#!/usr/bin/env python3
"""driver/xlr8_blur_fw.h must match what the assembler produces, and the program must be exact."""
import os
import random
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.dirname(HERE))
import blur_ref  # noqa: E402
import gen_blur_fw  # noqa: E402
import isa_sim  # noqa: E402

text = open(os.path.join(ROOT, "driver", "xlr8_blur_fw.h")).read()
if text != gen_blur_fw.render():
    sys.exit("FAIL: driver/xlr8_blur_fw.h is stale; run tools/gen_blur_fw.py > driver/xlr8_blur_fw.h")
words = [int(x, 16) for x in re.findall(r"0x([0-9a-f]{4}),", text)]
prog, base2, t1, t2 = gen_blur_fw.build()
assert words == [w & 0xFFFF for w in prog]
rng = random.Random(5)
img = [rng.getrandbits(24) for _ in range(4096)]
data = [0] * 32768
data[0x2000:0x2000 + 4096] = img
isa_sim.run(prog[:base2], data, t1, 0x2000, 0x6000)
isa_sim.run(prog[base2:], data, t2, 0x2000, 0x6000)
if data[0x6000:0x6000 + 4096] != blur_ref.box_blur_clamped(img, 64, 64):
    sys.exit("FAIL: firmware program does not blur correctly")
print(f"PASS: driver/xlr8_blur_fw.h is current ({len(words)} instructions) and blurs exactly")
