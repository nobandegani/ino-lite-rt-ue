# NeuCodec decoder → LiteRT conversion

Tooling that converts the **NeuCodec audio decoder** (a Vocos-style
neural vocoder, ~50 Hz codes → 24 kHz audio) from its HuggingFace
PyTorch checkpoint into a `.tflite` file consumable by LiteRT.

This is **decoder only**. The matching encoder, audio file I/O, and
HF feature extractor stay on the host runtime side and are not part
of the `.tflite`.

## Layout

```
Convert/NeuCodec/
├── scripts/                    # this folder
│   ├── neucodec_decoder.py     # build_decoder(): load + swap submodules + wrap
│   ├── convert_to_tflite.py    # CLI: HF safetensors -> .tflite
│   ├── requirements.txt        # extra deps on top of inolitert-conv
│   └── README.md
├── output/                     # .tflite lands here (contents gitignored)
└── vendor/neucodec/            # NeuCodec source, as submodule (read-only)
```

## Architecture summary (so the conversion math makes sense)

The decoder is `CodecDecoderVocos` in
`vendor/neucodec/neucodec/codec_decoder_vocos.py`:

```
codes [B, 1, F] int64 (FSQ indices, 0..65535 — 4^8 levels)
   ↓ ResidualFSQ.get_output_from_indices  (torch.embedding gather)
   ↓ Linear (vq_dim=2048 -> hidden_dim=1024)
   ↓ Conv1d(k=7, padding=3)
   ↓ 2× ResNetBlock (Conv1d k=3, GroupNorm-32, swish, dropout)
   ↓ 12× RoFormer block (RMSNorm, RoPE attention via SDPA, SwiGLU MLP)
   ↓ 2× ResNetBlock
   ↓ LayerNorm
   ↓ Linear (1024 -> n_fft+2 = 1922)  -- splits into magnitude & phase
   ↓ ISTFTHead (window-summed inverse STFT)
   ↓ audio [B, 1, (F-1) * 480] float32 at 24 kHz
```

Two of the original ops don't lift cleanly to TFLite, and upstream
already provides drop-in replacements in
`vendor/neucodec/onnx/onnx_ops.py`:

| Original                          | TFLite-unfriendly because       | Replacement              |
|-----------------------------------|---------------------------------|--------------------------|
| `ISTFTHead.istft` → `torch.fft.irfft` + `complex64` mag*(cos+1j*sin) | TFLite has no FFT, no complex | `OnnxISTFTHead`: precomputed inverse-DFT basis applied via `F.conv_transpose1d` |
| `ResidualFSQ` (vector_quantize_pytorch) | `FSQ` class internals don't trace | `OnnxResidualFSQ`: pure `torch.embedding` |

`build_decoder()` in `scripts/neucodec_decoder.py` performs both swaps
after loading the HF checkpoint, then wraps the model so
`forward(codes)` calls `model.decode_code(codes)`. Same pattern as
upstream's `Wrapper` class in `vendor/neucodec/onnx/export_onnx.py`,
just targeting LiteRT instead of ONNX.

## One-time environment setup

We use the **same `inolitert-conv` conda env that already has
litert-torch installed** for the NeuTTS Nano work — see
`Convert/NeuTTS/scripts/README.md` for that base setup. Then add the
NeuCodec-specific extras:

```bash
conda activate inolitert-conv
cd /mnt/e/Projects/InoProject/Plugins/InoLiteRT/Convert/NeuCodec
pip install -r scripts/requirements.txt
```

Adds: `vector-quantize-pytorch==1.17.8`, `torchtune>=0.3.1`,
`einops`, `librosa`.

## Convert to `.tflite`

```bash
python -m scripts.convert_to_tflite --num_frames=50 --quantize=fp16
# Produces output/neucodec_decoder_f50_fp16.tflite
```

This downloads the full NeuCodec checkpoint from HF on first run
(`huggingface.co/neuphonic/neucodec`, ~1 GB to the HF cache, NOT to
this repo), swaps the ISTFT head and FSQ quantizer for the
TFLite-friendly variants, traces the decoder forward, optionally
quantizes, and writes the `.tflite`.

### Quantization (`--quantize`)

| Mode                   | File suffix    | Size (F=50) | Works? |
|------------------------|----------------|-------------|--------|
| `none` (default)        | `_f32`         | 733 MB      | ✓ |
| `fp16`                  | `_fp16`        | 367 MB      | ✓ |
| `dynamic_int8`          | `_q8`          | 187 MB      | ✓ |
| `dynamic_int4_block32`  | `_q4_block32`  | —           | ✗ (see below) |

`--output_path` defaults to `output/neucodec_decoder_f{F}_{suffix}.tflite`
so you can run multiple `--quantize` values without overwriting.

**Note on int4**: `dynamic_int4_block32` fails on NeuCodec because the
FSQ codebook tensor is shape `(65536, 8)` and inner dim 8 doesn't
divide block size 32:

```
ValueError: Quantized dimension 8 in tensor shape (65536, 8) is not
divisible by block size 32.
```

Per `litert_torch/generative/quantize/supported_schemes.py`, the only
supported int4 granularities are `BLOCKWISE_{32,64,128,256}` —
channelwise int4 is **not** in the supported recipe matrix at all.
None of {32, 64, 128, 256} divides 8, so there's no usable int4 path
for the codebook without either reshaping the FSQ output (architectural
change) or building a per-layer recipe that quantizes the codebook
separately. For mobile, **use `fp16` or `dynamic_int8`** — `_q8` at
187 MB is the practical small-footprint pick.

### Choosing `--num_frames`

The exported graph has a **fixed code-sequence length** equal to
`--num_frames`. F=50 is 1 s of audio. Common choices:

| `--num_frames` | Audio length | Use case |
|---:|---:|---|
| 50 | 1 s | quick sanity / unit tests |
| 250 | 5 s | short utterances |
| 500 | 10 s | typical TTS responses |
| 1500 | 30 s | long replies |
| 6000 | 120 s | absolute max (`OnnxISTFTHead.MAX_FRAMES`) |

For runtime flexibility you can convert multiple buckets and pick the
smallest one ≥ actual code length on the C++ side, padding the rest.
Same idea as the multi-prefill signature trick we used for NeuTTS Nano.

## Runtime contract reminders

| | |
|---|---|
| Input name | `codes` |
| Input shape | `[1, 1, F]` (with F = `--num_frames` from conversion) |
| Input dtype | `int64` (FSQ indices) |
| Input range | `[0, 65535]` (4^8 FSQ levels) |
| Output name | (single output) |
| Output shape | `[1, 1, (F - 1) * 480]` (OnnxISTFTHead trims n_fft/2 samples on each edge) |
| Output dtype | `float32` |
| Output sample rate | **24 kHz** |

C++ side is responsible for: extracting `<\|speech_N\|>` IDs from the
NeuTTS LM output, mapping to FSQ indices (`N` itself if 0..65535 —
verify via the tokenizer added_tokens 128262..193797), reshaping to
`[1, 1, F]`, casting to int64, calling the .tflite, then pumping the
float32 audio buffer to the audio output device (or resampling to
16 kHz first if the device wants that).

## Out of scope here

- The encoder (`CodecEncoder`, `feature_extractor`, `semantic_model`).
- Audio I/O (`torchaudio.save`, etc.).
- The Perth watermarker — explicitly skipped per project requirements.
- Quantization. The current `litert_torch.convert(...)` call exports
  fp32 weights; we'll add quantization once the fp32 path is proven.
