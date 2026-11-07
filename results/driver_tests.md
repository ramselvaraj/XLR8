# Linux driver tests (Phase 5)

Run 2026-11-07 on the PYNQ-Z2 (kernel 5.15.19-xilinx-v2022.1) with `tools/board/run_driver_tests.sh 1000 10000`.
Bitstream: `SLVERR_EN=0`, registers at `0x4001_0000`, IRQ_F2P[1], 50 MHz set by the driver (timing in
`timing_50mhz_linux.rpt`: WNS +0.644 ns, WHS +0.092 ns). Loaded through a device-tree overlay
(`dts/xlr8.dtso`: FPGA-region bitstream load plus the platform device), driver `driver/xlr8.c`.

| Test | Result |
|---|---|
| Probe | `xlr8 40010000.xlr8: XLR8 hw 00000100, irq 57, /dev/xlr8` |
| Ball frames through the driver | 1,000 of 1,000 exact, mean CYCLES 462,289 (9.25 ms at 50 MHz) |
| Interrupt driven | 1,000 interrupts for 1,000 frames (counted from `/proc/interrupts`) |
| Bad arguments | unknown ioctl `ENOTTY`; reserved fields, zero or oversize program, zero or oversize buffer, submit without buffer, wait without submit, mmap without buffer or beyond it or with an offset: `EINVAL`; bad user pointer: `EFAULT`; 64 MiB buffer: clean `ENOMEM` when CMA cannot fit it |
| WAIT timeout | 50 ms wait on a hung job returns `ETIMEDOUT`; the later wait returns the watchdog result |
| poll | not readable before submit, readable after completion |
| Concurrent submitters | 4 processes x 60 frames, all exact (jobs queue on the one device) |
| Kill during job | SIGKILL at 8 offsets inside a job, the device stays usable and the next frame is exact |
| Watchdog | hung GPU (CMP then branch-to-self) is soft-reset after the timeout, status carries `XLR8_ST_TIMEOUT`, next job exact |
| Leak | 10,000 open / SET_BUF / close cycles: CmaFree 83,024 kB -> 83,036 kB |
| dmesg | only the two expected watchdog warnings from the test; no oops, BUG, or warnings from the driver |

Notes:

- The kernel prints `OF: overlay: WARNING: memory leak will occur if overlay removed` when the
  overlay is applied. That is the kernel flagging that removing overlays that add properties to
  existing nodes leaks them; the board is not meant to remove the overlay in normal use.
- CmaFree drifts a few MB between separate runs. Within a run it is flat; page cache can occupy
  movable CMA pages, so this is not counted as a leak.

## The PL clock (found during Phase 6)

When the bitstream is loaded through the FPGA manager instead of PYNQ's `Overlay`, nothing sets
the PL clock: `fclk0` came up at **100 MHz** (`/sys/kernel/debug/clk/clk_summary`), while timing was
closed at 50 MHz. The frames were still exact, but that is running the design out of spec, and the
measured cycle count jumped from about 454,000 to 596,000 per frame because DDR latency is fixed in
nanoseconds. The driver now takes `FCLK_CLK0` from the device tree (`clocks = <&clkc 15>`,
`clock-frequency = <50000000>`), sets and enables it, and logs `PL clock 50000000 Hz`. After a cold
boot `fclk0` reads 50,000,000 Hz and the frame cost is back to about 462,000 cycles. All numbers
above are from this fixed driver.
