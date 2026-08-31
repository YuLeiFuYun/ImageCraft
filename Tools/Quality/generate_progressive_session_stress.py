#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT = ROOT / "Tests/ImageCraftImageIOTests/Resources/Corpus/SessionStress"
EXPECTED_CJPEG_VERSION_PREFIX = "libjpeg-turbo version 3.2.0"
EXPECTED_SHA256 = {
    "canonical-zero-23x13-q75-progressive-420.jpg": "0d719304dd885f339356186593f4dc8aeae63b4e6618a2981e2437653ce0ce66",
    "noise576-q95-progressive-420.jpg": "fa8568e3f8b776f65a204a57d18959b0e2cc9e009be40f50cf48345c9230eca0",
    "restart64-q90-progressive-420-rst1b.jpg": "862c6b163071feef98a6912c455e10d59472c8c358766afddc74366955ba1ac2",
}

ALL_FIRST_ZERO_SCAN_SCRIPT = """\
0,1,2: 0-0, 0,0;
0: 1-63, 0,0;
1: 1-63, 0,0;
2: 1-63, 0,0;
"""


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_ppm(path: Path, width: int, height: int, pixels: bytes) -> None:
    if len(pixels) != width * height * 3:
        raise ValueError("RGB payload size does not match dimensions")
    path.write_bytes(f"P6\n{width} {height}\n255\n".encode() + pixels)


def noise_pixels(width: int, height: int) -> bytes:
    state = 0x9E3779B9
    output = bytearray()
    for y in range(height):
        for x in range(width):
            state ^= (state << 13) & 0xFFFFFFFF
            state ^= state >> 17
            state ^= (state << 5) & 0xFFFFFFFF
            output.extend(
                (
                    (state ^ x * 73 ^ y * 151) & 0xFF,
                    ((state >> 8) ^ x * 191 ^ y * 29) & 0xFF,
                    ((state >> 16) ^ x * 17 ^ y * 239) & 0xFF,
                )
            )
    return bytes(output)


def restart_pixels(width: int, height: int) -> bytes:
    output = bytearray()
    for y in range(height):
        for x in range(width):
            output.extend(
                (
                    (x * 37 + y * 11) & 0xFF,
                    (x * 13 + y * 53) & 0xFF,
                    (x * 97 + y * 7) & 0xFF,
                )
            )
    return bytes(output)


def inspect_jpeg(data: bytes) -> tuple[list[int], int]:
    if len(data) < 4 or data[:2] != b"\xff\xd8":
        raise ValueError("not JPEG")
    offset = 2
    scan_sizes: list[int] = []
    restart_markers = 0
    while offset < len(data):
        if data[offset] != 0xFF:
            raise ValueError(f"expected marker at {offset}")
        while offset < len(data) and data[offset] == 0xFF:
            offset += 1
        if offset >= len(data):
            raise ValueError("truncated marker")
        marker = data[offset]
        offset += 1
        if marker == 0xD9:
            if offset != len(data):
                raise ValueError("trailing JPEG bytes")
            return scan_sizes, restart_markers
        if marker == 0x01 or 0xD0 <= marker <= 0xD7:
            if 0xD0 <= marker <= 0xD7:
                restart_markers += 1
            continue
        if offset + 2 > len(data):
            raise ValueError("truncated segment length")
        length = (data[offset] << 8) | data[offset + 1]
        if length < 2 or offset + length > len(data):
            raise ValueError("invalid segment length")
        segment_end = offset + length
        if marker != 0xDA:
            offset = segment_end
            continue
        entropy_start = segment_end
        cursor = entropy_start
        while cursor < len(data):
            if data[cursor] != 0xFF:
                cursor += 1
                continue
            marker_start = cursor
            while cursor < len(data) and data[cursor] == 0xFF:
                cursor += 1
            if cursor >= len(data):
                raise ValueError("truncated entropy marker")
            code = data[cursor]
            if code == 0x00:
                cursor += 1
                continue
            if 0xD0 <= code <= 0xD7:
                restart_markers += 1
                cursor += 1
                continue
            scan_sizes.append(marker_start - entropy_start)
            offset = marker_start
            break
        else:
            raise ValueError("missing EOI")
    raise ValueError("missing EOI")


def cjpeg_version(cjpeg: str) -> str:
    completed = subprocess.run(
        [cjpeg, "-version"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    return completed.stdout.strip()


def encode(
    cjpeg: str,
    ppm: Path,
    output: Path,
    *,
    quality: int,
    restart: str | None,
    scan_script: Path | None,
) -> None:
    command = [
        cjpeg,
        "-quality",
        str(quality),
        "-sample",
        "2x2,1x1,1x1",
    ]
    if scan_script is None:
        command += ["-progressive"]
    else:
        command += ["-scans", str(scan_script)]
    if restart is not None:
        command += ["-restart", restart]
    command += ["-outfile", str(output), str(ppm)]
    subprocess.run(command, check=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--cjpeg", default=shutil.which("cjpeg"))
    parser.add_argument("--allow-unpinned-cjpeg", action="store_true")
    args = parser.parse_args()
    if not args.cjpeg:
        raise SystemExit("cjpeg is required")

    version = cjpeg_version(args.cjpeg)
    if not args.allow_unpinned_cjpeg and not version.startswith(EXPECTED_CJPEG_VERSION_PREFIX):
        raise SystemExit(
            f"expected {EXPECTED_CJPEG_VERSION_PREFIX!r}, observed {version!r}; "
            "use --allow-unpinned-cjpeg only for exploratory regeneration"
        )

    output_dir = args.output.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    cases = [
        {
            "file": "canonical-zero-23x13-q75-progressive-420.jpg",
            "width": 23,
            "height": 13,
            "quality": 75,
            "restart": None,
            "pixels": restart_pixels(23, 13),
            "scanScript": ALL_FIRST_ZERO_SCAN_SCRIPT,
            "scanScriptID": "all-first-zero-v1",
        },
        {
            "file": "noise576-q95-progressive-420.jpg",
            "width": 576,
            "height": 576,
            "quality": 95,
            "restart": None,
            "pixels": noise_pixels(576, 576),
            "scanScript": None,
            "scanScriptID": "libjpeg-simple-progression",
        },
        {
            "file": "restart64-q90-progressive-420-rst1b.jpg",
            "width": 64,
            "height": 64,
            "quality": 90,
            "restart": "1B",
            "pixels": restart_pixels(64, 64),
            "scanScript": None,
            "scanScriptID": "libjpeg-simple-progression",
        },
    ]

    manifest_cases = []
    with tempfile.TemporaryDirectory(prefix="imagecraft-progressive-session-") as temporary:
        temporary_dir = Path(temporary)
        for index, case in enumerate(cases):
            ppm = temporary_dir / f"source-{index}.ppm"
            write_ppm(ppm, case["width"], case["height"], case["pixels"])
            scan_script: Path | None = None
            if case["scanScript"] is not None:
                scan_script = temporary_dir / f"scans-{index}.txt"
                scan_script.write_text(case["scanScript"], encoding="utf-8")
            destination = output_dir / case["file"]
            encode(
                args.cjpeg,
                ppm,
                destination,
                quality=case["quality"],
                restart=case["restart"],
                scan_script=scan_script,
            )
            data = destination.read_bytes()
            digest = sha256(data)
            expected = EXPECTED_SHA256[case["file"]]
            if version.startswith(EXPECTED_CJPEG_VERSION_PREFIX) and digest != expected:
                raise SystemExit(
                    f"deterministic fixture drift for {case['file']}: expected {expected}, got {digest}"
                )
            scan_sizes, restart_markers = inspect_jpeg(data)
            manifest_cases.append(
                {
                    "file": case["file"],
                    "width": case["width"],
                    "height": case["height"],
                    "quality": case["quality"],
                    "restart": case["restart"],
                    "scanScriptID": case["scanScriptID"],
                    "byteCount": len(data),
                    "sha256": digest,
                    "scanCount": len(scan_sizes),
                    "maximumEntropyScanByteCount": max(scan_sizes),
                    "restartMarkerCount": restart_markers,
                }
            )

    manifest = {
        "schemaVersion": 1,
        "generator": "generate_progressive_session_stress.py",
        "cjpegVersion": version,
        "sampling": "2x2,1x1,1x1",
        "cases": manifest_cases,
    }
    (output_dir / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    )
    print(json.dumps(manifest, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
