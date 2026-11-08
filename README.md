# XLR8

**A custom SIMT GPU on FPGA fabric, exposed to Linux as a real device.**

*From RTL to `/dev/xlr8`.*

XLR8 takes the 8-lane SIMT GPU from [RAPTOR-SoC](../riscv/RAPTOR-SoC) and turns it into a
memory-mapped accelerator on a PYNQ-Z2. The ARM cores run Linux. A kernel driver exposes the
GPU as `/dev/xlr8`. A userspace app loads a GPU program, launches it, and reads back a rendered
frame from DDR. The flagship demo is a **bouncing ball** rendered on the GPU, one thread per
pixel, written out as an animation and checked against a Python golden model.

No HDMI. Output is a framebuffer in DDR that userspace saves as PNG/GIF and views from Jupyter.

## Status

Phases 0 to 8 are done and verified on the board: simulation, FPGA build (timing met at 50 MHz),
hardware bring-up, a Linux driver, a userspace renderer, benchmarks against the ARM cores, and
an 8x speedup from optimization. Phase 9 is narrowed to a V4L2 device (in progress). See [docs/PLAN.md](docs/PLAN.md) and the phase
documents; every number below is backed by a file in `results/`.

![ball rendered on the GPU](results/demo/ball.gif)

*120 frames rendered by the GPU in the FPGA, through `/dev/xlr8`, each checked pixel for pixel
against a CPU render.*

| Phase | Title | State |
|---|---|---|
| 0 | Import, baseline, tooling | done |
| 1 | Ball kernel and golden model in simulation | done |
| 2 | AXI wrapper (AXI4-Lite slave + AXI master bridge) | done |
| 3 | Vivado build for PYNQ-Z2 | done (50 MHz, WNS +0.971 ns) |
| 4 | Hardware bring-up from userspace (UIO / PYNQ MMIO) | done (1,000 frames exact on board) |
| 5 | Linux kernel driver | done (/dev/xlr8, 1,000 frames exact over interrupts) |
| 6 | Userspace library, renderer, animation | done (one command from cold boot to a verified GIF) |
| 7 | Benchmarks against the ARM cores | done (GPU 16x to 218x slower than the A9; see results/benchmarks.md) |
| 8 | Optimization and scale-out | done (ball 8.0x faster: arguments, posted writes; see results/optimization.md) |
| 9 | Extended goals | real-image blur through Linux done; V4L2 mem2mem device next. Skipped by choice: screen output, dma-buf export, RISC-V host, formal/UVM |
| 10 | Polish, demo, write-up | not started |

## Quick start

    make test                       # all simulation and host tests (needs verilator, python venv)
    make venv                       # once, for numpy and Pillow
    tools/board/demo.sh 120         # board: build, load, render, verify, fetch results/demo/*.gif
                                    # (SSH_ASKPASS must print the board password)

## Measured so far

| | |
|---|---|
| Timing, PYNQ-Z2 | met at 50 MHz, final build WNS +0.579 ns, WHS +0.051 ns (`results/timing_*_posted.rpt`, history in `results/optimization.md`) |
| Resources | 32.9k LUT (62%), 24 DSP, 0 BRAM (final build) |
| Ball frame, 64x64 | 52,741 cycles = 1.17 ms at 50 MHz after Phase 8 (9.4 ms before), 4,096 bus transactions |
| Bridge into ideal memory (sim) | 192,001 cycles; real DDR adds about 10 cycles per transaction |
| vs ARM (ball 64x64) | GPU 1.17 ms (9.4 ms before Phase 8); ARM scalar 0.051 ms, NEON 0.043 ms, NumPy 0.52 ms. GPU uses 1% of a core while running. |
| Real image | a photo blurred on the GPU through `/dev/xlr8`, 0 of 4,096 pixels differ from the CPU blur (`results/demo/blur_before_after.png`) |
| Driver | 1,000 frames exact over interrupts, 4 concurrent processes, SIGKILL mid-job, watchdog, 10,000 open/close without a leak |

## Layout

    docs/        plan, architecture, register map, phase specs, risks
    rtl/gpu/     vendored RAPTOR GPU (pinned revision)
    rtl/axi/     AXI4-Lite slave, AXI master bridge, program window
    rtl/top/     xlr8_top (the block-design IP wrapper)
    tb/          Verilator unit and system tests
    sw/kernels/  GPU assembly kernels (ball, gradient, checker, ...)
    sw/lib/      libxlr8 (userspace C library)
    sw/apps/     renderer and benchmark programs
    tools/       assembler, ISA simulator, golden models, frame diff
    driver/      Linux kernel module
    dts/         device-tree node / overlay
    fpga/        Vivado Tcl build for the PYNQ-Z2
    results/     measured numbers only (timing, utilization, benchmarks)

## Rule for claims

A number goes in this README or on a resume only if a file in `results/` backs it, produced by a
command recorded in the same folder. Estimates in the docs are labeled as estimates.
