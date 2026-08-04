#!/usr/bin/env python3
from __future__ import annotations

import argparse
from collections import defaultdict
import json
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
BENCHMARK_VERSION = "imagecraft-progressive-timeline-v1"
EXPECTED_CASES = {
    "progressive-jpeg-timeline-fit-512-chunk-1024": 1_024,
    "progressive-jpeg-timeline-fit-512-chunk-32768": 32 * 1_024,
}


def percentile(values: list[int], numerator: int, denominator: int) -> int:
    ordered = sorted(values)
    rank = max(1, (len(ordered) * numerator + denominator - 1) // denominator)
    return ordered[min(len(ordered) - 1, rank - 1)]


def duration_statistics(values: list[int]) -> dict[str, int]:
    return {
        "minimumNanoseconds": min(values),
        "medianNanoseconds": percentile(values, 50, 100),
        "p90Nanoseconds": percentile(values, 90, 100),
        "maximumNanoseconds": max(values),
        "meanNanoseconds": sum(values) // len(values),
    }


def fraction_ppm(numerator: int, denominator: int) -> int:
    if numerator < 0 or denominator <= 0:
        raise AssertionError("invalid encoded byte fraction")
    return min(1_000_000, numerator * 1_000_000 // denominator)


def summarize(samples: list[dict[str, Any]], encoded_bytes: int) -> dict[str, Any]:
    if not samples:
        raise AssertionError("timeline samples are empty")
    generation_count = len(samples[0]["generations"])
    if generation_count < 2 or generation_count > 4:
        raise AssertionError("unexpected progressive generation count")
    if any(len(sample["generations"]) != generation_count for sample in samples):
        raise AssertionError("generation count changed across timeline samples")

    generations = []
    for index in range(generation_count):
        reference = samples[0]["generations"][index]
        generation = reference["generation"]
        source_bytes = reference["sourceByteCount"]
        elapsed = []
        for sample in samples:
            item = sample["generations"][index]
            if item["generation"] != generation or item["sourceByteCount"] != source_bytes:
                raise AssertionError("progressive generation identity changed")
            elapsed.append(item["elapsedNanoseconds"])
        generations.append(
            {
                "generation": generation,
                "sourceByteCount": source_bytes,
                "encodedByteFractionPPM": fraction_ppm(source_bytes, encoded_bytes),
                "elapsed": duration_statistics(elapsed),
            }
        )

    first = generations[0]
    return {
        "generationCount": generation_count,
        "firstPreviewSourceByteCount": first["sourceByteCount"],
        "firstPreviewEncodedByteFractionPPM": first["encodedByteFractionPPM"],
        "firstPreviewElapsed": first["elapsed"],
        "generations": generations,
        "finishElapsed": duration_statistics(
            [sample["finishElapsedNanoseconds"] for sample in samples]
        ),
        "totalElapsed": duration_statistics(
            [sample["totalElapsedNanoseconds"] for sample in samples]
        ),
    }


def validate_process_report(report: dict[str, Any], path: Path) -> None:
    if report.get("schemaVersion") != 1:
        raise AssertionError(f"{path}: unsupported schema")
    if report.get("benchmarkVersion") != BENCHMARK_VERSION:
        raise AssertionError(f"{path}: unexpected benchmark version")
    if report.get("buildConfiguration") != "release":
        raise AssertionError(f"{path}: non-Release report")
    case_id = report.get("caseID")
    if case_id not in EXPECTED_CASES:
        raise AssertionError(f"{path}: unexpected case")
    if report.get("chunkSizeBytes") != EXPECTED_CASES[case_id]:
        raise AssertionError(f"{path}: chunk size mismatch")
    if report.get("warmupIterations") != 2:
        raise AssertionError(f"{path}: warmup count mismatch")
    iterations = report.get("iterations")
    samples = report.get("samples")
    if not isinstance(iterations, int) or iterations <= 0:
        raise AssertionError(f"{path}: invalid iteration count")
    if not isinstance(samples, list) or len(samples) != iterations:
        raise AssertionError(f"{path}: sample count mismatch")
    source = report.get("source", {})
    encoded_bytes = source.get("encodedByteCount")
    if not isinstance(encoded_bytes, int) or encoded_bytes <= 0:
        raise AssertionError(f"{path}: missing encoded size")
    if not source.get("encodedSHA256") or not report.get("output"):
        raise AssertionError(f"{path}: incomplete source/output identity")

    for sample in samples:
        generations = sample.get("generations")
        if not isinstance(generations, list) or not generations:
            raise AssertionError(f"{path}: invalid generation samples")
        elapsed = [item["elapsedNanoseconds"] for item in generations]
        if elapsed != sorted(elapsed):
            raise AssertionError(f"{path}: non-monotone generation timeline")
        if sample["finishElapsedNanoseconds"] < elapsed[-1]:
            raise AssertionError(f"{path}: finish precedes final preview")
        if sample["totalElapsedNanoseconds"] < sample["finishElapsedNanoseconds"]:
            raise AssertionError(f"{path}: total precedes finish")

    if report.get("summary") != summarize(samples, encoded_bytes):
        raise AssertionError(f"{path}: summary is not reproducible")
    environment = report.get("environment", {})
    if environment.get("lowPowerModeEnabled"):
        raise AssertionError(f"{path}: low power mode enabled")
    if environment.get("thermalState") not in {"nominal", "fair"}:
        raise AssertionError(f"{path}: unsuitable thermal state")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--case-directory", type=Path, required=True)
    parser.add_argument("--swift-version", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--expected-process-repetitions", type=int, default=3)
    parser.add_argument("--expected-iterations", type=int, default=7)
    args = parser.parse_args()

    paths = sorted(args.case_directory.glob("*.json"))
    reports = []
    for path in paths:
        report = json.loads(path.read_text(encoding="utf-8"))
        validate_process_report(report, path)
        reports.append(report)
    if not reports:
        raise AssertionError("no progressive timeline reports")

    first = reports[0]
    stable_fields = ("runtime", "decoderFingerprint")
    stable_hardware = {
        field: first["environment"][field]
        for field in ("hardwareModel", "activeProcessorCount", "physicalMemoryBytes")
    }
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for report in reports:
        for field in stable_fields:
            if report[field] != first[field]:
                raise AssertionError(f"environment drifted at {field}")
        hardware = {
            field: report["environment"][field]
            for field in ("hardwareModel", "activeProcessorCount", "physicalMemoryBytes")
        }
        if hardware != stable_hardware:
            raise AssertionError("hardware changed across timeline reports")
        grouped[report["caseID"]].append(report)

    if set(grouped) != set(EXPECTED_CASES):
        raise AssertionError("timeline case set mismatch")

    cases = []
    for case_id in sorted(grouped):
        group = grouped[case_id]
        if len(group) != args.expected_process_repetitions:
            raise AssertionError(f"{case_id}: process repetition mismatch")
        reference = group[0]
        for report in group:
            if report["iterations"] != args.expected_iterations:
                raise AssertionError(f"{case_id}: iteration count mismatch")
            for field in (
                "chunkSizeBytes",
                "chunkCount",
                "source",
                "output",
                "warmupIterations",
            ):
                if report[field] != reference[field]:
                    raise AssertionError(f"{case_id}: identity drifted at {field}")
        samples = [sample for report in group for sample in report["samples"]]
        encoded_bytes = reference["source"]["encodedByteCount"]
        cases.append(
            {
                "caseID": case_id,
                "processRepetitions": len(group),
                "warmupIterationsPerProcess": reference["warmupIterations"],
                "iterationsPerProcess": reference["iterations"],
                "totalIterations": len(samples),
                "chunkSizeBytes": reference["chunkSizeBytes"],
                "chunkCount": reference["chunkCount"],
                "source": reference["source"],
                "output": reference["output"],
                "samples": samples,
                "summary": summarize(samples, encoded_bytes),
                "environment": {
                    "thermalStates": sorted(
                        {report["environment"]["thermalState"] for report in group}
                    ),
                    "lowPowerModeEnabled": any(
                        report["environment"]["lowPowerModeEnabled"] for report in group
                    ),
                },
            }
        )

    aggregate = {
        "schemaVersion": SCHEMA_VERSION,
        "benchmarkVersion": BENCHMARK_VERSION,
        "buildConfiguration": "release",
        "swiftVersion": args.swift_version,
        "runtime": first["runtime"],
        "decoderFingerprint": first["decoderFingerprint"],
        "hardware": stable_hardware,
        "cases": cases,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(aggregate, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
