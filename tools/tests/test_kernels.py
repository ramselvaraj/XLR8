#!/usr/bin/env python3
"""Smoke kernels (gradient, checker) vs independent references, ISA sim and RTL."""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import ball_ref  # noqa: E402
import run_ball  # noqa: E402

ROOT = run_ball.ROOT


def check_kernel(name, params, expected):
    k = run_ball.Ball(workdir=os.path.join(ROOT, "build", name),
                      kernel=os.path.join(ROOT, "sw", "kernels", f"{name}.asm"))
    block = list(params)

    for label, fn in (("isa", k.render_isa), ("rtl", k.render_rtl)):
        # Ball's loader expects a 5-word block; pad the unused words.
        got = fn(tuple(block + [0] * (5 - len(block))))
        d = run_ball.first_diff(got, expected)
        if d:
            sys.exit(f"FAIL {name} ({label}): pixel {d[0]} got {d[1]:08x} expected {d[2]:08x}")
    print(f"PASS {name}: isa + rtl exact")


def main():
    check_kernel("gradient", [], ball_ref.render_gradient())
    for a, b in ((0x00FFFFFF, 0x00000000), (0x00123456, 0x00FEDCBA)):
        check_kernel("checker", [a, b], ball_ref.render_checker(a, b))


if __name__ == "__main__":
    main()
