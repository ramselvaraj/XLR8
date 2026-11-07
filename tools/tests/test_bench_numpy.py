#!/usr/bin/env python3
"""The NumPy benchmark kernels must equal the independent references exactly."""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "sw", "apps"))

import numpy as np  # noqa: E402
import ball_ref     # noqa: E402
import blur_ref     # noqa: E402
import bench_numpy as b  # noqa: E402

fails = 0
for name in ("ball64", "ball128", "ball256"):
    w = b.W[name]
    f = b.make(name)
    g = b.anim(w)
    for _ in range(12):
        cx, cy, r2 = next(g)
        got = f(cx, cy, r2).ravel().tolist()
        ref = ball_ref.render(cx, cy, r2, b.BALL, b.BG, w=w, h=w)
        fails += got != ref
got = b.make("gradient64")(0, 0, 0).ravel().tolist()
fails += got != ball_ref.render_gradient()
img = [(((x * 7 + 1) & 0xFF) << 16) | (((y * 5 + 3) & 0xFF) << 8) | ((x * 3 + y * 11) & 0xFF) for y in range(64) for x in range(64)]
got = b.make("blur64")(0, 0, 0).ravel().tolist()
fails += got != blur_ref.box_blur_clamped(img, 64, 64)
if fails:
    sys.exit(f"FAIL: {fails} numpy kernels differ from the references")
print("PASS: NumPy kernels (ball 64/128/256, gradient, blur) exact vs the references")
