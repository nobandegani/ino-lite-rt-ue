# NeuTTS Nano → LiteRT conversion

Tooling that converts the **NeuTTS Nano backbone** (a 24-layer Llama-3-family
causal LM, ~120M active params) from its HuggingFace `safetensors` checkpoint
into a multi-signature `.tflite` file consumable by LiteRT-LM.

This is **backbone only**. NeuCodec (audio decoder), eSpeak (phonemizer), and
the BPE tokenizer all stay on the host runtime side and are not part of the
`.tflite`.

## Layout

```
Convert/NeuTTS/
├── scripts/                    # this folder
│   ├── neutts_nano.py          # model authoring (config + builder + RoPE)
│   ├── convert_to_tflite.py    # CLI: HF safetensors -> .tflite
│   ├── verify.py               # CLI: logits parity vs HF
│   ├── requirements.txt
│   └── README.md
├── models/nano/                # FP32 HF checkpoint (gitignored)
├── output/                     # .tflite lands here (contents gitignored)
└── vendor/neutts/              # NeuTTS source, as submodule (read-only)
```

## One-time environment setup

> **Linux only.** litert-torch's `litert-converter` dependency only ships
> Linux wheels — Windows envs fail with `No matching distribution found for
> litert-converter` because no version matches the platform. Upstream's own
> README (`README.md` line 74) and CI matrix confirm Linux is the only
> supported OS. On Windows, run the conversion **in WSL** (see below). The
> output `.tflite` is platform-agnostic and works fine in your Windows
> LiteRT-LM build.
>
> Use **Python 3.10 or 3.11**, not 3.12+. The `litert-converter` `.dev`
> wheels declare `Requires-Python >=3.9,<3.12` so 3.12+ are filtered out.

### On Linux (or WSL on Windows)

If you're on Windows, first install WSL once:

```powershell
# Windows PowerShell, run as administrator. Reboots after.
wsl --install
```

Then launch Ubuntu from Start menu, set a username/password on first run,
and:

```bash
sudo apt update
sudo apt install -y python3.11 python3.11-venv python3-pip
```

Your Windows drives appear under `/mnt/<letter>/`. Move into the project
and set up the env:

```bash
cd /mnt/e/Projects/InoProject/Plugins/InoLiteRT/Convert/NeuTTS

python3.11 -m venv .venv
source .venv/bin/activate

# Step 1: pull all transitive deps (torch, ai-edge-litert-nightly,
# ai-edge-quantizer-nightly, litert-converter, jax, transformers, etc.)
# via upstream litert-torch's own requirements.txt.
pip install -r scripts/requirements.txt

# Step 2: install litert-torch itself, skipping its setup.py dep
# resolution (its `litert-converter==0.1.*` pin is broken — that version
# doesn't exist on PyPI even on Linux). The deps from step 1 already
# cover everything it needs.
pip install --no-deps -e ../../LiteRT/vendor/litert-torch

# Smoke test — prints `ok` if the install is good.
python -c "from litert_torch.generative.utilities import converter; print('ok')"
```

> **Why two steps?** litert-torch's `setup.py` pins `litert-converter==0.1.*`,
> but `litert-converter` only ships to PyPI as `0.0.0.devXXX` pre-releases
> (Linux-only) — no `0.1.*` release exists. Upstream's own `requirements.txt`
> works around this with the looser `litert-converter>=0.0.0.dev0`. We use
> their `requirements.txt` for the dep set, then install litert-torch
> itself with `--no-deps` to bypass the broken pin.

If you prefer **conda** to `venv`:

```bash
conda create -n inolitert python=3.11 -y
conda activate inolitert
pip install -r scripts/requirements.txt
pip install --no-deps -e ../../LiteRT/vendor/litert-torch
```

## 1. Verify the re-authoring (do this BEFORE conversion)

Proves that the litert-torch model in `neutts_nano.py` produces the same
logits as the original HuggingFace `LlamaForCausalLM` for the same input.
Tolerance: `atol=1e-4`.

```powershell
python -m scripts.verify --checkpoint_dir=models\nano
```

Expected: `Verification passed!`

If it fails, the re-authored config is wrong. The most likely culprit is the
linear-scale RoPE math in `_build_linear_scaled_rope_cache` (NeuTTS uses HF
`rope_scaling.type='linear'` with `factor=32.0`, NOT Llama-3's smooth NTK
scaling — do not copy `examples/llama/llama.py`'s `_build_llama3_rope_cache`
binding wholesale).

## 2. Convert to `.tflite`

```bash
python -m scripts.convert_to_tflite \
  --checkpoint_path=models/nano \
  --output_path=output \
  --output_name_prefix=neutts_nano \
  --kv_cache_max_len=2048 \
  --prefill_seq_lens=128 \
  --prefill_seq_lens=512 \
  --prefill_seq_lens=1024 \
  --quantize=dynamic_int8
```

> **Note**: `--prefill_seq_lens` is an absl `multi_int` flag, so it must
> be passed once per value, not as `--prefill_seq_lens=128,512,1024`
> (which fails with `invalid literal for int(): '128,512,1024'`).

Output file: `output/neutts_nano_q8_ekv2048.tflite` (~80 MB at int8 quant
for a 229M-emb+active model with tied embeddings).

`kv_cache_max_len=2048` matches the model's `max_position_embeddings` and the
NeuTTS runtime contract (`max_context = 2048` in
`vendor/neutts/neutts/neutts.py:83`). Reduce it if you only need shorter
generations and want a smaller cache footprint.

`prefill_seq_lens` selects which prefill chunk sizes get their own signature
in the `.tflite`. The defaults `[8, 64, 128, 256, 512, 1024]` cover most use
cases; the values here (128, 512, 1024) are tighter and match typical NeuTTS
prompt sizes (chat preamble + phonemes + ~50–500 reference codes).

### Quantization options

| `--quantize`                | Output suffix      | Trade-off                              |
|-----------------------------|--------------------|----------------------------------------|
| `none`                      | `_f32`             | fp32, largest, reference quality       |
| `fp16`                      | `_fp16`            | fp16, ~2× smaller than f32             |
| `weight_only_int8`          | `_q8_wo`           | weight-only int8                       |
| `dynamic_int8` *(default)*  | `_q8`              | balanced — good first try              |
| `dynamic_int4_block32`      | `_q4_block32`      | smallest, slower; **best for mobile**  |
| `dynamic_int4_block128`     | `_q4_block128`     | smaller, faster; some quality loss     |

## Runtime contract reminders

When wiring the resulting `.tflite` into LiteRT-LM:

- **EOS token** is **128261** (`<|SPEECH_GENERATION_END|>`), not Llama 3's
  default EOT. `min_new_tokens=50` floor prevents premature stop (matches
  `_infer_torch` in `vendor/neutts/neutts/neutts.py:357`).
- **Sampling**: `temperature=1.0`, `top_k=50`, no top_p, no repetition
  penalty. The host (LiteRT-LM) owns the sampler; the `.tflite` graph emits
  raw logits.
- **Vocab is padded**: 194,256 rows total, only 0–194,245 ever used (10
  unused trailing rows). Speech tokens at 128,262–193,797. Special control
  tokens at 128,256–128,261.
- **Chat template** is hard-coded in NeuTTS Python (no `chat_template` field
  in `tokenizer_config.json`). The runtime must build it itself — see
  `vendor/neutts/neutts/neutts.py:314-343` (`_apply_chat_template`).

## Out of scope here

- Running the conversion (this README documents *how*; you trigger it).
- NeuCodec decoder conversion (separate model).
- LiteRT-LM C++ integration in `InoLiteRT.cpp` / `InoAgents`.
- Tokenizer conversion to LiteRT-LM's preferred SentencePiece protobuf
  format.
