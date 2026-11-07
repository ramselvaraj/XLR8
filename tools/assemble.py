#!/usr/bin/env python3
"""Assembler for the RAPTOR-SoC GPU ISA (see docs/GPU_ISA.md).

Phase 1 subset: ADD, SUB, CONST, LDR, STR, RET.
Phase 2 adds:   MUL, DIV, AND, OR, XOR, SLL, SRL, CMP, branches
                (B/BEQ/BNE/BLT/BGE/BLE/BGT), labels, and the
                ``.gen_blur W H`` directive which emits a fully-unrolled
                interior 3x3 box-blur kernel.

Syntax::

    .threads 256
    .src 0x2000
    .dst 0x6000
    .text
        CONST r1, 0x20
        LDR   r2, r14, r0
        ...
    loop:
        ...
        BLT loop

    ; or, for a blur:
    .gen_blur 64 64
    .src 0x2000
    .dst 0x6000

Outputs a 16-bit-per-line hex program plus a JSON sidecar with launch
metadata.
"""
import argparse
import json
import re
import sys

OPCODES = {
    "ADD": 0x0, "CONST": 0x1, "SUB": 0x2, "LDR": 0x3, "STR": 0x4, "RET": 0x5,
    "MUL": 0x6, "DIV": 0x7, "AND": 0x8, "OR": 0x9, "XOR": 0xA,
    "SLL": 0xB, "SRL": 0xC, "CMP": 0xD,
}
# n, z, p condition bits
BRANCHES = {
    "B": 0b111, "BEQ": 0b010, "BNE": 0b101, "BLT": 0b100,
    "BGE": 0b011, "BLE": 0b110, "BGT": 0b001,
}
BR_OP = 0xE

PROG_WORDS = 1024          # testbench instruction memory size

COMMENT = re.compile(r"[;#].*$")


def parse_reg(tok):
    tok = tok.strip().lower()
    if not tok.startswith("r"):
        raise ValueError(f"expected register, got {tok!r}")
    n = int(tok[1:])
    if not 0 <= n < 16:
        raise ValueError(f"register out of range: {tok}")
    return n


def enc_r(op, a, b, c):
    return (op << 12) | (a << 8) | (b << 4) | c


def emit_blur(W, H):
    """Emit a fully-unrolled interior 3x3 box blur for a W x H image.

    One thread per interior pixel t in [0, (W-2)*(H-2)):
        iw = W-2;  x = t % iw + 1;  y = t / iw + 1;  p = y*W + x
        average each of R,G,B over the 3x3 neighbourhood around p, //9,
        repack to 0x00RRGGBB, store at DST + p.
    Register map: r6=0xFF r7=16 r8=8 r9=9 r10/11/12=sum R/G/B r13=p;
    r1..r5 temps; r14=SRC r15=DST.
    """
    iw = W - 2
    prog = []

    def C(rd, imm):
        prog.append((0x1 << 12) | (rd << 8) | (imm & 0xFF))

    def R(op, rd, rs1, rs2):
        prog.append(enc_r(OPCODES[op], rd, rs1, rs2))

    # constants + accumulators
    C(6, 0xFF)
    C(7, 16)
    C(8, 8)
    C(9, 9)
    C(10, 0)
    C(11, 0)
    C(12, 0)
    # x = t % iw + 1 ; y = t / iw + 1 ; p = y*W + x
    C(1, iw)
    R("DIV", 2, 0, 1)      # q = t / iw
    R("MUL", 3, 2, 1)      # q*iw
    R("SUB", 4, 0, 3)      # x0 = t - q*iw
    C(5, 1)
    R("ADD", 4, 4, 5)      # x = x0 + 1
    R("ADD", 2, 2, 5)      # y = q + 1
    C(1, W)
    R("MUL", 3, 2, 1)      # y*W
    R("ADD", 13, 3, 4)     # p = y*W + x

    offsets = [-(W + 1), -W, -(W - 1), -1, 0, 1, (W - 1), W, (W + 1)]
    for off in offsets:
        if off >= 0:
            C(1, off)
            R("ADD", 2, 13, 1)     # idx = p + off
        else:
            C(1, -off)
            R("SUB", 2, 13, 1)     # idx = p - |off|
        R("LDR", 3, 14, 2)         # r3 = mem[SRC + idx]
        R("SRL", 4, 3, 7)          # r4 = r3 >> 16
        R("AND", 4, 4, 6)          # r4 &= 0xFF   (R)
        R("ADD", 10, 10, 4)        # sumR += R
        R("SRL", 4, 3, 8)          # r4 = r3 >> 8
        R("AND", 4, 4, 6)
        R("ADD", 11, 11, 4)        # sumG += G
        R("AND", 4, 3, 6)          # r4 = r3 & 0xFF (B)
        R("ADD", 12, 12, 4)        # sumB += B

    R("DIV", 10, 10, 9)
    R("DIV", 11, 11, 9)
    R("DIV", 12, 12, 9)
    R("SLL", 10, 10, 7)            # R << 16
    R("SLL", 11, 11, 8)            # G << 8
    R("OR", 10, 10, 11)
    R("OR", 10, 10, 12)
    R("STR", 10, 15, 13)           # DST[p] = packed
    R("RET", 0, 0, 0)
    return prog, iw * (H - 2)


def emit_blur_border(W, H):
    """Emit a fully-unrolled clamped border 3x3 box blur for a W x H image.

    One thread per border pixel, in this order:
        [0, W)          top row (incl. both corners)
        [W, 2W)         bottom row (incl. both corners)
        [2W, 2W+H-2)    left edge (excl. corners)
        [.., B)         right edge (excl. corners)
    where B = 2*W + 2*(H-2). Each thread clamps the nine sample coordinates,
    averages R/G/B //9, repacks 0x00RRGGBB, and stores at DST + y*W + x.

    Branchless: the region is selected arithmetically from t so a warp that
    straddles two regions still computes correct coordinates (no divergence).

    Register map (loop): r1=Cm r2=x r3=Cp r4=Rm r6=Rp r5=R0 r7=0xFF r8=8
    r9/10/11=sumR/G/B r12/13=temps; r14=SRC r15=DST.
    """
    if W < 3 or H < 3:
        raise ValueError(f".gen_blur_border needs W>=3 and H>=3, got {W}x{H}")
    B = 2 * W + 2 * (H - 2)
    prog = []

    def C(rd, imm):
        prog.append((0x1 << 12) | (rd << 8) | (imm & 0xFF))

    def R(op, rd, rs1, rs2):
        prog.append(enc_r(OPCODES[op], rd, rs1, rs2))

    GM, G0, GP = 1, 2, 3          # columns: x-1 (clamped), x, x+1 (clamped)
    RP, R0, RM = 4, 5, 6          # rows (already *W): y+1, y, y-1 (clamped)
    BYTE, SH8 = 7, 8
    SUMR, SUMG, SUMB = 9, 10, 11
    TA, TB = 12, 13               # temps

    # --- precompute: region flags, x, y, then clamped columns/rows ---
    C(TA, 1)                      # ONE
    C(TB, 31)                     # shift for the sign bit
    C(7, W)                       # r7 = W
    C(8, 2 * W)                   # r8 = 2W
    C(11, H - 2)
    R("ADD", 10, 8, 11)           # r10 = BND = 2W + (H-2)

    R("SUB", 4, 0, 7);  R("SRL", 4, 4, TB)     # r4 = A0 = t<W
    R("SUB", 5, 0, 8);  R("SRL", 5, 5, TB)     # r5 = B0 = t<2W
    R("SUB", 6, 0, 10); R("SRL", 6, 6, TB)     # r6 = Cc = t<BND

    R("SUB", 8, TA, TA)           # r8 = 0
    R("SUB", 9, 5, 4)             # is_bot   = B0 - A0
    R("SUB", 10, 6, 5)            # is_left  = Cc - B0
    R("SUB", 11, TA, 6)           # is_right = 1 - Cc

    # x = (W-1) default(right); force by region
    R("SUB", 6, 7, TA)            # r6 = W-1
    R("ADD", 2, 6, 8)             # x = W-1
    R("SUB", 5, 8, 2); R("MUL", 5, 5, 10); R("ADD", 2, 2, 5)   # += is_left*(0-x)
    R("SUB", 5, 0, 7); R("SUB", 5, 5, 2);  R("MUL", 5, 5, 9);  R("ADD", 2, 2, 5)  # += is_bot*(t-W-x)
    R("SUB", 5, 0, 2); R("MUL", 5, 5, 4);  R("ADD", 2, 2, 5)   # += is_top*(t-x)

    # y = 0 default(top); force by region
    R("SUB", 3, 8, 8)             # y = 0
    C(6, H - 1)
    R("SUB", 5, 6, 3); R("MUL", 5, 5, 9);  R("ADD", 3, 3, 5)   # += is_bot*((H-1)-y)
    C(6, 2 * W)
    R("SUB", 5, 0, 6); R("ADD", 5, 5, TA); R("SUB", 5, 5, 3)
    R("MUL", 5, 5, 10); R("ADD", 3, 3, 5)                      # += is_left*(t-2W+1-y)
    C(6, 2 * W); C(5, H - 2); R("ADD", 6, 6, 5)                # r6 = BND
    R("SUB", 5, 0, 6); R("ADD", 5, 5, TA); R("SUB", 5, 5, 3)
    R("MUL", 5, 5, 11); R("ADD", 3, 3, 5)                      # += is_right*(t-BND+1-y)

    # rows (y in r3, W in r7) -> R0=r5, RM=r6, RP=r4
    R("MUL", 5, 3, 7)             # R0 = y*W
    R("SUB", 6, 3, TA); R("SRL", 8, 6, TB); R("MUL", 8, 8, 6)
    R("SUB", 6, 6, 8); R("MUL", 6, 6, 7)                       # RM = max(y-1,0)*W
    R("ADD", 4, 3, TA); C(8, H - 1)
    R("SUB", 9, 3, 8); R("SRL", 9, 9, TB); R("SUB", 9, TA, 9)
    R("SUB", 10, 8, 4); R("MUL", 10, 10, 9); R("ADD", 4, 4, 10)
    R("MUL", 4, 4, 7)                                          # RP = min(y+1,H-1)*W

    # columns -> GM=r1, G0=r2 (x), GP=r3
    R("SUB", 1, 2, TA); R("SRL", 8, 1, TB); R("MUL", 8, 8, 1)
    R("SUB", 1, 1, 8)             # GM = max(x-1,0)
    R("ADD", 3, 2, TA); C(8, W); R("SUB", 8, 8, TA)           # r8 = W-1
    R("SUB", 9, 2, 8); R("SRL", 9, 9, TB); R("SUB", 9, TA, 9)
    R("SUB", 10, 8, 3); R("MUL", 10, 10, 9); R("ADD", 3, 3, 10)  # GP = min(x+1,W-1)

    C(BYTE, 0xFF)
    C(SH8, 8)
    C(SUMR, 0); C(SUMG, 0); C(SUMB, 0)

    # --- nine clamped samples: address = row[dy] + col[dx] ---
    rows = {-1: RM, 0: R0, 1: RP}
    cols = {-1: GM, 0: G0, 1: GP}
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            R("ADD", TA, rows[dy], cols[dx])
            R("LDR", TA, 14, TA)                 # TA = mem[SRC + addr]
            C(TB, 16); R("SRL", TB, TA, TB); R("AND", TB, TB, BYTE)
            R("ADD", SUMR, SUMR, TB)
            R("SRL", TB, TA, SH8); R("AND", TB, TB, BYTE)
            R("ADD", SUMG, SUMG, TB)
            R("AND", TB, TA, BYTE)
            R("ADD", SUMB, SUMB, TB)

    C(TB, 9)
    R("DIV", SUMR, SUMR, TB)
    R("DIV", SUMG, SUMG, TB)
    R("DIV", SUMB, SUMB, TB)
    C(TB, 16); R("SLL", SUMR, SUMR, TB)
    R("SLL", SUMG, SUMG, SH8)                 # G << 8
    R("OR", SUMR, SUMR, SUMG)
    R("OR", SUMR, SUMR, SUMB)
    R("ADD", TA, R0, G0)                       # p = y*W + x
    R("STR", SUMR, 15, TA)
    R("RET", 0, 0, 0)
    return prog, B


def assemble(text):
    threads = None
    src, dst = 0, 0
    width = height = None
    interior = False
    pass_kind = None
    labels = {}
    prog = []
    pending = []   # (index, cond, label)

    raw = []
    for lineno, line in enumerate(text.splitlines(), 1):
        line = COMMENT.sub("", line).strip()
        if line:
            raw.append((lineno, line))

    for lineno, line in raw:
        if line.startswith("."):
            parts = line.split()
            d = parts[0].lower()
            if d == ".threads" and len(parts) == 2:
                threads = int(parts[1], 0)
            elif d == ".src" and len(parts) == 2:
                src = int(parts[1], 0)
            elif d == ".dst" and len(parts) == 2:
                dst = int(parts[1], 0)
            elif d == ".gen_blur" and len(parts) == 3:
                width, height = int(parts[1], 0), int(parts[2], 0)
                body, n = emit_blur(width, height)
                prog.extend(body)
                interior = True
                pass_kind = "interior"
                if threads is None:
                    threads = n
            elif d == ".gen_blur_border" and len(parts) == 3:
                width, height = int(parts[1], 0), int(parts[2], 0)
                body, n = emit_blur_border(width, height)
                prog.extend(body)
                pass_kind = "border"
                if threads is None:
                    threads = n
            elif d in (".text", ".data", ".global"):
                pass
            else:
                raise ValueError(f"line {lineno}: unknown directive {d!r}")
            continue

        if line.endswith(":"):
            labels[line[:-1]] = len(prog)
            continue

        toks = line.replace(",", " ").split()
        mnem = toks[0].upper()

        if mnem in BRANCHES:
            if len(toks) != 2:
                raise ValueError(f"line {lineno}: branch needs a label")
            pending.append((len(prog), BRANCHES[mnem], toks[1]))
            prog.append(0)
            continue

        if mnem not in OPCODES:
            raise ValueError(f"line {lineno}: unknown mnemonic {mnem!r}")
        op = OPCODES[mnem]
        try:
            if mnem == "RET":
                prog.append(enc_r(op, 0, 0, 0))
            elif mnem == "CONST":
                prog.append((op << 12) | (parse_reg(toks[1]) << 8) | (int(toks[2], 0) & 0xFF))
            elif mnem == "CMP":
                prog.append(enc_r(op, 0, parse_reg(toks[1]), parse_reg(toks[2])))
            else:  # 3-register R-type
                a, b, c = (parse_reg(t) for t in toks[1:4])
                prog.append(enc_r(op, a, b, c))
        except (IndexError, ValueError) as e:
            raise ValueError(f"line {lineno}: {e}") from e

    for idx, cond, label in pending:
        if label not in labels:
            raise ValueError(f"undefined label {label!r}")
        off = labels[label] - (idx + 1)
        if not -256 <= off <= 255:
            raise ValueError(f"branch to {label!r} out of range ({off})")
        prog[idx] = (BR_OP << 12) | (cond << 9) | (off & 0x1FF)

    if len(prog) > PROG_WORDS:
        raise ValueError(
            f"program is {len(prog)} instructions, exceeds "
            f"{PROG_WORDS}-word instruction memory")

    meta = {"threads": threads or 0, "src": src, "dst": dst}
    if pass_kind is not None:
        meta.update({"width": width, "height": height, "pass": pass_kind})
        if pass_kind == "interior":
            meta["interior"] = True          # Phase 2 compatibility
    return prog, meta, labels


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("--out", default="prog.hex")
    ap.add_argument("--meta", default=None)
    args = ap.parse_args()

    with open(args.source) as f:
        text = f.read()

    try:
        prog, meta, _ = assemble(text)
    except ValueError as e:
        sys.exit(f"assemble: {e}")

    with open(args.out, "w") as f:
        for w in prog:
            f.write(f"{w & 0xFFFF:04x}\n")
    if args.meta:
        with open(args.meta, "w") as f:
            json.dump(meta, f, indent=2)
    print(f"assemble: {len(prog)} instructions -> {args.out} {meta}")


if __name__ == "__main__":
    main()
