#!/usr/bin/env python3
from __future__ import annotations

import argparse
from collections import Counter
from itertools import combinations
import json
from pathlib import Path
from typing import Any

CURRENT_POLICY = (1, 2, 4, 8)
POLICY_WIDTH = 4
MAX_THRESHOLD = 9


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def divide_round_nearest(numerator: int, denominator: int) -> int:
    require(numerator >= 0 and denominator > 0, "invalid fixed-point division")
    return (numerator + denominator // 2) // denominator


def scan_attempt(scan: dict[str, Any]) -> dict[str, Any]:
    attempts = [
        checkpoint["freshSource"]
        for checkpoint in scan["checkpoints"]
        if checkpoint["freshSource"]["rasterAvailable"]
    ]
    require(attempts, "scan has no rasterizable checkpoint")
    hashes = {attempt["pixelRGBSHA256"] for attempt in attempts}
    require(len(hashes) == 1, "scan pixels changed between checkpoints")
    return attempts[0]


def variant_scan_series(report: dict[str, Any]) -> list[dict[str, int]]:
    series = []
    for scan in report["scans"]:
        attempt = scan_attempt(scan)
        metrics = attempt["metricsAgainstFinal"]
        series.append(
            {
                "scan": scan["scan"],
                "offset": scan["entropyEndMarkerStartOffset"],
                "encodedByteFractionPPM": scan["entropyEndMarkerStartOffset"]
                * 1_000_000
                // report["encodedByteCount"],
                "channelCount": metrics["channelCount"],
                "squaredErrorSum": metrics["squaredErrorSum"],
                "psnrMicrodecibels": metrics["psnrMicrodecibels"],
            }
        )
    return series


def evaluate_policy(
    thresholds: tuple[int, ...],
    reports: list[dict[str, Any]],
) -> dict[str, Any]:
    per_variant = []
    for report in reports:
        series = variant_scan_series(report)
        final_scan = len(series)
        emitted = [
            entry
            for entry in series
            if entry["scan"] in thresholds and entry["scan"] < final_scan
        ]
        require(emitted and emitted[0]["scan"] == 1, "policy must emit scan 1")
        channel_count = emitted[0]["channelCount"]
        require(
            all(entry["channelCount"] == channel_count for entry in emitted),
            "channel count changed within variant",
        )
        encoded_count = report["encodedByteCount"]
        remaining_bytes = encoded_count - emitted[0]["offset"]
        weighted_squared_error = 0
        for index, entry in enumerate(emitted):
            next_offset = (
                emitted[index + 1]["offset"]
                if index + 1 < len(emitted)
                else encoded_count
            )
            weighted_squared_error += entry["squaredErrorSum"] * (
                next_offset - entry["offset"]
            )
        exposure_mse_micro = divide_round_nearest(
            weighted_squared_error * 1_000_000,
            channel_count * remaining_bytes,
        )
        points = [entry["offset"] for entry in emitted] + [encoded_count]
        maximum_gap_ppm = max(
            (right - left) * 1_000_000 // encoded_count
            for left, right in zip(points, points[1:])
        )
        per_variant.append(
            {
                "caseID": report["caseID"],
                "emittedScans": [entry["scan"] for entry in emitted],
                "generationCount": len(emitted),
                "byteWeightedExposureMSEMicrounits": exposure_mse_micro,
                "maximumPreviewGapPPM": maximum_gap_ppm,
                "lastPreviewPSNRMicrodecibels": emitted[-1]["psnrMicrodecibels"],
            }
        )

    exposure_values = [
        entry["byteWeightedExposureMSEMicrounits"] for entry in per_variant
    ]
    gap_values = [entry["maximumPreviewGapPPM"] for entry in per_variant]
    last_psnr_values = [
        entry["lastPreviewPSNRMicrodecibels"] for entry in per_variant
    ]
    generation_counts = [entry["generationCount"] for entry in per_variant]
    return {
        "thresholds": list(thresholds),
        "meanByteWeightedExposureMSEMicrounits": divide_round_nearest(
            sum(exposure_values), len(exposure_values)
        ),
        "worstByteWeightedExposureMSEMicrounits": max(exposure_values),
        "maximumPreviewGapPPM": max(gap_values),
        "minimumLastPreviewPSNRMicrodecibels": min(last_psnr_values),
        "meanGenerationCountMicrounits": divide_round_nearest(
            sum(generation_counts) * 1_000_000,
            len(generation_counts),
        ),
        "generationCountDistribution": {
            str(count): frequency
            for count, frequency in sorted(Counter(generation_counts).items())
        },
        "perVariant": per_variant,
    }


def dominates(left: dict[str, Any], right: dict[str, Any]) -> bool:
    weak = (
        left["meanByteWeightedExposureMSEMicrounits"]
        <= right["meanByteWeightedExposureMSEMicrounits"]
        and left["worstByteWeightedExposureMSEMicrounits"]
        <= right["worstByteWeightedExposureMSEMicrounits"]
        and left["maximumPreviewGapPPM"] <= right["maximumPreviewGapPPM"]
        and left["minimumLastPreviewPSNRMicrodecibels"]
        >= right["minimumLastPreviewPSNRMicrodecibels"]
        and left["meanGenerationCountMicrounits"]
        >= right["meanGenerationCountMicrounits"]
    )
    return weak and any(
        left[field] != right[field]
        for field in (
            "meanByteWeightedExposureMSEMicrounits",
            "worstByteWeightedExposureMSEMicrounits",
            "maximumPreviewGapPPM",
            "minimumLastPreviewPSNRMicrodecibels",
            "meanGenerationCountMicrounits",
        )
    )


def strict_rank(
    policies: list[dict[str, Any]],
    current: dict[str, Any],
    field: str,
    maximize: bool,
) -> int:
    value = current[field]
    if maximize:
        return 1 + sum(policy[field] > value for policy in policies)
    return 1 + sum(policy[field] < value for policy in policies)


def checkpoint_findings(reports: list[dict[str, Any]]) -> dict[str, Any]:
    total_scans = 0
    total_checkpoints = 0
    entropy_end_rasterizable = 0
    fresh_sequential_equal = 0
    stable_within_scan = 0
    fresh_frame_status = Counter()
    sequential_frame_status = Counter()
    default_scan_8_to_9 = []

    for report in reports:
        for scan in report["scans"]:
            total_scans += 1
            total_checkpoints += len(scan["checkpoints"])
            entropy = next(
                checkpoint
                for checkpoint in scan["checkpoints"]
                if "entropy-end-before-marker" in checkpoint["labels"]
            )
            if entropy["freshSource"]["rasterAvailable"]:
                entropy_end_rasterizable += 1
            hashes = set()
            equal = True
            for checkpoint in scan["checkpoints"]:
                fresh = checkpoint["freshSource"]
                sequential = checkpoint["sequentialSource"]
                fresh_frame_status[str(fresh["frameStatusRawValue"])] += 1
                sequential_frame_status[str(sequential["frameStatusRawValue"])] += 1
                if (
                    fresh["rasterAvailable"] != sequential["rasterAvailable"]
                    or fresh["pixelRGBSHA256"] != sequential["pixelRGBSHA256"]
                ):
                    equal = False
                if fresh["rasterAvailable"]:
                    hashes.add(fresh["pixelRGBSHA256"])
            if equal:
                fresh_sequential_equal += 1
            if len(hashes) == 1:
                stable_within_scan += 1

        if report["scanScriptID"] == "default-successive-v1":
            series = variant_scan_series(report)
            scan8 = next(entry for entry in series if entry["scan"] == 8)
            scan9 = next(entry for entry in series if entry["scan"] == 9)
            default_scan_8_to_9.append(
                {
                    "sourceID": report["sourceID"],
                    "additionalEncodedBytes": scan9["offset"] - scan8["offset"],
                    "additionalEncodedByteFractionPPM": (
                        (scan9["offset"] - scan8["offset"])
                        * 1_000_000
                        // report["encodedByteCount"]
                    ),
                    "psnrGainMicrodecibels": (
                        scan9["psnrMicrodecibels"] - scan8["psnrMicrodecibels"]
                    ),
                }
            )

    return {
        "totalScanCount": total_scans,
        "totalCheckpointCount": total_checkpoints,
        "entropyEndBeforeMarkerRasterizableScanCount": entropy_end_rasterizable,
        "freshSequentialEqualScanCount": fresh_sequential_equal,
        "checkpointStableWithinScanCount": stable_within_scan,
        "freshFrameStatusDistributionAtRasterizableCheckpoints": dict(
            sorted(fresh_frame_status.items())
        ),
        "sequentialFrameStatusDistributionAtRasterizableCheckpoints": dict(
            sorted(sequential_frame_status.items())
        ),
        "defaultSuccessiveScan8To9": sorted(
            default_scan_8_to_9, key=lambda entry: entry["sourceID"]
        ),
    }


def analyze(aggregate: dict[str, Any]) -> dict[str, Any]:
    reports = aggregate["reports"]
    policies = [
        evaluate_policy((1, *tail), reports)
        for tail in combinations(range(2, MAX_THRESHOLD + 1), POLICY_WIDTH - 1)
    ]
    current = next(
        policy for policy in policies if tuple(policy["thresholds"]) == CURRENT_POLICY
    )
    pareto = [
        policy
        for policy in policies
        if not any(
            dominates(other, policy)
            for other in policies
            if other["thresholds"] != policy["thresholds"]
        )
    ]
    leaders = {
        "minimumMeanExposure": min(
            policies,
            key=lambda policy: (
                policy["meanByteWeightedExposureMSEMicrounits"],
                policy["thresholds"],
            ),
        )["thresholds"],
        "minimumWorstExposure": min(
            policies,
            key=lambda policy: (
                policy["worstByteWeightedExposureMSEMicrounits"],
                policy["thresholds"],
            ),
        )["thresholds"],
        "minimumMaximumGap": min(
            policies,
            key=lambda policy: (
                policy["maximumPreviewGapPPM"],
                policy["thresholds"],
            ),
        )["thresholds"],
        "maximumMinimumLastPreviewPSNR": max(
            policies,
            key=lambda policy: (
                policy["minimumLastPreviewPSNRMicrodecibels"],
                [-value for value in policy["thresholds"]],
            ),
        )["thresholds"],
    }
    current_summary = {
        key: value for key, value in current.items() if key != "perVariant"
    }
    current_summary["ranks"] = {
        "meanExposure": strict_rank(
            policies,
            current,
            "meanByteWeightedExposureMSEMicrounits",
            maximize=False,
        ),
        "worstExposure": strict_rank(
            policies,
            current,
            "worstByteWeightedExposureMSEMicrounits",
            maximize=False,
        ),
        "maximumGap": strict_rank(
            policies,
            current,
            "maximumPreviewGapPPM",
            maximize=False,
        ),
        "minimumLastPreviewPSNR": strict_rank(
            policies,
            current,
            "minimumLastPreviewPSNRMicrodecibels",
            maximize=True,
        ),
        "meanGenerationCount": strict_rank(
            policies,
            current,
            "meanGenerationCountMicrounits",
            maximize=True,
        ),
        "policyCount": len(policies),
    }
    current_summary["dominatingPolicies"] = [
        policy["thresholds"] for policy in policies if dominates(policy, current)
    ]
    return {
        "schemaVersion": 1,
        "analysisVersion": "imagecraft-progressive-scan-policy-v1",
        "objective": {
            "description": (
                "Pixel-domain diagnostic from the first emitted preview until final bytes; "
                "each preview's final-reference MSE is weighted by the encoded-byte interval "
                "for which that preview would remain displayed."
            ),
            "notIncluded": [
                "time",
                "network scheduling",
                "render or presentation latency",
                "energy",
                "subjective usefulness",
                "blank-state cost before the first preview",
            ],
        },
        "enumeration": {
            "requiredFirstThreshold": 1,
            "thresholdCount": POLICY_WIDTH,
            "maximumThreshold": MAX_THRESHOLD,
            "policyCount": len(policies),
        },
        "checkpointFindings": checkpoint_findings(reports),
        "leaders": leaders,
        "currentPolicy": current_summary,
        "paretoFrontier": [
            {
                key: value
                for key, value in policy.items()
                if key != "perVariant"
            }
            for policy in sorted(
                pareto,
                key=lambda policy: (
                    policy["meanByteWeightedExposureMSEMicrounits"],
                    policy["thresholds"],
                ),
            )
        ],
        "policies": policies,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("aggregate", type=Path)
    args = parser.parse_args()
    aggregate = json.loads(args.aggregate.read_text(encoding="utf-8"))
    print(json.dumps(analyze(aggregate), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
