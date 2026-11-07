#!/bin/bash
# Run the whole benchmark matrix on the board and fetch the CSVs into results/bench/.
#   tools/board/run_bench.sh [frames]       (the driver must be loaded: tools/board/demo.sh first)
set -euo pipefail
cd "$(dirname "$0")/../.."
. tools/board/common.sh
find_board
FRAMES=${1:-1000}
echo "board: $BOARD"
.venv/bin/python tools/board/mk_bench_progs.py
bssh 'rm -rf ~/xlr8/bench && mkdir -p ~/xlr8/bench/prog ~/xlr8/bench/src ~/xlr8/bench/out'
bscp build/bench/*.hex "$BOARD:xlr8/bench/prog/"
bscp sw/apps/bench.c sw/lib/xlr8.c sw/lib/xlr8.h driver/xlr8_uapi.h sw/apps/bench_numpy.py "$BOARD:xlr8/bench/src/"
bssh 'cd ~/xlr8/bench/src && gcc -O2 -mfpu=neon -Wall -I. -o ../bench bench.c xlr8.c 2>&1 | head -5
      echo "NEON instructions in the NEON paths: $(objdump -d ../bench | grep -cE "\<(vmla|vcle|vbsl|vorr|vshl|vadd|vsub|vst1)\.")"'

bsudo 'cd /home/xilinx/xlr8/bench; chmod 666 /dev/xlr8
{ echo "date: $(date -u +%FT%TZ)"; echo "kernel: $(uname -r)"; echo "cpu: $(grep -m1 "model name" /proc/cpuinfo) / $(grep -m1 "CPU part" /proc/cpuinfo)"
  echo "cpufreq: $(ls /sys/devices/system/cpu/cpu0/cpufreq 2>&1 | head -1)"
  mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
  grep -E "^ +(armpll|cpu_6or4x|cpu_3or2x|cpu_2x|cpu_1x|fclk0) " /sys/kernel/debug/clk/clk_summary | awk "{print \"clk \" \$1 \" \" \$5 \" Hz\"}"
  echo "load: $(cat /proc/loadavg)"; echo "gcc: $(gcc --version | head -1)"; echo "numpy: $(/usr/local/share/pynq-venv/bin/python -c "import numpy; print(numpy.__version__)")"
  echo "pl_clock: $(dmesg | grep "PL clock" | tail -1)"; } > out/system.txt; cat out/system.txt'

run() {  # impl workload frames
  bsudo "cd /home/xilinx/xlr8/bench && taskset -c 1 ./bench --impl $1 --workload $2 --frames $3 --prog prog/$2.hex > out/$1_$2.csv 2> out/$1_$2.log; tail -1 out/$1_$2.csv; cat out/$1_$2.log | tail -1"
}
for w in ball64 ball128 ball256 gradient64 blur64; do
  nf=$FRAMES; case $w in ball128|ball256) nf=$(( FRAMES < 300 ? FRAMES : 300 ));; esac
  echo "== $w"
  run scalar $w $FRAMES
  run neon   $w $FRAMES
  run xlr8   $w $nf
  bsudo "cd /home/xilinx/xlr8/bench && taskset -c 1 /usr/local/share/pynq-venv/bin/python src/bench_numpy.py $w $FRAMES 100 > out/numpy_$w.csv; tail -1 out/numpy_$w.csv"
done
mkdir -p results/bench
bscp "$BOARD:xlr8/bench/out/*" results/bench/
ls -la results/bench | head -30
