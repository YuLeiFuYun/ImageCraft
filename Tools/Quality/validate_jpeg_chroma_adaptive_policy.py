#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

from capture_jpeg_chroma_ground_truth import (
    adaptive_gradient_outlier_2x_reconstruction,
    expected_subsampled_cb,
    model_boundary_errors,
    source_cb_truth,
    strictly_better,
)
from capture_libjpeg_progressive_suspension import ROOT
from capture_progressive_jpeg_imcu_chroma_context import reconstructed_cb_rows

DEFAULT_PROFILE = ROOT / "Evidence/Experiments/JPEGChromaAdaptivePolicy/v3/profile.json"
DEFAULT_REPORT = ROOT / ".artifacts/program/T101/jpeg-chroma-adaptive-policy-v3.json"


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text())


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def no_worse(left: dict[str, Any], right: dict[str, Any]) -> bool:
    return all(
        float(left[key]) <= float(right[key])
        for key in (
            "rootMeanSquareCodeDifference",
            "meanAbsoluteCodeDifference",
            "maximumCodeDifference",
        )
    )


def validate(profile_path: Path, report_path: Path) -> dict[str, Any]:
    profile_path = profile_path.resolve()
    report_path = report_path.resolve()
    profile = load_json(profile_path)
    report = load_json(report_path)

    if int(profile.get("schemaVersion", 0)) != 3:
        raise ValueError("unexpected adaptive profile schema")
    if profile.get("profileID") != "IMAGECRAFT-JPEG-CHROMA-ADAPTIVE-POLICY-V3":
        raise ValueError("unexpected adaptive profile ID")
    if int(report.get("schemaVersion", 0)) != 3:
        raise ValueError("unexpected adaptive report schema")
    if report.get("evidenceVersion") != "imagecraft-jpeg-chroma-adaptive-policy-v3":
        raise ValueError("unexpected adaptive evidence version")
    if report.get("status") != "source-bound-reconstruction-quality-mechanism":
        raise ValueError("unexpected adaptive report status")
    if not report.get("formalSourceBoundExecution", False):
        raise ValueError("adaptive report is not source-bound formal execution")
    if report.get("productionBackendQualified", True):
        raise ValueError("adaptive experiment incorrectly claims production qualification")
    if report.get("profile", {}).get("sha256") != sha256_file(profile_path):
        raise ValueError("adaptive profile hash drift")
    if not report.get("sourceIdentity", {}).get("stableBeforeAfter", False):
        raise ValueError("source identity changed during adaptive capture")

    profile_cases = {str(case["id"]): case for case in profile["generatedCases"]}
    report_cases = {str(case["id"]): case for case in report["cases"]}
    if set(profile_cases) != set(report_cases):
        raise ValueError("adaptive case set drift")
    if len(report_cases) != 24:
        raise ValueError("adaptive matrix must contain exactly 24 cases")

    counts = {"matchesGlobal": 0, "strictlyBetterThanGlobalAndNotWorseThanClamp": 0, "notWorseThanGlobal": 0}
    metrics: dict[str, dict[str, float]] = {}
    for case_id, expected_case in profile_cases.items():
        actual = report_cases[case_id]
        for key in ("signal", "codingMode", "sampling"):
            if actual[key] != expected_case[key]:
                raise ValueError(f"{case_id}: {key} drift")

        signal = str(actual["signal"])
        truth = source_cb_truth(signal)
        subsampled = expected_subsampled_cb(signal)
        generator = actual["generator"]
        if generator.get("sourceCbRows") != truth:
            raise ValueError(f"{case_id}: source truth drift")
        if generator.get("subsampledCbRows") != subsampled:
            raise ValueError(f"{case_id}: subsampling drift")

        post_idct = actual["postIDCT"]["Cb"]["rowCodes"]
        if not isinstance(post_idct, list) or len(post_idct) != 32:
            raise ValueError(f"{case_id}: post-IDCT Cb geometry drift")
        global_rows = reconstructed_cb_rows(
            post_idct,
            output_height=64,
            output_imcu_rows=16,
            clamp_imcu_context=False,
        )
        clamped_rows = reconstructed_cb_rows(
            post_idct,
            output_height=64,
            output_imcu_rows=16,
            clamp_imcu_context=True,
        )
        adaptive_rows = adaptive_gradient_outlier_2x_reconstruction(
            post_idct,
            output_height=64,
        )
        global_error = model_boundary_errors(truth, global_rows, output_imcu_rows=16)
        clamped_error = model_boundary_errors(truth, clamped_rows, output_imcu_rows=16)
        adaptive_error = model_boundary_errors(truth, adaptive_rows, output_imcu_rows=16)

        models = actual["sourceTruthModels"]
        if models["globalCenteredLinear"] != global_error:
            raise ValueError(f"{case_id}: global model report drift")
        if models["imcuClampedCenteredLinear"] != clamped_error:
            raise ValueError(f"{case_id}: clamped model report drift")
        if models.get("adaptiveGradientOutlier2x") != adaptive_error:
            raise ValueError(f"{case_id}: adaptive model report drift")

        expectation = str(expected_case["adaptiveExpectation"])
        if models.get("adaptiveExpectation") != expectation:
            raise ValueError(f"{case_id}: adaptive expectation drift")
        if not models.get("adaptiveExpectationSatisfied", False):
            raise ValueError(f"{case_id}: capture did not satisfy adaptive expectation")
        counts[expectation] += 1

        adaptive_all = adaptive_error["allRows"]
        global_all = global_error["allRows"]
        clamped_all = clamped_error["allRows"]
        if expectation == "matchesGlobal":
            if adaptive_rows != global_rows:
                raise ValueError(f"{case_id}: smooth control diverged from global reconstruction")
        elif expectation == "strictlyBetterThanGlobalAndNotWorseThanClamp":
            if not strictly_better(adaptive_all, global_all):
                raise ValueError(f"{case_id}: adaptive rule did not strictly improve global")
            if not no_worse(adaptive_all, clamped_all):
                raise ValueError(f"{case_id}: adaptive rule is worse than iMCU clamping")
        elif expectation == "notWorseThanGlobal":
            if not no_worse(adaptive_all, global_all):
                raise ValueError(f"{case_id}: difficult control regressed versus global")
        else:
            raise ValueError(f"{case_id}: unsupported adaptive expectation")

        metrics[case_id] = {
            "globalRMSE": float(global_all["rootMeanSquareCodeDifference"]),
            "clampedRMSE": float(clamped_all["rootMeanSquareCodeDifference"]),
            "adaptiveRMSE": float(adaptive_all["rootMeanSquareCodeDifference"]),
        }

    if counts != {
        "matchesGlobal": 8,
        "strictlyBetterThanGlobalAndNotWorseThanClamp": 12,
        "notWorseThanGlobal": 4,
    }:
        raise ValueError(f"adaptive expectation cardinality drift: {counts}")
    if not report.get("summary", {}).get("allAdaptiveExpectationsSatisfied", False):
        raise ValueError("adaptive summary lost expectation gate")

    return {
        "caseCount": len(report_cases),
        "expectationCounts": counts,
        "metrics": metrics,
        "sourceIdentitySHA256": report["sourceIdentity"]["sourceIdentitySHA256"],
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, default=DEFAULT_PROFILE)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    args = parser.parse_args()
    print(json.dumps(validate(args.profile, args.report), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
