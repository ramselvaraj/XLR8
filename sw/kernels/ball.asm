; ball.asm -- render one frame of a filled circle, one thread per pixel (64x64).
;
; Parameter block at SRC (32-bit words, signed values in two's complement):
;   [0] cx   center x          [3] ball color 0x00RRGGBB
;   [1] cy   center y          [4] background color 0x00RRGGBB
;   [2] r2   radius squared
; Output: fb[DST + tid] = ball color if (x-cx)^2 + (y-cy)^2 <= r2, else background.
;
; Branch-free. d = r2 - dist2; d >> 31 is 1 when d < 0 (outside), 0 when inside or on the edge.
; Valid domain: cx, cy in [-16384, 16383] and r2 <= 2^30, so dist2 < 2^31 (no 32-bit wrap).
.threads 4096
.src 0x2000
.dst 0x6000
.text
    CONST r1, 63        ; x mask
    AND   r2, r0, r1    ; x = tid & 63
    CONST r3, 6
    SRL   r4, r0, r3    ; y = tid >> 6
    CONST r5, 0
    LDR   r6, r14, r5   ; cx
    CONST r5, 1
    LDR   r7, r14, r5   ; cy
    SUB   r2, r2, r6    ; dx
    SUB   r4, r4, r7    ; dy
    MUL   r2, r2, r2    ; dx^2
    MUL   r4, r4, r4    ; dy^2
    ADD   r2, r2, r4    ; dist2
    CONST r5, 2
    LDR   r6, r14, r5   ; r2
    SUB   r6, r6, r2    ; d = r2 - dist2
    CONST r5, 31
    SRL   r6, r6, r5    ; outside = sign(d)
    CONST r5, 1
    SUB   r7, r5, r6    ; inside = 1 - outside
    CONST r5, 3
    LDR   r8, r14, r5   ; ball color
    CONST r5, 4
    LDR   r9, r14, r5   ; background color
    MUL   r8, r8, r7    ; ball * inside
    MUL   r9, r9, r6    ; bg * outside
    ADD   r8, r8, r9
    STR   r8, r15, r0   ; fb[tid]
    RET
