// v4l2_test.c -- tests for the XLR8 V4L2 blur device. Build and run on the board:
//   gcc -O2 -Wall -I../../sw/lib -I.. -o v4l2_test v4l2_test.c ../../sw/lib/xlr8.c
//   sudo ./v4l2_test [frames] [ball.hex]
// ball.hex (optional) enables the "streams alongside a /dev/xlr8 client" test.
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "xlr8.h"

#define W 64
#define H 64
#define IMG (W * H * 4)
#define NBUF 4

static int failures;
#define CHECK(c, ...) do { if (!(c)) { failures++; printf("FAIL line %d: ", __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static void cpu_blur(uint32_t *o, const uint32_t *in)
{
	for (int y = 0; y < H; y++)
		for (int x = 0; x < W; x++) {
			unsigned sr = 0, sg = 0, sb = 0;
			for (int dy = -1; dy <= 1; dy++) {
				int sy = y + dy < 0 ? 0 : (y + dy > H - 1 ? H - 1 : y + dy);
				for (int dx = -1; dx <= 1; dx++) {
					int sx = x + dx < 0 ? 0 : (x + dx > W - 1 ? W - 1 : x + dx);
					uint32_t q = in[sy * W + sx];
					sr += (q >> 16) & 0xFF; sg += (q >> 8) & 0xFF; sb += q & 0xFF;
				}
			}
			o[y * W + x] = ((sr / 9) << 16) | ((sg / 9) << 8) | (sb / 9);
		}
}

static void make_image(uint32_t *img, uint32_t seed)
{
	uint32_t s = seed * 2654435761u + 1;
	for (int i = 0; i < W * H; i++) {
		s = s * 1664525u + 1013904223u;
		img[i] = (i % 7 == 0) ? (s >> 8) & 0xFFFFFF : (((i % W) * 4) << 16) | (((i / W) * 4) << 8) | ((s >> 24) & 0x3F);
	}
}

static int xioctl(int fd, unsigned long req, void *arg)
{
	int r;
	do { r = ioctl(fd, req, arg); } while (r < 0 && errno == EINTR);
	return r;
}

static int find_device(char *path, size_t n)
{
	DIR *d = opendir("/sys/class/video4linux");
	struct dirent *e;
	int found = 0;
	while (d && (e = readdir(d))) {
		char p[512], name[64] = "";
		FILE *f;
		if (strncmp(e->d_name, "video", 5)) continue;
		snprintf(p, sizeof(p), "/sys/class/video4linux/%s/name", e->d_name);
		f = fopen(p, "r");
		if (f) { if (fgets(name, sizeof(name), f)) name[strcspn(name, "\n")] = 0; fclose(f); }
		if (!strcmp(name, "xlr8")) { snprintf(path, n, "/dev/%s", e->d_name); found = 1; break; }
	}
	if (d) closedir(d);
	return found;
}

struct stream {
	int fd;
	void *out[NBUF], *cap[NBUF];
};

static int setup(struct stream *s, const char *dev)
{
	struct v4l2_requestbuffers rb;
	struct v4l2_buffer b;
	struct v4l2_plane pl;
	(void)pl;
	s->fd = open(dev, O_RDWR);
	if (s->fd < 0) return -1;
	for (int t = 0; t < 2; t++) {
		unsigned type = t ? V4L2_BUF_TYPE_VIDEO_CAPTURE : V4L2_BUF_TYPE_VIDEO_OUTPUT;
		void **maps = t ? s->cap : s->out;
		memset(&rb, 0, sizeof(rb));
		rb.count = NBUF; rb.type = type; rb.memory = V4L2_MEMORY_MMAP;
		if (xioctl(s->fd, VIDIOC_REQBUFS, &rb) || rb.count < NBUF) return -2;
		for (int i = 0; i < NBUF; i++) {
			memset(&b, 0, sizeof(b));
			b.type = type; b.memory = V4L2_MEMORY_MMAP; b.index = i;
			if (xioctl(s->fd, VIDIOC_QUERYBUF, &b) || b.length < IMG) return -3;
			maps[i] = mmap(NULL, b.length, PROT_READ | PROT_WRITE, MAP_SHARED, s->fd, b.m.offset);
			if (maps[i] == MAP_FAILED) return -4;
		}
	}
	return 0;
}

static void teardown(struct stream *s)
{
	for (int i = 0; i < NBUF; i++) {
		if (s->out[i] && s->out[i] != MAP_FAILED) munmap(s->out[i], IMG);
		if (s->cap[i] && s->cap[i] != MAP_FAILED) munmap(s->cap[i], IMG);
	}
	close(s->fd);
}

static int qbuf(int fd, unsigned type, int i)
{
	struct v4l2_buffer b;
	memset(&b, 0, sizeof(b));
	b.type = type; b.memory = V4L2_MEMORY_MMAP; b.index = i;
	if (type == V4L2_BUF_TYPE_VIDEO_OUTPUT) { b.bytesused = IMG; }
	return xioctl(fd, VIDIOC_QBUF, &b);
}

static int dqbuf(int fd, unsigned type, struct v4l2_buffer *b, int timeout_ms)
{
	struct pollfd p = { .fd = fd, .events = type == V4L2_BUF_TYPE_VIDEO_CAPTURE ? POLLIN : POLLOUT };
	int r = poll(&p, 1, timeout_ms);
	if (r <= 0) return -1;
	memset(b, 0, sizeof(*b));
	b->type = type; b->memory = V4L2_MEMORY_MMAP;
	return xioctl(fd, VIDIOC_DQBUF, b);
}

static int streamon(int fd)
{
	int t = V4L2_BUF_TYPE_VIDEO_OUTPUT, c = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	return xioctl(fd, VIDIOC_STREAMON, &t) || xioctl(fd, VIDIOC_STREAMON, &c);
}
static int streamoff(int fd)
{
	int t = V4L2_BUF_TYPE_VIDEO_OUTPUT, c = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	return xioctl(fd, VIDIOC_STREAMOFF, &t) || xioctl(fd, VIDIOC_STREAMOFF, &c);
}

/* stream `frames` frames through an open, set-up device; returns number of wrong frames, or -1 */
static int run_frames(struct stream *s, int frames, uint32_t seed, double *fps)
{
	uint32_t ref[W * H];
	struct v4l2_buffer b;
	int sent = 0, got = 0, bad = 0;
	struct timespec t0, t1;
	uint32_t imgs[NBUF][W * H];
	int seq_expect = 0;

	for (int i = 0; i < NBUF; i++) {
		make_image(imgs[i], seed + sent);
		memcpy(s->out[i], imgs[i], IMG);
		if (qbuf(s->fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, i) || qbuf(s->fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, i)) return -1;
		sent++;
	}
	if (streamon(s->fd)) return -1;
	clock_gettime(CLOCK_MONOTONIC, &t0);
	while (got < frames) {
		int i;
		if (dqbuf(s->fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, &b, 5000)) return -1;
		i = b.index;
		if (b.flags & V4L2_BUF_FLAG_ERROR) { bad++; }
		else {
			if (b.bytesused != IMG || (int)b.sequence != seq_expect) bad++;
			cpu_blur(ref, imgs[i]);
			if (memcmp(ref, s->cap[i], IMG)) bad++;
		}
		seq_expect++;
		got++;
		if (dqbuf(s->fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, &b, 5000)) return -1;
		if (sent < frames) {
			make_image(imgs[i], seed + sent);
			memcpy(s->out[i], imgs[i], IMG);
			if (qbuf(s->fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, i) || qbuf(s->fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, i)) return -1;
			sent++;
		}
	}
	clock_gettime(CLOCK_MONOTONIC, &t1);
	if (fps) *fps = frames / ((t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) * 1e-9);
	if (streamoff(s->fd)) return -1;
	return bad;
}

static long cma_free_kb(void)
{
	FILE *f = fopen("/proc/meminfo", "r");
	char line[256]; long v = -1;
	while (f && fgets(line, sizeof(line), f)) if (sscanf(line, "CmaFree: %ld kB", &v) == 1) break;
	if (f) fclose(f);
	return v;
}

/* ---------------------------------------------------------------- tests */

static void t_caps(const char *dev)
{
	struct v4l2_capability cap; struct v4l2_fmtdesc fd; struct v4l2_frmsizeenum fs; struct v4l2_format f;
	int fdv = open(dev, O_RDWR);
	CHECK(fdv >= 0, "open %s", dev);
	memset(&cap, 0, sizeof(cap));
	CHECK(xioctl(fdv, VIDIOC_QUERYCAP, &cap) == 0, "QUERYCAP");
	CHECK(!strcmp((char *)cap.driver, "xlr8"), "driver name %s", cap.driver);
	CHECK((cap.device_caps & V4L2_CAP_VIDEO_M2M) && (cap.device_caps & V4L2_CAP_STREAMING), "caps %08x", cap.device_caps);
	for (int t = 0; t < 2; t++) {
		unsigned type = t ? V4L2_BUF_TYPE_VIDEO_CAPTURE : V4L2_BUF_TYPE_VIDEO_OUTPUT;
		memset(&fd, 0, sizeof(fd)); fd.type = type; fd.index = 0;
		CHECK(xioctl(fdv, VIDIOC_ENUM_FMT, &fd) == 0 && fd.pixelformat == V4L2_PIX_FMT_XBGR32, "ENUM_FMT type %u", type);
		fd.index = 1;
		CHECK(xioctl(fdv, VIDIOC_ENUM_FMT, &fd) == -1 && errno == EINVAL, "ENUM_FMT index 1");
		memset(&f, 0, sizeof(f)); f.type = type;
		f.fmt.pix.width = 128; f.fmt.pix.height = 32; f.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
		CHECK(xioctl(fdv, VIDIOC_S_FMT, &f) == 0 && f.fmt.pix.width == W && f.fmt.pix.height == H &&
		      f.fmt.pix.pixelformat == V4L2_PIX_FMT_XBGR32 && f.fmt.pix.bytesperline == W * 4 && f.fmt.pix.sizeimage == IMG,
		      "S_FMT is forced to 64x64 XBGR32 (got %ux%u)", f.fmt.pix.width, f.fmt.pix.height);
		memset(&f, 0, sizeof(f)); f.type = type;
		CHECK(xioctl(fdv, VIDIOC_G_FMT, &f) == 0 && f.fmt.pix.sizeimage == IMG, "G_FMT");
	}
	memset(&fs, 0, sizeof(fs)); fs.pixel_format = V4L2_PIX_FMT_XBGR32;
	CHECK(xioctl(fdv, VIDIOC_ENUM_FRAMESIZES, &fs) == 0 && fs.type == V4L2_FRMSIZE_TYPE_DISCRETE && fs.discrete.width == W, "ENUM_FRAMESIZES");
	fs.index = 1;
	CHECK(xioctl(fdv, VIDIOC_ENUM_FRAMESIZES, &fs) == -1, "ENUM_FRAMESIZES index 1");
	close(fdv);
	printf("caps: driver xlr8, M2M|STREAMING, one format XBGR32 64x64 on both queues\n");
}

static void t_errors(const char *dev)
{
	struct v4l2_requestbuffers rb; struct v4l2_buffer b; struct stream s;
	int fd = open(dev, O_RDWR), t = V4L2_BUF_TYPE_VIDEO_OUTPUT;
	CHECK(xioctl(fd, VIDIOC_STREAMON, &t) == -1, "STREAMON with no buffers must fail");
	memset(&b, 0, sizeof(b)); b.type = V4L2_BUF_TYPE_VIDEO_OUTPUT; b.memory = V4L2_MEMORY_MMAP; b.index = 0;
	CHECK(xioctl(fd, VIDIOC_QBUF, &b) == -1 && errno == EINVAL, "QBUF before REQBUFS");
	memset(&rb, 0, sizeof(rb)); rb.count = 2; rb.type = V4L2_BUF_TYPE_VIDEO_OUTPUT; rb.memory = V4L2_MEMORY_USERPTR;
	CHECK(xioctl(fd, VIDIOC_REQBUFS, &rb) == -1, "USERPTR is not supported");
	memset(&rb, 0, sizeof(rb)); rb.count = 2; rb.type = V4L2_BUF_TYPE_VIDEO_OUTPUT; rb.memory = V4L2_MEMORY_MMAP;
	CHECK(xioctl(fd, VIDIOC_REQBUFS, &rb) == 0 && rb.count >= 2, "REQBUFS 2");
	memset(&b, 0, sizeof(b)); b.type = V4L2_BUF_TYPE_VIDEO_OUTPUT; b.memory = V4L2_MEMORY_MMAP; b.index = 99;
	CHECK(xioctl(fd, VIDIOC_QBUF, &b) == -1 && errno == EINVAL, "QBUF index out of range");
	memset(&rb, 0, sizeof(rb)); rb.count = 0; rb.type = V4L2_BUF_TYPE_VIDEO_OUTPUT; rb.memory = V4L2_MEMORY_MMAP;
	CHECK(xioctl(fd, VIDIOC_REQBUFS, &rb) == 0, "REQBUFS 0 frees the buffers");
	close(fd);
	CHECK(setup(&s, dev) == 0, "setup after the error cases");
	if (s.fd >= 0) { double fps; CHECK(run_frames(&s, 8, 50, &fps) == 0, "stream after the error cases"); teardown(&s); }
	printf("errors: bad REQBUFS/QBUF/STREAMON rejected, device still works\n");
}

static void t_stream(const char *dev, int frames)
{
	struct stream s; double fps = 0;
	CHECK(setup(&s, dev) == 0, "setup");
	int bad = run_frames(&s, frames, 1000, &fps);
	CHECK(bad == 0, "%d wrong frames (-1 = ioctl/poll failure)", bad);
	printf("stream: %d frames through V4L2, every one equal to the CPU blur, %.1f frames/s\n", frames, fps);
	/* DMABUF export of a CAPTURE buffer: the exported fd shows the same pixels */
	{
		struct v4l2_exportbuffer eb; memset(&eb, 0, sizeof(eb));
		eb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE; eb.index = 0; eb.flags = O_RDWR;
		if (xioctl(s.fd, VIDIOC_EXPBUF, &eb) == 0) {
			void *m = mmap(NULL, IMG, PROT_READ, MAP_SHARED, eb.fd, 0);
			CHECK(m != MAP_FAILED && !memcmp(m, s.cap[0], IMG), "exported dma-buf shows the buffer's pixels");
			if (m != MAP_FAILED) munmap(m, IMG);
			close(eb.fd);
			printf("expbuf: CAPTURE buffer exported as a dma-buf, same pixels\n");
		} else {
			CHECK(0, "EXPBUF failed: %s", strerror(errno));
		}
	}
	teardown(&s);
}

static void t_streamoff(const char *dev)
{
	struct stream s;
	CHECK(setup(&s, dev) == 0, "setup");
	for (int round = 0; round < 10; round++) {
		uint32_t img[W * H];
		for (int i = 0; i < NBUF; i++) {
			make_image(img, 77 + i); memcpy(s.out[i], img, IMG);
			qbuf(s.fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, i); qbuf(s.fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, i);
		}
		streamon(s.fd);
		usleep(round * 3000);                       /* turn streaming off at different points */
		CHECK(streamoff(s.fd) == 0, "STREAMOFF with queued buffers (round %d)", round);
	}
	double fps;
	CHECK(run_frames(&s, 20, 500, &fps) == 0, "stream after repeated STREAMOFF");
	teardown(&s);
	printf("streamoff: 10 STREAMOFFs with buffers queued, then 20 exact frames\n");
}

static void t_killed(const char *dev)
{
	for (int round = 0; round < 6; round++) {
		pid_t p = fork();
		if (p == 0) {
			struct stream s; uint32_t img[W * H];
			if (setup(&s, dev)) _exit(1);
			for (int i = 0; i < NBUF; i++) {
				make_image(img, i); memcpy(s.out[i], img, IMG);
				qbuf(s.fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, i); qbuf(s.fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, i);
			}
			streamon(s.fd);
			pause();
			_exit(0);
		}
		usleep(500 + round * 4000);
		kill(p, SIGKILL);
		waitpid(p, NULL, 0);
	}
	struct stream s; double fps;
	CHECK(setup(&s, dev) == 0, "setup");
	CHECK(run_frames(&s, 20, 900, &fps) == 0, "stream after streamers were killed");
	teardown(&s);
	printf("killed: 6 streamers killed mid-stream (jobs queued), the device still works\n");
}

static int ball_child(const char *ballhex, int frames)
{
	xlr8_t *x; struct xlr8_result r;
	if (xlr8_open(&x, NULL) || xlr8_load_file(x, ballhex) || xlr8_alloc(x, 0x20000)) return 1;
	uint32_t *buf = xlr8_buf(x);
	for (int n = 0; n < frames; n++) {
		long cx = 10 + n % 40, cy = 14 + (n * 3) % 36;
		memset(buf, 0, 0x20000);
		buf[0x2000] = cx; buf[0x2001] = cy; buf[0x2002] = 49; buf[0x2003] = 0xFF8000; buf[0x2004] = 0x101830;
		if (xlr8_run(x, 4096, 0x2000, 0x6000, 0, 0, &r) || (r.status & (XLR8_ST_ERROR | XLR8_ST_TIMEOUT))) return 2;
		for (int y = 0; y < H; y++) for (int xx = 0; xx < W; xx++) {
			uint32_t e = ((xx - cx) * (xx - cx) + (y - cy) * (y - cy) <= 49) ? 0xFF8000 : 0x101830;
			if (buf[0x6000 + y * W + xx] != e) return 3;
		}
	}
	xlr8_close(x);
	return 0;
}

static int stream_child(const char *dev, int frames, uint32_t seed)
{
	struct stream s; double fps;
	if (setup(&s, dev)) return 1;
	return run_frames(&s, frames, seed, &fps) == 0 ? 0 : 2;
}

static void t_concurrent(const char *dev, const char *ballhex)
{
	pid_t pid[4]; int n = 0, status;
	for (int i = 0; i < 3; i++) {
		pid[n] = fork();
		if (pid[n] == 0) _exit(stream_child(dev, 60, 3000 + i * 100));
		n++;
	}
	if (ballhex) {
		pid[n] = fork();
		if (pid[n] == 0) _exit(ball_child(ballhex, 60));
		n++;
	}
	for (int i = 0; i < n; i++) {
		waitpid(pid[i], &status, 0);
		CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0, "child %d status %x", i, status);
	}
	printf("concurrent: 3 V4L2 streamers%s at once, all exact\n", ballhex ? " plus a /dev/xlr8 ball renderer" : "");
}

static void t_leak(const char *dev, int iters)
{
	long before = cma_free_kb(), after;
	for (int i = 0; i < iters; i++) {
		struct stream s;
		if (setup(&s, dev)) { CHECK(0, "setup failed at iteration %d", i); return; }
		teardown(&s);
	}
	after = cma_free_kb();
	CHECK(after >= before - 64, "CMA leak: %ld kB lost", before - after);
	printf("leak: %d open/REQBUFS/mmap/close cycles, CmaFree %ld kB -> %ld kB\n", iters, before, after);
}

int main(int argc, char **argv)
{
	char dev[64];
	int frames = argc > 1 ? atoi(argv[1]) : 300;
	const char *ball = argc > 2 ? argv[2] : NULL;
	const char *only = argc > 3 ? argv[3] : NULL;      /* run just one test: caps errors stream streamoff killed concurrent leak */
#define RUN(name, call) do { if (!only || !strcmp(only, name)) { printf("-- %s\n", name); call; } } while (0)
	setvbuf(stdout, NULL, _IONBF, 0);
	if (!find_device(dev, sizeof(dev))) { fprintf(stderr, "no V4L2 device named xlr8 (is xlr8_v4l2 loaded?)\n"); return 2; }
	printf("device %s\n", dev);
	RUN("caps", t_caps(dev));
	RUN("errors", t_errors(dev));
	RUN("stream", t_stream(dev, frames));
	RUN("streamoff", t_streamoff(dev));
	RUN("killed", t_killed(dev));
	RUN("concurrent", t_concurrent(dev, ball));
	RUN("leak", t_leak(dev, 300));
	printf(failures ? "FAILED: %d checks\n" : "ALL PASS\n", failures);
	return failures ? 1 : 0;
}
