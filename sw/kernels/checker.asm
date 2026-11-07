; checker.asm -- 64x64 checkerboard with 8x8 squares. Colors from the parameter block at SRC:
;   [0] color A (0x00RRGGBB)   [1] color B
; square parity = ((x >> 3) ^ (y >> 3)) & 1; parity 0 -> A, 1 -> B.
.threads 4096
.src 0x2000
.dst 0x6000
.text
    CONST r1, 63
    AND   r2, r0, r1    ; x
    CONST r3, 6
    SRL   r4, r0, r3    ; y
    CONST r5, 3
    SRL   r2, r2, r5    ; x >> 3
    SRL   r4, r4, r5    ; y >> 3
    XOR   r2, r2, r4
    CONST r6, 1
    AND   r2, r2, r6    ; parity
    CONST r5, 0
    LDR   r7, r14, r5   ; A
    CONST r5, 1
    LDR   r8, r14, r5   ; B
    SUB   r9, r6, r2    ; 1 - parity
    MUL   r7, r7, r9
    MUL   r8, r8, r2
    ADD   r7, r7, r8
    STR   r7, r15, r0
    RET
