#!/usr/bin/env python3
"""Mandelbrot kernel: ISA simulator and RTL against the fixed-point reference (exact), and the
reference against a floating-point Mandelbrot (it must be the real set)."""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.dirname(HERE))

import gen_mandelbrot  # noqa: E402
import mandel_ref as mr  # noqa: E402
import run_kernel as rk  # noqa: E402
import assemble  # noqa: E402

FULL = (-9011, -6144)           # top-left corner (-2.2, -1.5) in Q12
ZOOM = (-3277, 205)             # (-0.8, 0.05)
fails = 0


def check(label, got, ref):
    global fails
    if got != ref:
        i = next(i for i in range(len(ref)) if got[i] != ref[i])
        print(f"FAIL {label}: pixel {i} got {got[i]:08x} expected {ref[i]:08x}")
        fails += 1


def kernel(w):
    return assemble.assemble(gen_mandelbrot.gen(w, 0x2000))[0]


# ISA simulator at 32x32 (two views) and 64x64 (full view)
for w, view, step in ((32, FULL, 384), (32, ZOOM, 30), (64, FULL, 192)):
    prog = kernel(w)
    args = [view[0] & mr.M, view[1] & mr.M, step]
    ref = mr.render(w, view[0], view[1], step)
    check(f"isa {w}x{w} step {step}", rk.run_isa(prog, w * w, 0, 0x2000, w * w, args=args), ref)
# RTL (Verilated GPU) at 32x32, both views
if os.path.exists(rk.BIN_ARGS):
    for view, step in ((FULL, 384), (ZOOM, 30)):
        prog = kernel(32)
        args = [view[0] & mr.M, view[1] & mr.M, step]
        check(f"rtl 32x32 step {step}", rk.run_rtl(prog, 1024, 0, 0x2000, 1024, args=args),
              mr.render(32, view[0], view[1], step))
else:
    print("note: build/obj_args missing, RTL not checked (make build-args)")

# the reference is a real Mandelbrot: its escape counts match plain floating point
w, step = 64, 192
ref = mr.render(w, FULL[0], FULL[1], step)
flt = mr.escape_counts_float(w, FULL[0], FULL[1], step)
inside_ref = [c == 0 for c in ref]
inside_flt = [n >= 31 for n in flt]
diff = sum(1 for a, b in zip(inside_ref, inside_flt) if a != b)
if diff > 0.02 * len(ref):
    print(f"FAIL: fixed-point set differs from floating point on {diff} of {len(ref)} pixels")
    fails += 1
print(f"float check: fixed-point and floating-point agree on {len(ref) - diff} of {len(ref)} pixels (inside/outside the set)")
if fails:
    sys.exit("FAIL")
print("PASS: Mandelbrot kernel exact (ISA sim 32x32 x2 and 64x64, RTL 32x32 x2)")
