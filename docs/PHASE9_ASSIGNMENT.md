# Phase 9: Real Images and a V4L2 Device

## A. Real images through Linux (done)

`sw/apps/imgfilter.c` runs the 3x3 blur on the GPU for a 64x64 photo through `/dev/xlr8` and
checks every pixel against a CPU blur. `tools/board/run_image_demo.sh` does the whole round trip and
writes `results/demo/blur_before_after.png`. Ball frames at 128x128 and 256x256 run through the same
path.

## B. V4L2 memory-to-memory device

Expose the GPU as a standard video device `/dev/videoN` so any V4L2 program can use it.

| Piece | Design |
|---|---|
| Framework | `v4l2-mem2mem` (built as a module from upstream 5.15.19 source, since the board kernel has the rest of V4L2 and `videobuf2-dma-contig` built in) |
| Queues | OUTPUT takes the source image, CAPTURE returns the result; `XRGB32`, 64x64, MMAP and DMABUF |
| Job | the GPU reads the OUTPUT buffer and writes the CAPTURE buffer directly in DDR: the memory window covers both buffers, SRC and DST are word offsets from its base |
| Filter | 3x3 blur (two launches, program loaded for each job so it cannot clash with `/dev/xlr8` users) |
| Scheduling | m2m runs one job at a time across all open files; jobs share the GPU with `/dev/xlr8` clients through the same claim mechanism |

Tests (`driver/tests/v4l2_test.c`, run on the board): capability and format ioctls, buffer setup
and mmap, streaming N frames with every CAPTURE frame equal to the CPU blur, several processes
streaming at once, streaming while a `/dev/xlr8` client renders, stream-off with queued buffers,
and close while streaming.
