// bench: the same frames on the ARM cores (scalar C, NEON) and on the XLR8 GPU.
//
//   bench --impl scalar|neon|xlr8 --workload ball64|ball128|ball256|gradient64|blur64
//         [--frames N] [--warmup N] [--prog FILE]
//
// CSV on stdout, one row per frame:
//   impl,workload,frame,total_ns,prep_ns,submit_ns,wait_ns,copy_ns,gpu_cycles,xacts,stalls
// and a trailing "# cpu_user_ms=.. cpu_sys_ms=.. wall_ms=.. frames=.." line. Every implementation is
// first checked for exact output against the scalar reference (outside the timed loop).
// A "frame" is complete once it sits in ordinary (cached) application memory: for the GPU that
// includes copying the result out of the driver's non-cacheable buffer.
#define _GNU_SOURCE
#include <errno.h>
#include <getopt.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>

#ifdef __ARM_NEON
#include <arm_neon.h>
#endif

#include "xlr8.h"

#define BALL 0x00FF8000u
#define BG   0x00101830u
#define MAXPIX (256 * 256)
#define NOVEC __attribute__((optimize("no-tree-vectorize")))

struct work {
	const char *name;
	int w, h;
	int kind;                       /* 0 ball, 1 gradient, 2 blur, 3 ball with kernel arguments (GPU only) */
	uint32_t threads, src, dst;
};
static const struct work W_TABLE[] = {
	{ "ball64",     64,  64,  0, 64 * 64,     0x2000, 0x6000 },
	{ "ball128",    128, 128, 0, 128 * 128,   0x2000, 0x2010 },
	{ "ball256",    256, 256, 0, 256 * 256,   0x2000, 0x2010 },
	{ "ball64a",    64,  64,  3, 64 * 64,     0x2000, 0x6000 },
	{ "ball128a",   128, 128, 3, 128 * 128,   0x2000, 0x2010 },
	{ "ball256a",   256, 256, 3, 256 * 256,   0x2000, 0x2010 },
	{ "gradient64", 64,  64,  1, 64 * 64,     0x2000, 0x6000 },
	{ "blur64",     64,  64,  2, 0,           0x2000, 0x6000 },
};
#define BLUR_T1 3844u               /* interior pass threads, program at base 0   */
#define BLUR_T2 252u                /* border pass threads, program at base 125   */
#define BLUR_BASE2 125u

static uint32_t blur_in[64 * 64];

struct anim { long x, y, vx, vy; };
static void anim_init(struct anim *a, int w) { a->x = (w * 10 / 64) * 16; a->y = (w * 14 / 64) * 16; a->vx = 21 * w / 64; a->vy = 13 * w / 64; }
static void anim_step(struct anim *a, long r, int w, int h)
{
	long lx = r * 16, hx = (w - 1 - r) * 16, ly = r * 16, hy = (h - 1 - r) * 16;
	a->x += a->vx; a->y += a->vy;
	if (a->x < lx) { a->x = 2 * lx - a->x; a->vx = -a->vx; } else if (a->x > hx) { a->x = 2 * hx - a->x; a->vx = -a->vx; }
	if (a->y < ly) { a->y = 2 * ly - a->y; a->vy = -a->vy; } else if (a->y > hy) { a->y = 2 * hy - a->y; a->vy = -a->vy; }
}

static inline uint64_t ns(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec;
}

/* ---------------------------------------------------------------- ARM scalar */
NOVEC static void scalar_ball(uint32_t *o, int w, int h, long cx, long cy, long r2)
{
	for (int y = 0; y < h; y++)
		for (int x = 0; x < w; x++)
			o[y * w + x] = ((x - cx) * (x - cx) + (y - cy) * (y - cy) <= r2) ? BALL : BG;
}
NOVEC static void scalar_gradient(uint32_t *o, int w, int h)
{
	for (int y = 0; y < h; y++)
		for (int x = 0; x < w; x++)
			o[y * w + x] = ((uint32_t)(x * 4) << 16) | ((uint32_t)(y * 4) << 8) | 0x80;
}
NOVEC static void scalar_blur(uint32_t *o, const uint32_t *in, int w, int h)
{
	for (int y = 0; y < h; y++)
		for (int x = 0; x < w; x++) {
			unsigned sr = 0, sg = 0, sb = 0;
			for (int dy = -1; dy <= 1; dy++) {
				int sy = y + dy < 0 ? 0 : (y + dy > h - 1 ? h - 1 : y + dy);
				for (int dx = -1; dx <= 1; dx++) {
					int sx = x + dx < 0 ? 0 : (x + dx > w - 1 ? w - 1 : x + dx);
					uint32_t q = in[sy * w + sx];
					sr += (q >> 16) & 0xFF; sg += (q >> 8) & 0xFF; sb += q & 0xFF;
				}
			}
			o[y * w + x] = ((sr / 9) << 16) | ((sg / 9) << 8) | (sb / 9);
		}
}

/* ---------------------------------------------------------------- ARM NEON */
#ifdef __ARM_NEON
static void neon_ball(uint32_t *o, int w, int h, long cx, long cy, long r2)
{
	const int32x4_t cxv = vdupq_n_s32((int32_t)cx), r2v = vdupq_n_s32((int32_t)r2);
	const uint32x4_t ballv = vdupq_n_u32(BALL), bgv = vdupq_n_u32(BG);
	const int32_t lane[4] = { 0, 1, 2, 3 };
	const int32x4_t lanev = vld1q_s32(lane);

	for (int y = 0; y < h; y++) {
		int32_t dy = (int32_t)(y - cy);
		int32x4_t dy2 = vdupq_n_s32(dy * dy);
		for (int x = 0; x < w; x += 4) {
			int32x4_t dx = vsubq_s32(vaddq_s32(vdupq_n_s32(x), lanev), cxv);
			int32x4_t d2 = vmlaq_s32(dy2, dx, dx);
			uint32x4_t m = vcleq_s32(d2, r2v);
			vst1q_u32(o + y * w + x, vbslq_u32(m, ballv, bgv));
		}
	}
}
static void neon_gradient(uint32_t *o, int w, int h)
{
	const uint32_t lane[4] = { 0, 1, 2, 3 };
	const uint32x4_t lanev = vld1q_u32(lane);

	for (int y = 0; y < h; y++) {
		uint32x4_t g = vdupq_n_u32(((uint32_t)(y * 4) << 8) | 0x80);
		for (int x = 0; x < w; x += 4) {
			uint32x4_t xv = vaddq_u32(vdupq_n_u32(x), lanev);
			uint32x4_t r = vshlq_n_u32(vshlq_n_u32(xv, 2), 16);
			vst1q_u32(o + y * w + x, vorrq_u32(r, g));
		}
	}
}
#endif

/* ---------------------------------------------------------------- XLR8 */
struct gpu {
	xlr8_t *x;
	uint32_t *buf;
};

static void make_blur_input(void)
{
	for (int y = 0; y < 64; y++)
		for (int x = 0; x < 64; x++)
			blur_in[y * 64 + x] = (((x * 7 + 1) & 0xFF) << 16) | (((y * 5 + 3) & 0xFF) << 8) | ((x * 3 + y * 11) & 0xFF);
}

struct times { uint64_t prep, submit, wait, copy; uint32_t cyc, xacts, stalls; };

static int gpu_frame(struct gpu *g, const struct work *wk, long cx, long cy, long r2, uint32_t *app, struct times *t)
{
	struct xlr8_result res;
	uint64_t t0 = ns(), t1, t2, t3, t4;
	int ret;

	memset(t, 0, sizeof(*t));
	if (wk->kind == 0) {
		g->buf[wk->src + 0] = (uint32_t)cx; g->buf[wk->src + 1] = (uint32_t)cy; g->buf[wk->src + 2] = (uint32_t)r2;
		g->buf[wk->src + 3] = BALL; g->buf[wk->src + 4] = BG;
	}
	const uint32_t kargs[5] = { (uint32_t)cx, (uint32_t)cy, (uint32_t)r2, BALL, BG };
	t1 = ns(); t->prep = t1 - t0;
	if (wk->kind == 2) {
		static const uint32_t thr[2] = { BLUR_T1, BLUR_T2 }, base[2] = { 0, BLUR_BASE2 };
		for (int p = 0; p < 2; p++) {
			t1 = ns();
			if ((ret = xlr8_submit(g->x, thr[p], wk->src, wk->dst, base[p]))) return ret;
			t2 = ns();
			if ((ret = xlr8_wait(g->x, 0, &res))) return ret;
			t3 = ns();
			t->submit += t2 - t1; t->wait += t3 - t2;
			t->cyc += res.cycles; t->xacts += res.xacts; t->stalls += res.stalls;
			if (res.status & (XLR8_ST_ERROR | XLR8_ST_TIMEOUT)) return -EIO;
		}
		t1 = ns() - 0;
	} else {
		if ((ret = wk->kind == 3 ? xlr8_submit_args(g->x, wk->threads, wk->src, wk->dst, 0, kargs, 5)
					 : xlr8_submit(g->x, wk->threads, wk->src, wk->dst, 0))) return ret;
		t2 = ns(); t->submit = t2 - t1;
		if ((ret = xlr8_wait(g->x, 0, &res))) return ret;
		t3 = ns(); t->wait = t3 - t2;
		t->cyc = res.cycles; t->xacts = res.xacts; t->stalls = res.stalls;
		if (res.status & (XLR8_ST_ERROR | XLR8_ST_TIMEOUT)) return -EIO;
	}
	t3 = ns();
	memcpy(app, g->buf + wk->dst, (size_t)wk->w * wk->h * 4);
	t4 = ns(); t->copy = t4 - t3;
	return 0;
}

static int cmp_u64(const void *a, const void *b) { uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b; return x < y ? -1 : x > y; }

int main(int argc, char **argv)
{
	const char *impl = "scalar", *wname = "ball64", *prog = NULL;
	int frames = 1000, warmup = 100, opt;
	static const struct option lo[] = { {"impl", 1, 0, 'i'}, {"workload", 1, 0, 'w'}, {"frames", 1, 0, 'n'},
					    {"warmup", 1, 0, 'u'}, {"prog", 1, 0, 'p'}, {0} };
	const struct work *wk = NULL;
	static uint32_t out[MAXPIX], ref[MAXPIX];
	struct gpu g = { 0 };
	struct anim a;
	struct times t;
	struct rusage r0, r1;
	uint64_t wall0, wall1;

	while ((opt = getopt_long(argc, argv, "", lo, NULL)) != -1) {
		switch (opt) {
		case 'i': impl = optarg; break;
		case 'w': wname = optarg; break;
		case 'n': frames = atoi(optarg); break;
		case 'u': warmup = atoi(optarg); break;
		case 'p': prog = optarg; break;
		default: return 2;
		}
	}
	for (size_t i = 0; i < sizeof(W_TABLE) / sizeof(W_TABLE[0]); i++)
		if (!strcmp(W_TABLE[i].name, wname)) wk = &W_TABLE[i];
	if (!wk) { fprintf(stderr, "unknown workload %s\n", wname); return 2; }
	int is_gpu = !strcmp(impl, "xlr8"), is_neon = !strcmp(impl, "neon");
	if (wk->kind == 3 && !is_gpu) { fprintf(stderr, "%s runs on the GPU only\n", wk->name); return 2; }
	if (!is_gpu && !is_neon && strcmp(impl, "scalar")) { fprintf(stderr, "unknown impl %s\n", impl); return 2; }
#ifndef __ARM_NEON
	if (is_neon) { fprintf(stderr, "built without NEON\n"); return 2; }
#endif
	if (is_neon && wk->kind == 2) { fprintf(stderr, "# neon blur not implemented, skipped\n"); return 0; }
	if (wk->kind == 2) make_blur_input();

	long radius = wk->w / 9;
	if (is_gpu) {
		int ret;
		if (!prog || (ret = xlr8_open(&g.x, NULL)) || (ret = xlr8_load_file(g.x, prog)) || (ret = xlr8_alloc(g.x, 1u << 20))) {
			fprintf(stderr, "xlr8 setup: %s\n", prog ? xlr8_strerror(ret) : "need --prog");
			return 1;
		}
		g.buf = xlr8_buf(g.x);
		if (wk->kind == 2) memcpy(g.buf + wk->src, blur_in, sizeof(blur_in));
	}

	/* ---- correctness first: the first frames of this run must equal the scalar reference */
	anim_init(&a, wk->w);
	{
		struct anim v = a;
		for (int n = 0; n < 8; n++) {
			long cx = v.x >> 4, cy = v.y >> 4, r2 = radius * radius;
			if (wk->kind == 0 || wk->kind == 3) scalar_ball(ref, wk->w, wk->h, cx, cy, r2);
			else if (wk->kind == 1) scalar_gradient(ref, wk->w, wk->h);
			else scalar_blur(ref, blur_in, wk->w, wk->h);
			if (is_gpu) {
				if (gpu_frame(&g, wk, cx, cy, r2, out, &t)) { fprintf(stderr, "gpu frame failed\n"); return 1; }
			} else if (is_neon) {
#ifdef __ARM_NEON
				if (wk->kind == 0) neon_ball(out, wk->w, wk->h, cx, cy, r2); else neon_gradient(out, wk->w, wk->h);
#endif
			} else {
				if (wk->kind == 0) scalar_ball(out, wk->w, wk->h, cx, cy, r2);
				else if (wk->kind == 1) scalar_gradient(out, wk->w, wk->h);
				else scalar_blur(out, blur_in, wk->w, wk->h);
			}
			if (memcmp(out, ref, (size_t)wk->w * wk->h * 4)) { fprintf(stderr, "MISMATCH impl=%s workload=%s frame %d\n", impl, wname, n); return 1; }
			anim_step(&v, radius, wk->w, wk->h);
		}
		fprintf(stderr, "# verify ok: %s %s\n", impl, wname);
	}

	printf("impl,workload,frame,total_ns,prep_ns,submit_ns,wait_ns,copy_ns,gpu_cycles,xacts,stalls\n");
	getrusage(RUSAGE_SELF, &r0);
	wall0 = ns();
	for (int n = -warmup; n < frames; n++) {
		long cx = a.x >> 4, cy = a.y >> 4, r2 = radius * radius;
		uint64_t t0 = ns(), t1;

		memset(&t, 0, sizeof(t));
		if (is_gpu) {
			if (gpu_frame(&g, wk, cx, cy, r2, out, &t)) { fprintf(stderr, "gpu frame failed\n"); return 1; }
		} else if (is_neon) {
#ifdef __ARM_NEON
			if (wk->kind == 0) neon_ball(out, wk->w, wk->h, cx, cy, r2); else neon_gradient(out, wk->w, wk->h);
#endif
		} else {
			if (wk->kind == 0) scalar_ball(out, wk->w, wk->h, cx, cy, r2);
			else if (wk->kind == 1) scalar_gradient(out, wk->w, wk->h);
			else scalar_blur(out, blur_in, wk->w, wk->h);
		}
		t1 = ns();
		if (n >= 0)
			printf("%s,%s,%d,%llu,%llu,%llu,%llu,%llu,%u,%u,%u\n", impl, wname, n, (unsigned long long)(t1 - t0),
			       (unsigned long long)t.prep, (unsigned long long)t.submit, (unsigned long long)t.wait,
			       (unsigned long long)t.copy, t.cyc, t.xacts, t.stalls);
		anim_step(&a, radius, wk->w, wk->h);
	}
	wall1 = ns();
	getrusage(RUSAGE_SELF, &r1);
	printf("# cpu_user_ms=%.1f cpu_sys_ms=%.1f wall_ms=%.1f frames=%d (including %d warmup)\n",
	       (r1.ru_utime.tv_sec - r0.ru_utime.tv_sec) * 1e3 + (r1.ru_utime.tv_usec - r0.ru_utime.tv_usec) / 1e3,
	       (r1.ru_stime.tv_sec - r0.ru_stime.tv_sec) * 1e3 + (r1.ru_stime.tv_usec - r0.ru_stime.tv_usec) / 1e3,
	       (wall1 - wall0) / 1e6, frames + warmup, warmup);
	(void)cmp_u64;
	xlr8_close(g.x);
	return 0;
}
