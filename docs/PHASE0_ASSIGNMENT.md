# Phase 0: Import, Baseline, Tooling

## Goal

Get the RAPTOR GPU building and passing its existing tests inside this repo, and settle the
toolchain questions that would otherwise block later phases.

## Starting points

- `../riscv/RAPTOR-SoC/simt_gpu/rtl/*.sv`, `tb/`, `tools/`, `sw/kernels/`
- `../riscv/RAPTOR-SoC/docs/GPU_ISA.md`, `BUS_PROTOCOL.md`

## Tasks

1. Copy the GPU RTL into `rtl/gpu/`, tools into `tools/`, kernels into `sw/kernels/`. Do not
   require a sibling checkout to build.
2. Write `rtl/gpu/SOURCE.md` recording the RAPTOR-SoC commit hash, copy date, and any local
   changes.
3. Add a top-level `Makefile` with targets `lint`, `test-gpu`, `test`.
4. Run the existing GPU unit and system tests here and record that they pass.
5. Decide where Vivado runs. Record machine, OS, and version in `docs/TOOLCHAIN.md`.
6. Decide the board image. Record the PYNQ image version and `uname -r` after booting the board.
7. Record the cross compiler, or decide to build natively on the board.
8. Confirm board access: serial console, network, SSH, and a way to copy files.

## Scope decisions

| Decision | Choice |
|---|---|
| Vendoring | Copy, pinned commit, no submodule |
| GPU changes | None in this phase |
| CPU, caches, CDC | Not imported |
| Simulator | Verilator |

## Exit criteria

- `make lint` is clean on `rtl/gpu/`.
- `make test-gpu` reproduces the RAPTOR GPU results.
- `docs/TOOLCHAIN.md` answers: where Vivado runs, board image and kernel version, cross
  compiler, board access method.
- `rtl/gpu/SOURCE.md` exists.
