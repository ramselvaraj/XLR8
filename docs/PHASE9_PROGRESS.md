# Phase 9 Progress

## Done

- **Real images through Linux:** `sw/apps/imgfilter.c`, `tools/board/run_image_demo.sh`, result image
  `results/demo/blur_before_after.png` (0 of 4,096 pixels differ from the CPU blur).
- **V4L2 memory-to-memory device:** `/dev/video0`, 64x64 XBGR32, 3x3 blur on the GPU, working
  alongside `/dev/xlr8`. Details and test results: `results/v4l2.md`.
  - core driver refactored: an in-kernel job interface (`xlr8_priv.h`: claim the GPU, load a
    program, run several launches back to back, release), exported to `xlr8_v4l2.ko`;
  - each `/dev/xlr8` file keeps its program and reloads it when another user has changed the RAM;
  - `v4l2-mem2mem` built from upstream source as a module.
