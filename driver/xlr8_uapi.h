/* SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note */
/*
 * XLR8 userspace ABI. Fixed-width types only. Every `reserved` field must be zero: a nonzero value
 * returns -EINVAL, so fields can be given meaning later without breaking old binaries.
 */
#ifndef XLR8_UAPI_H
#define XLR8_UAPI_H

#include <linux/ioctl.h>
#include <linux/types.h>

#define XLR8_UAPI_VERSION   2
#define XLR8_ID_VALUE       0x584C5238u     /* "XLR8" */
#define XLR8_MAX_PROG       1024            /* GPU instructions (16 bit each) */
#define XLR8_MAX_BUF        (64u << 20)     /* largest per-file buffer, bytes */
#define XLR8_NARGS          6               /* kernel arguments, preloaded into r8..r13 */

/* xlr8_wait.status bits: the hardware STATUS register plus driver flags */
#define XLR8_ST_DONE        (1u << 1)
#define XLR8_ST_ERROR       (1u << 2)       /* illegal address or AXI error response */
#define XLR8_ST_BAD_ACCESS  (1u << 3)
#define XLR8_ST_TIMEOUT     (1u << 16)      /* driver watchdog reset the GPU */
#define XLR8_ST_ABORTED     (1u << 17)      /* job cut short by a reset */

struct xlr8_info {
	__u32 uapi_version;
	__u32 id;               /* XLR8_ID_VALUE */
	__u32 hw_version;       /* 0x00MMNNPP */
	__u32 status;           /* current hardware STATUS */
	__u32 max_prog_instrs;
	__u32 buf_size;         /* this file's buffer, 0 if none */
	__u32 reserved[10];
};

struct xlr8_prog {
	__u64 instrs;           /* user pointer to __u16[count] */
	__u32 count;            /* 1..XLR8_MAX_PROG */
	__u32 reserved[3];
};

struct xlr8_buf {
	__u32 size;             /* in: bytes (rounded up to a page); out: actual size */
	__u32 reserved[3];
};

struct xlr8_submit {
	__u32 threads;
	__u32 src;              /* GPU word offset, loaded into r14 */
	__u32 dst;              /* GPU word offset, loaded into r15 */
	__u32 prog_base;        /* instruction index */
	__u32 args[XLR8_NARGS]; /* kernel arguments: arg k is in register r(8+k) at the start of each wave.
				 * Ordinary registers, so a kernel may overwrite them. Needs hardware 0.2+;
				 * nonzero args on older hardware return -EOPNOTSUPP. */
	__u32 reserved[2];
};

struct xlr8_wait {
	__u32 timeout_ms;       /* in: 0 = driver default; waiting longer than this returns -ETIMEDOUT */
	__u32 reserved_in;
	__u32 status;           /* out */
	__u32 cycles;
	__u32 xacts;
	__u32 stalls;
	__u32 err_addr;
	__u32 reserved_out[3];
};

#define XLR8_IOC_MAGIC      'X'
#define XLR8_IOC_GET_INFO   _IOR(XLR8_IOC_MAGIC, 0, struct xlr8_info)
#define XLR8_IOC_LOAD_PROG  _IOW(XLR8_IOC_MAGIC, 1, struct xlr8_prog)
#define XLR8_IOC_SET_BUF    _IOWR(XLR8_IOC_MAGIC, 2, struct xlr8_buf)
#define XLR8_IOC_SUBMIT     _IOW(XLR8_IOC_MAGIC, 3, struct xlr8_submit)
#define XLR8_IOC_WAIT       _IOWR(XLR8_IOC_MAGIC, 4, struct xlr8_wait)

/* The buffer is mapped with mmap(fd, offset 0, up to buf_size): GPU word w is at byte 4*w. */

#endif /* XLR8_UAPI_H */
