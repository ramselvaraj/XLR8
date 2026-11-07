# Phase 2 Progress

## Done

- `rtl/axi/xlr8_regs.sv`: AXI4-Lite slave, shadowed configuration, SLVERR rules, program window,
  W1C interrupt status, soft reset with state clearing.
- `rtl/axi/xlr8_prog_ram.sv`: 1024 x 16 instruction RAM, byte-writable, combinational fetch.
- `rtl/axi/xlr8_axi_bridge.sv`: GPU word bus to AXI3 master, base and limit, error capture,
  drain on soft reset.
- `rtl/axi/xlr8_perf.sv`: CYCLES, BUS_XACTS, BUS_STALLS.
- `rtl/top/xlr8_top.sv`: wires the above to `simt_gpu` (with `LOCK_MEMORY_OWNER=1`, required for
  multi-cycle memory).
- `tb/system/axi_mem_model.sv` (random stalls, error injection, master protocol checks) and
  `tb/system/tb_xlr8.sv` (AXI4-Lite BFM, 9 tests plus ball mode).
- `make lint` clean for the GPU alone and for `xlr8_top`. `make test-xlr8` and `make test-ball-axi`
  pass.
- `results/bridge_latency_sim.md`.

## Tests (all pass)

regs, prog, job, busy, oor, axierr, b2b, reset, irq, run at stall 0/25/60/90% with two seeds
(`make test-xlr8`), plus 100 ball frames exact through the wrapper at 0%, 50% and 90% stalls
(`make test-ball-axi`). The testbench also asserts: no AXI protocol violations, the GPU holds its
bus request until ready, CYCLES equals an independent start-to-done count, BUS_XACTS equals the
AXI transactions seen by the memory model, irq never rises before DONE or ERROR.

## Mutation checks

Removing the range check, allowing START while BUSY, and making DONE non-sticky are each caught.
Soft-reset safety has two independent protections: the bridge discards an aborted transaction's
response, and START is refused until the bridge is idle. Removing either one alone is not
observable (the other covers it). Removing both makes the post-reset job read stale data and the
`reset` test fails, so the test is sensitive to the hazard.

## Findings worth remembering

- `LOCK_MEMORY_OWNER=1` is required, otherwise the scheduler can switch warps while a transaction
  is outstanding.
- `ERR_ADDR` is the first illegal access in time, not the lowest address: either warp can go
  first depending on scheduler state. The tests use an independent monitor for the expectation.
- A program memory of all zeros never ends (NOPs, no RET). Soft reset recovers it (tested).
- Writing CTRL without bit2 clears `IRQ_EN`; the driver must write START and IRQ_EN together.
- AXI error responses on the Zynq GP port may abort the ARM (see PLAN); `SLVERR_EN` parameter
  exists for that, to be decided on the board in Phase 4/5.

## Deviations from the spec

- Program window is 0x1000-0x17FF and read/write (spec said 0x1000-0x1FFF, write only).
- `STATUS.BAD_ACCESS` added.
