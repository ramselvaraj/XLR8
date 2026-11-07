/* libxlr8: thin C wrapper over /dev/xlr8 (driver/xlr8_uapi.h).
 *
 * Every function returns 0 (or a non-negative value) on success and a negative errno on failure.
 * There is no global state: a handle owns the file descriptor, the buffer and its mapping. */
#ifndef XLR8_H
#define XLR8_H

#include <stddef.h>
#include <stdint.h>

#include "xlr8_uapi.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct xlr8 xlr8_t;

struct xlr8_result {
	uint32_t status;        /* XLR8_ST_* bits */
	uint32_t cycles;        /* GPU clocks, start to done */
	uint32_t xacts;         /* bus transactions */
	uint32_t stalls;        /* clocks waiting on memory */
	uint32_t err_addr;      /* first illegal GPU word address if XLR8_ST_ERROR */
};

/* System-call layer, replaceable for tests. NULL members use the real calls. */
struct xlr8_sys {
	int   (*open)(const char *path);
	int   (*close)(int fd);
	int   (*ioctl)(int fd, unsigned long req, void *arg);
	void *(*mmap)(int fd, size_t len);          /* NULL on failure */
	int   (*munmap)(void *p, size_t len);
};

int  xlr8_open(xlr8_t **out, const char *path);            /* path NULL: /dev/xlr8 */
int  xlr8_open_with(xlr8_t **out, const char *path, const struct xlr8_sys *sys);
void xlr8_close(xlr8_t *x);                                 /* NULL is allowed */

int  xlr8_info(xlr8_t *x, struct xlr8_info *info);

/* program: n 16-bit GPU instructions (1..XLR8_MAX_PROG), or a file */
int  xlr8_load(xlr8_t *x, const uint16_t *instrs, size_t n);
int  xlr8_load_file(xlr8_t *x, const char *path);          /* ".hex" text or raw little-endian words */

/* the GPU's memory window: GPU word w is buf[w]. Allocates and maps; replaces a previous buffer. */
int       xlr8_alloc(xlr8_t *x, size_t bytes);
uint32_t *xlr8_buf(xlr8_t *x);
size_t    xlr8_buf_size(xlr8_t *x);

int  xlr8_submit(xlr8_t *x, uint32_t threads, uint32_t src, uint32_t dst, uint32_t prog_base);
/* Same, with kernel arguments: arg k reaches the kernel in register r(8+k). nargs <= XLR8_NARGS, the
 * rest are zero. Needs hardware 0.2 or newer (-EOPNOTSUPP otherwise). */
int  xlr8_submit_args(xlr8_t *x, uint32_t threads, uint32_t src, uint32_t dst, uint32_t prog_base,
		      const uint32_t *args, size_t nargs);
int  xlr8_wait(xlr8_t *x, unsigned timeout_ms, struct xlr8_result *res);   /* timeout 0 = default */
int  xlr8_run(xlr8_t *x, uint32_t threads, uint32_t src, uint32_t dst, uint32_t prog_base,
	      unsigned timeout_ms, struct xlr8_result *res);                /* submit + wait */
int  xlr8_run_args(xlr8_t *x, uint32_t threads, uint32_t src, uint32_t dst, uint32_t prog_base,
		   const uint32_t *args, size_t nargs, unsigned timeout_ms, struct xlr8_result *res);

const char *xlr8_strerror(int err);

#ifdef __cplusplus
}
#endif
#endif
