#!/bin/bash
# Blur a real photo on the GPU through /dev/xlr8 and compare with the CPU blur.
#   tools/board/run_image_demo.sh [image.png]    (driver must be loaded: tools/board/demo.sh)
set -euo pipefail
cd "$(dirname "$0")/../.."
. tools/board/common.sh
find_board
IMG=${1:-/mnt/windows/Users/ramse/riscv/RAPTOR-SoC/simt_gpu/input_images/processed/alonso_ferrari_64.png}
mkdir -p build/image results/demo
.venv/bin/python - "$IMG" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB").resize((64, 64))
open("build/image/photo.raw", "wb").write(b"".join(((r << 16) | (g << 8) | b).to_bytes(4, "little") for r, g, b in im.getdata()))
im.resize((256, 256), Image.NEAREST).save("build/image/photo_x4.png")
PY
.venv/bin/python tools/board/mk_bench_progs.py > /dev/null
bscp build/bench/blur64n.hex build/image/photo.raw sw/apps/imgfilter.c sw/apps/imgout.h sw/lib/xlr8.c sw/lib/xlr8.h driver/xlr8_uapi.h "$BOARD:/tmp/"
bssh 'cd /tmp && gcc -O2 -Wall -I. -o imgfilter imgfilter.c xlr8.c && ls -l imgfilter | cut -c1-40 >/dev/null'
bsudo 'chmod 666 /dev/xlr8; cd /tmp && ./imgfilter --prog blur64n.hex --in photo.raw --out blurred_x4.png --raw-out blurred.raw'
bscp "$BOARD:/tmp/blurred_x4.png" "$BOARD:/tmp/blurred.raw" build/image/
.venv/bin/python - <<'PY'
from PIL import Image
a = Image.open("build/image/photo_x4.png"); b = Image.open("build/image/blurred_x4.png")
c = Image.new("RGB", (a.width * 2 + 8, a.height), (252, 252, 251)); c.paste(a, (0, 0)); c.paste(b, (a.width + 8, 0))
c.save("results/demo/blur_before_after.png"); print("wrote results/demo/blur_before_after.png (left: input, right: blurred on the GPU)")
PY
