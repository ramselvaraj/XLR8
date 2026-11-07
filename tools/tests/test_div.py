#!/usr/bin/env python3
"""DIV through the RTL with both dividers (FAST_DIV=1 combinational, FAST_DIV=0 sequential).

Operand pairs include zero divisors, divisors above 2^31, a < b, a == b, powers of two and random
32-bit values. Result must equal Python unsigned a // b (0 when b == 0).
"""
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.dirname(HERE))

import assemble  # noqa: E402
import isa_sim   # noqa: E402

M = 0xFFFFFFFF


def pairs(n=256, seed=0xD17):
    rng = random.Random(seed)
    fixed = [(0, 0), (5, 0), (M, 0), (0, 1), (M, 1), (M, M), (M, M - 1), (1, M), (M, 2), (M, 3),
             (0x80000000, 0x80000000), (0x80000000, 0x80000001), (0x80000000, 0x7FFFFFFF),
             (0xFFFFFFFE, 0x80000000), (0x7FFFFFFF, 0x80000001), (100, 7), (9, 9), (8, 9), (1 << 31, 1),
             (1 << 31, 2), (12345678, 1234), (0xDEADBEEF, 0xBEEF), (0xDEADBEEF, 0xDEADBEEF)]
    out = list(fixed)
    while len(out) < n:
        mode = rng.randrange(4)
        a = rng.getrandbits(32)
        b = [rng.getrandbits(32), rng.getrandbits(16) + 1, 1 << rng.randrange(32),
             rng.getrandbits(32) | 0x80000000][mode]
        out.append((a, b))
    return out[:n]


def run(binary, prs, workdir):
    os.makedirs(workdir, exist_ok=True)
    prog, meta = assemble.assemble(open(os.path.join(ROOT, "sw/kernels/divtest.asm")).read())[:2]
    ph, fh, oh = (os.path.join(workdir, n) for n in ("prog.hex", "frame.hex", "out.hex"))
    open(ph, "w").write("".join(f"{w & 0xFFFF:04x}\n" for w in prog))
    flat = [v for pr in prs for v in pr]
    open(fh, "w").write("".join(f"{v:08x}\n" for v in flat))
    subprocess.run([binary, f"+frame={fh}", f"+prog={ph}", f"+out={oh}", f"+count={len(prs)}",
                    f"+src={meta['src']}", f"+dst={meta['dst']}"], check=True, cwd=workdir,
                   stdout=subprocess.DEVNULL)
    out = isa_sim.read_hex_words(oh)
    # ISA simulator as a second opinion
    data = [0] * 32768
    data[meta["src"]:meta["src"] + len(flat)] = flat
    isa_sim.run(prog, data, len(prs), meta["src"], meta["dst"])
    return out[meta["dst"]:meta["dst"] + len(prs)], data[meta["dst"]:meta["dst"] + len(prs)], meta


def main():
    prs = pairs()
    fails = 0
    for name, binary in (("FAST_DIV=1", "build/obj/Vtb_gpu"), ("FAST_DIV=0", "build/obj_seqdiv/Vtb_gpu")):
        binary = os.path.join(ROOT, binary)
        if not os.path.exists(binary):
            sys.exit(f"missing {binary}; run `make build build-seqdiv`")
        rtl, isa, _ = run(binary, prs, os.path.join(ROOT, "build", "div_" + name[-1]))
        for i, (a, b) in enumerate(prs):
            exp = (a // b) if b else 0
            for who, got in (("rtl", rtl[i]), ("isa", isa[i])):
                if got != exp:
                    fails += 1
                    if fails < 6:
                        print(f"FAIL {name} {who}: {a:#x} / {b:#x} = {got:#x}, expected {exp:#x}")
    if fails:
        sys.exit(f"FAIL: {fails} mismatches")
    print(f"PASS: {len(prs)} divisions exact (rtl FAST_DIV=1 and 0, plus isa_sim)")


if __name__ == "__main__":
    main()
