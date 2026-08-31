#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
import platform
import tempfile
from typing import Any

from capture_libjpeg_progressive_suspension import (
    build_imagecraft_evidence,
    CaptureError,
    ROOT,
    capture_source_identity,
    parse_json_stdout,
    parse_ppm_rgb,
    run,
    sha256_bytes,
    sha256_file,
)
from capture_progressive_jpeg_cross_backend_sampling import jpeg_sampling_factors
from capture_progressive_jpeg_imcu_chroma_context import (
    RAW_PROBE_SOURCE,
    boundary_error,
    build_c_tool,
    fit_affine_color_map,
    reconstructed_cb_rows,
    rgba_blue_rows,
    rgb_blue_rows,
    row_error,
    row_uniform_values,
)


DEFAULT_PROFILE = ROOT / "Evidence/Experiments/JPEGChromaGroundTruth/v1/profile.json"
DEFAULT_OUTPUT = ROOT / ".artifacts/program/T101/jpeg-chroma-ground-truth-v1.json"
GENERATOR_SOURCE_V1 = (
    ROOT / "Tools/Quality/LibJPEGTurboRawChromaGroundTruthGenerator/main.c"
)
GENERATOR_SOURCE_V2 = (
    ROOT / "Tools/Quality/LibJPEGTurboRawChromaPolicyGenerator/main.c"
)
GENERATOR_SOURCE_V3 = (
    ROOT / "Tools/Quality/LibJPEGTurboRawChromaAdaptivePolicyGenerator/main.c"
)
# Backward-compatible import for existing v1 conformance tools.
GENERATOR_SOURCE = GENERATOR_SOURCE_V1


def has_jfif_app0(data: bytes) -> bool:
    if not data.startswith(b"\xff\xd8"):
        raise CaptureError("generated JPEG is missing SOI")
    offset = 2
    while offset < len(data):
        if data[offset] != 0xFF:
            raise CaptureError(f"generated JPEG marker is malformed at {offset}")
        while offset < len(data) and data[offset] == 0xFF:
            offset += 1
        if offset >= len(data):
            raise CaptureError("generated JPEG has a truncated marker")
        marker = data[offset]
        offset += 1
        if marker in (0xD8, 0xD9) or 0xD0 <= marker <= 0xD7:
            if marker == 0xD9:
                return False
            continue
        if marker == 0x01:
            continue
        if offset + 2 > len(data):
            raise CaptureError("generated JPEG has a truncated segment length")
        segment_length = int.from_bytes(data[offset : offset + 2], "big")
        if segment_length < 2 or offset + segment_length > len(data):
            raise CaptureError("generated JPEG segment exceeds input")
        payload = data[offset + 2 : offset + segment_length]
        if marker == 0xE0 and payload.startswith(b"JFIF\x00"):
            return True
        if marker == 0xDA:
            return False
        offset += segment_length
    return False


def source_cb_truth(signal: str = "ramp2-up") -> list[int]:
    if signal == "ramp2-up":
        return [65 + 2 * row for row in range(64)]
    if signal == "ramp2-down":
        return [190 - 2 * row for row in range(64)]
    if signal == "zigzag2":
        result: list[int] = []
        for row in range(64):
            if row <= 23:
                result.append(80 + 2 * row)
            elif row <= 39:
                result.append(126 - 2 * (row - 23))
            else:
                result.append(94 + 2 * (row - 39))
        return result
    if signal == "step-imcu":
        return [80 if row < 32 else 176 for row in range(64)]
    if signal == "quadratic":
        return [80 + (80 * row * row + 1984) // 3969 for row in range(64)]
    if signal == "kink":
        return [64 + row if row < 32 else 96 + 3 * (row - 32) for row in range(64)]
    if signal == "step-off24":
        return [80 if row < 24 else 176 for row in range(64)]
    if signal == "step-small":
        return [112 if row < 32 else 120 for row in range(64)]
    if signal == "ramp-step":
        return [64 + 2 * row + (24 if row >= 32 else 0) for row in range(64)]
    if signal == "impulse31":
        return [128 + (32 if row == 31 else 0) for row in range(64)]
    raise CaptureError(f"unsupported source-truth signal: {signal}")


def expected_subsampled_cb(signal: str = "ramp2-up") -> list[int]:
    truth = source_cb_truth(signal)
    return [(truth[2 * row] + truth[2 * row + 1]) // 2 for row in range(32)]


def model_boundary_errors(
    source_truth: list[int],
    reconstructed: list[int],
    *,
    output_imcu_rows: int,
) -> dict[str, Any]:
    observed = [float(value) for value in source_truth]
    predicted = [float(value) for value in reconstructed]
    return {
        "allRows": row_error(observed, predicted),
        "heldOutInternalIMCUBoundary": boundary_error(
            observed,
            predicted,
            output_imcu_rows=output_imcu_rows,
        ),
    }


def backend_source_truth_errors(
    observed_blue: list[float],
    source_truth: list[int],
    *,
    output_imcu_rows: int,
) -> dict[str, Any]:
    fit = fit_affine_color_map(
        source_truth,
        observed_blue,
        output_imcu_rows=output_imcu_rows,
    )
    boundary = boundary_error(
        observed_blue,
        list(fit["predictedBlueByRow"]),
        output_imcu_rows=output_imcu_rows,
    )
    return {
        "affineSourceTruthMap": fit,
        "heldOutInternalIMCUBoundary": boundary,
    }


def adaptive_gradient_outlier_2x_reconstruction(
    chroma_rows: list[int],
    *,
    output_height: int,
) -> list[int]:
    """Centered reconstruction with a local, iMCU-independent discontinuity test.

    An interval is treated as an edge only when its absolute chroma gradient is strictly greater
    than twice the larger same-side neighboring gradient. Edge intervals retain the current sample;
    every other interval uses the existing 3/4-current + 1/4-adjacent centered reconstruction.
    """
    if output_height <= 0 or not chroma_rows:
        raise CaptureError("invalid adaptive reconstruction geometry")

    def is_edge(first: int, second: int) -> bool:
        low = min(first, second)
        high = max(first, second)
        cross = abs(chroma_rows[high] - chroma_rows[low])
        left = (
            abs(chroma_rows[low] - chroma_rows[low - 1])
            if low > 0
            else cross
        )
        right = (
            abs(chroma_rows[high + 1] - chroma_rows[high])
            if high + 1 < len(chroma_rows)
            else cross
        )
        return cross > 2 * max(left, right)

    result: list[int] = []
    for output_row in range(output_height):
        source_row = output_row // 2
        if source_row >= len(chroma_rows):
            raise CaptureError("adaptive reconstruction source row exceeds chroma plane")
        if output_row & 1:
            adjacent = min(len(chroma_rows) - 1, source_row + 1)
            bias = 2
        else:
            adjacent = max(0, source_row - 1)
            bias = 1
        if adjacent != source_row and is_edge(source_row, adjacent):
            result.append(chroma_rows[source_row])
        else:
            result.append(
                (3 * chroma_rows[source_row] + chroma_rows[adjacent] + bias) // 4
            )
    return result


def strictly_better(left: dict[str, Any], right: dict[str, Any]) -> bool:
    return (
        float(left["rootMeanSquareCodeDifference"])
        < float(right["rootMeanSquareCodeDifference"])
        and float(left["meanAbsoluteCodeDifference"])
        < float(right["meanAbsoluteCodeDifference"])
    )


def expected_pairwise_winner(
    left: dict[str, Any],
    right: dict[str, Any],
    *,
    expected: str,
    left_name: str,
    right_name: str,
) -> bool:
    if expected == left_name:
        return strictly_better(left, right)
    if expected == right_name:
        return strictly_better(right, left)
    raise CaptureError(f"unsupported expected winner: {expected}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, default=DEFAULT_PROFILE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    profile_path = args.profile if args.profile.is_absolute() else ROOT / args.profile
    output_path = args.output if args.output.is_absolute() else ROOT / args.output
    profile = json.loads(profile_path.read_text())
    profile_id = profile.get("profileID")
    if profile_id not in {
        "IMAGECRAFT-JPEG-CHROMA-GROUND-TRUTH-V1",
        "IMAGECRAFT-JPEG-CHROMA-GROUND-TRUTH-MATRIX-V1",
        "IMAGECRAFT-JPEG-CHROMA-GROUND-TRUTH-POLICY-V2",
        "IMAGECRAFT-JPEG-CHROMA-ADAPTIVE-POLICY-V3",
    }:
        raise CaptureError("unexpected JPEG chroma ground-truth profile ID")
    policy_v2 = profile_id == "IMAGECRAFT-JPEG-CHROMA-GROUND-TRUTH-POLICY-V2"
    policy_v3 = profile_id == "IMAGECRAFT-JPEG-CHROMA-ADAPTIVE-POLICY-V3"
    generator_source = (
        GENERATOR_SOURCE_V3
        if policy_v3
        else (GENERATOR_SOURCE_V2 if policy_v2 else GENERATOR_SOURCE_V1)
    )

    output_imcu_rows = int(profile["outputIMCURowCount"])
    if output_imcu_rows != 16:
        raise CaptureError("unexpected JPEG chroma ground-truth iMCU row contract")
    expected_factors = {
        "440": [[1, 2], [1, 1], [1, 1]],
        "420": [[2, 2], [1, 1], [1, 1]],
    }

    with tempfile.TemporaryDirectory(prefix="imagecraft-jpeg-chroma-truth-") as temp_raw:
        temp = Path(temp_raw)
        before = capture_source_identity(temp / "source-before.json")
        jpeg_prefix = Path(run(["brew", "--prefix", "jpeg-turbo"]).stdout.strip())
        djpeg = jpeg_prefix / "bin/djpeg"
        if not djpeg.is_file():
            raise CaptureError("pinned djpeg is unavailable")
        djpeg_version = run([str(djpeg), "-version"]).stderr.strip()
        required_version = profile.get("requiredLibJPEGTurboVersionPrefix")
        if not isinstance(required_version, str) or not djpeg_version.startswith(
            required_version
        ):
            raise CaptureError("djpeg runtime is outside chroma ground-truth qualification")

        generator = build_c_tool(
            temp,
            generator_source,
            "raw-chroma-ground-truth-generator",
            jpeg_prefix,
        )
        raw_probe = build_c_tool(
            temp,
            RAW_PROBE_SOURCE,
            "raw-ycbcr-probe",
            jpeg_prefix,
        )
        imagecraft_evidence: Path | None = None
        if not policy_v3:
            build = run(
                [
                    "swift",
                    "build",
                    "-c",
                    "release",
                    "--product",
                    "ImageCraftEvidence",
                    "--jobs",
                    "1",
                ],
                cwd=ROOT,
            )
            if "Build complete!" not in build.stdout:
                raise CaptureError("ImageCraftEvidence release build did not report completion")
            imagecraft_evidence = build_imagecraft_evidence()
            if not imagecraft_evidence.is_file():
                raise CaptureError("ImageCraftEvidence release binary is unavailable")

        results: list[dict[str, Any]] = []
        for case in profile["generatedCases"]:
            case_id = str(case["id"])
            coding_mode = str(case["codingMode"])
            sampling = str(case["sampling"])
            signal = str(case.get("signal", "ramp2-up"))
            expected_truth = source_cb_truth(signal)
            expected_subsampled = expected_subsampled_cb(signal)
            if sampling not in expected_factors:
                raise CaptureError(f"unsupported ground-truth sampling: {case_id}")

            generated = temp / f"{case_id}.jpg"
            generated_completed = run(
                [str(generator), sampling, str(generated), coding_mode, signal]
            )
            if generated_completed.stderr.strip():
                raise CaptureError(
                    f"ground-truth generator emitted diagnostics: {case_id}: "
                    f"{generated_completed.stderr.strip()}"
                )
            generator_report = parse_json_stdout(
                generated_completed, f"ground-truth generator {case_id}"
            )
            if (
                generator_report.get("codingMode") != coding_mode
                or generator_report.get("sampling") != sampling
                or generator_report.get("signal") != signal
                or generator_report.get("sourceCbRows") != expected_truth
                or generator_report.get("subsampledCbRows") != expected_subsampled
            ):
                raise CaptureError(f"ground-truth generator contract drifted: {case_id}")

            encoded = generated.read_bytes()
            if not has_jfif_app0(encoded):
                raise CaptureError(f"generated ground-truth JPEG is not JFIF-tagged: {case_id}")
            factors = [
                [item["horizontal"], item["vertical"]]
                for item in jpeg_sampling_factors(encoded)
            ]
            if factors != expected_factors[sampling]:
                raise CaptureError(
                    f"ground-truth sampling factors drifted: {case_id}: {factors}"
                )

            raw_prefix = temp / f"{case_id}.raw"
            raw_completed = run([str(raw_probe), str(generated), str(raw_prefix)])
            if raw_completed.stderr.strip():
                raise CaptureError(
                    f"ground-truth raw probe emitted diagnostics: {case_id}: "
                    f"{raw_completed.stderr.strip()}"
                )
            raw_report = parse_json_stdout(raw_completed, f"ground-truth raw probe {case_id}")
            components = raw_report.get("components")
            if (
                raw_report.get("warningCount") != 0
                or raw_report.get("width") != 64
                or raw_report.get("height") != 64
                or not isinstance(components, list)
                or len(components) != 3
            ):
                raise CaptureError(f"ground-truth raw probe contract drifted: {case_id}")
            expected_progressive = coding_mode == "progressive"
            if raw_report.get("progressiveMode") is not expected_progressive:
                raise CaptureError(f"ground-truth coding mode drifted: {case_id}")

            y_plane = Path(f"{raw_prefix}-Y.raw").read_bytes()
            cb_plane = Path(f"{raw_prefix}-Cb.raw").read_bytes()
            cr_plane = Path(f"{raw_prefix}-Cr.raw").read_bytes()
            y_rows = row_uniform_values(y_plane, width=64, height=64)
            cb_width = int(components[1]["width"])
            cb_height = int(components[1]["height"])
            post_idct_cb = row_uniform_values(
                cb_plane,
                width=cb_width,
                height=cb_height,
            )
            cr_rows = row_uniform_values(cr_plane, width=cb_width, height=cb_height)
            if any(value != 128 for value in y_rows) or any(value != 128 for value in cr_rows):
                raise CaptureError(f"ground-truth neutral Y/Cr plane drifted: {case_id}")
            compression_domain_error = row_error(
                [float(value) for value in expected_subsampled],
                [float(value) for value in post_idct_cb],
            )

            global_cb = reconstructed_cb_rows(
                post_idct_cb,
                output_height=64,
                output_imcu_rows=output_imcu_rows,
                clamp_imcu_context=False,
            )
            clamped_cb = reconstructed_cb_rows(
                post_idct_cb,
                output_height=64,
                output_imcu_rows=output_imcu_rows,
                clamp_imcu_context=True,
            )
            adaptive_cb = (
                adaptive_gradient_outlier_2x_reconstruction(
                    post_idct_cb,
                    output_height=64,
                )
                if policy_v3
                else None
            )
            global_truth_error = model_boundary_errors(
                expected_truth,
                global_cb,
                output_imcu_rows=output_imcu_rows,
            )
            clamped_truth_error = model_boundary_errors(
                expected_truth,
                clamped_cb,
                output_imcu_rows=output_imcu_rows,
            )
            adaptive_truth_error = (
                model_boundary_errors(
                    expected_truth,
                    adaptive_cb,
                    output_imcu_rows=output_imcu_rows,
                )
                if adaptive_cb is not None
                else None
            )
            global_boundary = global_truth_error["heldOutInternalIMCUBoundary"]
            clamped_boundary = clamped_truth_error["heldOutInternalIMCUBoundary"]
            expected_model_winner: str | None = None
            model_winner_satisfied: bool | None = None
            if not policy_v3:
                expected_model_winner = str(
                    case.get("expectedModelBoundaryWinner", "globalCenteredLinear")
                )
                model_winner_satisfied = expected_pairwise_winner(
                    global_boundary,
                    clamped_boundary,
                    expected=expected_model_winner,
                    left_name="globalCenteredLinear",
                    right_name="imcuClampedCenteredLinear",
                )
                if not model_winner_satisfied:
                    raise CaptureError(
                        f"expected chroma reconstruction winner {expected_model_winner} did not "
                        f"win at internal iMCU boundaries: {case_id}"
                    )
            else:
                if adaptive_truth_error is None or adaptive_cb is None:
                    raise CaptureError(f"adaptive reconstruction missing: {case_id}")
                expectation = str(case["adaptiveExpectation"])
                adaptive_all = adaptive_truth_error["allRows"]
                global_all = global_truth_error["allRows"]
                clamped_all = clamped_truth_error["allRows"]
                if expectation == "matchesGlobal":
                    adaptive_satisfied = adaptive_cb == global_cb
                elif expectation == "strictlyBetterThanGlobalAndNotWorseThanClamp":
                    adaptive_satisfied = strictly_better(adaptive_all, global_all) and all(
                        float(adaptive_all[key]) <= float(clamped_all[key])
                        for key in (
                            "rootMeanSquareCodeDifference",
                            "meanAbsoluteCodeDifference",
                            "maximumCodeDifference",
                        )
                    )
                elif expectation == "notWorseThanGlobal":
                    adaptive_satisfied = all(
                        float(adaptive_all[key]) <= float(global_all[key])
                        for key in (
                            "rootMeanSquareCodeDifference",
                            "meanAbsoluteCodeDifference",
                            "maximumCodeDifference",
                        )
                    )
                else:
                    raise CaptureError(f"unsupported adaptive expectation: {expectation}")
                if not adaptive_satisfied:
                    raise CaptureError(
                        f"adaptive chroma expectation {expectation} failed: {case_id}"
                    )

                results.append(
                    {
                        "id": case_id,
                        "codingMode": coding_mode,
                        "sampling": sampling,
                        "signal": signal,
                        "input": {
                            "byteCount": len(encoded),
                            "sha256": sha256_bytes(encoded),
                            "jfifAPP0Present": True,
                            "samplingFactors": factors,
                        },
                        "generator": generator_report,
                        "rawProbe": raw_report,
                        "postIDCT": {
                            "Y": {"sha256": sha256_bytes(y_plane), "rowCodes": y_rows},
                            "Cb": {
                                "sha256": sha256_bytes(cb_plane),
                                "rowCodes": post_idct_cb,
                                "subsampledSourceError": compression_domain_error,
                            },
                            "Cr": {"sha256": sha256_bytes(cr_plane), "rowCodes": cr_rows},
                        },
                        "sourceTruthModels": {
                            "globalCenteredLinear": global_truth_error,
                            "imcuClampedCenteredLinear": clamped_truth_error,
                            "globalStrictlyCloserAtInternalBoundaries": strictly_better(
                                global_boundary, clamped_boundary
                            ),
                            "adaptiveGradientOutlier2x": adaptive_truth_error,
                            "adaptiveExpectation": expectation,
                            "adaptiveExpectationSatisfied": adaptive_satisfied,
                        },
                    }
                )
                continue

            reference_ppm = temp / f"{case_id}.reference.ppm"
            reference_completed = run(
                [str(djpeg), "-rgb", "-pnm", "-outfile", str(reference_ppm), str(generated)]
            )
            if reference_completed.stderr.strip():
                raise CaptureError(
                    f"ground-truth djpeg emitted diagnostics: {case_id}: "
                    f"{reference_completed.stderr.strip()}"
                )
            width, height, reference_rgb = parse_ppm_rgb(reference_ppm)
            if (width, height) != (64, 64):
                raise CaptureError(f"ground-truth djpeg geometry drifted: {case_id}")
            libjpeg_blue = rgb_blue_rows(reference_rgb, width=width, height=height)

            imagecraft_path = temp / f"{case_id}.imagecraft.rgba"
            imagecraft_completed = run(
                [
                    str(imagecraft_evidence),
                    "--packed-rgba-export",
                    str(generated),
                    "--output",
                    str(imagecraft_path),
                ]
            )
            if imagecraft_completed.stderr.strip():
                raise CaptureError(
                    f"ground-truth ImageCraft emitted diagnostics: {case_id}: "
                    f"{imagecraft_completed.stderr.strip()}"
                )
            imagecraft_report = parse_json_stdout(
                imagecraft_completed, f"ground-truth ImageCraft {case_id}"
            )
            imagecraft_rgba = imagecraft_path.read_bytes()
            imagecraft_blue = rgba_blue_rows(imagecraft_rgba, width=width, height=height)

            libjpeg_truth = backend_source_truth_errors(
                libjpeg_blue["meanBlueByRow"],
                expected_truth,
                output_imcu_rows=output_imcu_rows,
            )
            imagecraft_truth = backend_source_truth_errors(
                imagecraft_blue["meanBlueByRow"],
                expected_truth,
                output_imcu_rows=output_imcu_rows,
            )
            libjpeg_boundary = libjpeg_truth["heldOutInternalIMCUBoundary"]
            imagecraft_boundary = imagecraft_truth["heldOutInternalIMCUBoundary"]
            expected_backend_winner: str | None = None
            backend_winner_satisfied: bool | None = None
            if not policy_v3:
                expected_backend_winner = str(
                    case.get("expectedBackendBoundaryWinner", "libjpeg")
                )
                backend_winner_satisfied = expected_pairwise_winner(
                    libjpeg_boundary,
                    imagecraft_boundary,
                    expected=expected_backend_winner,
                    left_name="libjpeg",
                    right_name="imageCraftImageIO",
                )
                if not backend_winner_satisfied:
                    raise CaptureError(
                        f"expected backend winner {expected_backend_winner} did not preserve the "
                        f"source-defined boundary signal better: {case_id}"
                    )

            result = {
                    "id": case_id,
                    "codingMode": coding_mode,
                    "sampling": sampling,
                    "signal": signal,
                    "input": {
                        "byteCount": len(encoded),
                        "sha256": sha256_bytes(encoded),
                        "jfifAPP0Present": True,
                        "samplingFactors": factors,
                    },
                    "generator": generator_report,
                    "rawProbe": raw_report,
                    "postIDCT": {
                        "Y": {"sha256": sha256_bytes(y_plane), "rowCodes": y_rows},
                        "Cb": {
                            "sha256": sha256_bytes(cb_plane),
                            "rowCodes": post_idct_cb,
                            "subsampledSourceError": compression_domain_error,
                        },
                        "Cr": {"sha256": sha256_bytes(cr_plane), "rowCodes": cr_rows},
                    },
                    "sourceTruthModels": {
                        "globalCenteredLinear": global_truth_error,
                        "imcuClampedCenteredLinear": clamped_truth_error,
                        "globalStrictlyCloserAtInternalBoundaries": strictly_better(
                            global_boundary, clamped_boundary
                        ),
                    },
                    "backendSourceTruth": {
                        "libjpeg": libjpeg_truth,
                        "imageCraftImageIO": imagecraft_truth,
                        "libjpegStrictlyCloserAtInternalBoundaries": strictly_better(
                            libjpeg_boundary, imagecraft_boundary
                        ),
                    },
                    "libjpegRGBSHA256": sha256_bytes(reference_rgb),
                    "imageCraftRGBA8SHA256": sha256_bytes(imagecraft_rgba),
                    "imageCraftEvidence": imagecraft_report,
                }
            if policy_v3:
                result["sourceTruthModels"]["adaptiveGradientOutlier2x"] = adaptive_truth_error
                result["sourceTruthModels"]["adaptiveExpectation"] = expectation
                result["sourceTruthModels"]["adaptiveExpectationSatisfied"] = adaptive_satisfied
            if policy_v2:
                result["sourceTruthModels"]["expectedBoundaryWinner"] = expected_model_winner
                result["sourceTruthModels"]["expectedWinnerSatisfied"] = model_winner_satisfied
                result["backendSourceTruth"]["expectedBoundaryWinner"] = expected_backend_winner
                result["backendSourceTruth"]["expectedWinnerSatisfied"] = backend_winner_satisfied
            results.append(result)

        after = capture_source_identity(temp / "source-after.json")
        before_hash = before.get("sourceIdentitySHA256")
        if not before_hash or before_hash != after.get("sourceIdentitySHA256"):
            raise CaptureError("ImageCraft source identity changed during chroma ground-truth capture")

        report = {
            "schemaVersion": 3 if policy_v3 else (2 if policy_v2 else 1),
            "evidenceVersion": (
                "imagecraft-jpeg-chroma-adaptive-policy-v3"
                if policy_v3
                else (
                    "imagecraft-jpeg-chroma-ground-truth-policy-v2"
                    if policy_v2
                    else (
                        "imagecraft-jpeg-chroma-ground-truth-matrix-v1"
                        if profile_id == "IMAGECRAFT-JPEG-CHROMA-GROUND-TRUTH-MATRIX-V1"
                        else "imagecraft-jpeg-chroma-ground-truth-v1"
                    )
                )
            ),
            "status": "source-bound-reconstruction-quality-mechanism",
            "formalSourceBoundExecution": True,
            "productionBackendQualified": False,
            "profile": {
                "profileID": profile["profileID"],
                "path": str(profile_path.relative_to(ROOT)),
                "sha256": sha256_file(profile_path),
            },
            "sourceIdentity": {
                "sourceIdentitySHA256": before_hash,
                "fileCount": before.get("fileCount"),
                "stableBeforeAfter": True,
            },
            "runtime": {
                "pythonVersion": platform.python_version(),
                "architecture": platform.machine(),
                "jpegTurboPrefix": str(jpeg_prefix),
                "djpegVersion": djpeg_version,
                "djpegSHA256": sha256_file(djpeg),
                "generatorSHA256": sha256_file(generator),
                "generatorSourceSHA256": sha256_file(generator_source),
                "rawProbeSHA256": sha256_file(raw_probe),
                "rawProbeSourceSHA256": sha256_file(RAW_PROBE_SOURCE),
                "imageCraftEvidenceSHA256": (
                    sha256_file(imagecraft_evidence)
                    if imagecraft_evidence is not None
                    else None
                ),
            },
            "claimBoundary": profile["claimBoundary"],
            "cases": results,
            "summary": {
                "caseCount": len(results),
                "signals": sorted({str(case["signal"]) for case in results}),
                "allJFIFAPP0Present": all(
                    case["input"]["jfifAPP0Present"] for case in results
                ),
                "allGlobalReconstructionsStrictlyCloserToSourceTruth": all(
                    case["sourceTruthModels"][
                        "globalStrictlyCloserAtInternalBoundaries"
                    ]
                    for case in results
                ),
                "allLibjpegBackendsStrictlyCloserToSourceTruthAtInternalBoundaries": (
                    None
                    if policy_v3
                    else all(
                        case["backendSourceTruth"][
                            "libjpegStrictlyCloserAtInternalBoundaries"
                        ]
                        for case in results
                    )
                ),
                "globalBoundaryRMSEByCase": {
                    case["id"]: case["sourceTruthModels"]["globalCenteredLinear"][
                        "heldOutInternalIMCUBoundary"
                    ]["rootMeanSquareCodeDifference"]
                    for case in results
                },
                "clampedBoundaryRMSEByCase": {
                    case["id"]: case["sourceTruthModels"][
                        "imcuClampedCenteredLinear"
                    ]["heldOutInternalIMCUBoundary"]["rootMeanSquareCodeDifference"]
                    for case in results
                },
                "libjpegBoundaryRMSEByCase": (
                    {}
                    if policy_v3
                    else {
                        case["id"]: case["backendSourceTruth"]["libjpeg"][
                            "heldOutInternalIMCUBoundary"
                        ]["rootMeanSquareCodeDifference"]
                        for case in results
                    }
                ),
                "imageCraftBoundaryRMSEByCase": (
                    {}
                    if policy_v3
                    else {
                        case["id"]: case["backendSourceTruth"]["imageCraftImageIO"][
                            "heldOutInternalIMCUBoundary"
                        ]["rootMeanSquareCodeDifference"]
                        for case in results
                    }
                ),
            },
        }
        if policy_v2:
            report["summary"]["allExpectedModelWinnersSatisfied"] = all(
                case["sourceTruthModels"]["expectedWinnerSatisfied"] for case in results
            )
            report["summary"]["allExpectedBackendWinnersSatisfied"] = all(
                case["backendSourceTruth"]["expectedWinnerSatisfied"] for case in results
            )
            report["summary"]["expectedModelWinnerByCase"] = {
                case["id"]: case["sourceTruthModels"]["expectedBoundaryWinner"]
                for case in results
            }
            report["summary"]["expectedBackendWinnerByCase"] = {
                case["id"]: case["backendSourceTruth"]["expectedBoundaryWinner"]
                for case in results
            }
        if policy_v3:
            report["summary"]["allAdaptiveExpectationsSatisfied"] = all(
                case["sourceTruthModels"]["adaptiveExpectationSatisfied"]
                for case in results
            )
            report["summary"]["adaptiveExpectationByCase"] = {
                case["id"]: case["sourceTruthModels"]["adaptiveExpectation"]
                for case in results
            }
            report["summary"]["adaptiveAllRowsRMSEByCase"] = {
                case["id"]: case["sourceTruthModels"]["adaptiveGradientOutlier2x"][
                    "allRows"
                ]["rootMeanSquareCodeDifference"]
                for case in results
            }
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(
            "JPEG chroma ground-truth captured: "
            f"cases={len(results)} source={before_hash} output={output_path}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
