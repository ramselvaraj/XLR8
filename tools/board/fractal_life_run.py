#!/usr/bin/env python3
"""Runs ON the board: render a Mandelbrot view and a Game of Life animation on the GPU through
/dev/xlr8 (sw/lib/xlr8.py). Writes raw words for the host to verify and turn into images.

    python3 fractal_life_run.py mandelbrot128.hex life.hex outdir
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import xlr8  # noqa: E402

man_hex, life_hex, out = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(out, exist_ok=True)
W = 128
VIEWS = {"full": (-9011, -6144, 96), "zoom": (-3840, -358, 12)}
GUN = [(1, 5), (1, 6), (2, 5), (2, 6), (11, 5), (11, 6), (11, 7), (12, 4), (12, 8), (13, 3), (13, 9), (14, 3),
       (14, 9), (15, 6), (16, 4), (16, 8), (17, 5), (17, 6), (17, 7), (18, 6), (21, 3), (21, 4), (21, 5), (22, 3),
       (22, 4), (22, 5), (23, 2), (23, 6), (25, 1), (25, 2), (25, 6), (25, 7), (35, 3), (35, 4), (36, 3), (36, 4)]

with xlr8.Device() as gpu:
    print(gpu.info())
    gpu.alloc(0x40000)

    # ---- Mandelbrot
    gpu.load_file(man_hex)
    for name, (x0, y0, step) in VIEWS.items():
        t0 = time.time()
        res = gpu.run(threads=W * W, src=0, dst=0x2000, args=[x0 & 0xFFFFFFFF, y0 & 0xFFFFFFFF, step])
        dt = time.time() - t0
        assert res.ok, res
        open(f"{out}/mandel_{name}.raw", "wb").write(gpu.words[0x2000:0x2000 + W * W].tobytes())
        print(f"mandelbrot {name}: {dt * 1000:.1f} ms wall, CYCLES {res.cycles} ({res.cycles * 20e-6:.1f} ms at 50 MHz), xacts {res.xacts}")

    # ---- Game of Life: the GPU computes a generation, the host swaps source and destination
    gpu.load_file(life_hex)
    A, B = 0x2000, 0x6000
    for i in range(4096):
        gpu.words[A + i] = 0
    for x, y in GUN:
        gpu.words[A + ((y + 4) % 64) * 64 + (x + 4) % 64] = 1
    frames = [gpu.words[A:A + 4096].tobytes()]
    t0 = time.time()
    cyc = 0
    gens = 150
    src, dst = A, B
    for _ in range(gens):
        res = gpu.run(threads=4096, src=src, dst=dst)
        assert res.ok, res
        cyc += res.cycles
        frames.append(gpu.words[dst:dst + 4096].tobytes())
        src, dst = dst, src
    dt = time.time() - t0
    open(f"{out}/life_frames.raw", "wb").write(b"".join(frames))
    print(f"life: {gens} generations in {dt:.2f} s wall ({gens / dt:.0f} gen/s), mean CYCLES {cyc // gens} "
          f"({cyc / gens * 20e-6:.2f} ms at 50 MHz)")
