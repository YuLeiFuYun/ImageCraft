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
    structural_scans,
)
from capture_progressive_jpeg_imcu_chroma_context import build_c_tool


DEFAULT_PROFILE = ROOT / "Evidence/Experiments/IndependentProgressiveJPEG420/v1/profile.json"
DEFAULT_OUTPUT = ROOT / ".artifacts/program/T101/independent-progressive-jpeg-420-v1.json"
COEFFICIENT_PROBE_SOURCE = (
    ROOT / "Tools/Quality/LibJPEGTurboColorCoefficientPlaneProbe/main.c"
)


def align64(value: int) -> int:
    return (value + 63) // 64 * 64


def expected_state(width: int, height: int) -> dict[str, Any]:
    mcu_columns = (width + 15) // 16
    mcu_rows = (height + 15) // 16
    y_actual_width_blocks = (width + 7) // 8
    y_actual_height_blocks = (height + 7) // 8
    y_padded_width_blocks = mcu_columns * 2
    y_padded_height_blocks = mcu_rows * 2
    chroma_width = (width + 1) // 2
    chroma_height = (height + 1) // 2
    y_coefficient_bytes = y_padded_width_blocks * y_padded_height_blocks * 128
    chroma_coefficient_bytes = mcu_columns * mcu_rows * 128
    coefficient_state_bytes = y_coefficient_bytes + 2 * chroma_coefficient_bytes
    y_stride = align64(width)
    chroma_stride = align64(chroma_width)
    row_state_bytes = 19 * y_stride + 18 * chroma_stride
    total_state_bytes = coefficient_state_bytes + row_state_bytes + 3456
    return {
        "width": width,
        "height": height,
        "mcuColumns": mcu_columns,
        "mcuRows": mcu_rows,
        "yActualWidthBlocks": y_actual_width_blocks,
        "yActualHeightBlocks": y_actual_height_blocks,
        "yPaddedWidthBlocks": y_padded_width_blocks,
        "yPaddedHeightBlocks": y_padded_height_blocks,
        "chromaWidth": chroma_width,
        "chromaHeight": chroma_height,
        "chromaWidthBlocks": mcu_columns,
        "chromaHeightBlocks": mcu_rows,
        "yCoefficientBytes": y_coefficient_bytes,
        "chromaCoefficientBytesPerComponent": chroma_coefficient_bytes,
        "coefficientStateBytes": coefficient_state_bytes,
        "yRowStrideBytes": y_stride,
        "chromaRowStrideBytes": chroma_stride,
        "rowStateBytes": row_state_bytes,
        "totalStateBytes": total_state_bytes,
        "usesFancyGlobalContext": chroma_width > 2,
    }


def generated_cases(profile: dict[str, Any]) -> list[dict[str, Any]]:
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
                "expectedScanCount": int(profile["expectedDefaultSimpleProgressionScanCount"]),
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
                    "expectedScanCount": int(profile["expectedDefaultSimpleProgressionScanCount"]),
                }
            )
    for interval in profile["restartIntervalsMCUs"]:
        for width, height in [(17, 17), (31, 19), (64, 33)]:
            result.append(
                {
                    "id": f"restart-{interval}B-{width}x{height}",
                    "width": width,
                    "height": height,
                    "pattern": "deterministic-noise",
                    "quality": 75,
                    "restart": int(interval),
                    "expectedScanCount": int(profile["expectedDefaultSimpleProgressionScanCount"]),
                }
            )
    return result


def run_imagecraft(
    executable: Path,
    jpeg_path: Path,
    rgb_path: Path,
    coefficient_path: Path,
    label: str,
) -> tuple[dict[str, Any], bytes, bytes]:
    completed = run(
        [
            str(executable),
            "--independent-progressive-jpeg-420",
            str(jpeg_path),
            "--output",
            str(rgb_path),
            "--coefficients-output",
            str(coefficient_path),
        ]
    )
    if completed.stderr.strip():
        raise CaptureError(
            f"ImageCraft progressive 4:2:0 emitted diagnostics for {label}: "
            f"{completed.stderr.strip()}"
        )
    report = parse_json_stdout(completed, f"ImageCraft progressive 4:2:0 {label}")
    rgb = rgb_path.read_bytes()
    coefficients = coefficient_path.read_bytes()
    if (
        report.get("evidenceVersion") != "imagecraft-independent-progressive-jpeg-420-v1"
        or report.get("thresholdMinusOneRejectedBeforeStateAllocation") is not True
        or report.get("outputByteCount") != len(rgb)
        or report.get("outputSHA256") != sha256_bytes(rgb)
        or report.get("coefficientByteCount") != len(coefficients)
        or report.get("coefficientSHA256") != sha256_bytes(coefficients)
    ):
        raise CaptureError(f"ImageCraft progressive 4:2:0 evidence drifted: {label}")
    return report, rgb, coefficients


def validate_one(
    *,
    label: str,
    jpeg_path: Path,
    width: int,
    height: int,
    expected_scan_count: int,
    imagecraft: Path,
    djpeg: Path,
    coefficient_probe: Path,
    temp: Path,
) -> tuple[dict[str, Any], bytes, bytes, dict[str, Any]]:
    encoded = jpeg_path.read_bytes()
    scans = structural_scans(encoded)
    if len(scans) != expected_scan_count:
        raise CaptureError(
            f"progressive scan count drifted: {label}: "
            f"expected={expected_scan_count} actual={len(scans)}"
        )

    reference_path = temp / f"{label}.reference.ppm"
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
            f"djpeg emitted diagnostics for {label}: {reference_completed.stderr.strip()}"
        )
    reference = parse_ppm(reference_path, width, height)

    imagecraft_report, imagecraft_rgb, imagecraft_coefficients = run_imagecraft(
        imagecraft,
        jpeg_path,
        temp / f"{label}.imagecraft.rgb",
        temp / f"{label}.imagecraft.coefficients.bin",
        label,
    )
    if imagecraft_rgb != reference:
        mismatch = next(
            (index, imagecraft_rgb[index], reference[index])
            for index in range(min(len(imagecraft_rgb), len(reference)))
            if imagecraft_rgb[index] != reference[index]
        )
        pixel = mismatch[0] // 3
        raise CaptureError(
            f"ImageCraft progressive 4:2:0 RGB differs from libjpeg: {label} "
            f"mismatch={mismatch} pixel=(x={pixel % width},y={pixel // width},c={mismatch[0] % 3})"
        )

    libjpeg_coefficients_path = temp / f"{label}.libjpeg.coefficients.bin"
    coefficient_completed = run(
        [str(coefficient_probe), str(jpeg_path), str(libjpeg_coefficients_path)]
    )
    if coefficient_completed.stderr.strip():
        raise CaptureError(
            f"libjpeg coefficient probe emitted diagnostics for {label}: "
            f"{coefficient_completed.stderr.strip()}"
        )
    coefficient_report = parse_json_stdout(
        coefficient_completed, f"libjpeg progressive coefficient probe {label}"
    )
    libjpeg_coefficients = libjpeg_coefficients_path.read_bytes()
    if imagecraft_coefficients != libjpeg_coefficients:
        mismatch = next(
            (index, imagecraft_coefficients[index], libjpeg_coefficients[index])
            for index in range(min(len(imagecraft_coefficients), len(libjpeg_coefficients)))
            if imagecraft_coefficients[index] != libjpeg_coefficients[index]
        )
        raise CaptureError(
            f"ImageCraft progressive coefficients differ from libjpeg: {label} mismatch={mismatch}"
        )

    state = expected_state(width, height)
    expected_charge = width * height * 3 + int(state["totalStateBytes"])
    report_state = imagecraft_report.get("statePlan")
    if (
        imagecraft_report.get("scanCount") != expected_scan_count
        or imagecraft_report.get("operationByteCharge") != expected_charge
        or not isinstance(report_state, dict)
        or any(report_state.get(key) != value for key, value in state.items())
        or coefficient_report.get("progressiveMode") is not True
        or coefficient_report.get("coefficientByteCount") != state["coefficientStateBytes"]
        or len(imagecraft_coefficients) != state["coefficientStateBytes"]
    ):
        raise CaptureError(f"progressive 4:2:0 state/oracle report drifted: {label}")
    return imagecraft_report, imagecraft_rgb, imagecraft_coefficients, coefficient_report


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, default=DEFAULT_PROFILE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    profile_path = args.profile if args.profile.is_absolute() else ROOT / args.profile
    output_path = args.output if args.output.is_absolute() else ROOT / args.output
    profile = json.loads(profile_path.read_text())
    if profile.get("profileID") != "IMAGECRAFT-INDEPENDENT-PROGRESSIVE-JPEG-420-V1":
        raise CaptureError("unexpected progressive JPEG 4:2:0 profile ID")

    with tempfile.TemporaryDirectory(prefix="imagecraft-progressive-420-") as temp_raw:
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
            raise CaptureError("jpeg-turbo runtime is outside progressive 4:2:0 qualification")

        coefficient_probe = build_c_tool(
            temp,
            COEFFICIENT_PROBE_SOURCE,
            "color-coefficient-plane-probe",
            jpeg_prefix,
        )
        build = run(
            ["swift", "build", "-c", "release", "--product", "ImageCraftEvidence", "--jobs", "1"],
            cwd=ROOT,
        )
        if "Build complete!" not in build.stdout:
            raise CaptureError("ImageCraftEvidence release build did not report completion")
        imagecraft = build_imagecraft_evidence()
        if not imagecraft.is_file():
            raise CaptureError("ImageCraftEvidence release binary is unavailable")

        results: list[dict[str, Any]] = []
        generated = generated_cases(profile)
        for case in generated:
            case_id = str(case["id"])
            width, height = int(case["width"]), int(case["height"])
            source_path = temp / f"{case_id}.ppm"
            source = write_ppm(source_path, width, height, str(case["pattern"]))
            jpeg_path = temp / f"{case_id}.jpg"
            argv = [
                str(cjpeg),
                "-quality", str(case["quality"]),
                "-dct", "int",
                "-optimize",
                "-sample", "2x2,1x1,1x1",
                "-progressive",
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
                coding_mode != "progressive"
                or (parsed_width, parsed_height) != (width, height)
                or factors != [[2, 2], [1, 1], [1, 1]]
            ):
                raise CaptureError(f"generated progressive 4:2:0 SOF drifted: {case_id}")
            ic_report, ic_rgb, ic_coeff, coeff_report = validate_one(
                label=case_id,
                jpeg_path=jpeg_path,
                width=width,
                height=height,
                expected_scan_count=int(case["expectedScanCount"]),
                imagecraft=imagecraft,
                djpeg=djpeg,
                coefficient_probe=coefficient_probe,
                temp=temp,
            )
            results.append(
                {
                    **case,
                    "sourcePPMSHA256": sha256_bytes(source),
                    "jpegByteCount": len(encoded),
                    "jpegSHA256": sha256_bytes(encoded),
                    "imageCraftRGBSHA256": sha256_bytes(ic_rgb),
                    "coefficientSHA256": sha256_bytes(ic_coeff),
                    "imageCraftEvidence": ic_report,
                    "libjpegCoefficientProbe": coeff_report,
                    "exactLibjpegRGB": True,
                    "exactLibjpegCoefficients": True,
                    "retained": False,
                }
            )

        for raw_case in profile["retainedCases"]:
            case_id = str(raw_case["id"])
            jpeg_path = ROOT / str(raw_case["file"])
            encoded = jpeg_path.read_bytes()
            if sha256_bytes(encoded) != raw_case["sha256"]:
                raise CaptureError(f"retained progressive JPEG SHA drifted: {case_id}")
            width, height = int(raw_case["width"]), int(raw_case["height"])
            ic_report, ic_rgb, ic_coeff, coeff_report = validate_one(
                label=case_id,
                jpeg_path=jpeg_path,
                width=width,
                height=height,
                expected_scan_count=int(raw_case["scanCount"]),
                imagecraft=imagecraft,
                djpeg=djpeg,
                coefficient_probe=coefficient_probe,
                temp=temp,
            )
            results.append(
                {
                    **raw_case,
                    "jpegByteCount": len(encoded),
                    "jpegSHA256": sha256_bytes(encoded),
                    "imageCraftRGBSHA256": sha256_bytes(ic_rgb),
                    "coefficientSHA256": sha256_bytes(ic_coeff),
                    "imageCraftEvidence": ic_report,
                    "libjpegCoefficientProbe": coeff_report,
                    "exactLibjpegRGB": True,
                    "exactLibjpegCoefficients": True,
                    "retained": True,
                }
            )

        after = capture_source_identity(temp / "source-after.json")
        before_hash = before.get("sourceIdentitySHA256")
        if not before_hash or before_hash != after.get("sourceIdentitySHA256"):
            raise CaptureError("ImageCraft source identity changed during progressive 4:2:0 capture")

        report = {
            "schemaVersion": 1,
            "evidenceVersion": "imagecraft-independent-progressive-jpeg-420-conformance-v1",
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
                "generatedCaseCount": len(generated),
                "retainedCaseCount": len(profile["retainedCases"]),
                "allExactLibjpegRGB": all(case["exactLibjpegRGB"] for case in results),
                "allExactLibjpegCoefficients": all(
                    case["exactLibjpegCoefficients"] for case in results
                ),
                "allThresholdMinusOneRejected": all(
                    case["imageCraftEvidence"]["thresholdMinusOneRejectedBeforeStateAllocation"]
                    for case in results
                ),
                "maximumCoefficientStateByteCount": max(
                    int(case["imageCraftEvidence"]["statePlan"]["coefficientStateBytes"])
                    for case in results
                ),
                "maximumStateByteCount": max(
                    int(case["imageCraftEvidence"]["statePlan"]["totalStateBytes"])
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
            "independent progressive JPEG 4:2:0 captured: "
            f"cases={len(results)} source={before_hash} output={output_path}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
