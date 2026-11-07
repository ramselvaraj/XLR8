#!/usr/bin/env python3
"""Golden model for the RAPTOR-SoC GPU ISA v0 (Phase 1).

Executes an assembled program over `threads` threads against a flat word
memory. Because Phase 1 has no divergence, each thread is independent.

Used by run_sim.py to predict the GPU output before/while the RTL is brought
up, and to validate the assembler.

Usage::

    isa_sim.py --prog prog.hex --meta prog.json --frame frame.hex \\
               --out expected.hex --words 8192
"""
import argparse
import json
import sys

MASK32 = 0xFFFFFFFF
WORD_MASK = 0x00FFFFFF


def read_hex_words(path):
    words = []
    with open(path) as f:
        for line in f:
            for tok in line.split():
                words.append(int(tok, 16))
    return words


def decode(instr):
    return {
        "op": (instr >> 12) & 0xF,
        "rd": (instr >> 8) & 0xF,
        "rs1": (instr >> 4) & 0xF,
        "rs2": instr & 0xF,
        "imm": instr & 0xFF,
    }


def run(prog, data, threads, src, dst, max_steps=100000):
    """Execute `prog` for `threads` threads over `data` (mutated in place)."""
    for tid in range(threads):
        regs = [0] * 16
        regs[0] = tid & MASK32
        regs[14] = src & MASK32
        regs[15] = dst & MASK32
        pc = 0
        steps = 0
        n = z = p = 0
        while steps < max_steps:
            if not 0 <= pc < len(prog):
                raise RuntimeError(f"tid {tid}: pc {pc} out of program range")
            instr = prog[pc]
            d = decode(instr)
            op = d["op"]
            rd, rs1, rs2, imm = d["rd"], d["rs1"], d["rs2"], d["imm"]

            def wr(val):
                if rd not in (0, 14, 15):
                    regs[rd] = val & MASK32

            if op == 0x0:      # ADD
                wr(regs[rs1] + regs[rs2]); pc += 1
            elif op == 0x1:    # CONST
                wr(imm); pc += 1
            elif op == 0x2:    # SUB
                wr(regs[rs1] - regs[rs2]); pc += 1
            elif op == 0x3:    # LDR
                addr = (regs[rs1] + regs[rs2]) & MASK32
                wr(data[addr % len(data)]); pc += 1
            elif op == 0x4:    # STR
                addr = (regs[rs1] + regs[rs2]) & MASK32
                data[addr % len(data)] = regs[rd]
                pc += 1
            elif op == 0x5:    # RET
                break
            elif op == 0x6:    # MUL
                wr(regs[rs1] * regs[rs2]); pc += 1
            elif op == 0x7:    # DIV
                divisor = regs[rs2]
                wr(regs[rs1] // divisor if divisor else 0); pc += 1
            elif op == 0x8:    # AND
                wr(regs[rs1] & regs[rs2]); pc += 1
            elif op == 0x9:    # OR
                wr(regs[rs1] | regs[rs2]); pc += 1
            elif op == 0xA:    # XOR
                wr(regs[rs1] ^ regs[rs2]); pc += 1
            elif op == 0xB:    # SLL
                wr(regs[rs1] << (regs[rs2] & 31)); pc += 1
            elif op == 0xC:    # SRL
                wr((regs[rs1] & MASK32) >> (regs[rs2] & 31)); pc += 1
            elif op == 0xD:    # CMP
                res = (regs[rs1] - regs[rs2]) & MASK32
                n = (res >> 31) & 1
                z = 1 if res == 0 else 0
                p = 0 if z else (1 - n)
                pc += 1
            elif op == 0xE:    # BRnzp
                cond = (instr >> 9) & 0x7
                off = instr & 0x1FF
                if off >= 0x100:
                    off -= 0x200
                taken = ((cond & 0b100) and n) or ((cond & 0b010) and z) or ((cond & 0b001) and p)
                pc += 1 + (off if taken else 0)
            else:              # illegal -> NOP
                pc += 1
            steps += 1
        else:
            raise RuntimeError(f"tid {tid}: exceeded {max_steps} steps (infinite loop?)")
    return data


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prog", required=True)
    ap.add_argument("--meta", required=True)
    ap.add_argument("--frame", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--words", type=int, default=32768)
    args = ap.parse_args()

    with open(args.meta) as f:
        meta = json.load(f)
    threads, src, dst = meta["threads"], meta["src"], meta["dst"]

    prog = read_hex_words(args.prog)
    data = [0] * args.words
    frame = read_hex_words(args.frame)
    data[src:src + len(frame)] = frame

    run(prog, data, threads, src, dst)

    with open(args.out, "w") as f:
        for w in data:
            f.write(f"{w & WORD_MASK:08x}\n")
    print(f"isa_sim: ran {threads} threads, wrote {args.out}")


if __name__ == "__main__":
    main()
