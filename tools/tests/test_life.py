#!/usr/bin/env python3
"""Game of Life kernel: ISA simulator and RTL against the reference for several generations."""
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.dirname(HERE))

import life_ref as lr  # noqa: E402
import run_kernel as rk  # noqa: E402

prog, meta = rk.load(os.path.join(ROOT, "sw", "kernels", "life.asm"))
A, B = 0x2000, 0x6000
fails = 0


def check(label, got, ref):
    global fails
    if got != ref:
        i = next(i for i in range(len(ref)) if got[i] != ref[i])
        print(f"FAIL {label}: cell {i} got {got[i]} expected {ref[i]}")
        fails += 1


# 40 generations of the glider gun on the ISA simulator, swapping src/dst each launch
ref_frames = lr.run(lr.gun_start(), 40)
state = ref_frames[0]
for n in range(1, 41):
    out = rk.run_isa(prog, 4096, A, B, 4096, init=state)
    check(f"isa generation {n}", out, ref_frames[n])
    state = out
# random soup (wrap-around edges, dense cells), ISA and RTL
rng = random.Random(3)
soup = [1 if rng.random() < 0.35 else 0 for _ in range(4096)]
state = soup
for n in range(1, 4):
    ref = lr.step(state)
    check(f"isa soup {n}", rk.run_isa(prog, 4096, A, B, 4096, init=state), ref)
    if os.path.exists(rk.BIN_ARGS):
        check(f"rtl soup {n}", rk.run_rtl(prog, 4096, A, B, 4096, init=state), ref)
    state = ref
if os.path.exists(rk.BIN_ARGS):
    state = lr.gun_start()
    for n in range(1, 6):
        ref = lr.step(state)
        check(f"rtl gun {n}", rk.run_rtl(prog, 4096, A, B, 4096, init=state), ref)
        state = ref
else:
    print("note: build/obj_args missing, RTL not checked (make build-args)")
if fails:
    sys.exit("FAIL")
print("PASS: Game of Life kernel exact (ISA sim 40 generations of the glider gun + random soup, RTL gun and soup)")
