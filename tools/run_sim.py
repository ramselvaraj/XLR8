#!/usr/bin/env python3
"""Host driver: assemble -> golden model -> (optional RTL) -> PNG.

    kernel.asm -> prog.hex
    image      -> frame.hex
    isa_sim    -> expected.hex        (golden ISA model)
    (interior) -> blur_ref cross-check (independent reference)
    Verilated tb_gpu -> out.hex
    compare + render out.png

Usage::

    run_sim.py                                   # brighten, built-in pattern
    run_sim.py --golden-only                     # skip RTL, just the model
    run_sim.py --kernel sw/kernels/blur.asm      # interior blur (uses .gen_blur)
    run_sim.py --image in.png --width 64 --height 64
"""
import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import assemble    # noqa: E402
import blur_ref    # noqa: E402
import img_to_mem  # noqa: E402
import isa_sim     # noqa: E402
import mem_to_img  # noqa: E402

WORDS = 32768
SRC_ADDR = 0x2000
DST_ADDR = 0x6000


def run_full_frame(args, P):
    """Phase 3: interior pass + border pass, clamped full-frame blur."""
    W, H = args.width, args.height
    if W < 3 or H < 3:
        sys.exit(f"FAIL: full-frame blur needs W,H >= 3 (got {W}x{H})")

    src, dst = SRC_ADDR, DST_ADDR
    prog_i, meta_i = assemble.assemble(
        f".gen_blur {W} {H}\n.src {src:#x}\n.dst {dst:#x}\n")[:2]
    prog_b, meta_b = assemble.assemble(
        f".gen_blur_border {W} {H}\n.src {src:#x}\n.dst {dst:#x}\n")[:2]
    ti, tb = meta_i["threads"], meta_b["threads"]
    count = W * H
    print(f"assemble: interior {len(prog_i)} instr ({ti} threads), "
          f"border {len(prog_b)} instr ({tb} threads)")

    frame_hex, frame_json = P("frame.hex"), P("frame.json")
    out_hex, out_png = P("out.hex"), P("out.png")
    prog_i_hex, prog_b_hex = P("prog.hex"), P("prog2.hex")
    trace_hex = P("trace.txt")

    img_to_mem.generate(args.image, W, H, frame_hex, frame_json)
    frame = isa_sim.read_hex_words(frame_hex)[:count]

    # Golden model: both passes over one data-memory image.
    data = [0] * WORDS
    data[src:src + count] = frame
    isa_sim.run(prog_i, data, ti, src, dst)
    isa_sim.run(prog_b, data, tb, src, dst)
    expected = list(data)

    ref = blur_ref.box_blur_clamped(frame, W, H)
    bad = [p for p in range(count) if expected[dst + p] != ref[p]]
    if bad:
        p = bad[0]
        sys.exit(f"FAIL: model disagrees with blur reference at pixel {p} "
                 f"(model {expected[dst+p]:06x} vs ref {ref[p]:06x})")
    print(f"golden: isa_sim matches clamped reference on all {count} pixels")

    if args.golden_only:
        with open(out_hex, "w") as f:
            f.write("".join(f"{expected[dst+i] & 0x00FFFFFF:08x}\n" for i in range(count)))
        _, _, path = mem_to_img.write_image(out_hex, frame_json, out_png)
        print(f"GOLDEN: {count} pixels -> {path}")
        return

    with open(prog_i_hex, "w") as f:
        f.write("".join(f"{w & 0xFFFF:04x}\n" for w in prog_i))
    with open(prog_b_hex, "w") as f:
        f.write("".join(f"{w & 0xFFFF:04x}\n" for w in prog_b))

    if not os.path.exists(args.binary):
        sys.exit(f"error: verilated binary not found: {args.binary}\nrun `make build` first")
    cmd = [
        args.binary,
        f"+frame={frame_hex}", f"+out={out_hex}",
        f"+prog={prog_i_hex}", f"+count={ti}",
        f"+prog2={prog_b_hex}", f"+count2={tb}",
        f"+src={src}", f"+dst={dst}",
        f"+width={W}", f"+height={H}",
        f"+pass1=interior", f"+pass2=border",
    ]
    if args.trace:
        cmd.append(f"+trace={trace_hex}")
    print("run:", " ".join(cmd))
    try:
        subprocess.run(cmd, check=True, cwd=args.workdir)
    except subprocess.CalledProcessError:
        sys.exit("FAIL: RTL simulation did not complete (timeout or abort).")

    actual = isa_sim.read_hex_words(out_hex)
    mism = [i for i in range(count) if actual[dst + i] != expected[dst + i]]
    if mism:
        i = mism[0]
        sys.exit(f"FAIL: {len(mism)}/{count} pixel mismatches "
                 f"(first at {i}: got {actual[dst+i]:06x} expected {expected[dst+i]:06x})")
    src_touched = [i for i in range(count) if actual[src + i] != frame[i]]
    if src_touched:
        sys.exit(f"FAIL: source buffer modified at {len(src_touched)} words")

    with open(out_hex, "w") as f:
        f.write("".join(f"{actual[dst+i] & 0x00FFFFFF:08x}\n" for i in range(count)))
    _, _, path = mem_to_img.write_image(out_hex, frame_json, out_png)
    print(f"PASS: {count} pixels ({ti}+{tb} threads), 0 mismatches -> {path}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kernel", default=os.path.join(ROOT, "sw", "kernels", "brighten.asm"))
    ap.add_argument("--image", default=None, help="input image (needs Pillow)")
    ap.add_argument("--width", type=int, default=16)
    ap.add_argument("--height", type=int, default=16)
    ap.add_argument("--binary", default=os.path.join(ROOT, "build", "obj", "Vtb_gpu"))
    ap.add_argument("--workdir", default=os.path.join(ROOT, "build", "run"))
    ap.add_argument("--golden-only", action="store_true", help="skip the RTL sim")
    ap.add_argument("--full", action="store_true",
                    help="Phase 3 clamped full-frame blur (interior + border)")
    ap.add_argument("--trace", action="store_true", help="emit an RTL trace")
    args = ap.parse_args()

    args.workdir = os.path.abspath(args.workdir)
    args.binary = os.path.abspath(args.binary)
    os.makedirs(args.workdir, exist_ok=True)
    P = lambda name: os.path.join(args.workdir, name)  # noqa: E731

    if args.full:
        run_full_frame(args, P)
        return

    frame_hex, frame_json = P("frame.hex"), P("frame.json")
    prog_hex, prog_json = P("prog.hex"), P("prog.json")
    out_hex, out_png = P("out.hex"), P("out.png")

    # 1. Assemble.
    with open(args.kernel) as f:
        prog, meta = assemble.assemble(f.read())[:2]
    with open(prog_hex, "w") as f:
        f.write("".join(f"{w & 0xFFFF:04x}\n" for w in prog))
    with open(prog_json, "w") as f:
        json.dump(meta, f)
    print(f"assemble: {args.kernel} -> {len(prog)} instr, {meta}")

    interior = bool(meta.get("interior"))
    threads, src, dst = meta["threads"], meta["src"], meta["dst"]
    if interior:
        W, H = meta["width"], meta["height"]
    else:
        W, H = args.width, args.height
        if threads != W * H:
            sys.exit(f"FAIL: kernel .threads={threads} but image is {W*H} pixels")
    count = W * H

    # 2. Frame.
    img_to_mem.generate(args.image, W, H, frame_hex, frame_json)
    frame = isa_sim.read_hex_words(frame_hex)[:count]

    # 3. Golden ISA model.
    data = [0] * WORDS
    data[src:src + count] = frame
    isa_sim.run(prog, data, threads, src, dst)
    expected = list(data)

    # 4. Independent reference for interior blur (catches assembler/kernel bugs).
    if interior:
        ref = blur_ref.box_blur_interior(frame, W, H)
        bad = [p for p in range(count) if expected[dst + p] != ref[p]]
        if bad:
            p = bad[0]
            sys.exit(f"FAIL: kernel/model disagree with blur reference at pixel {p} "
                     f"(model {expected[dst+p]:06x} vs ref {ref[p]:06x})")
        print(f"golden: isa_sim matches blur reference on all {count} pixels")

    if args.golden_only:
        with open(out_hex, "w") as f:
            f.write("".join(f"{expected[dst+i] & 0x00FFFFFF:08x}\n" for i in range(count)))
        _, _, path = mem_to_img.write_image(out_hex, frame_json, out_png)
        print(f"GOLDEN: {threads} threads -> {path}")
        return

    # 5. RTL simulation.
    if not os.path.exists(args.binary):
        sys.exit(f"error: verilated binary not found: {args.binary}\nrun `make build` first")
    cmd = [
        args.binary,
        f"+frame={frame_hex}", f"+prog={prog_hex}", f"+out={out_hex}",
        f"+count={threads}", f"+src={src}", f"+dst={dst}",
    ]
    print("run:", " ".join(cmd))
    try:
        subprocess.run(cmd, check=True, cwd=args.workdir)
    except subprocess.CalledProcessError:
        sys.exit("FAIL: RTL simulation did not complete (timeout or abort).\n"
                 "      Implement/verify the Phase 2 ALU ops, then retry.")

    actual = isa_sim.read_hex_words(out_hex)

    # 6. Compare.
    mism = [i for i in range(count) if actual[dst + i] != expected[dst + i]]
    if mism:
        i = mism[0]
        sys.exit(f"FAIL: {len(mism)}/{count} pixel mismatches "
                 f"(first at {i}: got {actual[dst+i]:06x} expected {expected[dst+i]:06x})")
    src_touched = [i for i in range(count) if actual[src + i] != frame[i]]
    if src_touched:
        sys.exit(f"FAIL: source buffer modified at {len(src_touched)} words")

    # 7. Render.
    with open(out_hex, "w") as f:
        f.write("".join(f"{actual[dst+i] & 0x00FFFFFF:08x}\n" for i in range(count)))
    _, _, path = mem_to_img.write_image(out_hex, frame_json, out_png)
    print(f"PASS: {threads} threads, 0 mismatches -> {path}")


if __name__ == "__main__":
    main()
