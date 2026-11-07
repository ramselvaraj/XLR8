# Phase 6: Userspace Library, Renderer, Animation

## Goal

A clean C library and an app that renders the bouncing ball animation on the GPU and saves it.

## Deliverables

1. `sw/lib/libxlr8`: thin C wrapper over the ioctls. `xlr8_open`, `xlr8_load`,
   `xlr8_alloc`, `xlr8_submit`, `xlr8_wait`, `xlr8_info`, `xlr8_close`. Error codes, no hidden
   global state.
2. A small assembler step so `.asm` kernels compile to a binary blob the library loads. Reuse
   `tools/assemble.py`; add an `--emit-bin` mode.
3. `sw/apps/ball`: per frame, update ball position (same integer physics as
   `tools/animate_ref.py`), write the parameter block, submit, wait, copy the frame out.
4. Output: numbered PNGs and a GIF. Optionally an MP4 if ffmpeg exists on the image.
5. `sw/apps/ball --verify`: render every frame twice, GPU and CPU reference, and diff exactly.
6. Python bindings via `ctypes` for Jupyter use and a notebook that shows the animation.
7. Other kernels runnable from the same app: `gradient`, `checker`.

## Scope decisions

| Decision | Choice |
|---|---|
| Physics location | host (ARM), not GPU |
| Physics arithmetic | integer fixed point, shared with the golden model |
| Image I/O | tiny PNG writer in C, no heavy dependencies |
| Animation length | default 120 frames, configurable |

## Tests

- `--verify` passes over 600 frames.
- Library unit tests with a fake driver (stub ioctl layer) for error paths.
- Valgrind or ASan clean on the host build of the library.

## Exit criteria

- One command produces the GIF from a cold boot of the board.
- `--verify` reports zero mismatches.
- The notebook displays the animation in the browser.
- README has exact commands.

## Non-goals

No performance tuning here; that is Phases 7 and 8.
