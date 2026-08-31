#!/usr/bin/env python3
from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import struct
import tempfile

from capture_independent_png16_conformance import (
    _ICC_SRGB_D50_RGB_TO_XYZ,
    CaptureError,
    ROOT,
    build_littlecms_probe,
    capture_source_identity,
    icc_matrix_trc_rgba16be_to_srgb_rgba16be,
    parse_json_stdout,
    rgba16be_max_rgb_code_difference,
    run,
    sha256_bytes,
    sha256_file,
)


DEFAULT_PROFILE = (
    ROOT
    / "Evidence/Experiments/IndependentPNG16/v1/fixtures/epson3170-set1-gamma-matrix.icc"
)
DEFAULT_OUTPUT = ROOT / ".artifacts/program/T101/real-input-lcms-target-matrix-v1.json"


def parse_target_matrix(report: dict[str, object]) -> tuple[tuple[float, float, float], ...]:
    raw = report.get("targetRGBToD50XYZ")
    if not isinstance(raw, list) or len(raw) != 3:
        raise CaptureError("LittleCMS target matrix observation is malformed")
    rows: list[tuple[float, float, float]] = []
    for row in raw:
        if not isinstance(row, list) or len(row) != 3:
            raise CaptureError("LittleCMS target matrix row is malformed")
        rows.append(tuple(float(value) for value in row))
    return tuple(rows)


def differential(
    reference: bytes,
    candidate: bytes,
    points: list[tuple[int, int, int]],
) -> dict[str, object]:
    if len(reference) != len(candidate) or len(reference) != len(points) * 8:
        raise CaptureError("dense differential payload shape mismatch")
    histogram: Counter[int] = Counter()
    maximum = 0
    worst: list[dict[str, object]] = []
    for index, source_rgb in enumerate(points):
        channel_differences: list[int] = []
        for channel in range(3):
            offset = index * 8 + channel * 2
            lhs = int.from_bytes(reference[offset : offset + 2], "big")
            rhs = int.from_bytes(candidate[offset : offset + 2], "big")
            channel_differences.append(abs(lhs - rhs))
        if reference[index * 8 + 6 : index * 8 + 8] != candidate[index * 8 + 6 : index * 8 + 8]:
            raise CaptureError("dense LittleCMS differential changed alpha")
        pixel_maximum = max(channel_differences)
        histogram[pixel_maximum] += 1
        if pixel_maximum > maximum:
            maximum = pixel_maximum
            worst = [{"sourceRGB16": list(source_rgb), "rgbCodeDifferences": channel_differences}]
        elif pixel_maximum == maximum and len(worst) < 16:
            worst.append({"sourceRGB16": list(source_rgb), "rgbCodeDifferences": channel_differences})
    return {
        "maximumRGBCodeDifference": maximum,
        "nonzeroPixelCount": sum(count for delta, count in histogram.items() if delta != 0),
        "histogram": {str(delta): histogram[delta] for delta in sorted(histogram)},
        "worstPoints": worst,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, default=DEFAULT_PROFILE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    profile_path = args.profile.resolve()
    output_path = args.output if args.output.is_absolute() else ROOT / args.output
    profile = profile_path.read_bytes()

    with tempfile.TemporaryDirectory(prefix="imagecraft-real-input-lcms-") as temp_raw:
        temp = Path(temp_raw)
        before = capture_source_identity(temp / "source-before.json")
        littlecms_probe, littlecms_version = build_littlecms_probe(temp)

        levels = [round(index * 65_535 / 16) for index in range(17)]
        points: list[tuple[int, int, int]] = []
        source = bytearray()
        reference = bytearray()
        for red in levels:
            for green in levels:
                for blue in levels:
                    pixel = struct.pack(">HHHH", red, green, blue, 0xFFFF)
                    try:
                        converted = icc_matrix_trc_rgba16be_to_srgb_rgba16be(profile, pixel)
                    except CaptureError:
                        continue
                    points.append((red, green, blue))
                    source += pixel
                    reference += converted

        source_path = temp / "dense-source.rgba16be"
        reference_path = temp / "dense-reference.rgba16be"
        littlecms_path = temp / "dense-littlecms.rgba16be"
        source_path.write_bytes(source)
        reference_path.write_bytes(reference)
        littlecms_completed = run(
            [str(littlecms_probe), str(profile_path), str(source_path), str(littlecms_path)]
        )
        littlecms_report = parse_json_stdout(littlecms_completed, "LittleCMS dense real-input probe")
        littlecms_bytes = littlecms_path.read_bytes()
        target_matrix = parse_target_matrix(littlecms_report)
        counterfactual = icc_matrix_trc_rgba16be_to_srgb_rgba16be(
            profile,
            bytes(source),
            target_rgb_to_d50_xyz=target_matrix,
        )

        reference_delta = differential(bytes(reference), littlecms_bytes, points)
        counterfactual_delta = differential(counterfactual, littlecms_bytes, points)
        if rgba16be_max_rgb_code_difference(counterfactual, littlecms_bytes) > 1:
            raise CaptureError("LittleCMS target-matrix counterfactual did not collapse to <=1 code")

        after = capture_source_identity(temp / "source-after.json")
        before_hash = before.get("sourceIdentitySHA256")
        if before_hash != after.get("sourceIdentitySHA256"):
            raise CaptureError("ImageCraft source identity changed during dense ICC differential")

        report = {
            "schemaVersion": 1,
            "evidenceVersion": "imagecraft-real-input-lcms-target-matrix-differential-v1",
            "status": "source-bound-mechanism-differential",
            "sourceIdentity": {
                "sourceIdentitySHA256": before_hash,
                "fileCount": before.get("fileCount"),
                "stableBeforeAfter": True,
            },
            "profile": {
                "path": str(profile_path.relative_to(ROOT)),
                "sha256": sha256_file(profile_path),
                "byteCount": len(profile),
            },
            "grid": {
                "levelsPerChannel": 17,
                "totalDeviceRGBPoints": 17 ** 3,
                "qualifiedInTargetGamutPoints": len(points),
                "sourceRGBA16BESHA256": sha256_bytes(bytes(source)),
            },
            "littleCMS": {
                **littlecms_report,
                "version": littlecms_version,
                "probeSHA256": sha256_file(littlecms_probe),
            },
            "referenceTargetRGBToD50XYZ": [list(row) for row in _ICC_SRGB_D50_RGB_TO_XYZ],
            "referenceTargetDifferential": reference_delta,
            "littleCMSTargetMatrixCounterfactualDifferential": counterfactual_delta,
            "claimBoundary": [
                "The dense grid diagnoses the independent-CMS observation for one retained real-measurement-derived input-class matrix/TRC profile; it is not a new whole-domain ImageCraft pixel-conformance claim.",
                "The normative ImageCraft oracle remains the ICC reference sRGB D50 target matrix. Replacing only that target matrix with the one observed from LittleCMS cmsCreate_sRGBProfile is a counterfactual used to localize implementation delta, not to redefine the target color space.",
            ],
        }
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(
            "Real-input LittleCMS target-matrix differential captured: "
            f"points={len(points)} referenceMax={reference_delta['maximumRGBCodeDifference']} "
            f"counterfactualMax={counterfactual_delta['maximumRGBCodeDifference']} "
            f"output={output_path}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
