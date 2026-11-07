// libxlr8 unit tests against a fake driver (no hardware). Built with ASan/UBSan: leaks, double
// frees and uninitialised reads in the library fail the run.
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "xlr8.h"

static int failures;
#define CHECK(c, ...) do { if (!(c)) { failures++; printf("FAIL line %d: ", __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

/* ---- fake driver state */
static struct {
	int open_errno, mmap_fail;
	int ioctl_errno[8];             /* per ioctl nr; nonzero: fail with that errno */
	int opens, closes, mmaps, munmaps, ioctls;
	unsigned last_cmd_nr;
	struct xlr8_prog prog; uint16_t prog_data[XLR8_MAX_PROG];
	struct xlr8_buf buf; struct xlr8_submit submit; struct xlr8_wait wait;
	int reserved_dirty;
	void *maps[8];
} fk;

static int z(const uint32_t *r, int n) { while (n--) if (*r++) return 0; return 1; }

static int f_open(const char *p) { (void)p; fk.opens++; if (fk.open_errno) { errno = fk.open_errno; return -1; } return 100 + fk.opens; }
static int f_close(int fd) { (void)fd; fk.closes++; return 0; }
static int f_ioctl(int fd, unsigned long req, void *arg)
{
	unsigned nr = _IOC_NR(req);
	(void)fd;
	fk.ioctls++; fk.last_cmd_nr = nr;
	if (_IOC_TYPE(req) != 'X') { errno = ENOTTY; return -1; }
	if (nr < 8 && fk.ioctl_errno[nr]) { errno = fk.ioctl_errno[nr]; return -1; }
	switch (nr) {
	case 0: { struct xlr8_info *i = arg; if (!z(i->reserved, 10)) fk.reserved_dirty++;
		i->uapi_version = XLR8_UAPI_VERSION; i->id = XLR8_ID_VALUE; i->hw_version = 0x100; return 0; }
	case 1: { struct xlr8_prog *p = arg; if (!z(p->reserved, 3)) fk.reserved_dirty++;
		fk.prog = *p; memcpy(fk.prog_data, (void *)(uintptr_t)p->instrs, p->count * 2); return 0; }
	case 2: { struct xlr8_buf *b = arg; if (!z(b->reserved, 3)) fk.reserved_dirty++;
		fk.buf = *b; b->size = (b->size + 4095) & ~4095u; return 0; }
	case 3: { struct xlr8_submit *s = arg; if (!z(s->reserved, 2)) fk.reserved_dirty++; fk.submit = *s; return 0; }
	case 4: { struct xlr8_wait *w = arg; if (w->reserved_in || !z(w->reserved_out, 3)) fk.reserved_dirty++;
		fk.wait = *w; w->status = XLR8_ST_DONE; w->cycles = 1234; w->xacts = 56; w->stalls = 78; w->err_addr = 9; return 0; }
	}
	errno = ENOTTY; return -1;
}
static void *f_mmap(int fd, size_t len) { (void)fd; if (fk.mmap_fail) { errno = ENOMEM; return NULL; } void *p = calloc(1, len); fk.mmaps++; return p; }
static int f_munmap(void *p, size_t len) { (void)len; free(p); fk.munmaps++; return 0; }

static const struct xlr8_sys sys_fake = { f_open, f_close, f_ioctl, f_mmap, f_munmap };

static xlr8_t *open_ok(void)
{
	xlr8_t *x = NULL;
	int r = xlr8_open_with(&x, "/dev/fake", &sys_fake);
	CHECK(r == 0 && x, "open_with: %d", r);
	return x;
}

int main(void)
{
	xlr8_t *x = NULL;
	struct xlr8_info info; struct xlr8_result res;
	int r;

	/* open failure: no leak, errno mapped, out stays NULL */
	memset(&fk, 0, sizeof(fk)); fk.open_errno = ENOENT;
	r = xlr8_open_with(&x, NULL, &sys_fake);
	CHECK(r == -ENOENT && x == NULL, "open ENOENT -> %d", r);
	CHECK(xlr8_open_with(NULL, NULL, &sys_fake) == -EINVAL, "NULL out pointer");
	xlr8_close(NULL);                                   /* must not crash */

	/* info */
	memset(&fk, 0, sizeof(fk)); x = open_ok();
	r = xlr8_info(x, &info);
	CHECK(r == 0 && info.id == XLR8_ID_VALUE && info.hw_version == 0x100, "info %d", r);
	CHECK(xlr8_info(x, NULL) == -EINVAL, "info NULL");
	fk.ioctl_errno[0] = EIO;
	CHECK(xlr8_info(x, &info) == -EIO, "info EIO");

	/* load */
	uint16_t prog[4] = { 0x1234, 0xABCD, 0x0001, 0xFFFF };
	CHECK(xlr8_load(x, prog, 0) == -EINVAL, "load 0");
	CHECK(xlr8_load(x, prog, XLR8_MAX_PROG + 1) == -EINVAL, "load too many");
	CHECK(xlr8_load(x, NULL, 4) == -EINVAL, "load NULL");
	CHECK(xlr8_load(x, prog, 4) == 0 && fk.prog.count == 4 && !memcmp(fk.prog_data, prog, 8), "load ok");
	fk.ioctl_errno[1] = EBUSY;
	CHECK(xlr8_load(x, prog, 4) == -EBUSY, "load EBUSY mapped");
	fk.ioctl_errno[1] = 0;

	/* load_file: hex and binary, missing, empty */
	char hexp[] = "/tmp/xlr8_t_XXXXXX.hex", binp[] = "/tmp/xlr8_t_XXXXXX.bin", empty[] = "/tmp/xlr8_t_XXXXXX.bin";
	int fd = mkstemps(hexp, 4); FILE *f = fdopen(fd, "w"); fprintf(f, "1234\nabcd\n0001\n"); fclose(f);
	fd = mkstemps(binp, 4); f = fdopen(fd, "wb"); fwrite("\x34\x12\xcd\xab\x01\x00", 1, 6, f); fclose(f);
	fd = mkstemps(empty, 4); close(fd);
	memset(fk.prog_data, 0, sizeof(fk.prog_data));
	CHECK(xlr8_load_file(x, hexp) == 0 && fk.prog.count == 3 && fk.prog_data[0] == 0x1234 && fk.prog_data[1] == 0xABCD && fk.prog_data[2] == 1, "hex file");
	memset(fk.prog_data, 0, sizeof(fk.prog_data));
	CHECK(xlr8_load_file(x, binp) == 0 && fk.prog.count == 3 && fk.prog_data[0] == 0x1234 && fk.prog_data[1] == 0xABCD && fk.prog_data[2] == 1, "bin file");
	CHECK(xlr8_load_file(x, "/nonexistent/prog.bin") == -ENOENT, "missing file");
	CHECK(xlr8_load_file(x, empty) == -EINVAL, "empty file");
	unlink(hexp); unlink(binp); unlink(empty);

	/* alloc: bad sizes, success, replace, ioctl failure, mmap failure */
	CHECK(xlr8_alloc(x, 0) == -EINVAL, "alloc 0");
	CHECK(xlr8_alloc(x, XLR8_MAX_BUF + 1) == -EINVAL, "alloc too big");
	CHECK(xlr8_buf(x) == NULL && xlr8_buf_size(x) == 0, "no buffer yet");
	CHECK(xlr8_alloc(x, 5000) == 0 && xlr8_buf(x) && xlr8_buf_size(x) == 8192, "alloc 5000 -> 8192");
	((uint32_t *)xlr8_buf(x))[2047] = 7;                /* the whole mapping must be usable */
	int mm = fk.mmaps, um = fk.munmaps;
	CHECK(xlr8_alloc(x, 4096) == 0 && fk.mmaps == mm + 1 && fk.munmaps == um + 1 && xlr8_buf_size(x) == 4096, "re-alloc unmaps the old buffer");
	fk.ioctl_errno[2] = ENOMEM;
	CHECK(xlr8_alloc(x, 8192) == -ENOMEM && xlr8_buf_size(x) == 4096, "SET_BUF failure keeps the old mapping");
	fk.ioctl_errno[2] = 0; fk.mmap_fail = 1;
	r = xlr8_alloc(x, 8192);
	CHECK(r == -ENOMEM && xlr8_buf(x) == NULL, "mmap failure: %d, no stale pointer", r);
	fk.mmap_fail = 0;
	CHECK(xlr8_alloc(x, 4096) == 0, "alloc works again");

	/* submit / wait / run */
	CHECK(xlr8_submit(x, 4096, 0x2000, 0x6000, 3) == 0 && fk.submit.threads == 4096 && fk.submit.src == 0x2000 &&
	      fk.submit.dst == 0x6000 && fk.submit.prog_base == 3, "submit fields");
	memset(&res, 0, sizeof(res));
	CHECK(xlr8_wait(x, 250, &res) == 0 && fk.wait.timeout_ms == 250 && res.status == XLR8_ST_DONE &&
	      res.cycles == 1234 && res.xacts == 56 && res.stalls == 78 && res.err_addr == 9, "wait result");
	CHECK(xlr8_wait(x, 0, NULL) == 0, "wait without result pointer");
	fk.ioctl_errno[4] = ETIMEDOUT;
	CHECK(xlr8_wait(x, 1, &res) == -ETIMEDOUT, "wait ETIMEDOUT");
	fk.ioctl_errno[4] = EINTR;
	CHECK(xlr8_wait(x, 1, &res) == -EINTR, "wait EINTR");
	fk.ioctl_errno[4] = 0;
	fk.ioctl_errno[3] = EBUSY; int before = fk.ioctls;
	CHECK(xlr8_run(x, 1, 0, 0, 0, 0, &res) == -EBUSY && fk.ioctls == before + 1, "run stops at a failed submit");
	fk.ioctl_errno[3] = 0;
	CHECK(xlr8_run(x, 8, 1, 2, 0, 5, &res) == 0 && res.cycles == 1234, "run ok");
	{
		uint32_t a[3] = { 11, 22, 33 }, big[XLR8_NARGS + 1] = { 0 };
		CHECK(xlr8_submit_args(x, 9, 1, 2, 3, a, 3) == 0 && fk.submit.args[0] == 11 && fk.submit.args[1] == 22 &&
		      fk.submit.args[2] == 33 && fk.submit.args[3] == 0 && fk.submit.args[XLR8_NARGS - 1] == 0, "submit_args fields");
		CHECK(xlr8_submit_args(x, 9, 1, 2, 3, big, XLR8_NARGS + 1) == -EINVAL, "too many args");
		CHECK(xlr8_submit_args(x, 9, 1, 2, 3, NULL, 2) == -EINVAL, "args NULL with nargs");
		CHECK(xlr8_submit(x, 9, 1, 2, 3) == 0 && fk.submit.args[0] == 0, "plain submit sends zero args");
		fk.ioctl_errno[3] = EOPNOTSUPP;
		CHECK(xlr8_run_args(x, 9, 1, 2, 3, a, 3, 0, &res) == -EOPNOTSUPP, "old hardware: EOPNOTSUPP");
		fk.ioctl_errno[3] = 0;
		CHECK(xlr8_run_args(x, 9, 1, 2, 3, a, 3, 0, &res) == 0 && res.cycles == 1234, "run_args");
	}
	CHECK(xlr8_submit(NULL, 1, 0, 0, 0) == -EINVAL && xlr8_wait(NULL, 0, &res) == -EINVAL, "NULL handles");
	CHECK(fk.reserved_dirty == 0, "library left reserved ioctl fields nonzero %d times", fk.reserved_dirty);

	CHECK(strlen(xlr8_strerror(-EBUSY)) > 0 && !strcmp(xlr8_strerror(-EBUSY), xlr8_strerror(EBUSY)), "strerror");

	/* close releases mapping and fd */
	int c0 = fk.closes, u0 = fk.munmaps;
	xlr8_close(x);
	CHECK(fk.closes == c0 + 1 && fk.munmaps == u0 + 1, "close unmaps and closes");

	printf(failures ? "test_lib FAILED: %d checks\n" : "test_lib PASS\n", failures);
	return failures ? 1 : 0;
}
