# NeuTTS conversion — done

Pipeline that converts **NeuTTS Nano** (an open-source TTS by Neuphonic)
from PyTorch into LiteRT artifacts consumable by the LiteRT-LM C++
engine. The matching audio decoder lives in `../NeuCodec/`.

Current build target: **Option C — single GPU-tuned variant**
(BNTH/BNHT KV layout + mask-as-input + dynamic prime shapes). The
artifacts still run on CPU with a small (~5–10%) perf hit and ship as
`backend_constraint=gpu,cpu` so the LiteRT-LM engine accepts both.

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
Each `.litertlm` is a single file containing the LM, tokenizer, runtime
metadata, and the chat template. Drop into UE Content and load via
LiteRT-LM.

| File | Size | Use |
|------|------|------|
| `neutts_nano_f32_ekv2053.litertlm` | 878 MB | desktop reference |
| `neutts_nano_fp16_ekv2053.litertlm` | 442 MB | balanced |
| `neutts_nano_q8_ekv2053.litertlm` | **240 MB** | **mobile pick** |
| `neutts_nano_q4_block32_ekv2053.litertlm` | 129 MB | smallest, slightly noisier |

Bundle metadata on each `TFLiteModel` section:
- `backend_constraint = "gpu,cpu"` — engine rejects load if neither matches
- `prefer_activation_type = "fp16"` — runtime hint, see "GPU activation
  type" in Quirks below.

### Backbone graph shape (post-Option-C)

Each bundle contains **4 backbone signatures** (shared weights):
- `prefill_131` / `prefill_521` / `prefill_1031` — parallel prompt processing
- `decode` — single-token autoregressive generation (outputs logits)

The "prime" bucket numbers (131, 521, 1031) come from
`--gpu_dynamic_shapes=True` at conversion time: it rewrites each
declared bucket length to the next prime ≥10 to make WebGPU/ML-Drift
shader specialization happy. The shape we asked for was 128/512/1024;
the file holds primes.

| Input | Shape | dtype |
|---|---|---|
| `tokens` | `[1, P]` (P = bucket size) | int32 |
| `input_pos` | `[P]` | int32 |
| `mask` | `[1, 1, P, 2053]` (causal mask, host-built) | float32 |
| `kv_cache_k_0..23` | `[1, 3, 2053, 64]` — **BNTH** layout | float32 |
| `kv_cache_v_0..23` | `[1, 3, 64, 2053]` — **BNHT** layout (note: V transposed differently) | float32 |

`kv_cache_max_len = 2053` (the next prime ≥ the 2048 we asked for).

For decode: `tokens [1, 1]`, `input_pos [1]`, `mask [1, 1, 1, 2053]`,
same KV cache shapes. Decode also returns `logits [1, 1, vocab=194256]`.

### Codec decoder (`../NeuCodec/output/`)
| File | Size | Use |
|------|------|------|
| `neucodec_decoder_f32.tflite` | 740 MB | desktop |
| `neucodec_decoder_fp16.tflite` | 374 MB | balanced |
| `neucodec_decoder_q8.tflite` | **202 MB** | **mobile pick** |

Each contains **5 codec signatures**: `f100`, `f200`, `f400`, `f600`,
`f1000`. C++ picks the smallest bucket ≥ generated code count. Codec
was NOT touched by Option C (no KV cache, no attention mask, multi-sig
already correct).

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
    decode(prev_token, pos, mask) -> logits + updated KV
    mask logits[128261] = -inf if step < 50  (min_new_tokens floor)
    sample top-p=0.95 / top-k=50 / temp=1.0
    stop on token 128261
  -> generated_token_ids
  -> filter token IDs in [128262, 193797]  (drop accidental non-speech)
  -> fsq_codes = token_id - 128262
  -> pick smallest codec bucket >= len(fsq_codes)
  -> pad with last_code, run f<bucket> -> audio
  -> trim audio to (len(fsq_codes) - 2) * 480 samples
  -> 24 kHz mono float32 waveform
```

**Causal mask** (the host must build this every call):
```
prefill at start_pos=0, length P:
  mask = [1, 1, P, 2053] float32
  mask[0, 0, i, j] = 0    if j <= i        (causal: see your past)
  mask[0, 0, i, j] = -inf otherwise
decode at position p:
  mask = [1, 1, 1, 2053] float32
  mask[0, 0, 0, j] = 0    if j <= p
  mask[0, 0, 0, j] = -inf otherwise
```
(`-1e9` works as a stand-in for `-inf`.)

**Sampler params** (also in the bundle's LlmMetadataProto):
- `type = TOP_P` (NOT TOP_K — see Quirks)
- `k = 50` (top-k cap applied by `TopPSampler` internally)
- `p = 0.95`
- `temperature = 1.0`
- `min_new_tokens = 50` (enforced host-side; prevents short-utterance cutoff)
- `max_num_tokens = 2048`

## Quirks & gotchas (learned the hard way)

### Conversion / build pipeline

- **Linux only.** `litert-converter` only ships Linux wheels. Use WSL on Windows. Output `.tflite`/`.litertlm` are platform-agnostic.
- **Python 3.10 or 3.11.** `litert-converter`'s `.dev` wheels declare `Requires-Python >=3.9,<3.12`. 3.12+ envs fail at install.
- **litert-torch install is broken.** Setup.py pins `litert-converter==0.1.*` which doesn't exist on PyPI. Workaround: install upstream's `requirements.txt` first (has the real `>=0.0.0.dev0` constraint + `--pre`), then `pip install --no-deps -e ../../LiteRT/vendor/litert-torch`.
- **tf-nightly required at runtime.** `litert_torch/generative/layers/lora.py` imports `tensorflow.lite.python.schema_py_generated`. Not in `requirements.txt` (upstream lists it only in `dev-requirements.txt`).
- **Linear RoPE scaling, not NTK.** NeuTTS Nano uses `rope_scaling.type='linear', factor=32.0`. The default `_build_llama3_rope_cache` in litert-torch's `examples/llama/llama.py` is **wrong math** — uses smooth NTK piecewise scaling. We wrote `_build_linear_scaled_rope_cache` from scratch (`scripts/neutts_nano.py`).
- **transformers 5.x breaks the parity verifier.** litert-torch's `transformers_verifier` passes `use_model_defaults=False` to `model.generate()`, which 5.x rejects. We pass `verify_prompts=False` in `verify.py` — the logits-level check still runs and is the meaningful one.
- **Bundler PyPI wheel lags master.** `litert-lm-builder` 0.11.0 on PyPI doesn't expose `prefer_activation_type` as a kwarg on `add_tflite_model()` even though the vendored source has it. Workaround: pass it via `additional_metadata=[Metadata(key='prefer_activation_type', value='fp16', dtype=DType.STRING)]` — the runtime loader reads it identically.

### Generation correctness

- **min_new_tokens=50 is mandatory.** Without it, short prompts get EOS immediately and produce <0.5 s clips. Must be enforced host-side (LiteRT-LM's sampler honors the metadata when wired).
- **Codec padding boundary creates noise.** When you pad short codes with `0` to fill a bucket, the codec's STFT overlap-add smears those 0-codes into the last frame of real audio. Fixes (both applied in `test_tts.py`):
  - Pad with **the last real code** repeated (not 0).
  - Trim audio to `(n_real - 2) * 480` samples (not `n_real * 480`) — back off 2 frames to clear the STFT smear zone.

### Runtime / LiteRT-LM integration

- **`sampler_params.type = TOP_K` makes `create_session` return NULL.** LiteRT-LM's basic CPU sampler factory only implements `TOP_P` and `TYPE_UNSPECIFIED` (`runtime/components/sampler_factory.cc:579-595`). TOP_K returns `UnimplementedError("Sampler type: 1 not implemented yet.")` which propagates up and turns into a NULL session pointer. Our bundle uses **TOP_P with `k=50, p=0.95, temp=1.0`** (TopPSampler accepts both a top-k cap and top-p threshold, behaviorally close to pure top-k).
- **GPU activation type is silently forced to FP32 by the C API.** `c/engine.cc:375-380` calls `SetActivationDataType(FLOAT32)` whenever `backend=="gpu"`, which then overrides the bundle's `prefer_activation_type=fp16` hint at `engine_settings.cc:121-124` (only applied if executor's type is `nullopt`). **The UE plugin must call this AFTER `litert_lm_engine_settings_create(...)`**:
  ```cpp
  litert_lm_engine_settings_set_activation_data_type(settings, 1 /* FLOAT16 */);
  ```
  Otherwise the GPU path runs at fp32 (correct but ~1.5–2× slower).
- **GPU `max_top_k` defaults to 1 (greedy only).** The GPU sampler refuses any k>1 unless `GpuConfig::max_top_k` is bumped on the engine settings before `litert_lm_engine_create()`. Path: `engine_settings->GetMutableMainExecutorSettings().MutableBackendConfig<GpuConfig>()->max_top_k = N`.
- **NeuCodec doesn't go through LiteRT-LM.** No "vocoder" executor exists. Drive the codec via the lower-level `LiteRtCompiledModel*` C API directly. On GPU also call `gpu_options.SetSerializationDir(<cache>)` + `SetSerializeProgramCache(true)` — otherwise the 5 codec signatures JIT-compile 5 separate WebGPU shader sets on every cold start.

### NeuCodec model-side

- **NeuCodec int4 not supported.** The FSQ codebook is shape `(65536, 8)` and 8 doesn't divide any supported int4 block size (32/64/128/256). Channelwise int4 isn't in the recipe matrix. Use fp16 or int8 for the codec.

## Environment

WSL Ubuntu 24.04 + conda env `inolitert-conv` (Python 3.11.15). See
`scripts/README.md` for the two-step install. Same env is used for
both NeuTTS and NeuCodec conversion work.

## Conversion commands (for reproducibility)

### Backbone — all 4 quants

```bash
cd Convert/NeuTTS
for Q in none fp16 dynamic_int8 dynamic_int4_block32; do
  python -m scripts.convert_to_tflite \
    --checkpoint_path=models/nano \
    --output_path=output \
    --output_name_prefix=neutts_nano \
    --kv_cache_max_len=2048 \
    --prefill_seq_lens=128 --prefill_seq_lens=512 --prefill_seq_lens=1024 \
    --transpose_kv_cache=True \
    --mask_as_input=True \
    --gpu_dynamic_shapes=True \
    --quantize=$Q
done
python -m scripts.build_litertlm   # bundles all 4 into .litertlm
```

The three `--transpose_kv_cache`, `--mask_as_input`, `--gpu_dynamic_shapes`
flags are what make this Option C. The bucket numbers and kv_cache_max_len
in the resulting files become primes (131/521/1031, 2053).

### Codec — all 3 quants

```bash
cd Convert/NeuCodec
for Q in none fp16 dynamic_int8; do
  python -m scripts.convert_to_tflite --quantize=$Q
done
```

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

They won't match bit-for-bit (top-k/top-p sampling with different RNGs), but
should sound like the same voice saying the same thing with similar
quality.

## Repo history

Built mid-2026 in 50+ commits. See `git log --oneline -- Convert/NeuTTS/`
for the full trail. Key milestones:

- `62e7708` — vendor neutts submodule
- `1529961` — initial 8-file conversion setup
- `17dde59` — WSL pivot + first sanity-check
- `8d61b82` — `.litertlm` bundling (tokenizer + chat template baked in)
- `907b22b` — multi-signature NeuCodec
- `e3c4d75` — TOP_K → TOP_P fix (CPU sampler compat)
- `0cnjc5l5`/`2629b40` — Option C: re-convert with GPU flags, rebundle
  with `backend_constraint=gpu,cpu` + `prefer_activation_type=fp16`
- `11bd7c6` — test_tts.py discovers backbone shapes dynamically (handles
  BNTH/BNHT KV layout + mask input)
