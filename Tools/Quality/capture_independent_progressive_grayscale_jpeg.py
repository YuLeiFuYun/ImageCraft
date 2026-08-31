#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
import platform
import tempfile
from typing import Any

from capture_independent_baseline_grayscale_jpeg import parse_pgm, write_pgm
from capture_libjpeg_progressive_suspension import (
    build_imagecraft_evidence,
    CaptureError,
    ROOT,
    capture_source_identity,
    parse_json_stdout,
    run,
    sha256_bytes,
    sha256_file,
    structural_scans,
)
from capture_progressive_jpeg_imcu_chroma_context import build_c_tool


DEFAULT_PROFILE = (
    ROOT / "Evidence/Experiments/IndependentProgressiveGrayscaleJPEG/v1/profile.json"
)
DEFAULT_OUTPUT = (
    ROOT / ".artifacts/program/T101/independent-progressive-grayscale-jpeg-v1.json"
)
COEFFICIENT_PROBE_SOURCE = (
    ROOT / "Tools/Quality/LibJPEGTurboGrayscaleCoefficientPlaneProbe/main.c"
)


def generated_cases(profile: dict[str, Any]) -> list[dict[str, Any]]:
    cases: list[dict[str, Any]] = []
    for raw_width, raw_height in profile["geometryCases"]:
        width, height = int(raw_width), int(raw_height)
        cases.append(
            {
                "id": f"geometry-{width}x{height}-q75",
                "width": width,
                "height": height,
                "pattern": "deterministic-noise",
                "quality": 75,
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
                }
            )
    return cases


def custom_scan_cases(profile: dict[str, Any]) -> list[dict[str, Any]]:
    cases: list[dict[str, Any]] = []
    probes = [
        (17, 13, "deterministic-noise", 25),
        (31, 19, "checker", 75),
        (64, 17, "deterministic-noise", 100),
    ]
    for script in profile["customScanScripts"]:
        for width, height, pattern, quality in probes:
            cases.append(
                {
                    "id": f"custom-{script['id']}-{width}x{height}-q{quality}",
                    "width": width,
                    "height": height,
                    "pattern": pattern,
                    "quality": quality,
                    "scanScriptID": str(script["id"]),
                    "scanScript": str(script["file"]),
                    "expectedScanCount": int(script["scanCount"]),
                }
            )
    return cases


def restart_cases(profile: dict[str, Any]) -> list[dict[str, Any]]:
    cases: list[dict[str, Any]] = []
    for interval in profile["restartIntervalsMCUs"]:
        for width, height in [(17, 13), (31, 19), (64, 17)]:
            cases.append(
                {
                    "id": f"restart-{interval}B-{width}x{height}",
                    "width": width,
                    "height": height,
                    "pattern": "deterministic-noise",
                    "quality": 75,
                    "restartIntervalMCUs": int(interval),
                    "expectedScanCount": int(
                        profile["expectedDefaultSimpleProgressionScanCount"]
                    ),
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
            "--independent-progressive-grayscale-jpeg",
            str(jpeg_path),
            "--output",
            str(raw_path),
        ]
    )
    if completed.stderr.strip():
        raise CaptureError(
            f"ImageCraft progressive grayscale emitted diagnostics for {label}: "
            f"{completed.stderr.strip()}"
        )
    report = parse_json_stdout(completed, f"ImageCraft progressive grayscale {label}")
    pixels = raw_path.read_bytes()
    if (
        report.get("evidenceVersion") != "imagecraft-independent-progressive-grayscale-jpeg-v1"
        or report.get("thresholdMinusOneRejectedBeforeStateAllocation") is not True
        or report.get("fixedStateByteCount") != 448
        or report.get("outputByteCount") != len(pixels)
        or report.get("outputSHA256") != sha256_bytes(pixels)
    ):
        raise CaptureError(f"ImageCraft progressive grayscale evidence drifted: {label}")
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
    if profile.get("profileID") != "IMAGECRAFT-INDEPENDENT-PROGRESSIVE-GRAYSCALE-JPEG-V1":
        raise CaptureError("unexpected independent progressive grayscale profile ID")
    expected_scan_count = int(profile["expectedDefaultSimpleProgressionScanCount"])

    with tempfile.TemporaryDirectory(prefix="imagecraft-progressive-gray-") as temp_raw:
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
            raise CaptureError("jpeg-turbo runtime is outside progressive grayscale qualification")

        coefficient_probe = build_c_tool(
            temp,
            COEFFICIENT_PROBE_SOURCE,
            "grayscale-coefficient-plane-probe",
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

        default_cases = generated_cases(profile)
        custom_cases = custom_scan_cases(profile)
        restart_matrix = restart_cases(profile)
        results: list[dict[str, Any]] = []
        for case in default_cases + custom_cases + restart_matrix:
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
            scan_script = case.get("scanScript")
            if scan_script is not None:
                cjpeg_argv.extend(["-scans", str(ROOT / str(scan_script))])
            else:
                cjpeg_argv.append("-progressive")
            restart_interval = case.get("restartIntervalMCUs")
            if restart_interval is not None:
                cjpeg_argv.extend(["-restart", f"{int(restart_interval)}B"])
            cjpeg_argv.extend(["-outfile", str(jpeg_path), str(source_path)])
            encoded_completed = run(cjpeg_argv)
            if encoded_completed.stderr.strip():
                raise CaptureError(
                    f"cjpeg emitted diagnostics for {case_id}: {encoded_completed.stderr.strip()}"
                )
            encoded = jpeg_path.read_bytes()
            scans = structural_scans(encoded)
            case_scan_count = int(case.get("expectedScanCount", expected_scan_count))
            if len(scans) != case_scan_count:
                raise CaptureError(
                    f"progressive scan count drifted: {case_id}: "
                    f"expected={case_scan_count} actual={len(scans)}"
                )

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
                    f"ImageCraft progressive grayscale differs from libjpeg: "
                    f"{case_id} mismatch={mismatch}"
                )
            blocks_across = width // 8 + (0 if width % 8 == 0 else 1)
            blocks_down = height // 8 + (0 if height % 8 == 0 else 1)
            coefficient_bytes = blocks_across * blocks_down * 128
            expected_charge = width * height + coefficient_bytes + 448
            if (
                imagecraft_report.get("scanCount") != case_scan_count
                or imagecraft_report.get("coefficientStateByteCount") != coefficient_bytes
                or imagecraft_report.get("operationByteCharge") != expected_charge
            ):
                raise CaptureError(f"progressive resource/scan report drifted: {case_id}")

            libjpeg_coefficients_path = temp / f"{case_id}.libjpeg.coefficients.bin"
            coefficient_probe_completed = run(
                [str(coefficient_probe), str(jpeg_path), str(libjpeg_coefficients_path)]
            )
            if coefficient_probe_completed.stderr.strip():
                raise CaptureError(
                    f"libjpeg coefficient probe emitted diagnostics for {case_id}: "
                    f"{coefficient_probe_completed.stderr.strip()}"
                )
            coefficient_probe_report = parse_json_stdout(
                coefficient_probe_completed, f"libjpeg coefficient probe {case_id}"
            )
            libjpeg_coefficients = libjpeg_coefficients_path.read_bytes()

            imagecraft_coefficients_path = temp / f"{case_id}.imagecraft.coefficients.bin"
            coefficient_evidence_completed = run(
                [
                    str(imagecraft),
                    "--independent-progressive-grayscale-coefficients",
                    str(jpeg_path),
                    "--output",
                    str(imagecraft_coefficients_path),
                ]
            )
            if coefficient_evidence_completed.stderr.strip():
                raise CaptureError(
                    f"ImageCraft coefficient evidence emitted diagnostics for {case_id}: "
                    f"{coefficient_evidence_completed.stderr.strip()}"
                )
            coefficient_evidence_report = parse_json_stdout(
                coefficient_evidence_completed, f"ImageCraft coefficient evidence {case_id}"
            )
            imagecraft_coefficients = imagecraft_coefficients_path.read_bytes()
            if imagecraft_coefficients != libjpeg_coefficients:
                mismatch = next(
                    (
                        index,
                        imagecraft_coefficients[index],
                        libjpeg_coefficients[index],
                    )
                    for index in range(
                        min(len(imagecraft_coefficients), len(libjpeg_coefficients))
                    )
                    if imagecraft_coefficients[index] != libjpeg_coefficients[index]
                )
                raise CaptureError(
                    f"ImageCraft progressive coefficients differ from libjpeg: "
                    f"{case_id} mismatch={mismatch}"
                )
            if (
                len(imagecraft_coefficients) != coefficient_bytes
                or coefficient_probe_report.get("progressiveMode") is not True
                or coefficient_probe_report.get("coefficientByteCount") != coefficient_bytes
                or coefficient_evidence_report.get("coefficientByteCount") != coefficient_bytes
                or coefficient_evidence_report.get("scanCount") != case_scan_count
                or coefficient_evidence_report.get("coefficientSHA256")
                != sha256_bytes(imagecraft_coefficients)
                or coefficient_evidence_report.get("finalPixelSHA256")
                != sha256_bytes(imagecraft_pixels)
            ):
                raise CaptureError(f"progressive coefficient evidence drifted: {case_id}")
            results.append(
                {
                    **case,
                    "sourcePGMSHA256": sha256_bytes(source),
                    "jpegByteCount": len(encoded),
                    "jpegSHA256": sha256_bytes(encoded),
                    "scanCount": len(scans),
                    "referenceSHA256": sha256_bytes(reference),
                    "imageCraftSHA256": sha256_bytes(imagecraft_pixels),
                    "imageCraftEvidence": imagecraft_report,
                    "libjpegCoefficientProbe": coefficient_probe_report,
                    "imageCraftCoefficientEvidence": coefficient_evidence_report,
                    "coefficientSHA256": sha256_bytes(imagecraft_coefficients),
                    "exactLibjpegCoefficients": True,
                    "exactLibjpegISlow": True,
                }
            )

        after = capture_source_identity(temp / "source-after.json")
        before_hash = before.get("sourceIdentitySHA256")
        if not before_hash or before_hash != after.get("sourceIdentitySHA256"):
            raise CaptureError("ImageCraft source identity changed during progressive grayscale capture")

        report = {
            "schemaVersion": 1,
            "evidenceVersion": "imagecraft-independent-progressive-grayscale-jpeg-conformance-v1",
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
                "coefficientProbeSHA256": sha256_file(coefficient_probe),
                "coefficientProbeSourceSHA256": sha256_file(COEFFICIENT_PROBE_SOURCE),
            },
            "claimBoundary": profile["claimBoundary"],
            "cases": results,
            "summary": {
                "caseCount": len(results),
                "allExactLibjpegISlow": all(case["exactLibjpegISlow"] for case in results),
                "allExactLibjpegCoefficients": all(
                    case["exactLibjpegCoefficients"] for case in results
                ),
                "allScanCountsExact": all(
                    int(case["scanCount"])
                    == int(case.get("expectedScanCount", expected_scan_count))
                    for case in results
                ),
                "allThresholdMinusOneRejected": all(
                    case["imageCraftEvidence"][
                        "thresholdMinusOneRejectedBeforeStateAllocation"
                    ]
                    for case in results
                ),
                "fixedStateByteCount": 448,
                "defaultCaseCount": len(default_cases),
                "customScanCaseCount": len(custom_cases),
                "restartCaseCount": len(restart_matrix),
                "maximumCoefficientStateByteCount": max(
                    int(case["imageCraftEvidence"]["coefficientStateByteCount"])
                    for case in results
                ),
                "maximumOperationByteCharge": max(
                    int(case["imageCraftEvidence"]["operationByteCharge"])
                    for case in results
                ),
            },
        }
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(
            "independent progressive grayscale JPEG captured: "
            f"cases={len(results)} source={before_hash} output={output_path}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
