#!/usr/bin/env python3
"""Render the ball animation through the full xlr8_top wrapper (AXI-Lite control + AXI3 memory)
in Verilator and compare every frame exactly against the independent reference.

Usage: run_ball_axi.py [--frames N] [--stall PCT] [--seed S]
"""
import argparse
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import animate_ref  # noqa: E402
import assemble     # noqa: E402
import ball_ref     # noqa: E402

BINARY = os.path.join(ROOT, "build", "xlr8", "Vtb_xlr8")
KERNEL = os.path.join(ROOT, "sw", "kernels", "ball.asm")
KERNEL_ARGS = os.path.join(ROOT, "sw", "kernels", "ball_args.asm")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--frames", type=int, default=100)
    ap.add_argument("--stall", type=int, default=0)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--args", action="store_true", help="kernel arguments (ball_args.asm) instead of a parameter block")
    ap.add_argument("--workdir", default=os.path.join(ROOT, "build", "ball_axi"))
    args = ap.parse_args()
    os.makedirs(args.workdir, exist_ok=True)
    if not os.path.exists(BINARY):
        sys.exit("build/xlr8/Vtb_xlr8 missing; run `make build-xlr8`")

    prog, _ = assemble.assemble(open(KERNEL_ARGS if args.args else KERNEL).read())[:2]
    prog_hex = os.path.join(args.workdir, "prog.hex")
    with open(prog_hex, "w") as f:
        f.write("".join(f"{w & 0xFFFF:04x}\n" for w in prog))

    params = list(animate_ref.frames(args.frames))
    par_hex = os.path.join(args.workdir, "params.hex")
    with open(par_hex, "w") as f:
        for p in params:
            f.write("".join(f"{w:08x}\n" for w in ball_ref.param_block(*p)))
    out_hex = os.path.join(args.workdir, "out.hex")

    cmd = [BINARY, "+test=ball", f"+stall={args.stall}", f"+verilator+seed+{args.seed}",
           f"+ballprog={prog_hex}", f"+ballparams={par_hex}", f"+frames={args.frames}",
           f"+ballout={out_hex}"] + (["+ballargs"] if args.args else [])
    res = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    sys.stdout.write("".join(l + "\n" for l in res.stdout.splitlines() if l.startswith("ball frame")))
    if res.returncode != 0 or "tb_xlr8: PASS" not in res.stdout:
        sys.exit("FAIL: testbench reported errors\n" + res.stdout[-2000:])

    words = [int(x, 16) for x in open(out_hex).read().split()]
    n = ball_ref.W * ball_ref.H
    if len(words) != n * args.frames:
        sys.exit(f"FAIL: expected {n * args.frames} pixels, got {len(words)}")
    for fi, p in enumerate(params):
        ref = ball_ref.render(*p)
        got = words[fi * n:(fi + 1) * n]
        if got != ref:
            i = next(i for i in range(n) if got[i] != ref[i])
            sys.exit(f"FAIL: frame {fi} pixel {i} got {got[i]:08x} expected {ref[i]:08x}")
    print(f"PASS: {args.frames} ball frames exact through xlr8_top ({'kernel arguments' if args.args else 'parameter block'}, stall={args.stall}%, seed={args.seed})")


if __name__ == "__main__":
    main()
