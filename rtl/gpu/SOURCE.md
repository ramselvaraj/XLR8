# Vendored source

The files in this directory, `tb/unit/`, `tb/system/tb_gpu.sv`, `tools/*.py`, `tools/tests/`, and
`sw/kernels/` were copied from the RAPTOR-SoC `simt_gpu/` tree.

| Field | Value |
|---|---|
| Source repo | `riscv/RAPTOR-SoC` (local, `github.com/ramselvaraj/RAPTOR-SoC`) |
| Source commit | `c96e6e9` ("docs: explain design and verification clearly") |
| Copied | 2026-11-07 |
| Source tree state | `simt_gpu/` unmodified at that commit (an unrelated docs file had local edits) |

## Local changes

- `rtl/gpu/files.txt` and the top-level `Makefile` use XLR8 paths (`rtl/gpu/`, `tb/system/`).
- `tb/tb_gpu.sv` moved to `tb/system/tb_gpu.sv`.
- RTL files themselves: no changes.
- `input_images/` was not copied. `tools/run_sim.py` falls back to its built-in test pattern.

Record every later change to files here in this list.
