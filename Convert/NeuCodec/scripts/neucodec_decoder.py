# Copyright 2026 Inoland. Licensed under the Apache License, Version 2.0.
"""NeuCodec decoder authoring for litert-torch conversion.

Mirrors upstream's ONNX-export pattern from
``vendor/neucodec/onnx/export_onnx.py``: load the full ``NeuCodec``,
monkey-patch two of its submodules with TFLite-friendly variants from
``vendor/neucodec/onnx/onnx_ops.py``, and wrap so that ``forward(codes)``
calls ``model.decode_code(codes)`` — the encoder is allocated but never
on the trace.

The two swaps are essential — without them, conversion hits ops that
TFLite has no equivalent for:

  - ``ISTFTHead`` -> ``OnnxISTFTHead``
      Replaces ``torch.fft.irfft`` + complex tensors (``mag * (cos + 1j*sin)``)
      with a precomputed inverse-DFT basis applied via ``F.conv_transpose1d``.
      Hard upper bound on output length: ``MAX_FRAMES = 6000`` (per
      ``onnx_ops.py``), i.e. ~120 s of audio at 50 Hz codes.

  - ``ResidualFSQ`` -> ``OnnxResidualFSQ``
      Replaces ``vector_quantize_pytorch.FSQ``'s lookup (which uses
      operations that don't lower well) with a vanilla ``torch.embedding``
      gather. The codebook is materialized once at construction so the
      tracer captures it as a constant.

Input/output contract (matching upstream ONNX):
  - input  : ``codes`` shape ``[B, 1, F]`` dtype ``int64``,
             values in ``[0, 65535]`` (FSQ levels=[4]*8 -> 4^8 = 65536).
  - output : ``audio`` shape ``[B, 1, F * 480]`` dtype ``float32`` at 24 kHz.
"""

from __future__ import annotations

import importlib.util
import os
import sys
from typing import Tuple

import torch
from torch import nn

# ----------------------------------------------------------------------
# Make the vendored neucodec package + onnx_ops module importable.
# ----------------------------------------------------------------------
_HERE = os.path.dirname(os.path.abspath(__file__))
_VENDOR = os.path.normpath(os.path.join(_HERE, "..", "vendor", "neucodec"))
if _VENDOR not in sys.path:
  sys.path.insert(0, _VENDOR)


def _load_onnx_ops():
  """Load ``vendor/neucodec/onnx/onnx_ops.py`` directly.

  We can't ``from onnx.onnx_ops import ...`` because ``onnx`` is a
  PyPI package name (the ONNX format library) — that import path
  would resolve to the wrong module if it's installed. The neucodec
  ``onnx/`` folder also has no ``__init__.py``, so we load the file
  by absolute path via importlib.
  """
  path = os.path.join(_VENDOR, "onnx", "onnx_ops.py")
  spec = importlib.util.spec_from_file_location("neucodec_onnx_ops", path)
  if spec is None or spec.loader is None:
    raise RuntimeError(f"Failed to create import spec for {path}")
  mod = importlib.util.module_from_spec(spec)
  spec.loader.exec_module(mod)
  return mod


# Imported lazily (inside build_decoder) so static-analysis tools don't
# choke on the vendored path before sys.path is patched.
def _import_neucodec():
  from neucodec import NeuCodec  # noqa: WPS433 (intentional late import)

  return NeuCodec


# ----------------------------------------------------------------------
# The thin wrapper.
# ----------------------------------------------------------------------
class NeuCodecDecoderWrapper(nn.Module):
  """``forward(codes)`` -> ``audio`` (calls ``model.decode_code(codes)``).

  ``decode_code`` is pure tensor ops on the decoder side — no audio
  resampling, no Python-only steps — so the entire body of this method
  belongs inside the .tflite. Encoder modules of the wrapped NeuCodec
  remain in memory (they were instantiated by ``NeuCodec.__init__``)
  but are not on the trace because nothing calls them.
  """

  def __init__(self, neucodec_model: nn.Module):
    super().__init__()
    self.model = neucodec_model

  def forward(self, codes: torch.Tensor) -> torch.Tensor:
    return self.model.decode_code(codes)


def build_decoder(
    repo_id: str = "neuphonic/neucodec",
    hop_length: int = 480,
    hidden_dim: int = 1024,
    vq_dim: int = 2048,
) -> nn.Module:
  """Build the NeuCodec decoder ready for ``litert_torch.convert``.

  Args:
    repo_id: HuggingFace repo for the full NeuCodec checkpoint
      (e.g. ``"neuphonic/neucodec"``). Loaded via
      ``NeuCodec.from_pretrained`` which downloads ``pytorch_model.bin``
      to the HF cache on first run.
    hop_length: 480 for the 24 kHz / 50 Hz NeuCodec checkpoint.
      ``n_fft`` is automatically ``hop_length * 4 = 1920``.
    hidden_dim: 1024 for the standard checkpoint.
    vq_dim: 2048 — input dim of the FSQ projection.

  Returns:
    A ``NeuCodecDecoderWrapper`` in ``eval()`` mode with the two
    TFLite-friendly swaps applied. Pass directly to
    ``litert_torch.convert``.
  """
  NeuCodec = _import_neucodec()
  onnx_ops = _load_onnx_ops()

  print(f"Loading NeuCodec from {repo_id} ...")
  full = NeuCodec.from_pretrained(repo_id)
  full.eval()

  # ----- swap ISTFT head -----
  print("Swapping ISTFTHead -> OnnxISTFTHead (no torch.fft, no complex tensors) ...")
  onnx_head = onnx_ops.OnnxISTFTHead(
      dim=hidden_dim,
      n_fft=hop_length * 4,
      hop_length=hop_length,
  )
  # The original head's only learnable parameter is the `out` Linear;
  # the rest of the math (window, inverse_basis) is recomputed inside
  # OnnxISTFTHead from the same n_fft / hop_length and hard-baked as
  # buffers. So we only need to copy `out.weight` + `out.bias`.
  onnx_head.out.load_state_dict(full.generator.head.out.state_dict())
  full.generator.head = onnx_head

  # ----- swap ResidualFSQ -----
  print("Swapping ResidualFSQ -> OnnxResidualFSQ (torch.embedding gather) ...")
  onnx_fsq = onnx_ops.OnnxResidualFSQ(
      dim=vq_dim,
      levels=[4, 4, 4, 4, 4, 4, 4, 4],
      num_quantizers=1,
  )
  onnx_fsq.load_state_dict(full.generator.quantizer.state_dict())
  full.generator.quantizer = onnx_fsq

  return NeuCodecDecoderWrapper(full).eval()


def get_sample_codes(
    num_frames: int = 50,
    batch_size: int = 1,
    dtype: torch.dtype = torch.long,
) -> torch.Tensor:
  """Build a ``[B, 1, F]`` int64 sample tensor for tracing.

  ``num_frames=50`` is 1 second at 50 Hz codes. Values are zero — fine
  for tracing since values don't affect graph topology, only shapes do.
  Adjust ``num_frames`` to the bucket size you want exported.
  """
  return torch.zeros((batch_size, 1, num_frames), dtype=dtype)
