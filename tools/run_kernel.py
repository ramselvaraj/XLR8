#!/usr/bin/env python3
"""Run any kernel on the ISA simulator or the Verilated GPU (NARGS build), for tests.

run_isa / run_rtl return the words at `dst`. `init` is a list of words placed at `src` first.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import assemble  # noqa: E402
import isa_sim   # noqa: E402

BIN_ARGS = os.path.join(ROOT, "build", "obj_args", "Vtb_gpu")
WORDS = 32768


def load(kernel_path):
    prog, meta = assemble.assemble(open(kernel_path).read())[:2]
    return prog, meta


def run_isa(prog, threads, src, dst, n, init=None, args=None):
    data = [0] * WORDS
    if init:
        data[src:src + len(init)] = init
    isa_sim.run(prog, data, threads, src, dst, args=args)
    return data[dst:dst + n]


def run_rtl(prog, threads, src, dst, n, init=None, args=None, workdir=None):
    wd = workdir or os.path.join(ROOT, "build", "kernel_run")
    os.makedirs(wd, exist_ok=True)
    ph, fh, oh = (os.path.join(wd, x) for x in ("prog.hex", "frame.hex", "out.hex"))
    open(ph, "w").write("".join(f"{w & 0xFFFF:04x}\n" for w in prog))
    open(fh, "w").write("".join(f"{w & 0xFFFFFFFF:08x}\n" for w in (init or [0])))
    cmd = [BIN_ARGS, f"+frame={fh}", f"+prog={ph}", f"+out={oh}", f"+count={threads}", f"+src={src}", f"+dst={dst}"]
    for k, v in enumerate(args or []):
        cmd.append(f"+arg{k}={v & 0xFFFFFFFF}")
    subprocess.run(cmd, check=True, cwd=wd, stdout=subprocess.DEVNULL)
    out = isa_sim.read_hex_words(oh)
    return out[dst:dst + n]
