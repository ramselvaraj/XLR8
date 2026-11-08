#!/usr/bin/env python3
"""Phase 8 progress chart: ball frame time at each optimisation step, against the ARM."""
import csv
import os
import statistics as st

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

R = "results"


def med(path):
    rows = [r for r in csv.reader(open(path)) if r and not r[0].startswith(("#", "impl"))]
    return st.median(float(r[3]) / 1e6 for r in rows)


steps = [("Phase 7 baseline\n(6 transactions/pixel)", "bench", "ball"),
         ("+ kernel arguments\n(1 transaction/pixel)", "bench_step1_args", "balla"),
         ("+ posted writes", "bench_step2_posted", "balla")]
sizes = [("64x64", "64"), ("128x128", "128"), ("256x256", "256")]
INK, MUTED, GRID = "#0b0b0b", "#52514e", "#e6e5e1"
COL = ["#2a78d6", "#eb6834", "#1baf7a"]          # fixed slots 1-3, one per step
fig, ax = plt.subplots(figsize=(9.5, 4.8))
bw = 0.25
for k, (label, d, kind) in enumerate(steps):
    xs, vals = [], []
    for j, (sz, n) in enumerate(sizes):
        name = f"ball{n}" if kind == "ball" else f"ball{n}a"
        p = f"{R}/{d}/xlr8_{name}.csv"
        if not os.path.exists(p):
            continue
        xs.append(j + (k - 1) * (bw + 0.02))
        vals.append(med(p))
    ax.bar(xs, vals, bw, color=COL[k], label=label.replace("\n", " "))
    for x, v in zip(xs, vals):
        ax.text(x, v * 1.1, f"{v:.3g}", ha="center", va="bottom", fontsize=8, color=INK)
# ARM reference (scalar C), drawn as markers with labels
arm = {n: med(f"{R}/bench/scalar_ball{n}.csv") for _, n in sizes}
for j, (sz, n) in enumerate(sizes):
    ax.plot([j - 0.42, j + 0.42], [arm[n]] * 2, color=INK, linewidth=1.5, linestyle=(0, (4, 2)))
    ax.text(j + 0.43, arm[n], f"ARM scalar\n{arm[n]:.3g} ms", fontsize=7.5, va="center", color=INK)
ax.set_yscale("log")
ax.set_ylim(0.03, 400)
ax.set_xlim(-0.6, 2.9)
ax.set_xticks(range(len(sizes)))
ax.set_xticklabels([s for s, _ in sizes])
ax.set_ylabel("frame time, ms (median; log scale)")
ax.grid(axis="y", color=GRID, linewidth=0.8)
ax.set_axisbelow(True)
for sp in ("top", "right"):
    ax.spines[sp].set_visible(False)
ax.legend(frameon=False, ncol=3, loc="lower center", bbox_to_anchor=(0.5, -0.2), fontsize=9)
ax.set_title("XLR8 ball frame time by optimisation step (dashed: ARM scalar C, same frame)", loc="left", fontsize=11)
fig.tight_layout()
fig.savefig(f"{R}/optimization.png", dpi=150)
print("wrote results/optimization.png")
