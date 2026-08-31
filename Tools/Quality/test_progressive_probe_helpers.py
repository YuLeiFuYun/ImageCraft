#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import tempfile
import unittest

from capture_libjpeg_progressive_suspension import CaptureError, parse_ppm_rgb


class PPMParserTests(unittest.TestCase):
    def parse(self, data: bytes) -> tuple[int, int, bytes]:
        with tempfile.TemporaryDirectory(prefix="imagecraft-ppm-parser-") as temp_raw:
            path = Path(temp_raw) / "fixture.ppm"
            path.write_bytes(data)
            return parse_ppm_rgb(path)

    def test_binary_raster_whitespace_bytes_are_not_consumed(self) -> None:
        raster = bytes([0x20, 0x09, 0x0A])
        width, height, decoded = self.parse(b"P6\n1 1\n255\n" + raster)
        self.assertEqual((width, height), (1, 1))
        self.assertEqual(decoded, raster)

    def test_crlf_header_separator_does_not_consume_raster_newline(self) -> None:
        raster = bytes([0x0A, 0x20, 0x09])
        width, height, decoded = self.parse(b"P6\r\n1 1\r\n255\r\n" + raster)
        self.assertEqual((width, height), (1, 1))
        self.assertEqual(decoded, raster)

    def test_missing_raster_separator_fails_closed(self) -> None:
        with self.assertRaises(CaptureError):
            self.parse(b"P6\n1 1\n255" + bytes([1, 2, 3]))


class QualityHarnessBinaryResolutionTests(unittest.TestCase):
    def test_quality_scripts_do_not_guess_repository_local_release_binary(self) -> None:
        quality_root = Path(__file__).resolve().parent
        stale = ".build/release/" + "ImageCraftEvidence"
        offenders = sorted(
            path.name
            for path in quality_root.glob("*.py")
            if path != Path(__file__).resolve() and stale in path.read_text()
        )
        self.assertEqual(offenders, [])


if __name__ == "__main__":
    unittest.main()
