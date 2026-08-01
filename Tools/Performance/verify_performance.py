#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    args = parser.parse_args()

    report = json.loads(args.report.read_text(encoding="utf-8"))
    baseline = json.loads(args.baseline.read_text(encoding="utf-8"))
    for field in (
        "schemaVersion",
        "benchmarkVersion",
        "buildConfiguration",
        "swiftVersion",
        "runtime",
        "decoderFingerprint",
        "encoderFingerprint",
        "rssSampleIntervalMicroseconds",
        "hardware",
    ):
        if report[field] != baseline[field]:
            raise AssertionError(f"performance baseline identity mismatch: {field}")

    current_by_id = {case["caseID"]: case for case in report["cases"]}
    baseline_by_id = {case["caseID"]: case for case in baseline["cases"]}
    if set(current_by_id) != set(baseline_by_id):
        raise AssertionError("performance case set differs from baseline")

    failures = []
    for case_id in sorted(baseline_by_id):
        current = current_by_id[case_id]
        expected = baseline_by_id[case_id]
        for field in (
            "processRepetitions",
            "iterationsPerProcess",
            "memoryIterationsPerProcess",
            "warmupIterationsPerProcess",
            "source",
            "output",
        ):
            if current[field] != expected[field]:
                failures.append(f"{case_id}: {field} changed")
        if current["environment"]["lowPowerModeEnabled"]:
            failures.append(f"{case_id}: low power mode enabled")
        if not set(current["environment"]["thermalStates"]).issubset({"nominal", "fair"}):
            failures.append(
                f"{case_id}: thermal states {current['environment']['thermalStates']}"
            )

        checks = (
            (
                "medianNanoseconds",
                current["duration"]["medianNanoseconds"],
                expected["budget"]["maximumMedianNanoseconds"],
            ),
            (
                "p90Nanoseconds",
                current["duration"]["p90Nanoseconds"],
                expected["budget"]["maximumP90Nanoseconds"],
            ),
            (
                "medianSampledPeakDeltaBytes",
                current["memory"]["medianSampledPeakDeltaBytes"],
                expected["budget"]["maximumMedianSampledPeakDeltaBytes"],
            ),
            (
                "maximumSampledPeakDeltaBytes",
                current["memory"]["maximumSampledPeakDeltaBytes"],
                expected["budget"]["maximumProcessSampledPeakDeltaBytes"],
            ),
        )
        for name, value, maximum in checks:
            if value > maximum:
                failures.append(f"{case_id}: {name}={value} exceeds {maximum}")

    if failures:
        raise AssertionError("performance regressions:\n" + "\n".join(failures))

    for case_id in sorted(current_by_id):
        case = current_by_id[case_id]
        print(
            f"{case_id}: median={case['duration']['medianNanoseconds']} ns, "
            f"p90={case['duration']['p90Nanoseconds']} ns, "
            f"median-peak-delta={case['memory']['medianSampledPeakDeltaBytes']} bytes, "
            f"max-peak-delta={case['memory']['maximumSampledPeakDeltaBytes']} bytes"
        )


if __name__ == "__main__":
    main()
