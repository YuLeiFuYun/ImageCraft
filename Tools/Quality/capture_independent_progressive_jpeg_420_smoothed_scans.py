#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
import platform
import tempfile
from typing import Any

from capture_jpeg_ycbcr_to_rgb_conformance import parse_sof, write_ppm
from capture_libjpeg_progressive_suspension import (
    CaptureError,
    ROOT,
    build_imagecraft_evidence,
    build_probe,
    capture_source_identity,
    parse_json_stdout,
    run,
    sha256_bytes,
    sha256_file,
    structural_scans,
)


DEFAULT_PROFILE = ROOT / "Evidence/Experiments/IndependentProgressiveJPEG420SmoothedScans/v1/profile.json"
DEFAULT_OUTPUT = ROOT / ".artifacts/program/T101/independent-progressive-jpeg-420-smoothed-scans-v1.json"
PROBE_SOURCE = ROOT / "Tools/Quality/LibJPEGTurboSuspendingProgressiveProbe/main.c"


def validate_scan_pair(
    *,
    case_id: str,
    scan_number: int,
    imagecraft_path: Path,
    libjpeg_path: Path,
    expected_byte_count: int,
) -> dict[str, Any]:
    imagecraft = imagecraft_path.read_bytes()
    libjpeg = libjpeg_path.read_bytes()
    if len(imagecraft) != expected_byte_count or len(libjpeg) != expected_byte_count:
        raise CaptureError(
            f"scan byte count drifted: {case_id}/scan-{scan_number}: "
            f"ImageCraft={len(imagecraft)} libjpeg={len(libjpeg)} expected={expected_byte_count}"
        )
    if imagecraft != libjpeg:
        mismatch = next(
            (index, imagecraft[index], libjpeg[index])
            for index in range(expected_byte_count)
            if imagecraft[index] != libjpeg[index]
        )
        pixel = mismatch[0] // 3
        raise CaptureError(
            f"per-scan RGB differs from default-previews libjpeg: {case_id}/scan-{scan_number} "
            f"mismatch={mismatch} pixel={pixel} channel={mismatch[0] % 3}"
        )
    return {
        "scanNumber": scan_number,
        "byteCount": expected_byte_count,
        "sha256": sha256_bytes(imagecraft),
        "exactDefaultBlockSmoothingLibjpegRGB": True,
    }


def validate_case(
    *,
    case_id: str,
    jpeg_path: Path,
    width: int,
    height: int,
    expected_scan_count: int,
    imagecraft: Path,
    probe: Path,
    temp: Path,
) -> dict[str, Any]:
    encoded = jpeg_path.read_bytes()
    scans = structural_scans(encoded)
    if len(scans) != expected_scan_count:
        raise CaptureError(
            f"structural scan count drifted: {case_id}: "
            f"expected={expected_scan_count} actual={len(scans)}"
        )
    output_bytes = width * height * 3

    imagecraft_dir = temp / f"{case_id}.imagecraft-scans"
    completed = run(
        [
            str(imagecraft),
            "--independent-progressive-jpeg-420-smoothed-scans",
            str(jpeg_path),
            "--output-directory",
            str(imagecraft_dir),
        ]
    )
    if completed.stderr.strip():
        raise CaptureError(
            f"ImageCraft scan evidence emitted diagnostics for {case_id}: "
            f"{completed.stderr.strip()}"
        )
    imagecraft_report = parse_json_stdout(completed, f"ImageCraft scan evidence {case_id}")
    if (
        imagecraft_report.get("evidenceVersion")
        != "imagecraft-independent-progressive-jpeg-420-smoothed-scans-v1"
        or imagecraft_report.get("width") != width
        or imagecraft_report.get("height") != height
        or imagecraft_report.get("scanCount") != expected_scan_count
        or imagecraft_report.get("outputBackingReusedAcrossScans") is not True
    ):
        raise CaptureError(f"ImageCraft scan evidence drifted: {case_id}")
    reported_generations = imagecraft_report.get("generations")
    if not isinstance(reported_generations, list) or len(reported_generations) != expected_scan_count:
        raise CaptureError(f"ImageCraft scan generation count drifted: {case_id}")

    prefix = temp / f"{case_id}.libjpeg-nosmoothing"
    probe_completed = run(
        [
            str(probe),
            str(jpeg_path),
            str(max(1, len(encoded))),
            str(prefix),
            "500",
            "0",
            "default-previews",
        ]
    )
    if probe_completed.stderr.strip():
        raise CaptureError(
            f"libjpeg default-previews scan probe emitted diagnostics for {case_id}: "
            f"{probe_completed.stderr.strip()}"
        )
    probe_report = parse_json_stdout(probe_completed, f"libjpeg default-previews scans {case_id}")
    if (
        probe_report.get("decodeMode") != "default-previews"
        or probe_report.get("warningCount") != 0
        or probe_report.get("scanCompletedEventCount") != expected_scan_count
        or probe_report.get("finalScanNumber") != expected_scan_count
        or probe_report.get("width") != width
        or probe_report.get("height") != height
    ):
        raise CaptureError(f"libjpeg default-previews scan report drifted: {case_id}")

    generation_results: list[dict[str, Any]] = []
    for scan_number in range(1, expected_scan_count + 1):
        imagecraft_scan = imagecraft_dir / f"scan-{scan_number:03d}.rgb"
        libjpeg_scan = Path(f"{prefix}-scan-{scan_number:03d}.rgb")
        if not imagecraft_scan.is_file() or not libjpeg_scan.is_file():
            raise CaptureError(f"missing scan artifact: {case_id}/scan-{scan_number}")
        result = validate_scan_pair(
            case_id=case_id,
            scan_number=scan_number,
            imagecraft_path=imagecraft_scan,
            libjpeg_path=libjpeg_scan,
            expected_byte_count=output_bytes,
        )
        reported = reported_generations[scan_number - 1]
        if (
            not isinstance(reported, dict)
            or reported.get("scanNumber") != scan_number
            or reported.get("byteCount") != output_bytes
            or reported.get("sha256") != result["sha256"]
        ):
            raise CaptureError(f"ImageCraft generation manifest drifted: {case_id}/scan-{scan_number}")
        generation_results.append(result)

    if generation_results[-1]["sha256"] != imagecraft_report.get("finalOutputSHA256"):
        raise CaptureError(f"final scan does not equal final decoder output: {case_id}")
    # Scan rasters are evidence-harness temporaries, not retained report payload. Remove each
    # full-frame copy immediately so the real-photo matrix cannot accidentally turn into a
    # hundreds-of-megabytes temp live set and obscure the decoder resource model being measured.
    for scan_number in range(1, expected_scan_count + 1):
        (imagecraft_dir / f"scan-{scan_number:03d}.rgb").unlink()
        Path(f"{prefix}-scan-{scan_number:03d}.rgb").unlink()
    imagecraft_dir.rmdir()
    final_probe_output = Path(f"{prefix}-final.rgb")
    if final_probe_output.is_file():
        final_probe_output.unlink()
    return {
        "inputByteCount": len(encoded),
        "inputSHA256": sha256_bytes(encoded),
        "scanCount": expected_scan_count,
        "imageCraftOperationByteCharge": imagecraft_report.get("operationByteCharge"),
        "outputBackingReusedAcrossScans": True,
        "libjpegProbe": {
            "implementation": probe_report.get("implementation"),
            "decodeMode": probe_report.get("decodeMode"),
            "warningCount": probe_report.get("warningCount"),
        },
        "generations": generation_results,
        "allScansExactDefaultBlockSmoothingLibjpegRGB": True,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, default=DEFAULT_PROFILE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    profile_path = args.profile if args.profile.is_absolute() else ROOT / args.profile
    output_path = args.output if args.output.is_absolute() else ROOT / args.output
    profile = json.loads(profile_path.read_text())
    if profile.get("profileID") != "IMAGECRAFT-INDEPENDENT-PROGRESSIVE-JPEG-420-SMOOTHED-SCANS-V1":
        raise CaptureError("unexpected progressive JPEG 4:2:0 scan profile ID")

    with tempfile.TemporaryDirectory(prefix="imagecraft-progressive-420-scans-") as temp_raw:
        temp = Path(temp_raw)
        before = capture_source_identity(temp / "source-before.json")
        jpeg_prefix = Path(run(["brew", "--prefix", "jpeg-turbo"]).stdout.strip())
        cjpeg = jpeg_prefix / "bin/cjpeg"
        cjpeg_version = run([str(cjpeg), "-version"]).stderr.strip()
        required = profile.get("requiredLibJPEGTurboVersionPrefix")
        if not isinstance(required, str) or not cjpeg_version.startswith(required):
            raise CaptureError("jpeg-turbo runtime is outside per-scan qualification")
        imagecraft = build_imagecraft_evidence()
        probe = build_probe(temp, jpeg_prefix)

        results: list[dict[str, Any]] = []
        for case in profile["generatedCases"]:
            case_id = str(case["id"])
            width = int(case["width"])
            height = int(case["height"])
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
            if case.get("restart") is not None:
                argv.extend(["-restart", f"{int(case['restart'])}B"])
            argv.extend(["-outfile", str(jpeg_path), str(source_path)])
            encoded_completed = run(argv)
            if encoded_completed.stderr.strip():
                raise CaptureError(
                    f"cjpeg emitted diagnostics for {case_id}: {encoded_completed.stderr.strip()}"
                )
            coding_mode, parsed_width, parsed_height, factors = parse_sof(jpeg_path.read_bytes())
            if (
                coding_mode != "progressive"
                or (parsed_width, parsed_height) != (width, height)
                or factors != [[2, 2], [1, 1], [1, 1]]
            ):
                raise CaptureError(f"generated progressive 4:2:0 SOF drifted: {case_id}")
            expected_scan_count = int(profile["expectedDefaultSimpleProgressionScanCount"])
            result = validate_case(
                case_id=case_id,
                jpeg_path=jpeg_path,
                width=width,
                height=height,
                expected_scan_count=expected_scan_count,
                imagecraft=imagecraft,
                probe=probe,
                temp=temp,
            )
            results.append(
                {
                    **case,
                    "retained": False,
                    "sourcePPMSHA256": sha256_bytes(source),
                    **result,
                }
            )

        for case in profile["retainedCases"]:
            case_id = str(case["id"])
            jpeg_path = ROOT / str(case["file"])
            encoded = jpeg_path.read_bytes()
            if sha256_bytes(encoded) != case["sha256"]:
                raise CaptureError(f"retained progressive JPEG SHA drifted: {case_id}")
            result = validate_case(
                case_id=case_id,
                jpeg_path=jpeg_path,
                width=int(case["width"]),
                height=int(case["height"]),
                expected_scan_count=int(case["scanCount"]),
                imagecraft=imagecraft,
                probe=probe,
                temp=temp,
            )
            results.append({**case, "retained": True, **result})

        after = capture_source_identity(temp / "source-after.json")
        before_hash = before.get("sourceIdentitySHA256")
        if not before_hash or before_hash != after.get("sourceIdentitySHA256"):
            raise CaptureError("ImageCraft source identity changed during per-scan capture")

        scan_total = sum(int(case["scanCount"]) for case in results)
        report = {
            "schemaVersion": 1,
            "evidenceVersion": "imagecraft-independent-progressive-jpeg-420-smoothed-scans-conformance-v1",
            "status": "source-bound-package-backend-smoothed-scan-conformance",
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
                "cjpegSHA256": sha256_file(cjpeg),
                "imageCraftEvidenceSHA256": sha256_file(imagecraft),
                "probeSHA256": sha256_file(probe),
                "probeSourceSHA256": sha256_file(PROBE_SOURCE),
            },
            "claimBoundary": profile["claimBoundary"],
            "cases": results,
            "summary": {
                "caseCount": len(results),
                "generatedCaseCount": len(profile["generatedCases"]),
                "retainedCaseCount": len(profile["retainedCases"]),
                "scanGenerationCount": scan_total,
                "allScansExactDefaultBlockSmoothingLibjpegRGB": all(
                    case["allScansExactDefaultBlockSmoothingLibjpegRGB"] for case in results
                ),
                "allOutputBackingReusedAcrossScans": all(
                    case["outputBackingReusedAcrossScans"] for case in results
                ),
                "maximumOperationByteCharge": max(
                    int(case["imageCraftOperationByteCharge"]) for case in results
                ),
            },
        }
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(
            "independent progressive JPEG 4:2:0 smoothed per-scan conformance captured: "
            f"cases={len(results)} scans={scan_total} source={before_hash} output={output_path}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
