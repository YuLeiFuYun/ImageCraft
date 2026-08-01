#!/usr/bin/env python3
import argparse
import json
from pathlib import Path

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


def validate(path: Path) -> None:
    baseline = json.loads(path.read_text(encoding="utf-8"))
    if baseline.get("schemaVersion") != 1:
        raise AssertionError(f"{path}: unsupported schema")
    if baseline.get("benchmarkVersion") != "imagecraft-performance-v1":
        raise AssertionError(f"{path}: unexpected benchmark version")
    if baseline.get("buildConfiguration") != "release":
        raise AssertionError(f"{path}: performance baseline is not Release")
    if not baseline.get("swiftVersion"):
        raise AssertionError(f"{path}: missing Swift version")
    for field in (
        "runtime",
        "decoderFingerprint",
        "encoderFingerprint",
        "rssSampleIntervalMicroseconds",
        "hardware",
    ):
        if not baseline.get(field):
            raise AssertionError(f"{path}: missing {field}")

    cases = baseline.get("cases")
    if not isinstance(cases, list):
        raise AssertionError(f"{path}: cases must be a list")
    by_id = {case.get("caseID"): case for case in cases}
    if set(by_id) != EXPECTED_CASES or len(by_id) != len(cases):
        raise AssertionError(f"{path}: case set mismatch")

    iterations = set()
    repetitions = set()
    warmups = set()
    memory_iterations = set()
    for case_id, case in by_id.items():
        iterations.add(case.get("iterationsPerProcess"))
        repetitions.add(case.get("processRepetitions"))
        warmups.add(case.get("warmupIterationsPerProcess"))
        memory_iterations.add(case.get("memoryIterationsPerProcess"))
        if not case.get("source") or not case.get("output"):
            raise AssertionError(f"{path}: {case_id} has no source/output identity")
        observed = case.get("observed", {})
        budget = case.get("budget", {})
        pairs = (
            ("medianNanoseconds", "maximumMedianNanoseconds"),
            ("p90Nanoseconds", "maximumP90Nanoseconds"),
            (
                "medianSampledPeakDeltaBytes",
                "maximumMedianSampledPeakDeltaBytes",
            ),
            (
                "maximumSampledPeakDeltaBytes",
                "maximumProcessSampledPeakDeltaBytes",
            ),
        )
        for observed_key, budget_key in pairs:
            value = observed.get(observed_key)
            maximum = budget.get(budget_key)
            if not isinstance(value, int) or value < 0:
                raise AssertionError(f"{path}: {case_id} invalid {observed_key}")
            if not isinstance(maximum, int) or maximum < value:
                raise AssertionError(f"{path}: {case_id} invalid {budget_key}")
        estimate = observed.get("estimatedWorkingSetBytes")
        if case_id.startswith("decode-") or case_id.startswith("probe-") or case_id.startswith("prepare-"):
            if not isinstance(estimate, int) or estimate <= 0:
                raise AssertionError(f"{path}: {case_id} missing decode estimate")
        elif estimate is not None:
            raise AssertionError(f"{path}: {case_id} has unexpected decode estimate")

    if (
        len(iterations) != 1
        or len(repetitions) != 1
        or len(warmups) != 1
        or len(memory_iterations) != 1
    ):
        raise AssertionError(f"{path}: inconsistent measurement counts")
    if (
        next(iter(iterations)) <= 0
        or next(iter(repetitions)) <= 0
        or next(iter(warmups)) < 0
        or next(iter(memory_iterations)) <= 0
    ):
        raise AssertionError(f"{path}: non-positive measurement counts")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("baselines", nargs="+", type=Path)
    args = parser.parse_args()
    for path in args.baselines:
        validate(path)


if __name__ == "__main__":
    main()
