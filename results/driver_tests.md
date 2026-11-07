# Linux driver tests (Phase 5)

Run 2026-11-07 on the PYNQ-Z2 (kernel 5.15.19-xilinx-v2022.1) with `tools/board/run_driver_tests.sh 1000 10000`.
Bitstream: `SLVERR_EN=0`, registers at `0x4001_0000`, IRQ_F2P[1], 50 MHz (timing in
`timing_50mhz_linux.rpt`: WNS +0.644 ns, WHS +0.092 ns). Loaded through a device-tree overlay
(`dts/xlr8.dtso`: FPGA-region bitstream load plus the platform device), driver `driver/xlr8.c`.

| Test | Result |
|---|---|
| Probe | `xlr8 40010000.xlr8: XLR8 hw 00000100, irq 57, /dev/xlr8` |
| Ball frames through the driver | 1,000 of 1,000 exact, mean CYCLES 454,316 |
| Interrupt driven | 1,000 interrupts for 1,000 frames (counted from `/proc/interrupts`) |
| Bad arguments | unknown ioctl `ENOTTY`; reserved fields, zero or oversize program, zero or oversize buffer, submit without buffer, wait without submit, mmap without buffer or beyond it or with an offset: `EINVAL`; bad user pointer: `EFAULT`; 64 MiB buffer: clean `ENOMEM` when CMA cannot fit it |
| WAIT timeout | 50 ms wait on a hung job returns `ETIMEDOUT`; the later wait returns the watchdog result |
| poll | not readable before submit, readable after completion |
| Concurrent submitters | 4 processes x 60 frames, all exact (jobs queue on the one device) |
| Kill during job | SIGKILL at 8 offsets inside a job, the device stays usable and the next frame is exact |
| Watchdog | hung GPU (CMP then branch-to-self) is soft-reset after the timeout, status carries `XLR8_ST_TIMEOUT`, next job exact |
| Leak | 10,000 open / SET_BUF / close cycles: CmaFree 91,016 kB -> 91,028 kB |
| dmesg | only the two expected watchdog warnings from the test; no oops, BUG, or warnings from the driver |

Notes:

- The kernel prints `OF: overlay: WARNING: memory leak will occur if overlay removed` when the
  overlay is applied. That is the kernel flagging that removing overlays that add properties to
  existing nodes leaks them; the board is not meant to remove the overlay in normal use.
- CmaFree drifts a few MB between separate runs. Within a run it is flat; page cache can occupy
  movable CMA pages, so this is not counted as a leak.
