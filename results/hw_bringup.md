# Hardware bring-up on the PYNQ-Z2 (Phase 4)

Board: PYNQ-Z2, PynqLinux kernel 5.15.19-xilinx-v2022.1, bitstream built with `SLVERR_EN=1`,
50 MHz PL clock, HP0 forced to 32-bit. Produced 2026-11-07 by `tools/board/run_bringup.sh`
(commands below). Buffer from PYNQ `allocate` (CMA, non-cacheable) at physical `0x14060000`.

## Ball animation, 64x64, 4096 threads, 29-instruction kernel

| Run | Result |
|---|---|
| `run_bringup.sh 1000` | 1,000 frames exact against `tools/ball_ref.py`, zero mismatches |
| ID register | `0x584C5238`, VERSION `0x00000100` |
| CYCLES per frame | mean 454,630, min 454,267, max 458,782 |
| Frame time at 50 MHz | 9.09 ms (about 110 frames/s from the GPU alone) |
| BUS_XACTS | 24,576 (6 per pixel, as predicted) |
| BUS_STALLS | about 364,000 (14.8 per transaction) |

Python's end-to-end loop, including the per-frame pixel check, ran at 18 frames/s (55.6 s for
1,000 frames), so the Python check, not the GPU, sets that rate.

## Simulation versus hardware

| | Cycles per frame | Cycles per transaction |
|---|---|---|
| Ideal bus (Phase 1 sim) | 91,143 | 3.7 |
| Bridge into a zero-wait AXI model (Phase 2 sim) | 192,001 | 7.8 |
| Real DDR through HP0 (this run) | 454,630 | 18.5 |

Real memory adds about 10.7 cycles (about 214 ns) per transaction beyond the zero-wait model, on top
of the 4 the bridge itself costs. One transaction in flight at a time is the bottleneck: about 75%
of the frame time is waiting on DDR. This is the number Phase 8 attacks (fewer transactions per
pixel, bursts, more than one request in flight).

## Error paths on hardware (SLVERR_EN=1)

| Test | Result |
|---|---|
| START while BUSY | SLVERR, running job completes unchanged |
| Program-window write while BUSY | SLVERR, program word unchanged |
| Read of unmapped offset 0x1800 | SLVERR |
| MEM_LIMIT smaller than the frame | STATUS.ERROR set, ERR_ADDR = first illegal word, IRQ_STATUS = 3, job ends |
| Clean job after an error | ERROR and ERR_ADDR cleared, pixels exact |
| SOFT_RESET at 0, 0.5 and 2 ms into a job, then a clean job | pixels exact each time |

**An SLVERR from the PL is a SIGBUS to the process that made the access** ("external abort on
non-linefetch"). From a kernel driver the same fault would be an oops. So the Linux build uses
`SLVERR_EN=0` (illegal accesses return OKAY and set STATUS.BAD_ACCESS). That bitstream is built as
tag `50mhz_slverr0`; see PHASE4_PROGRESS.md for its results.

## Cache coherence

The HP port is not cache-coherent with the ARM. Test with a cacheable buffer (pre-filled with a
sentinel and pulled into the CPU cache), then one GPU job:

| Read | Wrong pixels |
|---|---|
| Without `invalidate()` | 1,096 of 4,096 |
| After `invalidate()` | 0 of 4,096 |

The driver must use a non-cacheable or coherent buffer (`dma_alloc_coherent`) or explicit cache
maintenance (`dma_sync_*`). Phase 5 uses `dma_alloc_coherent`.

## Findings from bring-up

- Zynq PS control registers (the AFI registers) need 32-bit accesses. A byte read through
  `struct.unpack_from` on an `mmap` raised an external abort and killed the script. Use 32-bit
  views (numpy `uint32`).
- With HP0 forced to 32-bit (`AFI_RDCHAN_CTRL`/`WRCHAN_CTRL` = 1) the GPU's 32-bit master reads and
  writes correctly. The WRCHAN register reads back `0xf01`, the RDCHAN `0x1`.

## Commands

    tools/board/run_bringup.sh 1000              # soak
    tools/board/run_bringup.sh 3 --errors        # error paths
    tools/board/run_bringup.sh 1 --coherence     # cache coherence

## Re-run on the Linux bitstream (SLVERR_EN=0, base 0x4001_0000)

`tools/board/run_bringup.sh 300` and `--errors` on `build/fpga/out_50mhz_linux`:

- 300 frames exact, CYCLES mean 454,595 (9.09 ms at 50 MHz), same as before.
- START while BUSY, program write while BUSY and the unmapped read now return OKAY (no SIGBUS); the
  running job and the program memory are unchanged, STATUS shows BAD_ACCESS (`0xa` with DONE).
- Small MEM_LIMIT, clean job after error and soft reset at 0, 0.5 and 2 ms behave as before.
