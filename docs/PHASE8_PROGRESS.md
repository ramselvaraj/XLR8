# Phase 8 Progress

Each step: hypothesis, one change, full test suite, FPGA build with timing closed, hardware
benchmark, and the result recorded whether or not it helped. Details and numbers:
`results/optimization.md`.

## Done

1. **Kernel arguments** (`ARG0..ARG5` preloaded into `r8..r13`): ball 9.37 -> 1.99 ms (4.7x).
2. **Posted writes** (bridge stores complete on address/data acceptance, reads and `DONE` wait
   for write responses): 1.99 -> 1.17 ms (1.7x), 8.0x in total.
3. **Divide-free blur** (`.gen_blur W H nodiv`: multiply and shift for the divisions): 3% on
   blur64 on top of posted writes; blur is bound by its nine loads.

## Verification added

- ISA simulator, RTL and AXI wrapper tests for the argument kernels (`NARGS=6` build, ball animation,
  edge cases and fuzz exact), register tests for `ARG0..ARG5`.
- AXI memory model rebuilt for posted writes: several outstanding writes, in-order responses,
  writes committed to memory only when their response is issued, and a check that the bridge
  never issues a read with a write outstanding.
- `raw.asm` (store, load back, store, load back) and a monitor that no write is outstanding when
  `DONE` rises.
- Mutation checks: dropping the read-after-write wait is caught (745 failure lines over 6 runs),
  dropping the `DONE` drain gate is caught (6 of 6 runs, but only after adding the monitor: the
  first tests missed it because software polling reads `BUSY`, which already includes the drain,
  while an interrupt-driven driver does not), and a wrong posted-write error address is caught.
- Exhaustive proof for the multiply-shift divisions (`x//9 == (x*7282)>>16` for 0..2295, the row-width
  divisor over all thread indices) and the divide-free blur is exact on 5 sizes x 2 images.
- Driver ABI v2 (arguments in `SUBMIT`), library `xlr8_submit_args`, Python binding; 1,000 frames
  and 5,000 open/close cycles pass on the posted-writes bitstream.

## Bugs found

- Kernel build on the board uses an older C dialect: `for (int k ...)` is not allowed in the
  driver.
- A test treating offset `0x44` as reserved broke when it became `ARG2`.

## Not done (see results/optimization.md for why)

Bursts and coalescing for reads, more lanes, a higher clock, ISA additions, a pipelined instruction
fetch. The profile after step 2 says the next gain for the ball is in the instruction pipeline; for
blur it is in the loads.
