#!/bin/bash
# One command from a freshly booted board to an animated GIF rendered on the GPU:
#   tools/board/demo.sh [frames]        (SSH_ASKPASS must print the board password)
# Copies the bitstream, overlay, driver and app to ~/xlr8 on the board, builds the driver and app
# there natively, loads everything if /dev/xlr8 is not already present, renders with --verify
# (every frame is also rendered on the CPU and compared exactly), and fetches the GIF and PNGs
# into results/demo/.
set -euo pipefail
cd "$(dirname "$0")/../.."
. tools/board/common.sh
find_board
FRAMES=${1:-120}
OUT=${OUT:-build/fpga/out_50mhz_posted}
echo "board: $BOARD"

if [ ! -f "$OUT/xlr8.bit.bin" ] || [ "$OUT/xlr8.bit" -nt "$OUT/xlr8.bit.bin" ]; then
  ( cd "$OUT" && printf 'all:\n{\n\txlr8.bit\n}\n' > xlr8.bif && \
    /mnt/windows/vivado_linux/2026.1/Vivado/bin/bootgen -image xlr8.bif -arch zynq -process_bitstream bin -w on >/dev/null )
fi
dtc -@ -I dts -O dtb -o build/xlr8.dtbo dts/xlr8.dtso
mkdir -p build/prog
.venv/bin/python tools/assemble.py sw/kernels/ball.asm --out build/prog/ball.hex --bin build/prog/ball.bin >/dev/null
.venv/bin/python tools/assemble.py sw/kernels/gradient.asm --out build/prog/gradient.hex >/dev/null
.venv/bin/python tools/assemble.py sw/kernels/checker.asm --out build/prog/checker.hex >/dev/null

bssh 'rm -rf ~/xlr8 && mkdir -p ~/xlr8/driver ~/xlr8/sw/lib ~/xlr8/sw/apps'
bscp "$OUT/xlr8.bit.bin" build/xlr8.dtbo build/prog/ball.hex build/prog/ball.bin build/prog/gradient.hex build/prog/checker.hex "$BOARD:xlr8/"
bscp driver/xlr8.c driver/xlr8_uapi.h driver/Makefile "$BOARD:xlr8/driver/"
bscp sw/Makefile "$BOARD:xlr8/sw/"
bscp sw/lib/xlr8.c sw/lib/xlr8.h "$BOARD:xlr8/sw/lib/"
bscp sw/apps/ball.c sw/apps/imgout.h "$BOARD:xlr8/sw/apps/"

echo "---- build on the board"
bssh 'cd ~/xlr8 && make -C /usr/src/kernel M=$HOME/xlr8/driver modules 2>&1 | grep -E "warning|error" ; ls driver/xlr8.ko && make -C sw 2>&1 | grep -E "warning|error|Error"; ls sw/build/ball'

echo "---- load (bitstream through the FPGA region, then the driver)"
bsudo 'set -e; H=/home/xilinx/xlr8
if [ ! -e /dev/xlr8 ]; then
  cp $H/xlr8.bit.bin /lib/firmware/xlr8.bit.bin
  OV=/sys/kernel/config/device-tree/overlays/xlr8
  [ -d $OV ] && rmdir $OV
  mkdir $OV; cat $H/xlr8.dtbo > $OV/dtbo; echo overlay: $(cat $OV/status); sleep 1
  insmod $H/driver/xlr8.ko
fi
ls -l /dev/xlr8; dmesg | grep xlr8 | tail -1; chmod 666 /dev/xlr8'

echo "---- render"
bssh 'cd ~/xlr8 && rm -rf frames && ./sw/build/ball --prog ball.hex --frames '"$FRAMES"' --gif ball.gif --png-dir frames --scale 4 --verify && ./sw/build/ball --prog gradient.hex --kernel gradient --png-dir frames_gradient --scale 4 --verify && ./sw/build/ball --prog checker.hex --kernel checker --gif checker.gif --scale 4 --verify'
mkdir -p results/demo
bscp "$BOARD:xlr8/ball.gif" "$BOARD:xlr8/checker.gif" results/demo/
bscp "$BOARD:xlr8/frames/frame_0000.png" results/demo/ball_frame_0000.png 2>/dev/null || true
bscp "$BOARD:xlr8/frames/frame_0040.png" results/demo/ball_frame_0040.png 2>/dev/null || true
bscp "$BOARD:xlr8/frames_gradient/frame_0000.png" results/demo/gradient.png 2>/dev/null || true
ls -la results/demo
