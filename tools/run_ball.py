#!/usr/bin/env python3
"""Run the ball kernel through the ISA simulator and the Verilated RTL, and compare both
against the independent reference (ball_ref.py). Exact equality only.

Library use: `Ball(workdir)` then `.render_isa(params)` / `.render_rtl(params)`.
CLI: run_ball.py --frames N   renders the animation and checks every frame.
"""
import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import animate_ref  # noqa: E402
import assemble     # noqa: E402
import ball_ref     # noqa: E402
import isa_sim      # noqa: E402

KERNEL = os.path.join(ROOT, "sw", "kernels", "ball.asm")
BINARY = os.path.join(ROOT, "build", "obj", "Vtb_gpu")
WORDS = 32768


class Ball:
    def __init__(self, workdir=None, kernel=KERNEL, binary=BINARY):
        self.workdir = os.path.abspath(workdir or os.path.join(ROOT, "build", "ball"))
        os.makedirs(self.workdir, exist_ok=True)
        self.binary = binary
        with open(kernel) as f:
            self.prog, self.meta = assemble.assemble(f.read())[:2]
        self.threads = self.meta["threads"]
        self.src, self.dst = self.meta["src"], self.meta["dst"]
        self.prog_hex = os.path.join(self.workdir, "prog.hex")
        with open(self.prog_hex, "w") as f:
            f.write("".join(f"{w & 0xFFFF:04x}\n" for w in self.prog))
        self.frame_hex = os.path.join(self.workdir, "params.hex")
        self.out_hex = os.path.join(self.workdir, "out.hex")

    def render_isa(self, params):
        data = [0] * WORDS
        block = ball_ref.param_block(*params)
        data[self.src:self.src + len(block)] = block
        isa_sim.run(self.prog, data, self.threads, self.src, self.dst)
        return data[self.dst:self.dst + ball_ref.W * ball_ref.H]

    def render_rtl(self, params):
        with open(self.frame_hex, "w") as f:
            f.write("".join(f"{w:08x}\n" for w in ball_ref.param_block(*params)))
        cmd = [self.binary, f"+frame={self.frame_hex}", f"+prog={self.prog_hex}",
               f"+out={self.out_hex}", f"+count={self.threads}",
               f"+src={self.src}", f"+dst={self.dst}"]
        subprocess.run(cmd, check=True, cwd=self.workdir, stdout=subprocess.DEVNULL)
        data = isa_sim.read_hex_words(self.out_hex)
        return data[self.dst:self.dst + ball_ref.W * ball_ref.H]


def first_diff(a, b):
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            return i, x, y
    return None


def check(ball, params, rtl=True):
    """Return None on success, else a description of the first mismatch."""
    ref = ball_ref.render(*params)
    for name, fn in (("isa", ball.render_isa), ("rtl", ball.render_rtl)):
        if name == "rtl" and not rtl:
            continue
        d = first_diff(fn(params), ref)
        if d:
            i, got, exp = d
            return (f"{name} mismatch for params={params} at pixel {i} "
                    f"(x={i % ball_ref.W}, y={i // ball_ref.W}): got {got:08x}, expected {exp:08x}")
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--frames", type=int, default=100)
    ap.add_argument("--no-rtl", action="store_true")
    args = ap.parse_args()
    ball = Ball()
    print(f"kernel: {len(ball.prog)} instructions, {ball.threads} threads")
    for n, p in enumerate(animate_ref.frames(args.frames)):
        err = check(ball, p, rtl=not args.no_rtl)
        if err:
            sys.exit(f"FAIL frame {n}: {err}")
    print(f"PASS: {args.frames} animation frames exact (isa{'' if args.no_rtl else ' + rtl'})")


if __name__ == "__main__":
    main()
