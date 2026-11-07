# Toolchain

All items verified 2026-11-07 on the actual machines.

| Item | Value |
|---|---|
| Simulator | Verilator 5.052 (`/usr/bin/verilator`, Linux host) |
| Python | `python3`, venv `.venv` (numpy, Pillow), created with `uv venv` |
| Vivado | 2026.1 at `/mnt/windows/vivado_linux/2026.1/Vivado/bin/vivado`, runs on the Linux host (2025.2 install there is partial, no `bin/`) |
| Board files | TUL `pynq-z2/A.0/board.xml`, from `linux_projects/rv32-linux/build/fpga/board_repo` (override with `XLR8_BOARD_REPO`) |
| FPGA part | `xc7z020clg400-1`, board part `tul.com.tw:pynq-z2:part0:1.0` |
| Board | PYNQ-Z2 on Wi-Fi, user `xilinx`, SSH password auth. The DHCP address changes across reboots (was `.4`, then `.3`); `tools/board/common.sh` finds it by scanning for ssh plus Jupyter (port 9090) |
| Board OS | PynqLinux (Ubuntu 22.04), kernel `5.15.19-xilinx-v2022.1`, armv7l, 2 cores |
| Board memory | `mem=448M` from `/boot/uEnv.txt` (rv32-linux reservation, top 64 MiB of DDR is not Linux's), 430 MB visible, CMA 128 MB (`CONFIG_DMA_CMA=y`) |
| Board kernel features | `CONFIG_MODULES=y`, `CONFIG_UIO_PDRV_GENIRQ=m`, `CONFIG_CMA=y`, `/dev/uio0..1` present, `configfs` mounted |
| Board toolchain | native `gcc`, `make`; kernel tree at `/usr/src/kernel` needed `sudo make modules_prepare` once (about 25 min on the board) before out-of-tree modules would build. Module build is native, no cross compiler needed |
| Board base device tree | already has PYNQ's `fabric@40000000` generic-uio node (64 KB, IRQ 61), so XLR8 uses `0x40010000` and `IRQ_F2P[1]` instead |
| PYNQ python | use `/usr/local/share/pynq-venv/bin/python` with `XILINX_XRT=/usr`, not from `/home/xilinx` |
| sudo on board | needs the same password |
| Device-tree compiler | `/usr/bin/dtc` on the host |

## Build commands

    make test                                  # all simulation tests
    vivado -mode batch -source fpga/pynq_z2/build.tcl -tclargs until bit    # about 20 min
    tools/board/run_bringup.sh 100             # userspace bring-up (PYNQ overlay + /dev/mem)
    tools/board/run_driver_tests.sh 1000 10000 # build driver on the board, load overlay, run tests

The board password is never stored in the repo. `run_bringup.sh` reads it through `SSH_ASKPASS`.

## Lessons carried over from rv32-linux

- The PS HP ports power up in 64-bit mode and the bitstream cannot change that. Set
  `AFI_RDCHAN_CTRL`/`AFI_WRCHAN_CTRL` bit 0 (FabricWidth) at `0xF8008000` + `0x00`/`0x14` for HP0.
  `tools/board/bringup.py` does this.
- Reserving DDR for the GPU: the top 64 MiB is already outside Linux's 448 MiB. Phase 4 can use
  PYNQ `allocate` (CMA), which is simpler.
