# Copyright 2026 Inoland. Licensed under the Apache License, Version 2.0.
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
SAMPLE_RATE = 24000

# Mask value for positions we DON'T want attended to. Added to QK scores
# before softmax — large negative is needed to push softmax weight to ~0.
MASK_NEG_INF = -1e9


def _inspect_backbone(interp):
    """Read shapes from the loaded interpreter so we don't hardcode anything.

    Works for both the old BTNH (default) and new BNTH/BNHT (--transpose_kv_cache)
    layouts, with or without `mask` as input.
    """
    sigs = interp.get_signature_list()
    # Prefill buckets — parse "prefill_NNN" -> NNN, sorted ascending.
    prefill_buckets = sorted(
        int(name.split("_", 1)[1])
        for name in sigs.keys()
        if name.startswith("prefill_") and name.split("_", 1)[1].isdigit()
    )
    if not prefill_buckets:
        raise SystemExit(f"No prefill_* signatures in backbone: {list(sigs.keys())}")
    if "decode" not in sigs:
        raise SystemExit(f"No `decode` signature in backbone: {list(sigs.keys())}")

    # KV cache shape from kv_cache_k_0 of the first prefill signature.
    runner0 = interp.get_signature_runner(f"prefill_{prefill_buckets[0]}")
    inputs = runner0.get_input_details()
    k0 = inputs.get("kv_cache_k_0")
    if k0 is None:
        raise SystemExit("kv_cache_k_0 not found in backbone inputs.")
    k_shape = tuple(int(x) for x in k0["shape"])  # K layout
    v0 = inputs.get("kv_cache_v_0")
    v_shape = tuple(int(x) for x in v0["shape"]) if v0 is not None else None

    num_layers = sum(1 for k in inputs if k.startswith("kv_cache_k_"))
    has_mask = "mask" in inputs

    return {
        "prefill_buckets": prefill_buckets,
        "num_layers": num_layers,
        "k_shape": k_shape,            # full K cache shape including batch
        "v_shape": v_shape,
        "has_mask": has_mask,
        "kv_cache_max_len": _infer_kv_max(k_shape, v_shape),
    }


def _infer_kv_max(k_shape, v_shape):
    """The KV "time" dim is the dim with the biggest extent (typically 2048 or 2053)."""
    return max(k_shape[1:])  # ignore batch dim


def _zero_kv_cache(num_layers, k_shape, v_shape):
    """Build all-zero K/V cache tensors with the exact shapes the model wants."""
    kv = {}
    for i in range(num_layers):
        kv[f"kv_cache_k_{i}"] = np.zeros(k_shape, dtype=np.float32)
        kv[f"kv_cache_v_{i}"] = np.zeros(v_shape, dtype=np.float32)
    return kv


def _build_prefill_mask(prefill_len, kv_max):
    """Causal mask for the first prefill from an empty cache.

    Shape: [1, 1, prefill_len, kv_max]. mask[..., i, j] = 0 if j <= i, -inf otherwise.
    """
    mask = np.full((1, 1, prefill_len, kv_max), MASK_NEG_INF, dtype=np.float32)
    # Lower-triangular zeros within the [prefill_len, prefill_len] block.
    i = np.arange(prefill_len)[:, None]
    j = np.arange(prefill_len)[None, :]
    mask[0, 0, :, :prefill_len] = np.where(j <= i, 0.0, MASK_NEG_INF).astype(np.float32)
    return mask


def _build_decode_mask(current_pos, kv_max):
    """Mask for one decode step at position `current_pos`.

    The new token at position p attends to KV slots [0..p] (its own slot
    is being written right now). Slots beyond p are -inf.
    """
    mask = np.full((1, 1, 1, kv_max), MASK_NEG_INF, dtype=np.float32)
    mask[0, 0, 0, : current_pos + 1] = 0.0
    return mask


def _pick_prefill_bucket(prompt_len, prefill_buckets):
    for b in prefill_buckets:
        if prompt_len <= b:
            return b
    raise ValueError(
        f"Prompt length {prompt_len} exceeds max bucket {prefill_buckets[-1]}."
    )


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
    p.add_argument("--codec_frames", type=int, default=None,
                   help="Force a specific codec F bucket. Default: pick the"
                        " smallest bucket >= number of generated codes.")
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

    bb_suffix, codec_suffix = quant_suffix[args.quant]
    if codec_suffix is None:
        raise SystemExit(
            f"No NeuCodec variant exists for --quant={args.quant} (only fp32/fp16/int8)."
        )
    if args.backbone is None:
        # Try the new GPU-tuned ekv2053 first, fall back to the old ekv2048.
        for kv_size in (2053, 2048):
            candidate = f"output/neutts_nano_{bb_suffix}_ekv{kv_size}.tflite"
            if Path(candidate).exists():
                args.backbone = candidate
                break
        if args.backbone is None:
            args.backbone = f"output/neutts_nano_{bb_suffix}_ekv2053.tflite"
    if args.codec is None:
        # Codec .tflite is multi-signature now (one file per quant tier,
        # multiple F buckets as signatures named f100/f200/f400/f600/f1000).
        args.codec = f"../NeuCodec/output/neucodec_decoder_{codec_suffix}.tflite"
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

    # --- 5. Load backbone, inspect signatures, run prefill ----------
    print(f"[4/7] Loading backbone {Path(args.backbone).name}...")
    bb = litert_interpreter.Interpreter(model_path=args.backbone)
    bb.allocate_tensors()
    info = _inspect_backbone(bb)
    print(
        f"  backbone shapes: prefill buckets={info['prefill_buckets']},"
        f" layers={info['num_layers']},"
        f" K={info['k_shape']}, V={info['v_shape']},"
        f" kv_max={info['kv_cache_max_len']}, mask={info['has_mask']}"
    )

    if len(prompt_ids) > info["prefill_buckets"][-1]:
        raise SystemExit(
            f"Prompt {len(prompt_ids)} tokens exceeds prefill_{info['prefill_buckets'][-1]}. "
            "Use a shorter reference voice or input."
        )

    bucket = _pick_prefill_bucket(len(prompt_ids), info["prefill_buckets"])
    print(f"[5/7] Prefilling (bucket={bucket})...")
    pad_len = bucket - len(prompt_ids)
    tokens_padded = np.array([prompt_ids + [0] * pad_len], dtype=np.int32)
    input_pos = np.arange(bucket, dtype=np.int32)

    kv = _zero_kv_cache(info["num_layers"], info["k_shape"], info["v_shape"])
    prefill_runner = bb.get_signature_runner(f"prefill_{bucket}")
    prefill_inputs = dict(tokens=tokens_padded, input_pos=input_pos, **kv)
    if info["has_mask"]:
        prefill_inputs["mask"] = _build_prefill_mask(bucket, info["kv_cache_max_len"])
    kv_out = prefill_runner(**prefill_inputs)
    # Carry forward updated KV cache
    for k, v in kv_out.items():
        if k.startswith(("kv_cache_k_", "kv_cache_v_")):
            kv[k] = v

    # Inspect codec early so we know the available F buckets and the
    # largest one (= cap for the decode loop).
    print(f"[6/7] Loading codec {Path(args.codec).name}...")
    codec = litert_interpreter.Interpreter(model_path=args.codec)
    codec.allocate_tensors()
    codec_sigs = list(codec.get_signature_list().keys())
    # Signatures are named f<N> (e.g. f100, f200). Parse out the buckets.
    buckets = sorted(int(s[1:]) for s in codec_sigs
                     if s.startswith("f") and s[1:].isdigit())
    if not buckets:
        raise SystemExit(f"Codec {args.codec} has no f<N> signatures: {codec_sigs}")
    print(f"  codec buckets: {buckets}")
    max_speech_tokens = args.codec_frames if args.codec_frames is not None else buckets[-1]

    # --- 6. Decode loop ---------------------------------------------
    print(f"  decoding (max {max_speech_tokens} speech tokens)...")
    decode_runner = bb.get_signature_runner("decode")
    generated_ids = []
    pos = len(prompt_ids)  # next position to decode at
    for step in range(max_speech_tokens):
        tok_in = np.array(
            [[generated_ids[-1] if generated_ids else prompt_ids[-1]]],
            dtype=np.int32,
        )
        pos_in = np.array([pos], dtype=np.int32)
        decode_inputs = dict(tokens=tok_in, input_pos=pos_in, **kv)
        if info["has_mask"]:
            decode_inputs["mask"] = _build_decode_mask(pos, info["kv_cache_max_len"])
        out = decode_runner(**decode_inputs)
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
    n_real = len(speech_codes)
    print(f"  generated {n_real} valid speech codes")
    if not speech_codes:
        raise SystemExit("Model produced no speech codes; aborting.")

    # Pick the smallest bucket >= n_real. If n_real exceeds the largest
    # bucket, fall back to the largest (we'll lose some tail audio).
    chosen_bucket = next((b for b in buckets if b >= n_real), buckets[-1])
    if n_real > chosen_bucket:
        print(f"  WARNING: n_real={n_real} exceeds largest bucket {chosen_bucket}; truncating.")
    print(f"[7/7] Decoding codec with signature f{chosen_bucket}...")

    # Pad to chosen_bucket with the LAST real code repeated (not 0). Code
    # 0 decodes to something arbitrary; repeating the last code gives a
    # sustained continuation that trims cleanly below.
    last_code = speech_codes[-1] if n_real > 0 else 0
    padded = speech_codes[:chosen_bucket] + [last_code] * (chosen_bucket - min(n_real, chosen_bucket))
    padded = padded[:chosen_bucket]
    codes_np = np.array([[padded]], dtype=np.int64)

    codec_runner = codec.get_signature_runner(f"f{chosen_bucket}")
    audio = codec_runner(codes=codes_np)
    audio_wave = list(audio.values())[0][0, 0, :]
    # Set max_speech_tokens for the trim formula below.
    max_speech_tokens = chosen_bucket

    # Trim to roughly n_real * 480 samples, but back off ~2 frames to
    # avoid the codec's STFT overlap-add smearing the padding boundary
    # into the last frame of real audio. n_fft=1920 hop=480 means each
    # output sample is influenced by frames within ±2 frames of its
    # position, so the safe end is (n_real - 2) * 480.
    safe_end = max(0, (n_real - 2) * 480)
    trim = min(len(audio_wave), safe_end) if n_real > 2 else min(len(audio_wave), n_real * 480)
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
