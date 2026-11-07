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
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import animate_ref  # noqa: E402
import ball_ref     # noqa: E402

BASE = 0x40010000
R = dict(CTRL=0x00, STATUS=0x04, THREADS=0x08, SRC=0x0C, DST=0x10, PROG=0x14, MBASE=0x18,
         MLIM=0x1C, IRQ=0x20, CYC=0x24, XACT=0x28, STALL=0x2C, ERRA=0x30, ID=0x34, VER=0x38,
         ARG0=0x3C, ARG1=0x40, WIN=0x1000)
SRC_W, DST_W = 0x2000, 0x6000          # GPU word offsets (match the kernels)
BUF_BYTES = 0x20000                    # 32768 words


def words(fd, base, size):
    """32-bit view of a physical register block. Zynq PS/PL registers need 32-bit accesses:
    byte accesses (struct.unpack_from on an mmap) raise an external abort."""
    import numpy as np
    m = mmap.mmap(fd, size, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=base)
    return m, np.frombuffer(m, dtype=np.uint32)


def set_hp0_32bit(fd):
    """HP ports power up in 64-bit mode and the bitstream cannot change it (see rv32-linux notes)."""
    m, v = words(fd, 0xF8008000, 0x1000)
    for off in (0x00, 0x14):                       # AFI_RDCHAN_CTRL, AFI_WRCHAN_CTRL
        v[off // 4] = int(v[off // 4]) | 1
    vals = [int(v[o // 4]) for o in (0x00, 0x14)]
    del v
    m.close()
    return vals


class Regs:
    def __init__(self, fd):
        self.m, self.v = words(fd, BASE, 0x2000)

    def rd(self, name_or_off):
        off = R[name_or_off] if isinstance(name_or_off, str) else name_or_off
        return int(self.v[off // 4])

    def wr(self, name_or_off, val):
        off = R[name_or_off] if isinstance(name_or_off, str) else name_or_off
        self.v[off // 4] = val & 0xFFFFFFFF


def load_prog(x, path):
    prog = [int(t, 16) for line in open(path) for t in line.split()]
    for w in range((len(prog) + 1) // 2):
        lo = prog[2 * w]
        hi = prog[2 * w + 1] if 2 * w + 1 < len(prog) else 0
        x.wr(R["WIN"] + 4 * w, (hi << 16) | lo)
    for w in range((len(prog) + 1) // 2):
        want = (((prog[2 * w + 1] if 2 * w + 1 < len(prog) else 0) << 16) | prog[2 * w])
        got = x.rd(R["WIN"] + 4 * w)
        if got != want:
            sys.exit(f"FAIL: program window readback word {w}: {got:08x} != {want:08x}")
    return len(prog)


def start_frame(x, buf, phys, p, limit=BUF_BYTES, clear=True, start=True):
    block = ball_ref.param_block(*p)
    if clear:
        buf[:] = 0
    for i, v in enumerate(block):
        buf[SRC_W + i] = v
    buf.flush()
    x.wr("THREADS", 4096); x.wr("SRC", SRC_W); x.wr("DST", DST_W)
    x.wr("MBASE", phys); x.wr("MLIM", limit); x.wr("PROG", 0)
    if start:
        x.wr("CTRL", 1)


def wait_idle(x, timeout):
    t0 = time.time()
    while x.rd("STATUS") & 1:
        if time.time() - t0 > timeout:
            x.wr("CTRL", 2)
            sys.exit(f"FAIL: timed out, STATUS={x.rd('STATUS'):08x}")
    return x.rd("STATUS")


def frame_pixels(buf):
    buf.invalidate()
    return [int(v) for v in buf[DST_W:DST_W + ball_ref.W * ball_ref.H]]


def render_frames(x, buf, phys, n, timeout, quiet=False):
    stats = []
    for k, p in enumerate(animate_ref.frames(n)):
        start_frame(x, buf, phys, p)
        st = wait_idle(x, timeout)
        if st & 0xF != 0x2:
            sys.exit(f"FAIL: frame {k} STATUS={st:08x} ERR_ADDR={x.rd('ERRA'):08x}")
        got = frame_pixels(buf)
        ref = ball_ref.render(*p)
        if got != ref:
            i = next(i for i in range(len(ref)) if got[i] != ref[i])
            sys.exit(f"FAIL: frame {k} pixel {i} got {got[i]:08x} expected {ref[i]:08x}")
        stats.append((x.rd("CYC"), x.rd("XACT"), x.rd("STALL")))
    return stats


def in_child(fn):
    """Run fn() in a forked child; return ('ok', None) or ('signal', signum)."""
    pid = os.fork()
    if pid == 0:
        try:
            fn()
        finally:
            os._exit(0)
    _, status = os.waitpid(pid, 0)
    if os.WIFSIGNALED(status):
        return "signal", os.WTERMSIG(status)
    return "ok", os.WEXITSTATUS(status)


def test_errors(x, buf, phys, timeout):
    import signal
    base = list(animate_ref.frames(1))[0]
    out = {}
    # 1. START while BUSY (SLVERR if SLVERR_EN=1)
    def start_then(second):
        def f():
            x.wr("CTRL", 1)          # job runs for ~9 ms, so the next access is certainly while BUSY
            second()
        return f
    start_frame(x, buf, phys, base, start=False)
    out["start_while_busy"] = in_child(start_then(lambda: x.wr("CTRL", 1)))
    st = wait_idle(x, timeout)
    ok = (st & 0xF) in (0x2, 0xA)
    print(f"  START while BUSY: child {out['start_while_busy']}, job still finished: {ok}, STATUS={st:08x}")
    got = frame_pixels(buf)
    print("  running job unaffected:", got == ball_ref.render(*base))
    # 2. program window write while BUSY
    w0 = x.rd(R["WIN"])
    start_frame(x, buf, phys, base, start=False)
    out["prog_while_busy"] = in_child(start_then(lambda: x.wr(R["WIN"], 0xFFFFFFFF)))
    wait_idle(x, timeout)
    print(f"  program write while BUSY: child {out['prog_while_busy']}; window word0 {w0:08x} -> {x.rd(R['WIN']):08x}")
    # 3. unmapped read
    out["unmapped_read"] = in_child(lambda: x.rd(0x1800))
    print(f"  unmapped read 0x1800: child {out['unmapped_read']}")
    # 4. out-of-range window -> ERROR flag, job finishes
    start_frame(x, buf, phys, base, limit=(SRC_W + 8) * 4)
    st = wait_idle(x, timeout)
    print(f"  small MEM_LIMIT: STATUS={st:08x} ERR_ADDR={x.rd('ERRA'):08x} IRQ_STATUS={x.rd('IRQ'):x}")
    # 5. recovery: clean job clears everything
    start_frame(x, buf, phys, base)
    st = wait_idle(x, timeout)
    print(f"  clean job after error: STATUS={st:08x} ERR_ADDR={x.rd('ERRA'):08x} pixels ok={frame_pixels(buf) == ball_ref.render(*base)}")
    # 6. soft reset mid-job then clean job
    for delay in (0.0, 0.0005, 0.002):
        start_frame(x, buf, phys, base)
        time.sleep(delay)
        x.wr("CTRL", 2)
        t0 = time.time()
        while x.rd("STATUS") & 1 and time.time() - t0 < 1:
            pass
        start_frame(x, buf, phys, base)
        st = wait_idle(x, timeout)
        good = (st & 0xF) == 0x2 and frame_pixels(buf) == ball_ref.render(*base)
        print(f"  soft reset after {delay*1000:.1f} ms, then clean job: ok={good}")
    names = {signal.SIGBUS: "SIGBUS", signal.SIGSEGV: "SIGSEGV"}
    print("  note: on this ARM an AXI SLVERR from the PL is a bus error to the accessing process")
    for k, (kind, v) in out.items():
        if kind == "signal":
            print(f"  RESULT {k}: child killed by {names.get(v, v)}")
        else:
            print(f"  RESULT {k}: child exited normally")


def test_coherence(x, phys_unused, timeout):
    """Is a cacheable buffer coherent with the GPU's HP-port writes? (Zynq HP ports are not.)"""
    from pynq import allocate
    import numpy as np
    base = list(animate_ref.frames(1))[0]
    cb = allocate(shape=(BUF_BYTES // 4,), dtype=np.uint32, cacheable=True)
    ph = cb.physical_address
    cb[:] = 0xDEADBEEF
    cb.flush()
    block = ball_ref.param_block(*base)
    for i, v in enumerate(block):
        cb[SRC_W + i] = v
    cb.flush()
    cb[DST_W:DST_W + 4096] = 0xDEADBEEF          # stale sentinel, now in the CPU cache
    cb.flush()
    _ = [int(v) for v in cb[DST_W:DST_W + 4096]]  # pull the lines into the cache
    x.wr("THREADS", 4096); x.wr("SRC", SRC_W); x.wr("DST", DST_W)
    x.wr("MBASE", ph); x.wr("MLIM", BUF_BYTES); x.wr("PROG", 0); x.wr("CTRL", 1)
    wait_idle(x, timeout)
    ref = ball_ref.render(*base)
    stale = [int(v) for v in cb[DST_W:DST_W + 4096]]
    n_stale = sum(1 for a, b in zip(stale, ref) if a != b)
    cb.invalidate()
    fresh = [int(v) for v in cb[DST_W:DST_W + 4096]]
    n_fresh = sum(1 for a, b in zip(fresh, ref) if a != b)
    print(f"  cacheable buffer, read without invalidate: {n_stale} of 4096 pixels wrong")
    print(f"  cacheable buffer, after invalidate():      {n_fresh} of 4096 pixels wrong")
    cb.freebuffer()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bit", default="xlr8.bit")
    ap.add_argument("--prog", required=True, help="hex file, one 16-bit instruction per line")
    ap.add_argument("--frames", type=int, default=20)
    ap.add_argument("--no-load", action="store_true", help="bitstream already loaded")
    ap.add_argument("--timeout", type=float, default=5.0)
    ap.add_argument("--errors", action="store_true")
    ap.add_argument("--coherence", action="store_true")
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
    print(f"buffer physical address {phys:#x}, {BUF_BYTES} bytes (non-cacheable)")
    print(f"loaded {load_prog(x, a.prog)} instructions")

    if a.errors:
        print("error paths on hardware:")
        test_errors(x, buf, phys, a.timeout)
    elif a.coherence:
        print("cache coherence:")
        test_coherence(x, phys, a.timeout)
    else:
        t0 = time.time()
        stats = render_frames(x, buf, phys, a.frames, a.timeout)
        dt = time.time() - t0
        c, xa, s = stats[0]
        print(f"PASS: {a.frames} frames exact on hardware ({dt:.1f} s wall, {a.frames/dt:.1f} frames/s incl. python checking)")
        print(f"frame 0: CYCLES={c} BUS_XACTS={xa} BUS_STALLS={s}")
        cy = [v[0] for v in stats]
        print(f"CYCLES mean={sum(cy)/len(cy):.0f} min={min(cy)} max={max(cy)}  "
              f"(at 50 MHz: {sum(cy)/len(cy)*20e-6:.2f} ms/frame)")
    buf.freebuffer()


if __name__ == "__main__":
    main()
