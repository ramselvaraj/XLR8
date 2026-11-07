#!/usr/bin/env python3
"""Focused tests for tools/blur_ref.py (Phase 3 full-frame reference).

Run:  python3 -m unittest discover -s tools/tests -t . -v
  or: cd simt_gpu && python3 tools/tests/test_blur_ref.py
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import blur_ref  # noqa: E402

W = 3


def img3():
    """A 3x3 image with a +3 ramp per pixel, distinct R/G/B channels.

    index -> packed value
      0 0x010203   1 0x040506   2 0x070809
      3 0x0A0B0C   4 0x0D0E0F   5 0x101112
      6 0x131415   7 0x161718   8 0x191A1B
    """
    return [0x010203, 0x040506, 0x070809,
            0x0A0B0C, 0x0D0E0F, 0x101112,
            0x131415, 0x161718, 0x191A1B]


def rgb(word):
    return (word >> 16) & 0xFF, (word >> 8) & 0xFF, word & 0xFF


class TestClampedBlur(unittest.TestCase):

    def test_shape_preserved(self):
        out = blur_ref.box_blur_clamped(img3(), W, W)
        self.assertEqual(len(out), 9)
        self.assertIsInstance(out, list)

    def test_uniform_image_is_identity(self):
        src = [0x123456] * 25
        out = blur_ref.box_blur_clamped(src, 5, 5)
        self.assertEqual(out, src)

    def test_all_four_corners(self):
        # Hand-computed with edge-replicated (clamped) sampling.
        out = blur_ref.box_blur_clamped(img3(), W, W)
        self.assertEqual(out[0], 0x050607, "top-left")
        self.assertEqual(out[2], 0x090A0B, "top-right")
        self.assertEqual(out[6], 0x111213, "bottom-left")
        self.assertEqual(out[8], 0x151617, "bottom-right")

    def test_edge_and_interior(self):
        out = blur_ref.box_blur_clamped(img3(), W, W)
        self.assertEqual(out[1], 0x070809, "top edge middle")
        self.assertEqual(out[4], 0x0D0E0F, "interior")

    def test_packed_channel_extraction_and_repack(self):
        # Only the centre pixel is non-zero; its channels must survive
        # extraction and repacking independently.
        src = [0] * 9
        src[4] = 0x112233  # r=0x11 g=0x22 b=0x33
        out = blur_ref.box_blur_clamped(src, W, W)
        r, g, b = rgb(out[4])
        self.assertEqual((r, g, b), (0x11 // 9, 0x22 // 9, 0x33 // 9))
        self.assertEqual((r, g, b), (1, 3, 5))

    def test_integer_division_truncates(self):
        # Interior sum of red = 1 -> 0 (truncates); green = 9 -> 1 (exact).
        src = [0] * 9
        src[4] = 0x010900
        out = blur_ref.box_blur_clamped(src, W, W)
        self.assertEqual(out[4], 0x000100)

    def test_clamp_replicates_edge(self):
        # A single hot corner: its value is sampled 4x at (0,0) with clamping.
        src = [0] * 9
        src[0] = 0x090000  # r = 9
        out = blur_ref.box_blur_clamped(src, W, W)
        # (0,0): r = 9*4 // 9 = 4
        self.assertEqual(rgb(out[0])[0], 4)

    def test_matches_interior_on_interior_pixels(self):
        src = img3()
        full = blur_ref.box_blur_clamped(src, W, W)
        interior = blur_ref.box_blur_interior(src, W, W)
        self.assertEqual(full[4], interior[4])


if __name__ == "__main__":
    unittest.main(verbosity=2)
