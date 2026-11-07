#!/usr/bin/env python3
"""Independent reference renderer for the ball kernel.

Pure Python. Imports neither the assembler nor the ISA simulator. Uses exact integer
math (no 32-bit wrap), so it also defines the kernel's valid domain.

Frame: W x H pixels, row-major, one packed 0x00RRGGBB value per pixel.
"""
W = 64
H = 64

# Valid domain of the GPU kernel (see sw/kernels/ball.asm).
CENTER_MIN, CENTER_MAX = -16384, 16383
R2_MAX = 1 << 30


def in_kernel_domain(cx, cy, r2):
    return (CENTER_MIN <= cx <= CENTER_MAX and CENTER_MIN <= cy <= CENTER_MAX
            and 0 <= r2 <= R2_MAX)


def render(cx, cy, r2, ball, bg, w=W, h=H):
    out = []
    for y in range(h):
        for x in range(w):
            inside = (x - cx) ** 2 + (y - cy) ** 2 <= r2
            out.append(ball if inside else bg)
    return out


def param_block(cx, cy, r2, ball, bg):
    """The five 32-bit words the kernel loads from SRC."""
    m = 0xFFFFFFFF
    return [cx & m, cy & m, r2 & m, ball & m, bg & m]


def render_gradient(w=W, h=H):
    return [(((x * 4) << 16) | ((y * 4) << 8) | 0x80) for y in range(h) for x in range(w)]


def render_checker(a, b, w=W, h=H, size=8):
    return [a if (((x // size) ^ (y // size)) & 1) == 0 else b for y in range(h) for x in range(w)]
