#!/usr/bin/env python3
"""NumPy versions of the benchmark workloads. Same CSV as bench.c (no GPU columns).

    python bench_numpy.py ball64 [frames] [warmup]
"""
import resource
import sys
import time

import numpy as np

BALL, BG = 0x00FF8000, 0x00101830
W = {"ball64": 64, "ball128": 128, "ball256": 256, "gradient64": 64, "blur64": 64}


def anim(w):
    x, y, vx, vy = (w * 10 // 64) * 16, (w * 14 // 64) * 16, 21 * w // 64, 13 * w // 64
    r = w // 9
    lo, hi = r * 16, (w - 1 - r) * 16
    while True:
        yield x >> 4, y >> 4, r * r
        x += vx; y += vy
        if x < lo: x, vx = 2 * lo - x, -vx
        elif x > hi: x, vx = 2 * hi - x, -vx
        if y < lo: y, vy = 2 * lo - y, -vy
        elif y > hi: y, vy = 2 * hi - y, -vy


def make(name):
    w = W[name]
    xs = np.arange(w, dtype=np.int32)
    if name.startswith("ball"):
        def f(cx, cy, r2):
            dx = (xs - cx)[None, :]
            dy = (xs - cy)[:, None]
            return np.where(dx * dx + dy * dy <= r2, np.uint32(BALL), np.uint32(BG)).astype(np.uint32)
        return f
    if name.startswith("gradient"):
        g = ((xs.astype(np.uint32)[None, :] * 4) << 16) | ((xs.astype(np.uint32)[:, None] * 4) << 8) | 0x80
        return lambda cx, cy, r2: g.copy()
    ys = np.arange(w)
    img = (((ys[None, :] * 7 + 1) & 0xFF) << 16) | (((ys[:, None] * 5 + 3) & 0xFF) << 8) | ((ys[None, :] * 3 + ys[:, None] * 11) & 0xFF)
    img = img.astype(np.uint32)
    ix = np.clip(np.arange(-1, w + 1), 0, w - 1)

    def blur(cx, cy, r2):
        p = img[np.ix_(ix, ix)]
        out = np.zeros((w, w), dtype=np.uint32)
        for shift in (16, 8, 0):
            c = ((p >> shift) & 0xFF).astype(np.uint32)
            s = sum(c[dy:dy + w, dx:dx + w] for dy in range(3) for dx in range(3))
            out |= (s // 9) << shift
        return out
    return blur


def main():
    name = sys.argv[1]
    frames = int(sys.argv[2]) if len(sys.argv) > 2 else 1000
    warm = int(sys.argv[3]) if len(sys.argv) > 3 else 100
    f = make(name)
    g = anim(W[name])
    print("impl,workload,frame,total_ns,prep_ns,submit_ns,wait_ns,copy_ns,gpu_cycles,xacts,stalls")
    r0, w0 = resource.getrusage(resource.RUSAGE_SELF), time.monotonic()
    for n in range(-warm, frames):
        cx, cy, r2 = next(g)
        t0 = time.perf_counter_ns()
        f(cx, cy, r2)
        t1 = time.perf_counter_ns()
        if n >= 0:
            print(f"numpy,{name},{n},{t1 - t0},0,0,0,0,0,0,0")
    r1, w1 = resource.getrusage(resource.RUSAGE_SELF), time.monotonic()
    print(f"# cpu_user_ms={(r1.ru_utime - r0.ru_utime) * 1e3:.1f} cpu_sys_ms={(r1.ru_stime - r0.ru_stime) * 1e3:.1f} "
          f"wall_ms={(w1 - w0) * 1e3:.1f} frames={frames + warm} (including {warm} warmup)")


if __name__ == "__main__":
    main()
