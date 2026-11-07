#!/usr/bin/env python3
"""Render a packed-RGB hex frame (0x00RRGGBB per line) back into an image.

Writes PNG when Pillow is available, otherwise falls back to binary PPM.

Usage:
    mem_to_img.py --in out.hex --meta frame.json --out output.png
"""
import argparse
import json
import math
import os

WORD_MASK = 0x00FFFFFF


def read_words(path):
    words = []
    with open(path) as f:
        for line in f:
            for tok in line.split():
                words.append(int(tok, 16) & WORD_MASK)
    return words


def load_dims(meta_path, n):
    if meta_path and os.path.exists(meta_path):
        with open(meta_path) as f:
            m = json.load(f)
        return int(m["width"]), int(m["height"])
    s = int(math.isqrt(n)) or 1
    return s, max(1, n // s)


def write_image(in_hex, meta_path, out_path):
    words = read_words(in_hex)
    w, h = load_dims(meta_path, len(words))
    pixels = words[: w * h]

    try:
        from PIL import Image
        img = Image.new("RGB", (w, h))
        px = img.load()
        for i, word in enumerate(pixels):
            px[i % w, i // w] = ((word >> 16) & 0xFF, (word >> 8) & 0xFF, word & 0xFF)
        img.save(out_path)
    except Exception:
        ppm = os.path.splitext(out_path)[0] + ".ppm"
        with open(ppm, "wb") as f:
            f.write(b"P6\n%d %d\n255\n" % (w, h))
            buf = bytearray()
            for word in pixels:
                buf += bytes(((word >> 16) & 0xFF, (word >> 8) & 0xFF, word & 0xFF))
            f.write(buf)
        out_path = ppm
        print(f"Pillow unavailable; wrote {ppm}")

    return w, h, out_path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="in_hex", required=True)
    ap.add_argument("--meta", default=None)
    ap.add_argument("--out", default="output.png")
    args = ap.parse_args()

    w, h, path = write_image(args.in_hex, args.meta, args.out)
    print(f"wrote {w}x{h} image to {path}")


if __name__ == "__main__":
    main()
