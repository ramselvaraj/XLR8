# Phase 3: Vivado Build for the PYNQ-Z2

## Goal

Produce a bitstream and hardware handoff (`.bit` and `.hwh`) of XLR8 on the Zynq-7020 with timing
met, built by a script anyone can rerun.

## Starting points

- Phase 2 `xlr8_top` and its AXI interfaces
- Existing PYNQ-Z2 project work: `../linux_projects/rv32-linux/fpga/pynq_z2/build.tcl` is a
  working reference for board setup in this repo family

## Tasks

1. Package `xlr8_top` as a Vivado IP, or instantiate it as a module reference in the block design.
2. Block design: `processing_system7` with the PYNQ-Z2 preset, `FCLK_CLK0` at 50 MHz, GP0 master
   to `xlr8_regs` through an AXI interconnect, `xlr8_axi_bridge` master to `S_AXI_HP0`, interrupt
   to `IRQ_F2P[0]`, reset from `proc_sys_reset`.
3. Address editor: fixed base for the register block, recorded in `docs/REGISTER_MAP.md`.
4. `fpga/pynq_z2/build.tcl`: project create, synth, implement, bitstream, export `.hwh`, all in
   batch mode.
5. Constraints: only the clock constraint the PS provides; no board pins used.
6. Reports to `results/`: utilization, timing summary, worst paths, clock report.
7. Confirm HP0 data width and AXI3 settings match the bridge.
8. Record whether the GPU's combinational instruction read maps to LUT RAM or BRAM, and its timing
   impact.

## Scope decisions

| Decision | Choice |
|---|---|
| Clock | 50 MHz first, raise only with margin |
| PL pins | none |
| IP delivery | module reference or packaged IP, whichever builds cleanly |
| Debug | add ILA only when something fails, as a separate build option |

## Exit criteria

- `build.tcl` runs from a clean tree and produces `.bit` and `.hwh`.
- Timing met: WNS and WHS non-negative, recorded in `results/timing_50mhz.rpt`.
- Utilization recorded in `results/utilization_50mhz.rpt`.
- No unconstrained paths and no critical warnings other than documented ones.

## Risks

- A long combinational path through the ALU divider can fail 50 MHz. Check the worst path before
  assuming margin.
- The combinational instruction fetch may need to change if it only fits as distributed RAM at a
  size that costs too many LUTs.

## Non-goals

No Linux, no driver. No clock above 50 MHz yet.
