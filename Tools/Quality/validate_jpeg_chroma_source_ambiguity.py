#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

from capture_libjpeg_progressive_suspension import ROOT
from capture_progressive_jpeg_imcu_chroma_context import reconstructed_cb_rows

DEFAULT_PROFILE = ROOT / "Evidence/Experiments/JPEGChromaSourceAmbiguity/v1/profile.json"


def box_downsample_2x(values: list[int]) -> list[int]:
    if len(values) % 2 != 0:
        raise ValueError("full-resolution truth must have even length")
    return [(values[i] + values[i + 1]) // 2 for i in range(0, len(values), 2)]


def nearest_current_2x(values: list[int]) -> list[int]:
    result: list[int] = []
    for value in values:
        result.extend([value, value])
    return result


def rmse(truth: list[int], observed: list[int]) -> float:
    if len(truth) != len(observed) or not truth:
        raise ValueError("invalid RMSE geometry")
    return math.sqrt(sum((a - b) ** 2 for a, b in zip(truth, observed)) / len(truth))


def validate(profile_path: Path) -> dict[str, object]:
    profile = json.loads(profile_path.read_text())
    if int(profile.get("schemaVersion", 0)) != 1:
        raise ValueError("unexpected ambiguity profile schema")
    if profile.get("profileID") != "IMAGECRAFT-JPEG-CHROMA-SOURCE-AMBIGUITY-V1":
        raise ValueError("unexpected ambiguity profile ID")
    # These two full-resolution signals are deliberately different but collapse to exactly the
    # same low-resolution chroma after the qualified 2-row integer box average.
    thin_stripe = list(profile["sourceTruths"]["phaseShiftedThinStripe"])
    true_plateau = list(profile["sourceTruths"]["trueLowResolutionPlateau"])
    # Luma is deliberately identical across the two worlds. This strengthens the ambiguity result:
    # full-resolution luma helps only under a chroma/luma correlation prior; it is not a universal
    # source-truth authority by itself.
    shared_full_resolution_luma = list(profile["sharedFullResolutionLuma"])
    thin_low = box_downsample_2x(thin_stripe)
    plateau_low = box_downsample_2x(true_plateau)
    if thin_low != list(profile["subsampledCb"]) or plateau_low != thin_low:
        raise ValueError("ambiguity construction drift")

    centered = reconstructed_cb_rows(
        thin_low,
        output_height=8,
        output_imcu_rows=8,
        clamp_imcu_context=False,
    )
    nearest = nearest_current_2x(thin_low)
    if centered != list(profile["reconstructionCandidates"]["centeredThreeQuarterOneQuarter"]):
        raise ValueError("centered reconstruction drift")
    if nearest != list(profile["reconstructionCandidates"]["nearestCurrent"]):
        raise ValueError("nearest reconstruction drift")

    thin_centered = rmse(thin_stripe, centered)
    thin_nearest = rmse(thin_stripe, nearest)
    plateau_centered = rmse(true_plateau, centered)
    plateau_nearest = rmse(true_plateau, nearest)
    if not thin_centered < thin_nearest:
        raise ValueError("thin-stripe truth no longer prefers centered reconstruction")
    if not plateau_nearest < plateau_centered:
        raise ValueError("plateau truth no longer prefers nearest reconstruction")

    return {
        "schemaVersion": 1,
        "evidenceVersion": "imagecraft-jpeg-chroma-source-ambiguity-v1",
        "claim": (
            "No deterministic reconstruction policy whose inputs are limited to the subsampled "
            "chroma samples can universally minimize full-resolution source-truth error, because "
            "distinct source truths can map to the same subsampled samples while preferring "
            "opposite reconstructions."
        ),
        "subsampledCb": thin_low,
        "sharedFullResolutionLuma": shared_full_resolution_luma,
        "sourceTruths": {
            "phaseShiftedThinStripe": thin_stripe,
            "trueLowResolutionPlateau": true_plateau,
        },
        "reconstructions": {
            "centeredThreeQuarterOneQuarter": centered,
            "nearestCurrent": nearest,
        },
        "rmse": {
            "phaseShiftedThinStripe": {
                "centered": thin_centered,
                "nearest": thin_nearest,
                "winner": "centered",
            },
            "trueLowResolutionPlateau": {
                "centered": plateau_centered,
                "nearest": plateau_nearest,
                "winner": "nearest",
            },
        },
        "implication": (
            "Any source-adaptive policy that seeks stronger guarantees than a prior must add "
            "information not present in subsampled chroma alone (for example full-resolution "
            "luma structure), or explicitly accept a perceptual/content prior rather than claim "
            "universal source-truth dominance."
        ),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, default=DEFAULT_PROFILE)
    args = parser.parse_args()
    print(json.dumps(validate(args.profile.resolve()), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
