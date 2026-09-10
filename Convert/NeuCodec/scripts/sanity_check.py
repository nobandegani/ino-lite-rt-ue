# Copyright 2026 Inoland. Licensed under the Apache License, Version 2.0.
"""Sanity-check the converted NeuCodec decoder ``.tflite``.

Loads both the .tflite (via ai_edge_litert) and the equivalent PyTorch
decoder (with the same Onnx* swaps applied), runs both on the SAME
random codes, and compares the resulting 24 kHz waveforms.

Run from ``Plugins/InoLiteRT/Convert/NeuCodec/``:

    python -m scripts.sanity_check \
        --tflite_path=output/neucodec_decoder_f50.tflite \
        --num_frames=50

What to expect for a healthy fp32 conversion:
  - Max abs sample diff in the few-units-of-1e-3 range (it's the same
    ops just reordered by the converter).
  - MSE well under upstream's 0.03 acceptance bar (their test in
    vendor/neucodec/tests/test_models.py compares ONNX-decoded vs
    PyTorch-decoded with that tolerance).
  - Output shape: ``[1, 1, num_frames * 480]``.
"""

from __future__ import annotations

import os

from absl import app, flags
import numpy as np
import torch

from ai_edge_litert import interpreter as litert_interpreter

from . import neucodec_decoder

_TFLITE_PATH = flags.DEFINE_string(
    "tflite_path",
    "output/neucodec_decoder_f50.tflite",
    "Path to the .tflite file produced by scripts.convert_to_tflite.",
)
_REPO_ID = flags.DEFINE_string(
    "repo_id",
    "neuphonic/neucodec",
    "HuggingFace repo for the reference PyTorch model.",
)
_NUM_FRAMES = flags.DEFINE_integer(
    "num_frames",
    50,
    "Number of FSQ code frames in the test input. Must match the"
    " --num_frames the .tflite was converted with (the .tflite has a"
    " fixed input shape).",
)
_SEED = flags.DEFINE_integer(
    "seed",
    42,
    "Seed for the random codes — keeps runs reproducible.",
)
_SAVE_WAV = flags.DEFINE_string(
    "save_wav",
    "",
    "Optional path to write the .tflite-decoded audio as a 24 kHz wav"
    " file (uses scipy.io.wavfile if available). Empty = don't save.",
)


def _print_signature_info(interp: litert_interpreter.Interpreter) -> None:
  print("=" * 70)
  for name, sd in interp.get_signature_list().items():
    print(f"  signature `{name}`")
    print(f"    inputs:  {sd['inputs']}")
    print(f"    outputs: {sd['outputs']}")
  print("=" * 70)


def main(_):
  print(f"Loading .tflite from {_TFLITE_PATH.value} ...")
  interp = litert_interpreter.Interpreter(
      model_path=_TFLITE_PATH.value,
      experimental_default_delegate_latest_features=True,
  )
  interp.allocate_tensors()
  _print_signature_info(interp)

  # ----- Build the equivalent PyTorch reference (with Onnx* swaps) ----
  print(f"\nBuilding PyTorch reference decoder (repo={_REPO_ID.value}) ...")
  py_decoder = neucodec_decoder.build_decoder(repo_id=_REPO_ID.value)

  # ----- Generate random codes in valid range -------------------------
  rng = np.random.default_rng(_SEED.value)
  # FSQ levels=[4]*8 -> 4^8 = 65536 valid indices, range [0, 65535].
  codes_np = rng.integers(
      low=0, high=65536, size=(1, 1, _NUM_FRAMES.value), dtype=np.int64
  )
  codes_torch = torch.from_numpy(codes_np)

  print(
      f"\nTest input: shape={tuple(codes_np.shape)}, dtype={codes_np.dtype},"
      f" value range=[{codes_np.min()}, {codes_np.max()}]"
  )

  # ----- PyTorch forward ----------------------------------------------
  print("\nRunning PyTorch decoder ...")
  with torch.no_grad():
    py_audio = py_decoder(codes_torch).cpu().numpy()
  print(
      f"  -> output shape={py_audio.shape}, dtype={py_audio.dtype},"
      f" min={py_audio.min():+.4f}, max={py_audio.max():+.4f}"
  )

  # ----- TFLite forward -----------------------------------------------
  print("\nRunning .tflite decoder ...")
  # The signature is `serving_default` (litert_torch's default name when
  # no explicit signature is registered). Input name comes from
  # sample_kwargs we used at conversion: `codes`.
  sig_names = list(interp.get_signature_list().keys())
  if not sig_names:
    raise RuntimeError("No signatures in .tflite")
  sig_name = sig_names[0]
  runner = interp.get_signature_runner(sig_name)
  tflite_out = runner(codes=codes_np)
  out_keys = list(tflite_out.keys())
  print(f"  output keys from .tflite: {out_keys}")
  tflite_audio = tflite_out[out_keys[0]]
  print(
      f"  -> output shape={tflite_audio.shape}, dtype={tflite_audio.dtype},"
      f" min={tflite_audio.min():+.4f}, max={tflite_audio.max():+.4f}"
  )

  # ----- Compare ------------------------------------------------------
  if py_audio.shape != tflite_audio.shape:
    raise RuntimeError(
        f"Shape mismatch: PyTorch {py_audio.shape} vs .tflite"
        f" {tflite_audio.shape}"
    )

  diff = py_audio.astype(np.float32) - tflite_audio.astype(np.float32)
  max_abs_diff = float(np.max(np.abs(diff)))
  mean_abs_diff = float(np.mean(np.abs(diff)))
  mse = float(np.mean(diff**2))

  # OnnxISTFTHead trims n_fft/2 samples from each end (lines 107-108 of
  # vendor/neucodec/onnx/onnx_ops.py), so the actual output length is
  # (F-1) * hop_length, NOT F * hop_length. For F=50, that's 23520
  # samples = 0.98 s at 24 kHz (close to 1 s; one frame's worth gets
  # trimmed at the edges).
  expected_samples = (_NUM_FRAMES.value - 1) * 480
  print("\n" + "=" * 70)
  print("SANITY SUMMARY")
  print("=" * 70)
  print(f"Output shape:             {tflite_audio.shape} (expected"
        f" [1, 1, {expected_samples}])")
  print(f"Max abs sample diff:      {max_abs_diff:.6f}")
  print(f"Mean abs sample diff:     {mean_abs_diff:.6f}")
  print(f"MSE:                      {mse:.6e}")
  print(f"Upstream tolerance bar:   MSE < 0.03"
        f"  ({'OK' if mse < 0.03 else 'FAIL'})")

  ok_mse = mse < 0.03
  ok_shape = tflite_audio.shape == py_audio.shape
  ok_finite = np.isfinite(tflite_audio).all() and np.isfinite(py_audio).all()
  if ok_mse and ok_shape and ok_finite:
    print("\nOK: .tflite matches PyTorch within upstream's tolerance.")
  else:
    print("\nWARNING: numbers look off — investigate.")

  # ----- Optional: save the wav ---------------------------------------
  if _SAVE_WAV.value:
    try:
      from scipy.io import wavfile
    except ImportError:
      print(
          f"\nNote: --save_wav={_SAVE_WAV.value} requested but scipy is"
          " not installed; skipping. (`pip install scipy` to enable.)"
      )
    else:
      # squeeze [1, 1, T] -> [T] and convert to int16 for portability
      wav_data = tflite_audio[0, 0, :]
      wav_int16 = np.clip(wav_data, -1.0, 1.0)
      wav_int16 = (wav_int16 * 32767.0).astype(np.int16)
      os.makedirs(os.path.dirname(_SAVE_WAV.value) or ".", exist_ok=True)
      wavfile.write(_SAVE_WAV.value, 24000, wav_int16)
      print(f"\nSaved test audio to {_SAVE_WAV.value}")
      print("  (random-codes input -> noise; not real speech)")


if __name__ == "__main__":
  app.run(main)
