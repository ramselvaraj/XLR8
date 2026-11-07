# Ball kernel (Phase 1)

Produced 2026-11-07 by `make test-ball`, Verilator 5.052, RTL unmodified from RAPTOR `c96e6e9`.

| Metric | Value |
|---|---|
| Instructions | 29 (`sw/kernels/ball.asm`) |
| Registers used | r0 to r9 (r0 tid, r14 SRC, r15 DST fixed) |
| Threads | 4096 (64x64) |
| Bus transactions per pixel | 6 (5 LDR + 1 STR) |
| RTL cycles per frame, single-cycle bus | 91,143 (testbench total, includes about 5 cycles of reset and launch) |
| Valid domain | cx, cy in [-16384, 16383], r2 <= 2^30 |

91,143 cycles over 4096 pixels is about 22 cycles per pixel with a zero-latency bus. That is the
floor. Real AXI latency adds to the 6 serialized transactions per pixel.

## Verification

`make test-ball` (about 60 s):

- 100 animation frames, ISA sim and RTL, exact.
- 19 edge cases (walls, corners, radius 0 and 1, exact edge, radius larger than the frame,
  off-screen centers, negative centers, domain extremes), ISA sim and RTL, exact.
- 1,000 random parameter sets on the ISA sim, 150 of them also on the RTL, exact.
- Gradient and checker kernels, ISA sim and RTL, exact.
- Mutation check: changing the sign-extract shift from 31 to 30 is detected immediately.

The reference (`tools/ball_ref.py`) uses exact integer math and imports neither the assembler nor
the ISA simulator.

## Resolved VERIFY items from PLAN.md section 6

- `SUB` wraps modulo 2^32, so negative `dx` works.
- `MUL` returns the low 32 bits, so squaring negative values is correct in the valid domain.
- `SRL` shifts by `rs2[4:0]`; `SRL` by 31 returns the sign bit.
- Reusing one scratch register for `CONST` then `LDR` is safe: a warp executes in order.
- No ISA change is needed for the ball kernel.
