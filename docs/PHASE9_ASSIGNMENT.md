# Phase 9: Extended Goals

Committed scope: all items below get done, after Phase 8. Items are independent and can be ordered by blockers (D waits on rv32-linux).

## A. Show it on a screen

Reuse the HDMI path from the killswitch project or a Linux framebuffer: scan the GPU's DDR
buffer out through a video pipeline, or copy it to `/dev/fb0`. Adds the visual demo that was
deliberately skipped.

## B. Standard Linux video interface

Expose XLR8 as a V4L2 memory-to-memory device or a DRM render node, so standard tools can use it.
The most impressive for kernel and embedded roles, and the most work.

## C. dma-buf export

Let userspace share the GPU buffer with other devices without copies.

## D. Run the host on your own RISC-V Linux

Drive XLR8 from the `rv32-linux` core instead of the ARM cores: your CPU, your Linux, your GPU.
Blocked until rv32-linux has a working interactive shell and acceptable boot time, and needs the
GPU attached to that SoC's bus rather than the Zynq PS.

## E. Larger frames and real images

Move beyond 64x64: a non-power-of-two width needs `DIV` or a different address scheme. Load a
source image and run blur and brighten through the Linux path.

## F. Formal and UVM verification of the new RTL

SymbiYosys properties on the AXI slave and bridge handshakes, and a UVM environment for the
register block. Adds verification keywords to the resume.

## Exit criteria

For each stretch goal attempted: a design note, tests, measured results, and a README section.
