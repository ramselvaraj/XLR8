#!/usr/bin/env python3
"""Generated ball kernels (128x128 on ISA sim and RTL, 256x256 on the ISA sim) vs ball_ref."""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.dirname(HERE))

import assemble  # noqa: E402
import ball_ref  # noqa: E402
import isa_sim   # noqa: E402

BIN = os.path.join(ROOT, "build", "obj", "Vtb_gpu")
CASES = [(40, 70, 900, 0x00FF8000, 0x00101830), (-5, 20, 400, 1, 2), (200, 200, 6000, 0xABCDEF, 0x123456), (0, 0, 0, 7, 9)]


def run(w, params, rtl):
    prog, meta = assemble.assemble(open(os.path.join(ROOT, f"sw/kernels/ball{w}.asm")).read())[:2]
    block = ball_ref.param_block(*params)
    words = 1 << 17
    data = [0] * words
    data[meta["src"]:meta["src"] + 5] = block
    if not rtl:
        isa_sim.run(prog, data, meta["threads"], meta["src"], meta["dst"])
        return data[meta["dst"]:meta["dst"] + w * w]
    wd = os.path.join(ROOT, "build", f"ballsz{w}")
    os.makedirs(wd, exist_ok=True)
    ph, fh, oh = (os.path.join(wd, n) for n in ("p.hex", "f.hex", "o.hex"))
    open(ph, "w").write("".join(f"{x & 0xFFFF:04x}\n" for x in prog))
    open(fh, "w").write("".join(f"{x:08x}\n" for x in block))
    subprocess.run([BIN, f"+frame={fh}", f"+prog={ph}", f"+out={oh}", f"+count={meta['threads']}",
                    f"+src={meta['src']}", f"+dst={meta['dst']}"], check=True, cwd=wd, stdout=subprocess.DEVNULL)
    out = isa_sim.read_hex_words(oh)
    return out[meta["dst"]:meta["dst"] + w * w]


fails = 0
for w, rtl in ((128, True), (256, False)):
    for p in CASES:
        got = run(w, p, rtl)
        ref = ball_ref.render(*p, w=w, h=w)
        if got != ref:
            i = next(i for i in range(len(ref)) if got[i] != ref[i])
            print(f"FAIL {w}x{w} {p}: pixel {i} got {got[i]:x} expected {ref[i]:x}")
            fails += 1
if fails:
    sys.exit("FAIL")
print("PASS: generated ball kernels exact (128x128 ISA sim + RTL, 256x256 ISA sim)")
