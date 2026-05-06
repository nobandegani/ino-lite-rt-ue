"""NeuTTS Nano backbone — model authoring for litert-torch.

Re-authors NeuTTS Nano's backbone (a 24-layer Llama-3-family causal LM with
hidden_size=576, GQA 9/3, head_dim=64, intermediate_size=2304, vocab_size=194256,
RoPE base=500000 with linear scaling factor=32, tied word embeddings) using the
litert-torch generative API so it can be converted to a multi-signature .tflite.

Architecture is taken verbatim from
``Plugins/InoLiteRT/Convert/NeuTTS/models/nano/config.json``.

Mirrors the structure of ``litert_torch/generative/examples/smollm/smollm.py``
(closest fork base — same hidden_size=576, num_heads=9, num_query_groups=3,
head_dim=64, tied embeddings) with:
  - num_layers raised 30 -> 24
  - vocab_size raised 49152 -> 194256
  - intermediate_size raised 1536 -> 2304
  - rotary_base raised 10000 -> 500000
  - a custom linear-scale RoPE callable (HF ``rope_scaling.type='linear'``,
    ``factor=32.0``) — the default RoPE in litert-torch has no scaling, and
    Llama 3.2's smooth NTK scaling in ``examples/llama/llama.py`` is the wrong
    math for ``type='linear'``.
"""

from functools import partial
from typing import Callable, Dict, Tuple

import torch
from torch import nn

import litert_torch.generative.layers.model_config as cfg
from litert_torch.generative.utilities import model_builder

# Tied lm_head -> embed_tokens. The HF checkpoint has ``tie_word_embeddings: true``
# and ships only ``model.embed_tokens.weight``; ``ModelLoader`` handles the missing
# ``lm_head.weight`` via ``strict=not config.lm_head_share_weight_with_embedding``
# inside ``build_decoder_only_model``.
TENSOR_NAMES = model_builder.TENSOR_NAMES


def _build_linear_scaled_rope_cache(
    input_pos: torch.Tensor,
    n_elem: int,
    base: int,
    *,
    scaling_factor: float,
    dtype: torch.dtype,
    device: torch.device,
) -> Tuple[torch.Tensor, torch.Tensor]:
  """RoPE with HF's ``rope_scaling.type='linear'``.

  Linear scaling means: divide every position index by the scaling factor before
  computing ``outer(seq_idx, theta)``. Equivalent to making the model think it's
  operating on a sequence ``factor`` times shorter than it actually is.

  Signature matches the contract enforced by ``DecoderOnlyModel.forward``:
  ``rope = self.config.build_rope(input_pos, n_elem, attn_config.rotary_base)``
  — i.e. positional, three-arg. ``scaling_factor``/``dtype``/``device`` are
  bound via ``functools.partial`` in :func:`get_model_config`.
  """
  theta = 1.0 / (base ** (torch.arange(0, n_elem, 2).float() / n_elem))
  seq_idx = input_pos.float() / float(scaling_factor)
  idx_theta = torch.outer(seq_idx, theta)
  cos = torch.cos(idx_theta).to(dtype=dtype, device=device)
  sin = torch.sin(idx_theta).to(dtype=dtype, device=device)
  return cos, sin


class NeuTTSNano(model_builder.DecoderOnlyModel):
  """NeuTTS Nano backbone built from the Edge Generative API layers."""
  pass


def get_model_config() -> cfg.ModelConfig:
  """Returns the model config matching ``models/nano/config.json``."""
  attn_config = cfg.AttentionConfig(
      num_heads=9,
      head_dim=64,
      num_query_groups=3,  # HF ``num_key_value_heads`` (GQA 3:1)
      rotary_base=500000,
      rotary_percentage=1.0,
  )
  ff_config = cfg.FeedForwardConfig(
      type=cfg.FeedForwardType.GATED,  # SwiGLU: down(silu(gate(x)) * up(x))
      activation=cfg.ActivationConfig(cfg.ActivationType.SILU),
      intermediate_size=2304,
  )
  norm_config = cfg.NormalizationConfig(
      type=cfg.NormalizationType.RMS_NORM,
      epsilon=1e-5,  # HF ``rms_norm_eps``
  )
  block_config = cfg.TransformerBlockConfig(
      attn_config=attn_config,
      ff_config=ff_config,
      pre_attention_norm_config=norm_config,
      post_attention_norm_config=norm_config,
  )
  build_rope = partial(
      _build_linear_scaled_rope_cache,
      scaling_factor=32.0,
      dtype=torch.float32,
      device=torch.device("cpu"),
  )
  return cfg.ModelConfig(
      vocab_size=194256,
      num_layers=24,
      max_seq_len=2048,  # HF ``max_position_embeddings``
      embedding_dim=576,
      block_configs=block_config,
      final_norm_config=norm_config,
      build_rope=build_rope,
      # ``lm_head_share_weight_with_embedding`` defaults to True — matches
      # HF ``tie_word_embeddings: true``.
  )


def get_fake_model_config() -> cfg.ModelConfig:
  """Tiny config for unit / converter smoke tests."""
  config = get_model_config()
  config.vocab_size = 128
  config.num_layers = 2
  config.block_config(0).ff_config.intermediate_size = 64
  return config


def build_model(
    checkpoint_path: str,
    custom_loader: Callable[[str], Dict[str, torch.Tensor]] = None,
    mask_cache_size: int = 0,
) -> nn.Module:
  """Build NeuTTS Nano and load weights from ``checkpoint_path``.

  ``checkpoint_path`` must point to either a directory containing one or more
  ``*.safetensors`` shards (the HF layout) or a single ``.safetensors`` /
  ``.bin`` / ``.pt`` file. ``ModelLoader`` auto-detects.
  """
  return model_builder.build_decoder_only_model(
      checkpoint_path=checkpoint_path,
      config=get_model_config(),
      tensor_names=TENSOR_NAMES,
      model_class=NeuTTSNano,
      custom_loader=custom_loader,
      mask_cache_size=mask_cache_size,
  )
