#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import subprocess
import sys
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from analyze_progressive_scan_policies import analyze  # noqa: E402
from validate_progressive_experiment import (  # noqa: E402
    ROOT,
    canonical_source_identity,
    resolve_repository_path,
    sha256,
    validate_git_binding,
)

EXPECTED_COMMIT = "8cbf3886ee69c03d813f97289a3b17a5b1c90aa7"
EXPECTED_TREE = "d6eb977aafd5973871871bd423c6cd9f97ee9478"
EXPECTED_EXPERIMENT_ID = "progressive-jpeg-scan-checkpoint-policy-v1"
EXPECTED_MATRIX_VERSION = "imagecraft-progressive-scan-checkpoint-matrix-v1"
EXPECTED_EVIDENCE_VERSION = "imagecraft-progressive-scan-checkpoint-v1"
KNOWN_LABELS = {
    "entropy-end-before-marker",
    "terminating-marker-code-end",
    "immediate-following-segment-end",
    "next-scan-entropy-start",
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def expected_raw_names(manifest: dict[str, Any]) -> set[str]:
    return {
        f"{variant['id']}-{suffix}.json"
        for variant in manifest["variants"]
        for suffix in ("a", "b")
    }


def validate_metrics(
    context: str,
    metrics: dict[str, Any],
    expected_channel_count: int,
) -> None:
    channel_count = metrics.get("channelCount")
    require(channel_count == expected_channel_count, f"{context}: channel count mismatch")
    different = metrics.get("differentChannelCount")
    maximum = metrics.get("maximumAbsoluteError")
    absolute_sum = metrics.get("absoluteErrorSum")
    squared_sum = metrics.get("squaredErrorSum")
    require(isinstance(different, int) and 0 <= different <= channel_count, f"{context}: invalid different count")
    require(isinstance(maximum, int) and 0 <= maximum <= 255, f"{context}: invalid maximum error")
    require(isinstance(absolute_sum, int) and 0 <= absolute_sum <= 255 * channel_count, f"{context}: invalid absolute sum")
    require(isinstance(squared_sum, int) and 0 <= squared_sum <= 255 * 255 * channel_count, f"{context}: invalid squared sum")
    require(
        metrics.get("meanAbsoluteErrorMicrounits")
        == absolute_sum * 1_000_000 // channel_count,
        f"{context}: MAE is not reproducible",
    )
    require(
        metrics.get("meanSquaredErrorMicrounits")
        == squared_sum * 1_000_000 // channel_count,
        f"{context}: MSE is not reproducible",
    )
    mse = squared_sum / channel_count
    psnr = 999.0 if mse == 0 else 10.0 * math.log10((255.0 * 255.0) / mse)
    require(
        metrics.get("psnrMicrodecibels") == round(psnr * 1_000_000),
        f"{context}: PSNR is not reproducible",
    )
    coverages = [
        metrics.get("absoluteErrorAtMost8PPM"),
        metrics.get("absoluteErrorAtMost16PPM"),
        metrics.get("absoluteErrorAtMost32PPM"),
        metrics.get("absoluteErrorAtMost64PPM"),
    ]
    require(
        all(isinstance(value, int) and 0 <= value <= 1_000_000 for value in coverages),
        f"{context}: invalid coverage",
    )
    require(coverages == sorted(coverages), f"{context}: coverage is not monotone")


def validate_attempt(
    context: str,
    attempt: dict[str, Any],
    expected_channel_count: int,
    expected_width: int,
    expected_height: int,
) -> None:
    require(isinstance(attempt.get("sourceStatusRawValue"), int), f"{context}: invalid source status")
    require(isinstance(attempt.get("frameStatusRawValue"), int), f"{context}: invalid frame status")
    require(isinstance(attempt.get("propertiesAvailable"), bool), f"{context}: invalid property flag")
    require(isinstance(attempt.get("rasterAvailable"), bool), f"{context}: invalid raster flag")
    if not attempt["rasterAvailable"]:
        require(
            all(
                attempt.get(field) is None
                for field in (
                    "outputPixelWidth",
                    "outputPixelHeight",
                    "pixelRGBSHA256",
                    "metricsAgainstFinal",
                )
            ),
            f"{context}: unavailable raster retained output",
        )
        return
    require(attempt.get("outputPixelWidth") == expected_width, f"{context}: output width mismatch")
    require(attempt.get("outputPixelHeight") == expected_height, f"{context}: output height mismatch")
    require(
        isinstance(attempt.get("pixelRGBSHA256"), str)
        and len(attempt["pixelRGBSHA256"]) == 64,
        f"{context}: missing pixel digest",
    )
    validate_metrics(context, attempt["metricsAgainstFinal"], expected_channel_count)


def validate_report(report: dict[str, Any], manifest_hash: str) -> None:
    case_id = report.get("caseID", "unknown")
    require(report.get("schemaVersion") == 1, f"{case_id}: unsupported schema")
    require(report.get("evidenceVersion") == EXPECTED_EVIDENCE_VERSION, f"{case_id}: evidence version mismatch")
    require(report.get("buildConfiguration") == "release", f"{case_id}: not a Release capture")
    require(report.get("manifestSHA256") == manifest_hash, f"{case_id}: manifest mismatch")
    encoded_count = report.get("encodedByteCount")
    require(isinstance(encoded_count, int) and encoded_count > 0, f"{case_id}: invalid encoded count")
    require(isinstance(report.get("encodedSHA256"), str) and len(report["encodedSHA256"]) == 64, f"{case_id}: missing encoded digest")
    width = report.get("outputPixelWidth")
    height = report.get("outputPixelHeight")
    require(isinstance(width, int) and width > 0 and isinstance(height, int) and height > 0, f"{case_id}: invalid output dimensions")
    channel_count = width * height * 3
    scans = report.get("scans")
    require(isinstance(scans, list) and len(scans) == report.get("declaredScanCount"), f"{case_id}: scan count mismatch")
    require([scan.get("scan") for scan in scans] == list(range(1, len(scans) + 1)), f"{case_id}: scan sequence mismatch")
    previous_entropy_start = 0
    previous_checkpoint_offset = 0
    for scan in scans:
        scan_number = scan["scan"]
        entropy_start = scan.get("entropyStartOffset")
        entropy_end = scan.get("entropyEndMarkerStartOffset")
        marker_end = scan.get("terminatingMarkerCodeEndOffset")
        immediate_end = scan.get("immediateFollowingSegmentEndOffset")
        next_start = scan.get("nextScanEntropyStartOffset")
        require(
            isinstance(entropy_start, int)
            and previous_entropy_start < entropy_start < entropy_end < marker_end <= immediate_end <= encoded_count,
            f"{case_id}: invalid scan boundary {scan_number}",
        )
        require(next_start is None or immediate_end <= next_start <= encoded_count, f"{case_id}: invalid next scan start {scan_number}")
        require(isinstance(scan.get("terminatingMarkerHex"), str), f"{case_id}: missing marker identity")
        checkpoints = scan.get("checkpoints")
        require(isinstance(checkpoints, list) and checkpoints, f"{case_id}: missing checkpoints {scan_number}")
        offsets = [checkpoint.get("offset") for checkpoint in checkpoints]
        require(offsets == sorted(set(offsets)), f"{case_id}: checkpoint offsets are not strict {scan_number}")
        require(offsets[0] >= previous_checkpoint_offset, f"{case_id}: checkpoint order regressed")
        entropy_checkpoint_count = 0
        fresh_hashes = set()
        sequential_hashes = set()
        for checkpoint in checkpoints:
            offset = checkpoint["offset"]
            labels = checkpoint.get("labels")
            require(isinstance(labels, list) and labels == sorted(set(labels)), f"{case_id}: invalid labels")
            require(set(labels) <= KNOWN_LABELS, f"{case_id}: unknown checkpoint label")
            expected_offsets = {
                "entropy-end-before-marker": entropy_end,
                "terminating-marker-code-end": marker_end,
                "immediate-following-segment-end": immediate_end,
                "next-scan-entropy-start": next_start,
            }
            for label in labels:
                require(offset == expected_offsets[label], f"{case_id}: checkpoint label offset mismatch")
            if "entropy-end-before-marker" in labels:
                entropy_checkpoint_count += 1
            require(
                checkpoint.get("encodedByteFractionPPM")
                == offset * 1_000_000 // encoded_count,
                f"{case_id}: checkpoint fraction mismatch",
            )
            context = f"{case_id}:scan-{scan_number}:offset-{offset}"
            fresh = checkpoint["freshSource"]
            sequential = checkpoint["sequentialSource"]
            validate_attempt(context + ":fresh", fresh, channel_count, width, height)
            validate_attempt(context + ":sequential", sequential, channel_count, width, height)
            require(
                fresh["rasterAvailable"] == sequential["rasterAvailable"],
                f"{context}: fresh/sequential availability differs",
            )
            require(
                fresh["pixelRGBSHA256"] == sequential["pixelRGBSHA256"],
                f"{context}: fresh/sequential pixels differ",
            )
            if fresh["rasterAvailable"]:
                fresh_hashes.add(fresh["pixelRGBSHA256"])
                sequential_hashes.add(sequential["pixelRGBSHA256"])
        require(entropy_checkpoint_count == 1, f"{case_id}: missing entropy-end checkpoint")
        require(len(fresh_hashes) == 1 and fresh_hashes == sequential_hashes, f"{case_id}: pixels changed within scan {scan_number}")
        previous_entropy_start = entropy_start
        previous_checkpoint_offset = offsets[-1]


def rebuild_aggregate(manifest_path: str, raw_paths: list[Path]) -> dict[str, Any]:
    completed = subprocess.run(
        [
            sys.executable,
            str(ROOT / "Tools/Performance/aggregate_progressive_scan_checkpoints.py"),
            "--manifest",
            manifest_path,
            *[str(path) for path in raw_paths],
        ],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(completed.stdout)


def rebuild_policy_analysis(aggregate_path: Path) -> dict[str, Any]:
    completed = subprocess.run(
        [
            sys.executable,
            str(ROOT / "Tools/Performance/analyze_progressive_scan_policies.py"),
            str(aggregate_path),
        ],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(completed.stdout)


def validate(path: Path) -> None:
    experiment = json.loads(path.read_text(encoding="utf-8"))
    require(experiment.get("schemaVersion") == 1, "unsupported checkpoint experiment schema")
    require(experiment.get("experimentID") == EXPECTED_EXPERIMENT_ID, "unexpected checkpoint experiment identity")
    artifacts = experiment.get("artifacts", {})
    require(set(artifacts) == {"manifest", "aggregate", "policyAnalysis", "rawReports"}, "checkpoint artifact set mismatch")

    manifest_meta = artifacts["manifest"]
    manifest_path = resolve_repository_path(manifest_meta["path"])
    require(sha256(manifest_path) == manifest_meta.get("sha256"), "checkpoint manifest digest mismatch")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    require(manifest.get("corpusVersion") == "progressive-real-photo-v1", "checkpoint corpus mismatch")

    aggregate_meta = artifacts["aggregate"]
    aggregate_path = resolve_repository_path(aggregate_meta["path"])
    require(sha256(aggregate_path) == aggregate_meta.get("sha256"), "checkpoint aggregate digest mismatch")
    aggregate = json.loads(aggregate_path.read_text(encoding="utf-8"))
    require(aggregate.get("matrixVersion") == EXPECTED_MATRIX_VERSION, "checkpoint matrix version mismatch")

    analysis_meta = artifacts["policyAnalysis"]
    analysis_path = resolve_repository_path(analysis_meta["path"])
    require(sha256(analysis_path) == analysis_meta.get("sha256"), "policy analysis digest mismatch")
    policy_analysis = json.loads(analysis_path.read_text(encoding="utf-8"))

    raw_meta = artifacts["rawReports"]
    expected_names = expected_raw_names(manifest)
    require(set(raw_meta) == expected_names, "checkpoint raw artifact set mismatch")
    raw_paths: dict[str, Path] = {}
    raw_bytes: dict[str, bytes] = {}
    for name, metadata in raw_meta.items():
        report_path = resolve_repository_path(metadata["path"])
        require(sha256(report_path) == metadata.get("sha256"), f"checkpoint raw digest mismatch: {name}")
        raw_paths[name] = report_path
        raw_bytes[name] = report_path.read_bytes()
        validate_report(json.loads(raw_bytes[name]), manifest_meta["sha256"])
    for name in sorted(expected_names):
        if not name.endswith("-a.json"):
            continue
        other = name[:-7] + "-b.json"
        require(raw_bytes[name] == raw_bytes[other], f"checkpoint repeat drifted: {name}")

    rebuilt = rebuild_aggregate(manifest_meta["path"], [raw_paths[name] for name in sorted(raw_paths)])
    require(aggregate == rebuilt, "checkpoint aggregate is not reproducible")
    require(policy_analysis == rebuild_policy_analysis(aggregate_path), "policy analysis is not reproducible")
    require(policy_analysis == analyze(aggregate), "policy analysis library result drifted")

    implementation = experiment.get("implementation", {})
    require(implementation.get("commit") == EXPECTED_COMMIT, "unexpected checkpoint implementation commit")
    require(implementation.get("commitTree") == EXPECTED_TREE, "unexpected checkpoint implementation tree")
    require(implementation.get("cleanWorktreeAtCapture") is True, "checkpoint capture was not clean")
    identity_path = resolve_repository_path(implementation["sourceIdentityReportPath"])
    require(sha256(identity_path) == implementation.get("sourceIdentityReportSHA256"), "checkpoint source identity digest mismatch")
    identity = json.loads(identity_path.read_text(encoding="utf-8"))
    require(canonical_source_identity(identity) == identity.get("sourceIdentitySHA256"), "checkpoint source identity is inconsistent")
    for field, value in {
        "sourceIdentitySchemaVersion": identity["schemaVersion"],
        "sourceIdentityID": identity["identityID"],
        "sourceIdentityFileCount": identity["fileCount"],
        "sourceIdentitySHA256": identity["sourceIdentitySHA256"],
    }.items():
        require(implementation.get(field) == value, f"checkpoint implementation mismatch: {field}")
    validate_git_binding(EXPECTED_COMMIT, EXPECTED_TREE, identity)

    for field in ("runtime", "environment", "decoderFingerprint"):
        require(experiment["environment"].get(field) == aggregate.get(field), f"checkpoint environment drifted: {field}")

    methodology = experiment.get("methodology", {})
    require(methodology.get("variantCount") == 12, "checkpoint variant count drifted")
    require(methodology.get("executionsPerVariant") == 2, "checkpoint repeat count drifted")
    require(methodology.get("freshAndSequentialIncrementalSources") is True, "checkpoint source modes missing")
    require(methodology.get("timingMeasured") is False, "checkpoint experiment must not claim timing")

    findings = experiment.get("findings", {})
    require(findings.get("checkpointFindings") == policy_analysis["checkpointFindings"], "checkpoint findings drifted")
    require(findings.get("leaders") == policy_analysis["leaders"], "policy leaders drifted")
    require(findings.get("currentPolicy") == policy_analysis["currentPolicy"], "current policy findings drifted")
    require(findings.get("paretoFrontierCount") == len(policy_analysis["paretoFrontier"]), "Pareto count drifted")

    decision = experiment.get("decision", {})
    require(decision.get("passed") is True, "checkpoint experiment qualification failed")
    require(decision.get("productionThresholds") == [1, 2, 4, 8], "checkpoint production decision drifted")
    require(decision.get("changeProductionThresholds") is False, "checkpoint experiment must not silently change policy")
    require(decision.get("supportedClaims") and decision.get("unsupportedClaims"), "checkpoint claim boundary incomplete")
    require(experiment.get("remainingEvidence"), "checkpoint remaining evidence missing")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("experiment", type=Path)
    args = parser.parse_args()
    validate(args.experiment)
    print(f"Progressive JPEG scan-checkpoint experiment passed: {args.experiment}")


if __name__ == "__main__":
    main()
