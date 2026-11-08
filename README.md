<p align="center">
  <img src="docs/assets/xlr8-banner.png" alt="XLR8: create a GPU, control it from Linux" width="100%">
</p>

# XLR8

**A custom SIMT GPU on FPGA fabric, exposed to Linux as a real device.**

*From RTL to `/dev/xlr8`.*

XLR8 takes the 8-lane SIMT GPU from [RAPTOR-SoC](../riscv/RAPTOR-SoC) and turns it into a
memory-mapped accelerator on a PYNQ-Z2. The ARM cores run Linux, a kernel driver exposes the GPU as
`/dev/xlr8` (and as a standard V4L2 video device), and a userspace library loads a GPU program,
launches one thread per pixel, and reads the finished frame back from DDR.

Everything below was rendered by the GPU in the FPGA and checked pixel for pixel against a
reference.

## Gallery

| Bouncing ball, 120 frames | Conway's Game of Life, glider gun |
|---|---|
| <img src="results/demo/ball.gif" width="320"> | <img src="results/demo/life.gif" width="320"> |

| Mandelbrot, 128x128 | Zoomed Mandelbrot |
|---|---|
| <img src="results/demo/mandelbrot_full.png" width="320"> | <img src="results/demo/mandelbrot_zoom.png" width="320"> |

| Photo blurred on the GPU (before / after) |
|---|
| <img src="results/demo/blur_before_after.png" width="480"> |

Kernels and numbers: [results/fractal_life.md](results/fractal_life.md).

## How it fits together

    userspace app / any V4L2 program
            |  ioctl / mmap
       /dev/xlr8, /dev/video0         Linux driver: one job at a time, IRQ-driven,
            |                         watchdog, DMA buffer per client
      AXI4-Lite control slave         registers, program RAM, perf counters
            |
       SIMT GPU (2 warps x 4 lanes)   16-bit ISA, one thread per pixel
            |
      AXI master bridge  ->  HP0  ->  DDR framebuffer

The GPU program is loaded at run time through the program window, so the same bitstream runs the
ball, the blur, Mandelbrot and Life. Details: [docs/PLAN.md](docs/PLAN.md) and
[docs/REGISTER_MAP.md](docs/REGISTER_MAP.md).

## Numbers

| | |
|---|---|
| Timing, PYNQ-Z2 | met at 50 MHz, WNS +0.579 ns, WHS +0.051 ns (`results/timing_*_posted.rpt`) |
| Resources | 32.9k LUT (62%), 24 DSP, 0 BRAM |
| Ball frame, 64x64 | 1.17 ms at 50 MHz, 8x faster than the first version (9.4 ms), 4,096 bus transactions |
| vs ARM (ball 64x64) | ARM scalar 0.051 ms, NEON 0.043 ms, NumPy 0.52 ms. The GPU uses 1% of a core while running. |
| Mandelbrot 128x128 | 108.6 ms per frame, all 16,384 pixels identical to the reference |
| Game of Life 64x64 | 65 generations/s, 151 of 151 generations identical |
| V4L2 | `/dev/video0` blurs 64x64 frames at 53.7 frames/s, every frame exact (`results/v4l2.md`) |
| Real image | a photo blurred through `/dev/xlr8`, 0 of 4,096 pixels differ from the CPU blur |
| Driver | 1,000 frames exact over interrupts, 4 concurrent processes, SIGKILL mid-job, watchdog, 10,000 open/close without a leak |

Benchmarks: [results/benchmarks.md](results/benchmarks.md). Optimization history:
[results/optimization.md](results/optimization.md).

## Quick start

    make venv                       # once, for numpy and Pillow
    make test                       # all simulation and host tests (needs verilator)
    tools/board/demo.sh 120         # board: build, load, render, verify, fetch results/demo/*.gif
                                    # (SSH_ASKPASS must print the board password)

## Layout

    docs/        plan, architecture, register map, phase specs and progress notes
    rtl/gpu/     vendored RAPTOR GPU (pinned revision)
    rtl/axi/     AXI4-Lite slave, AXI master bridge, program window
    rtl/top/     xlr8_top (the block-design IP wrapper)
    tb/          Verilator unit and system tests
    sw/kernels/  GPU assembly kernels (ball, blur, mandelbrot, life, ...)
    sw/lib/      libxlr8 (userspace C library and Python binding)
    sw/apps/     renderer and benchmark programs
    tools/       assembler, ISA simulator, golden models, board scripts
    driver/      Linux kernel modules (xlr8, xlr8_v4l2)
    dts/         device-tree overlay
    fpga/        Vivado Tcl build for the PYNQ-Z2
    results/     measured numbers only (timing, utilization, benchmarks)

## Rule for claims

A number goes in this README or on a resume only if a file in `results/` backs it, produced by a
command recorded in the same folder. Estimates in the docs are labeled as estimates.
