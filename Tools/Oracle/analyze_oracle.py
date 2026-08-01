#!/usr/bin/env python3
import argparse
import hashlib
import json
import math
import platform
from pathlib import Path

QUALITIES = (25, 50, 75, 90)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--jpeg-version", required=True)
    parser.add_argument("--png-version", required=True)
    return parser.parse_args()


def read_ppm(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    if not data.startswith(b"P6"):
        raise ValueError(f"{path} is not a binary PPM")
    offset = 2
    tokens: list[int] = []
    while len(tokens) < 3:
        while offset < len(data) and data[offset] in b" \t\r\n":
            offset += 1
        if offset < len(data) and data[offset] == ord("#"):
            while offset < len(data) and data[offset] != ord("\n"):
                offset += 1
            continue
        end = offset
        while end < len(data) and data[end] not in b" \t\r\n":
            end += 1
        tokens.append(int(data[offset:end]))
        offset = end
    while offset < len(data) and data[offset] in b" \t\r\n":
        offset += 1
    width, height, maximum = tokens
    if maximum != 255:
        raise ValueError(f"{path} uses unsupported maximum {maximum}")
    pixels = data[offset:]
    expected = width * height * 3
    if len(pixels) != expected:
        raise ValueError(f"{path} has {len(pixels)} pixel bytes, expected {expected}")
    return width, height, pixels


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def metrics(reference: bytes, candidate: bytes) -> dict[str, float | int]:
    if len(reference) != len(candidate):
        raise ValueError("pixel buffers differ in length")
    differences = [abs(left - right) for left, right in zip(reference, candidate)]
    squared_error = sum(value * value for value in differences)
    mse = squared_error / len(differences)
    psnr = 10 * math.log10((255 * 255) / mse) if mse else 999.0
    return {
        "differentChannelCount": sum(value != 0 for value in differences),
        "maximumAbsoluteError": max(differences),
        "meanAbsoluteError": round(sum(differences) / len(differences), 9),
        "meanSquaredError": round(mse, 9),
        "psnrDB": round(psnr, 9),
    }


def load_pixels(path: Path, expected_size: tuple[int, int]) -> bytes:
    width, height, pixels = read_ppm(path)
    if (width, height) != expected_size:
        raise AssertionError(
            f"{path} dimensions {(width, height)} do not match {expected_size}"
        )
    return pixels


def jpeg_entry(
    root: Path,
    encoder: str,
    quality: int,
    source: bytes,
    expected_size: tuple[int, int],
) -> dict:
    if encoder == "imageio":
        jpeg_path = root / "artifacts" / f"imageio-q0.{quality:02d}.jpg"
    else:
        jpeg_path = root / "turbo" / f"turbo-q{quality}.jpg"
    imageio_pixels = load_pixels(
        root / "decoded" / f"imageio-{encoder}-q{quality}.ppm", expected_size
    )
    turbo_pixels = load_pixels(
        root / "decoded" / f"djpeg-{encoder}-q{quality}.ppm", expected_size
    )
    return {
        "byteCount": jpeg_path.stat().st_size,
        "imageIODecode": metrics(source, imageio_pixels),
        "libjpegTurboDecode": metrics(source, turbo_pixels),
        "quality": quality,
        "sha256": sha256(jpeg_path),
        "crossDecoder": metrics(imageio_pixels, turbo_pixels),
    }


def validate_jpeg_series(name: str, entries: list[dict]) -> None:
    for entry in entries:
        if entry["imageIODecode"]["psnrDB"] < 14.0:
            raise AssertionError(f"{name} ImageIO decode PSNR too low: {entry}")
        if entry["libjpegTurboDecode"]["psnrDB"] < 14.0:
            raise AssertionError(f"{name} libjpeg-turbo decode PSNR too low: {entry}")
        if entry["crossDecoder"]["psnrDB"] < 27.0:
            raise AssertionError(f"{name} cross-decoder PSNR too low: {entry}")
    for key in ("imageIODecode", "libjpegTurboDecode"):
        values = [entry[key]["psnrDB"] for entry in entries]
        if any(right < left for left, right in zip(values, values[1:])):
            raise AssertionError(f"{name} {key} PSNR is not monotone: {values}")
        if values[-1] - values[0] < 2.5:
            raise AssertionError(f"{name} {key} quality range is ineffective: {values}")
    byte_counts = [entry["byteCount"] for entry in entries]
    if any(right <= left for left, right in zip(byte_counts, byte_counts[1:])):
        raise AssertionError(f"{name} encoded sizes are not strictly increasing: {byte_counts}")


def main() -> None:
    args = parse_args()
    evidence = json.loads(args.evidence.read_text(encoding="utf-8"))
    width = evidence["source"]["width"]
    height = evidence["source"]["height"]
    expected_size = (width, height)
    source_width, source_height, source = read_ppm(args.root / "artifacts" / "source.ppm")
    if (source_width, source_height) != expected_size:
        raise AssertionError("source PPM does not match evidence dimensions")

    imageio_png = load_pixels(
        args.root / "decoded" / "imageio-imageio.png.ppm", expected_size
    )
    libpng_png = load_pixels(
        args.root / "decoded" / "libpng-imageio.png.ppm", expected_size
    )
    if imageio_png != source:
        raise AssertionError("ImageIO PNG round-trip changed source pixels")
    if libpng_png != source:
        raise AssertionError("libpng did not recover exact source pixels from ImageIO PNG")

    imageio_entries = [
        jpeg_entry(args.root, "imageio", quality, source, expected_size)
        for quality in QUALITIES
    ]
    turbo_entries = [
        jpeg_entry(args.root, "turbo", quality, source, expected_size)
        for quality in QUALITIES
    ]
    validate_jpeg_series("ImageIO", imageio_entries)
    validate_jpeg_series("libjpeg-turbo", turbo_entries)

    report = {
        "schemaVersion": 1,
        "runtime": evidence["runtime"],
        "imageCraftEncoderFingerprint": evidence["encoderFingerprint"],
        "source": {
            "generator": evidence["source"]["generator"],
            "height": height,
            "ppmSHA256": sha256(args.root / "artifacts" / "source.ppm"),
            "width": width,
        },
        "oracles": {
            "analysisPython": platform.python_version(),
            "libjpegTurbo": args.jpeg_version,
            "libpng": args.png_version,
        },
        "png": {
            "byteCount": (args.root / "artifacts" / "imageio.png").stat().st_size,
            "imageIODecodeExact": True,
            "libpngDecodeExact": True,
            "sha256": sha256(args.root / "artifacts" / "imageio.png"),
        },
        "jpeg": {
            "imageIOEncoder": imageio_entries,
            "libjpegTurboEncoder": turbo_entries,
        },
    }
    print(json.dumps(report, indent=2, sort_keys=True, ensure_ascii=False))


if __name__ == "__main__":
    main()
