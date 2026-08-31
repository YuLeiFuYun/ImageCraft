#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
import platform
import tempfile
from typing import Any

from capture_jpeg_ycbcr_to_rgb_conformance import parse_ppm, parse_sof, write_ppm
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


DEFAULT_PROFILE = ROOT / "Evidence/Experiments/IndependentBaselineJPEG444/v1/profile.json"
DEFAULT_OUTPUT = ROOT / ".artifacts/program/T101/independent-baseline-jpeg-444-v1.json"


def cases(profile: dict[str, Any]) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for raw_width, raw_height in profile["geometryCases"]:
        width, height = int(raw_width), int(raw_height)
        result.append(
            {
                "id": f"geometry-{width}x{height}-q75",
                "width": width,
                "height": height,
                "pattern": "deterministic-noise",
                "quality": 75,
                "restart": None,
            }
        )
    for pattern in profile["patterns"]:
        for quality in profile["qualities"]:
            result.append(
                {
                    "id": f"content-{pattern}-q{quality}-31x19",
                    "width": 31,
                    "height": 19,
                    "pattern": str(pattern),
                    "quality": int(quality),
                    "restart": None,
                }
            )
    for interval in profile["restartIntervalsMCUs"]:
        for width, height in [(17, 13), (31, 19), (64, 17)]:
            result.append(
                {
                    "id": f"restart-{interval}B-{width}x{height}",
                    "width": width,
                    "height": height,
                    "pattern": "deterministic-noise",
                    "quality": 75,
                    "restart": int(interval),
                }
            )
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, default=DEFAULT_PROFILE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    profile_path = args.profile if args.profile.is_absolute() else ROOT / args.profile
    output_path = args.output if args.output.is_absolute() else ROOT / args.output
    profile = json.loads(profile_path.read_text())
    if profile.get("profileID") != "IMAGECRAFT-INDEPENDENT-BASELINE-JPEG-444-V1":
        raise CaptureError("unexpected baseline JPEG 4:4:4 profile ID")

    with tempfile.TemporaryDirectory(prefix="imagecraft-baseline-444-") as temp_raw:
        temp = Path(temp_raw)
        before = capture_source_identity(temp / "source-before.json")
        jpeg_prefix = Path(run(["brew", "--prefix", "jpeg-turbo"]).stdout.strip())
        cjpeg = jpeg_prefix / "bin/cjpeg"
        djpeg = jpeg_prefix / "bin/djpeg"
        cjpeg_version = run([str(cjpeg), "-version"]).stderr.strip()
        djpeg_version = run([str(djpeg), "-version"]).stderr.strip()
        required = profile.get("requiredLibJPEGTurboVersionPrefix")
        if (
            not isinstance(required, str)
            or not cjpeg_version.startswith(required)
            or not djpeg_version.startswith(required)
        ):
            raise CaptureError("jpeg-turbo runtime is outside baseline 4:4:4 qualification")

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

        results: list[dict[str, Any]] = []
        for case in cases(profile):
            case_id = str(case["id"])
            width, height = int(case["width"]), int(case["height"])
            source_path = temp / f"{case_id}.ppm"
            source = write_ppm(source_path, width, height, str(case["pattern"]))
            jpeg_path = temp / f"{case_id}.jpg"
            argv = [
                str(cjpeg),
                "-quality",
                str(case["quality"]),
                "-dct",
                "int",
                "-optimize",
                "-sample",
                "1x1,1x1,1x1",
            ]
            if case["restart"] is not None:
                argv.extend(["-restart", f"{case['restart']}B"])
            argv.extend(["-outfile", str(jpeg_path), str(source_path)])
            completed = run(argv)
            if completed.stderr.strip():
                raise CaptureError(
                    f"cjpeg emitted diagnostics for {case_id}: {completed.stderr.strip()}"
                )
            encoded = jpeg_path.read_bytes()
            coding_mode, parsed_width, parsed_height, factors = parse_sof(encoded)
            if (
                coding_mode != "baseline"
                or (parsed_width, parsed_height) != (width, height)
                or factors != [[1, 1], [1, 1], [1, 1]]
            ):
                raise CaptureError(f"generated baseline 4:4:4 SOF drifted: {case_id}")

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
                    "--independent-baseline-jpeg-444",
                    str(jpeg_path),
                    "--output",
                    str(imagecraft_path),
                ]
            )
            if imagecraft_completed.stderr.strip():
                raise CaptureError(
                    f"ImageCraft baseline 4:4:4 emitted diagnostics for {case_id}: "
                    f"{imagecraft_completed.stderr.strip()}"
                )
            report = parse_json_stdout(imagecraft_completed, f"ImageCraft baseline 4:4:4 {case_id}")
            imagecraft_rgb = imagecraft_path.read_bytes()
            if imagecraft_rgb != reference:
                mismatch = next(
                    (index, imagecraft_rgb[index], reference[index])
                    for index in range(min(len(imagecraft_rgb), len(reference)))
                    if imagecraft_rgb[index] != reference[index]
                )
                raise CaptureError(
                    f"ImageCraft baseline 4:4:4 differs from libjpeg: "
                    f"{case_id} mismatch={mismatch}"
                )
            expected_charge = width * height * 3 + 704
            expected_mcus = (width // 8 + (0 if width % 8 == 0 else 1)) * (
                height // 8 + (0 if height % 8 == 0 else 1)
            )
            if (
                report.get("evidenceVersion") != "imagecraft-independent-baseline-jpeg-444-v1"
                or report.get("outputSHA256") != sha256_bytes(imagecraft_rgb)
                or report.get("fixedScratchByteCount") != 704
                or report.get("operationByteCharge") != expected_charge
                or report.get("decodedMCUCount") != expected_mcus
                or report.get("thresholdMinusOneRejectedBeforeDecodeAllocation") is not True
            ):
                raise CaptureError(f"baseline 4:4:4 evidence drifted: {case_id}")
            if case["restart"] is not None and report.get("restartIntervalMCUs") != case["restart"]:
                raise CaptureError(f"baseline 4:4:4 restart report drifted: {case_id}")

            results.append(
                {
                    **case,
                    "sourcePPMSHA256": sha256_bytes(source),
                    "jpegByteCount": len(encoded),
                    "jpegSHA256": sha256_bytes(encoded),
                    "referenceRGBSHA256": sha256_bytes(reference),
                    "imageCraftRGBSHA256": sha256_bytes(imagecraft_rgb),
                    "imageCraftEvidence": report,
                    "exactLibjpegRGB": True,
                }
            )

        after = capture_source_identity(temp / "source-after.json")
        before_hash = before.get("sourceIdentitySHA256")
        if not before_hash or before_hash != after.get("sourceIdentitySHA256"):
            raise CaptureError("ImageCraft source identity changed during baseline 4:4:4 capture")

        report = {
            "schemaVersion": 1,
            "evidenceVersion": "imagecraft-independent-baseline-jpeg-444-conformance-v1",
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
            "cases": results,
            "summary": {
                "caseCount": len(results),
                "allExactLibjpegRGB": all(case["exactLibjpegRGB"] for case in results),
                "allThresholdMinusOneRejected": all(
                    case["imageCraftEvidence"]["thresholdMinusOneRejectedBeforeDecodeAllocation"]
                    for case in results
                ),
                "fixedScratchByteCount": 704,
                "restartCaseCount": sum(1 for case in results if case["restart"] is not None),
                "maximumOperationByteCharge": max(
                    int(case["imageCraftEvidence"]["operationByteCharge"])
                    for case in results
                ),
            },
        }
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(
            "independent baseline JPEG 4:4:4 captured: "
            f"cases={len(results)} source={before_hash} output={output_path}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
