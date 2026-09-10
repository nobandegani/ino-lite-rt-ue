# Copyright 2026 Inoland. Licensed under the Apache License, Version 2.0.
"""Sanity-check the converted ``neutts_nano.tflite``.

Loads the .tflite via ai_edge_litert, inspects its signatures, runs one
prefill + several decode steps, and compares the .tflite's last-token logits
against the original HF model on the same prompt. Quantifies how much
``dynamic_int8`` quantization drifted things.

Run from ``Plugins/InoLiteRT/Convert/NeuTTS/``:

    python -m scripts.sanity_check \
        --tflite_path=output/neutts_nano_q8_ekv2048.tflite \
        --checkpoint_dir=models/nano

What to expect for a healthy int8 conversion of a 229M-param model:
  - Top-1 token from .tflite usually matches HF's top-1 (>=80% of positions).
  - Top-10 overlap typically >= 8/10.
  - Max abs logit diff in the few-units range (1e0-1e1) — not the 1e-4 we
    saw in fp32 parity, that's expected with int8 weights.
  - Greedy generations look like coherent token sequences (not random IDs,
    not all the same token).
"""

from absl import app, flags
import numpy as np
import torch
import transformers
from ai_edge_litert import interpreter as litert_interpreter

_TFLITE_PATH = flags.DEFINE_string(
    "tflite_path", None, "Path to the .tflite file.", required=True
)
_CHECKPOINT_DIR = flags.DEFINE_string(
    "checkpoint_dir",
    None,
    "Directory with the HF checkpoint (config.json + safetensors + tokenizer).",
    required=True,
)
_PROMPT = flags.DEFINE_string(
    "prompt",
    "user: Convert the text to speech:",
    "Prompt to feed both models. Keep short (<128 tokens) so it fits prefill_128.",
)
_DECODE_STEPS = flags.DEFINE_integer(
    "decode_steps",
    16,
    "How many greedy decode steps to run after the prefill.",
)


def _print_signature_info(interp: litert_interpreter.Interpreter) -> None:
  """Print a concise summary of every signature."""
  print("=" * 70)
  sigs = interp.get_signature_list()
  print(f".tflite signatures: {list(sigs.keys())}")
  for name, sd in sigs.items():
    print(
        f"  {name}: {len(sd['inputs'])} inputs, {len(sd['outputs'])} outputs"
        f"  (logits in outputs: {'logits' in sd['outputs']})"
    )
  print("=" * 70)


def _zero_kv_cache(
    runner: litert_interpreter.SignatureRunner,
) -> dict[str, np.ndarray]:
  """Build a zero-filled KV cache dict matching the signature's k_*/v_* inputs."""
  kv: dict[str, np.ndarray] = {}
  details = runner.get_input_details()
  for name, det in details.items():
    if name.startswith("kv_cache_k_") or name.startswith("kv_cache_v_"):
      kv[name] = np.zeros(det["shape"], dtype=det["dtype"])
  return kv


def _greedy_argmax(logits_row: np.ndarray) -> int:
  return int(np.argmax(logits_row))


def main(_):
  print(f"Loading .tflite from {_TFLITE_PATH.value} ...")
  interp = litert_interpreter.Interpreter(
      model_path=_TFLITE_PATH.value,
      experimental_default_delegate_latest_features=True,
  )
  interp.allocate_tensors()
  _print_signature_info(interp)

  print(f"\nLoading HF tokenizer from {_CHECKPOINT_DIR.value} ...")
  tokenizer = transformers.AutoTokenizer.from_pretrained(_CHECKPOINT_DIR.value)

  # Tokenize the prompt. add_special_tokens=True so we get <|begin_of_text|>
  # prepended (matches what the model was trained with).
  prompt_ids = tokenizer.encode(_PROMPT.value, add_special_tokens=True)
  print(f"\nPrompt: {_PROMPT.value!r}")
  print(f"Token IDs ({len(prompt_ids)}): {prompt_ids}")

  # ------- Pick the smallest prefill signature that fits the prompt -------
  prefill_sigs = sorted(
      [s for s in interp.get_signature_list() if s.startswith("prefill_")],
      key=lambda s: int(s.removeprefix("prefill_")),
  )
  if not prefill_sigs:
    raise RuntimeError("No prefill_* signatures in .tflite")
  chosen = None
  for s in prefill_sigs:
    if int(s.removeprefix("prefill_")) >= len(prompt_ids):
      chosen = s
      break
  if chosen is None:
    raise RuntimeError(
        f"Prompt has {len(prompt_ids)} tokens; no prefill signature is large"
        f" enough. Available: {prefill_sigs}"
    )
  prefill_seq_len = int(chosen.removeprefix("prefill_"))
  print(f"\nUsing signature `{chosen}` (seq_len={prefill_seq_len}).")

  # ------- Pad prompt to prefill_seq_len with pad_token_id -------
  pad_id = tokenizer.pad_token_id
  if pad_id is None:
    pad_id = 0
  padded_ids = list(prompt_ids) + [pad_id] * (prefill_seq_len - len(prompt_ids))
  prompt_len = len(prompt_ids)

  # ------- Run prefill -------
  prefill_runner = interp.get_signature_runner(chosen)
  kv = _zero_kv_cache(prefill_runner)
  prefill_inputs = {
      "tokens": np.array([padded_ids], dtype=np.int32),
      "input_pos": np.arange(prefill_seq_len, dtype=np.int32),
      **kv,
  }
  print("\nRunning prefill (this populates the KV cache) ...")
  prefill_out = prefill_runner(**prefill_inputs)

  # The prefill output dict has updated k_*/v_* tensors. Some converters also
  # emit a `logits` output on prefill; some don't. Handle both.
  has_prefill_logits = "logits" in prefill_out
  if has_prefill_logits:
    last_logits_tflite = prefill_out["logits"][0, prompt_len - 1, :]
    print(
        "Prefill emitted logits — using last-prompt-token logits for"
        " comparison."
    )
  else:
    print(
        "Prefill did NOT emit logits (default for our converter). Will run"
        " one decode step at the next position to get logits."
    )

  # Carry KV forward — the keys in prefill_out match the same k_*/v_* names.
  forward_kv = {k: v for k, v in prefill_out.items() if k.startswith(("kv_cache_k_", "kv_cache_v_"))}

  # ------- If no prefill logits, run one decode step at position prompt_len -1
  # to get the "next-token" logits we want to compare to HF -------
  decode_runner = interp.get_signature_runner("decode")
  if not has_prefill_logits:
    # Decode at position prompt_len - 1: feed the LAST prompt token, ask the
    # model to predict what comes next. Note: the KV cache from prefill
    # already contains entries at positions 0..prefill_seq_len-1 for the
    # padded sequence. To get a comparable "next-token after prompt" logit,
    # we re-run the last prompt token at position prompt_len-1.
    #
    # Simpler alternative for sanity-check: just step from position
    # prefill_seq_len (continuing past the padding). The HF comparison
    # below will use the same convention.
    pass  # we'll do this as part of the greedy decode below

  # ------- HF reference forward pass on the SAME prompt -------
  print("\nLoading HF model for reference logits ...")
  hf_model = transformers.AutoModelForCausalLM.from_pretrained(
      _CHECKPOINT_DIR.value
  )
  hf_model.eval()
  with torch.no_grad():
    hf_out = hf_model(torch.tensor([prompt_ids], dtype=torch.long))
  last_logits_hf = hf_out.logits[0, -1, :].cpu().numpy()
  hf_top1 = int(np.argmax(last_logits_hf))
  hf_top10 = np.argsort(-last_logits_hf)[:10].tolist()
  print(f"HF top-1 next token id: {hf_top1} -> {tokenizer.decode([hf_top1])!r}")
  print(f"HF top-10 next token ids: {hf_top10}")

  # ------- Greedy decode for N steps, comparing against HF along the way ----
  print(
      f"\nGreedy decode for {_DECODE_STEPS.value} steps with the .tflite"
      " (starting after the padded prompt slot) ..."
  )
  decoded_ids: list[int] = []
  pos = prefill_seq_len  # continue past the prefill window
  next_tok = padded_ids[prompt_len - 1]  # seed with the last real prompt token
  current_kv = forward_kv

  for step in range(_DECODE_STEPS.value):
    decode_inputs = {
        "tokens": np.array([[next_tok]], dtype=np.int32),
        "input_pos": np.array([pos], dtype=np.int32),
        **current_kv,
    }
    decode_out = decode_runner(**decode_inputs)
    logits = decode_out["logits"][0, 0, :]
    next_tok = _greedy_argmax(logits)
    decoded_ids.append(next_tok)
    current_kv = {
        k: v for k, v in decode_out.items() if k.startswith(("kv_cache_k_", "kv_cache_v_"))
    }
    pos += 1

  decoded_text = tokenizer.decode(decoded_ids, skip_special_tokens=False)
  print(f"\nGenerated {len(decoded_ids)} tokens:")
  print(f"  IDs:  {decoded_ids}")
  print(f"  text: {decoded_text!r}")

  # ------- Quality summary -------
  # Compare the very-first-decode-step logits against HF (most apples-to-apples).
  # We replay decode at pos = prompt_len with the last-prompt-token to get a
  # comparable logit, since HF's "last-position logits" is the prediction for
  # the token AFTER the prompt.
  print("\nReplaying one decode step at pos = prompt_len for HF comparison ...")
  cmp_kv = forward_kv  # KV from prefill (still contains position prompt_len-1)
  cmp_inputs = {
      "tokens": np.array([[prompt_ids[-1]]], dtype=np.int32),
      "input_pos": np.array([prompt_len - 1], dtype=np.int32),
      **cmp_kv,
  }
  # NOTE: this re-runs the last prompt token. The KV cache will have a
  # duplicate entry at that position, but for a single-token comparison
  # the resulting logits should still be a fair int8-vs-fp32 measurement.
  cmp_out = decode_runner(**cmp_inputs)
  last_logits_tflite = cmp_out["logits"][0, 0, :]

  tflite_top1 = int(np.argmax(last_logits_tflite))
  tflite_top10 = np.argsort(-last_logits_tflite)[:10].tolist()
  print(f"\n.tflite top-1: {tflite_top1} -> {tokenizer.decode([tflite_top1])!r}")
  print(f".tflite top-10: {tflite_top10}")

  diff = last_logits_tflite.astype(np.float32) - last_logits_hf.astype(
      np.float32
  )
  max_abs_diff = float(np.max(np.abs(diff)))
  mean_abs_diff = float(np.mean(np.abs(diff)))
  top10_overlap = len(set(hf_top10) & set(tflite_top10))

  print("\n" + "=" * 70)
  print("SANITY SUMMARY")
  print("=" * 70)
  print(f"Top-1 match:     {tflite_top1 == hf_top1}")
  print(f"Top-10 overlap:  {top10_overlap}/10")
  print(f"Max abs diff:    {max_abs_diff:.4f}")
  print(f"Mean abs diff:   {mean_abs_diff:.4f}")
  print(
      f"Generated text:  {decoded_text!r}"
      if decoded_text.strip()
      else "Generated text: (only special/empty tokens — see IDs above)"
  )

  # Crude pass/fail
  ok = top10_overlap >= 5 and not np.isnan(max_abs_diff)
  print(f"\n{'OK' if ok else 'WARNING'}:"
        f" {'looks fine for int8' if ok else 'numbers look off — investigate'}")


if __name__ == "__main__":
  app.run(main)
