#!/usr/bin/env python3
"""Phase 1 ball kernel tests: animation, edge cases, parameter fuzz. ISA sim and RTL vs reference.

Negative centers and off-screen balls exercise SUB wraparound, MUL of negative operands and the
SRL-by-31 sign trick on the real RTL ALU, not only in the Python model.
"""
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import animate_ref  # noqa: E402
import ball_ref     # noqa: E402
import run_ball     # noqa: E402

BALL, BG = 0x00FF8000, 0x00101830
FRAMES = 100
FUZZ_ISA = 1000
FUZZ_RTL = 150

EDGE_CASES = {
    "left wall":        (0, 32, 49),
    "right wall":       (63, 32, 49),
    "top wall":         (32, 0, 49),
    "bottom wall":      (32, 63, 49),
    "corner 0,0":       (0, 0, 49),
    "corner 63,63":     (63, 63, 49),
    "radius 0":         (20, 20, 0),
    "radius 0 offgrid": (-5, -5, 0),
    "radius 1":         (30, 30, 1),
    "exact edge":       (32, 32, 25),
    "radius > frame":   (32, 32, 100000),
    "offscreen left":   (-100, 32, 10000),
    "offscreen top":    (32, -100, 10000),
    "offscreen right":  (200, 32, 10000),
    "negative both":    (-30, -30, 2500),
    "domain min":       (ball_ref.CENTER_MIN, ball_ref.CENTER_MIN, 49),
    "domain max":       (ball_ref.CENTER_MAX, ball_ref.CENTER_MAX, 49),
    "domain max r2":    (ball_ref.CENTER_MIN, ball_ref.CENTER_MAX, ball_ref.R2_MAX),
    "same colors":      (32, 32, 49),
}


def main():
    fails = 0
    for name, kw in (("parameter block", {}), ("kernel arguments", dict(kernel=os.path.join(run_ball.ROOT, "sw", "kernels", "ball_args.asm"), args_mode=True, workdir=os.path.join(run_ball.ROOT, "build", "ball_args")))):
        print(f"== ball kernel with {name}")
        fails += one(run_ball.Ball(**kw))
    if fails:
        sys.exit(f"FAIL: {fails} mismatches")
    print("PASS: ball kernels exact on animation, edge cases and fuzz (parameter block and kernel arguments)")


def one(ball):
    fails = 0

    def run(label, params, rtl=True):
        nonlocal fails
        assert ball_ref.in_kernel_domain(*params[:3]), (label, params)
        err = run_ball.check(ball, params, rtl=rtl)
        if err:
            fails += 1
            print(f"FAIL {label}: {err}")

    for n, p in enumerate(animate_ref.frames(FRAMES)):
        run(f"animation frame {n}", p)
    print(f"animation: {FRAMES} frames done")

    for name, (cx, cy, r2) in EDGE_CASES.items():
        bg = BALL if name == "same colors" else BG
        run(f"edge case '{name}'", (cx, cy, r2, BALL, bg))
    print(f"edge cases: {len(EDGE_CASES)} done")

    rng = random.Random(0xB411)
    for n in range(FUZZ_ISA):
        p = (rng.randint(-200, 260), rng.randint(-200, 260), rng.randint(0, 4000),
             rng.getrandbits(24), rng.getrandbits(24))
        run(f"fuzz {n}", p, rtl=(n < FUZZ_RTL))
    print(f"fuzz: {FUZZ_ISA} ISA, {FUZZ_RTL} RTL done")

    return fails


if __name__ == "__main__":
    main()
