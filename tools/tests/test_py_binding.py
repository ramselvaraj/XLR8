#!/usr/bin/env python3
"""Check the Python binding's ioctl numbers and struct sizes against the C header (no hardware)."""
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "sw", "lib"))
import xlr8  # noqa: E402

src = r'''
#include <stdio.h>
#include "xlr8_uapi.h"
int main(void) {
    printf("%lu %lu %lu %lu %lu\n", (unsigned long)XLR8_IOC_GET_INFO, (unsigned long)XLR8_IOC_LOAD_PROG,
           (unsigned long)XLR8_IOC_SET_BUF, (unsigned long)XLR8_IOC_SUBMIT, (unsigned long)XLR8_IOC_WAIT);
    printf("%zu %zu %zu %zu %zu\n", sizeof(struct xlr8_info), sizeof(struct xlr8_prog), sizeof(struct xlr8_buf),
           sizeof(struct xlr8_submit), sizeof(struct xlr8_wait));
    return 0;
}
'''
with tempfile.TemporaryDirectory() as t:
    c, exe = os.path.join(t, "a.c"), os.path.join(t, "a")
    open(c, "w").write(src)
    subprocess.check_call(["gcc", "-I", os.path.join(ROOT, "driver"), c, "-o", exe])
    lines = subprocess.check_output([exe], text=True).split("\n")
nums = list(map(int, lines[0].split()))
sizes = list(map(int, lines[1].split()))
mine = [xlr8.GET_INFO, xlr8.LOAD_PROG, xlr8.SET_BUF, xlr8.SUBMIT, xlr8.WAIT]
msize = [xlr8._INFO.size, xlr8._PROG.size, xlr8._BUF.size, xlr8._SUBMIT.size, xlr8._WAIT.size]
if nums != mine or sizes != msize:
    sys.exit(f"FAIL: C {nums} {sizes} vs Python {mine} {msize}")
print("PASS: Python ioctl numbers and struct sizes match the C header")
