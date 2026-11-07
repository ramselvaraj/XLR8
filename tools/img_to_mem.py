#!/usr/bin/env python3
"""Convert an image (or a built-in test pattern) into a packed-RGB hex frame.

Each output line is one 32-bit word, 0x00RRGGBB, in raster order. A JSON
sidecar records width/height so the output can be reshaped on the way back.

Usage:
    img_to_mem.py --image in.png --width 16 --height 16 --out frame.hex --meta frame.json
    img_to_mem.py --width 16 --height 16 --out frame.hex --meta frame.json   # test pattern
"""
import argparse
import json
import sys

WORD_MASK = 0x00FFFFFF


def have_pil():
    try:
        import PIL  # noqa: F401
        return True
    except Exception:
        return False


def rgb_word(r, g, b):
    return ((r & 0xFF) << 16) | ((g & 0xFF) << 8) | (b & 0xFF)


def _pattern_pixel(x, y, w, h):
    r = (x * 255) // max(1, w - 1)
    g = (y * 255) // max(1, h - 1)
    b = 255 - r
    if ((x // 2) + (y // 2)) % 2 == 0:
        r = min(255, r + 40)
    return r, g, b


def _words_from_pil(img, w, h):
    from PIL import Image
    img = img.convert("RGB").resize((w, h))
    px = img.load()
    return [rgb_word(*px[x, y]) for y in range(h) for x in range(w)]


def _words_from_pattern(w, h):
    return [rgb_word(*_pattern_pixel(x, y, w, h)) for y in range(h) for x in range(w)]


def generate(image_path, w, h, out_hex, meta_path=None):
    if image_path:
        if not have_pil():
            sys.exit("error: Pillow is required to read images; run `make venv`")
        from PIL import Image
        words = _words_from_pil(Image.open(image_path), w, h)
    else:
        words = _words_from_pattern(w, h)

    with open(out_hex, "w") as f:
        for word in words:
            f.write(f"{word & WORD_MASK:08x}\n")

    if meta_path:
        with open(meta_path, "w") as f:
            json.dump({"width": w, "height": h}, f)

    return words


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", default=None, help="input image (needs Pillow)")
    ap.add_argument("--width", type=int, default=16)
    ap.add_argument("--height", type=int, default=16)
    ap.add_argument("--out", default="frame.hex")
    ap.add_argument("--meta", default=None, help="JSON sidecar with width/height")
    args = ap.parse_args()

    generate(args.image, args.width, args.height, args.out, args.meta)
    print(f"wrote {args.width * args.height} pixels to {args.out}")


if __name__ == "__main__":
    main()
