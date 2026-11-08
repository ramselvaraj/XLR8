#!/usr/bin/env python3
"""Fixed-point Mandelbrot reference (Q12), written as the algorithm, not through the ISA simulator.

Every operation wraps modulo 2^32 exactly like the GPU's 32-bit integer ALU. Per pixel:
    c = (x*step + x0, y*step + y0);  z = 0;  alive = 1;  count = 0
    repeat N times:
        a = (zr*zr) >> 12            b = (zi*zi) >> 12            s2 = ((zr+zi)^2) >> 12
        new_zi = s2 - a - b + ci     (= 2*zr*zi + ci)
        outside = sign bit of (4.0 - a - b);   alive *= (1 - outside);   count += alive
        new_zr = a - b + cr
        z = new * alive              (an escaped point is frozen at 0, so nothing overflows)
    colour = ((8c)<<16 | (c*c>>2)<<8 | (4c+64)) * (1 - alive)       (points that never escape are black)
"""
M = 0xFFFFFFFF
Q = 12
FOUR = 4 << Q


def pixel(x, y, x0, y0, step, iters):
    cr = (x * step + x0) & M
    ci = (y * step + y0) & M
    zr = zi = 0
    alive = 1
    count = 0
    for _ in range(iters):
        a = ((zr * zr) & M) >> Q
        b = ((zi * zi) & M) >> Q
        s = (zr + zi) & M
        s2 = ((s * s) & M) >> Q
        nzi = (s2 - a - b + ci) & M
        d = (FOUR - a - b) & M
        outside = d >> 31
        alive = (alive * (1 - outside)) & M
        count = (count + alive) & M
        nzr = (a - b + cr) & M
        zr = (nzr * alive) & M
        zi = (nzi * alive) & M
    # count above is the number of iterations the point stayed inside; colour from it
    return colour(count, alive)


def colour(count, alive):
    v = count
    packed = ((v << 3) << 16) | (((v * v) >> 2) << 8) | ((v << 2) + 64)
    return (packed * (1 - alive)) & M


def render(w, x0, y0, step, iters=31):
    return [pixel(x, y, x0, y0, step, iters) for y in range(w) for x in range(w)]


def to_u32(v):
    return v & M


def escape_counts_float(w, x0, y0, step, iters=31):
    """Plain floating-point Mandelbrot escape counts, to check the fixed-point image is the real set."""
    out = []
    for y in range(w):
        for x in range(w):
            c = complex(((x * step + x0) if (x * step + x0) < 2**31 else (x * step + x0) - 2**32) / 4096.0,
                        (y * step + y0) / 4096.0)
            z = 0j
            n = 0
            for _ in range(iters):
                if abs(z) > 2.0:
                    break
                z = z * z + c
                n += 1
            out.append(n)
    return out
