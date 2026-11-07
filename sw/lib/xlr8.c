#include "xlr8.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

struct xlr8 {
	struct xlr8_sys sys;
	int fd;
	uint32_t *buf;
	size_t size;
};

/* ---- real system calls */
static int   real_open(const char *p)            { return open(p, O_RDWR | O_CLOEXEC); }
static int   real_close(int fd)                  { return close(fd); }
static int   real_ioctl(int fd, unsigned long r, void *a) { return ioctl(fd, r, a); }
static void *real_mmap(int fd, size_t len)
{
	void *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	return p == MAP_FAILED ? NULL : p;
}
static int   real_munmap(void *p, size_t len)    { return munmap(p, len); }

static int call(xlr8_t *x, unsigned long req, void *arg)
{
	return x->sys.ioctl(x->fd, req, arg) < 0 ? -errno : 0;
}

int xlr8_open_with(xlr8_t **out, const char *path, const struct xlr8_sys *sys)
{
	xlr8_t *x;
	int fd;

	if (!out)
		return -EINVAL;
	*out = NULL;
	x = calloc(1, sizeof(*x));
	if (!x)
		return -ENOMEM;
	x->sys.open   = (sys && sys->open)   ? sys->open   : real_open;
	x->sys.close  = (sys && sys->close)  ? sys->close  : real_close;
	x->sys.ioctl  = (sys && sys->ioctl)  ? sys->ioctl  : real_ioctl;
	x->sys.mmap   = (sys && sys->mmap)   ? sys->mmap   : real_mmap;
	x->sys.munmap = (sys && sys->munmap) ? sys->munmap : real_munmap;
	fd = x->sys.open(path ? path : "/dev/xlr8");
	if (fd < 0) {
		int e = errno ? -errno : -EIO;
		free(x);
		return e;
	}
	x->fd = fd;
	*out = x;
	return 0;
}

int xlr8_open(xlr8_t **out, const char *path)
{
	return xlr8_open_with(out, path, NULL);
}

static void unmap(xlr8_t *x)
{
	if (x->buf) {
		x->sys.munmap(x->buf, x->size);
		x->buf = NULL;
		x->size = 0;
	}
}

void xlr8_close(xlr8_t *x)
{
	if (!x)
		return;
	unmap(x);
	x->sys.close(x->fd);
	free(x);
}

int xlr8_info(xlr8_t *x, struct xlr8_info *info)
{
	if (!x || !info)
		return -EINVAL;
	memset(info, 0, sizeof(*info));
	return call(x, XLR8_IOC_GET_INFO, info);
}

int xlr8_load(xlr8_t *x, const uint16_t *instrs, size_t n)
{
	struct xlr8_prog p;

	if (!x || !instrs || n == 0 || n > XLR8_MAX_PROG)
		return -EINVAL;
	memset(&p, 0, sizeof(p));
	p.instrs = (uint64_t)(uintptr_t)instrs;
	p.count = (uint32_t)n;
	return call(x, XLR8_IOC_LOAD_PROG, &p);
}

int xlr8_load_file(xlr8_t *x, const char *path)
{
	uint16_t prog[XLR8_MAX_PROG];
	size_t n = 0, len;
	FILE *f;
	int ret;

	if (!x || !path)
		return -EINVAL;
	f = fopen(path, "rb");
	if (!f)
		return -errno;
	len = strlen(path);
	if (len > 4 && !strcmp(path + len - 4, ".hex")) {
		unsigned v;
		while (n < XLR8_MAX_PROG && fscanf(f, "%x", &v) == 1)
			prog[n++] = (uint16_t)v;
	} else {
		unsigned char b[2];
		while (n < XLR8_MAX_PROG && fread(b, 1, 2, f) == 2)
			prog[n++] = (uint16_t)(b[0] | (b[1] << 8));
	}
	fclose(f);
	ret = xlr8_load(x, prog, n);
	return ret;
}

int xlr8_alloc(xlr8_t *x, size_t bytes)
{
	struct xlr8_buf b;
	void *p;
	int ret;

	if (!x || bytes == 0 || bytes > XLR8_MAX_BUF)
		return -EINVAL;
	memset(&b, 0, sizeof(b));
	b.size = (uint32_t)bytes;
	ret = call(x, XLR8_IOC_SET_BUF, &b);
	if (ret)
		return ret;
	unmap(x);                       /* the driver replaced the old buffer */
	p = x->sys.mmap(x->fd, b.size);
	if (!p)
		return errno ? -errno : -ENOMEM;
	x->buf = p;
	x->size = b.size;
	return 0;
}

uint32_t *xlr8_buf(xlr8_t *x)      { return x ? x->buf : NULL; }
size_t    xlr8_buf_size(xlr8_t *x) { return x ? x->size : 0; }

int xlr8_submit(xlr8_t *x, uint32_t threads, uint32_t src, uint32_t dst, uint32_t prog_base)
{
	struct xlr8_submit s;

	if (!x)
		return -EINVAL;
	memset(&s, 0, sizeof(s));
	s.threads = threads;
	s.src = src;
	s.dst = dst;
	s.prog_base = prog_base;
	return call(x, XLR8_IOC_SUBMIT, &s);
}

int xlr8_wait(xlr8_t *x, unsigned timeout_ms, struct xlr8_result *res)
{
	struct xlr8_wait w;
	int ret;

	if (!x)
		return -EINVAL;
	memset(&w, 0, sizeof(w));
	w.timeout_ms = timeout_ms;
	ret = call(x, XLR8_IOC_WAIT, &w);
	if (ret)
		return ret;
	if (res) {
		res->status = w.status;
		res->cycles = w.cycles;
		res->xacts = w.xacts;
		res->stalls = w.stalls;
		res->err_addr = w.err_addr;
	}
	return 0;
}

int xlr8_run(xlr8_t *x, uint32_t threads, uint32_t src, uint32_t dst, uint32_t prog_base,
	     unsigned timeout_ms, struct xlr8_result *res)
{
	int ret = xlr8_submit(x, threads, src, dst, prog_base);

	return ret ? ret : xlr8_wait(x, timeout_ms, res);
}

const char *xlr8_strerror(int err)
{
	if (err < 0)
		err = -err;
	return strerror(err);
}
