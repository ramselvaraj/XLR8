// xlr8_test.c -- /dev/xlr8 driver tests. Build and run on the board:
//   gcc -O2 -Wall -I.. -o xlr8_test xlr8_test.c && sudo ./xlr8_test ball.hex [frames] [leak_iters]
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#include "xlr8_uapi.h"

#define SRC_W 0x2000
#define DST_W 0x6000
#define BUF_BYTES 0x20000
#define W 64
#define H 64

static int failures;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static uint16_t ball_prog[XLR8_MAX_PROG], ball_args_prog[XLR8_MAX_PROG];
static int ball_len, ball_args_len;

static int load_hex(const char *path, uint16_t *out)
{
	FILE *f = fopen(path, "r");
	unsigned v;
	int n = 0;
	if (!f) { perror(path); exit(2); }
	while (fscanf(f, "%x", &v) == 1 && n < XLR8_MAX_PROG) out[n++] = v;
	fclose(f);
	return n;
}

/* ---- the same integer physics as tools/animate_ref.py, and the reference render */
struct anim { long x, y, vx, vy; };
static void anim_init(struct anim *a) { a->x = 10 * 16; a->y = 14 * 16; a->vx = 21; a->vy = 13; }
static void anim_step(struct anim *a, long radius)
{
	long lo_x = radius * 16, hi_x = (W - 1 - radius) * 16, lo_y = radius * 16, hi_y = (H - 1 - radius) * 16;
	a->x += a->vx; a->y += a->vy;
	if (a->x < lo_x) { a->x = 2 * lo_x - a->x; a->vx = -a->vx; } else if (a->x > hi_x) { a->x = 2 * hi_x - a->x; a->vx = -a->vx; }
	if (a->y < lo_y) { a->y = 2 * lo_y - a->y; a->vy = -a->vy; } else if (a->y > hi_y) { a->y = 2 * hi_y - a->y; a->vy = -a->vy; }
}
#define BALL 0x00FF8000u
#define BG   0x00101830u
static void ref_render(long cx, long cy, long r2, uint32_t *out)
{
	for (int y = 0; y < H; y++)
		for (int x = 0; x < W; x++)
			out[y * W + x] = ((x - cx) * (x - cx) + (y - cy) * (y - cy) <= r2) ? BALL : BG;
}

struct dev { int fd; uint32_t *map; };

static int dev_open(struct dev *d, int map)
{
	struct xlr8_buf b = { .size = BUF_BYTES };
	d->fd = open("/dev/xlr8", O_RDWR);
	if (d->fd < 0) return -1;
	if (ioctl(d->fd, XLR8_IOC_SET_BUF, &b)) return -2;
	d->map = NULL;
	if (map) {
		d->map = mmap(NULL, b.size, PROT_READ | PROT_WRITE, MAP_SHARED, d->fd, 0);
		if (d->map == MAP_FAILED) return -3;
	}
	return 0;
}
static void dev_close(struct dev *d) { if (d->map) munmap(d->map, BUF_BYTES); close(d->fd); }

static int load_prog(int fd, const uint16_t *p, int n)
{
	struct xlr8_prog lp = { .instrs = (uintptr_t)p, .count = n };
	return ioctl(fd, XLR8_IOC_LOAD_PROG, &lp);
}

static int submit_frame(struct dev *d, long cx, long cy, long r2)
{
	struct xlr8_submit s = { .threads = W * H, .src = SRC_W, .dst = DST_W };
	memset(d->map, 0, BUF_BYTES);
	d->map[SRC_W + 0] = (uint32_t)cx; d->map[SRC_W + 1] = (uint32_t)cy; d->map[SRC_W + 2] = (uint32_t)r2;
	d->map[SRC_W + 3] = BALL; d->map[SRC_W + 4] = BG;
	return ioctl(d->fd, XLR8_IOC_SUBMIT, &s);
}

/* returns number of wrong pixels, or -1 on ioctl failure */
static int wait_check(struct dev *d, long cx, long cy, long r2, struct xlr8_wait *out, unsigned timeout_ms)
{
	struct xlr8_wait w = { .timeout_ms = timeout_ms };
	uint32_t ref[W * H];
	int bad = 0;
	if (ioctl(d->fd, XLR8_IOC_WAIT, &w)) return -1;
	if (out) *out = w;
	if (w.status & (XLR8_ST_ERROR | XLR8_ST_TIMEOUT | XLR8_ST_ABORTED)) return -2;
	ref_render(cx, cy, r2, ref);
	for (int i = 0; i < W * H; i++) bad += (d->map[DST_W + i] != ref[i]);
	return bad;
}

static long irq_count(void)
{
	FILE *f = fopen("/proc/interrupts", "r");
	char line[512];
	long total = -1;
	while (f && fgets(line, sizeof(line), f)) {
		if (strstr(line, "xlr8")) {
			long a = 0, b = 0;
			sscanf(line, " %*d: %ld %ld", &a, &b);
			total = a + b;
		}
	}
	if (f) fclose(f);
	return total;
}

static long cma_free_kb(void)
{
	FILE *f = fopen("/proc/meminfo", "r");
	char line[256];
	long v = -1;
	while (f && fgets(line, sizeof(line), f))
		if (sscanf(line, "CmaFree: %ld kB", &v) == 1) break;
	if (f) fclose(f);
	return v;
}

static void set_timeout(unsigned ms)
{
	FILE *f = fopen("/sys/module/xlr8/parameters/job_timeout_ms", "w");
	if (f) { fprintf(f, "%u", ms); fclose(f); }
}

/* ---------------------------------------------------------------- tests */

static void t_info(void)
{
	struct dev d; struct xlr8_info i;
	CHECK(dev_open(&d, 1) == 0, "open");
	CHECK(ioctl(d.fd, XLR8_IOC_GET_INFO, &i) == 0, "info");
	CHECK(i.id == XLR8_ID_VALUE, "id %08x", i.id);
	CHECK(i.uapi_version == XLR8_UAPI_VERSION, "uapi version");
	CHECK(i.buf_size == BUF_BYTES, "buf_size %u", i.buf_size);
	printf("info: id=%08x hw=%08x max_prog=%u\n", i.id, i.hw_version, i.max_prog_instrs);
	dev_close(&d);
}

static void t_frames(int frames)
{
	struct dev d; struct anim a; long irq0 = irq_count(), irq1;
	struct xlr8_wait w; unsigned long cyc_sum = 0;
	CHECK(dev_open(&d, 1) == 0, "open");
	CHECK(load_prog(d.fd, ball_prog, ball_len) == 0, "load_prog: %s", strerror(errno));
	anim_init(&a);
	int bad_frames = 0;
	for (int n = 0; n < frames; n++) {
		long cx = a.x >> 4, cy = a.y >> 4;
		CHECK(submit_frame(&d, cx, cy, 49) == 0, "submit %d", n);
		int bad = wait_check(&d, cx, cy, 49, &w, 0);
		if (bad != 0) { bad_frames++; if (bad_frames < 4) printf("frame %d: bad=%d status=%x\n", n, bad, w.status); }
		cyc_sum += w.cycles;
		anim_step(&a, 7);
	}
	irq1 = irq_count();
	CHECK(bad_frames == 0, "%d of %d frames wrong", bad_frames, frames);
	printf("frames: %d exact=%d, mean CYCLES=%lu, interrupts=%ld\n", frames, frames - bad_frames, cyc_sum / frames, irq1 - irq0);
	CHECK(irq1 - irq0 >= frames, "expected >= %d interrupts, saw %ld", frames, irq1 - irq0);
	dev_close(&d);
}

static void t_badargs(void)
{
	struct xlr8_prog p; struct xlr8_buf b; struct xlr8_submit s; struct xlr8_wait w;
	int fd = open("/dev/xlr8", O_RDWR);
	CHECK(fd >= 0, "open");
	CHECK(ioctl(fd, _IO('X', 99)) == -1 && errno == ENOTTY, "unknown ioctl errno %d", errno);
	/* before any buffer */
	memset(&s, 0, sizeof(s)); s.threads = 1;
	CHECK(ioctl(fd, XLR8_IOC_SUBMIT, &s) == -1 && errno == EINVAL, "submit without buffer");
	memset(&w, 0, sizeof(w));
	CHECK(ioctl(fd, XLR8_IOC_WAIT, &w) == -1 && errno == EINVAL, "wait without submit");
	CHECK(mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0) == MAP_FAILED && errno == EINVAL, "mmap without buffer");
	/* SET_BUF */
	memset(&b, 0, sizeof(b));
	CHECK(ioctl(fd, XLR8_IOC_SET_BUF, &b) == -1 && errno == EINVAL, "SET_BUF size 0");
	b.size = XLR8_MAX_BUF + 1;
	CHECK(ioctl(fd, XLR8_IOC_SET_BUF, &b) == -1 && errno == EINVAL, "SET_BUF too big");
	b.size = 4096; b.reserved[2] = 1;
	CHECK(ioctl(fd, XLR8_IOC_SET_BUF, &b) == -1 && errno == EINVAL, "SET_BUF reserved");
	b.reserved[2] = 0; b.size = 5000;
	CHECK(ioctl(fd, XLR8_IOC_SET_BUF, &b) == 0 && b.size == 8192, "SET_BUF rounds to pages: %u", b.size);
	CHECK(mmap(NULL, 3 * 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0) == MAP_FAILED && errno == EINVAL, "mmap beyond buffer");
	CHECK(mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 4096) == MAP_FAILED, "mmap with offset");
	/* LOAD_PROG */
	memset(&p, 0, sizeof(p));
	p.instrs = (uintptr_t)ball_prog; p.count = 0;
	CHECK(ioctl(fd, XLR8_IOC_LOAD_PROG, &p) == -1 && errno == EINVAL, "LOAD_PROG count 0");
	p.count = XLR8_MAX_PROG + 1;
	CHECK(ioctl(fd, XLR8_IOC_LOAD_PROG, &p) == -1 && errno == EINVAL, "LOAD_PROG oversized");
	p.count = 4; p.reserved[0] = 7;
	CHECK(ioctl(fd, XLR8_IOC_LOAD_PROG, &p) == -1 && errno == EINVAL, "LOAD_PROG reserved");
	p.reserved[0] = 0; p.instrs = 0x10;
	CHECK(ioctl(fd, XLR8_IOC_LOAD_PROG, &p) == -1 && errno == EFAULT, "LOAD_PROG bad pointer");
	/* SUBMIT / WAIT field checks */
	memset(&s, 0, sizeof(s)); s.reserved[1] = 1;
	CHECK(ioctl(fd, XLR8_IOC_SUBMIT, &s) == -1 && errno == EINVAL, "SUBMIT reserved");
	memset(&s, 0, sizeof(s)); s.prog_base = XLR8_MAX_PROG;
	CHECK(ioctl(fd, XLR8_IOC_SUBMIT, &s) == -1 && errno == EINVAL, "SUBMIT prog_base range");
	memset(&w, 0, sizeof(w)); w.reserved_in = 1;
	CHECK(ioctl(fd, XLR8_IOC_WAIT, &w) == -1 && errno == EINVAL, "WAIT reserved");
	/* the 64 MiB maximum may or may not fit CMA; it must fail cleanly or work, never hang */
	b.size = XLR8_MAX_BUF; b.reserved[0] = 0;
	int r = ioctl(fd, XLR8_IOC_SET_BUF, &b);
	CHECK(r == 0 || errno == ENOMEM, "SET_BUF max: %s", strerror(errno));
	close(fd);
	printf("badargs: done\n");
}

/* kernel arguments: the same animation with the parameters in r8..r12 instead of memory */
static void t_args(int frames)
{
	struct dev d; struct anim a; struct xlr8_wait w; unsigned long cyc = 0, xa = 0;
	int bad_frames = 0;
	struct xlr8_buf b = { .size = BUF_BYTES };
	(void)b;
	CHECK(dev_open(&d, 1) == 0, "open");
	CHECK(load_prog(d.fd, ball_args_prog, ball_args_len) == 0, "load args kernel");
	anim_init(&a);
	for (int n = 0; n < frames; n++) {
		long cx = a.x >> 4, cy = a.y >> 4;
		struct xlr8_submit s = { .threads = W * H, .src = SRC_W, .dst = DST_W,
					 .args = { (uint32_t)cx, (uint32_t)cy, 49, BALL, BG } };
		CHECK(ioctl(d.fd, XLR8_IOC_SUBMIT, &s) == 0, "submit %d: %s", n, strerror(errno));
		int bad = wait_check(&d, cx, cy, 49, &w, 0);
		if (bad != 0) { bad_frames++; if (bad_frames < 4) printf("args frame %d: bad=%d status=%x\n", n, bad, w.status); }
		cyc += w.cycles; xa += w.xacts;
		anim_step(&a, 7);
	}
	CHECK(bad_frames == 0, "%d of %d argument frames wrong", bad_frames, frames);
	printf("args: %d frames exact=%d, mean CYCLES=%lu, bus transactions per frame=%lu\n", frames, frames - bad_frames, cyc / frames, xa / frames);
	CHECK(xa / frames == W * H, "expected 1 transaction per pixel, saw %lu per frame", xa / frames);
	dev_close(&d);
}

static void t_timeout(void)
{
	/* WAIT with a short timeout returns -ETIMEDOUT while the job keeps running. Use a hung job
	 * (branch to self) so the result does not depend on timer granularity. */
	struct dev d; struct xlr8_wait w = { .timeout_ms = 50 };
	uint16_t hang[2] = { 0xD000, 0xEFFF };    /* CMP r0,r0 (sets Z) then B -1: loops on itself */
	struct xlr8_submit s = { .threads = 8, .src = SRC_W, .dst = DST_W };
	CHECK(dev_open(&d, 1) == 0, "open");
	set_timeout(400);
	CHECK(load_prog(d.fd, hang, 2) == 0, "load hang");
	CHECK(ioctl(d.fd, XLR8_IOC_SUBMIT, &s) == 0, "submit hung job");
	int r = ioctl(d.fd, XLR8_IOC_WAIT, &w);
	CHECK(r == -1 && errno == ETIMEDOUT, "50 ms wait on a hung job should time out (r=%d errno=%d)", r, errno);
	w.timeout_ms = 0;                           /* default: waits for the watchdog */
	r = ioctl(d.fd, XLR8_IOC_WAIT, &w);
	CHECK(r == 0 && (w.status & XLR8_ST_TIMEOUT), "second wait returns the watchdog result (r=%d status=%x)", r, w.status);
	set_timeout(3000);
	/* a normal 1 ms wait on a real job: either outcome is fine, the frame must still be correct */
	CHECK(load_prog(d.fd, ball_prog, ball_len) == 0, "reload ball");
	CHECK(submit_frame(&d, 30, 30, 49) == 0, "submit");
	w.timeout_ms = 1;
	r = ioctl(d.fd, XLR8_IOC_WAIT, &w);
	CHECK(r == 0 || (r == -1 && errno == ETIMEDOUT), "1 ms wait: r=%d errno=%d", r, errno);
	if (r != 0)
		CHECK(wait_check(&d, 30, 30, 49, NULL, 0) == 0, "frame correct after a timed-out wait");
	printf("timeout: WAIT(50 ms) on a hung job -> ETIMEDOUT, watchdog then reports TIMEOUT\n");
	dev_close(&d);
}

static void t_poll(void)
{
	struct dev d; struct pollfd p;
	CHECK(dev_open(&d, 1) == 0, "open");
	CHECK(load_prog(d.fd, ball_prog, ball_len) == 0, "load");
	p.fd = d.fd; p.events = POLLIN;
	CHECK(poll(&p, 1, 0) == 0, "poll before submit must not be readable");
	CHECK(submit_frame(&d, 20, 40, 49) == 0, "submit");
	CHECK(poll(&p, 1, 2000) == 1 && (p.revents & POLLIN), "poll after submit");
	CHECK(wait_check(&d, 20, 40, 49, NULL, 0) == 0, "frame after poll");
	printf("poll: readable after completion\n");
	dev_close(&d);
}

static int child_frames(int id, int n)
{
	struct dev d; struct anim a;
	if (dev_open(&d, 1)) return 1;
	anim_init(&a);
	for (int k = 0; k < id * 17; k++) anim_step(&a, 7);     /* different phase per process */
	for (int k = 0; k < n; k++) {
		long cx = a.x >> 4, cy = a.y >> 4;
		if (submit_frame(&d, cx, cy, 49)) return 2;
		if (wait_check(&d, cx, cy, 49, NULL, 0) != 0) return 3;
		anim_step(&a, 7);
	}
	dev_close(&d);
	return 0;
}

static void t_concurrent(void)
{
	pid_t pid[3]; int status;
	struct dev d;
	CHECK(dev_open(&d, 0) == 0, "open");
	CHECK(load_prog(d.fd, ball_prog, ball_len) == 0, "load");
	for (int i = 0; i < 3; i++) {
		pid[i] = fork();
		if (pid[i] == 0) _exit(child_frames(i + 1, 60));
	}
	int rc_self = child_frames(0, 60);
	CHECK(rc_self == 0, "parent frames rc=%d", rc_self);
	for (int i = 0; i < 3; i++) {
		waitpid(pid[i], &status, 0);
		CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0, "child %d status %x", i, status);
	}
	printf("concurrent: 4 processes x 60 frames, all exact\n");
	dev_close(&d);
}

static void t_kill(void)
{
	struct dev d;
	CHECK(dev_open(&d, 1) == 0, "open");
	CHECK(load_prog(d.fd, ball_prog, ball_len) == 0, "load");
	for (int round = 0; round < 8; round++) {
		pid_t p = fork();
		if (p == 0) {
			struct dev c;
			if (dev_open(&c, 1)) _exit(1);
			submit_frame(&c, 32, 32, 49);
			pause();
			_exit(0);
		}
		usleep(300 + round * 1200);                  /* kill at different points of the ~9 ms job */
		kill(p, SIGKILL);
		waitpid(p, NULL, 0);
		CHECK(submit_frame(&d, 25, 25, 49) == 0, "submit after kill (round %d)", round);
		CHECK(wait_check(&d, 25, 25, 49, NULL, 0) == 0, "clean frame after kill (round %d)", round);
	}
	printf("kill: SIGKILL during jobs at 8 offsets, device stayed usable\n");
	dev_close(&d);
}

static void t_watchdog(void)
{
	struct dev d; struct xlr8_wait w = { 0 };
	uint16_t hang[2] = { 0xD000, 0xEFFF };   /* CMP r0,r0 then B -1: the warps never finish */
	CHECK(dev_open(&d, 1) == 0, "open");
	set_timeout(300);
	CHECK(load_prog(d.fd, hang, 2) == 0, "load hang program");
	struct xlr8_submit s = { .threads = 8, .src = SRC_W, .dst = DST_W };
	CHECK(ioctl(d.fd, XLR8_IOC_SUBMIT, &s) == 0, "submit hung job");
	int r = ioctl(d.fd, XLR8_IOC_WAIT, &w);
	CHECK(r == 0 && (w.status & XLR8_ST_TIMEOUT), "watchdog result r=%d status=%x errno=%d", r, w.status, errno);
	set_timeout(3000);
	CHECK(load_prog(d.fd, ball_prog, ball_len) == 0, "reload ball");
	CHECK(submit_frame(&d, 40, 20, 49) == 0, "submit after watchdog");
	CHECK(wait_check(&d, 40, 20, 49, NULL, 0) == 0, "clean frame after watchdog reset");
	printf("watchdog: hung GPU reset after ~300 ms (STATUS flag set), next job exact\n");
	dev_close(&d);
}

static void t_leak(int iters)
{
	long before = cma_free_kb(), after;
	for (int i = 0; i < iters; i++) {
		struct dev d;
		if (dev_open(&d, i % 4 == 0)) { CHECK(0, "open/alloc failed at iteration %d: %s", i, strerror(errno)); return; }
		dev_close(&d);
	}
	after = cma_free_kb();
	printf("leak: %d open/alloc/close cycles, CmaFree %ld kB -> %ld kB\n", iters, before, after);
	CHECK(after >= before - 64, "CMA leak: lost %ld kB", before - after);
}

int main(int argc, char **argv)
{
	int frames = argc > 2 ? atoi(argv[2]) : 100;
	int leak = argc > 3 ? atoi(argv[3]) : 2000;
	if (argc < 2) { fprintf(stderr, "usage: %s ball.hex [frames] [leak_iters]\n", argv[0]); return 2; }
	ball_len = load_hex(argv[1], ball_prog);
	if (argc > 4) ball_args_len = load_hex(argv[4], ball_args_prog);
	t_info();
	t_badargs();
	t_frames(frames);
	if (ball_args_len) t_args(frames);
	t_timeout();
	t_poll();
	t_concurrent();
	t_kill();
	t_watchdog();
	t_leak(leak);
	printf(failures ? "FAILED: %d checks\n" : "ALL PASS\n", failures);
	return failures ? 1 : 0;
}
