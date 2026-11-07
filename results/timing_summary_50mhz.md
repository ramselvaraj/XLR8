# XLR8 on PYNQ-Z2, 50 MHz (Phase 3)

Vivado 2026.1, `xc7z020clg400-1`, post-route, `fpga/pynq_z2/build.tcl until bit`, 2026-11-07.
Raw reports: `timing_50mhz.rpt`, `utilization_50mhz.rpt`, `worst_paths_50mhz.rpt`,
`clocks_50mhz.rpt`, `drc_50mhz.rpt`, `methodology_50mhz.rpt`.

| Metric | Value |
|---|---|
| WNS (setup) | +0.971 ns |
| WHS (hold) | +0.021 ns |
| TNS / failing endpoints | 0 / 0 of 53,511 |
| Unconstrained paths | none |
| Critical path | 18.5 ns, 16 levels (2 DSP48E1, 5 CARRY4), about 54 MHz as built |
| Slice LUTs | 30,982 of 53,200 (58.2%) |
| Slice registers | 23,420 of 106,400 (22.0%) |
| DSP48 | 24 of 220 |
| Block RAM | 0 of 140 |
| Critical warnings | only the 4 board-preset `PSU-*` DDR skew notes (same as rv32-linux) |

## What it took

The first build failed timing at -80.5 ns: the GPU ALU's combinational 32-bit unsigned divide is a
282-stage carry chain (100 ns). The divider is now a 32-cycle sequential unit (`seq_div`, selected by
`FAST_DIV=0` in `xlr8_top`; the default `FAST_DIV=1` keeps the original behavior for the RAPTOR
tests). A warp running DIV leaves the scheduler so the other warp keeps the bus.
Results are identical: `make test-div` checks 256 operand pairs (zero divisors, divisors above 2^31,
powers of two, random) on both dividers against Python, and the blur kernels (which use DIV) pass
on both.

## Resource note for Phase 8

58% of the LUTs go to the register file: 2 warps x 4 lanes x 16 registers x 32 bits with async
reset cannot map to RAM, and has three read muxes per lane. Doubling the lanes will not fit
without reworking the register file.
