; life.asm -- Conway's Game of Life, 64x64 torus, one generation per launch (tools/gen_life.py).
.threads 4096
.src 0x2000
.dst 0x6000
.text
    CONST r1, 63
    AND   r2, r0, r1      ; x
    CONST r3, 6
    SRL   r4, r0, r3      ; y
    CONST r5, 1
    ADD   r6, r2, r1
    AND   r6, r6, r1      ; x-1 (wrapped)
    ADD   r7, r2, r5
    AND   r7, r7, r1      ; x+1
    ADD   r8, r4, r1
    AND   r8, r8, r1
    SLL   r8, r8, r3      ; (y-1)*64
    SLL   r9, r4, r3      ; y*64
    ADD   r10, r4, r5
    AND   r10, r10, r1
    SLL   r10, r10, r3    ; (y+1)*64
    SUB   r11, r11, r11   ; neighbour sum
    ADD   r12, r8, r6
    LDR   r13, r14, r12
    ADD   r11, r11, r13
    ADD   r12, r8, r2
    LDR   r13, r14, r12
    ADD   r11, r11, r13
    ADD   r12, r8, r7
    LDR   r13, r14, r12
    ADD   r11, r11, r13
    ADD   r12, r9, r6
    LDR   r13, r14, r12
    ADD   r11, r11, r13
    ADD   r12, r9, r7
    LDR   r13, r14, r12
    ADD   r11, r11, r13
    ADD   r12, r10, r6
    LDR   r13, r14, r12
    ADD   r11, r11, r13
    ADD   r12, r10, r2
    LDR   r13, r14, r12
    ADD   r11, r11, r13
    ADD   r12, r10, r7
    LDR   r13, r14, r12
    ADD   r11, r11, r13
    LDR   r13, r14, r0     ; this cell
    CONST r1, 31
    CONST r2, 3
    SUB   r3, r11, r2     ; sum - 3
    SUB   r4, r4, r4       ; 0
    SUB   r5, r4, r3
    OR    r3, r3, r5
    SRL   r3, r3, r1      ; sum != 3
    CONST r5, 1
    SUB   r3, r5, r3      ; sum == 3
    CONST r2, 2
    SUB   r6, r11, r2     ; sum - 2
    SUB   r7, r4, r6
    OR    r6, r6, r7
    SRL   r6, r6, r1      ; sum != 2
    SUB   r6, r5, r6      ; sum == 2
    MUL   r6, r6, r13     ; alive and sum == 2
    ADD   r3, r3, r6      ; next state
    STR   r3, r15, r0
    RET
