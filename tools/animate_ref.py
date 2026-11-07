#!/usr/bin/env python3
"""Integer bouncing-ball physics, the single source of per-frame parameters.

All arithmetic is integer so a C implementation (the userspace app) can match it exactly.
Position and velocity are in 1/16 pixel units. The center pixel is pos >> 4.
"""
SUB = 16


def frames(n, w=64, h=64, radius=7, x0=10 * SUB, y0=14 * SUB, vx=21, vy=13,
           ball=0x00FF8000, bg=0x00101830):
    """Yield (cx, cy, r2, ball, bg) for n frames."""
    x, y = x0, y0
    lo_x, hi_x = radius * SUB, (w - 1 - radius) * SUB
    lo_y, hi_y = radius * SUB, (h - 1 - radius) * SUB
    for _ in range(n):
        yield (x >> 4, y >> 4, radius * radius, ball, bg)
        x += vx
        y += vy
        if x < lo_x:
            x, vx = 2 * lo_x - x, -vx
        elif x > hi_x:
            x, vx = 2 * hi_x - x, -vx
        if y < lo_y:
            y, vy = 2 * lo_y - y, -vy
        elif y > hi_y:
            y, vy = 2 * hi_y - y, -vy
