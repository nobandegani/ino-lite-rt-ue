# Copyright 2026 Inoland. Licensed under the Apache License, Version 2.0.
"""Convert the NeuTTS Nano backbone to a multi-signature ``.tflite`` model.

Run from ``Plugins/InoLiteRT/Convert/NeuTTS/`` so the package import works:

    python -m scripts.convert_to_tflite \
        --checkpoint_path=models/nano \
        --output_path=output \
        --output_name_prefix=neutts_nano \
        --kv_cache_max_len=2048 \
        --prefill_seq_lens=128,512,1024 \
        --quantize=dynamic_int8

Output filename: ``{output_name_prefix}_{quant_suffix}_ekv{kv_cache_max_len}.tflite``
e.g. ``neutts_nano_q8_ekv2048.tflite``.

Available ``--quantize`` modes (from
``litert_torch.generative.utilities.converter.QuantizationName``):
  - ``none`` (fp32, biggest)
  - ``dynamic_int8``  (default, balanced)
  - ``weight_only_int8``
  - ``fp16``
  - ``dynamic_int4_block32``  (smallest, slowest activation; better quality
                               than block128)
  - ``dynamic_int4_block128`` (smallest, fastest)

All other flags from ``define_conversion_flags`` apply (``--prefill_seq_lens``,
``--kv_cache_max_len``, ``--mask_as_input``, ``--transpose_kv_cache``, etc.).
"""

from absl import app

from litert_torch.generative.utilities import converter

from . import neutts_nano

# Registers ``--checkpoint_path``, ``--output_path``, ``--output_name_prefix``,
# ``--prefill_seq_lens``, ``--decode_batch_size``, ``--kv_cache_max_len``,
# ``--quantize``, ``--lora_ranks``, ``--mask_as_input``, ``--transpose_kv_cache``,
# ``--custom_checkpoint_loader``, ``--gpu_dynamic_shapes``,
# ``--export_gpu_dynamic_shape_verifications``.
flags = converter.define_conversion_flags("neutts_nano")


def main(_):
  converter.build_and_convert_to_tflite_from_flags(neutts_nano.build_model)


if __name__ == "__main__":
  app.run(main)
