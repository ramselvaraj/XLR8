#!/usr/bin/env python3
"""The divide-free blur kernels (`.gen_blur W H nodiv`, `.gen_blur_border W H nodiv`) must equal
box_blur_clamped exactly, and contain no DIV instruction."""
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import assemble  # noqa: E402
import blur_ref  # noqa: E402
import isa_sim   # noqa: E402

SRC, DST, WORDS = 0x2000, 0x6000, 32768


def run(W, H, img, nodiv):
    suffix = " nodiv" if nodiv else ""
    out = None
    data = [0] * WORDS
    data[SRC:SRC + len(img)] = img
    progs = []
    for d in (".gen_blur", ".gen_blur_border"):
        p, m = assemble.assemble(f"{d} {W} {H}{suffix}\n.src {SRC:#x}\n.dst {DST:#x}\n")[:2]
        progs.append((p, m))
        isa_sim.run(p, data, m["threads"], SRC, DST)
    return data[DST:DST + W * H], progs


fails = 0
rng = random.Random(9)
for W, H in ((8, 8), (16, 16), (17, 11), (32, 32), (64, 64)):
    for kind in ("random", "extremes"):
        img = [rng.getrandbits(24) for _ in range(W * H)] if kind == "random" else \
              [rng.choice((0x000000, 0xFFFFFF, 0xFF00FF, 0x00FF00)) for _ in range(W * H)]
        ref = blur_ref.box_blur_clamped(img, W, H)
        got, progs = run(W, H, img, True)
        for p, _ in progs:
            if any(((w >> 12) & 0xF) == 0x7 for w in p):
                print(f"FAIL {W}x{H}: a DIV instruction remains"); fails += 1
        if got != ref:
            i = next(i for i in range(len(ref)) if got[i] != ref[i])
            print(f"FAIL {W}x{H} {kind}: pixel {i} got {got[i]:06x} expected {ref[i]:06x}")
            fails += 1
if fails:
    sys.exit("FAIL")
n_div = sum(len(p) for p, _ in run(64, 64, [0] * 4096, False)[1])
n_nodiv = sum(len(p) for p, _ in run(64, 64, [0] * 4096, True)[1])
print(f"PASS: divide-free blur exact on 5 sizes x 2 images (64x64 program: {n_div} -> {n_nodiv} instructions, no DIV)")
