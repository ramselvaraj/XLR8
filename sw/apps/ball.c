// ball: render an animation on the XLR8 GPU through /dev/xlr8.
//
//   ball --prog ball.hex [--kernel ball|gradient|checker] [--frames N] [--gif out.gif]
//        [--png-dir DIR] [--scale S] [--verify] [--delay-cs N]
//
// ball: a bouncing ball (physics on the ARM, pixels on the GPU). gradient and checker render one
// frame. --verify renders every frame again on the CPU and compares exactly; any difference exits 1.
#define _GNU_SOURCE
#include <errno.h>
#include <getopt.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

#include "imgout.h"
#include "xlr8.h"

#define W 64
#define H 64
#define SRC_W 0x2000u
#define DST_W 0x6000u
#define BUF_BYTES 0x20000u

#define BALL_COLOR 0x00FF8000u
#define BG_COLOR   0x00101830u
#define CHK_A      0x00FFFFFFu
#define CHK_B      0x00203060u

/* ---- integer physics, identical to tools/animate_ref.py */
struct anim { long x, y, vx, vy; };
static void anim_init(struct anim *a) { a->x = 10 * 16; a->y = 14 * 16; a->vx = 21; a->vy = 13; }
static void anim_step(struct anim *a, long radius)
{
	long lo_x = radius * 16, hi_x = (W - 1 - radius) * 16, lo_y = radius * 16, hi_y = (H - 1 - radius) * 16;

	a->x += a->vx; a->y += a->vy;
	if (a->x < lo_x)      { a->x = 2 * lo_x - a->x; a->vx = -a->vx; }
	else if (a->x > hi_x) { a->x = 2 * hi_x - a->x; a->vx = -a->vx; }
	if (a->y < lo_y)      { a->y = 2 * lo_y - a->y; a->vy = -a->vy; }
	else if (a->y > hi_y) { a->y = 2 * hi_y - a->y; a->vy = -a->vy; }
}

/* ---- CPU reference renders (the same definitions as tools/ball_ref.py) */
static void ref_ball(long cx, long cy, long r2, uint32_t *out)
{
	for (int y = 0; y < H; y++)
		for (int x = 0; x < W; x++)
			out[y * W + x] = ((x - cx) * (x - cx) + (y - cy) * (y - cy) <= r2) ? BALL_COLOR : BG_COLOR;
}
static void ref_gradient(uint32_t *out)
{
	for (int y = 0; y < H; y++)
		for (int x = 0; x < W; x++)
			out[y * W + x] = ((uint32_t)(x * 4) << 16) | ((uint32_t)(y * 4) << 8) | 0x80;
}
static void ref_checker(uint32_t *out)
{
	for (int y = 0; y < H; y++)
		for (int x = 0; x < W; x++)
			out[y * W + x] = ((((x / 8) ^ (y / 8)) & 1) == 0) ? CHK_A : CHK_B;
}

static double now(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec * 1e-9;
}

int main(int argc, char **argv)
{
	const char *prog = NULL, *gif_path = NULL, *png_dir = NULL, *kernel = "ball";
	int frames = 120, scale = 4, verify = 0, delay_cs = 4, opt;
	static const struct option lo[] = {
		{"prog", 1, 0, 'p'}, {"kernel", 1, 0, 'k'}, {"frames", 1, 0, 'n'}, {"gif", 1, 0, 'g'},
		{"png-dir", 1, 0, 'd'}, {"scale", 1, 0, 's'}, {"verify", 0, 0, 'v'}, {"delay-cs", 1, 0, 'D'}, {0}
	};
	xlr8_t *x;
	struct xlr8_result res;
	struct gif gif;
	uint32_t ref[W * H], first_cycles = 0;
	uint64_t cyc_sum = 0;
	int gif_open_done = 0, mism_frames = 0, is_ball, ret;
	double t0, t1;

	while ((opt = getopt_long(argc, argv, "", lo, NULL)) != -1) {
		switch (opt) {
		case 'p': prog = optarg; break;
		case 'k': kernel = optarg; break;
		case 'n': frames = atoi(optarg); break;
		case 'g': gif_path = optarg; break;
		case 'd': png_dir = optarg; break;
		case 's': scale = atoi(optarg); break;
		case 'v': verify = 1; break;
		case 'D': delay_cs = atoi(optarg); break;
		default: return 2;
		}
	}
	is_ball = !strcmp(kernel, "ball");
	if (!prog || frames < 1 || scale < 1 || (!is_ball && strcmp(kernel, "gradient") && strcmp(kernel, "checker"))) {
		fprintf(stderr, "usage: %s --prog FILE [--kernel ball|gradient|checker] [--frames N] [--gif F] [--png-dir D] [--scale S] [--verify]\n", argv[0]);
		return 2;
	}
	if (!is_ball)
		frames = 1;
	if (png_dir)
		mkdir(png_dir, 0755);

	if ((ret = xlr8_open(&x, NULL)) || (ret = xlr8_load_file(x, prog)) || (ret = xlr8_alloc(x, BUF_BYTES))) {
		fprintf(stderr, "xlr8: %s\n", xlr8_strerror(ret));
		return 1;
	}
	uint32_t *buf = xlr8_buf(x);

	struct anim a;
	anim_init(&a);
	t0 = now();
	for (int n = 0; n < frames; n++) {
		long cx = a.x >> 4, cy = a.y >> 4;

		memset(buf, 0, BUF_BYTES);
		if (is_ball) {
			buf[SRC_W + 0] = (uint32_t)cx; buf[SRC_W + 1] = (uint32_t)cy; buf[SRC_W + 2] = 49;
			buf[SRC_W + 3] = BALL_COLOR;   buf[SRC_W + 4] = BG_COLOR;
		} else if (!strcmp(kernel, "checker")) {
			buf[SRC_W + 0] = CHK_A; buf[SRC_W + 1] = CHK_B;
		}
		ret = xlr8_run(x, W * H, SRC_W, DST_W, 0, 0, &res);
		if (ret) { fprintf(stderr, "frame %d: %s\n", n, xlr8_strerror(ret)); xlr8_close(x); return 1; }
		if (res.status & (XLR8_ST_ERROR | XLR8_ST_TIMEOUT | XLR8_ST_ABORTED)) {
			fprintf(stderr, "frame %d: status %#x err_addr %#x\n", n, res.status, res.err_addr);
			xlr8_close(x);
			return 1;
		}
		const uint32_t *fb = buf + DST_W;
		cyc_sum += res.cycles;
		if (n == 0) first_cycles = res.cycles;

		if (verify) {
			if (is_ball)                       ref_ball(cx, cy, 49, ref);
			else if (!strcmp(kernel, "gradient")) ref_gradient(ref);
			else                                ref_checker(ref);
			if (memcmp(fb, ref, sizeof(ref))) {
				mism_frames++;
				for (int i = 0; i < W * H; i++)
					if (fb[i] != ref[i]) {
						fprintf(stderr, "frame %d pixel %d: got %08x expected %08x\n", n, i, fb[i], ref[i]);
						break;
					}
			}
		}
		if (png_dir) {
			char p[512];
			snprintf(p, sizeof(p), "%s/frame_%04d.png", png_dir, n);
			if (png_write(p, fb, W, H, scale)) { perror(p); return 1; }
		}
		if (gif_path) {
			if (!gif_open_done) {
				uint32_t pal[4]; int np = 0;
				if (is_ball) { pal[0] = BG_COLOR; pal[1] = BALL_COLOR; np = 2; }
				else if (!strcmp(kernel, "checker")) { pal[0] = CHK_A; pal[1] = CHK_B; np = 2; }
				if (np == 0 || gif_open(&gif, gif_path, W, H, scale, pal, np)) {
					fprintf(stderr, "cannot write a GIF for kernel %s (needs at most 4 colours); use --png-dir\n", kernel);
					return 1;
				}
				gif_open_done = 1;
			}
			if (gif_frame(&gif, fb, W, H, delay_cs)) { fprintf(stderr, "frame %d has a colour outside the GIF palette\n", n); return 1; }
		}
		anim_step(&a, 7);
	}
	t1 = now();
	if (gif_open_done)
		gif_close(&gif);

	printf("%s: %d frame(s) rendered in %.2f s (%.1f frames/s), GPU %.2f ms/frame (CYCLES mean %llu, first %u)\n",
	       kernel, frames, t1 - t0, frames / (t1 - t0), (double)cyc_sum / frames * 20e-6,
	       (unsigned long long)(cyc_sum / frames), first_cycles);
	if (verify)
		printf("verify: %d of %d frames match the CPU reference\n", frames - mism_frames, frames);
	xlr8_close(x);
	return mism_frames ? 1 : 0;
}
