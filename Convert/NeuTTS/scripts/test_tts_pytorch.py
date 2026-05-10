"""Reference TTS using the upstream PyTorch NeuTTS pipeline.

Bypasses LiteRT entirely — runs HuggingFace NeuTTS Nano + PyTorch
NeuCodec end-to-end. Use as a sanity reference against scripts/test_tts.py
(the LiteRT path) to confirm our converted models produce equivalent
audio.

Output: generated/pytorch_ref/<sanitized_text>.wav

Run from Plugins/InoLiteRT/Convert/NeuTTS/:

    python scripts/test_tts_pytorch.py --text 'hello there'
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import numpy as np
import soundfile as sf
import torch

# Make the vendored neutts and neucodec packages importable.
_HERE = Path(__file__).resolve().parent
_NEUTTS_VENDOR = _HERE.parent / "vendor" / "neutts"
_NEUCODEC_VENDOR = _HERE.parent.parent / "NeuCodec" / "vendor" / "neucodec"
for p in (_NEUTTS_VENDOR, _NEUCODEC_VENDOR):
    if str(p) not in sys.path:
        sys.path.insert(0, str(p))

from neutts import NeuTTS  # noqa: E402


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--text", required=True)
    p.add_argument("--ref_wav", default="vendor/neutts/samples/jo.wav")
    p.add_argument("--ref_txt", default="vendor/neutts/samples/jo.txt")
    p.add_argument("--backbone_repo", default="models/nano",
                   help="HF backbone repo or local checkpoint dir.")
    p.add_argument("--codec_repo", default="neuphonic/neucodec")
    p.add_argument("--out", default=None,
                   help="Override output WAV (default: generated/pytorch_ref/<text>.wav).")
    p.add_argument("--seed", type=int, default=42)
    args = p.parse_args()

    torch.manual_seed(args.seed)
    np.random.seed(args.seed)

    if args.out is None:
        stem = re.sub(r"[^a-z0-9 ]+", "", args.text.lower()).strip()
        stem = re.sub(r"\s+", "_", stem) or "test"
        args.out = f"generated/pytorch_ref/{stem}.wav"

    print(f"[1/3] Loading NeuTTS (backbone={args.backbone_repo}, codec={args.codec_repo})...")
    tts = NeuTTS(
        backbone_repo=args.backbone_repo,
        backbone_device="cpu",
        codec_repo=args.codec_repo,
        codec_device="cpu",
        # Required when backbone_repo isn't in BACKBONE_LANGUAGE_MAP (e.g. a
        # local path like "models/nano" instead of "neuphonic/neutts-nano").
        language="en-us",
    )

    print(f"[2/3] Encoding reference voice from {args.ref_wav}...")
    ref_text = Path(args.ref_txt).read_text(encoding="utf-8").strip()
    ref_codes = tts.encode_reference(args.ref_wav)
    print(f"  ref codes shape={tuple(ref_codes.shape)}")

    print(f"[3/3] Generating audio for: '{args.text}'...")
    wav = tts.infer(args.text, ref_codes, ref_text)

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(out_path), wav, 24000)
    print(f"\nDone. Wrote {out_path} ({len(wav)/24000:.2f} s @ 24 kHz)")


if __name__ == "__main__":
    main()
