#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
import platform
import tempfile
from typing import Any

from capture_libjpeg_progressive_suspension import (
    build_imagecraft_evidence,
    CaptureError,
    ROOT,
    capture_source_identity,
    parse_json_stdout,
    run,
    sha256_bytes,
    sha256_file,
)
from capture_progressive_jpeg_imcu_chroma_context import build_c_tool


DEFAULT_PROFILE = ROOT / "Evidence/Experiments/JPEGYCbCrToRGB/v1/profile.json"
DEFAULT_OUTPUT = ROOT / ".artifacts/program/T101/jpeg-ycbcr-to-rgb-v1.json"
PROBE_SOURCE = ROOT / "Tools/Quality/LibJPEGTurboUpsampledYCbCrInterleavedProbe/main.c"


def write_ppm(path: Path, width: int, height: int, pattern: str) -> bytes:
    pixels = bytearray(width * height * 3)
    for y in range(height):
        for x in range(width):
            index = (y * width + x) * 3
            if pattern == "neutral-gradient":
                value = 0 if width == 1 else round(x * 255 / (width - 1))
                r, g, b = value, value, value
            elif pattern == "chroma-grid":
                r = (x * 41 + y * 7 + 17) & 0xFF
                g = (x * 11 + y * 53 + 91) & 0xFF
                b = (x * 67 + y * 19 + 203) & 0xFF
            elif pattern == "deterministic-noise":
                r = (x * 37 + y * 71 + x * y * 13 + 23) & 0xFF
                g = (x * 61 + y * 29 + x * y * 17 + 47) & 0xFF
                b = (x * 17 + y * 83 + x * y * 23 + 131) & 0xFF
            else:
                raise CaptureError(f"unsupported RGB source pattern: {pattern}")
            pixels[index] = r
            pixels[index + 1] = g
            pixels[index + 2] = b
    payload = f"P6\n{width} {height}\n255\n".encode() + bytes(pixels)
    path.write_bytes(payload)
    return payload


def parse_ppm(path: Path, expected_width: int, expected_height: int) -> bytes:
    data = path.read_bytes()
    if not data.startswith(b"P6"):
        raise CaptureError("djpeg RGB reference is not binary PPM")
    position = 2
    tokens: list[bytes] = []
    while len(tokens) < 3:
        while position < len(data) and data[position : position + 1].isspace():
            position += 1
        if position < len(data) and data[position] == ord("#"):
            newline = data.find(b"\n", position)
            if newline < 0:
                raise CaptureError("unterminated PPM comment")
            position = newline + 1
            continue
        end = position
        while end < len(data) and not data[end : end + 1].isspace():
            end += 1
        if end == position:
            raise CaptureError("missing PPM header token")
        tokens.append(data[position:end])
        position = end
    width, height, maximum = (int(token) for token in tokens)
    if (width, height, maximum) != (expected_width, expected_height, 255):
        raise CaptureError("unexpected PPM reference geometry")
    raster_bytes = width * height * 3
    raster_start = len(data) - raster_bytes
    if raster_start <= position:
        raise CaptureError("unexpected PPM reference byte count")
    separator = data[position:raster_start]
    if not separator or any(not bytes([value]).isspace() for value in separator):
        raise CaptureError("unexpected PPM header/raster separator")
    pixels = data[raster_start:]
    if len(pixels) != raster_bytes:
        raise CaptureError("unexpected PPM raster byte count")
    return pixels


def parse_sof(data: bytes) -> tuple[str, int, int, list[list[int]]]:
    if not data.startswith(b"\xff\xd8"):
        raise CaptureError("generated JPEG is missing SOI")
    offset = 2
    while offset < len(data):
        if data[offset] != 0xFF:
            raise CaptureError(f"JPEG marker does not start with 0xFF at {offset}")
        while offset < len(data) and data[offset] == 0xFF:
            offset += 1
        if offset >= len(data):
            raise CaptureError("truncated JPEG marker")
        marker = data[offset]
        offset += 1
        if marker == 0xD9:
            break
        if marker == 0xD8 or marker == 0x01 or 0xD0 <= marker <= 0xD7:
            continue
        if offset + 2 > len(data):
            raise CaptureError("truncated JPEG segment length")
        length = int.from_bytes(data[offset : offset + 2], "big")
        if length < 2 or offset + length > len(data):
            raise CaptureError("JPEG segment exceeds input")
        payload = data[offset + 2 : offset + length]
        if marker in {0xC0, 0xC2}:
            if len(payload) < 6:
                raise CaptureError("truncated SOF")
            precision = payload[0]
            height = int.from_bytes(payload[1:3], "big")
            width = int.from_bytes(payload[3:5], "big")
            count = payload[5]
            if precision != 8 or count != 3 or len(payload) != 6 + 3 * count:
                raise CaptureError("unexpected generated SOF shape")
            factors: list[list[int]] = []
            for component in range(count):
                sampling = payload[7 + component * 3]
                factors.append([sampling >> 4, sampling & 0x0F])
            return ("baseline" if marker == 0xC0 else "progressive", width, height, factors)
        if marker == 0xDA:
            raise CaptureError("SOS reached before SOF")
        offset += length
    raise CaptureError("generated JPEG is missing SOF0/SOF2")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, default=DEFAULT_PROFILE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    profile_path = args.profile if args.profile.is_absolute() else ROOT / args.profile
    output_path = args.output if args.output.is_absolute() else ROOT / args.output
    profile = json.loads(profile_path.read_text())
    if profile.get("profileID") != "IMAGECRAFT-JPEG-YCBCR-TO-RGB-V1":
        raise CaptureError("unexpected JPEG YCbCr-to-RGB profile ID")
    width, height = (int(value) for value in profile["geometry"])

    with tempfile.TemporaryDirectory(prefix="imagecraft-jpeg-ycbcr-rgb-") as temp_raw:
        temp = Path(temp_raw)
        before = capture_source_identity(temp / "source-before.json")
        jpeg_prefix = Path(run(["brew", "--prefix", "jpeg-turbo"]).stdout.strip())
        cjpeg = jpeg_prefix / "bin/cjpeg"
        djpeg = jpeg_prefix / "bin/djpeg"
        if not cjpeg.is_file() or not djpeg.is_file():
            raise CaptureError("pinned cjpeg/djpeg are unavailable")
        cjpeg_version = run([str(cjpeg), "-version"]).stderr.strip()
        djpeg_version = run([str(djpeg), "-version"]).stderr.strip()
        required = profile.get("requiredLibJPEGTurboVersionPrefix")
        if (
            not isinstance(required, str)
            or not cjpeg_version.startswith(required)
            or not djpeg_version.startswith(required)
        ):
            raise CaptureError("jpeg-turbo runtime is outside YCbCr-to-RGB qualification")

        probe = build_c_tool(
            temp,
            PROBE_SOURCE,
            "upsampled-ycbcr-interleaved-probe",
            jpeg_prefix,
        )
        build = run(
            [
                "swift",
                "build",
                "-c",
                "release",
                "--product",
                "ImageCraftEvidence",
                "--jobs",
                "1",
            ],
            cwd=ROOT,
        )
        if "Build complete!" not in build.stdout:
            raise CaptureError("ImageCraftEvidence release build did not report completion")
        imagecraft = build_imagecraft_evidence()
        if not imagecraft.is_file():
            raise CaptureError("ImageCraftEvidence release binary is unavailable")

        source_paths: dict[str, tuple[Path, bytes]] = {}
        for pattern in profile["patterns"]:
            source_path = temp / f"source-{pattern}.ppm"
            source_paths[str(pattern)] = (
                source_path,
                write_ppm(source_path, width, height, str(pattern)),
            )

        results: list[dict[str, Any]] = []
        for sampling in profile["samplings"]:
            sampling_id = str(sampling["id"])
            cjpeg_sampling = str(sampling["cjpeg"])
            expected_factors = sampling["factors"]
            for coding_mode in profile["codingModes"]:
                for quality in profile["qualities"]:
                    for pattern in profile["patterns"]:
                        case_id = f"{sampling_id}-{coding_mode}-q{quality}-{pattern}"
                        source_path, source_bytes = source_paths[str(pattern)]
                        jpeg_path = temp / f"{case_id}.jpg"
                        argv = [
                            str(cjpeg),
                            "-quality",
                            str(quality),
                            "-dct",
                            "int",
                            "-optimize",
                            "-sample",
                            cjpeg_sampling,
                        ]
                        if coding_mode == "progressive":
                            argv.append("-progressive")
                        elif coding_mode != "baseline":
                            raise CaptureError(f"unsupported coding mode: {coding_mode}")
                        argv.extend(["-outfile", str(jpeg_path), str(source_path)])
                        completed = run(argv)
                        if completed.stderr.strip():
                            raise CaptureError(
                                f"cjpeg emitted diagnostics for {case_id}: {completed.stderr.strip()}"
                            )
                        encoded = jpeg_path.read_bytes()
                        actual_mode, actual_width, actual_height, factors = parse_sof(encoded)
                        if (
                            actual_mode != coding_mode
                            or (actual_width, actual_height) != (width, height)
                            or factors != expected_factors
                        ):
                            raise CaptureError(
                                f"generated JPEG SOF drifted: {case_id}: "
                                f"mode={actual_mode} geometry={actual_width}x{actual_height} factors={factors}"
                            )

                        ycbcr_path = temp / f"{case_id}.ycbcr.raw"
                        probe_completed = run([str(probe), str(jpeg_path), str(ycbcr_path)])
                        if probe_completed.stderr.strip():
                            raise CaptureError(
                                f"YCbCr probe emitted diagnostics for {case_id}: "
                                f"{probe_completed.stderr.strip()}"
                            )
                        probe_report = parse_json_stdout(probe_completed, f"YCbCr probe {case_id}")
                        ycbcr = ycbcr_path.read_bytes()
                        if (
                            len(ycbcr) != width * height * 3
                            or probe_report.get("width") != width
                            or probe_report.get("height") != height
                            or probe_report.get("outputComponents") != 3
                            or probe_report.get("fancyUpsampling") is not True
                            or probe_report.get("dctMethod") != "islow"
                            or probe_report.get("progressiveMode") is not (coding_mode == "progressive")
                        ):
                            raise CaptureError(f"YCbCr probe report drifted: {case_id}")

                        reference_path = temp / f"{case_id}.reference.ppm"
                        reference_completed = run(
                            [
                                str(djpeg),
                                "-rgb",
                                "-dct",
                                "int",
                                "-pnm",
                                "-outfile",
                                str(reference_path),
                                str(jpeg_path),
                            ]
                        )
                        if reference_completed.stderr.strip():
                            raise CaptureError(
                                f"djpeg emitted diagnostics for {case_id}: "
                                f"{reference_completed.stderr.strip()}"
                            )
                        reference = parse_ppm(reference_path, width, height)

                        imagecraft_path = temp / f"{case_id}.imagecraft.rgb"
                        imagecraft_completed = run(
                            [
                                str(imagecraft),
                                "--jpeg-ycbcr-to-rgb",
                                str(ycbcr_path),
                                "--output",
                                str(imagecraft_path),
                            ]
                        )
                        if imagecraft_completed.stderr.strip():
                            raise CaptureError(
                                f"ImageCraft color primitive emitted diagnostics for {case_id}: "
                                f"{imagecraft_completed.stderr.strip()}"
                            )
                        imagecraft_report = parse_json_stdout(
                            imagecraft_completed, f"ImageCraft YCbCr-to-RGB {case_id}"
                        )
                        imagecraft_rgb = imagecraft_path.read_bytes()
                        if imagecraft_rgb != reference:
                            mismatch = next(
                                (
                                    index,
                                    imagecraft_rgb[index],
                                    reference[index],
                                )
                                for index in range(min(len(imagecraft_rgb), len(reference)))
                                if imagecraft_rgb[index] != reference[index]
                            )
                            raise CaptureError(
                                f"ImageCraft YCbCr-to-RGB differs from libjpeg: "
                                f"{case_id} mismatch={mismatch}"
                            )
                        if (
                            imagecraft_report.get("evidenceVersion")
                            != "imagecraft-jpeg-ycbcr-to-rgb-v1"
                            or imagecraft_report.get("inputByteCount") != len(ycbcr)
                            or imagecraft_report.get("inputSHA256") != sha256_bytes(ycbcr)
                            or imagecraft_report.get("pixelCount") != width * height
                            or imagecraft_report.get("outputByteCount") != len(imagecraft_rgb)
                            or imagecraft_report.get("outputSHA256") != sha256_bytes(imagecraft_rgb)
                        ):
                            raise CaptureError(f"ImageCraft color report drifted: {case_id}")

                        results.append(
                            {
                                "id": case_id,
                                "sampling": sampling_id,
                                "samplingFactors": factors,
                                "codingMode": coding_mode,
                                "quality": int(quality),
                                "pattern": str(pattern),
                                "sourcePPMSHA256": sha256_bytes(source_bytes),
                                "jpegByteCount": len(encoded),
                                "jpegSHA256": sha256_bytes(encoded),
                                "fullResolutionYCbCrSHA256": sha256_bytes(ycbcr),
                                "referenceRGBSHA256": sha256_bytes(reference),
                                "imageCraftRGBSHA256": sha256_bytes(imagecraft_rgb),
                                "probe": probe_report,
                                "imageCraftEvidence": imagecraft_report,
                                "exactLibjpegRGB": True,
                            }
                        )

        after = capture_source_identity(temp / "source-after.json")
        before_hash = before.get("sourceIdentitySHA256")
        if not before_hash or before_hash != after.get("sourceIdentitySHA256"):
            raise CaptureError("ImageCraft source identity changed during YCbCr-to-RGB capture")

        report = {
            "schemaVersion": 1,
            "evidenceVersion": "imagecraft-jpeg-ycbcr-to-rgb-conformance-v1",
            "status": "source-bound-package-kernel-conformance",
            "formalSourceBoundExecution": True,
            "productionBackendQualified": False,
            "profile": {
                "profileID": profile["profileID"],
                "path": str(profile_path.relative_to(ROOT)),
                "sha256": sha256_file(profile_path),
            },
            "sourceIdentity": {
                "sourceIdentitySHA256": before_hash,
                "fileCount": before.get("fileCount"),
                "stableBeforeAfter": True,
            },
            "runtime": {
                "pythonVersion": platform.python_version(),
                "architecture": platform.machine(),
                "jpegTurboPrefix": str(jpeg_prefix),
                "cjpegVersion": cjpeg_version,
                "djpegVersion": djpeg_version,
                "cjpegSHA256": sha256_file(cjpeg),
                "djpegSHA256": sha256_file(djpeg),
                "probeSHA256": sha256_file(probe),
                "probeSourceSHA256": sha256_file(PROBE_SOURCE),
                "imageCraftEvidenceSHA256": sha256_file(imagecraft),
            },
            "claimBoundary": profile["claimBoundary"],
            "cases": results,
            "summary": {
                "caseCount": len(results),
                "allExactLibjpegRGB": all(case["exactLibjpegRGB"] for case in results),
                "samplings": sorted({str(case["sampling"]) for case in results}),
                "codingModes": sorted({str(case["codingMode"]) for case in results}),
                "qualities": sorted({int(case["quality"]) for case in results}),
                "patterns": sorted({str(case["pattern"]) for case in results}),
            },
        }
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(
            "JPEG YCbCr-to-RGB captured: "
            f"cases={len(results)} source={before_hash} output={output_path}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
