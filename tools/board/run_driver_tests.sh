#!/bin/bash
# Host side: build the driver on the board, load everything, run the test suite, show dmesg.
#   tools/board/run_driver_tests.sh [frames] [leak_iters]
set -euo pipefail
cd "$(dirname "$0")/../.."
. tools/board/common.sh
find_board
FRAMES=${1:-100}; LEAK=${2:-2000}
OUT=${OUT:-build/fpga/out_50mhz_posted}
echo "board: $BOARD"

# bitstream -> .bit.bin (the kernel FPGA manager wants a raw bin)
if [ ! -f "$OUT/xlr8.bit.bin" ] || [ "$OUT/xlr8.bit" -nt "$OUT/xlr8.bit.bin" ]; then
  ( cd "$OUT" && printf 'all:\n{\n\txlr8.bit\n}\n' > xlr8.bif && \
    /mnt/windows/vivado_linux/2026.1/Vivado/bin/bootgen -image xlr8.bif -arch zynq -process_bitstream bin -w on >/dev/null )
fi
dtc -@ -I dts -O dtb -o build/xlr8.dtbo dts/xlr8.dtso
mkdir -p build/prog
.venv/bin/python tools/assemble.py sw/kernels/ball.asm --out build/prog/ball.hex --meta build/prog/ball.json >/dev/null
.venv/bin/python tools/assemble.py sw/kernels/ball_args.asm --out build/prog/ball_args.hex >/dev/null

bscp "$OUT/xlr8.bit.bin" build/xlr8.dtbo build/prog/ball.hex build/prog/ball_args.hex driver/tests/xlr8_test.c \
     driver/tests/v4l2_test.c sw/lib/xlr8.c sw/lib/xlr8.h tools/board/load_xlr8.sh "$BOARD:/tmp/"
bssh 'rm -rf /tmp/xdrv && mkdir -p /tmp/xdrv/third_party'
bscp driver/xlr8.c driver/xlr8_priv.h driver/xlr8_uapi.h driver/xlr8_v4l2.c driver/xlr8_blur_fw.h driver/Makefile "$BOARD:/tmp/xdrv/"
bscp driver/third_party/v4l2-mem2mem.c "$BOARD:/tmp/xdrv/third_party/"
bssh 'cd /tmp/xdrv && make -C /usr/src/kernel M=/tmp/xdrv modules 2>&1 | grep -E "warning|error|Error" ; ls /tmp/xdrv/xlr8.ko /tmp/xdrv/xlr8_v4l2.ko /tmp/xdrv/third_party/v4l2-mem2mem.ko &&
      cp /tmp/xdrv/xlr8_uapi.h /tmp/ && gcc -O2 -Wall -I/tmp -o /tmp/xlr8_test /tmp/xlr8_test.c &&
      gcc -O2 -Wall -I/tmp -o /tmp/v4l2_test /tmp/v4l2_test.c /tmp/xlr8.c'
bsudo 'bash /tmp/load_xlr8.sh'
RC=0
if [ -z "${ONLY_V4L2:-}" ]; then
  bsudo "/tmp/xlr8_test /tmp/ball.hex $FRAMES $LEAK /tmp/ball_args.hex" || RC=$?
fi
if [ "${V4L2:-1}" = 1 ]; then
  echo "---- V4L2 device"
  bsudo "/tmp/v4l2_test 300 /tmp/ball.hex ${ONLY_V4L2:-}" || RC=$?
fi
echo "---- dmesg (xlr8 / warnings)"
bsudo "dmesg | grep -iE 'xlr8|BUG|WARNING|Oops|Unable to handle' | tail -20"
exit $RC
