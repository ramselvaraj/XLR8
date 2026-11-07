# Phase 3 Progress

## Done

- `fpga/pynq_z2/build.tcl`: PS7 (board preset), GP0 to `xlr8_top` control through an AXI
  interconnect, `xlr8_top` master to HP0 (32-bit), IRQ to `IRQ_F2P`, reset from `proc_sys_reset`.
  Options: `board_repo`, `until`, `fclk`, `slverr`, `tag`.
- Address map: registers at `0x4000_0000`, 8 KiB. The GPU master sees DDR at `0x0000_0000`,
  512 MiB.
- Bitstream, `.hwh` and `.xsa` produced. Timing met at 50 MHz, see
  `results/timing_summary_50mhz.md`.
- RTL change to make timing: sequential divider (`rtl/gpu/seq_div.sv`), `FAST_DIV` parameter in
  `alu`, `warp`, `simt_gpu`, `tb_gpu`. New `make build-seqdiv`, `make test-div`.

## Findings

- The combinational divider alone was a 100 ns path. Everything else fit 50 MHz.
- The reset-fanout violation seen in the first run (-1.6 ns on the async GPU reset) went away
  once the divider was fixed.
- LUT use is 58%, almost all register file. Clock headroom is small (critical path 18.5 ns).
- Left at 50 MHz as planned; raising the clock comes in Phase 8.

## Deviations

- The GPU RTL is no longer untouched: see `rtl/gpu/SOURCE.md`.
