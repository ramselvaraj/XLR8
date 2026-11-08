# Phase 2: AXI Wrapper

## Goal

Wrap the GPU with the control and memory interfaces it needs to live on a Zynq, and verify the
wrapper in simulation with hostile bus behavior.

## Modules

| Module | Job |
|---|---|
| `xlr8_regs` | AXI4-Lite slave: register map in PLAN section 4, shadowing, SLVERR rules |
| `xlr8_prog_ram` | 1024 x 16 instruction RAM, written through the program window, read combinationally by the GPU |
| `xlr8_axi_bridge` | GPU word bus to AXI3 master, base and limit, error capture |
| `xlr8_perf` | CYCLES, BUS_XACTS, BUS_STALLS, ERR_ADDR counters |
| `xlr8_top` | wires the above plus `simt_gpu`, one clock, active-low reset, IRQ out |

## Tasks

1. AXI4-Lite slave with independent AW/W/AR channels, byte strobes honored, one outstanding
   transaction.
2. Shadow configuration registers. START snapshots them. START while BUSY returns SLVERR.
3. Program window: two instructions per 32-bit write, SLVERR during BUSY.
4. Bridge: one outstanding transaction initially. Hold `mem_ready` low until the matching AXI
   response arrives. Add `MEM_BASE`, check `addr < MEM_LIMIT`, capture first bad address.
5. Bridge reads: `mem_rdata` must be valid in the cycle `mem_ready` is high, per the bus protocol.
6. DONE is raised only after the last write's B response. IRQ level follows `IRQ_STATUS & IRQ_EN`.
7. Perf counters, cleared on START.
8. Write a Verilator AXI memory model (slave) and an AXI-Lite master BFM with random stalls.
9. Lint-clean under `verilator --lint-only -Wall`.

## Scope decisions

| Decision | Choice |
|---|---|
| Data AXI flavor | AXI3, 32-bit, single beat (matches Zynq HP) |
| Bursts | none yet |
| Outstanding data transactions | 1 |
| Clock | one, no CDC |
| Reset | synchronous, active-low `aresetn`, as Vivado IP expects |

## Tests

- Register read/write/readback for every register, including byte strobes.
- START during BUSY gives SLVERR and does not change the running job.
- Config writes during BUSY do not alter the active job.
- Program window write then readback through the GPU fetch.
- Bridge with 0 to 50 random wait states on AR/R/AW/W/B, 1,000 jobs.
- Out-of-range address sets ERROR and ERR_ADDR, job still terminates.
- AXI error response (SLVERR/DECERR) from memory sets ERROR, job still terminates.
- Back-to-back jobs with different parameters.
- Reset during a running job, then a clean job.
- Full ball animation through the real wrapper, exact against golden model.

## Exit criteria

- All tests pass under random stalls.
- Ball frames exact through `xlr8_top`.
- `results/bridge_latency_sim.md` records cycles per word with zero stalls (the floor for `L`).
