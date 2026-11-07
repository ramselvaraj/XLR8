# Userspace library, renderer and demo (Phase 6)

Produced 2026-11-07 by `tools/board/demo.sh` after a cold boot of the board (kernel 5.15.19,
PL clock 50 MHz set by the driver).

## One command

    SSH_ASKPASS=<script that prints the board password> tools/board/demo.sh 120

From a freshly booted board this took 69 s end to end: discover the board, copy the bitstream,
overlay, driver and app, build them natively on the board, load the bitstream through the FPGA
region, insert the driver, render with `--verify`, and fetch the results into `results/demo/`.

## Results

| Run | Result |
|---|---|
| `ball --frames 120 --verify` | 120 of 120 frames match the CPU reference exactly |
| GPU time | CYCLES mean 462,690, 9.25 ms per frame at 50 MHz |
| End to end | 20.6 frames per second including PNG and GIF encoding on the ARM |
| `gradient --verify`, `checker --verify` | 1 of 1 frame exact each (CYCLES 100,356 and 298,356) |
| GIF size | 63 KB for 120 frames at 256x256 (real LZW; a first stored-code version was 4.4 MB) |

Files: `results/demo/ball.gif`, `checker.gif`, `gradient.png`, `ball_frame_0040.png`.

## Tests (no hardware needed): `make test-sw`

- `sw/tests/test_lib.c`: libxlr8 against a fake driver, built with AddressSanitizer and
  UBSan. Covers open failure, bad sizes, reserved fields always zero, hex and binary program
  files, missing and empty files, buffer replacement, SET_BUF failure keeping the old mapping,
  mmap failure leaving no stale pointer, `ETIMEDOUT` and `EINTR` mapping, run stopping at a failed
  submit, and close releasing everything. No leaks.
- `sw/tests/test_img.c` + `tools/tests/test_img_decode.py`: PNG (scale 1 and 4) and GIF writers
  decoded with Pillow and compared pixel for pixel, including a noisy 4-colour frame that forces
  LZW dictionary growth and resets.
- `tools/tests/test_py_binding.py`: the Python binding's ioctl numbers and struct sizes equal the
  C header's.
