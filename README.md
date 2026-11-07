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

Planning. Nothing here is built yet. See [docs/PLAN.md](docs/PLAN.md) and the phase documents.

| Phase | Title | State |
|---|---|---|
| 0 | Import, baseline, tooling | GPU imported, tests pass; toolchain items open |
| 1 | Ball kernel and golden model in simulation | done |
| 2 | AXI wrapper (AXI4-Lite slave + AXI master bridge) | done |
| 3 | Vivado build for PYNQ-Z2 | done (50 MHz, WNS +0.971 ns) |
| 4 | Hardware bring-up from userspace (UIO / PYNQ MMIO) | not started |
| 5 | Linux kernel driver | not started |
| 6 | Userspace library, renderer, animation | not started |
| 7 | Benchmarks against the ARM cores | not started |
| 8 | Optimization and scale-out | not started |
| 9 | Screen output, V4L2, dma-buf, RISC-V host, formal/UVM (all committed scope) | not started |
| 10 | Polish, demo, write-up | not started |

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
