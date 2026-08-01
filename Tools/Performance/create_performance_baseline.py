#!/usr/bin/env python3
import argparse
import json
import math
from pathlib import Path

MIB = 1024 * 1024


def timing_budget(value: int, factor: float, additive_ns: int) -> int:
    return max(math.ceil(value * factor), value + additive_ns)


def memory_budget(value: int, additive_mib: int) -> int:
    return max(math.ceil(value * 1.5), value + additive_mib * MIB)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    report = json.loads(args.report.read_text(encoding="utf-8"))
    cases = []
    for case in report["cases"]:
        duration = case["duration"]
        memory = case["memory"]
        cases.append(
            {
                "caseID": case["caseID"],
                "processRepetitions": case["processRepetitions"],
                "iterationsPerProcess": case["iterationsPerProcess"],
                "memoryIterationsPerProcess": case["memoryIterationsPerProcess"],
                "warmupIterationsPerProcess": case["warmupIterationsPerProcess"],
                "source": case["source"],
                "output": case["output"],
                "observed": {
                    "medianNanoseconds": duration["medianNanoseconds"],
                    "p90Nanoseconds": duration["p90Nanoseconds"],
                    "medianSampledPeakDeltaBytes": memory[
                        "medianSampledPeakDeltaBytes"
                    ],
                    "maximumSampledPeakDeltaBytes": memory[
                        "maximumSampledPeakDeltaBytes"
                    ],
                    "estimatedWorkingSetBytes": memory.get(
                        "estimatedWorkingSetBytes"
                    ),
                },
                "budget": {
                    "maximumMedianNanoseconds": timing_budget(
                        duration["medianNanoseconds"], 1.5, 10_000_000
                    ),
                    "maximumP90Nanoseconds": timing_budget(
                        duration["p90Nanoseconds"], 1.75, 15_000_000
                    ),
                    "maximumMedianSampledPeakDeltaBytes": memory_budget(
                        memory["medianSampledPeakDeltaBytes"], 16
                    ),
                    "maximumProcessSampledPeakDeltaBytes": memory_budget(
                        memory["maximumSampledPeakDeltaBytes"], 32
                    ),
                },
            }
        )

    baseline = {
        "schemaVersion": 1,
        "benchmarkVersion": report["benchmarkVersion"],
        "buildConfiguration": report["buildConfiguration"],
        "swiftVersion": report["swiftVersion"],
        "runtime": report["runtime"],
        "decoderFingerprint": report["decoderFingerprint"],
        "encoderFingerprint": report["encoderFingerprint"],
        "rssSampleIntervalMicroseconds": report["rssSampleIntervalMicroseconds"],
        "hardware": report["hardware"],
        "cases": cases,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(baseline, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
