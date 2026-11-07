# Phase 1: Ball Kernel and Golden Model in Simulation

## Goal

Render a bouncing ball on the unmodified GPU in Verilator, and prove every frame matches an
independent Python model. No AXI and no FPGA yet.

## Starting points

- Phase 0 tree, `tools/assemble.py`, `tools/isa_sim.py`, `tools/run_sim.py`
- `sw/kernels/blur.asm` for style, `docs/PLAN.md` section 6 for the kernel sketch

## Tasks

1. `tools/ball_ref.py`: pure-Python renderer. Takes `cx, cy, r2, ball, bg`, returns a 64x64
   frame of packed RGB. It must not import the assembler or the ISA simulator.
2. `sw/kernels/ball.asm`: the kernel from PLAN section 6. Parameters come from a block at SRC.
3. Resolve the VERIFY items: `SUB` wraparound, `MUL` of negatives, `SRL` shift amount, register
   reuse. Write a small directed test for each in `tb/unit/`.
4. `tools/animate_ref.py`: physics for a bouncing ball (position, velocity, wall bounce, integer
   fixed point). This is the single source of truth for per-frame parameters, later reused by the
   userspace app.
5. `tb/system/`: Verilator test that for each of N frames writes the parameter block, launches the
   GPU, and diffs the framebuffer against `ball_ref.py`.
6. Edge cases: ball clipped at each wall, radius 0, radius larger than the frame, center
   off-screen, exact-edge pixels.
7. Also write `gradient.asm` and `checker.asm` as simpler smoke kernels.
8. Count instructions and registers for `ball.asm`. Record in `results/ball_kernel.md`.

## Scope decisions

| Decision | Choice |
|---|---|
| GPU RTL | unmodified |
| Resolution | 64x64, width a power of two |
| Parameters | loaded with LDR from SRC (baseline; Phase 8 optimizes) |
| Comparison | exact equality, no tolerance |

## Tests

- 100 animation frames, all exact.
- Each edge case above, exact.
- ISA simulator and RTL agree on every frame.
- Random parameter fuzz: 1,000 random `(cx, cy, r2, colors)` tuples, exact.

## Exit criteria

- All tests pass in `make test`.
- `results/ball_kernel.md` states instruction count, registers used, and RTL cycles per frame.
- If the kernel does not fit the register budget or needs an instruction the ISA lacks, this is
  recorded and the ISA change is moved to Phase 8 with a workaround here.

## Non-goals

No ISA changes. No bridge. No board.
