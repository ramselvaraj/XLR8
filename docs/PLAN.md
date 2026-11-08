# XLR8 Master Plan

Status: plan only. Estimates are labeled. Anything marked VERIFY must be checked before it is
relied on.

## 1. Goal

Run the RAPTOR SIMT GPU in the programmable logic of a Zynq-7020 (PYNQ-Z2) and make it a real
Linux device. A userspace program renders frames of a bouncing ball on the GPU. Output matches a
Python golden model bit for bit.

### What "done" means

1. The GPU bitstream builds for the PYNQ-Z2 and meets timing at the target clock.
2. A kernel module binds to a device-tree node and creates `/dev/xlr8`.
3. A userspace renderer loads a GPU program, launches it, and receives a frame.
4. N frames of the ball animation match the golden model exactly.
5. Frame time, resource use, and timing are measured and recorded in `results/`.
6. The same render on the ARM cores is measured as a baseline.


## 2. Starting point (verified against the RAPTOR-SoC tree)

| Fact | Source |
|---|---|
| GPU top is `simt_gpu`, parameters `WARPS=2`, `LANES=4`, `PC_W=16` | `simt_gpu/rtl/simt_gpu.sv` |
| Launch inputs: `start`, `thread_count`, `src_addr`, `dst_addr`; outputs `busy`, `done` | same |
| Data bus: `mem_req/we/addr/wdata/rdata/ready`, 32-bit word addresses, ready may take many cycles | `docs/BUS_PROTOCOL.md` |
| Instruction port: `imem_addr[15:0]` in, `imem_rdata[15:0]` back, combinational | `simt_gpu.sv` |
| 16 registers per lane, `r0`=tid, `r14`=SRC, `r15`=DST, `r1-r13` general | `docs/GPU_ISA.md` |
| Ops: ADD CONST SUB LDR STR RET MUL DIV AND OR XOR SLL SRL CMP BRnzp | `docs/GPU_ISA.md` |
| Branches are uniform only; no per-lane divergence | `docs/GPU_ISA.md` |
| `mem_unit` walks lanes one at a time: one bus transfer per active lane per LDR/STR | `mem_unit.sv` |
| Existing tools: `assemble.py`, `isa_sim.py`, `blur_ref.py`, `run_sim.py` | `simt_gpu/tools/` |

The serialized `mem_unit` matters most for performance. Every pixel costs one bus transaction per
LDR and one per STR, and each transaction will cross AXI to DDR.

## 3. System architecture

```
 Linux userspace            libxlr8 + renderer app
        │ open/ioctl/mmap/poll
 Linux kernel               xlr8.ko  (platform driver, misc device, IRQ, DMA buffer)
        │ AXI4-Lite (GP0)                         ▲ IRQ_F2P
 ┌──────┴──────────────────────────────── PL ─────┴────────────────┐
 │  xlr8_regs (AXI-Lite slave)                                        │
 │    ├─ control/status/args registers                                │
 │    └─ program window ──► prog RAM (BRAM, 1024 x 16)                │
 │                                  │ imem                            │
 │                              simt_gpu  (2 warps x 4 lanes)         │
 │                                  │ word bus                        │
 │                          xlr8_axi_bridge (AXI master, AXI3)        │
 └────────────────────────────────┬───────────────────────────────────┘
                              HP0 port ──► DDR  (frame buffer + params, CMA)
```

### Why an address base register

The GPU emits 32-bit word addresses starting at 0. The bridge adds a `MEM_BASE` register (a
physical DDR address programmed by the driver) and a `MEM_LIMIT`. The kernel never sees physical
addresses, and a bad GPU address cannot reach arbitrary DDR. An out-of-range access sets an error
status bit and returns zero.

### Why GP0 for control and HP0 for data

Zynq-7000 exposes AXI3 slave ports to the PL (HP0-HP3) and AXI3 master ports to the PL (GP0-GP1)
(VERIFY against UG585). Control traffic is tiny and fits GP0. Pixel traffic goes through HP0 with
a direct path to the DDR controller. Note these are AXI3, so bursts are at most 16 beats and there
is no `WLAST` interleave.

### Clocking

Single PL clock from `FCLK_CLK0`. Start at 50 MHz, the clock RAPTOR synthesized the GPU at, then
raise only after timing closes with margin. No CDC is needed. This is a deliberate simplification
over RAPTOR-SoC, where CPU and GPU were separate domains.

## 4. Register map (AXI4-Lite, 32-bit, byte-addressed, base from device tree)

| Offset | Name | R/W | Description |
|---|---|---|---|
| 0x00 | CTRL | RW | bit0 START (self-clearing), bit1 SOFT_RESET, bit2 IRQ_EN (level, set by every CTRL write: write `START\|IRQ_EN` together) |
| 0x04 | STATUS | R | bit0 BUSY, bit1 DONE (sticky until next START), bit2 ERROR, bit3 BAD_ACCESS (sticky until next START or SOFT_RESET) |
| 0x08 | THREADS | RW | thread count |
| 0x0C | SRC | RW | GPU word offset for `r14` |
| 0x10 | DST | RW | GPU word offset for `r15` |
| 0x14 | PROG_BASE | RW | program word offset (kept from RAPTOR) |
| 0x18 | MEM_BASE | RW | physical DDR byte address added by the bridge |
| 0x1C | MEM_LIMIT | RW | byte size of the allowed window |
| 0x20 | IRQ_STATUS | RW1C | bit0 DONE, bit1 ERROR |
| 0x24 | CYCLES | R | GPU clock cycles for the last job (START to DONE) |
| 0x28 | BUS_XACTS | R | bus transactions issued in the last job |
| 0x2C | BUS_STALLS | R | cycles waiting on AXI in the last job |
| 0x30 | ERR_ADDR | R | first out-of-range GPU word address |
| 0x34 | ID | R | `0x584C5238` ("XLR8") |
| 0x38 | VERSION | R | major.minor.patch, one byte each |
| 0x3C-0x50 | ARG0..ARG5 | RW | kernel arguments, preloaded into r8..r13 (hardware 0.2.0, Phase 8) |
| 0x1000-0x17FF | PROG_WIN | RW | program RAM, two 16-bit instructions per 32-bit word, 512 words |

Rules:
- START while BUSY returns SLVERR and does not disturb the running job. Writes to read-only or
  reserved registers and any unmapped address also return SLVERR and set STATUS.BAD_ACCESS.
  `SLVERR_EN=0` returns OKAY instead and keeps BAD_ACCESS. VERIFY on the board: an AXI error on the
  Zynq GP port can raise an external abort in Linux, in which case build with `SLVERR_EN=0`.
- SOFT_RESET resets the GPU, program fetch state and counters for 8 cycles but keeps the
  configuration registers. The bridge finishes any AXI transaction already in flight and discards
  its result, and START is refused (BUSY) until that drain is complete.
- An all-zero program memory runs NOPs forever (no RET), so a job never ends. The driver watchdog
  recovers it with SOFT_RESET (tested).
- Configuration registers are shadowed. A write during BUSY updates the shadow only, and START
  snapshots all of them. This is the same safety rule RAPTOR uses.
- DONE rises one cycle after the GPU's final STR is acknowledged by the bridge.
- Program window writes during BUSY return SLVERR.

## 5. Memory map and data formats

- Framebuffer pixel: packed RGB in the low 24 bits, `0x00RRGGBB`, one pixel per 32-bit word.
- Frame size for Phase 1 through 6: 64 x 64 (4096 words, 16 KiB). Width is a power of two so
  `x = tid & 63` and `y = tid >> 6`.
- Parameter block for the ball kernel, 32-bit words at `SRC`:

| Word | Content |
|---|---|
| 0 | `cx` center x |
| 1 | `cy` center y |
| 2 | `r2` radius squared |
| 3 | ball color |
| 4 | background color |

- Framebuffer written at `DST`. Parameter block and framebuffer live in one contiguous
  `dma_alloc_coherent` region. `MEM_BASE` is its physical address.

## 6. The ball kernel

One thread per pixel. All control flow is branch-free. A uniform kernel means no divergence is
needed.

Inside test: `d = r2 - (dx*dx + dy*dy)`. `d >> 31` is 1 when negative (outside) and 0 when
non-negative (inside, including the exact edge). The color is
`inside*ball + outside*bg`, using two MULs. Packed RGB is only ever multiplied by 0 or 1, so no
per-channel math is needed.

Sketch (estimate: about 28 instructions, registers up to r9):

```
CONST r1, 63        ; mask
AND   r2, r0, r1    ; x = tid & 63
CONST r3, 6
SRL   r4, r0, r3    ; y = tid >> 6
CONST r5, 0
LDR   r6, r14, r5   ; cx
CONST r5, 1
LDR   r7, r14, r5   ; cy
SUB   r2, r2, r6    ; dx
SUB   r4, r4, r7    ; dy
MUL   r2, r2, r2
MUL   r4, r4, r4
ADD   r2, r2, r4    ; dist^2
CONST r5, 2
LDR   r6, r14, r5   ; r2
SUB   r6, r6, r2    ; d = r2 - dist^2
CONST r5, 31
SRL   r6, r6, r5    ; outside = sign bit
CONST r5, 1
SUB   r7, r5, r6    ; inside = 1 - outside
CONST r5, 3
LDR   r8, r14, r5   ; ball color
CONST r5, 4
LDR   r9, r14, r5   ; bg color
MUL   r8, r8, r7
MUL   r9, r9, r6
ADD   r8, r8, r9
STR   r8, r15, r0   ; fb[tid]
RET
```

Open details VERIFY in Phase 1: `SUB` wraparound for negative `dx`; `MUL` low-32-bit result for
negative operands; exact `SRL` shift amount semantics (uses `rs2[4:0]`); whether the assembler
accepts `CONST` reuse of one register inside a lane without hazards.

Per-pixel bus cost of this baseline: 5 loads + 1 store = 6 transactions per pixel, 24,576 per
64x64 frame. Phase 8 cuts the loads.

## 7. Performance model (estimates, to be replaced by measurements)

Let `L` be the bridge latency per word access in GPU clock cycles. The mem_unit is serialized, so:

    frame_cycles  ≈ pixels * transactions_per_pixel * L          (bus-bound)
    frame_time    = frame_cycles / f_clk

With L between 20 and 40 cycles (an estimate for AXI3 through HP0), 24,576 transactions give
roughly 0.5M to 1M cycles, so 10 to 20 ms at 50 MHz. Cutting to 1 transaction per pixel gives
about 2 to 4 ms. Compute is negligible next to this. Phase 7 measures real `L` with the
`BUS_STALLS` counter.

The ARM baseline for 4096 pixels of this math is tens of microseconds in C. Expect the GPU to
lose on raw speed at this size. The project's value is the integration and correctness, plus a
scaling story in Phase 8. Report this plainly.

## 8. Verification strategy

| Level | Tool | What |
|---|---|---|
| ISA | `isa_sim.py` | every kernel runs in Python and matches the golden render |
| Unit RTL | Verilator | AXI-Lite slave, program window, bridge, counters |
| Bridge | Verilator + AXI BFM | random AW/W/AR/R/B stalls, error responses, back-to-back jobs |
| System RTL | Verilator | wrapper + GPU + RAM model; ball frames vs golden |
| Protocol | assertions | no BUSY START, DONE sticky, IRQ only after commit |
| Hardware | PYNQ MMIO | same frames from real fabric vs golden |
| Driver | userspace tests | open/close, concurrent open, bad ioctl, timeout, kill during job |
| Soak | script | 10,000 frames, zero mismatches |

Golden models: `tools/ball_ref.py` (pure Python, independent of the assembler and ISA sim).
Every comparison is exact, not tolerance-based.

## 9. Tooling

- Simulation: Verilator (present on this machine at `/usr/bin/verilator`).
- Vivado: not on the Linux PATH here. The existing Vivado projects live on the Windows side.
  VERIFY which machine runs Vivado and which version (a 2025.2 installer is in Downloads).
  Plan: `fpga/pynq_z2/build.tcl` in batch mode, runnable from either.
- Board image: PYNQ for the PYNQ-Z2. VERIFY the image version and its kernel version before
  building the module, since an out-of-tree module must match the running kernel.
- Cross compiler: `arm-linux-gnueabihf-gcc`. VERIFY it is installed, or build natively on the
  board.

## 10. Repository conventions

- One folder per concern as in the README layout.
- RTL: SystemVerilog, lint-clean under `verilator --lint-only -Wall`.
- Every phase has `docs/PHASEn_ASSIGNMENT.md` (spec) and gets `docs/PHASEn_PROGRESS.md` (what
  actually happened) when work begins, as in RAPTOR-SoC.
- Vendored RAPTOR source is copied, not linked. Record the source commit in `rtl/gpu/SOURCE.md`.
- Measured results only in `results/`, each with the exact command that produced it.

## 11. Risk register

| Risk | Impact | Mitigation |
|---|---|---|
| Serialized `mem_unit` makes frames slow | demo is sluggish | measure first; Phase 8 coalescing and kernel args |
| AXI bridge bug corrupts frames | wrong pixels | exhaustive random-stall tests before any hardware |
| Combinational `imem_rdata` and BRAM mismatch | timing or functional break | prog RAM as async-read distributed RAM first; later pipeline the fetch |
| Combinational data-bus read vs AXI latency | protocol mismatch | bridge holds `mem_ready` low until R returns; GPU already waits on ready |
| Kernel/ module version mismatch | driver will not load | pin PYNQ image, record `uname -r`, build against its headers |
| No Vivado on Linux box | cannot build | settle which machine builds in Phase 0 |
| Linux cache coherence on the frame buffer | stale pixels | use `dma_alloc_coherent` or a non-cacheable mapping, document the choice |
| Timing failure at 50 MHz from the divider | build fails | keep DIV out of kernels, check the worst path in the report |

## 12. Resume framing (only after the matching phase is measured)

> Ported a custom SIMT GPU (8 lanes, custom 16-bit ISA) to the Zynq-7020, adding an AXI4-Lite
> control interface, an AXI master bridge to DDR, and a Linux kernel driver (device tree, DMA
> buffer, IRQ, ioctl). Rendered a bouncing-ball animation bit-exact against a Python golden
> model, timing closed at X MHz with Y LUTs, Z ms per frame.

Fill X, Y, Z from `results/`, not from this document.
