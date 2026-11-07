#!/usr/bin/env python3
"""Validate a Phase 3 RTL trace produced by tb_gpu.sv (+trace=<path>).

Checks:
  - both passes started and completed
  - both warps received grants
  - no write targeted the source framebuffer
  - every destination pixel written exactly once
  - total reads/writes match the expected 3x3 clamped-blur traffic

Usage:
    check_trace.py --trace build/run/trace64/trace.txt
"""
import argparse
import re
import sys

# Expected memory traffic for a complete 3x3 clamped blur (per size).
EXPECT_READS = {16: 2304, 32: 9216, 64: 36864}
EXPECT_WRITES = {16: 256, 32: 1024, 64: 4096}

KV = re.compile(r"(\w+)=(\S+)")


def parse(path):
    cfg, starts, dones, summary = {}, [], [], {}
    reads, writes, grants = [], [], {0: 0, 1: 0}
    with open(path) as f:
        for line in f:
            toks = dict(KV.findall(line))
            if line.startswith("CONFIG"):
                cfg = {k: int(v) for k, v in toks.items()}
            elif line.startswith("PASS_START"):
                starts.append(toks.get("pass"))
            elif line.startswith("PASS_DONE"):
                dones.append(toks.get("pass"))
            elif line.startswith("GRANT"):
                grants[int(toks["warp"])] = grants.get(int(toks["warp"]), 0) + 1
            elif line.startswith("BUS"):
                if toks.get("op") == "read":
                    reads.append(int(toks["addr"]))
                elif toks.get("op") == "write":
                    writes.append((int(toks["addr"]), int(toks["data"], 16)))
            elif line.startswith("SUMMARY"):
                summary = {k: int(v) for k, v in toks.items()}
    return cfg, starts, dones, summary, reads, writes, grants


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--trace", required=True)
    args = ap.parse_args()

    cfg, starts, dones, summary, reads, writes, grants = parse(args.trace)
    errors = []

    W, H = cfg.get("width", 0), cfg.get("height", 0)
    src, dst = cfg.get("src", 0), cfg.get("dst", 0)
    count = W * H
    print(f"trace: {W}x{H} src={src} dst={dst}")

    # Passes.
    if not starts or not dones:
        errors.append("missing PASS_START/PASS_DONE")
    for p in starts:
        if p not in dones:
            errors.append(f"pass {p!r} started but never completed")
    print(f"passes: started={starts} done={dones}")

    # Grants.
    if grants.get(0, 0) == 0 or grants.get(1, 0) == 0:
        errors.append(f"a warp received no grants: {grants}")
    print(f"grants: {grants}")

    # Source preservation.
    bad_src = [a for (a, _) in writes if src <= a < src + count]
    if bad_src:
        errors.append(f"{len(bad_src)} writes to source framebuffer")

    # Exactly one write per destination pixel.
    dst_writes = [a for (a, _) in writes if dst <= a < dst + count]
    seen = {}
    for a in dst_writes:
        seen[a] = seen.get(a, 0) + 1
    dup = {a: n for a, n in seen.items() if n != 1}
    if dup:
        errors.append(f"{len(dup)} destination pixels not written exactly once")
    if len(seen) != count:
        errors.append(f"only {len(seen)}/{count} destination pixels written")

    # Traffic totals.
    if W in EXPECT_READS:
        if len(reads) != EXPECT_READS[W]:
            errors.append(f"reads {len(reads)} != expected {EXPECT_READS[W]}")
        if len(writes) != EXPECT_WRITES[W]:
            errors.append(f"writes {len(writes)} != expected {EXPECT_WRITES[W]}")
    if summary:
        if summary.get("reads") != len(reads):
            errors.append(f"SUMMARY reads {summary.get('reads')} != {len(reads)}")
        if summary.get("writes") != len(writes):
            errors.append(f"SUMMARY writes {summary.get('writes')} != {len(writes)}")
        if summary.get("cycles", 0) <= 0:
            errors.append("SUMMARY cycles <= 0")
        print(f"summary: {summary}")

    print(f"traffic: reads={len(reads)} writes={len(writes)}")

    if errors:
        for e in errors:
            print(f"FAIL: {e}")
        sys.exit(1)
    print("TRACE PASS")


if __name__ == "__main__":
    main()
