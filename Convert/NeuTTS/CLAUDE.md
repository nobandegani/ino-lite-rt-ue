# NeuTTS conversion — done

Pipeline that converts **NeuTTS Nano** (an open-source TTS by Neuphonic)
from PyTorch into LiteRT artifacts consumable by the LiteRT-LM C++
engine. The matching audio decoder lives in `../NeuCodec/`.

## What's here

```
Convert/NeuTTS/
├── CLAUDE.md            ← this file
├── .gitignore
├── vendor/neutts/       ← upstream source submodule (read-only)
├── models/nano/         ← FP32 HF checkpoint, ~915 MB (gitignored)
├── voices/              ← pre-encoded reference voices (.pt)
│   └── jo.pt            ← English sample, 653 codes / ~13 s
├── output/              ← .tflite / .litertlm artifacts (gitignored)
│   └── *.litertlm       ← final bundles
├── generated/           ← test WAVs produced by test_tts.py (gitignored)
│   └── <quant>/*.wav
└── scripts/
    ├── neutts_nano.py        ← litert-torch model authoring (the architecture)
    ├── convert_to_tflite.py  ← HF safetensors -> .tflite (one quant per run)
    ├── verify.py             ← parity check vs HF model (atol=1e-4)
    ├── sanity_check.py       ← post-conversion .tflite vs HF logits
    ├── build_litertlm.py     ← bundle .tflite + tokenizer + chat template
    ├── encode_voice.py       ← WAV + transcript -> voices/<name>.pt
    ├── test_tts.py           ← end-to-end TFLite TTS smoke test
    ├── test_tts_pytorch.py   ← PyTorch-reference TTS for A/B comparison
    ├── requirements.txt
    └── README.md             ← env setup + commands
```

## Final artifacts

### Backbone bundles (`output/`)
Each `.litertlm` is a single file containing the LM, tokenizer, and
runtime metadata. Drop into UE Content and load via LiteRT-LM.

| File | Size | Use |
|------|------|------|
| `neutts_nano_f32_ekv2048.litertlm` | 895 MB | desktop reference |
| `neutts_nano_fp16_ekv2048.litertlm` | 459 MB | balanced |
| `neutts_nano_q8_ekv2048.litertlm` | **257 MB** | **mobile pick** |
| `neutts_nano_q4_block32_ekv2048.litertlm` | 146 MB | smallest, slightly noisier |

Each bundle contains **4 backbone signatures** (shared weights):
- `prefill_128` / `prefill_512` / `prefill_1024` — parallel prompt processing
- `decode` — single-token autoregressive generation (outputs logits)

KV cache shape per layer: `[1, 2048, 3, 64]` (NUM_KV_HEADS=3, HEAD_DIM=64).
Cache names: `kv_cache_k_0..23` and `kv_cache_v_0..23`.

### Codec decoder (`../NeuCodec/output/`)
| File | Size | Use |
|------|------|------|
| `neucodec_decoder_f32.tflite` | 740 MB | desktop |
| `neucodec_decoder_fp16.tflite` | 374 MB | balanced |
| `neucodec_decoder_q8.tflite` | **202 MB** | **mobile pick** |

Each contains **5 codec signatures**: `f100`, `f200`, `f400`, `f600`,
`f1000`. C++ picks the smallest bucket ≥ generated code count.

### Reference voices (`voices/`)
`*.pt` files holding `{"codes": LongTensor[F], "text": str}`. One per
voice. Ship as Content assets; load at runtime.

## Architecture (NeuTTS Nano backbone)

From `models/nano/config.json` — confirmed by Llasa-recipe finetune:

| Field | Value |
|------|------|
| Architecture | `LlamaForCausalLM` (Llama-3 family) |
| `hidden_size` | 576 |
| `intermediate_size` | 2304 |
| `num_hidden_layers` | 24 |
| `num_attention_heads` | 9 |
| `num_key_value_heads` | 3 (GQA 3:1) |
| `head_dim` | 64 |
| `vocab_size` | 194,256 |
| `max_position_embeddings` | 2048 |
| `rope_theta` | 500,000 |
| `rope_scaling` | `linear, factor=32` (NOT Llama-3 NTK!) |
| `tie_word_embeddings` | true |
| `rms_norm_eps` | 1e-5 |

Active params ≈ 120 M, total (with tied embed) ≈ 229 M.

### Vocab layout

```
0..127,999       : Llama-3 BPE tokens (words/subwords/bytes)
128,000..128,255 : Llama-3 specials (begin_of_text, eot, header, etc.)
128,256..128,261 : NeuTTS controls
                     128,256 = <|TEXT_REPLACE|>
                     128,257 = <|TEXT_PROMPT_START|>
                     128,258 = <|TEXT_PROMPT_END|>
                     128,259 = <|SPEECH_REPLACE|>
                     128,260 = <|SPEECH_GENERATION_START|>
                     128,261 = <|SPEECH_GENERATION_END|>    ← EOS
128,262..193,797 : <|speech_0|>..<|speech_65535|>  (FSQ code = id - 128262)
193,798..194,245 : IPA phoneme glyphs (single-token per glyph)
194,246..194,255 : unused padding rows
```

## Runtime contract (for C++ integration)

**Chat template** (literal text, host builds before tokenize):
```
<|begin_of_text|>user: Convert the text to speech:<|TEXT_PROMPT_START|>{ref_phones} {input_phones}<|TEXT_PROMPT_END|>
assistant:<|SPEECH_GENERATION_START|>{ref_codes_as_speech_tokens}
```
(this template is also baked into the `.litertlm` LlmMetadataProto so
LiteRT-LM's session API can apply it automatically)

**Pipeline:**
```
text -> eSpeak phonemize (host) -> tokenize (HF BPE, bundled) ->
  prefill_X (smallest bucket >= prompt_len) -> populates KV cache ->
  decode loop:
    decode(prev_token, pos) -> logits
    mask logits[128261] = -inf if step < 50  (min_new_tokens floor)
    sample top-k=50, temp=1.0
    stop on token 128261
  -> generated_token_ids
  -> filter token IDs in [128262, 193797]  (drop accidental non-speech)
  -> fsq_codes = token_id - 128262
  -> pick smallest codec bucket >= len(fsq_codes)
  -> pad with last_code, run f<bucket> -> audio
  -> trim audio to (len(fsq_codes) - 2) * 480 samples
  -> 24 kHz mono float32 waveform
```

**Sampler params** (also in the bundle's LlmMetadataProto):
- type = TOP_K
- k = 50
- temperature = 1.0
- min_new_tokens = 50  (enforced host-side; prevents short-utterance cutoff)
- max_num_tokens = 2048

## Quirks & gotchas (learned the hard way)

- **Linux only.** `litert-converter` only ships Linux wheels. Use WSL on Windows. Output `.tflite`/`.litertlm` are platform-agnostic.
- **Python 3.10 or 3.11.** `litert-converter`'s `.dev` wheels declare `Requires-Python >=3.9,<3.12`. 3.12+ envs fail at install.
- **litert-torch install is broken.** Setup.py pins `litert-converter==0.1.*` which doesn't exist on PyPI. Workaround: install upstream's `requirements.txt` first (has the real `>=0.0.0.dev0` constraint + `--pre`), then `pip install --no-deps -e ../../LiteRT/vendor/litert-torch`.
- **tf-nightly required at runtime.** `litert_torch/generative/layers/lora.py` imports `tensorflow.lite.python.schema_py_generated`. Not in `requirements.txt` (upstream lists it only in `dev-requirements.txt`).
- **Linear RoPE scaling, not NTK.** NeuTTS Nano uses `rope_scaling.type='linear', factor=32.0`. The default `_build_llama3_rope_cache` in litert-torch's `examples/llama/llama.py` is **wrong math** — uses smooth NTK piecewise scaling. We wrote `_build_linear_scaled_rope_cache` from scratch (`scripts/neutts_nano.py`).
- **transformers 5.x breaks the parity verifier.** litert-torch's `transformers_verifier` passes `use_model_defaults=False` to `model.generate()`, which 5.x rejects. We pass `verify_prompts=False` in `verify.py` — the logits-level check still runs and is the meaningful one.
- **min_new_tokens=50 is mandatory.** Without it, short prompts get EOS immediately and produce <0.5 s clips. Must be enforced host-side (LiteRT-LM's sampler honors the metadata when wired).
- **Codec padding boundary creates noise.** When you pad short codes with `0` to fill a bucket, the codec's STFT overlap-add smears those 0-codes into the last frame of real audio. Fixes (both applied in `test_tts.py`):
  - Pad with **the last real code** repeated (not 0).
  - Trim audio to `(n_real - 2) * 480` samples (not `n_real * 480`) — back off 2 frames to clear the STFT smear zone.
- **NeuCodec int4 not supported.** The FSQ codebook is shape `(65536, 8)` and 8 doesn't divide any supported int4 block size (32/64/128/256). Channelwise int4 isn't in the recipe matrix. Use fp16 or int8 for the codec.

## Environment

WSL Ubuntu 24.04 + conda env `inolitert-conv` (Python 3.11.15). See
`scripts/README.md` for the two-step install. Same env is used for
both NeuTTS and NeuCodec conversion work.

## Sanity comparison

Run a phrase through both pipelines and listen:

```bash
# LiteRT path
python scripts/test_tts.py --text "hello there" --quant int8
# -> generated/int8/hello_there.wav

# PyTorch reference (HF backbone + PyTorch NeuCodec)
python scripts/test_tts_pytorch.py --text "hello there"
# -> generated/pytorch_ref/hello_there.wav
```

They won't match bit-for-bit (top-k sampling with different RNGs), but
should sound like the same voice saying the same thing with similar
quality.

## Repo history

Built in 30+ commits, mid-2026. See `git log --oneline -- Convert/NeuTTS/`
for the full trail. Key milestones:

- `62e7708` — vendor neutts submodule
- `1529961` — initial 8-file conversion setup
- `17dde59` — WSL pivot + first sanity-check
- `8d61b82` — `.litertlm` bundling (tokenizer + chat template baked in)
- `907b22b` — multi-signature NeuCodec
