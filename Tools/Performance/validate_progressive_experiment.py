#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import math
import subprocess
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
EXPECTED_CASES = {
    "progressive-jpeg-fit-512-chunk-1024",
    "progressive-jpeg-fit-512-chunk-32768",
}
REPORT_IDENTITY_FIELDS = (
    "schemaVersion",
    "benchmarkVersion",
    "buildConfiguration",
    "swiftVersion",
    "runtime",
    "decoderFingerprint",
    "encoderFingerprint",
    "rssSampleIntervalMicroseconds",
    "hardware",
)
CASE_IDENTITY_FIELDS = (
    "processRepetitions",
    "memoryIterationsPerProcess",
    "warmupIterationsPerProcess",
    "iterationsPerProcess",
    "totalIterations",
    "source",
    "output",
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def resolve_repository_path(value: str) -> Path:
    path = (ROOT / value).resolve()
    try:
        path.relative_to(ROOT.resolve())
    except ValueError as error:
        raise AssertionError(f"experiment path escapes repository: {value}") from error
    if not path.is_file():
        raise AssertionError(f"experiment artifact is missing: {value}")
    return path


def percentile(values: list[int], numerator: int, denominator: int) -> int:
    ordered = sorted(values)
    rank = max(1, (len(ordered) * numerator + denominator - 1) // denominator)
    return ordered[min(len(ordered) - 1, rank - 1)]


def validate_duration(case_id: str, case: dict[str, Any]) -> None:
    samples = case.get("samplesNanoseconds")
    if not isinstance(samples, list) or not samples or not all(
        isinstance(value, int) and value > 0 for value in samples
    ):
        raise AssertionError(f"{case_id}: invalid timing samples")
    if len(samples) != case.get("totalIterations"):
        raise AssertionError(f"{case_id}: timing sample count mismatch")
    duration = case.get("duration", {})
    expected = {
        "minimumNanoseconds": min(samples),
        "medianNanoseconds": percentile(samples, 50, 100),
        "p90Nanoseconds": percentile(samples, 90, 100),
        "maximumNanoseconds": max(samples),
        "meanNanoseconds": sum(samples) // len(samples),
    }
    if duration != expected:
        raise AssertionError(f"{case_id}: duration statistics are not reproducible")


def validate_memory(case_id: str, case: dict[str, Any]) -> None:
    memory = case.get("memory", {})
    deltas = memory.get("sampledPeakDeltaBytes")
    repetitions = case.get("processRepetitions")
    if not isinstance(deltas, list) or len(deltas) != repetitions or not all(
        isinstance(value, int) and value >= 0 for value in deltas
    ):
        raise AssertionError(f"{case_id}: invalid RSS delta samples")
    if deltas != sorted(deltas):
        raise AssertionError(f"{case_id}: aggregate RSS deltas must be sorted")
    if memory.get("medianSampledPeakDeltaBytes") != percentile(deltas, 50, 100):
        raise AssertionError(f"{case_id}: RSS median mismatch")
    if memory.get("maximumSampledPeakDeltaBytes") != max(deltas):
        raise AssertionError(f"{case_id}: RSS maximum mismatch")
    for field in ("baselineResidentBytes", "sampledPeakResidentBytes"):
        values = memory.get(field)
        if not isinstance(values, list) or len(values) != repetitions:
            raise AssertionError(f"{case_id}: invalid {field}")
    estimate = memory.get("estimatedWorkingSetBytes")
    if not isinstance(estimate, int) or estimate <= 0:
        raise AssertionError(f"{case_id}: missing working-set estimate")


def validate_report(path: Path) -> dict[str, Any]:
    report = json.loads(path.read_text(encoding="utf-8"))
    if report.get("schemaVersion") != 1:
        raise AssertionError(f"{path}: unsupported performance report schema")
    if report.get("benchmarkVersion") != "imagecraft-performance-v1":
        raise AssertionError(f"{path}: unexpected benchmark version")
    if report.get("buildConfiguration") != "release":
        raise AssertionError(f"{path}: report is not a Release build")
    cases = report.get("cases")
    if not isinstance(cases, list):
        raise AssertionError(f"{path}: cases must be a list")
    by_id = {case.get("caseID"): case for case in cases}
    if set(by_id) != EXPECTED_CASES or len(by_id) != len(cases):
        raise AssertionError(f"{path}: progressive case set mismatch")
    for case_id, case in by_id.items():
        if case.get("processRepetitions") != 3:
            raise AssertionError(f"{case_id}: expected three process repetitions")
        if case.get("memoryIterationsPerProcess") != 1:
            raise AssertionError(f"{case_id}: expected one memory iteration")
        if case.get("warmupIterationsPerProcess") != 2:
            raise AssertionError(f"{case_id}: expected two warmups")
        if case.get("iterationsPerProcess") != 7 or case.get("totalIterations") != 21:
            raise AssertionError(f"{case_id}: expected 3x7 timed iterations")
        validate_duration(case_id, case)
        validate_memory(case_id, case)
    return report


def canonical_source_identity(report: dict[str, Any]) -> str:
    payload = json.dumps(
        {
            "schemaVersion": report["schemaVersion"],
            "identityID": report["identityID"],
            "coverage": report["coverage"],
            "files": report["files"],
        },
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    return hashlib.sha256(payload).hexdigest()


def close(actual: float, expected: float) -> bool:
    return math.isclose(actual, expected, rel_tol=1e-12, abs_tol=1e-12)


def git_output(*arguments: str, binary: bool = False) -> bytes | str:
    completed = subprocess.run(
        ["git", *arguments],
        cwd=ROOT,
        check=True,
        capture_output=True,
    )
    return completed.stdout if binary else completed.stdout.decode().strip()


def repository_has_git_history() -> bool:
    try:
        completed = subprocess.run(
            ["git", "rev-parse", "--is-inside-work-tree"],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
    except OSError:
        return False
    return completed.returncode == 0 and completed.stdout.strip() == "true"


def identity_path_is_included(path: str, coverage: dict[str, Any]) -> bool:
    parts = path.split("/")
    if not parts or parts[0] not in set(coverage["includedTopLevel"]):
        return False
    if any(part in set(coverage["excludedAnywhere"]) for part in parts):
        return False
    return not any(
        path == subtree or path.startswith(f"{subtree}/")
        for subtree in coverage["excludedSubtrees"]
    )


def validate_git_binding(
    commit: str,
    expected_tree: str,
    identity: dict[str, Any],
) -> None:
    if not repository_has_git_history():
        return
    actual_tree = git_output("rev-parse", f"{commit}^{{tree}}")
    if actual_tree != expected_tree:
        raise AssertionError("implementation commit tree mismatch")

    tracked_paths = str(git_output("ls-tree", "-r", "--name-only", commit)).splitlines()
    expected_paths = {
        path
        for path in tracked_paths
        if identity_path_is_included(path, identity["coverage"])
    }
    entries = {entry["path"]: entry for entry in identity["files"]}
    if set(entries) != expected_paths:
        raise AssertionError("source identity file set does not match implementation commit")

    for path, entry in entries.items():
        data = git_output("show", f"{commit}:{path}", binary=True)
        if len(data) != entry["byteCount"] or hashlib.sha256(data).hexdigest() != entry["sha256"]:
            raise AssertionError(f"source identity content does not match commit: {path}")
        listing = str(git_output("ls-tree", commit, "--", path))
        mode = listing.split(maxsplit=1)[0] if listing else ""
        if (mode == "100755") != entry["executable"]:
            raise AssertionError(f"source identity mode does not match commit: {path}")


def validate(path: Path) -> None:
    experiment = json.loads(path.read_text(encoding="utf-8"))
    if experiment.get("schemaVersion") != 1:
        raise AssertionError("unsupported progressive experiment schema")
    if experiment.get("experimentID") != "progressive-jpeg-bounded-preview-ab-v1":
        raise AssertionError("unexpected progressive experiment identity")

    artifacts = experiment.get("artifacts", {})
    required_artifacts = {"beforeHistorical", "afterHistorical", "afterClean"}
    if set(artifacts) != required_artifacts:
        raise AssertionError("progressive experiment artifact set mismatch")
    reports: dict[str, dict[str, Any]] = {}
    for key in sorted(required_artifacts):
        metadata = artifacts[key]
        artifact_path = resolve_repository_path(metadata["path"])
        if sha256(artifact_path) != metadata.get("sha256"):
            raise AssertionError(f"{key}: artifact digest mismatch")
        reports[key] = validate_report(artifact_path)

    reference = reports["afterClean"]
    for key, report in reports.items():
        for field in REPORT_IDENTITY_FIELDS:
            if report.get(field) != reference.get(field):
                raise AssertionError(f"{key}: environment identity drifted at {field}")

    by_report = {
        key: {case["caseID"]: case for case in report["cases"]}
        for key, report in reports.items()
    }
    for case_id in sorted(EXPECTED_CASES):
        clean_case = by_report["afterClean"][case_id]
        for key in ("beforeHistorical", "afterHistorical"):
            candidate = by_report[key][case_id]
            for field in CASE_IDENTITY_FIELDS:
                if candidate.get(field) != clean_case.get(field):
                    raise AssertionError(f"{case_id}: {key} drifted at {field}")

    implementation = experiment.get("implementation", {})
    if implementation.get("commit") != "4460ca8aee1196cefad2f9f5076e601b7ef30f94":
        raise AssertionError("unexpected measured implementation commit")
    identity_path = resolve_repository_path(implementation["sourceIdentityReportPath"])
    if sha256(identity_path) != implementation.get("sourceIdentityReportSHA256"):
        raise AssertionError("source identity report digest mismatch")
    identity = json.loads(identity_path.read_text(encoding="utf-8"))
    if canonical_source_identity(identity) != identity.get("sourceIdentitySHA256"):
        raise AssertionError("stored source identity is internally inconsistent")
    expected_identity = {
        "sourceIdentitySchemaVersion": identity["schemaVersion"],
        "sourceIdentityID": identity["identityID"],
        "sourceIdentityFileCount": identity["fileCount"],
        "sourceIdentitySHA256": identity["sourceIdentitySHA256"],
    }
    for field, value in expected_identity.items():
        if implementation.get(field) != value:
            raise AssertionError(f"implementation identity mismatch: {field}")
    if implementation.get("cleanWorktreeAtCapture") is not True:
        raise AssertionError("clean implementation capture is required")
    commit_tree = implementation.get("commitTree")
    if commit_tree != "915c2efc1c61700ddabdef96032544332b42208e":
        raise AssertionError("unexpected implementation commit tree")
    if not implementation.get("gitBinding"):
        raise AssertionError("implementation Git binding description is missing")
    validate_git_binding(implementation["commit"], commit_tree, identity)

    methodology = experiment.get("methodology", {})
    if set(methodology.get("caseIDs", [])) != EXPECTED_CASES:
        raise AssertionError("methodology case registry mismatch")
    if methodology.get("processRepetitionsPerCase") != 3:
        raise AssertionError("methodology process count drifted")
    if methodology.get("timedIterationsPerProcess") != 7:
        raise AssertionError("methodology iteration count drifted")
    if methodology.get("totalTimedIterationsPerCase") != 21:
        raise AssertionError("methodology total sample count drifted")

    environment = experiment.get("environment", {})
    for field in (
        "runtime",
        "swiftVersion",
        "hardware",
        "decoderFingerprint",
        "encoderFingerprint",
    ):
        if environment.get(field) != reference.get(field):
            raise AssertionError(f"experiment environment drifted at {field}")

    rules = experiment.get("decisionRules", {})
    minimum_speedup = rules.get("minimumBeforeToCleanSpeedup")
    minimum_rss = rules.get("minimumBeforeToCleanRSSReduction")
    reproduction = rules.get("cleanToHistoricalAfterDurationRatioRange")
    if minimum_speedup != 2.0 or minimum_rss != 2.0 or reproduction != [0.8, 1.2]:
        raise AssertionError("progressive experiment decision rules drifted")
    rule_timing = rules.get("ruleTiming", "")
    if "post-hoc" not in rule_timing or "not a preregistered" not in rule_timing:
        raise AssertionError("progressive experiment must disclose post-hoc rule timing")

    summary_cases = experiment.get("cases", {})
    if set(summary_cases) != EXPECTED_CASES:
        raise AssertionError("summary case set mismatch")
    for case_id in sorted(EXPECTED_CASES):
        before = by_report["beforeHistorical"][case_id]
        historical = by_report["afterHistorical"][case_id]
        clean = by_report["afterClean"][case_id]
        expected_ratios = {
            "beforeToCleanMedianSpeedup": before["duration"]["medianNanoseconds"]
            / clean["duration"]["medianNanoseconds"],
            "beforeToCleanP90Speedup": before["duration"]["p90Nanoseconds"]
            / clean["duration"]["p90Nanoseconds"],
            "beforeToCleanMedianRSSReduction": before["memory"][
                "medianSampledPeakDeltaBytes"
            ]
            / clean["memory"]["medianSampledPeakDeltaBytes"],
            "beforeToCleanMaximumRSSReduction": before["memory"][
                "maximumSampledPeakDeltaBytes"
            ]
            / clean["memory"]["maximumSampledPeakDeltaBytes"],
            "cleanToHistoricalAfterMedianRatio": clean["duration"][
                "medianNanoseconds"
            ]
            / historical["duration"]["medianNanoseconds"],
            "cleanToHistoricalAfterP90Ratio": clean["duration"]["p90Nanoseconds"]
            / historical["duration"]["p90Nanoseconds"],
        }
        recorded = summary_cases[case_id].get("ratios", {})
        for field, value in expected_ratios.items():
            if not isinstance(recorded.get(field), (int, float)) or not close(
                float(recorded[field]), value
            ):
                raise AssertionError(f"{case_id}: ratio mismatch for {field}")
        for field in (
            "beforeToCleanMedianSpeedup",
            "beforeToCleanP90Speedup",
        ):
            if expected_ratios[field] < minimum_speedup:
                raise AssertionError(f"{case_id}: duration improvement floor failed")
        for field in (
            "beforeToCleanMedianRSSReduction",
            "beforeToCleanMaximumRSSReduction",
        ):
            if expected_ratios[field] < minimum_rss:
                raise AssertionError(f"{case_id}: RSS improvement floor failed")
        for field in (
            "cleanToHistoricalAfterMedianRatio",
            "cleanToHistoricalAfterP90Ratio",
        ):
            if not reproduction[0] <= expected_ratios[field] <= reproduction[1]:
                raise AssertionError(f"{case_id}: clean duration reproduction failed")
        decision = summary_cases[case_id].get("decision", {})
        if decision != {
            "cleanDurationReproductionPassed": True,
            "substantialImprovementPassed": True,
        }:
            raise AssertionError(f"{case_id}: decision marker drifted")

    decision = experiment.get("decision", {})
    if decision.get("passed") is not True:
        raise AssertionError("progressive experiment must remain passed")
    if not decision.get("supportedClaims") or not decision.get("unsupportedClaims"):
        raise AssertionError("progressive claim boundary is incomplete")
    if not experiment.get("remainingEvidence"):
        raise AssertionError("progressive follow-up evidence list is missing")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("experiment", type=Path)
    args = parser.parse_args()
    validate(args.experiment)
    print(f"Progressive JPEG experiment passed: {args.experiment}")


if __name__ == "__main__":
    main()
