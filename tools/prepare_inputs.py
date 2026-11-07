#!/usr/bin/env python3
"""Crop and downscale the source photos into framebuffer-friendly squares.

The simt_gpu framebuffer holds 4096 32-bit words, so the largest square image
is 64x64. This produces 64/32/16 px packed-RGB PNGs under
input_images/processed/, plus a _preview.png contact sheet so the crops can be
eyeballed.

Crop boxes are hand-tuned per source to centre the subject's helmet and keep
watermarks/background out. Coordinates are (left, top, right, bottom) in the
original image.

Usage:
    .venv/bin/python tools/prepare_inputs.py
"""
import os

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC_DIR = os.path.join(ROOT, "input_images")
OUT_DIR = os.path.join(SRC_DIR, "processed")

# stem -> (left, top, right, bottom); square crops that frame Alonso.
CROPS = {
    "alonso_aston":   (210,   0, 630, 420),
    "alonso_ferrari": (330,   0, 830, 500),
    "alonso_renault": (160, 110, 600, 550),
}

SIZES = (64, 32, 16)
PREVIEW_SCALE = 4  # upscale 64px -> 256px on the contact sheet


def process():
    os.makedirs(OUT_DIR, exist_ok=True)
    preview_rows = []

    for stem, box in CROPS.items():
        src = None
        for ext in (".jpg", ".jpeg", ".png"):
            path = os.path.join(SRC_DIR, stem + ext)
            if os.path.exists(path):
                src = path
                break
        if src is None:
            raise SystemExit(f"missing source image for {stem}")

        im = Image.open(src).convert("RGB")
        left, top, right, bottom = box
        if not (0 <= left < right <= im.width and 0 <= top < bottom <= im.height):
            raise SystemExit(f"crop {box} out of bounds for {im.width}x{im.height} {stem}")
        crop = im.crop((left, top, right, bottom))

        tiles = []
        for size in SIZES:
            out = crop.resize((size, size), Image.LANCZOS)
            out_path = os.path.join(OUT_DIR, f"{stem}_{size}.png")
            out.save(out_path)
            print(f"{os.path.relpath(out_path, ROOT)}  ({size}x{size})")
            tiles.append(out)

        preview_rows.append((stem, tiles))

    make_preview(preview_rows)


def make_preview(rows):
    cell = 64 * PREVIEW_SCALE
    label_w = 150
    pad = 12
    width = label_w + pad + len(SIZES) * (cell + pad)
    height = pad + len(rows) * (cell + pad)
    sheet = Image.new("RGB", (width, height), (24, 24, 28))
    draw = ImageDraw.Draw(sheet)

    for r, (stem, tiles) in enumerate(rows):
        y = pad + r * (cell + pad)
        draw.text((pad, y + cell // 2), stem, fill=(230, 230, 230))
        for c, tile in enumerate(tiles):
            x = label_w + pad + c * (cell + pad)
            big = tile.resize((cell, cell), Image.NEAREST)
            sheet.paste(big, (x, y))
            draw.text((x, y - 10), f"{tile.width}px", fill=(160, 200, 255))

    out_path = os.path.join(OUT_DIR, "_preview.png")
    sheet.save(out_path)
    print(f"{os.path.relpath(out_path, ROOT)}  (contact sheet)")


if __name__ == "__main__":
    process()
