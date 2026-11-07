# Phase 0 Progress

## Done

- GPU RTL, unit tests, system testbench, tools, and kernels copied into this repo.
- `rtl/gpu/SOURCE.md` records the source commit `c96e6e9`.
- `Makefile` with `lint`, `test-unit`, `test-py`, `test-gpu`, `test`.
- `make lint`: clean.
- `make test-gpu`: passes. All 7 unit testbenches, both Python tests, brighten, interior blur
  (3844 threads), and full-frame clamped blur at 16x16, 32x32 and 64x64, all with 0 mismatches.
- `docs/TOOLCHAIN.md` written with verified and open items.

## Observation worth keeping

Full-frame 64x64 blur takes 317,207 cycles in simulation with a zero-latency, single-cycle bus.
That is the floor for that kernel. Real AXI latency will multiply the bus-bound part.

## Open (blocks later phases, not Phase 1 or 2)

- Where Vivado runs and its version.
- PYNQ image version and kernel version.
- ARM cross compiler or native build on the board.
- Board access method.
