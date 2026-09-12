#!/usr/bin/env python3
from __future__ import annotations

import unittest

from capture_jpeg_chroma_ground_truth import adaptive_gradient_outlier_2x_reconstruction
from capture_jpeg_chroma_natural_image_objective import (
    adaptive_vertical_row_v3,
    block_ssim_rgb,
    rgb_error,
)


class JPEGChromaNaturalImageObjectiveTests(unittest.TestCase):
    def test_block_ssim_identity_is_exact_one(self) -> None:
        width = 16
        height = 16
        payload = bytes((index * 37 + 11) & 0xFF for index in range(width * height * 3))
        result = block_ssim_rgb(
            payload,
            payload,
            width=width,
            height=height,
            block_width=8,
            block_height=8,
            k1=0.01,
            k2=0.03,
            sample_range=255.0,
        )
        self.assertAlmostEqual(result["meanRGBChannelBlockSSIM8x8"], 1.0, places=15)
        self.assertEqual(result["blockCount"], 4)
        self.assertEqual(rgb_error(payload, payload)["meanAbsoluteRGBCodeDifference"], 0.0)

    def test_block_ssim_and_mae_move_in_expected_direction_for_perturbation(self) -> None:
        width = 16
        height = 16
        reference = bytes([128] * (width * height * 3))
        candidate = bytearray(reference)
        for offset in range(0, len(candidate), 3):
            candidate[offset] = 144
        score = block_ssim_rgb(
            reference,
            bytes(candidate),
            width=width,
            height=height,
            block_width=8,
            block_height=8,
            k1=0.01,
            k2=0.03,
            sample_range=255.0,
        )
        self.assertLess(score["meanRGBChannelBlockSSIM8x8"], 1.0)
        error = rgb_error(reference, bytes(candidate))
        self.assertGreater(error["meanAbsoluteRGBCodeDifference"], 0.0)
        self.assertEqual(error["maximumRGBCodeDifference"], 16)

    def test_adaptive_vertical_matches_retained_v3_one_column_oracle(self) -> None:
        for source in (
            [80, 80, 80, 80, 176, 176, 176, 176],
            [80, 80, 128, 128, 80, 80, 80, 80],
            [64, 66, 68, 70, 72, 90, 108, 126],
        ):
            expected = adaptive_gradient_outlier_2x_reconstruction(
                source,
                output_height=len(source) * 2,
            )
            actual = [
                adaptive_vertical_row_v3(
                    bytes(source),
                    width=1,
                    height=len(source),
                    output_y=row,
                )[0]
                for row in range(len(source) * 2)
            ]
            self.assertEqual(actual, expected)


if __name__ == "__main__":
    unittest.main()
