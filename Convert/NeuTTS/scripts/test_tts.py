"""End-to-end TTS smoke test: text -> audio.

Loads:
  - voices/<voice>.pt           (FSQ codes + transcript for the reference voice)
  - output/<backbone>.tflite    (NeuTTS Nano backbone)
  - output/<codec>.tflite       (NeuCodec decoder, F=50 -> 0.98 s of audio)
  - models/nano/tokenizer.json  (HF tokenizer)

Pipeline:
  1. eSpeak phonemize (ref_text + " " + input_text)
  2. Build prompt string with NeuTTS chat template
  3. Append ref voice's <|speech_N|> codes after <|SPEECH_GENERATION_START|>
  4. Tokenize prompt
  5. Prefill backbone with prompt (padded to next prefill bucket: 128/512/1024)
  6. Decode loop: sample top-k=50 temp=1.0, stop on <|SPEECH_GENERATION_END|>
     or when we've generated 50 speech tokens (codec F=50 budget)
  7. Convert generated speech token IDs to FSQ codes (id - 128262)
  8. Pad to F=50, run codec, save WAV

Run from Plugins/InoLiteRT/Convert/NeuTTS/:

    python scripts/test_tts.py \
        --text "Hello world" \
        --voice voices/jo.pt \
        --backbone output/neutts_nano_q8_ekv2048.tflite \
        --codec output/neucodec_decoder_f50_q8.tflite \
        --out output/test.wav
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import torch
from ai_edge_litert import interpreter as litert_interpreter
from scipy.io import wavfile
from transformers import AutoTokenizer

# Use phonemizer (already installed as a neutts dep) directly. Importing
# `from neutts.phonemizers import BasePhonemizer` would pull in the
# neutts package __init__, which transitively imports neucodec — and we
# don't pip-install neucodec in this env.
from phonemizer.backend import EspeakBackend  # noqa: E402

# --- Constants (from models/nano/config.json + tokenizer.json) ----------
SPEECH_OFFSET = 128262          # <|speech_0|> starts here
SPEECH_END = 128261             # <|SPEECH_GENERATION_END|>
TOP_K = 50
TEMPERATURE = 1.0
MIN_NEW_TOKENS = 50             # Match NeuTTS's _infer_torch — don't let the
                                # model emit EOS in the first 50 steps. Without
                                # this short utterances cut off after ~0.5 s.
NUM_LAYERS = 24
NUM_KV_HEADS = 3
HEAD_DIM = 64
KV_CACHE_MAX_LEN = 2048
PREFILL_BUCKETS = [128, 512, 1024]
SAMPLE_RATE = 24000


def _zero_kv_cache():
    """Build the all-zero KV cache dict expected by both prefill and decode."""
    shape = (1, KV_CACHE_MAX_LEN, NUM_KV_HEADS, HEAD_DIM)
    kv = {}
    for i in range(NUM_LAYERS):
        kv[f"kv_cache_k_{i}"] = np.zeros(shape, dtype=np.float32)
        kv[f"kv_cache_v_{i}"] = np.zeros(shape, dtype=np.float32)
    return kv


def _pick_prefill_bucket(prompt_len: int) -> int:
    for b in PREFILL_BUCKETS:
        if prompt_len <= b:
            return b
    raise ValueError(f"Prompt length {prompt_len} exceeds max bucket {PREFILL_BUCKETS[-1]}.")


def _sample_top_k(logits: np.ndarray, k: int, temperature: float) -> int:
    """Top-k sampling on a 1D logits vector."""
    logits = logits.astype(np.float32) / temperature
    # Get top-k indices and their logits
    top_idx = np.argpartition(logits, -k)[-k:]
    top_logits = logits[top_idx]
    # Softmax over top-k
    top_logits -= top_logits.max()
    probs = np.exp(top_logits)
    probs /= probs.sum()
    chosen = np.random.choice(top_idx, p=probs)
    return int(chosen)


def main():
    # Map --quant to file suffixes used by the .tflite naming convention.
    quant_suffix = {
        "fp32": ("f32", "f32"),               # (backbone_suffix, codec_suffix)
        "fp16": ("fp16", "fp16"),
        "int8": ("q8", "q8"),
        "int4": ("q4_block32", None),          # NeuCodec has no int4 variant
    }

    p = argparse.ArgumentParser()
    p.add_argument("--text", required=True, help="Text to synthesize.")
    p.add_argument("--quant", choices=list(quant_suffix), default="fp32",
                   help="Quantization tier. Selects matching backbone + codec + output subfolder.")
    p.add_argument("--codec_frames", type=int, default=200,
                   help="Codec F bucket to use (must match a converted .tflite — default 200).")
    p.add_argument("--voice", default="voices/jo.pt")
    p.add_argument("--backbone", default=None,
                   help="Override backbone .tflite path (default: derived from --quant).")
    p.add_argument("--codec", default=None,
                   help="Override codec .tflite path (default: derived from --quant and --codec_frames).")
    p.add_argument("--tokenizer_dir", default="models/nano")
    p.add_argument("--out", default=None,
                   help="Override output WAV path (default: generated/<quant>/<text>.wav).")
    p.add_argument("--seed", type=int, default=42)
    args = p.parse_args()
    max_speech_tokens = args.codec_frames

    bb_suffix, codec_suffix = quant_suffix[args.quant]
    if codec_suffix is None:
        raise SystemExit(
            f"No NeuCodec variant exists for --quant={args.quant} (only fp32/fp16/int8)."
        )
    if args.backbone is None:
        args.backbone = f"output/neutts_nano_{bb_suffix}_ekv2048.tflite"
    if args.codec is None:
        # Codec .tflite lives in Convert/NeuCodec/output/, not Convert/NeuTTS/output/.
        args.codec = (
            f"../NeuCodec/output/neucodec_decoder_f{args.codec_frames}_{codec_suffix}.tflite"
        )
    if args.out is None:
        # Sanitize input text into a filename stem: lowercase, alnum + spaces only,
        # spaces -> underscores. e.g. "How are you?" -> "how_are_you".
        import re
        stem = re.sub(r"[^a-z0-9 ]+", "", args.text.lower()).strip()
        stem = re.sub(r"\s+", "_", stem)
        if not stem:
            stem = "test"
        args.out = f"generated/{args.quant}/{stem}.wav"

    np.random.seed(args.seed)

    # --- 1. Load reference voice -------------------------------------
    print(f"[1/7] Loading reference voice from {args.voice}...")
    ref = torch.load(args.voice, weights_only=False)
    ref_codes = ref["codes"].tolist()
    ref_text = ref["text"]
    print(f"  ref codes: {len(ref_codes)}, ref text: '{ref_text[:60]}...'")

    # --- 2. Phonemize ref_text + input_text --------------------------
    # Same EspeakBackend settings as vendor/neutts/neutts/phonemizers.py
    print(f"[2/7] Phonemizing...")
    phon = EspeakBackend(
        language="en-us",
        preserve_punctuation=True,
        with_stress=True,
        words_mismatch="ignore",
        language_switch="remove-flags",
    )
    ref_phones = " ".join(phon.phonemize([ref_text])[0].split())
    in_phones = " ".join(phon.phonemize([args.text])[0].split())
    phonemes = ref_phones + " " + in_phones
    print(f"  phonemes: '{phonemes[:80]}...'")

    # --- 3. Build prompt string (matches _infer_ggml in neutts.py) ---
    codes_str = "".join(f"<|speech_{i}|>" for i in ref_codes)
    prompt = (
        f"user: Convert the text to speech:<|TEXT_PROMPT_START|>{phonemes}"
        f"<|TEXT_PROMPT_END|>\nassistant:<|SPEECH_GENERATION_START|>{codes_str}"
    )

    # --- 4. Tokenize -------------------------------------------------
    print(f"[3/7] Tokenizing...")
    tok = AutoTokenizer.from_pretrained(args.tokenizer_dir)
    prompt_ids = tok.encode(prompt)
    print(f"  prompt_ids length: {len(prompt_ids)}")
    if len(prompt_ids) > PREFILL_BUCKETS[-1]:
        raise SystemExit(
            f"Prompt {len(prompt_ids)} tokens exceeds prefill_{PREFILL_BUCKETS[-1]}. "
            "Use a shorter reference voice or input."
        )

    # --- 5. Load backbone and run prefill ----------------------------
    print(f"[4/7] Loading backbone {Path(args.backbone).name}...")
    bb = litert_interpreter.Interpreter(model_path=args.backbone)
    bb.allocate_tensors()

    bucket = _pick_prefill_bucket(len(prompt_ids))
    print(f"[5/7] Prefilling (bucket={bucket})...")
    pad_len = bucket - len(prompt_ids)
    tokens_padded = np.array([prompt_ids + [0] * pad_len], dtype=np.int32)
    input_pos = np.arange(bucket, dtype=np.int32)

    kv = _zero_kv_cache()
    prefill_runner = bb.get_signature_runner(f"prefill_{bucket}")
    kv_out = prefill_runner(tokens=tokens_padded, input_pos=input_pos, **kv)
    # Carry forward updated KV cache
    for k, v in kv_out.items():
        if k.startswith(("kv_cache_k_", "kv_cache_v_")):
            kv[k] = v

    # --- 6. Decode loop ---------------------------------------------
    print(f"[6/7] Decoding (max {max_speech_tokens} speech tokens)...")
    decode_runner = bb.get_signature_runner("decode")
    generated_ids = []
    pos = len(prompt_ids)  # next position to decode at
    for step in range(max_speech_tokens):
        tok_in = np.array(
            [[generated_ids[-1] if generated_ids else prompt_ids[-1]]],
            dtype=np.int32,
        )
        pos_in = np.array([pos], dtype=np.int32)
        out = decode_runner(tokens=tok_in, input_pos=pos_in, **kv)
        logits = out["logits"][0, 0, :].copy()
        # Block EOS for the first MIN_NEW_TOKENS steps so short utterances
        # don't get cut off mid-word.
        if step < MIN_NEW_TOKENS:
            logits[SPEECH_END] = -1e9
        next_id = _sample_top_k(logits, TOP_K, TEMPERATURE)
        # Carry forward KV
        for k, v in out.items():
            if k.startswith(("kv_cache_k_", "kv_cache_v_")):
                kv[k] = v
        if next_id == SPEECH_END:
            print(f"  hit <|SPEECH_GENERATION_END|> after {step+1} steps")
            break
        generated_ids.append(next_id)
        pos += 1
    else:
        print(f"  hit max_speech_tokens limit ({max_speech_tokens})")

    # --- 7. Convert to FSQ codes and run codec -----------------------
    speech_codes = [tid - SPEECH_OFFSET for tid in generated_ids
                    if SPEECH_OFFSET <= tid < SPEECH_OFFSET + 65536]
    print(f"  generated {len(speech_codes)} valid speech codes")
    if not speech_codes:
        raise SystemExit("Model produced no speech codes; aborting.")

    # Codec graph has a fixed F. Pad the codes vector to that length;
    # we'll trim the codec's audio output to discard the padding's noise.
    n_real = len(speech_codes)
    padded = speech_codes + [0] * (max_speech_tokens - n_real)
    padded = padded[:max_speech_tokens]
    codes_np = np.array([[padded]], dtype=np.int64)

    print(f"[7/7] Decoding codec...")
    codec = litert_interpreter.Interpreter(model_path=args.codec)
    codec.allocate_tensors()
    codec_runner = codec.get_signature_runner(
        list(codec.get_signature_list().keys())[0]
    )
    audio = codec_runner(codes=codes_np)
    audio_wave = list(audio.values())[0][0, 0, :]

    # Trim to the real-codes audio length: 480 samples per FSQ frame (24 kHz
    # / 50 Hz codes). Anything beyond is the codec hallucinating audio for
    # our zero-padding — drop it.
    trim = min(len(audio_wave), n_real * 480)
    audio_wave = audio_wave[:trim]
    print(f"  trimmed to {trim} samples ({trim/SAMPLE_RATE:.2f} s real audio)")

    # --- Save WAV ---------------------------------------------------
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    audio_int16 = np.clip(audio_wave, -1.0, 1.0)
    audio_int16 = (audio_int16 * 32767.0).astype(np.int16)
    wavfile.write(out_path, SAMPLE_RATE, audio_int16)
    print(f"\nDone. Wrote {out_path} ({len(audio_int16)/SAMPLE_RATE:.2f} s @ {SAMPLE_RATE} Hz)")


if __name__ == "__main__":
    main()
