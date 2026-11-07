# Phase 5 Progress

## Done

- `driver/xlr8.c` (platform driver, misc device `/dev/xlr8`, IRQ, per-file coherent DMA buffer,
  `mmap`, `poll`, watchdog) and `driver/xlr8_uapi.h` (versioned ABI, reserved fields must be zero).
- `dts/xlr8.dtso`: one overlay that loads the bitstream through the FPGA region and creates the
  platform device.
- Loaded with `tools/board/load_xlr8.sh`; driver built natively on the board.
- `driver/tests/xlr8_test.c`: all tests pass (see `results/driver_tests.md`).

## Design choices

- One job at a time. `SUBMIT` and `LOAD_PROG` sleep until the device is free, so concurrent
  processes queue. Completion frees the device immediately (results are kept per file), so a
  process that never calls `WAIT` cannot starve the others.
- Buffers use `dma_alloc_coherent` (non-cacheable on this ARM), which Phase 4 showed is required:
  the HP port is not cache-coherent.
- The driver sets `S_AXI_HP0` to 32-bit itself (the port powers up 64-bit).
- A delayed-work watchdog soft-resets a job that overruns `job_timeout_ms`; closing a file with a
  job running also soft-resets, so a killed process cannot leave the GPU stuck.
- `SLVERR_EN=0`: an AXI error from the PL kills the accessing process (measured in Phase 4).

## Things that went wrong and what they taught

- PYNQ's base device tree already owns `0x4000_0000` (generic-uio, 64 KB) and `IRQ_F2P[0]`. XLR8
  moved to `0x4001_0000` and `IRQ_F2P[1]` (one more FPGA build).
- The board's kernel tree needed `make modules_prepare` before modules would build.
- The board's DHCP address changed after a reboot; the scripts now discover it.
- Two of my own test mistakes looked like driver bugs (a "hung" program that was not hung: the
  `B` branch needs flags set by a `CMP`; and a 1 ms wait that rounded up to a jiffy longer than a job).

## Open

- Overlay removal warns about a kernel-side leak (kernel behavior, noted in the results).
