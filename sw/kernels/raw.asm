; raw.asm -- read-after-write through memory: each store is read back before the next step.
;   dst[tid]       = tid + 1
;   dst[tid + 256] = dst[tid] + 1     (loaded back from memory)
;   dst[tid + 512] = dst[tid + 256] + 1
; A bridge that lets a load pass an earlier posted store reads stale data and the chain breaks.
.threads 256
.src 0x2000
.dst 0x6000
.text
    CONST r1, 1
    ADD   r2, r0, r1
    STR   r2, r15, r0
    LDR   r3, r15, r0
    ADD   r3, r3, r1
    CONST r5, 8
    SLL   r6, r1, r5
    ADD   r4, r0, r6
    STR   r3, r15, r4
    LDR   r7, r15, r4
    ADD   r7, r7, r1
    CONST r5, 9
    SLL   r6, r1, r5
    ADD   r4, r0, r6
    STR   r7, r15, r4
    RET
