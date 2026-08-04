#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
EVIDENCE_VERSION = "imagecraft-progressive-quality-v1"
EXPECTED_CASES = {
    "progressive-jpeg-quality-fit-512-chunk-1024": 1_024,
    "progressive-jpeg-quality-fit-512-chunk-32768": 32 * 1_024,
}


def rounded_ratio(value: int, multiplier: int, divisor: int) -> int:
    if divisor <= 0:
        raise AssertionError("invalid divisor")
    return value * multiplier // divisor


def validate_metrics(metrics: dict[str, Any], case_id: str, generation: int) -> None:
    count = metrics.get("channelCount")
    different = metrics.get("differentChannelCount")
    maximum = metrics.get("maximumAbsoluteError")
    absolute_sum = metrics.get("absoluteErrorSum")
    squared_sum = metrics.get("squaredErrorSum")
    if not isinstance(count, int) or count <= 0:
        raise AssertionError(f"{case_id} g{generation}: invalid channel count")
    if not isinstance(different, int) or not 0 <= different <= count:
        raise AssertionError(f"{case_id} g{generation}: invalid different count")
    if not isinstance(maximum, int) or not 0 <= maximum <= 255:
        raise AssertionError(f"{case_id} g{generation}: invalid maximum error")
    if not isinstance(absolute_sum, int) or absolute_sum < 0:
        raise AssertionError(f"{case_id} g{generation}: invalid absolute sum")
    if not isinstance(squared_sum, int) or squared_sum < 0:
        raise AssertionError(f"{case_id} g{generation}: invalid squared sum")
    expected_mae = rounded_ratio(absolute_sum, 1_000_000, count)
    expected_mse = rounded_ratio(squared_sum, 1_000_000, count)
    if metrics.get("meanAbsoluteErrorMicrounits") != expected_mae:
        raise AssertionError(f"{case_id} g{generation}: MAE fixed point mismatch")
    if metrics.get("meanSquaredErrorMicrounits") != expected_mse:
        raise AssertionError(f"{case_id} g{generation}: MSE fixed point mismatch")
    mse = squared_sum / count
    psnr = 999.0 if mse == 0 else 10.0 * math.log10((255.0 * 255.0) / mse)
    expected_psnr = round(psnr * 1_000_000)
    actual_psnr = metrics.get("psnrMicrodecibels")
    if not isinstance(actual_psnr, int) or abs(actual_psnr - expected_psnr) > 2:
        raise AssertionError(f"{case_id} g{generation}: PSNR mismatch")
    ppm_fields = [
        "absoluteErrorAtMost8PPM",
        "absoluteErrorAtMost16PPM",
        "absoluteErrorAtMost32PPM",
        "absoluteErrorAtMost64PPM",
    ]
    values = [metrics.get(field) for field in ppm_fields]
    if any(not isinstance(value, int) or not 0 <= value <= 1_000_000 for value in values):
        raise AssertionError(f"{case_id} g{generation}: invalid threshold PPM")
    if values != sorted(values):
        raise AssertionError(f"{case_id} g{generation}: threshold coverage is not monotone")


def validate_report(report: dict[str, Any], path: Path) -> None:
    if report.get("schemaVersion") != SCHEMA_VERSION:
        raise AssertionError(f"{path}: unsupported schema")
    if report.get("evidenceVersion") != EVIDENCE_VERSION:
        raise AssertionError(f"{path}: unexpected evidence version")
    if report.get("buildConfiguration") != "release":
        raise AssertionError(f"{path}: non-Release report")
    case_id = report.get("caseID")
    if case_id not in EXPECTED_CASES:
        raise AssertionError(f"{path}: unexpected case")
    if report.get("chunkSizeBytes") != EXPECTED_CASES[case_id]:
        raise AssertionError(f"{path}: chunk size mismatch")
    if not report.get("runtime") or not report.get("decoderFingerprint"):
        raise AssertionError(f"{path}: runtime identity missing")
    environment = report.get("environment", {})
    if environment.get("lowPowerModeEnabled"):
        raise AssertionError(f"{path}: low power mode enabled")
    if environment.get("thermalState") not in {"nominal", "fair"}:
        raise AssertionError(f"{path}: unsuitable thermal state")
    source = report.get("source", {})
    encoded_bytes = source.get("encodedByteCount")
    if not isinstance(encoded_bytes, int) or encoded_bytes <= 0:
        raise AssertionError(f"{path}: encoded byte identity missing")
    if not source.get("encodedSHA256") or not report.get("finalPixelRGBSHA256"):
        raise AssertionError(f"{path}: source/final pixel identity missing")
    output = report.get("output", {})
    if output.get("pixelWidth") != 512 or output.get("pixelHeight") != 341:
        raise AssertionError(f"{path}: unexpected output dimensions")
    generations = report.get("generations")
    if not isinstance(generations, list) or len(generations) != 4:
        raise AssertionError(f"{path}: expected four quality generations")
    if [item.get("generation") for item in generations] != [1, 2, 3, 4]:
        raise AssertionError(f"{path}: generation identity mismatch")
    source_counts = [item.get("sourceByteCount") for item in generations]
    if source_counts != sorted(source_counts) or len(set(source_counts)) != 4:
        raise AssertionError(f"{path}: generation source bytes are not strict")
    for item in generations:
        source_bytes = item.get("sourceByteCount")
        expected_fraction = source_bytes * 1_000_000 // encoded_bytes
        if item.get("encodedByteFractionPPM") != expected_fraction:
            raise AssertionError(f"{path}: encoded fraction mismatch")
        if not item.get("pixelRGBSHA256"):
            raise AssertionError(f"{path}: generation pixel identity missing")
        validate_metrics(item.get("metricsAgainstFinal", {}), case_id, item["generation"])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--case-directory", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    paths = sorted(args.case_directory.glob("*.json"))
    reports = []
    for path in paths:
        report = json.loads(path.read_text(encoding="utf-8"))
        validate_report(report, path)
        reports.append(report)
    if not reports:
        raise AssertionError("no progressive quality reports")
    by_id = {report["caseID"]: report for report in reports}
    if set(by_id) != set(EXPECTED_CASES) or len(by_id) != len(reports):
        raise AssertionError("progressive quality case set mismatch")

    first = reports[0]
    stable_fields = ("runtime", "decoderFingerprint", "source", "output", "finalPixelRGBSHA256")
    for report in reports[1:]:
        for field in stable_fields:
            if report[field] != first[field]:
                raise AssertionError(f"quality reports drifted at {field}")
        reference_hardware = {
            field: first["environment"][field]
            for field in ("hardwareModel", "activeProcessorCount", "physicalMemoryBytes")
        }
        current_hardware = {
            field: report["environment"][field]
            for field in ("hardwareModel", "activeProcessorCount", "physicalMemoryBytes")
        }
        if current_hardware != reference_hardware:
            raise AssertionError("quality report hardware changed")

    aggregate = {
        "schemaVersion": SCHEMA_VERSION,
        "evidenceVersion": EVIDENCE_VERSION,
        "buildConfiguration": "release",
        "runtime": first["runtime"],
        "decoderFingerprint": first["decoderFingerprint"],
        "hardware": {
            field: first["environment"][field]
            for field in ("hardwareModel", "activeProcessorCount", "physicalMemoryBytes")
        },
        "source": first["source"],
        "output": first["output"],
        "finalPixelRGBSHA256": first["finalPixelRGBSHA256"],
        "cases": [by_id[case_id] for case_id in sorted(by_id)],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(aggregate, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
