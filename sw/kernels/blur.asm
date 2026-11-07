; blur.asm -- interior 3x3 box blur, fully unrolled.
; The assembler expands .gen_blur into the per-thread kernel and sets the
; thread count to the number of interior pixels, (W-2)*(H-2).
; Border pixels are untouched in Phase 2 (handled in Phase 3).
.gen_blur 64 64
.src 0x2000
.dst 0x6000
