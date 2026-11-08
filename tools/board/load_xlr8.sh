#!/bin/bash
# Runs ON the board as root: load the XLR8 bitstream through an FPGA-region overlay, which also
# creates the platform device, then insert the driver module.
#   needs in /tmp: xlr8.bit.bin xlr8.dtbo and xdrv/ (xlr8.ko, xlr8_v4l2.ko, third_party/v4l2-mem2mem.ko)
set -e
OV=/sys/kernel/config/device-tree/overlays/xlr8
rmmod xlr8_v4l2 2>/dev/null || true
rmmod xlr8 2>/dev/null || true
[ -d "$OV" ] && rmdir "$OV"
cp /tmp/xlr8.bit.bin /lib/firmware/xlr8.bit.bin
mkdir "$OV"
cat /tmp/xlr8.dtbo > "$OV/dtbo"
echo "overlay status: $(cat $OV/status)"
sleep 1
lsmod | grep -q '^v4l2_mem2mem' || insmod /tmp/xdrv/third_party/v4l2-mem2mem.ko
insmod /tmp/xdrv/xlr8.ko
[ -f /tmp/xdrv/xlr8_v4l2.ko ] && insmod /tmp/xdrv/xlr8_v4l2.ko
ls -l /dev/xlr8
dmesg | tail -5
