#!/bin/bash
# Copy the bitstream and bring-up files to the board and run them.
#   tools/board/run_bringup.sh [frames]
# Needs: BOARD (default xilinx@192.168.0.4), SSH_ASKPASS pointing at a script that prints the
# password (never put the password on the command line), and build/fpga/out_50mhz/xlr8.{bit,hwh}.
set -euo pipefail
cd "$(dirname "$0")/../.."
BOARD=${BOARD:-xilinx@192.168.0.4}
OUT=${OUT:-build/fpga/out_50mhz}
FRAMES=${1:-20}
EXTRA=${2:-}
export SSH_ASKPASS_REQUIRE=force DISPLAY=${DISPLAY:-:0}
SSH="ssh -o PubkeyAuthentication=no"
mkdir -p build/prog
.venv/bin/python tools/assemble.py sw/kernels/ball.asm --out build/prog/ball.hex --meta build/prog/ball.json >/dev/null
scp -o PubkeyAuthentication=no -q "$OUT/xlr8.bit" "$OUT/xlr8.hwh" build/prog/ball.hex \
    tools/board/bringup.py tools/animate_ref.py tools/ball_ref.py "$BOARD:/tmp/"
# the sudo password goes over ssh stdin, not the command line
"$SSH_ASKPASS" | $SSH "$BOARD" "cd /tmp && sudo -S -p '' env XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python bringup.py --bit xlr8.bit --prog ball.hex --frames $FRAMES $EXTRA"
