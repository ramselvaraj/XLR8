# XLR8 Register Map

Status: implemented, verified in simulation (Phase 2) and on hardware (Phases 4-5).
Base address `0x4001_0000` (8 KiB), interrupt `IRQ_F2P[1]` (SPI 30). PYNQ's own device tree already
uses `0x4000_0000`-`0x4000_FFFF` and `IRQ_F2P[0]` for a generic-uio node.
Byte offsets, 32-bit registers, AXI4-Lite, 13-bit address space.

| Offset | Name | Access | Description |
|---|---|---|---|
| 0x00 | CTRL | RW | bit0 START (self-clearing), bit1 SOFT_RESET, bit2 IRQ_EN. Reads return only bit2. |
| 0x04 | STATUS | R | bit0 BUSY, bit1 DONE, bit2 ERROR, bit3 BAD_ACCESS |
| 0x08 | THREADS | RW | thread count |
| 0x0C | SRC | RW | GPU word offset loaded into `r14` |
| 0x10 | DST | RW | GPU word offset loaded into `r15` |
| 0x14 | PROG_BASE | RW | instruction index added to the GPU program counter |
| 0x18 | MEM_BASE | RW | physical byte address added by the bridge (4-byte aligned) |
| 0x1C | MEM_LIMIT | RW | byte size of the window the GPU may touch |
| 0x20 | IRQ_STATUS | RW1C | bit0 DONE, bit1 ERROR |
| 0x24 | CYCLES | R | clocks from the cycle after the start pulse through the done pulse |
| 0x28 | BUS_XACTS | R | bus transactions completed in the last job |
| 0x2C | BUS_STALLS | R | clocks with a bus request waiting in the last job |
| 0x30 | ERR_ADDR | R | GPU word address of the first illegal or errored access (time order) |
| 0x34 | ID | R | `0x584C5238` ("XLR8") |
| 0x38 | VERSION | R | `0x00MMNNPP` (currently `0x00000100`, version 0.1.0) |
| 0x3C | ARG0 | RW | reserved for Phase 8 kernel arguments (stored, unused) |
| 0x40 | ARG1 | RW | reserved for Phase 8 kernel arguments (stored, unused) |
| 0x1000-0x17FF | PROG_WIN | RW | program RAM, 512 words, instruction 2w in bits [15:0], 2w+1 in [31:16] |

Anything else is unmapped: reads and writes return SLVERR (or OKAY when `SLVERR_EN=0`) and set
BAD_ACCESS.

## Rules

- START while BUSY, program writes while BUSY, writes to read-only or reserved registers: SLVERR,
  no effect, BAD_ACCESS set.
- Configuration is shadowed. START snapshots THREADS, SRC, DST, PROG_BASE, MEM_BASE, MEM_LIMIT,
  ARG0 and ARG1. Writes during a job change only the shadow, which START picks up next time.
- START clears DONE, ERROR, BAD_ACCESS, ERR_ADDR, IRQ_STATUS and the performance counters.
- DONE stays set until the next START (reading STATUS never clears it). IRQ_STATUS can be cleared
  separately by writing 1s.
- The interrupt line is `IRQ_EN && (IRQ_STATUS != 0)`. CTRL is written whole, so a START write
  that omits bit2 turns the interrupt off: write `0x5` to start with interrupts enabled.
- ERROR is set by an access outside `[0, MEM_LIMIT)` (no AXI traffic is generated; reads return 0,
  writes are dropped) or by an AXI SLVERR/DECERR response (the access completes). The job always
  finishes.
- SOFT_RESET (write bit1) holds the GPU in reset for 8 cycles, clears BUSY, DONE, ERROR and
  IRQ_STATUS, keeps configuration, and drains any AXI transaction already issued. Use it to
  recover a hung GPU.
