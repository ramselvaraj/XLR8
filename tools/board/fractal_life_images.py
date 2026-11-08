#!/usr/bin/env python3
"""Verify the board's raw Mandelbrot and Game of Life output against the references (exact), then
write the images:  fractal_life_images.py <raw dir> <out dir>"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(HERE)), "tools"))
sys.path.insert(0, os.path.dirname(HERE))
from PIL import Image  # noqa: E402

import life_ref as lr   # noqa: E402
import mandel_ref as mr  # noqa: E402

raw, out = sys.argv[1], sys.argv[2]
W = 128
VIEWS = {"full": (-9011, -6144, 96), "zoom": (-3840, -358, 12)}
BG, FG = (14, 20, 40), (255, 196, 64)
ok = True

# ---- Mandelbrot
for name, (x0, y0, step) in VIEWS.items():
    words = list(struct.unpack(f"<{W * W}I", open(f"{raw}/mandel_{name}.raw", "rb").read()))
    ref = mr.render(W, x0, y0, step)
    bad = sum(1 for a, b in zip(words, ref) if a != b)
    print(f"mandelbrot {name}: {W * W - bad} of {W * W} pixels identical to the reference")
    ok &= bad == 0
    im = Image.new("RGB", (W, W))
    im.putdata([((v >> 16) & 255, (v >> 8) & 255, v & 255) for v in words])
    im.resize((W * 4, W * 4), Image.NEAREST).save(f"{out}/mandelbrot_{name}.png")

# ---- Game of Life
data = open(f"{raw}/life_frames.raw", "rb").read()
n_frames = len(data) // (4096 * 4)
frames = [list(struct.unpack("<4096I", data[i * 16384:(i + 1) * 16384])) for i in range(n_frames)]
ref = lr.run(lr.gun_start(), n_frames - 1)
bad_gens = sum(1 for a, b in zip(frames, ref) if a != b)
print(f"life: {n_frames - bad_gens} of {n_frames} generations identical to the reference")
ok &= bad_gens == 0


def frame_img(f, scale):
    im = Image.new("RGB", (64, 64))
    im.putdata([FG if v else BG for v in f])
    return im.resize((64 * scale, 64 * scale), Image.NEAREST)


picks = [0, 10, 20, 30, 45, 60, 75, 90, 105, 120, 135, 149]
S, GAP = 3, 6
sheet = Image.new("RGB", (4 * 64 * S + 5 * GAP, 3 * 64 * S + 4 * GAP), (252, 252, 251))
for k, g in enumerate(picks):
    sheet.paste(frame_img(frames[g], S), (GAP + (k % 4) * (64 * S + GAP), GAP + (k // 4) * (64 * S + GAP)))
sheet.save(f"{out}/life_sheet.png")
gif = [frame_img(f, 5) for f in frames]
gif[0].save(f"{out}/life.gif", save_all=True, append_images=gif[1:], duration=50, loop=0)
print("wrote", ", ".join(sorted(f for f in os.listdir(out) if f.startswith(("mandelbrot", "life")))))
sys.exit(0 if ok else 1)
