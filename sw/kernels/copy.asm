; copy.asm -- out[tid] = in[tid]
; Phase 1 milestone M2: proves the ISA + memory path before adding arithmetic.
.threads 256
.src 0x2000
.dst 0x6000
.text
    LDR r1, r14, r0     ; r1 = src[tid]   (r14 = SRC)
    STR r1, r15, r0     ; dst[tid] = r1   (r15 = DST)
    RET
