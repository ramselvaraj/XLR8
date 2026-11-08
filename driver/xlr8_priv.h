/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Interface between the XLR8 core driver (xlr8.ko) and kernel users such as the V4L2 device
 * (xlr8_v4l2.ko). A kernel job runs on the same device as /dev/xlr8 clients: it claims the GPU,
 * loads its program, runs one or more launches back to back, and releases it.
 */
#ifndef XLR8_PRIV_H
#define XLR8_PRIV_H

#include <linux/device.h>
#include <linux/types.h>

struct xlr8_dev;

#define XLR8_KJOB_MAX_PASS 2

struct xlr8_kjob_pass {
	u32 threads;
	u32 prog_base;          /* instruction index of this pass's program */
};

struct xlr8_kjob {
	const u16 *prog;        /* all passes' instructions, back to back */
	unsigned int nprog;
	struct xlr8_kjob_pass pass[XLR8_KJOB_MAX_PASS];
	unsigned int npass;
	u32 mbase;              /* physical byte address the GPU's word 0 refers to */
	u32 mlim;               /* byte size of the window the GPU may touch */
	u32 src;                /* GPU word offsets handed to the kernel in r14 / r15 */
	u32 dst;
};

/* Look up the (single) XLR8 device and pin the core module; NULL if it is not probed. */
struct xlr8_dev *xlr8_dev_get(void);
void xlr8_dev_put(struct xlr8_dev *d);
struct device *xlr8_dev_device(struct xlr8_dev *d);

/*
 * Run a job and wait for it. Process context only; sleeps. Returns 0, -ETIMEDOUT if the watchdog
 * had to reset the GPU, or -EIO if the hardware reported an error.
 */
int xlr8_kjob_run(struct xlr8_dev *d, const struct xlr8_kjob *job);

#endif
