# Phase 8: Optimization and Scale-Out

## Goal

Attack the bottlenecks Phase 7 measured. Each item is independent, gated by its measured
benefit, and keeps the golden-model tests exact.

## Candidate work, in recommended order

| # | Item | Why | Expected effect (estimate) |
|---|---|---|---|
| 1 | Kernel arguments in registers | ball does 5 loads per pixel for values that never change | ~6 to 1 transactions per pixel |
| 2 | Burst AXI in the bridge | one transaction per word wastes latency | large, depends on `mem_unit` |
| 3 | Coalescing `mem_unit` | lanes with consecutive addresses merge into one burst | up to LANES-fold fewer transfers |
| 4 | Parameterize `LANES` and `WARPS`, try 16 and 32 lanes | more parallel pixels | bounded by bus, LUT/DSP budget |
| 5 | Raise the clock | 50 MHz is conservative | check the worst path first |
| 6 | ISA additions: `SLT`/`SEL` or `MIN`/`MAX` | needed for circles with soft edges and Mandelbrot | enables new kernels |
| 7 | Pipelined instruction fetch | if BRAM fetch is needed for size or timing | timing |

### Item 1 detail: kernel arguments

Add `ARG0` and `ARG1` registers (already reserved at 0x3C and 0x40). The dispatcher preloads them
into two reserved registers (`r12`, `r13`) next to `r14`/`r15`. Document the new convention in
`GPU_ISA.md`. Kernels written before this change must still run (those registers were unused).
The ball kernel moves from five LDRs to arguments, and the parameter block shrinks.

### Item 6 detail: ISA additions

Any ISA change updates, in lockstep: decoder, ALU, `assemble.py`, `isa_sim.py`, `GPU_ISA.md`, and
the golden-model tests. Then add the new kernels (soft-edge circle, Mandelbrot) as stretch demos.

## Process

For each item: write the hypothesis, change one thing, run the full test suite, rerun Phase 7
benchmarks, keep or revert by the data. Record each in `docs/PHASE8_PROGRESS.md` and
`results/`.

## Exit criteria

- At least items 1 and 2 done and measured.
- Before and after numbers for every item attempted, including ones that did not help.
- All earlier tests still pass with exact output.
