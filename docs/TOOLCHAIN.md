# Toolchain

Status of each item as of Phase 0. "Verified" means checked on this machine or in existing
project docs. "Open" means it needs a decision or a check on real hardware.

| Item | Status | Detail |
|---|---|---|
| Simulator | Verified | Verilator 5.052 at `/usr/bin/verilator` (Linux, this machine) |
| Python | Verified | `python3`, project venv at `.venv` (numpy, Pillow) via `make venv` or `uv` |
| Lint | Verified | `make lint` clean (`verilator --lint-only -Wall`) |
| Device-tree compiler | Verified | `/usr/bin/dtc` |
| Host C compiler | Verified | `/usr/bin/gcc` |
| Vivado | **Open** | Not on this Linux machine's PATH, and no Xilinx folder found on the mounted Windows drive. Existing rv32-linux build used `vivado -mode batch` with TUL board files, so Vivado is installed somewhere (likely a Windows install or another machine). Record where. |
| Board files | Open | rv32-linux used TUL `pynq-z2/A.0/board.xml`. Reuse. |
| Board image | Open | rv32-linux README says verified on a PYNQ v2.7 image. Confirm the version and `uname -r` on the board. |
| ARM cross compiler | **Open** | `arm-linux-gnueabihf-gcc` is not installed. Install it (Arch: `arm-linux-gnueabihf-gcc`) or build natively on the board. |
| Kernel headers | Open | An out-of-tree module needs headers matching the board's kernel. |
| Board access | Open | No serial device seen on this machine. Record serial, SSH, and file-copy method. |

## Known from the sibling project

`linux_projects/rv32-linux` already built a PYNQ-Z2 design with HP0 and HP1 ports and closed
timing at 50 MHz (whole SoC 4.7k LUT, WNS +1.65 ns, critical path about 18.4 ns). Its
`fpga/pynq_z2/build.tcl` is the starting reference for Phase 3.

## To close Phase 0

Fill in the open rows. Items needed from you: where Vivado runs (machine, OS, version), PYNQ image
version and `uname -r`, and how you reach the board.
