#!/bin/bash
# Mandelbrot and Game of Life on the GPU through /dev/xlr8, verified against the references and
# turned into images in results/demo/.   tools/board/run_fractal_life.sh   (driver must be loaded)
set -euo pipefail
cd "$(dirname "$0")/../.."
. tools/board/common.sh
find_board
mkdir -p build/fl results/demo
.venv/bin/python tools/assemble.py sw/kernels/mandelbrot128.asm --out build/fl/mandelbrot128.hex >/dev/null
.venv/bin/python tools/assemble.py sw/kernels/life.asm --out build/fl/life.hex >/dev/null
bscp build/fl/mandelbrot128.hex build/fl/life.hex sw/lib/xlr8.py tools/board/fractal_life_run.py "$BOARD:/tmp/"
bsudo 'chmod 666 /dev/xlr8; cd /tmp && python3 fractal_life_run.py mandelbrot128.hex life.hex fl_out'
rm -rf build/fl/out && mkdir -p build/fl/out
bscp "$BOARD:/tmp/fl_out/*" build/fl/out/
.venv/bin/python tools/board/fractal_life_images.py build/fl/out results/demo
