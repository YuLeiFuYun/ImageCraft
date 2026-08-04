#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from aggregate_progressive_timeline import (  # noqa: E402
    BENCHMARK_VERSION,
    EXPECTED_CASES,
    summarize,
)
from validate_progressive_experiment import (  # noqa: E402
    canonical_source_identity,
    close,
    resolve_repository_path,
    sha256,
    validate_git_binding,
)

EXPECTED_COMMIT = "ffaef9fb45c633e26c4872805cfc18c7ecbb8f05"
EXPECTED_TREE = "0160bffe65815fff3ca04210ebefb3c67fcecb74"


def validate_campaign(path: Path) -> dict[str, Any]:
    report = json.loads(path.read_text(encoding="utf-8"))
    if report.get("schemaVersion") != 1:
        raise AssertionError(f"{path}: unsupported timeline schema")
    if report.get("benchmarkVersion") != BENCHMARK_VERSION:
        raise AssertionError(f"{path}: unexpected timeline benchmark version")
    if report.get("buildConfiguration") != "release":
        raise AssertionError(f"{path}: timeline report is not Release")
    if not report.get("swiftVersion") or not report.get("runtime"):
        raise AssertionError(f"{path}: incomplete runtime identity")
    if not report.get("decoderFingerprint") or not report.get("hardware"):
        raise AssertionError(f"{path}: incomplete implementation identity")

    cases = report.get("cases")
    if not isinstance(cases, list):
        raise AssertionError(f"{path}: cases must be a list")
    by_id = {case.get("caseID"): case for case in cases}
    if set(by_id) != set(EXPECTED_CASES) or len(by_id) != len(cases):
        raise AssertionError(f"{path}: timeline case set mismatch")

    for case_id, case in by_id.items():
        if case.get("processRepetitions") != 3:
            raise AssertionError(f"{case_id}: expected three process repetitions")
        if case.get("warmupIterationsPerProcess") != 2:
            raise AssertionError(f"{case_id}: expected two warmups")
        if case.get("iterationsPerProcess") != 7 or case.get("totalIterations") != 21:
            raise AssertionError(f"{case_id}: expected 3x7 timeline samples")
        if case.get("chunkSizeBytes") != EXPECTED_CASES[case_id]:
            raise AssertionError(f"{case_id}: chunk size mismatch")
        samples = case.get("samples")
        if not isinstance(samples, list) or len(samples) != 21:
            raise AssertionError(f"{case_id}: raw timeline sample count mismatch")
        source = case.get("source", {})
        encoded_bytes = source.get("encodedByteCount")
        if not isinstance(encoded_bytes, int) or encoded_bytes <= 0:
            raise AssertionError(f"{case_id}: encoded byte identity is missing")
        if not source.get("encodedSHA256") or not case.get("output"):
            raise AssertionError(f"{case_id}: source/output identity is missing")
        if case.get("summary") != summarize(samples, encoded_bytes):
            raise AssertionError(f"{case_id}: aggregate summary is not reproducible")
        summary = case["summary"]
        if summary.get("generationCount") != 4:
            raise AssertionError(f"{case_id}: expected four bounded generations")
        generations = summary.get("generations", [])
        if [item.get("generation") for item in generations] != [1, 2, 3, 4]:
            raise AssertionError(f"{case_id}: generation identity drifted")
        source_counts = [item.get("sourceByteCount") for item in generations]
        if source_counts != sorted(source_counts) or len(set(source_counts)) != 4:
            raise AssertionError(f"{case_id}: generation source bytes are not strict")
        if summary["firstPreviewSourceByteCount"] % case["chunkSizeBytes"] != 0:
            raise AssertionError(f"{case_id}: first preview is not on a chunk boundary")
        environment = case.get("environment", {})
        if environment.get("lowPowerModeEnabled"):
            raise AssertionError(f"{case_id}: low power mode was enabled")
        if not set(environment.get("thermalStates", [])).issubset({"nominal", "fair"}):
            raise AssertionError(f"{case_id}: unsuitable thermal state")
    return report


def case_map(report: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {case["caseID"]: case for case in report["cases"]}


def expected_ratios(
    first: dict[str, Any],
    second: dict[str, Any],
    pooled: dict[str, Any],
) -> dict[str, float]:
    return {
        "campaign2ToCampaign1FirstPreviewMedian": second["firstPreviewElapsed"]
        ["medianNanoseconds"]
        / first["firstPreviewElapsed"]["medianNanoseconds"],
        "campaign2ToCampaign1FirstPreviewP90": second["firstPreviewElapsed"]
        ["p90Nanoseconds"]
        / first["firstPreviewElapsed"]["p90Nanoseconds"],
        "campaign2ToCampaign1FinishMedian": second["finishElapsed"]["medianNanoseconds"]
        / first["finishElapsed"]["medianNanoseconds"],
        "campaign2ToCampaign1FinishP90": second["finishElapsed"]["p90Nanoseconds"]
        / first["finishElapsed"]["p90Nanoseconds"],
        "pooledFirstPreviewToFinishMedian": pooled["firstPreviewElapsed"]
        ["medianNanoseconds"]
        / pooled["finishElapsed"]["medianNanoseconds"],
    }


def validate(path: Path) -> None:
    experiment = json.loads(path.read_text(encoding="utf-8"))
    if experiment.get("schemaVersion") != 1:
        raise AssertionError("unsupported first-preview experiment schema")
    if experiment.get("experimentID") != "progressive-jpeg-first-preview-timeline-v1":
        raise AssertionError("unexpected first-preview experiment identity")

    artifacts = experiment.get("artifacts", {})
    if set(artifacts) != {"campaign1", "campaign2"}:
        raise AssertionError("first-preview artifact set mismatch")
    campaigns = {}
    for key in ("campaign1", "campaign2"):
        metadata = artifacts[key]
        artifact_path = resolve_repository_path(metadata["path"])
        if sha256(artifact_path) != metadata.get("sha256"):
            raise AssertionError(f"{key}: artifact digest mismatch")
        campaigns[key] = validate_campaign(artifact_path)

    first = campaigns["campaign1"]
    second = campaigns["campaign2"]
    for field in (
        "benchmarkVersion",
        "buildConfiguration",
        "swiftVersion",
        "runtime",
        "decoderFingerprint",
        "hardware",
    ):
        if first.get(field) != second.get(field):
            raise AssertionError(f"campaign environment drifted at {field}")

    environment = experiment.get("environment", {})
    for field in ("runtime", "swiftVersion", "hardware", "decoderFingerprint"):
        if environment.get(field) != first.get(field):
            raise AssertionError(f"experiment environment drifted at {field}")

    implementation = experiment.get("implementation", {})
    if implementation.get("commit") != EXPECTED_COMMIT:
        raise AssertionError("unexpected first-preview implementation commit")
    if implementation.get("commitTree") != EXPECTED_TREE:
        raise AssertionError("unexpected first-preview implementation tree")
    if implementation.get("cleanWorktreeAtCapture") is not True:
        raise AssertionError("first-preview capture must use a clean worktree")
    identity_path = resolve_repository_path(implementation["sourceIdentityReportPath"])
    if sha256(identity_path) != implementation.get("sourceIdentityReportSHA256"):
        raise AssertionError("first-preview source identity digest mismatch")
    identity = json.loads(identity_path.read_text(encoding="utf-8"))
    if canonical_source_identity(identity) != identity.get("sourceIdentitySHA256"):
        raise AssertionError("first-preview source identity is internally inconsistent")
    for field, value in {
        "sourceIdentitySchemaVersion": identity["schemaVersion"],
        "sourceIdentityID": identity["identityID"],
        "sourceIdentityFileCount": identity["fileCount"],
        "sourceIdentitySHA256": identity["sourceIdentitySHA256"],
    }.items():
        if implementation.get(field) != value:
            raise AssertionError(f"first-preview implementation mismatch: {field}")
    validate_git_binding(EXPECTED_COMMIT, EXPECTED_TREE, identity)

    methodology = experiment.get("methodology", {})
    expected_method = {
        "benchmarkVersion": BENCHMARK_VERSION,
        "buildConfiguration": "release",
        "campaigns": 2,
        "processRepetitionsPerCasePerCampaign": 3,
        "timedIterationsPerProcess": 7,
        "totalTimedIterationsPerCase": 42,
        "warmupIterationsPerProcess": 2,
        "fixtureAndChunkConstructionExcluded": True,
        "networkArrivalExcluded": True,
    }
    for field, value in expected_method.items():
        if methodology.get(field) != value:
            raise AssertionError(f"first-preview methodology drifted at {field}")

    rules = experiment.get("decisionRules", {})
    if rules.get("maximumPooledFirstPreviewEncodedByteFractionPPM") != 50_000:
        raise AssertionError("first-preview byte-fraction rule drifted")
    if rules.get("maximumPooledFirstPreviewMedianNanoseconds") != 10_000_000:
        raise AssertionError("first-preview local-latency rule drifted")
    if rules.get("campaign2ToCampaign1FirstPreviewRatioRange") != [0.8, 1.2]:
        raise AssertionError("first-preview replication rule drifted")
    if rules.get("campaign2ToCampaign1FinishMedianRatioRange") != [0.8, 1.2]:
        raise AssertionError("finish-median replication rule drifted")
    timing = rules.get("ruleTiming", "")
    if "post-hoc" not in timing or "not a preregistered" not in timing:
        raise AssertionError("first-preview rules must disclose post-hoc timing")

    first_cases = case_map(first)
    second_cases = case_map(second)
    summary_cases = experiment.get("cases", {})
    if set(summary_cases) != set(EXPECTED_CASES):
        raise AssertionError("first-preview summary case set mismatch")
    intervals = []
    for case_id in sorted(EXPECTED_CASES):
        c1 = first_cases[case_id]
        c2 = second_cases[case_id]
        for field in ("chunkSizeBytes", "chunkCount", "source", "output"):
            if c1.get(field) != c2.get(field):
                raise AssertionError(f"{case_id}: campaigns drifted at {field}")
        pooled = summarize(
            c1["samples"] + c2["samples"],
            c1["source"]["encodedByteCount"],
        )
        recorded = summary_cases[case_id]
        if recorded.get("chunkSizeBytes") != c1["chunkSizeBytes"]:
            raise AssertionError(f"{case_id}: recorded chunk size mismatch")
        if recorded.get("chunkCount") != c1["chunkCount"]:
            raise AssertionError(f"{case_id}: recorded chunk count mismatch")
        if recorded.get("campaign1") != c1["summary"]:
            raise AssertionError(f"{case_id}: campaign 1 summary mismatch")
        if recorded.get("campaign2") != c2["summary"]:
            raise AssertionError(f"{case_id}: campaign 2 summary mismatch")
        if recorded.get("pooled") != pooled:
            raise AssertionError(f"{case_id}: pooled summary mismatch")

        expected_interval = {
            "exclusiveLowerBound": max(
                0, pooled["firstPreviewSourceByteCount"] - c1["chunkSizeBytes"]
            ),
            "inclusiveUpperBound": pooled["firstPreviewSourceByteCount"],
        }
        if recorded.get("firstCompletedScanBoundaryIntervalBytes") != expected_interval:
            raise AssertionError(f"{case_id}: first-scan interval mismatch")
        intervals.append(expected_interval)

        ratios = expected_ratios(c1["summary"], c2["summary"], pooled)
        for field, value in ratios.items():
            actual = recorded.get("ratios", {}).get(field)
            if not isinstance(actual, (int, float)) or not close(float(actual), value):
                raise AssertionError(f"{case_id}: ratio mismatch for {field}")
        lower, upper = 0.8, 1.2
        expected_decision = {
            "firstPreviewByteFractionPassed": pooled[
                "firstPreviewEncodedByteFractionPPM"
            ]
            <= 50_000,
            "firstPreviewLocalMedianPassed": pooled["firstPreviewElapsed"]
            ["medianNanoseconds"]
            <= 10_000_000,
            "firstPreviewReplicationPassed": lower
            <= ratios["campaign2ToCampaign1FirstPreviewMedian"]
            <= upper
            and lower <= ratios["campaign2ToCampaign1FirstPreviewP90"] <= upper,
            "finishMedianReplicationPassed": lower
            <= ratios["campaign2ToCampaign1FinishMedian"]
            <= upper,
            "finishP90Qualified": False,
        }
        if recorded.get("decision") != expected_decision:
            raise AssertionError(f"{case_id}: decision mismatch")
        if not all(value for key, value in expected_decision.items() if key != "finishP90Qualified"):
            raise AssertionError(f"{case_id}: first-preview qualification failed")

    expected_intersection = {
        "exclusiveLowerBound": max(item["exclusiveLowerBound"] for item in intervals),
        "inclusiveUpperBound": min(item["inclusiveUpperBound"] for item in intervals),
    }
    if expected_intersection["exclusiveLowerBound"] >= expected_intersection[
        "inclusiveUpperBound"
    ]:
        raise AssertionError("first-scan boundary intervals do not overlap")
    inference = experiment.get("inference", {}).get(
        "fixedFixtureFirstCompletedScanBoundaryBytes", {}
    )
    for field, value in expected_intersection.items():
        if inference.get(field) != value:
            raise AssertionError(f"first-scan inference mismatch at {field}")
    if not inference.get("derivation"):
        raise AssertionError("first-scan inference derivation is missing")

    decision = experiment.get("decision", {})
    if decision.get("passed") is not True:
        raise AssertionError("first-preview experiment must remain passed")
    if not decision.get("supportedClaims") or not decision.get("unsupportedClaims"):
        raise AssertionError("first-preview claim boundary is incomplete")
    if not experiment.get("remainingEvidence"):
        raise AssertionError("first-preview remaining evidence is missing")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("experiment", type=Path)
    args = parser.parse_args()
    validate(args.experiment)
    print(f"Progressive JPEG first-preview experiment passed: {args.experiment}")


if __name__ == "__main__":
    main()
