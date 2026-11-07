# Phase 7: Benchmarks Against the ARM Cores

## Goal

Measure what the GPU actually buys, and report it honestly, including if it loses.

## Method

Same workload, same parameters, same output, five implementations:

| Impl | Description |
|---|---|
| ARM scalar C | plain loop, `-O2` |
| ARM NEON | intrinsics or `-O3 -ftree-vectorize` verified in the disassembly |
| NumPy | vectorized |
| XLR8 baseline | Phase 6 kernel, 6 transactions per pixel |
| XLR8 tuned | after Phase 8 (rerun then) |

Workloads: ball (64x64), then larger frames if the kernel and memory allow, gradient, and the
3x3 blur kernel carried over from RAPTOR.

## Measurements

- Frame time: median, p5, p95 over at least 1,000 frames, warm.
- Split XLR8 time into: ioctl overhead, GPU job, interrupt wakeup, copy-out.
- GPU `CYCLES`, `BUS_XACTS`, `BUS_STALLS`, derived `L`.
- ARM CPU usage during the run.
- Resource and timing from Phase 3 for context.
- Energy if a USB power meter is available; otherwise omit.

## Tasks

1. `sw/apps/bench` with one flag per implementation and CSV output.
2. `tools/plot_bench.py` producing figures from the CSVs.
3. Write `results/benchmarks.md` with the table, the commands, board image version, clock, and
   date.
4. Write a short analysis: where time goes, what bounds it, what Phase 8 should attack.

## Rules

- No number in the README or resume without a CSV behind it.
- Report losses. A GPU slower than NEON at 64x64 is an expected, explainable result.
- Pin CPU frequency governor and record it.

## Exit criteria

- `results/benchmarks.md` with reproducible commands and raw CSVs.
- A written explanation of the time breakdown.
