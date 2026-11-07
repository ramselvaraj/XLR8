#!/bin/bash
# Host side: build the driver on the board, load everything, run the test suite, show dmesg.
#   tools/board/run_driver_tests.sh [frames] [leak_iters]
set -euo pipefail
cd "$(dirname "$0")/../.."
. tools/board/common.sh
find_board
FRAMES=${1:-100}; LEAK=${2:-2000}
OUT=${OUT:-build/fpga/out_50mhz_args}
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

bscp "$OUT/xlr8.bit.bin" build/xlr8.dtbo build/prog/ball.hex build/prog/ball_args.hex driver/xlr8.c driver/xlr8_uapi.h driver/Makefile \
     driver/tests/xlr8_test.c tools/board/load_xlr8.sh "$BOARD:/tmp/"
bssh 'rm -rf /tmp/xdrv && mkdir /tmp/xdrv && cp /tmp/xlr8.c /tmp/xlr8_uapi.h /tmp/Makefile /tmp/xdrv/ &&
      make -C /usr/src/kernel M=/tmp/xdrv modules 2>&1 | grep -E "warning|error|Error" ; ls /tmp/xdrv/xlr8.ko &&
      gcc -O2 -Wall -I/tmp -o /tmp/xlr8_test /tmp/xlr8_test.c'
bsudo 'bash /tmp/load_xlr8.sh'
RC=0
bsudo "/tmp/xlr8_test /tmp/ball.hex $FRAMES $LEAK /tmp/ball_args.hex" || RC=$?
echo "---- dmesg (xlr8 / warnings)"
bsudo "dmesg | grep -iE 'xlr8|BUG|WARNING|Oops|Unable to handle' | tail -20"
exit $RC
