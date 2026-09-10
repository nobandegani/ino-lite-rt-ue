# Copyright 2026 Inoland. Licensed under the Apache License, Version 2.0.
"""Convert the NeuCodec decoder to ``.tflite`` via litert-torch.

Mirrors ``vendor/neucodec/onnx/export_onnx.py`` but uses
``litert_torch.convert(...)`` (the base PyTorch->LiteRT API, NOT the
generative API used for NeuTTS Nano — the codec is a pure conv/attention
network with no KV cache, no autoregressive structure).

Run from ``Plugins/InoLiteRT/Convert/NeuCodec/``:

    python -m scripts.convert_to_tflite --num_frames=50 --quantize=fp16
    # -> output/neucodec_decoder_f50_fp16.tflite

Available --quantize modes (matches the NeuTTS Nano converter naming):
  none, fp16, dynamic_int8, dynamic_int4_block32

Output contract:
  - input  ``codes``  : int64 ``[1, 1, num_frames]``
  - output ``audio``  : float32 ``[1, 1, (num_frames - 1) * 480]`` at 24 kHz
    (OnnxISTFTHead trims n_fft/2 = 960 samples from each edge)

The exported .tflite has a fixed code-sequence length equal to
``--num_frames``. To support multiple lengths, run conversion multiple
times with different ``--num_frames`` and pick the right .tflite at
runtime, or implement multi-signature export later.

OnnxISTFTHead's ``MAX_FRAMES = 6000`` (~120 s at 50 Hz codes) is the
hard upper bound on ``--num_frames``.
"""

from __future__ import annotations

import os

from absl import app, flags
import torch

import litert_torch
from litert_torch._convert.interface import Converter
from litert_torch.generative.quantize import quant_attrs, quant_recipes

from . import neucodec_decoder

_OUTPUT_PATH = flags.DEFINE_string(
    "output_path",
    "",
    "Where to write the converted .tflite. Empty = auto-name based on"
    " --num_frames and --quantize, e.g."
    " output/neucodec_decoder_f50_fp16.tflite.",
)
_REPO_ID = flags.DEFINE_string(
    "repo_id",
    "neuphonic/neucodec",
    "HuggingFace repo with the full NeuCodec checkpoint to load.",
)
_NUM_FRAMES = flags.DEFINE_multi_integer(
    "num_frames",
    [100, 200, 400, 600, 1000],
    "Code-sequence length F to bake into the .tflite as a signature."
    " Pass this flag multiple times to produce a multi-signature .tflite"
    " (e.g. --num_frames=100 --num_frames=200). Each signature is named"
    " f<N>. Output audio length is (N - 1) * 480 samples (24 kHz, with"
    " n_fft/2 trim each edge). Max is 6000 (OnnxISTFTHead.MAX_FRAMES).",
)
_BATCH_SIZE = flags.DEFINE_integer(
    "batch_size",
    1,
    "Batch dimension for the exported .tflite (usually 1).",
)
_QUANTIZE = flags.DEFINE_enum(
    "quantize",
    "none",
    ["none", "fp16", "dynamic_int8", "dynamic_int4_block32"],
    "Quantization mode. The recipes come from"
    " litert_torch.generative.quantize.quant_recipes — they're written"
    " for the generative API but work on any litert_torch.convert"
    " model when called with mcfg=None (recipe.verify() does not"
    " require a ModelConfig). Modes:\n"
    "  none                  - fp32 weights\n"
    "  fp16                  - fp16 weights\n"
    "  dynamic_int8          - int8 weights, dynamic activation"
    " (channelwise — fine for NeuCodec)\n"
    "  dynamic_int4_block32  - int4 weights, blockwise-32\n"
    "\n"
    "WARNING: dynamic_int4_block32 currently FAILS on NeuCodec because"
    " the FSQ codebook tensor is shape (65536, 8) and the inner dim 8"
    " is not divisible by 32. Per"
    " litert_torch/generative/quantize/supported_schemes.py the only"
    " supported int4 granularities are BLOCKWISE_{32,64,128,256} —"
    " channelwise int4 is not in the matrix. There is no working int4"
    " path for NeuCodec without either reshaping the codebook"
    " (architectural change) or using a per-layer recipe that excludes"
    " the codebook from int4 (not yet implemented here). Use fp16 or"
    " dynamic_int8 instead for mobile builds.",
)

# Output filename suffix per quantize mode (matches litert-torch's
# generative converter naming for NeuTTS Nano).
_QUANT_SUFFIX = {
    "none": "f32",
    "fp16": "fp16",
    "dynamic_int8": "q8",
    "dynamic_int4_block32": "q4_block32",
}


def _make_quant_config(quantize: str):
  """Build a QuantConfig from a --quantize flag value, or None for fp32."""
  if quantize == "none":
    return None
  if quantize == "fp16":
    return quant_recipes.full_fp16_recipe()
  if quantize == "dynamic_int8":
    return quant_recipes.full_dynamic_recipe()
  if quantize == "dynamic_int4_block32":
    return quant_recipes.full_dynamic_recipe(
        weight_dtype=quant_attrs.Dtype.INT4,
        granularity=quant_attrs.Granularity.BLOCKWISE_32,
    )
  raise ValueError(f"Unknown --quantize mode: {quantize!r}")


def main(_):
  frames_list = sorted(set(_NUM_FRAMES.value))
  for f in frames_list:
    if f > 6000:
      raise ValueError(
          f"--num_frames={f} exceeds OnnxISTFTHead.MAX_FRAMES = 6000"
          " — see vendor/neucodec/onnx/onnx_ops.py."
      )

  # Resolve output path. Empty default -> auto-name from quantize only
  # (no F in the name since the file has multiple F buckets baked in).
  out_path = _OUTPUT_PATH.value
  if not out_path:
    suffix = _QUANT_SUFFIX[_QUANTIZE.value]
    out_path = f"output/neucodec_decoder_{suffix}.tflite"
  os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)

  print(f"Building decoder (repo={_REPO_ID.value}) ...")
  decoder = neucodec_decoder.build_decoder(repo_id=_REPO_ID.value)

  print(f"Will export {len(frames_list)} signature(s): "
        f"{[f'f{f}' for f in frames_list]}")

  # Quick PyTorch sanity check on the smallest bucket before the long
  # conversion — ensures the swaps + weight loads + wrapper are all
  # consistent.
  smallest = frames_list[0]
  sample_codes_smallest = neucodec_decoder.get_sample_codes(
      num_frames=smallest, batch_size=_BATCH_SIZE.value,
  )
  print(f"\nPyTorch sanity forward at F={smallest} ...")
  with torch.no_grad():
    py_out = decoder(sample_codes_smallest)
  expected = (smallest - 1) * 480
  print(f"  -> output shape={tuple(py_out.shape)}, dtype={py_out.dtype}"
        f" (expected [{_BATCH_SIZE.value}, 1, {expected}])")

  # Build the converter and register one signature per F. Weights are
  # shared across signatures in the resulting .tflite — only the graph
  # topology (input shape) differs per signature.
  converter_obj = Converter()
  for f in frames_list:
    sample = neucodec_decoder.get_sample_codes(
        num_frames=f, batch_size=_BATCH_SIZE.value,
    )
    sig_name = f"f{f}"
    print(f"  registering signature `{sig_name}` (codes shape={tuple(sample.shape)})")
    converter_obj.add_signature(
        sig_name, decoder, sample_kwargs={"codes": sample},
    )

  quant_config = _make_quant_config(_QUANTIZE.value)
  print(f"\nConverting (quantize={_QUANTIZE.value!r}) ...")
  edge_model = converter_obj.convert(quant_config=quant_config)

  print(f"Writing {out_path} ...")
  edge_model.export(out_path)

  size_mb = os.path.getsize(out_path) / (1024 * 1024)
  print(f"Done. Wrote {out_path} ({size_mb:.1f} MB,"
        f" signatures: {[f'f{f}' for f in frames_list]}).")


if __name__ == "__main__":
  app.run(main)
