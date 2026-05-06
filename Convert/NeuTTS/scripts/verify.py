"""Verify the re-authored NeuTTS Nano matches the HF model logits.

Run BEFORE conversion. If verification fails, the re-authored architecture is
wrong (most likely the linear-scale RoPE math) — converting in that state
produces a ``.tflite`` that runs but generates garbage.

    python -m scripts.verify --checkpoint_dir=models/nano

Compares logits + greedy generations between
  (a) the original ``transformers.AutoModelForCausalLM`` loaded from the HF
      checkpoint, and
  (b) the litert-torch re-authored model in :mod:`scripts.neutts_nano`,
under ``atol=1e-04`` (per the verifier's default and what
``examples/llama/verify_util.py`` uses).
"""

from absl import app, flags
import transformers

from litert_torch.generative.utilities import (
    transformers_verifier,
    verifier,
)

from . import neutts_nano

_CHECKPOINT_DIR = flags.DEFINE_string(
    "checkpoint_dir",
    None,
    "Directory containing config.json + model.safetensors + tokenizer.json.",
    required=True,
)
_PROMPTS = flags.DEFINE_multi_string(
    "prompts",
    "user: Convert the text to speech:",
    "Test prompts for parity comparison. Default mirrors the start of the "
    "NeuTTS chat template.",
)
_MAX_NEW_TOKENS = flags.DEFINE_integer(
    "max_new_tokens",
    30,
    "Number of greedy tokens to generate from each prompt.",
)
_ATOL = flags.DEFINE_float(
    "atol",
    1e-4,
    "Absolute tolerance for the logits-equality check.",
)


def main(_):
  checkpoint_dir = _CHECKPOINT_DIR.value

  print(f"Loading HF model from {checkpoint_dir} ...")
  original_model = transformers.AutoModelForCausalLM.from_pretrained(
      checkpoint_dir
  )
  tokenizer = transformers.AutoTokenizer.from_pretrained(checkpoint_dir)

  print("Building re-authored NeuTTS Nano ...")
  reauthored_model = neutts_nano.build_model(
      checkpoint_path=checkpoint_dir,
      mask_cache_size=verifier.DEFAULT_KV_CACHE_MAX_LEN,
  )

  print("Verifying logits + greedy generations ...")
  verifier.verify_reauthored_model(
      original_model=transformers_verifier.TransformersModelWrapper(
          original_model
      ),
      reauthored_model=verifier.ReauthoredModelWrapper(reauthored_model),
      tokenizer=verifier.TokenizerWrapper(tokenizer),
      generate_prompts=_PROMPTS.value,
      max_new_tokens=_MAX_NEW_TOKENS.value,
      atol=_ATOL.value,
  )


if __name__ == "__main__":
  app.run(main)
