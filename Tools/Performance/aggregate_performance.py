#!/usr/bin/env python3
import argparse
from collections import defaultdict
import json
from pathlib import Path

SCHEMA_VERSION = 1
EXPECTED_CASES = {
    "decode-jpeg-full",
    "decode-jpeg-fit-512",
    "decode-jpeg-fit-1024",
    "decode-jpeg-fill-1024",
    "probe-then-decode-jpeg-fit-512",
    "prepare-then-decode-jpeg-fit-512",
    "encode-png",
    "encode-jpeg-q75",
}


def percentile(sorted_values: list[int], numerator: int, denominator: int) -> int:
    rank = max(1, (len(sorted_values) * numerator + denominator - 1) // denominator)
    return sorted_values[min(len(sorted_values) - 1, rank - 1)]


def duration_statistics(samples: list[int]) -> dict:
    ordered = sorted(samples)
    return {
        "minimumNanoseconds": ordered[0],
        "medianNanoseconds": percentile(ordered, 50, 100),
        "p90Nanoseconds": percentile(ordered, 90, 100),
        "maximumNanoseconds": ordered[-1],
        "meanNanoseconds": sum(samples) // len(samples),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--case-directory", type=Path, required=True)
    parser.add_argument("--swift-version", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--expected-case", action="append", default=[])
    args = parser.parse_args()

    reports = [
        json.loads(path.read_text(encoding="utf-8"))
        for path in sorted(args.case_directory.glob("*.json"))
    ]
    if not reports:
        raise AssertionError("no performance case reports")

    first = reports[0]
    stable_environment = {
        key: first["environment"][key]
        for key in ("hardwareModel", "activeProcessorCount", "physicalMemoryBytes")
    }
    grouped: dict[str, list[dict]] = defaultdict(list)
    for report in reports:
        for field in (
            "schemaVersion",
            "benchmarkVersion",
            "runtime",
            "decoderFingerprint",
            "encoderFingerprint",
            "rssSampleIntervalMicroseconds",
        ):
            if report[field] != first[field]:
                raise AssertionError(f"inconsistent {field} across performance cases")
        current_stable = {
            key: report["environment"][key]
            for key in ("hardwareModel", "activeProcessorCount", "physicalMemoryBytes")
        }
        if current_stable != stable_environment:
            raise AssertionError("hardware environment changed across performance cases")
        if report["environment"]["lowPowerModeEnabled"]:
            raise AssertionError(f"low power mode enabled during {report['caseID']}")
        if report["environment"]["thermalState"] not in {"nominal", "fair"}:
            raise AssertionError(
                f"thermal state unsuitable during {report['caseID']}: "
                f"{report['environment']['thermalState']}"
            )
        if len(report["samplesNanoseconds"]) != report["iterations"]:
            raise AssertionError(f"sample count mismatch: {report['caseID']}")
        grouped[report["caseID"]].append(report)

    expected_cases = set(args.expected_case) if args.expected_case else EXPECTED_CASES
    if set(grouped) != expected_cases:
        raise AssertionError(
            f"performance case set mismatch: actual={sorted(grouped)} "
            f"expected={sorted(expected_cases)}"
        )

    cases = []
    for case_id, group in sorted(grouped.items()):
        reference = group[0]
        for report in group[1:]:
            for field in (
                "memoryIterations",
                "warmupIterations",
                "iterations",
                "source",
                "output",
            ):
                if report[field] != reference[field]:
                    raise AssertionError(f"inconsistent {field} for {case_id}")
            if (
                report["memory"].get("estimatedWorkingSetBytes")
                != reference["memory"].get("estimatedWorkingSetBytes")
            ):
                raise AssertionError(f"inconsistent resource estimate for {case_id}")

        samples = [
            sample
            for report in group
            for sample in report["samplesNanoseconds"]
        ]
        peak_deltas = sorted(
            report["memory"]["sampledPeakDeltaBytes"] for report in group
        )
        cases.append(
            {
                "caseID": case_id,
                "processRepetitions": len(group),
                "memoryIterationsPerProcess": reference["memoryIterations"],
                "warmupIterationsPerProcess": reference["warmupIterations"],
                "iterationsPerProcess": reference["iterations"],
                "totalIterations": len(samples),
                "source": reference["source"],
                "samplesNanoseconds": samples,
                "duration": duration_statistics(samples),
                "memory": {
                    "baselineResidentBytes": [
                        report["memory"]["baselineResidentBytes"] for report in group
                    ],
                    "sampledPeakResidentBytes": [
                        report["memory"]["sampledPeakResidentBytes"] for report in group
                    ],
                    "sampledPeakDeltaBytes": peak_deltas,
                    "medianSampledPeakDeltaBytes": percentile(peak_deltas, 50, 100),
                    "maximumSampledPeakDeltaBytes": peak_deltas[-1],
                    "estimatedWorkingSetBytes": reference["memory"].get(
                        "estimatedWorkingSetBytes"
                    ),
                },
                "environment": {
                    "thermalStates": sorted(
                        {report["environment"]["thermalState"] for report in group}
                    ),
                    "lowPowerModeEnabled": any(
                        report["environment"]["lowPowerModeEnabled"] for report in group
                    ),
                },
                "output": reference["output"],
            }
        )

    aggregate = {
        "schemaVersion": SCHEMA_VERSION,
        "benchmarkVersion": first["benchmarkVersion"],
        "buildConfiguration": "release",
        "swiftVersion": args.swift_version,
        "runtime": first["runtime"],
        "decoderFingerprint": first["decoderFingerprint"],
        "encoderFingerprint": first["encoderFingerprint"],
        "rssSampleIntervalMicroseconds": first["rssSampleIntervalMicroseconds"],
        "hardware": stable_environment,
        "cases": cases,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(aggregate, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
