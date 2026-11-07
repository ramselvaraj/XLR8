; brighten.asm -- out[tid] = in[tid] + 0x20
; Phase 1 acceptance kernel.
.threads 256
.src 0x2000
.dst 0x6000
.text
    CONST r1, 0x20      ; delta
    LDR   r2, r14, r0   ; r2 = src[tid]   (r14 = SRC)
    ADD   r3, r2, r1    ; add delta
    STR   r3, r15, r0   ; dst[tid] = r3   (r15 = DST)
    RET
