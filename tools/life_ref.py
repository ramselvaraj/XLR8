#!/usr/bin/env python3
"""Conway's Game of Life on a 64x64 torus: reference and the Gosper glider gun start pattern."""
N = 64
GUN = [(1, 5), (1, 6), (2, 5), (2, 6), (11, 5), (11, 6), (11, 7), (12, 4), (12, 8), (13, 3), (13, 9), (14, 3),
       (14, 9), (15, 6), (16, 4), (16, 8), (17, 5), (17, 6), (17, 7), (18, 6), (21, 3), (21, 4), (21, 5), (22, 3),
       (22, 4), (22, 5), (23, 2), (23, 6), (25, 1), (25, 2), (25, 6), (25, 7), (35, 3), (35, 4), (36, 3), (36, 4)]


def gun_start(ox=4, oy=4):
    g = [0] * (N * N)
    for x, y in GUN:
        g[((y + oy) % N) * N + (x + ox) % N] = 1
    return g


def step(g):
    out = [0] * (N * N)
    for y in range(N):
        for x in range(N):
            s = 0
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    if dx or dy:
                        s += g[((y + dy) % N) * N + (x + dx) % N]
            alive = g[y * N + x]
            out[y * N + x] = 1 if (s == 3 or (alive and s == 2)) else 0
    return out


def run(g, gens):
    frames = [g]
    for _ in range(gens):
        g = step(g)
        frames.append(g)
    return frames
