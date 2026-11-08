// imgfilter: run the 3x3 blur on the XLR8 GPU for a real 64x64 image, through /dev/xlr8.
//
//   imgfilter --prog blur64n.hex --in photo.raw --out blurred.png [--raw-out blurred.raw] [--scale S]
//
// photo.raw is 64*64 little-endian 32-bit words, 0x00RRGGBB. The blur is two launches (interior pass
// at instruction 0, border pass at BASE2). The result is checked pixel for pixel against a CPU blur.
#define _GNU_SOURCE
#include <errno.h>
#include <getopt.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "imgout.h"
#include "xlr8.h"

#define W 64
#define H 64
#define SRC_W 0x2000u
#define DST_W 0x6000u

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

int main(int argc, char **argv)
{
	const char *prog = NULL, *in_path = NULL, *out_png = NULL, *raw_out = NULL;
	int scale = 4, base2 = 139, opt;
	static const struct option lo[] = { {"prog", 1, 0, 'p'}, {"in", 1, 0, 'i'}, {"out", 1, 0, 'o'}, {"raw-out", 1, 0, 'r'},
					    {"scale", 1, 0, 's'}, {"base2", 1, 0, 'b'}, {0} };
	uint32_t in[W * H], ref[W * H], got[W * H];
	xlr8_t *x;
	struct xlr8_result r1, r2;
	struct timespec t0, t1;
	int ret;
	FILE *f;

	while ((opt = getopt_long(argc, argv, "", lo, NULL)) != -1) {
		switch (opt) {
		case 'p': prog = optarg; break;
		case 'i': in_path = optarg; break;
		case 'o': out_png = optarg; break;
		case 'r': raw_out = optarg; break;
		case 's': scale = atoi(optarg); break;
		case 'b': base2 = atoi(optarg); break;
		default: return 2;
		}
	}
	if (!prog || !in_path || !out_png) { fprintf(stderr, "usage: %s --prog F --in raw --out png [--raw-out raw]\n", argv[0]); return 2; }
	f = fopen(in_path, "rb");
	if (!f || fread(in, 4, W * H, f) != W * H) { fprintf(stderr, "cannot read %s (need %d words)\n", in_path, W * H); return 1; }
	fclose(f);

	if ((ret = xlr8_open(&x, NULL)) || (ret = xlr8_load_file(x, prog)) || (ret = xlr8_alloc(x, 1u << 20))) {
		fprintf(stderr, "xlr8: %s\n", xlr8_strerror(ret));
		return 1;
	}
	uint32_t *buf = xlr8_buf(x);
	memcpy(buf + SRC_W, in, sizeof(in));

	clock_gettime(CLOCK_MONOTONIC, &t0);
	if ((ret = xlr8_run(x, 3844, SRC_W, DST_W, 0, 0, &r1)) || (ret = xlr8_run(x, 252, SRC_W, DST_W, base2, 0, &r2))) {
		fprintf(stderr, "run: %s\n", xlr8_strerror(ret));
		return 1;
	}
	clock_gettime(CLOCK_MONOTONIC, &t1);
	if ((r1.status | r2.status) & (XLR8_ST_ERROR | XLR8_ST_TIMEOUT | XLR8_ST_ABORTED)) { fprintf(stderr, "GPU reported an error\n"); return 1; }
	memcpy(got, buf + DST_W, sizeof(got));
	cpu_blur(ref, in);

	int bad = 0;
	for (int i = 0; i < W * H; i++) bad += got[i] != ref[i];
	printf("blur 64x64 on the GPU: %.2f ms (CYCLES %u + %u), %d of %d pixels differ from the CPU blur\n",
	       (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6, r1.cycles, r2.cycles, bad, W * H);
	if (png_write(out_png, got, W, H, scale)) { perror(out_png); return 1; }
	if (raw_out && (f = fopen(raw_out, "wb"))) { fwrite(got, 4, W * H, f); fclose(f); }
	xlr8_close(x);
	return bad ? 1 : 0;
}
