# Phase 6 Progress

## Done

- `sw/lib/xlr8.{h,c}`: C library over `/dev/xlr8`, per-handle state, negative errno returns, a
  replaceable system-call layer for tests.
- `sw/lib/xlr8.py`: pure-Python binding (ioctl, mmap), no compiled code.
- `sw/apps/ball.c` with `imgout.h`: bouncing ball, gradient and checker kernels, `--verify`
  against a CPU render, PNG and GIF writers with no dependencies.
- `sw/apps/ball_demo.ipynb`: renders and shows the animation in Jupyter.
- `tools/assemble.py --bin` for raw little-endian program files.
- `tools/board/demo.sh`: board discovery to GIF in one command, tested from a cold boot.
- Tests in `make test-sw` and `results/userspace.md`.

## Found along the way

- The PL clock in the FPGA-manager flow is 100 MHz, not 50 MHz (see `results/driver_tests.md`).
  Fixed in the driver with a device-tree clock. This would have been invisible without the cycle
  count: the frames were still exact.
- The first GIF encoder used the "clear every two codes" trick, valid but 4.4 MB. Replaced with a
  real LZW encoder (63 KB), checked with Pillow.
- `B` (branch always) needs a `CMP` first to set the flags; an unconditionally-hanging program
  must `CMP` before it branches to itself.

## Deviation

- The notebook has been written and its JSON validated, but it has not been run in the board's
  Jupyter. The same code paths (`xlr8.py` ioctls, mmap) are exercised by the C tests, but
  `xlr8.py` itself is verified only for ioctl numbers and sizes, not end to end on the board.
