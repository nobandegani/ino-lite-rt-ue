"""Encode a reference WAV + transcript into NeuTTS reference data.

Usage:
    python encode.py --wav samples/jo.wav --text samples/jo.txt --name jo

Output:
    Voices/<name>.pt        # dict: {"codes": torch.LongTensor[F], "text": str}

The .pt file contains everything the runtime needs to clone this voice:
  - `codes`: FSQ codes for the WAV (50 Hz)
  - `text`:  the transcript so the chat template can use it
"""

import argparse
from pathlib import Path

import torch
from librosa import load
from neucodec import NeuCodec


def main(wav_path: str, text_path: str, name: str, out_dir: str) -> None:
    out = Path(out_dir) / f"{name}.pt"
    print(f"Loading NeuCodec...")
    codec = NeuCodec.from_pretrained("neuphonic/neucodec").eval().to("cpu")

    print(f"Encoding {wav_path}...")
    wav, _ = load(wav_path, sr=16000, mono=True)
    wav_t = torch.from_numpy(wav).float().unsqueeze(0).unsqueeze(0)
    with torch.no_grad():
        codes = codec.encode_code(audio_or_path=wav_t).squeeze(0).squeeze(0)

    text = Path(text_path).read_text(encoding="utf-8").strip()

    out.parent.mkdir(parents=True, exist_ok=True)
    torch.save({"codes": codes, "text": text}, out)
    print(f"Saved -> {out}  (codes shape={tuple(codes.shape)}, text='{text[:60]}...')")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--wav", required=True, help="Path to reference WAV (16 kHz mono recommended).")
    p.add_argument("--text", required=True, help="Path to transcript .txt file.")
    p.add_argument("--name", required=True, help="Output filename stem, e.g. 'jo' -> jo.pt.")
    p.add_argument("--out_dir", default=str(Path(__file__).resolve().parent),
                   help="Output directory (default: Voices/).")
    args = p.parse_args()
    main(args.wav, args.text, args.name, args.out_dir)
