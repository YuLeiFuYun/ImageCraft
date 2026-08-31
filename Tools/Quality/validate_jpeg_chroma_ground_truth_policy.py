#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

from capture_jpeg_chroma_ground_truth import source_cb_truth
from capture_libjpeg_progressive_suspension import ROOT

DEFAULT_PROFILE = ROOT / "Evidence/Experiments/JPEGChromaGroundTruthPolicy/v2/profile.json"
DEFAULT_REPORT = ROOT / ".artifacts/program/T101/jpeg-chroma-ground-truth-policy-v2.json"


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text())


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def strictly_better(left: dict[str, Any], right: dict[str, Any]) -> bool:
    return (
        float(left["rootMeanSquareCodeDifference"])
        < float(right["rootMeanSquareCodeDifference"])
        and float(left["meanAbsoluteCodeDifference"])
        < float(right["meanAbsoluteCodeDifference"])
    )


def expected_subsampled(signal: str) -> list[int]:
    truth = source_cb_truth(signal)
    return [(truth[2 * row] + truth[2 * row + 1]) // 2 for row in range(32)]


def require_winner(
    left: dict[str, Any],
    right: dict[str, Any],
    *,
    expected: str,
    left_name: str,
    right_name: str,
    label: str,
) -> None:
    if expected == left_name:
        ok = strictly_better(left, right)
    elif expected == right_name:
        ok = strictly_better(right, left)
    else:
        raise ValueError(f"unsupported {label} expected winner: {expected}")
    if not ok:
        raise ValueError(f"{label} expected winner did not win: {expected}")


def validate(profile_path: Path, report_path: Path) -> dict[str, Any]:
    profile_path = profile_path.resolve()
    report_path = report_path.resolve()
    profile = load_json(profile_path)
    report = load_json(report_path)

    if int(profile.get("schemaVersion", 0)) != 2:
        raise ValueError("unexpected policy profile schema")
    if profile.get("profileID") != "IMAGECRAFT-JPEG-CHROMA-GROUND-TRUTH-POLICY-V2":
        raise ValueError("unexpected policy profile ID")
    if int(report.get("schemaVersion", 0)) != 2:
        raise ValueError("unexpected policy report schema")
    if report.get("evidenceVersion") != "imagecraft-jpeg-chroma-ground-truth-policy-v2":
        raise ValueError("unexpected policy evidence version")
    if report.get("status") != "source-bound-reconstruction-quality-mechanism":
        raise ValueError("unexpected policy report status")
    if not report.get("formalSourceBoundExecution", False):
        raise ValueError("policy report is not source-bound formal execution")
    if report.get("productionBackendQualified", True):
        raise ValueError("policy experiment incorrectly claims production qualification")
    if report.get("profile", {}).get("sha256") != sha256_file(profile_path):
        raise ValueError("policy profile hash drift")
    if not report.get("sourceIdentity", {}).get("stableBeforeAfter", False):
        raise ValueError("source identity changed during policy capture")

    profile_cases = {str(case["id"]): case for case in profile["generatedCases"]}
    report_cases = {str(case["id"]): case for case in report["cases"]}
    if set(profile_cases) != set(report_cases):
        raise ValueError("policy case set drift")
    if len(report_cases) != 16:
        raise ValueError("policy matrix must contain exactly 16 cases")

    smooth_count = 0
    step_count = 0
    model_winners: dict[str, str] = {}
    backend_winners: dict[str, str] = {}
    for case_id, expected_case in profile_cases.items():
        actual = report_cases[case_id]
        for key in ("signal", "codingMode", "sampling"):
            if actual[key] != expected_case[key]:
                raise ValueError(f"{case_id}: {key} drift")
        signal = str(actual["signal"])
        truth = source_cb_truth(signal)
        subsampled = expected_subsampled(signal)
        generator = actual["generator"]
        if generator.get("sourceCbRows") != truth:
            raise ValueError(f"{case_id}: generator source truth drift")
        if generator.get("subsampledCbRows") != subsampled:
            raise ValueError(f"{case_id}: generator subsampling drift")

        models = actual["sourceTruthModels"]
        global_boundary = models["globalCenteredLinear"]["heldOutInternalIMCUBoundary"]
        clamped_boundary = models["imcuClampedCenteredLinear"]["heldOutInternalIMCUBoundary"]
        expected_model = str(expected_case["expectedModelBoundaryWinner"])
        require_winner(
            global_boundary,
            clamped_boundary,
            expected=expected_model,
            left_name="globalCenteredLinear",
            right_name="imcuClampedCenteredLinear",
            label=f"{case_id} model",
        )
        if models.get("expectedBoundaryWinner") != expected_model:
            raise ValueError(f"{case_id}: reported model winner drift")
        if not models.get("expectedWinnerSatisfied", False):
            raise ValueError(f"{case_id}: reported model winner not satisfied")
        model_winners[case_id] = expected_model

        backends = actual["backendSourceTruth"]
        libjpeg_boundary = backends["libjpeg"]["heldOutInternalIMCUBoundary"]
        imagecraft_boundary = backends["imageCraftImageIO"]["heldOutInternalIMCUBoundary"]
        expected_backend = str(expected_case["expectedBackendBoundaryWinner"])
        require_winner(
            libjpeg_boundary,
            imagecraft_boundary,
            expected=expected_backend,
            left_name="libjpeg",
            right_name="imageCraftImageIO",
            label=f"{case_id} backend",
        )
        if backends.get("expectedBoundaryWinner") != expected_backend:
            raise ValueError(f"{case_id}: reported backend winner drift")
        if not backends.get("expectedWinnerSatisfied", False):
            raise ValueError(f"{case_id}: reported backend winner not satisfied")
        backend_winners[case_id] = expected_backend

        if signal == "step-imcu":
            step_count += 1
            if expected_model != "imcuClampedCenteredLinear":
                raise ValueError(f"{case_id}: step model winner is not clamped")
            if expected_backend != "imageCraftImageIO":
                raise ValueError(f"{case_id}: step backend winner is not ImageCraft/ImageIO")
            if float(clamped_boundary["maximumCodeDifference"]) >= float(
                global_boundary["maximumCodeDifference"]
            ):
                raise ValueError(f"{case_id}: step max-error ordering did not favor clamping")
        else:
            smooth_count += 1
            if expected_model != "globalCenteredLinear":
                raise ValueError(f"{case_id}: smooth model winner is not global")
            if expected_backend != "libjpeg":
                raise ValueError(f"{case_id}: smooth backend winner is not libjpeg")

    if smooth_count != 12 or step_count != 4:
        raise ValueError("policy matrix signal-family cardinality drift")
    summary = report.get("summary", {})
    if not summary.get("allExpectedModelWinnersSatisfied", False):
        raise ValueError("policy summary lost model winner gate")
    if not summary.get("allExpectedBackendWinnersSatisfied", False):
        raise ValueError("policy summary lost backend winner gate")

    return {
        "caseCount": len(report_cases),
        "smoothCaseCount": smooth_count,
        "stepCaseCount": step_count,
        "modelWinners": model_winners,
        "backendWinners": backend_winners,
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
