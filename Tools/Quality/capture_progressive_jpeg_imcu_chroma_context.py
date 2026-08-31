#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import platform
import subprocess
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
from capture_progressive_jpeg_chroma_reconstruction import ycbcr_tables
from capture_progressive_jpeg_cross_backend_sampling import (
    compare_rgb_to_opaque_rgba,
    jpeg_sampling_factors,
)


DEFAULT_PROFILE = (
    ROOT / "Evidence/Experiments/ProgressiveJPEGIMCUChromaContext/v1/profile.json"
)
DEFAULT_OUTPUT = (
    ROOT / ".artifacts/program/T101/progressive-jpeg-imcu-chroma-context-v1.json"
)
GENERATOR_SOURCE = ROOT / "Tools/Quality/LibJPEGTurboRawChromaSignalGenerator/main.c"
RAW_PROBE_SOURCE = ROOT / "Tools/Quality/LibJPEGTurboRawYCbCrProbe/main.c"


def build_c_tool(temp: Path, source: Path, name: str, jpeg_prefix: Path) -> Path:
    output = temp / name
    run(
        [
            "cc",
            "-O2",
            "-Wall",
            "-Wextra",
            f"-I{jpeg_prefix / 'include'}",
            str(source),
            f"-L{jpeg_prefix / 'lib'}",
            "-ljpeg",
            f"-Wl,-rpath,{jpeg_prefix / 'lib'}",
            "-o",
            str(output),
        ]
    )
    return output


def row_uniform_values(payload: bytes, *, width: int, height: int) -> list[int]:
    if len(payload) != width * height:
        raise CaptureError("plane payload shape mismatch")
    values: list[int] = []
    for row in range(height):
        start = row * width
        first = payload[start]
        if any(value != first for value in payload[start : start + width]):
            raise CaptureError("source-generated component row is not horizontally uniform")
        values.append(first)
    return values


def rgba_blue_rows(payload: bytes, *, width: int, height: int) -> dict[str, Any]:
    if len(payload) != width * height * 4:
        raise CaptureError("packed RGBA payload shape mismatch")
    rows: list[float] = []
    spreads: list[int] = []
    for row in range(height):
        row_start = row * width * 4
        blue_values: list[int] = []
        for column in range(width):
            offset = row_start + column * 4
            if payload[offset + 3] != 255:
                raise CaptureError("source-generated ImageCraft output alpha is not opaque")
            blue_values.append(payload[offset + 2])
        rows.append(sum(blue_values) / len(blue_values))
        spreads.append(max(blue_values) - min(blue_values))
    return {
        "meanBlueByRow": rows,
        "blueSpreadByRow": spreads,
        "maximumBlueSpreadWithinRow": max(spreads),
    }


def rgb_blue_rows(payload: bytes, *, width: int, height: int) -> dict[str, Any]:
    if len(payload) != width * height * 3:
        raise CaptureError("RGB payload shape mismatch")
    rows: list[float] = []
    spreads: list[int] = []
    for row in range(height):
        row_start = row * width * 3
        blue_values = [payload[row_start + column * 3 + 2] for column in range(width)]
        rows.append(sum(blue_values) / len(blue_values))
        spreads.append(max(blue_values) - min(blue_values))
    return {
        "meanBlueByRow": rows,
        "blueSpreadByRow": spreads,
        "maximumBlueSpreadWithinRow": max(spreads),
    }


def reconstructed_cb_rows(
    cb_rows: list[int],
    *,
    output_height: int,
    output_imcu_rows: int,
    clamp_imcu_context: bool,
) -> list[int]:
    reconstructed: list[int] = []
    chroma_rows_per_imcu = output_imcu_rows // 2
    if output_imcu_rows <= 0 or output_imcu_rows % 2 != 0:
        raise CaptureError("invalid output iMCU row count")
    for output_row in range(output_height):
        source_row = output_row // 2
        if source_row >= len(cb_rows):
            raise CaptureError("output row exceeds source chroma geometry")
        if output_row & 1:
            adjacent_row = min(len(cb_rows) - 1, source_row + 1)
            if clamp_imcu_context and source_row % chroma_rows_per_imcu == chroma_rows_per_imcu - 1:
                adjacent_row = source_row
            bias = 2
        else:
            adjacent_row = max(0, source_row - 1)
            if clamp_imcu_context and source_row % chroma_rows_per_imcu == 0:
                adjacent_row = source_row
            bias = 1
        reconstructed.append(
            (cb_rows[source_row] * 3 + cb_rows[adjacent_row] + bias) >> 2
        )
    return reconstructed


def predicted_blue_rows(
    cb_rows: list[int],
    *,
    output_height: int,
    output_imcu_rows: int,
    clamp_imcu_context: bool,
) -> list[int]:
    _, cb_b, _, _ = ycbcr_tables()
    predicted: list[int] = []
    for reconstructed_cb in reconstructed_cb_rows(
        cb_rows,
        output_height=output_height,
        output_imcu_rows=output_imcu_rows,
        clamp_imcu_context=clamp_imcu_context,
    ):
        blue = 128 + cb_b[reconstructed_cb]
        predicted.append(min(255, max(0, blue)))
    return predicted


def row_error(observed: list[float], predicted: list[float]) -> dict[str, Any]:
    if len(observed) != len(predicted) or not observed:
        raise CaptureError("row-error payload shape mismatch")
    differences = [abs(actual - expected) for actual, expected in zip(observed, predicted)]
    squared = sum(value * value for value in differences)
    return {
        "rowCount": len(differences),
        "maximumCodeDifference": max(differences),
        "meanAbsoluteCodeDifference": sum(differences) / len(differences),
        "rootMeanSquareCodeDifference": math.sqrt(squared / len(differences)),
        "fractionAtMostOneCode": sum(value <= 1 for value in differences) / len(differences),
        "differencesByRow": differences,
    }


def fit_affine_color_map(
    reconstructed_cb: list[int],
    observed_blue: list[float],
    *,
    output_imcu_rows: int,
) -> dict[str, Any]:
    if len(reconstructed_cb) != len(observed_blue) or not reconstructed_cb:
        raise CaptureError("affine color-map payload shape mismatch")
    training_indices = [
        index
        for index in range(len(reconstructed_cb))
        if index % output_imcu_rows not in (0, output_imcu_rows - 1)
    ]
    x_values = [float(reconstructed_cb[index]) for index in training_indices]
    y_values = [float(observed_blue[index]) for index in training_indices]
    if len(x_values) < 2:
        raise CaptureError("affine color-map fit has insufficient interior rows")
    x_mean = sum(x_values) / len(x_values)
    y_mean = sum(y_values) / len(y_values)
    denominator = sum((value - x_mean) ** 2 for value in x_values)
    if denominator <= 0:
        raise CaptureError("affine color-map fit lacks chroma variation")
    gain = sum(
        (x_value - x_mean) * (y_value - y_mean)
        for x_value, y_value in zip(x_values, y_values)
    ) / denominator
    intercept = y_mean - gain * x_mean
    fitted = [intercept + gain * float(value) for value in reconstructed_cb]
    return {
        "trainingDomain": "non-boundary output rows",
        "trainingRowCount": len(training_indices),
        "intercept": intercept,
        "gain": gain,
        "trainingError": row_error(
            [observed_blue[index] for index in training_indices],
            [fitted[index] for index in training_indices],
        ),
        "predictedBlueByRow": fitted,
    }


def boundary_error(
    observed: list[float],
    predicted: list[float],
    *,
    output_imcu_rows: int,
) -> dict[str, Any]:
    indices = [
        index
        for index in range(len(observed))
        if index % output_imcu_rows in (0, output_imcu_rows - 1)
        and index not in (0, len(observed) - 1)
    ]
    if not indices:
        raise CaptureError("boundary error has no held-out iMCU rows")
    result = row_error(
        [observed[index] for index in indices],
        [predicted[index] for index in indices],
    )
    result["rowIndices"] = indices
    return result


def phase_statistics(
    reference_rgb: bytes,
    imagecraft_rgba: bytes,
    *,
    width: int,
    height: int,
    output_imcu_rows: int,
) -> dict[str, Any]:
    if len(reference_rgb) != width * height * 3 or len(imagecraft_rgba) != width * height * 4:
        raise CaptureError("phase-statistics payload shape mismatch")
    absolute_sum_by_phase = [0] * output_imcu_rows
    sample_count_by_phase = [0] * output_imcu_rows
    maximum_by_phase = [0] * output_imcu_rows
    pixel_count_by_phase = [0] * output_imcu_rows
    pixel_gt4_by_phase = [0] * output_imcu_rows
    pixel_gt8_by_phase = [0] * output_imcu_rows
    pixel_gt16_by_phase = [0] * output_imcu_rows
    pixel_maxima: list[tuple[int, int]] = []

    for row in range(height):
        phase = row % output_imcu_rows
        for column in range(width):
            rgb_offset = (row * width + column) * 3
            rgba_offset = (row * width + column) * 4
            if imagecraft_rgba[rgba_offset + 3] != 255:
                raise CaptureError("natural-photo ImageCraft output alpha is not opaque")
            pixel_maximum = 0
            for channel in range(3):
                difference = abs(
                    int(reference_rgb[rgb_offset + channel])
                    - int(imagecraft_rgba[rgba_offset + channel])
                )
                absolute_sum_by_phase[phase] += difference
                sample_count_by_phase[phase] += 1
                maximum_by_phase[phase] = max(maximum_by_phase[phase], difference)
                pixel_maximum = max(pixel_maximum, difference)
            pixel_count_by_phase[phase] += 1
            pixel_gt4_by_phase[phase] += pixel_maximum > 4
            pixel_gt8_by_phase[phase] += pixel_maximum > 8
            pixel_gt16_by_phase[phase] += pixel_maximum > 16
            pixel_maxima.append((pixel_maximum, phase))

    phases: list[dict[str, Any]] = []
    for phase in range(output_imcu_rows):
        samples = sample_count_by_phase[phase]
        pixels = pixel_count_by_phase[phase]
        phases.append(
            {
                "phase": phase,
                "sampleCount": samples,
                "meanAbsoluteRGBCodeDifference": absolute_sum_by_phase[phase] / samples,
                "maximumRGBCodeDifference": maximum_by_phase[phase],
                "pixelFractionAbove4Codes": pixel_gt4_by_phase[phase] / pixels,
                "pixelFractionAbove8Codes": pixel_gt8_by_phase[phase] / pixels,
                "pixelFractionAbove16Codes": pixel_gt16_by_phase[phase] / pixels,
            }
        )

    boundary_phases = {0, output_imcu_rows - 1}
    boundary_samples = sum(
        sample_count_by_phase[phase] for phase in boundary_phases
    )
    boundary_absolute = sum(
        absolute_sum_by_phase[phase] for phase in boundary_phases
    )
    interior_samples = sum(sample_count_by_phase) - boundary_samples
    interior_absolute = sum(absolute_sum_by_phase) - boundary_absolute
    boundary_pixels = sum(pixel_count_by_phase[phase] for phase in boundary_phases)
    interior_pixels = sum(pixel_count_by_phase) - boundary_pixels
    boundary_gt4 = sum(pixel_gt4_by_phase[phase] for phase in boundary_phases)
    interior_gt4 = sum(pixel_gt4_by_phase) - boundary_gt4
    boundary_gt8 = sum(pixel_gt8_by_phase[phase] for phase in boundary_phases)
    interior_gt8 = sum(pixel_gt8_by_phase) - boundary_gt8
    boundary_gt16 = sum(pixel_gt16_by_phase[phase] for phase in boundary_phases)
    interior_gt16 = sum(pixel_gt16_by_phase) - boundary_gt16

    top_count = min(200, len(pixel_maxima))
    top = sorted(pixel_maxima, reverse=True)[:top_count]
    top_boundary = sum(phase in boundary_phases for _, phase in top)
    return {
        "phases": phases,
        "boundary": {
            "phases": sorted(boundary_phases),
            "meanAbsoluteRGBCodeDifference": boundary_absolute / boundary_samples,
            "pixelFractionAbove4Codes": boundary_gt4 / boundary_pixels,
            "pixelFractionAbove8Codes": boundary_gt8 / boundary_pixels,
            "pixelFractionAbove16Codes": boundary_gt16 / boundary_pixels,
        },
        "interior": {
            "meanAbsoluteRGBCodeDifference": interior_absolute / interior_samples,
            "pixelFractionAbove4Codes": interior_gt4 / interior_pixels,
            "pixelFractionAbove8Codes": interior_gt8 / interior_pixels,
            "pixelFractionAbove16Codes": interior_gt16 / interior_pixels,
        },
        "topPixelTail": {
            "count": top_count,
            "boundaryCount": top_boundary,
            "boundaryFraction": top_boundary / top_count,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, default=DEFAULT_PROFILE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    profile_path = args.profile if args.profile.is_absolute() else ROOT / args.profile
    output_path = args.output if args.output.is_absolute() else ROOT / args.output
    profile = json.loads(profile_path.read_text())
    if profile.get("profileID") != "IMAGECRAFT-PROGRESSIVE-JPEG-IMCU-CHROMA-CONTEXT-V1":
        raise CaptureError("unexpected iMCU chroma-context profile ID")

    with tempfile.TemporaryDirectory(prefix="imagecraft-imcu-chroma-context-") as temp_raw:
        temp = Path(temp_raw)
        before = capture_source_identity(temp / "source-before.json")
        jpeg_prefix = Path(run(["brew", "--prefix", "jpeg-turbo"]).stdout.strip())
        djpeg = jpeg_prefix / "bin/djpeg"
        if not djpeg.is_file():
            raise CaptureError("pinned djpeg is unavailable")
        djpeg_version = run([str(djpeg), "-version"]).stderr.strip()
        required_version = profile.get("requiredLibJPEGTurboVersionPrefix")
        if not isinstance(required_version, str) or not djpeg_version.startswith(required_version):
            raise CaptureError("djpeg runtime is outside iMCU chroma-context qualification")

        generator = build_c_tool(
            temp,
            GENERATOR_SOURCE,
            "raw-chroma-signal-generator",
            jpeg_prefix,
        )
        raw_probe = build_c_tool(temp, RAW_PROBE_SOURCE, "raw-ycbcr-probe", jpeg_prefix)
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

        model = profile["model"]
        output_imcu_rows = int(model["outputIMCURowCount"])
        generated_results: list[dict[str, Any]] = []
        for case in profile["generatedCases"]:
            case_id = str(case["id"])
            sampling = str(case["sampling"])
            generated = temp / f"{case_id}.jpg"
            generator_completed = run([str(generator), sampling, str(generated)])
            generator_report = parse_json_stdout(generator_completed, f"generator {case_id}")
            encoded = generated.read_bytes()
            actual_sampling = [
                [item["horizontal"], item["vertical"]]
                for item in jpeg_sampling_factors(encoded)
            ]
            if actual_sampling != case["expectedFactors"]:
                raise CaptureError(
                    f"generated sampling factors drifted: {case_id}: {actual_sampling}"
                )

            raw_prefix = temp / f"{case_id}.raw"
            raw_completed = run([str(raw_probe), str(generated), str(raw_prefix)])
            if raw_completed.stderr.strip():
                raise CaptureError(f"raw probe warned: {case_id}: {raw_completed.stderr.strip()}")
            raw_report = parse_json_stdout(raw_completed, f"raw probe {case_id}")
            if raw_report.get("warningCount") != 0:
                raise CaptureError(f"raw probe warning count drifted: {case_id}")
            width = int(raw_report["width"])
            height = int(raw_report["height"])
            components = raw_report["components"]
            if width != 64 or height != 64 or not isinstance(components, list) or len(components) != 3:
                raise CaptureError(f"generated raw geometry drifted: {case_id}")
            y_plane = Path(f"{raw_prefix}-Y.raw").read_bytes()
            cb_plane = Path(f"{raw_prefix}-Cb.raw").read_bytes()
            cr_plane = Path(f"{raw_prefix}-Cr.raw").read_bytes()
            y_rows = row_uniform_values(y_plane, width=width, height=height)
            cb_width = int(components[1]["width"])
            cb_height = int(components[1]["height"])
            cb_rows = row_uniform_values(cb_plane, width=cb_width, height=cb_height)
            cr_rows = row_uniform_values(cr_plane, width=cb_width, height=cb_height)
            if any(value != 128 for value in y_rows) or any(value != 128 for value in cr_rows):
                raise CaptureError(f"generated neutral Y/Cr planes drifted: {case_id}")
            generated_cb_rows = generator_report.get("cbRows")
            if not isinstance(generated_cb_rows, list) or len(generated_cb_rows) != len(cb_rows):
                raise CaptureError(f"generated Cb row contract drifted: {case_id}")
            generated_to_post_idct_cb = row_error(
                [float(value) for value in generated_cb_rows],
                [float(value) for value in cb_rows],
            )

            reference_ppm = temp / f"{case_id}.reference.ppm"
            reference_completed = run(
                [str(djpeg), "-rgb", "-pnm", "-outfile", str(reference_ppm), str(generated)]
            )
            if reference_completed.stderr.strip():
                raise CaptureError(f"djpeg warned: {case_id}: {reference_completed.stderr.strip()}")
            reference_width, reference_height, reference_rgb = parse_ppm_rgb(reference_ppm)
            if (reference_width, reference_height) != (width, height):
                raise CaptureError(f"reference geometry drifted: {case_id}")
            libjpeg_blue = rgb_blue_rows(reference_rgb, width=width, height=height)

            imagecraft_path = temp / f"{case_id}.rgba"
            imagecraft_completed = run(
                [
                    str(imagecraft_evidence),
                    "--packed-rgba-export",
                    str(generated),
                    "--output",
                    str(imagecraft_path),
                ]
            )
            imagecraft_report = parse_json_stdout(
                imagecraft_completed, f"ImageCraft {case_id}"
            )
            imagecraft_rgba = imagecraft_path.read_bytes()
            imagecraft_blue = rgba_blue_rows(imagecraft_rgba, width=width, height=height)

            global_cb = reconstructed_cb_rows(
                cb_rows,
                output_height=height,
                output_imcu_rows=output_imcu_rows,
                clamp_imcu_context=False,
            )
            clamped_cb = reconstructed_cb_rows(
                cb_rows,
                output_height=height,
                output_imcu_rows=output_imcu_rows,
                clamp_imcu_context=True,
            )

            libjpeg_color_map = fit_affine_color_map(
                global_cb,
                libjpeg_blue["meanBlueByRow"],
                output_imcu_rows=output_imcu_rows,
            )
            libjpeg_global_prediction = list(libjpeg_color_map["predictedBlueByRow"])
            libjpeg_intercept = float(libjpeg_color_map["intercept"])
            libjpeg_gain = float(libjpeg_color_map["gain"])
            libjpeg_clamped_prediction = [
                libjpeg_intercept + libjpeg_gain * float(value) for value in clamped_cb
            ]
            libjpeg_global_boundary_error = boundary_error(
                libjpeg_blue["meanBlueByRow"],
                libjpeg_global_prediction,
                output_imcu_rows=output_imcu_rows,
            )
            libjpeg_clamped_boundary_error = boundary_error(
                libjpeg_blue["meanBlueByRow"],
                libjpeg_clamped_prediction,
                output_imcu_rows=output_imcu_rows,
            )

            imagecraft_color_map = fit_affine_color_map(
                global_cb,
                imagecraft_blue["meanBlueByRow"],
                output_imcu_rows=output_imcu_rows,
            )
            imagecraft_global_prediction = list(
                imagecraft_color_map["predictedBlueByRow"]
            )
            imagecraft_intercept = float(imagecraft_color_map["intercept"])
            imagecraft_gain = float(imagecraft_color_map["gain"])
            imagecraft_clamped_prediction = [
                imagecraft_intercept + imagecraft_gain * float(value)
                for value in clamped_cb
            ]
            imagecraft_global_error = row_error(
                imagecraft_blue["meanBlueByRow"], imagecraft_global_prediction
            )
            imagecraft_clamped_error = row_error(
                imagecraft_blue["meanBlueByRow"], imagecraft_clamped_prediction
            )
            imagecraft_global_boundary_error = boundary_error(
                imagecraft_blue["meanBlueByRow"],
                imagecraft_global_prediction,
                output_imcu_rows=output_imcu_rows,
            )
            imagecraft_clamped_boundary_error = boundary_error(
                imagecraft_blue["meanBlueByRow"],
                imagecraft_clamped_prediction,
                output_imcu_rows=output_imcu_rows,
            )
            if not (
                libjpeg_global_boundary_error["rootMeanSquareCodeDifference"]
                < libjpeg_clamped_boundary_error["rootMeanSquareCodeDifference"]
                and libjpeg_global_boundary_error["meanAbsoluteCodeDifference"]
                < libjpeg_clamped_boundary_error["meanAbsoluteCodeDifference"]
            ):
                raise CaptureError(
                    f"libjpeg does not prefer global context on held-out boundary rows: {case_id}"
                )
            if not (
                imagecraft_clamped_boundary_error["rootMeanSquareCodeDifference"]
                < imagecraft_global_boundary_error["rootMeanSquareCodeDifference"]
                and imagecraft_clamped_boundary_error["meanAbsoluteCodeDifference"]
                < imagecraft_global_boundary_error["meanAbsoluteCodeDifference"]
            ):
                raise CaptureError(
                    f"iMCU-clamped context does not improve held-out ImageCraft boundary rows: {case_id}"
                )
            cross_backend = compare_rgb_to_opaque_rgba(reference_rgb, imagecraft_rgba)
            generated_results.append(
                {
                    "id": case_id,
                    "sampling": sampling,
                    "input": {
                        "byteCount": len(encoded),
                        "sha256": sha256_bytes(encoded),
                        "samplingFactors": actual_sampling,
                    },
                    "generator": generator_report,
                    "rawProbe": raw_report,
                    "postIDCT": {
                        "Y": {"sha256": sha256_bytes(y_plane), "rowCodes": y_rows},
                        "Cb": {
                            "sha256": sha256_bytes(cb_plane),
                            "rowCodes": cb_rows,
                            "generatedToPostIDCT": generated_to_post_idct_cb,
                        },
                        "Cr": {"sha256": sha256_bytes(cr_plane), "rowCodes": cr_rows},
                    },
                    "models": {
                        "libjpegAffineColorMap": libjpeg_color_map,
                        "libjpegGlobalContextBlue": {
                            "heldOutBoundary": libjpeg_global_boundary_error,
                        },
                        "libjpegIMCUClampedContextBlue": {
                            "heldOutBoundary": libjpeg_clamped_boundary_error,
                        },
                        "imageCraftAffineColorMap": imagecraft_color_map,
                        "imageCraftGlobalContextBlue": {
                            **imagecraft_global_error,
                            "heldOutBoundary": imagecraft_global_boundary_error,
                        },
                        "imageCraftIMCUClampedContextBlue": {
                            **imagecraft_clamped_error,
                            "heldOutBoundary": imagecraft_clamped_boundary_error,
                        },
                    },
                    "blueRowObservations": {
                        "libjpeg": libjpeg_blue,
                        "imageCraft": imagecraft_blue,
                    },
                    "crossBackend": cross_backend,
                    "imageCraft": imagecraft_report,
                    "libjpegRGBSHA256": sha256_bytes(reference_rgb),
                    "imageCraftRGBA8SHA256": sha256_bytes(imagecraft_rgba),
                }
            )

        natural = profile["retainedNaturalCase"]
        natural_path = ROOT / str(natural["file"])
        natural_bytes = natural_path.read_bytes()
        if sha256_bytes(natural_bytes) != natural["sha256"]:
            raise CaptureError("retained natural JPEG identity drifted")
        natural_ppm = temp / "natural.reference.ppm"
        natural_reference_completed = run(
            [str(djpeg), "-rgb", "-pnm", "-outfile", str(natural_ppm), str(natural_path)]
        )
        if natural_reference_completed.stderr.strip():
            raise CaptureError(
                f"natural djpeg emitted diagnostics: {natural_reference_completed.stderr.strip()}"
            )
        natural_width, natural_height, natural_reference_rgb = parse_ppm_rgb(natural_ppm)
        if (natural_width, natural_height) != (natural["width"], natural["height"]):
            raise CaptureError("retained natural JPEG geometry drifted")
        natural_rgba_path = temp / "natural.imagecraft.rgba"
        natural_imagecraft_completed = run(
            [
                str(imagecraft_evidence),
                "--packed-rgba-export",
                str(natural_path),
                "--output",
                str(natural_rgba_path),
            ]
        )
        natural_imagecraft_report = parse_json_stdout(
            natural_imagecraft_completed, "natural ImageCraft"
        )
        natural_rgba = natural_rgba_path.read_bytes()
        natural_cross_backend = compare_rgb_to_opaque_rgba(
            natural_reference_rgb, natural_rgba
        )
        natural_phase = phase_statistics(
            natural_reference_rgb,
            natural_rgba,
            width=natural_width,
            height=natural_height,
            output_imcu_rows=output_imcu_rows,
        )
        if not (
            natural_phase["boundary"]["meanAbsoluteRGBCodeDifference"]
            > natural_phase["interior"]["meanAbsoluteRGBCodeDifference"]
            and natural_phase["boundary"]["pixelFractionAbove8Codes"]
            > natural_phase["interior"]["pixelFractionAbove8Codes"]
        ):
            raise CaptureError("natural residuals are not concentrated at predicted iMCU phases")

        after = capture_source_identity(temp / "source-after.json")
        before_hash = before.get("sourceIdentitySHA256")
        if not before_hash or before_hash != after.get("sourceIdentitySHA256"):
            raise CaptureError("ImageCraft source identity changed during iMCU context capture")

        report = {
            "schemaVersion": 1,
            "evidenceVersion": "imagecraft-progressive-jpeg-imcu-chroma-context-v1",
            "status": "source-bound-reconstruction-mechanism-conformance",
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
                "generatorSourceSHA256": sha256_file(GENERATOR_SOURCE),
                "rawProbeSHA256": sha256_file(raw_probe),
                "rawProbeSourceSHA256": sha256_file(RAW_PROBE_SOURCE),
                "imageCraftEvidenceSHA256": sha256_file(imagecraft_evidence),
            },
            "claimBoundary": profile["claimBoundary"],
            "model": model,
            "generatedCases": generated_results,
            "retainedNaturalCase": {
                "id": natural["id"],
                "file": natural["file"],
                "sha256": natural["sha256"],
                "crossBackend": natural_cross_backend,
                "phaseLocalization": natural_phase,
                "imageCraft": natural_imagecraft_report,
                "libjpegRGBSHA256": sha256_bytes(natural_reference_rgb),
                "imageCraftRGBA8SHA256": sha256_bytes(natural_rgba),
            },
            "summary": {
                "generatedCaseCount": len(generated_results),
                "allGeneratedLibjpegGlobalBoundaryRMSELower": all(
                    result["models"]["libjpegGlobalContextBlue"][
                        "heldOutBoundary"
                    ]["rootMeanSquareCodeDifference"]
                    < result["models"]["libjpegIMCUClampedContextBlue"][
                        "heldOutBoundary"
                    ]["rootMeanSquareCodeDifference"]
                    for result in generated_results
                ),
                "allGeneratedImageCraftIMCUClampedBoundaryRMSELower": all(
                    result["models"]["imageCraftIMCUClampedContextBlue"][
                        "heldOutBoundary"
                    ]["rootMeanSquareCodeDifference"]
                    < result["models"]["imageCraftGlobalContextBlue"][
                        "heldOutBoundary"
                    ]["rootMeanSquareCodeDifference"]
                    for result in generated_results
                ),
                "generatedImageCraftGlobalBoundaryRMSEByCase": {
                    result["id"]: result["models"]["imageCraftGlobalContextBlue"][
                        "heldOutBoundary"
                    ]["rootMeanSquareCodeDifference"]
                    for result in generated_results
                },
                "generatedImageCraftClampedBoundaryRMSEByCase": {
                    result["id"]: result["models"]["imageCraftIMCUClampedContextBlue"][
                        "heldOutBoundary"
                    ]["rootMeanSquareCodeDifference"]
                    for result in generated_results
                },
                "naturalBoundaryToInteriorMAERatio": (
                    natural_phase["boundary"]["meanAbsoluteRGBCodeDifference"]
                    / natural_phase["interior"]["meanAbsoluteRGBCodeDifference"]
                ),
                "naturalTop200BoundaryFraction": natural_phase["topPixelTail"][
                    "boundaryFraction"
                ],
            },
        }
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(
            "progressive JPEG iMCU chroma-context captured: "
            f"generated={len(generated_results)} source={before_hash} output={output_path}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
