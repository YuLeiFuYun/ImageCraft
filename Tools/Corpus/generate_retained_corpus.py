#!/usr/bin/env python3
import argparse
import base64
import binascii
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import zlib

SCHEMA_VERSION = 1
GENERATOR = "imagecraft-retained-corpus-v1"


def chunk(kind: bytes, payload: bytes) -> bytes:
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", binascii.crc32(kind + payload) & 0xFFFFFFFF)


def png_rgba(width: int, height: int, *, srgb: bool, text_payload: bytes | None = None) -> bytes:
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            rows.extend(((x * 17 + y * 3) & 0xFF, (x * 5 + y * 29) & 0xFF, (255 - x * 9 - y * 7) & 0xFF, (x * 23 + y * 37) & 0xFF))
    result = bytearray(b"\x89PNG\r\n\x1a\n")
    result.extend(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)))
    if srgb:
        result.extend(chunk(b"sRGB", b"\x00"))
    if text_payload is not None:
        result.extend(chunk(b"tEXt", text_payload))
    result.extend(chunk(b"IDAT", zlib.compress(bytes(rows), level=9)))
    result.extend(chunk(b"IEND", b""))
    return bytes(result)


def png_gray(width: int, height: int) -> bytes:
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            rows.append((x * 31 + y * 47) & 0xFF)
    result = bytearray(b"\x89PNG\r\n\x1a\n")
    result.extend(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0)))
    result.extend(chunk(b"IDAT", zlib.compress(bytes(rows), level=9)))
    result.extend(chunk(b"IEND", b""))
    return bytes(result)


def ppm(width: int, height: int) -> bytes:
    pixels = bytearray()
    for y in range(height):
        for x in range(width):
            checker = 37 if ((x // 4) + (y // 4)) % 2 == 0 else 211
            pixels.extend(((x * 17 + y * 3 + checker) & 0xFF, (x * 5 + y * 19 + checker // 2) & 0xFF, (x * 11 + y * 7 + 255 - checker) & 0xFF))
    return f"P6\n{width} {height}\n255\n".encode() + pixels


def pgm(width: int, height: int) -> bytes:
    pixels = bytes((x * 23 + y * 41) & 0xFF for y in range(height) for x in range(width))
    return f"P5\n{width} {height}\n255\n".encode() + pixels


def inject_jpeg_segment(data: bytes, marker: int, payload: bytes) -> bytes:
    if not data.startswith(b"\xFF\xD8") or len(payload) > 65533:
        raise ValueError("invalid JPEG or segment")
    segment = bytes((0xFF, marker)) + struct.pack(">H", len(payload) + 2) + payload
    return data[:2] + segment + data[2:]


def exif_orientation_payload(orientation: int) -> bytes:
    tiff = b"II" + struct.pack("<H", 42) + struct.pack("<I", 8)
    tiff += struct.pack("<H", 1)
    tiff += struct.pack("<HHI", 0x0112, 3, 1)
    tiff += struct.pack("<H", orientation) + b"\x00\x00"
    tiff += struct.pack("<I", 0)
    return b"Exif\x00\x00" + tiff


def run(command: list[str]) -> str:
    completed = subprocess.run(command, check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return completed.stdout.strip()


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path: Path, data: bytes) -> None:
    path.write_bytes(data)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cjpeg", required=True)
    parser.add_argument("--jpeg-prefix", type=Path, required=True)
    parser.add_argument("--cc", default=os.environ.get("CC", "cc"))
    args = parser.parse_args()

    output = args.output
    output.mkdir(parents=True, exist_ok=True)
    for existing in output.iterdir():
        if existing.is_file():
            existing.unlink()
        else:
            shutil.rmtree(existing)

    write(output / "png-rgba-srgb.png", png_rgba(17, 9, srgb=True))
    write(output / "png-gray-unlabeled.png", png_gray(7, 5))
    text_payload = b"ImageCraft\x00" + b"A" * (128 - len(b"ImageCraft\x00"))
    write(output / "png-text-128.png", png_rgba(13, 7, srgb=True, text_payload=text_payload))
    write(output / "png-truncated.png", (output / "png-rgba-srgb.png").read_bytes()[:-1])

    with tempfile.TemporaryDirectory() as temporary:
        temp = Path(temporary)
        rgb = temp / "source.ppm"
        gray = temp / "gray.pgm"
        rgb.write_bytes(ppm(23, 13))
        gray.write_bytes(pgm(19, 11))
        baseline = output / "jpeg-baseline-420.jpg"
        progressive = output / "jpeg-progressive-420.jpg"
        grayscale = output / "jpeg-grayscale.jpg"
        run([args.cjpeg, "-quality", "75", "-sample", "2x2,1x1,1x1", "-baseline", "-outfile", str(baseline), str(rgb)])
        run([args.cjpeg, "-quality", "75", "-sample", "2x2,1x1,1x1", "-progressive", "-outfile", str(progressive), str(rgb)])
        run([args.cjpeg, "-quality", "85", "-grayscale", "-baseline", "-outfile", str(grayscale), str(gray)])

        cmyk_tool = temp / "jpeg_cmyk_fixture"
        source = Path(__file__).with_name("jpeg_cmyk_fixture.c")
        run([args.cc, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", f"-I{args.jpeg_prefix / 'include'}", str(source), f"-L{args.jpeg_prefix / 'lib'}", "-ljpeg", "-o", str(cmyk_tool)])
        run([str(cmyk_tool), str(output / "jpeg-cmyk.jpg")])

    baseline_data = (output / "jpeg-baseline-420.jpg").read_bytes()
    write(output / "jpeg-orientation-6.jpg", inject_jpeg_segment(baseline_data, 0xE1, exif_orientation_payload(6)))
    write(output / "jpeg-app3-128.jpg", inject_jpeg_segment(baseline_data, 0xE3, b"M" * 128))
    write(output / "jpeg-truncated.jpg", baseline_data[:-2])

    static_gif = base64.b64decode("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")
    trailer = static_gif.rfind(b"\x3B")
    image_start = static_gif.find(b"\x21\xF9")
    animated_gif = static_gif[:trailer] + static_gif[image_start:trailer] + b"\x3B"
    write(output / "gif-static.gif", static_gif)
    write(output / "gif-animated-two-frame.gif", animated_gif)
    write(output / "gif-truncated.gif", static_gif[:-1])

    cases = [
        {"id": "png-rgba-srgb", "file": "png-rgba-srgb.png", "kind": "valid", "format": "png", "width": 17, "height": 9, "frames": 1, "orientation": 1, "sourceColorProfile": "standardSRGB", "alpha": "present"},
        {"id": "png-gray-unlabeled", "file": "png-gray-unlabeled.png", "kind": "valid", "format": "png", "width": 7, "height": 5, "frames": 1, "orientation": 1, "sourceColorProfile": "absent", "alpha": "none"},
        {"id": "png-text-128", "file": "png-text-128.png", "kind": "metadataBoundary", "format": "png", "width": 13, "height": 7, "frames": 1, "orientation": 1, "sourceColorProfile": "standardSRGB", "containerMetadataBytes": 128},
        {"id": "png-truncated", "file": "png-truncated.png", "kind": "failure", "expectedError": "unsupportedOrCorruptImage"},
        {"id": "jpeg-baseline-420", "file": "jpeg-baseline-420.jpg", "kind": "valid", "format": "jpeg", "width": 23, "height": 13, "frames": 1, "orientation": 1, "sourceColorProfile": "absent", "jpegFrame": "baseline", "components": 3},
        {"id": "jpeg-progressive-420", "file": "jpeg-progressive-420.jpg", "kind": "valid", "format": "jpeg", "width": 23, "height": 13, "frames": 1, "orientation": 1, "sourceColorProfile": "absent", "jpegFrame": "progressive", "components": 3},
        {"id": "jpeg-orientation-6", "file": "jpeg-orientation-6.jpg", "kind": "valid", "format": "jpeg", "width": 13, "height": 23, "frames": 1, "orientation": 6, "sourceColorProfile": "absent", "jpegFrame": "baseline", "components": 3},
        {"id": "jpeg-grayscale", "file": "jpeg-grayscale.jpg", "kind": "valid", "format": "jpeg", "width": 19, "height": 11, "frames": 1, "orientation": 1, "sourceColorProfile": "absent", "jpegFrame": "baseline", "components": 1},
        {"id": "jpeg-cmyk", "file": "jpeg-cmyk.jpg", "kind": "valid", "format": "jpeg", "width": 11, "height": 7, "frames": 1, "orientation": 1, "sourceColorProfile": "absent", "jpegFrame": "baseline", "components": 4},
        {"id": "jpeg-app3-128", "file": "jpeg-app3-128.jpg", "kind": "metadataBoundary", "format": "jpeg", "width": 23, "height": 13, "frames": 1, "orientation": 1, "sourceColorProfile": "absent", "containerMetadataBytes": 128},
        {"id": "jpeg-truncated", "file": "jpeg-truncated.jpg", "kind": "failure", "expectedError": "unsupportedOrCorruptImage"},
        {"id": "gif-static", "file": "gif-static.gif", "kind": "valid", "format": "gif", "width": 1, "height": 1, "frames": 1, "orientation": 1, "sourceColorProfile": "absent"},
        {"id": "gif-animated-two-frame", "file": "gif-animated-two-frame.gif", "kind": "frameBoundary", "format": "gif", "width": 1, "height": 1, "frames": 2, "orientation": 1, "sourceColorProfile": "absent", "expectedCoreError": "frameLimitExceeded"},
        {"id": "gif-truncated", "file": "gif-truncated.gif", "kind": "failure", "expectedError": "unsupportedOrCorruptImage"},
    ]
    for case in cases:
        path = output / case["file"]
        case["byteCount"] = path.stat().st_size
        case["sha256"] = sha256(path)

    cjpeg_version = run([args.cjpeg, "-version"]).splitlines()[0]
    manifest = {
        "schemaVersion": SCHEMA_VERSION,
        "corpusVersion": "v1",
        "generator": GENERATOR,
        "tools": {"cjpeg": cjpeg_version, "cmykGenerator": "libjpeg API via jpeg-turbo"},
        "cases": cases,
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
