"""Bundle the NeuTTS Nano backbone, tokenizer, and chat template into ``.litertlm``.

For each existing ``.tflite`` variant in ``output/``, produces a matching
``.litertlm`` containing:

  - the ``.tflite`` model            (TFLiteModel section, PREFILL_DECODE)
  - ``models/nano/tokenizer.json``   (HF_Tokenizer_Zlib section)
  - LlmMetadata proto with:           (LlmMetadataProto section)
      * start_token  = 128000 (<|begin_of_text|>)
      * stop_tokens  = [128261]  (<|SPEECH_GENERATION_END|>)
      * prompt_templates.user.prefix = "user: Convert the text to speech:<|TEXT_PROMPT_START|>"
      * prompt_templates.user.suffix = "<|TEXT_PROMPT_END|>\\nassistant:<|SPEECH_GENERATION_START|>"
      * sampler_params: TOP_K = 50, temperature = 1.0
      * max_num_tokens = 2048
      * llm_model_type = generic_model("neutts_nano")
  - system metadata (author, model name, source)

Voice cloning note: NeuTTS prepends reference voice codes after
``<|SPEECH_GENERATION_START|>`` before generation begins. Those codes
are voice-specific (different for each reference WAV) and CANNOT be
baked into the prompt template. The C++ runtime is responsible for
appending them per-call. The template here covers the invariant text
structure only.

Run from ``Plugins/InoLiteRT/Convert/NeuTTS/`` (with the inolitert-conv
conda env active in WSL):

    python -m scripts.build_litertlm

Outputs land next to the source ``.tflite`` in ``output/``:
    output/neutts_nano_f32_ekv2048.litertlm
    output/neutts_nano_fp16_ekv2048.litertlm
    output/neutts_nano_q8_ekv2048.litertlm
    output/neutts_nano_q4_block32_ekv2048.litertlm
"""

from __future__ import annotations

import glob
import os
import sys
from pathlib import Path
from typing import Iterable

# litert-lm-builder installs the protos as submodules of itself (the
# bundling step rewrites imports during PyPI packaging).
from litert_lm_builder.runtime.proto import (
    llm_metadata_pb2,
    sampler_params_pb2,
)
from litert_lm_builder.litertlm_builder import (
    LitertLmFileBuilder,
    TfLiteModelType,
    Metadata,
    DType,
)


_HERE = Path(__file__).resolve().parent
_NEUTTS_ROOT = _HERE.parent  # Convert/NeuTTS/
_OUTPUT_DIR = _NEUTTS_ROOT / "output"
_TOKENIZER_PATH = _NEUTTS_ROOT / "models" / "nano" / "tokenizer.json"


# --- Token IDs from models/nano/tokenizer.json -----------------------
# Confirmed in models/nano/config.json and tokenizer.json's added_tokens.
_BEGIN_OF_TEXT = 128000             # <|begin_of_text|>
_SPEECH_GENERATION_END = 128261     # <|SPEECH_GENERATION_END|> (NeuTTS EOS)

# --- Chat template ---------------------------------------------------
# Mirrors `_infer_ggml` in vendor/neutts/neutts/neutts.py:370-373:
#     prompt = (
#         f"user: Convert the text to speech:<|TEXT_PROMPT_START|>"
#         f"{ref_text} {input_text}"
#         f"<|TEXT_PROMPT_END|>\nassistant:<|SPEECH_GENERATION_START|>"
#         f"{codes_str}"
#     )
# We bake the invariant text into the user prefix/suffix. The voice's
# reference codes (codes_str) are appended at runtime by the C++ host.
_USER_PREFIX = "user: Convert the text to speech:<|TEXT_PROMPT_START|>"
_USER_SUFFIX = "<|TEXT_PROMPT_END|>\nassistant:<|SPEECH_GENERATION_START|>"


def _build_llm_metadata_pb(out_path: Path) -> Path:
  """Build the LlmMetadata proto and serialize to a binary .pb file."""
  meta = llm_metadata_pb2.LlmMetadata()

  # Start / stop tokens.
  meta.start_token.token_ids.ids.append(_BEGIN_OF_TEXT)
  meta.stop_tokens.add().token_ids.ids.append(_SPEECH_GENERATION_END)

  # Prompt template (user role).
  meta.prompt_templates.user.prefix = _USER_PREFIX
  meta.prompt_templates.user.suffix = _USER_SUFFIX

  # Sampler defaults — match `_infer_ggml` in neutts.py:374-380.
  meta.sampler_params.type = sampler_params_pb2.SamplerParameters.TOP_K
  meta.sampler_params.k = 50
  meta.sampler_params.temperature = 1.0

  # Total prompt + generation length cap (NeuTTS's `max_context`).
  meta.max_num_tokens = 2048

  # Mark this as a generic / unknown architecture from LiteRT-LM's POV.
  # NeuTTS Nano is a custom Llama-3-family LM that LiteRT-LM doesn't have
  # a dedicated model_type for, so generic_model is the right choice.
  meta.llm_model_type.generic_model.model_role = "neutts_nano"

  out_path.parent.mkdir(parents=True, exist_ok=True)
  out_path.write_bytes(meta.SerializeToString())
  print(f"  wrote {out_path.name} ({len(meta.SerializeToString())} B)")
  return out_path


def _iter_tflite_variants() -> Iterable[Path]:
  """Yield every neutts_nano_*.tflite under output/."""
  pattern = str(_OUTPUT_DIR / "neutts_nano_*.tflite")
  for p in sorted(glob.glob(pattern)):
    yield Path(p)


def _build_one_bundle(
    tflite_path: Path,
    llm_metadata_pb: Path,
    output_path: Path,
) -> None:
  """Build a single .litertlm containing the backbone + tokenizer + metadata."""
  print(f"\nBundling {output_path.name} ...")
  builder = LitertLmFileBuilder()

  # System metadata — descriptive, doesn't affect runtime.
  builder.add_system_metadata(Metadata(
      key="author", value="Neuphonic", dtype=DType.STRING,
  ))
  builder.add_system_metadata(Metadata(
      key="model_name", value="NeuTTS Nano", dtype=DType.STRING,
  ))
  builder.add_system_metadata(Metadata(
      key="model_source", value="huggingface.co/neuphonic/neutts-nano",
      dtype=DType.STRING,
  ))
  builder.add_system_metadata(Metadata(
      key="bundle_source", value=tflite_path.name, dtype=DType.STRING,
  ))

  # LlmMetadata (start/stop tokens, chat template, sampler, max tokens).
  builder.add_llm_metadata(str(llm_metadata_pb))

  # The .tflite itself — tagged PREFILL_DECODE so LiteRT-LM picks it up
  # as the main inference model.
  builder.add_tflite_model(
      str(tflite_path),
      TfLiteModelType.PREFILL_DECODE,
  )

  # HF tokenizer.json — the bundler zlib-compresses it into the bundle.
  builder.add_hf_tokenizer(str(_TOKENIZER_PATH))

  output_path.parent.mkdir(parents=True, exist_ok=True)
  with output_path.open("wb") as f:
    builder.build(f)

  size_mb = output_path.stat().st_size / (1024 * 1024)
  print(f"  -> {output_path.name} ({size_mb:.1f} MB)")


def main() -> int:
  if not _TOKENIZER_PATH.exists():
    print(f"ERROR: tokenizer not found at {_TOKENIZER_PATH}", file=sys.stderr)
    return 1

  print("Building LlmMetadata proto ...")
  llm_metadata_pb = _build_llm_metadata_pb(
      _OUTPUT_DIR / "neutts_nano_metadata.pb"
  )

  variants = list(_iter_tflite_variants())
  if not variants:
    print(
        f"ERROR: no neutts_nano_*.tflite found under {_OUTPUT_DIR}",
        file=sys.stderr,
    )
    return 1

  print(f"Found {len(variants)} .tflite variant(s) to bundle:")
  for p in variants:
    print(f"  - {p.name}")

  for tflite in variants:
    bundle_path = tflite.with_suffix(".litertlm")
    _build_one_bundle(tflite, llm_metadata_pb, bundle_path)

  print("\nDone.")
  return 0


if __name__ == "__main__":
  sys.exit(main())
