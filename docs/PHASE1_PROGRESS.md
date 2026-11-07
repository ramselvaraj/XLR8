# Phase 1 Progress

## Done

- `sw/kernels/ball.asm` (29 instructions, r0 to r9), plus `gradient.asm` and `checker.asm`.
- `tools/ball_ref.py`: independent exact-integer reference, no assembler or ISA sim imports.
- `tools/animate_ref.py`: integer physics, 1/16 pixel units, shared with the later userspace app.
- `tools/run_ball.py`: renders through the ISA sim and the Verilated RTL and compares exactly.
- `tools/tests/test_ball.py` and `test_kernels.py`, wired into `make test-ball` and `make test`.
- `results/ball_kernel.md` with measured numbers.

## Result

All Phase 1 exit criteria met with no ISA change. Resolved the PLAN VERIFY items for `SUB`, `MUL`
and `SRL` (see `results/ball_kernel.md`).

## Deviations from the spec

- The kernel has a documented valid domain (|center| <= 16384, r2 <= 2^30) because a 32-bit
  `dist2` would otherwise wrap. The reference defines the true result; tests stay in the domain.
- RTL runs are one process per frame. The testbench loads one parameter block per run, so the
  fuzz test runs only 150 of its 1,000 cases on the RTL (the rest on the ISA sim).
