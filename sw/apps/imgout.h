/* imgout.h: dependency-free PNG and GIF writers for 0x00RRGGBB frames. */
#ifndef IMGOUT_H
#define IMGOUT_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ PNG (stored deflate) */

static uint32_t io_crc_table[256];
static int io_crc_ready;

static uint32_t io_crc(uint32_t crc, const uint8_t *p, size_t n)
{
	if (!io_crc_ready) {
		for (uint32_t i = 0; i < 256; i++) {
			uint32_t c = i;
			for (int k = 0; k < 8; k++)
				c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
			io_crc_table[i] = c;
		}
		io_crc_ready = 1;
	}
	crc = ~crc;
	while (n--)
		crc = io_crc_table[(crc ^ *p++) & 0xFF] ^ (crc >> 8);
	return ~crc;
}

static void io_be32(uint8_t *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }

static void io_chunk(FILE *f, const char *type, const uint8_t *data, uint32_t len)
{
	uint8_t hdr[8], tail[4];
	uint32_t crc;

	io_be32(hdr, len);
	memcpy(hdr + 4, type, 4);
	fwrite(hdr, 1, 8, f);
	if (len)
		fwrite(data, 1, len, f);
	crc = io_crc(0, (const uint8_t *)type, 4);
	if (len) {
		/* continue the CRC over the data */
		crc = ~crc;
		for (uint32_t i = 0; i < len; i++)
			crc = io_crc_table[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
		crc = ~crc;
	}
	io_be32(tail, crc);
	fwrite(tail, 1, 4, f);
}

/* pixels: w*h words 0x00RRGGBB; scale: integer nearest-neighbour upscale. Returns 0 or -1. */
static int png_write(const char *path, const uint32_t *px, int w, int h, int scale)
{
	int W = w * scale, H = h * scale;
	size_t rowlen = 1 + (size_t)W * 3, raw = rowlen * H;
	uint8_t *img = malloc(raw), *z;
	size_t zlen, pos = 0, nblocks = (raw + 65534) / 65535;
	uint32_t a = 1, b = 0;
	uint8_t ihdr[13];
	FILE *f;

	if (!img)
		return -1;
	for (int y = 0; y < H; y++) {
		uint8_t *r = img + rowlen * y;
		*r++ = 0;
		for (int x = 0; x < W; x++) {
			uint32_t v = px[(y / scale) * w + (x / scale)];
			*r++ = v >> 16; *r++ = v >> 8; *r++ = v;
		}
	}
	zlen = 2 + raw + nblocks * 5 + 4;
	z = malloc(zlen);
	if (!z) { free(img); return -1; }
	z[pos++] = 0x78; z[pos++] = 0x01;
	for (size_t off = 0; off < raw; off += 65535) {
		size_t n = raw - off > 65535 ? 65535 : raw - off;
		z[pos++] = (off + n >= raw) ? 1 : 0;
		z[pos++] = n & 0xFF; z[pos++] = n >> 8;
		z[pos++] = ~n & 0xFF; z[pos++] = (~n >> 8) & 0xFF;
		memcpy(z + pos, img + off, n);
		pos += n;
	}
	for (size_t i = 0; i < raw; i++) { a = (a + img[i]) % 65521; b = (b + a) % 65521; }
	io_be32(z + pos, (b << 16) | a);
	pos += 4;

	f = fopen(path, "wb");
	if (!f) { free(img); free(z); return -1; }
	fwrite("\x89PNG\r\n\x1a\n", 1, 8, f);
	io_be32(ihdr, W); io_be32(ihdr + 4, H);
	ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
	io_chunk(f, "IHDR", ihdr, 13);
	io_chunk(f, "IDAT", z, (uint32_t)pos);
	io_chunk(f, "IEND", NULL, 0);
	fclose(f);
	free(img); free(z);
	return 0;
}

/* ------------------------------------------------------------------ GIF (up to 4 colours) */

struct gif {
	FILE *f;
	int w, h, scale;
	uint32_t pal[4];
	int npal;
	uint8_t bitbuf[260];
	int nbytes, nbits;
	uint32_t acc;
};

static void gif_flush_block(struct gif *g)
{
	if (g->nbytes) {
		fputc(g->nbytes, g->f);
		fwrite(g->bitbuf, 1, g->nbytes, g->f);
		g->nbytes = 0;
	}
}

static void gif_emit(struct gif *g, unsigned code, int width)       /* LSB first */
{
	g->acc |= (uint32_t)code << g->nbits;
	g->nbits += width;
	while (g->nbits >= 8) {
		g->bitbuf[g->nbytes++] = g->acc & 0xFF;
		g->acc >>= 8;
		g->nbits -= 8;
		if (g->nbytes == 255)
			gif_flush_block(g);
	}
}

/* palette entries are the colours that appear; at most 4 */
static int gif_open(struct gif *g, const char *path, int w, int h, int scale, const uint32_t *palette, int npal)
{
	uint8_t hdr[13];

	if (npal < 1 || npal > 4)
		return -1;
	memset(g, 0, sizeof(*g));
	g->f = fopen(path, "wb");
	if (!g->f)
		return -1;
	g->w = w * scale; g->h = h * scale; g->scale = scale; g->npal = npal;
	for (int i = 0; i < npal; i++) g->pal[i] = palette[i];
	memcpy(hdr, "GIF89a", 6);
	hdr[6] = g->w & 0xFF; hdr[7] = g->w >> 8; hdr[8] = g->h & 0xFF; hdr[9] = g->h >> 8;
	hdr[10] = 0x80 | (1 << 4) | 1;      /* global table, 2 bits (4 colours) */
	hdr[11] = 0; hdr[12] = 0;
	fwrite(hdr, 1, 13, g->f);
	for (int i = 0; i < 4; i++) {
		uint32_t c = i < npal ? palette[i] : 0;
		fputc(c >> 16, g->f); fputc(c >> 8, g->f); fputc(c, g->f);
	}
	fwrite("\x21\xFF\x0BNETSCAPE2.0\x03\x01\x00\x00\x00", 1, 19, g->f);     /* loop forever */
	return 0;
}

/* LZW with the standard variable code width (3 to 12 bits for a 4-colour palette). */
static int gif_frame(struct gif *g, const uint32_t *px, int w, int h, int delay_cs)
{
	enum { CLEAR = 4, EOI = 5, MAXC = 4096 };
	size_t n = (size_t)g->w * g->h;
	uint8_t *idx = malloc(n);
	int16_t *dict = malloc(sizeof(int16_t) * MAXC * 4);
	int width = 3, next = EOI + 1;
	long cur;

	if (!idx || !dict) { free(idx); free(dict); return -1; }
	for (int y = 0; y < g->h; y++)
		for (int x = 0; x < g->w; x++) {
			uint32_t v = px[(y / g->scale) * w + (x / g->scale)];
			int k = -1;
			for (int i = 0; i < g->npal; i++) if (g->pal[i] == v) k = i;
			if (k < 0) { free(idx); free(dict); return -1; }
			idx[(size_t)y * g->w + x] = (uint8_t)k;
		}

	fwrite("\x21\xF9\x04\x04", 1, 4, g->f);
	fputc(delay_cs & 0xFF, g->f); fputc(delay_cs >> 8, g->f);
	fputc(0, g->f); fputc(0, g->f);
	fputc(0x2C, g->f);
	fputc(0, g->f); fputc(0, g->f); fputc(0, g->f); fputc(0, g->f);
	fputc(g->w & 0xFF, g->f); fputc(g->w >> 8, g->f); fputc(g->h & 0xFF, g->f); fputc(g->h >> 8, g->f);
	fputc(0, g->f);
	fputc(2, g->f);                              /* LZW minimum code size */
	g->nbytes = 0; g->nbits = 0; g->acc = 0;

	memset(dict, 0xFF, sizeof(int16_t) * MAXC * 4);          /* -1: empty */
	gif_emit(g, CLEAR, width);
	cur = idx[0];
	for (size_t i = 1; i < n; i++) {
		int c = idx[i];
		int16_t hit = dict[cur * 4 + c];

		if (hit >= 0) {
			cur = hit;
			continue;
		}
		gif_emit(g, (unsigned)cur, width);
		if (next < MAXC) {
			int nc = next++;
			dict[cur * 4 + c] = (int16_t)nc;
			if (nc == (1 << width) && width < 12)
				width++;
		} else {                                   /* table full: restart */
			gif_emit(g, CLEAR, width);
			memset(dict, 0xFF, sizeof(int16_t) * MAXC * 4);
			width = 3; next = EOI + 1;
		}
		cur = c;
	}
	gif_emit(g, (unsigned)cur, width);
	gif_emit(g, EOI, width);
	if (g->nbits) {
		g->bitbuf[g->nbytes++] = g->acc & 0xFF;
		g->acc = 0; g->nbits = 0;
	}
	gif_flush_block(g);
	fputc(0, g->f);
	free(idx); free(dict);
	(void)h;
	return 0;
}

static void gif_close(struct gif *g)
{
	fputc(0x3B, g->f);
	fclose(g->f);
}

#endif
