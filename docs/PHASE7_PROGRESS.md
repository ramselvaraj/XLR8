# Phase 7 Progress

## Done

- `sw/apps/bench.c`: scalar C, NEON intrinsics and XLR8 implementations of ball (64/128/256),
  gradient and blur, with a per-frame CSV (total, prepare, submit, wait, copy-out, CYCLES,
  transactions, stalls) and CPU time from `getrusage`. Correctness against the scalar reference is
  checked before timing.
- `sw/apps/bench_numpy.py` (checked against the references by `tools/tests/test_bench_numpy.py`).
- `tools/gen_ball.py` and `sw/kernels/ball128.asm`, `ball256.asm` (checked by
  `tools/tests/test_ball_sizes.py`: ISA sim and RTL at 128, ISA sim at 256).
- `tools/board/run_bench.sh`, `tools/board/mk_bench_progs.py`, `tools/plot_bench.py`.
- `results/benchmarks.md`, `results/bench_tables.md`, `results/bench/` (CSVs, system info, charts).

## Result

The GPU is 16x to 218x slower than the ARM cores on every workload, as expected from a 50 MHz
design with one transaction in flight. Only blur is cheaper in CPU time on the GPU. See
`results/benchmarks.md`.

## Notes

- The ARM has no cpufreq driver, so there is no governor to pin; the CPU clock is fixed at
  650 MHz (`cpu_6or4x`) and recorded.
- The first draft of the breakdown chart labelled microseconds as milliseconds and showed nothing
  (the GPU is 99% of every frame); caught by looking at the render, replaced by the CPU-cost chart.
- Energy was not measured.
