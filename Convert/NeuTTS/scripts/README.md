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

Python ≥ 3.10. From `Plugins/InoLiteRT/Convert/NeuTTS/`:

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r scripts\requirements.txt
```

The bulk of the dependency tree (torch 2.11, ai-edge-litert-nightly,
ai-edge-quantizer-nightly, jax, transformers, safetensors) is pulled in
transitively via the editable install of `litert-torch` in
`requirements.txt`.

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

```powershell
python -m scripts.convert_to_tflite `
  --checkpoint_path=models\nano `
  --output_path=output `
  --output_name_prefix=neutts_nano `
  --kv_cache_max_len=2048 `
  --prefill_seq_lens=128,512,1024 `
  --quantize=dynamic_int8
```

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
