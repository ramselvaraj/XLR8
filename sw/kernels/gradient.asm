; gradient.asm -- 64x64 horizontal red / vertical green gradient, 0x00RRGGBB.
;   R = x * 4 (0..252), G = y * 4 (0..252), B = 0x80
; No parameter block; SRC is unused.
.threads 4096
.src 0x2000
.dst 0x6000
.text
    CONST r1, 63
    AND   r2, r0, r1    ; x
    CONST r3, 6
    SRL   r4, r0, r3    ; y
    CONST r5, 2
    SLL   r2, r2, r5    ; R = x*4
    SLL   r4, r4, r5    ; G = y*4
    CONST r6, 16
    SLL   r2, r2, r6    ; R << 16
    CONST r6, 8
    SLL   r4, r4, r6    ; G << 8
    OR    r2, r2, r4
    CONST r7, 0x80      ; B
    OR    r2, r2, r7
    STR   r2, r15, r0
    RET
