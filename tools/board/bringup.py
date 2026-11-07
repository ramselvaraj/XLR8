#!/usr/bin/env python3
"""XLR8 hardware bring-up on the PYNQ-Z2 (Phase 4). Runs ON the board:

    cd /tmp && sudo env XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python bringup.py \
        --bit xlr8.bit --prog ball.hex --frames 100

Loads the bitstream, forces HP0 to 32-bit, maps the XLR8 registers at 0x4000_0000 through
/dev/mem, loads the GPU program through the program window, renders the ball animation into a
physically contiguous buffer and compares every frame to the independent reference.
"""
import argparse
import mmap
import os
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import animate_ref  # noqa: E402
import ball_ref     # noqa: E402

BASE = 0x40000000
R = dict(CTRL=0x00, STATUS=0x04, THREADS=0x08, SRC=0x0C, DST=0x10, PROG=0x14, MBASE=0x18,
         MLIM=0x1C, IRQ=0x20, CYC=0x24, XACT=0x28, STALL=0x2C, ERRA=0x30, ID=0x34, VER=0x38,
         ARG0=0x3C, ARG1=0x40, WIN=0x1000)
SRC_W, DST_W = 0x2000, 0x6000          # GPU word offsets (match the kernels)
BUF_BYTES = 0x20000                    # 32768 words


def set_hp0_32bit(fd):
    """HP ports power up in 64-bit mode and the bitstream cannot change it (see rv32-linux notes)."""
    regs = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=0xF8008000)
    for off in (0x00, 0x14):                       # AFI_RDCHAN_CTRL, AFI_WRCHAN_CTRL
        v = struct.unpack_from("<I", regs, off)[0]
        struct.pack_into("<I", regs, off, v | 1)
    vals = [struct.unpack_from("<I", regs, o)[0] for o in (0x00, 0x14)]
    regs.close()
    return vals


class Regs:
    def __init__(self, fd):
        self.m = mmap.mmap(fd, 0x2000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=BASE)

    def rd(self, name_or_off):
        off = R[name_or_off] if isinstance(name_or_off, str) else name_or_off
        return struct.unpack_from("<I", self.m, off)[0]

    def wr(self, name_or_off, v):
        off = R[name_or_off] if isinstance(name_or_off, str) else name_or_off
        struct.pack_into("<I", self.m, off, v & 0xFFFFFFFF)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bit", default="xlr8.bit")
    ap.add_argument("--prog", required=True, help="hex file, one 16-bit instruction per line")
    ap.add_argument("--frames", type=int, default=20)
    ap.add_argument("--kernel", default="ball", choices=["ball"])
    ap.add_argument("--no-load", action="store_true", help="bitstream already loaded")
    ap.add_argument("--timeout", type=float, default=5.0)
    a = ap.parse_args()

    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    if not a.no_load:
        from pynq import Overlay          # loads .bit and the .hwh next to it, sets FCLK0
        Overlay(a.bit)
    print("HP0 AFI regs after set:", [hex(v) for v in set_hp0_32bit(fd)])

    x = Regs(fd)
    ident = x.rd("ID")
    print(f"ID = {ident:08x}  VERSION = {x.rd('VER'):08x}  STATUS = {x.rd('STATUS'):08x}")
    if ident != 0x584C5238:
        sys.exit("FAIL: ID register mismatch (bitstream not loaded, or wrong address)")

    from pynq import allocate
    import numpy as np
    buf = allocate(shape=(BUF_BYTES // 4,), dtype=np.uint32, cacheable=False)
    phys = buf.physical_address
    print(f"buffer physical address {phys:#x}, {BUF_BYTES} bytes")

    prog = [int(t, 16) for line in open(a.prog) for t in line.split()]
    for w in range((len(prog) + 1) // 2):
        lo = prog[2 * w]
        hi = prog[2 * w + 1] if 2 * w + 1 < len(prog) else 0
        x.wr(R["WIN"] + 4 * w, (hi << 16) | lo)
    for w in range((len(prog) + 1) // 2):
        want = (((prog[2 * w + 1] if 2 * w + 1 < len(prog) else 0) << 16) | prog[2 * w])
        got = x.rd(R["WIN"] + 4 * w)
        if got != want:
            sys.exit(f"FAIL: program window readback word {w}: {got:08x} != {want:08x}")
    print(f"loaded {len(prog)} instructions")

    cyc = []
    for n, p in enumerate(animate_ref.frames(a.frames)):
        block = ball_ref.param_block(*p)
        buf[:] = 0
        for i, v in enumerate(block):
            buf[SRC_W + i] = v
        buf.flush()
        x.wr("THREADS", 4096); x.wr("SRC", SRC_W); x.wr("DST", DST_W)
        x.wr("MBASE", phys); x.wr("MLIM", BUF_BYTES); x.wr("PROG", 0)
        x.wr("CTRL", 1)
        t0 = time.time()
        while x.rd("STATUS") & 1:
            if time.time() - t0 > a.timeout:
                x.wr("CTRL", 2)
                sys.exit(f"FAIL: frame {n} timed out, STATUS={x.rd('STATUS'):08x}")
        st = x.rd("STATUS")
        if st & 0xF != 0x2:
            sys.exit(f"FAIL: frame {n} STATUS={st:08x} ERR_ADDR={x.rd('ERRA'):08x}")
        buf.invalidate()
        got = [int(buf[DST_W + i]) for i in range(ball_ref.W * ball_ref.H)]
        ref = ball_ref.render(*p)
        if got != ref:
            i = next(i for i in range(len(ref)) if got[i] != ref[i])
            sys.exit(f"FAIL: frame {n} pixel {i} got {got[i]:08x} expected {ref[i]:08x}")
        cyc.append((x.rd("CYC"), x.rd("XACT"), x.rd("STALL")))
    c, xa, s = cyc[0]
    print(f"PASS: {a.frames} frames exact on hardware")
    print(f"frame 0: CYCLES={c} BUS_XACTS={xa} BUS_STALLS={s}")
    print(f"mean CYCLES={sum(v[0] for v in cyc)/len(cyc):.0f}  min={min(v[0] for v in cyc)}  max={max(v[0] for v in cyc)}")
    buf.freebuffer()


if __name__ == "__main__":
    main()
