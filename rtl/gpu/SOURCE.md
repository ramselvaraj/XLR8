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
- RTL changes (Phase 3, for FPGA timing):
  - new `seq_div.sv`, a 32-cycle sequential unsigned divider.
  - `alu.sv`: parameter `HAS_DIV` (default 1, unchanged behavior). With 0, DIV is not built.
  - `warp.sv`: parameter `FAST_DIV` (default 1, unchanged behavior). With 0, DIV runs on `seq_div`
    in a new `W_DIV` state (warp not requesting the bus while dividing).
  - `simt_gpu.sv`: parameter `FAST_DIV` passed through. `xlr8_top` sets it to 0.
  - `tb/system/tb_gpu.sv`: parameter `FAST_DIV` to test both.
- `input_images/` was not copied. `tools/run_sim.py` falls back to its built-in test pattern.

Record every later change to files here in this list.
