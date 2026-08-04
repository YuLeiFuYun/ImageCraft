#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from aggregate_progressive_quality import (
    EVIDENCE_VERSION,
    EXPECTED_CASES,
    SCHEMA_VERSION,
    validate_report,
)
from validate_progressive_experiment import (
    canonical_source_identity,
    close,
    resolve_repository_path,
    sha256,
    validate_git_binding,
)

EXPECTED_COMMIT = "085ba9b6a53f56c6fb5f41df9048401a43dc5b48"
EXPECTED_TREE = "fc316d90e1221f55ab7799bdb0749032ca4740f1"


def aggregate_from_reports(reports: list[dict[str, Any]]) -> dict[str, Any]:
    by_id = {report["caseID"]: report for report in reports}
    if set(by_id) != set(EXPECTED_CASES) or len(by_id) != len(reports):
        raise AssertionError("quality aggregate case set mismatch")
    first = reports[0]
    for report in reports[1:]:
        for field in (
            "runtime",
            "decoderFingerprint",
            "source",
            "output",
            "finalPixelRGBSHA256",
        ):
            if report[field] != first[field]:
                raise AssertionError(f"quality raw reports drifted at {field}")
        reference_hardware = {
            field: first["environment"][field]
            for field in ("hardwareModel", "activeProcessorCount", "physicalMemoryBytes")
        }
        current_hardware = {
            field: report["environment"][field]
            for field in ("hardwareModel", "activeProcessorCount", "physicalMemoryBytes")
        }
        if current_hardware != reference_hardware:
            raise AssertionError("quality raw report hardware changed")
    return {
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


def classifications(generation: dict[str, Any]) -> dict[str, bool]:
    number = generation["generation"]
    metrics = generation["metricsAgainstFinal"]
    return {
        "coarseRelativeToFinal": number <= 2
        and metrics["psnrMicrodecibels"] < 25_000_000
        and metrics["meanAbsoluteErrorMicrounits"] > 10_000_000
        and metrics["absoluteErrorAtMost16PPM"] < 600_000,
        "nearFinalByDeclaredPixelThresholds": number >= 3
        and metrics["psnrMicrodecibels"] >= 40_000_000
        and metrics["meanAbsoluteErrorMicrounits"] <= 2_000_000
        and metrics["maximumAbsoluteError"] <= 8
        and metrics["absoluteErrorAtMost8PPM"] == 1_000_000,
    }


def robustness(
    left: dict[str, Any], right: dict[str, Any]
) -> list[dict[str, int | bool]]:
    result = []
    for first, second in zip(left["generations"], right["generations"], strict=True):
        if first["generation"] != second["generation"]:
            raise AssertionError("quality generation identity differs by chunk schedule")
        first_metrics = first["metricsAgainstFinal"]
        second_metrics = second["metricsAgainstFinal"]
        result.append(
            {
                "generation": first["generation"],
                "sourceByteFractionDifferencePPM": abs(
                    first["encodedByteFractionPPM"]
                    - second["encodedByteFractionPPM"]
                ),
                "psnrDifferenceMicrodecibels": abs(
                    first_metrics["psnrMicrodecibels"]
                    - second_metrics["psnrMicrodecibels"]
                ),
                "meanAbsoluteErrorDifferenceMicrounits": abs(
                    first_metrics["meanAbsoluteErrorMicrounits"]
                    - second_metrics["meanAbsoluteErrorMicrounits"]
                ),
                "pixelRGBExactMatch": first["pixelRGBSHA256"]
                == second["pixelRGBSHA256"],
            }
        )
    return result


def validate(path: Path) -> None:
    experiment = json.loads(path.read_text(encoding="utf-8"))
    if experiment.get("schemaVersion") != 1:
        raise AssertionError("unsupported progressive quality experiment schema")
    if experiment.get("experimentID") != "progressive-jpeg-generation-quality-v1":
        raise AssertionError("unexpected progressive quality experiment identity")

    artifacts = experiment.get("artifacts", {})
    aggregate_meta = artifacts.get("aggregate", {})
    aggregate_path = resolve_repository_path(aggregate_meta["path"])
    if sha256(aggregate_path) != aggregate_meta.get("sha256"):
        raise AssertionError("progressive quality aggregate digest mismatch")
    aggregate = json.loads(aggregate_path.read_text(encoding="utf-8"))

    raw_meta = artifacts.get("rawReports", {})
    expected_raw_names = {
        "progressive-jpeg-quality-fit-512-chunk-1024-a.json",
        "progressive-jpeg-quality-fit-512-chunk-1024-b.json",
        "progressive-jpeg-quality-fit-512-chunk-32768-a.json",
        "progressive-jpeg-quality-fit-512-chunk-32768-b.json",
    }
    if set(raw_meta) != expected_raw_names:
        raise AssertionError("progressive quality raw artifact set mismatch")
    raw_bytes: dict[str, bytes] = {}
    raw_reports: dict[str, dict[str, Any]] = {}
    for name, metadata in raw_meta.items():
        report_path = resolve_repository_path(metadata["path"])
        if sha256(report_path) != metadata.get("sha256"):
            raise AssertionError(f"quality raw report digest mismatch: {name}")
        raw_bytes[name] = report_path.read_bytes()
        report = json.loads(raw_bytes[name])
        validate_report(report, report_path)
        raw_reports[name] = report

    for prefix in (
        "progressive-jpeg-quality-fit-512-chunk-1024",
        "progressive-jpeg-quality-fit-512-chunk-32768",
    ):
        if raw_bytes[f"{prefix}-a.json"] != raw_bytes[f"{prefix}-b.json"]:
            raise AssertionError(f"quality repeated execution drifted: {prefix}")

    unique_reports = [
        raw_reports["progressive-jpeg-quality-fit-512-chunk-1024-a.json"],
        raw_reports["progressive-jpeg-quality-fit-512-chunk-32768-a.json"],
    ]
    expected_aggregate = aggregate_from_reports(unique_reports)
    if aggregate != expected_aggregate:
        raise AssertionError("progressive quality aggregate is not reproducible")

    implementation = experiment.get("implementation", {})
    if implementation.get("commit") != EXPECTED_COMMIT:
        raise AssertionError("unexpected progressive quality implementation commit")
    if implementation.get("commitTree") != EXPECTED_TREE:
        raise AssertionError("unexpected progressive quality implementation tree")
    if implementation.get("cleanWorktreeAtCapture") is not True:
        raise AssertionError("quality evidence must use a clean worktree")
    identity_path = resolve_repository_path(implementation["sourceIdentityReportPath"])
    if sha256(identity_path) != implementation.get("sourceIdentityReportSHA256"):
        raise AssertionError("quality source identity report digest mismatch")
    identity = json.loads(identity_path.read_text(encoding="utf-8"))
    if canonical_source_identity(identity) != identity.get("sourceIdentitySHA256"):
        raise AssertionError("quality source identity is internally inconsistent")
    for field, value in {
        "sourceIdentitySchemaVersion": identity["schemaVersion"],
        "sourceIdentityID": identity["identityID"],
        "sourceIdentityFileCount": identity["fileCount"],
        "sourceIdentitySHA256": identity["sourceIdentitySHA256"],
    }.items():
        if implementation.get(field) != value:
            raise AssertionError(f"quality implementation mismatch: {field}")
    validate_git_binding(EXPECTED_COMMIT, EXPECTED_TREE, identity)

    environment = experiment.get("environment", {})
    for field in ("runtime", "hardware", "decoderFingerprint"):
        if environment.get(field) != aggregate.get(field):
            raise AssertionError(f"quality environment drifted at {field}")

    methodology = experiment.get("methodology", {})
    if methodology.get("evidenceVersion") != EVIDENCE_VERSION:
        raise AssertionError("quality evidence version drifted")
    if methodology.get("buildConfiguration") != "release":
        raise AssertionError("quality evidence must remain Release")
    if methodology.get("caseCount") != 2 or methodology.get("executionsPerCase") != 2:
        raise AssertionError("quality execution count drifted")
    if "complete decode" not in methodology.get("reference", ""):
        raise AssertionError("quality final-decode reference is not explicit")
    if "sRGB RGB8" not in methodology.get("analysisSurface", ""):
        raise AssertionError("quality analysis surface is not explicit")

    rules = experiment.get("decisionRules", {})
    if "post-hoc" not in rules.get("ruleTiming", ""):
        raise AssertionError("quality thresholds must disclose post-hoc timing")
    coarse_rule = rules.get("coarseRelativeToFinal", {})
    near_rule = rules.get("nearFinalByDeclaredPixelThresholds", {})
    robustness_rule = rules.get("chunkScheduleRobustness", {})
    if coarse_rule != {
        "generationRange": [1, 2],
        "maximumPSNRMicrodecibelsExclusive": 25_000_000,
        "minimumMeanAbsoluteErrorMicrounitsExclusive": 10_000_000,
        "maximumAbsoluteErrorAtMost16PPMExclusive": 600_000,
    }:
        raise AssertionError("coarse quality rule drifted")
    if near_rule != {
        "generationRange": [3, 4],
        "minimumPSNRMicrodecibels": 40_000_000,
        "maximumMeanAbsoluteErrorMicrounits": 2_000_000,
        "maximumAbsoluteError": 8,
        "requiredAbsoluteErrorAtMost8PPM": 1_000_000,
    }:
        raise AssertionError("near-final quality rule drifted")
    if robustness_rule != {
        "maximumPSNRDifferenceMicrodecibels": 500_000,
        "maximumMeanAbsoluteErrorDifferenceMicrounits": 1_000_000,
    }:
        raise AssertionError("chunk-schedule quality rule drifted")

    aggregate_cases = {case["caseID"]: case for case in aggregate["cases"]}
    recorded_cases = experiment.get("cases", {})
    if set(recorded_cases) != set(aggregate_cases):
        raise AssertionError("quality summary case set mismatch")
    for case_id, case in aggregate_cases.items():
        recorded = recorded_cases[case_id]
        if recorded.get("chunkSizeBytes") != case["chunkSizeBytes"]:
            raise AssertionError(f"{case_id}: quality chunk size mismatch")
        if recorded.get("chunkCount") != case["chunkCount"]:
            raise AssertionError(f"{case_id}: quality chunk count mismatch")
        if recorded.get("generations") != case["generations"]:
            raise AssertionError(f"{case_id}: quality generations mismatch")
        expected_classifications = {
            str(item["generation"]): classifications(item)
            for item in case["generations"]
        }
        if recorded.get("classifications") != expected_classifications:
            raise AssertionError(f"{case_id}: quality classifications mismatch")
        for number, result in expected_classifications.items():
            if int(number) <= 2 and not result["coarseRelativeToFinal"]:
                raise AssertionError(f"{case_id} g{number}: coarse classification failed")
            if int(number) >= 3 and not result["nearFinalByDeclaredPixelThresholds"]:
                raise AssertionError(f"{case_id} g{number}: near-final classification failed")

    ordered_ids = sorted(aggregate_cases)
    expected_robustness = robustness(
        aggregate_cases[ordered_ids[0]], aggregate_cases[ordered_ids[1]]
    )
    if experiment.get("chunkScheduleComparison") != expected_robustness:
        raise AssertionError("quality chunk-schedule comparison mismatch")
    for item in expected_robustness:
        if item["psnrDifferenceMicrodecibels"] > 500_000:
            raise AssertionError("quality PSNR is not robust across chunk schedules")
        if item["meanAbsoluteErrorDifferenceMicrounits"] > 1_000_000:
            raise AssertionError("quality MAE is not robust across chunk schedules")

    decision = experiment.get("decision", {})
    if decision.get("passed") is not True:
        raise AssertionError("progressive quality experiment must remain passed")
    if not decision.get("supportedClaims") or not decision.get("unsupportedClaims"):
        raise AssertionError("progressive quality claim boundary is incomplete")
    if not experiment.get("remainingEvidence"):
        raise AssertionError("progressive quality remaining evidence is missing")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("experiment", type=Path)
    args = parser.parse_args()
    validate(args.experiment)
    print(f"Progressive JPEG generation-quality experiment passed: {args.experiment}")


if __name__ == "__main__":
    main()
