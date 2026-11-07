#!/usr/bin/env python3
"""Assemble the GPU programs the benchmark needs into build/bench/*.hex.

blur64 is two programs back to back: the interior pass at instruction 0 and the border pass at
instruction BASE2 (loaded together, launched with prog_base 0 and BASE2).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import assemble  # noqa: E402

out = os.path.join(ROOT, "build", "bench")
os.makedirs(out, exist_ok=True)


def write(name, prog):
    with open(os.path.join(out, name), "w") as f:
        f.write("".join(f"{w & 0xFFFF:04x}\n" for w in prog))


for name, kernel in (("ball64.hex", "ball.asm"), ("ball128.hex", "ball128.asm"), ("ball256.hex", "ball256.asm"),
                     ("gradient64.hex", "gradient.asm")):
    prog, _ = assemble.assemble(open(os.path.join(ROOT, "sw", "kernels", kernel)).read())[:2]
    write(name, prog)

W = H = 64
p1, m1 = assemble.assemble(f".gen_blur {W} {H}\n.src 0x2000\n.dst 0x6000\n")[:2]
p2, m2 = assemble.assemble(f".gen_blur_border {W} {H}\n.src 0x2000\n.dst 0x6000\n")[:2]
assert (len(p1), m1["threads"], m2["threads"]) == (125, 3844, 252), (len(p1), m1["threads"], m2["threads"])
assert len(p1) + len(p2) <= 1024
write("blur64.hex", p1 + p2)
print(f"blur64: interior {len(p1)} instr at 0, border {len(p2)} instr at {len(p1)}; total {len(p1) + len(p2)}")
