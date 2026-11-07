// Writes a few PNG and GIF files for tools/tests/test_img_decode.py to decode and compare.
#include <stdio.h>
#include <sys/stat.h>
#include "imgout.h"

int main(int argc, char **argv)
{
	const char *dir = argc > 1 ? argv[1] : "img_out";
	char p[512];
	uint32_t a[64 * 64], b[64 * 64], g[64 * 64];
	struct gif gf;
	uint32_t pal[2] = { 0x00101830, 0x00FF8000 };

	mkdir(dir, 0755);
	for (int y = 0; y < 64; y++)
		for (int x = 0; x < 64; x++) {
			int in = (x - 20) * (x - 20) + (y - 30) * (y - 30) <= 49;
			a[y * 64 + x] = in ? pal[1] : pal[0];
			b[y * 64 + x] = (x == y) ? pal[1] : pal[0];
			g[y * 64 + x] = ((uint32_t)(x * 4) << 16) | ((uint32_t)(y * 4) << 8) | 0x80;
		}
	snprintf(p, sizeof(p), "%s/grad_s1.png", dir);  if (png_write(p, g, 64, 64, 1)) return 1;
	snprintf(p, sizeof(p), "%s/ball_s4.png", dir);  if (png_write(p, a, 64, 64, 4)) return 1;
	snprintf(p, sizeof(p), "%s/anim.gif", dir);
	if (gif_open(&gf, p, 64, 64, 3, pal, 2)) return 1;
	if (gif_frame(&gf, a, 64, 64, 5) || gif_frame(&gf, b, 64, 64, 5) || gif_frame(&gf, a, 64, 64, 5)) return 1;
	gif_close(&gf);
	{   /* a noisy 4-colour frame: long dictionary growth, several table resets */
		uint32_t pal4[4] = { 0x000000, 0xFF0000, 0x00FF00, 0x0000FF }, n[64 * 64];
		unsigned s = 12345;
		struct gif g4;
		for (int i = 0; i < 64 * 64; i++) { s = s * 1103515245u + 12345u; n[i] = pal4[(s >> 16) & 3]; }
		snprintf(p, sizeof(p), "%s/noise.gif", dir);
		if (gif_open(&g4, p, 64, 64, 4, pal4, 4)) return 1;
		if (gif_frame(&g4, n, 64, 64, 2)) return 1;
		gif_close(&g4);
		FILE *f = fopen("/dev/null", "w"); (void)f;
		snprintf(p, sizeof(p), "%s/noise.raw", dir);
		f = fopen(p, "wb"); fwrite(n, sizeof(n[0]), 64 * 64, f); fclose(f);
	}
	puts("test_img: wrote files");
	return 0;
}
