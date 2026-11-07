#!/bin/bash
# Copy the bitstream and bring-up files to the board and run them (PYNQ userspace flow, Phase 4).
#   tools/board/run_bringup.sh [frames] [extra bringup.py flags, e.g. --errors | --coherence]
# SSH_ASKPASS must point at a script that prints the board password.
set -euo pipefail
cd "$(dirname "$0")/../.."
. tools/board/common.sh
find_board
OUT=${OUT:-build/fpga/out_50mhz_linux}
FRAMES=${1:-20}
EXTRA=${2:-}
mkdir -p build/prog
.venv/bin/python tools/assemble.py sw/kernels/ball.asm --out build/prog/ball.hex --meta build/prog/ball.json >/dev/null
bscp "$OUT/xlr8.bit" "$OUT/xlr8.hwh" build/prog/ball.hex tools/board/bringup.py tools/animate_ref.py tools/ball_ref.py "$BOARD:/tmp/"
bsudo "cd /tmp && env XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python bringup.py --bit xlr8.bit --prog ball.hex --frames $FRAMES $EXTRA"
