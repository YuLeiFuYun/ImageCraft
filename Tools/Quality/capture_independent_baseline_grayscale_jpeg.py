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


DEFAULT_PROFILE = (
    ROOT / "Evidence/Experiments/IndependentBaselineGrayscaleJPEG/v1/profile.json"
)
DEFAULT_OUTPUT = (
    ROOT / ".artifacts/program/T101/independent-baseline-grayscale-jpeg-v1.json"
)


def write_pgm(path: Path, width: int, height: int, pattern: str) -> bytes:
    pixels = bytearray(width * height)
    for y in range(height):
        for x in range(width):
            if pattern == "flat":
                value = 127
            elif pattern == "horizontal-ramp":
                value = 0 if width == 1 else round(x * 255 / (width - 1))
            elif pattern == "checker":
                value = 24 if ((x // 3) + (y // 2)) & 1 == 0 else 231
            elif pattern == "deterministic-noise":
                value = (x * 37 + y * 71 + x * y * 19 + width * 11 + height * 7) & 0xFF
            else:
                raise CaptureError(f"unsupported baseline grayscale pattern: {pattern}")
            pixels[y * width + x] = value
    data = f"P5\n{width} {height}\n255\n".encode() + bytes(pixels)
    path.write_bytes(data)
    return data


def parse_pgm(path: Path, expected_width: int, expected_height: int) -> bytes:
    data = path.read_bytes()
    if not data.startswith(b"P5"):
        raise CaptureError("djpeg grayscale reference is not binary PGM")
    position = 2
    tokens: list[bytes] = []
    while len(tokens) < 3:
        while position < len(data) and data[position : position + 1].isspace():
            position += 1
        if position < len(data) and data[position] == ord("#"):
            newline = data.find(b"\n", position)
            if newline < 0:
                raise CaptureError("unterminated PGM comment")
            position = newline + 1
            continue
        end = position
        while end < len(data) and not data[end : end + 1].isspace():
            end += 1
        if end == position:
            raise CaptureError("missing PGM header token")
        tokens.append(data[position:end])
        position = end
    width, height, maximum = (int(token) for token in tokens)
    if (width, height, maximum) != (expected_width, expected_height, 255):
        raise CaptureError("unexpected PGM reference geometry")
    raster_bytes = width * height
    raster_start = len(data) - raster_bytes
    if raster_start <= position:
        raise CaptureError("unexpected PGM reference byte count")
    separator = data[position:raster_start]
    if not separator or any(not bytes([value]).isspace() for value in separator):
        raise CaptureError("unexpected PGM header/raster separator")
    pixels = data[raster_start:]
    if len(pixels) != raster_bytes:
        raise CaptureError("unexpected PGM raster byte count")
    return pixels


def generated_cases(profile: dict[str, Any]) -> list[dict[str, Any]]:
    cases: list[dict[str, Any]] = []
    for raw_width, raw_height in profile["geometryCases"]:
        width, height = int(raw_width), int(raw_height)
        cases.append(
            {
                "id": f"geometry-{width}x{height}-q75-no-restart",
                "width": width,
                "height": height,
                "pattern": "deterministic-noise",
                "quality": 75,
                "restart": None,
            }
        )
    for pattern in profile["patterns"]:
        for quality in profile["qualities"]:
            cases.append(
                {
                    "id": f"content-{pattern}-q{quality}-19x11",
                    "width": 19,
                    "height": 11,
                    "pattern": str(pattern),
                    "quality": int(quality),
                    "restart": None,
                }
            )
    for interval in profile["restartIntervalsMCUs"]:
        for width, height in [(17, 13), (31, 19), (64, 17)]:
            cases.append(
                {
                    "id": f"restart-{interval}B-{width}x{height}",
                    "width": width,
                    "height": height,
                    "pattern": "deterministic-noise",
                    "quality": 75,
                    "restart": int(interval),
                }
            )
    return cases


def run_imagecraft(
    executable: Path,
    jpeg_path: Path,
    raw_path: Path,
    label: str,
) -> tuple[dict[str, Any], bytes]:
    completed = run(
        [
            str(executable),
            "--independent-baseline-grayscale-jpeg",
            str(jpeg_path),
            "--output",
            str(raw_path),
        ]
    )
    if completed.stderr.strip():
        raise CaptureError(
            f"ImageCraft baseline grayscale emitted diagnostics for {label}: "
            f"{completed.stderr.strip()}"
        )
    report = parse_json_stdout(completed, f"ImageCraft baseline grayscale {label}")
    pixels = raw_path.read_bytes()
    decoder = report.get("decoder")
    output = report.get("output")
    if (
        report.get("evidenceVersion") != "imagecraft-independent-baseline-grayscale-jpeg-v1"
        or report.get("thresholdMinusOneRejectedBeforeDecodeAllocation") is not True
        or not isinstance(decoder, dict)
        or decoder.get("fixedScratchByteCount") != 512
        or not isinstance(output, dict)
        or output.get("sha256") != sha256_bytes(pixels)
    ):
        raise CaptureError(f"ImageCraft baseline grayscale evidence drifted: {label}")
    return report, pixels


def djpeg_reference(
    djpeg: Path,
    jpeg_path: Path,
    output_path: Path,
    width: int,
    height: int,
    label: str,
) -> bytes:
    completed = run(
        [
            str(djpeg),
            "-grayscale",
            "-dct",
            "int",
            "-pnm",
            "-outfile",
            str(output_path),
            str(jpeg_path),
        ]
    )
    if completed.stderr.strip():
        raise CaptureError(
            f"djpeg emitted diagnostics for {label}: {completed.stderr.strip()}"
        )
    return parse_pgm(output_path, width, height)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, default=DEFAULT_PROFILE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    profile_path = args.profile if args.profile.is_absolute() else ROOT / args.profile
    output_path = args.output if args.output.is_absolute() else ROOT / args.output
    profile = json.loads(profile_path.read_text())
    if profile.get("profileID") != "IMAGECRAFT-INDEPENDENT-BASELINE-GRAYSCALE-JPEG-V1":
        raise CaptureError("unexpected independent baseline grayscale profile ID")

    with tempfile.TemporaryDirectory(prefix="imagecraft-baseline-gray-") as temp_raw:
        temp = Path(temp_raw)
        before = capture_source_identity(temp / "source-before.json")
        jpeg_prefix = Path(run(["brew", "--prefix", "jpeg-turbo"]).stdout.strip())
        cjpeg = jpeg_prefix / "bin/cjpeg"
        djpeg = jpeg_prefix / "bin/djpeg"
        if not cjpeg.is_file() or not djpeg.is_file():
            raise CaptureError("pinned cjpeg/djpeg are unavailable")
        cjpeg_version = run([str(cjpeg), "-version"]).stderr.strip()
        djpeg_version = run([str(djpeg), "-version"]).stderr.strip()
        required_version = profile.get("requiredLibJPEGTurboVersionPrefix")
        if (
            not isinstance(required_version, str)
            or not cjpeg_version.startswith(required_version)
            or not djpeg_version.startswith(required_version)
        ):
            raise CaptureError("jpeg-turbo runtime is outside baseline grayscale qualification")

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

        case_results: list[dict[str, Any]] = []
        for case in generated_cases(profile):
            case_id = str(case["id"])
            width, height = int(case["width"]), int(case["height"])
            source_path = temp / f"{case_id}.pgm"
            source = write_pgm(source_path, width, height, str(case["pattern"]))
            jpeg_path = temp / f"{case_id}.jpg"
            cjpeg_argv = [
                str(cjpeg),
                "-grayscale",
                "-quality",
                str(case["quality"]),
                "-dct",
                "int",
                "-optimize",
            ]
            if case["restart"] is not None:
                cjpeg_argv.extend(["-restart", f"{case['restart']}B"])
            cjpeg_argv.extend(["-outfile", str(jpeg_path), str(source_path)])
            encoded_completed = run(cjpeg_argv)
            if encoded_completed.stderr.strip():
                raise CaptureError(
                    f"cjpeg emitted diagnostics for {case_id}: {encoded_completed.stderr.strip()}"
                )
            encoded = jpeg_path.read_bytes()
            reference = djpeg_reference(
                djpeg,
                jpeg_path,
                temp / f"{case_id}.reference.pgm",
                width,
                height,
                case_id,
            )
            imagecraft_report, imagecraft_pixels = run_imagecraft(
                imagecraft,
                jpeg_path,
                temp / f"{case_id}.imagecraft.raw",
                case_id,
            )
            if imagecraft_pixels != reference:
                mismatch = next(
                    (
                        index,
                        imagecraft_pixels[index],
                        reference[index],
                    )
                    for index in range(min(len(imagecraft_pixels), len(reference)))
                    if imagecraft_pixels[index] != reference[index]
                )
                raise CaptureError(
                    f"ImageCraft baseline grayscale differs from libjpeg: "
                    f"{case_id} mismatch={mismatch}"
                )
            expected_charge = width * height + 512
            if imagecraft_report["decoder"]["operationByteCharge"] != expected_charge:
                raise CaptureError(f"operation charge drifted: {case_id}")
            if case["restart"] is not None and (
                imagecraft_report["decoder"]["restartIntervalMCUs"] != case["restart"]
            ):
                raise CaptureError(f"restart interval drifted: {case_id}")
            case_results.append(
                {
                    **case,
                    "sourcePGMSHA256": sha256_bytes(source),
                    "jpegByteCount": len(encoded),
                    "jpegSHA256": sha256_bytes(encoded),
                    "referenceSHA256": sha256_bytes(reference),
                    "imageCraftSHA256": sha256_bytes(imagecraft_pixels),
                    "imageCraftEvidence": imagecraft_report,
                    "exactLibjpegISlow": True,
                }
            )

        retained_results: list[dict[str, Any]] = []
        for retained in profile["retainedCases"]:
            case_id = str(retained["id"])
            jpeg_path = ROOT / str(retained["file"])
            encoded = jpeg_path.read_bytes()
            if sha256_bytes(encoded) != retained["sha256"]:
                raise CaptureError(f"retained baseline grayscale SHA drifted: {case_id}")
            reference = djpeg_reference(
                djpeg,
                jpeg_path,
                temp / f"{case_id}.reference.pgm",
                19,
                11,
                case_id,
            )
            imagecraft_report, imagecraft_pixels = run_imagecraft(
                imagecraft,
                jpeg_path,
                temp / f"{case_id}.imagecraft.raw",
                case_id,
            )
            if imagecraft_pixels != reference:
                raise CaptureError(f"retained baseline grayscale differs from libjpeg: {case_id}")
            retained_results.append(
                {
                    **retained,
                    "jpegByteCount": len(encoded),
                    "referenceSHA256": sha256_bytes(reference),
                    "imageCraftSHA256": sha256_bytes(imagecraft_pixels),
                    "imageCraftEvidence": imagecraft_report,
                    "exactLibjpegISlow": True,
                }
            )

        after = capture_source_identity(temp / "source-after.json")
        before_hash = before.get("sourceIdentitySHA256")
        if not before_hash or before_hash != after.get("sourceIdentitySHA256"):
            raise CaptureError("ImageCraft source identity changed during baseline grayscale capture")

        combined = case_results + retained_results
        report = {
            "schemaVersion": 1,
            "evidenceVersion": "imagecraft-independent-baseline-grayscale-jpeg-conformance-v1",
            "status": "source-bound-package-backend-slice-conformance",
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
                "imageCraftEvidenceSHA256": sha256_file(imagecraft),
            },
            "claimBoundary": profile["claimBoundary"],
            "cases": case_results,
            "retainedCases": retained_results,
            "summary": {
                "generatedCaseCount": len(case_results),
                "retainedCaseCount": len(retained_results),
                "allExactLibjpegISlow": all(case["exactLibjpegISlow"] for case in combined),
                "allThresholdMinusOneRejected": all(
                    case["imageCraftEvidence"][
                        "thresholdMinusOneRejectedBeforeDecodeAllocation"
                    ]
                    for case in combined
                ),
                "fixedScratchByteCount": 512,
                "restartCaseCount": sum(
                    1 for case in case_results if case["restart"] is not None
                ),
                "maximumOperationByteCharge": max(
                    int(case["imageCraftEvidence"]["decoder"]["operationByteCharge"])
                    for case in combined
                ),
            },
        }
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(
            "independent baseline grayscale JPEG captured: "
            f"generated={len(case_results)} retained={len(retained_results)} "
            f"source={before_hash} output={output_path}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
