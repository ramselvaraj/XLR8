#!/usr/bin/env python3
"""Decode the PNG/GIF files written by sw/tests/test_img.c with Pillow and compare pixels exactly."""
import os
import sys
from PIL import Image

d = sys.argv[1] if len(sys.argv) > 1 else "sw/build/img_out"
PAL = [(0x10, 0x18, 0x30), (0xFF, 0x80, 0x00)]


def ball(x, y):
    return (x - 20) ** 2 + (y - 30) ** 2 <= 49


fails = 0

im = Image.open(f"{d}/grad_s1.png").convert("RGB")
assert im.size == (64, 64), im.size
for y in range(64):
    for x in range(64):
        if im.getpixel((x, y)) != (x * 4, y * 4, 0x80):
            fails += 1
im = Image.open(f"{d}/ball_s4.png").convert("RGB")
assert im.size == (256, 256), im.size
for y in range(256):
    for x in range(256):
        if im.getpixel((x, y)) != PAL[1 if ball(x // 4, y // 4) else 0]:
            fails += 1

g = Image.open(f"{d}/anim.gif")
assert g.size == (192, 192) and g.n_frames == 3, (g.size, g.n_frames)
for fi in range(3):
    g.seek(fi)
    fr = g.convert("RGB")
    for y in range(192):
        for x in range(192):
            sx, sy = x // 3, y // 3
            inside = ball(sx, sy) if fi != 1 else (sx == sy)
            if fr.getpixel((x, y)) != PAL[1 if inside else 0]:
                fails += 1
    assert g.info.get("duration") == 50, g.info.get("duration")
import struct
raw = open(f"{d}/noise.raw", "rb").read()
words = struct.unpack("<%dI" % (64 * 64), raw)
ng = Image.open(f"{d}/noise.gif").convert("RGB")
assert ng.size == (256, 256)
for y in range(256):
    for x in range(256):
        v = words[(y // 4) * 64 + (x // 4)]
        if ng.getpixel((x, y)) != ((v >> 16) & 255, (v >> 8) & 255, v & 255):
            fails += 1
if fails:
    sys.exit(f"FAIL: {fails} wrong pixels")
print("PASS: PNG (scale 1 and 4), 3-frame GIF and a noisy 4-colour GIF decode with exact pixels")
