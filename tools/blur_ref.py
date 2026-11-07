#!/usr/bin/env python3
"""Independent integer reference for the 3x3 box blur.

Deliberately does NOT use the GPU ISA: run_sim compares it against both the
golden ISA model and the RTL, so a bug in the assembler/kernel is caught here.

`box_blur_interior` is the Phase 2 reference (interior pixels only; border left
0). `box_blur_clamped` is the Phase 3 full-frame reference (every pixel, with
out-of-range neighbour coordinates clamped to the image edge).
"""
MASK = 0x00FFFFFF


def box_blur_interior(img, W, H):
    """img: flat list of packed-RGB words. Returns a new list, same length."""
    out = [0] * len(img)
    for y in range(1, H - 1):
        for x in range(1, W - 1):
            sr = sg = sb = 0
            for dy in (-1, 0, 1):
                row = (y + dy) * W
                for dx in (-1, 0, 1):
                    q = img[row + x + dx]
                    sr += (q >> 16) & 0xFF
                    sg += (q >> 8) & 0xFF
                    sb += q & 0xFF
            out[y * W + x] = ((sr // 9) << 16) | ((sg // 9) << 8) | (sb // 9)
    return out


def box_blur_clamped(img, W, H):
    """Full-frame 3x3 box blur with clamped (edge-replicated) sampling.

    Every output coordinate (x, y) samples the 3x3 neighbourhood centred on it,
    clamping each sample coordinate to [0, W-1] / [0, H-1]. Channels average
    independently and integer-divide by 9 (truncating toward zero), then repack
    as 0x00RRGGBB. Returns a new list, same length as `img`.
    """
    out = [0] * len(img)
    for y in range(H):
        for x in range(W):
            sr = sg = sb = 0
            for dy in (-1, 0, 1):
                sy = min(max(y + dy, 0), H - 1)
                row = sy * W
                for dx in (-1, 0, 1):
                    sx = min(max(x + dx, 0), W - 1)
                    q = img[row + sx]
                    sr += (q >> 16) & 0xFF
                    sg += (q >> 8) & 0xFF
                    sb += q & 0xFF
            out[y * W + x] = ((sr // 9) << 16) | ((sg // 9) << 8) | (sb // 9)
    return out
