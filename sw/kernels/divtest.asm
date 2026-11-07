; divtest.asm -- dst[tid] = src[2*tid] / src[2*tid+1] (unsigned 32-bit), 256 threads.
; Operand pairs live in the source buffer; a zero divisor must give 0.
.threads 256
.src 0x2000
.dst 0x6000
.text
    CONST r1, 1
    SLL   r2, r0, r1    ; 2*tid
    LDR   r3, r14, r2   ; a
    ADD   r2, r2, r1    ; 2*tid + 1
    LDR   r4, r14, r2   ; b
    DIV   r5, r3, r4
    STR   r5, r15, r0
    RET
