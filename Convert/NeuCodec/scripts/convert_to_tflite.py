"""Convert the NeuCodec decoder to ``.tflite`` via litert-torch.

Mirrors ``vendor/neucodec/onnx/export_onnx.py`` but uses
``litert_torch.convert(...)`` (the base PyTorch->LiteRT API, NOT the
generative API used for NeuTTS Nano — the codec is a pure conv/attention
network with no KV cache, no autoregressive structure).

Run from ``Plugins/InoLiteRT/Convert/NeuCodec/``:

    python -m scripts.convert_to_tflite \
        --output_path=output/neucodec_decoder.tflite \
        --num_frames=50

Output contract:
  - input  ``codes``  : int64 ``[1, 1, num_frames]``
  - output ``audio``  : float32 ``[1, 1, num_frames * 480]`` at 24 kHz

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

from . import neucodec_decoder

_OUTPUT_PATH = flags.DEFINE_string(
    "output_path",
    "output/neucodec_decoder.tflite",
    "Where to write the converted .tflite file.",
)
_REPO_ID = flags.DEFINE_string(
    "repo_id",
    "neuphonic/neucodec",
    "HuggingFace repo with the full NeuCodec checkpoint to load.",
)
_NUM_FRAMES = flags.DEFINE_integer(
    "num_frames",
    50,
    "Code-sequence length F to bake into the exported .tflite. Output"
    " audio length is num_frames * 480 samples (24 kHz). Max is 6000"
    " (OnnxISTFTHead.MAX_FRAMES).",
)
_BATCH_SIZE = flags.DEFINE_integer(
    "batch_size",
    1,
    "Batch dimension for the exported .tflite (usually 1).",
)


def main(_):
  if _NUM_FRAMES.value > 6000:
    raise ValueError(
        f"--num_frames={_NUM_FRAMES.value} exceeds OnnxISTFTHead.MAX_FRAMES"
        " = 6000 — see vendor/neucodec/onnx/onnx_ops.py."
    )

  out_path = _OUTPUT_PATH.value
  os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)

  print(f"Building decoder (repo={_REPO_ID.value}) ...")
  decoder = neucodec_decoder.build_decoder(repo_id=_REPO_ID.value)

  sample_codes = neucodec_decoder.get_sample_codes(
      num_frames=_NUM_FRAMES.value,
      batch_size=_BATCH_SIZE.value,
  )
  print(
      f"Sample input: shape={tuple(sample_codes.shape)},"
      f" dtype={sample_codes.dtype}"
  )

  # Quick PyTorch sanity check before the long conversion — ensures the
  # swaps + weight loads + wrapper are all consistent.
  print("PyTorch sanity forward (decoder.eval()) ...")
  with torch.no_grad():
    py_out = decoder(sample_codes)
  print(
      f"  -> output shape={tuple(py_out.shape)},"
      f" dtype={py_out.dtype} (expected {(_BATCH_SIZE.value, 1, _NUM_FRAMES.value * 480)})"
  )

  print("\nConverting to .tflite via litert_torch.convert(...) ...")
  edge_model = litert_torch.convert(
      decoder,
      sample_kwargs={"codes": sample_codes},
  )

  print(f"Writing {out_path} ...")
  edge_model.export(out_path)

  size_mb = os.path.getsize(out_path) / (1024 * 1024)
  print(f"Done. Wrote {out_path} ({size_mb:.1f} MB).")


if __name__ == "__main__":
  app.run(main)
