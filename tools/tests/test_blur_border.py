#!/usr/bin/env python3
"""Test the .gen_blur_border generator against box_blur_clamped via isa_sim.

Run:  python3 tools/tests/test_blur_border.py
"""
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.dirname(HERE)
sys.path.insert(0, TOOLS)

import assemble   # noqa: E402
import blur_ref   # noqa: E402
import isa_sim    # noqa: E402

WORDS = 32768
SRC = 8192
DST = 24576


def make_image(W, H):
    """A distinct, non-uniform value per pixel so address errors are visible."""
    return [(((x * 7 + 1) & 0xFF) << 16) | (((y * 5 + 3) & 0xFF) << 8)
            | ((x * 3 + y * 11) & 0xFF)
            for y in range(H) for x in range(W)]


def border_indices(W, H):
    idx = set(range(0, W))                                  # top
    idx |= set(range((H - 1) * W, (H - 1) * W + W))         # bottom
    for y in range(1, H - 1):
        idx.add(y * W)                                      # left
        idx.add(y * W + (W - 1))                            # right
    return idx


class TestBorderGenerator(unittest.TestCase):

    def check_size(self, W, H):
        img = make_image(W, H)
        text = f".gen_blur_border {W} {H}\n.src {SRC}\n.dst {DST}\n"
        prog, meta, _ = assemble.assemble(text)

        self.assertEqual(meta["pass"], "border")
        self.assertEqual(meta["threads"], 2 * W + 2 * (H - 2))
        self.assertLessEqual(len(prog), 1024)

        data = [0] * WORDS
        data[SRC:SRC + W * H] = img
        isa_sim.run(prog, data, meta["threads"], SRC, DST)

        expected = blur_ref.box_blur_clamped(img, W, H)
        border = border_indices(W, H)
        bad = [p for p in border if data[DST + p] != expected[p]]
        self.assertEqual(bad, [], f"{W}x{H}: {len(bad)} border mismatches, "
                                  f"first {bad[0] if bad else '-'}")

        interior = [p for p in range(W * H) if p not in border]
        touched = [p for p in interior if data[DST + p] != 0]
        self.assertEqual(touched, [], f"{W}x{H}: interior dst written")

    def test_16x16(self):
        self.check_size(16, 16)

    def test_32x32(self):
        self.check_size(32, 32)

    def test_64x64(self):
        self.check_size(64, 64)

    def test_rejects_small_dims(self):
        for W, H in ((2, 8), (8, 2), (1, 1)):
            with self.assertRaises(ValueError):
                assemble.assemble(f".gen_blur_border {W} {H}\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
