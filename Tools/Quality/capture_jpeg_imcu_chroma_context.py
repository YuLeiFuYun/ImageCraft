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
from capture_progressive_jpeg_cross_backend_sampling import (
    compare_rgb_to_opaque_rgba,
    jpeg_sampling_factors,
)
from capture_progressive_jpeg_imcu_chroma_context import (
    GENERATOR_SOURCE,
    RAW_PROBE_SOURCE,
    boundary_error,
    build_c_tool,
    fit_affine_color_map,
    phase_statistics,
    reconstructed_cb_rows,
    rgba_blue_rows,
    rgb_blue_rows,
    row_error,
    row_uniform_values,
)


DEFAULT_PROFILE = ROOT / "Evidence/Experiments/JPEGIMCUChromaContext/v1/profile.json"
DEFAULT_OUTPUT = ROOT / ".artifacts/program/T101/jpeg-imcu-chroma-context-v1.json"


def fitted_context_errors(
    observed_blue: list[float],
    global_cb: list[int],
    clamped_cb: list[int],
    *,
    output_imcu_rows: int,
) -> dict[str, Any]:
    color_map = fit_affine_color_map(
        global_cb,
        observed_blue,
        output_imcu_rows=output_imcu_rows,
    )
    global_prediction = list(color_map["predictedBlueByRow"])
    intercept = float(color_map["intercept"])
    gain = float(color_map["gain"])
    clamped_prediction = [intercept + gain * float(value) for value in clamped_cb]
    return {
        "affineColorMap": color_map,
        "globalContext": {
            "allRows": row_error(observed_blue, global_prediction),
            "heldOutBoundary": boundary_error(
                observed_blue,
                global_prediction,
                output_imcu_rows=output_imcu_rows,
            ),
        },
        "imcuClampedContext": {
            "allRows": row_error(observed_blue, clamped_prediction),
            "heldOutBoundary": boundary_error(
                observed_blue,
                clamped_prediction,
                output_imcu_rows=output_imcu_rows,
            ),
        },
    }


def prefers_global(model: dict[str, Any]) -> bool:
    global_error = model["globalContext"]["heldOutBoundary"]
    clamped_error = model["imcuClampedContext"]["heldOutBoundary"]
    return (
        float(global_error["rootMeanSquareCodeDifference"])
        < float(clamped_error["rootMeanSquareCodeDifference"])
        and float(global_error["meanAbsoluteCodeDifference"])
        < float(clamped_error["meanAbsoluteCodeDifference"])
    )


def prefers_clamped(model: dict[str, Any]) -> bool:
    global_error = model["globalContext"]["heldOutBoundary"]
    clamped_error = model["imcuClampedContext"]["heldOutBoundary"]
    return (
        float(clamped_error["rootMeanSquareCodeDifference"])
        < float(global_error["rootMeanSquareCodeDifference"])
        and float(clamped_error["meanAbsoluteCodeDifference"])
        < float(global_error["meanAbsoluteCodeDifference"])
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, default=DEFAULT_PROFILE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    profile_path = args.profile if args.profile.is_absolute() else ROOT / args.profile
    output_path = args.output if args.output.is_absolute() else ROOT / args.output
    profile = json.loads(profile_path.read_text())
    if profile.get("profileID") != "IMAGECRAFT-JPEG-IMCU-CHROMA-CONTEXT-V1":
        raise CaptureError("unexpected JPEG iMCU chroma-context profile ID")

    model = profile["model"]
    output_imcu_rows = int(model["outputIMCURowCount"])
    if output_imcu_rows != 16:
        raise CaptureError("unexpected generated JPEG iMCU output-row contract")

    with tempfile.TemporaryDirectory(prefix="imagecraft-jpeg-imcu-context-") as temp_raw:
        temp = Path(temp_raw)
        before = capture_source_identity(temp / "source-before.json")
        jpeg_prefix = Path(run(["brew", "--prefix", "jpeg-turbo"]).stdout.strip())
        djpeg = jpeg_prefix / "bin/djpeg"
        if not djpeg.is_file():
            raise CaptureError("pinned djpeg is unavailable")
        djpeg_version = run([str(djpeg), "-version"]).stderr.strip()
        required_version = profile.get("requiredLibJPEGTurboVersionPrefix")
        if not isinstance(required_version, str) or not djpeg_version.startswith(required_version):
            raise CaptureError("djpeg runtime is outside JPEG iMCU context qualification")

        generator = build_c_tool(
            temp,
            GENERATOR_SOURCE,
            "raw-chroma-signal-generator",
            jpeg_prefix,
        )
        raw_probe = build_c_tool(
            temp,
            RAW_PROBE_SOURCE,
            "raw-ycbcr-probe",
            jpeg_prefix,
        )
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

        generated_results: list[dict[str, Any]] = []
        for case in profile["generatedCases"]:
            case_id = str(case["id"])
            coding_mode = str(case["codingMode"])
            sampling = str(case["sampling"])
            generated = temp / f"{case_id}.jpg"
            generator_completed = run(
                [str(generator), sampling, str(generated), coding_mode]
            )
            if generator_completed.stderr.strip():
                raise CaptureError(
                    f"raw component generator emitted diagnostics: {case_id}: "
                    f"{generator_completed.stderr.strip()}"
                )
            generator_report = parse_json_stdout(generator_completed, f"generator {case_id}")
            if (
                generator_report.get("codingMode") != coding_mode
                or generator_report.get("sampling") != sampling
            ):
                raise CaptureError(f"generator contract drifted: {case_id}")

            encoded = generated.read_bytes()
            actual_sampling = [
                [item["horizontal"], item["vertical"]]
                for item in jpeg_sampling_factors(encoded)
            ]
            if actual_sampling != case["expectedFactors"]:
                raise CaptureError(
                    f"generated sampling factors drifted: {case_id}: {actual_sampling}"
                )

            frame_completed = run(
                [
                    str(imagecraft_evidence),
                    "--jpeg-frame-sampling-geometry",
                    str(generated),
                ]
            )
            if frame_completed.stderr.strip():
                raise CaptureError(
                    f"ImageCraft frame geometry emitted diagnostics: {case_id}: "
                    f"{frame_completed.stderr.strip()}"
                )
            frame_report = parse_json_stdout(
                frame_completed,
                f"ImageCraft frame geometry {case_id}",
            )
            frame_geometry = frame_report.get("geometry")
            expected_coding = (
                "progressiveDCT" if coding_mode == "progressive" else "baselineDCT"
            )
            expected_sampling_mode = (
                "threeComponent440" if sampling == "440" else "threeComponent420"
            )
            if (
                frame_report.get("evidenceVersion")
                != "imagecraft-jpeg-frame-sampling-geometry-v1"
                or not isinstance(frame_geometry, dict)
                or frame_geometry.get("codingMode") != expected_coding
                or frame_geometry.get("samplingMode") != expected_sampling_mode
                or frame_geometry.get("outputIMCURowHeight") != 16
                or frame_geometry.get("totalIMCURowCount") != 4
                or frame_geometry.get("internalIMCUBoundaryCount") != 3
                or frame_geometry.get("verticalChromaSubsamplingPresent") is not True
                or frame_geometry.get("verticalChromaBoundaryAdjacentOutputRowCount") != 6
            ):
                raise CaptureError(
                    f"ImageCraft frame sampling geometry drifted: {case_id}"
                )

            raw_prefix = temp / f"{case_id}.raw"
            raw_completed = run([str(raw_probe), str(generated), str(raw_prefix)])
            if raw_completed.stderr.strip():
                raise CaptureError(
                    f"raw component probe emitted diagnostics: {case_id}: "
                    f"{raw_completed.stderr.strip()}"
                )
            raw_report = parse_json_stdout(raw_completed, f"raw probe {case_id}")
            if raw_report.get("warningCount") != 0:
                raise CaptureError(f"raw component probe warning count drifted: {case_id}")
            expected_progressive = coding_mode == "progressive"
            if raw_report.get("progressiveMode") is not expected_progressive:
                raise CaptureError(f"raw component coding mode drifted: {case_id}")
            width = int(raw_report["width"])
            height = int(raw_report["height"])
            components = raw_report.get("components")
            if width != 64 or height != 64 or not isinstance(components, list) or len(components) != 3:
                raise CaptureError(f"raw component geometry drifted: {case_id}")

            y_plane = Path(f"{raw_prefix}-Y.raw").read_bytes()
            cb_plane = Path(f"{raw_prefix}-Cb.raw").read_bytes()
            cr_plane = Path(f"{raw_prefix}-Cr.raw").read_bytes()
            y_rows = row_uniform_values(y_plane, width=width, height=height)
            cb_width = int(components[1]["width"])
            cb_height = int(components[1]["height"])
            cb_rows = row_uniform_values(cb_plane, width=cb_width, height=cb_height)
            cr_rows = row_uniform_values(cr_plane, width=cb_width, height=cb_height)
            if any(value != 128 for value in y_rows) or any(value != 128 for value in cr_rows):
                raise CaptureError(f"generated neutral Y/Cr post-IDCT planes drifted: {case_id}")
            generated_cb_rows = generator_report.get("cbRows")
            if not isinstance(generated_cb_rows, list) or len(generated_cb_rows) != len(cb_rows):
                raise CaptureError(f"generated Cb row contract drifted: {case_id}")
            generated_to_post_idct = row_error(
                [float(value) for value in generated_cb_rows],
                [float(value) for value in cb_rows],
            )

            reference_ppm = temp / f"{case_id}.reference.ppm"
            reference_completed = run(
                [str(djpeg), "-rgb", "-pnm", "-outfile", str(reference_ppm), str(generated)]
            )
            if reference_completed.stderr.strip():
                raise CaptureError(
                    f"djpeg emitted diagnostics: {case_id}: {reference_completed.stderr.strip()}"
                )
            reference_width, reference_height, reference_rgb = parse_ppm_rgb(reference_ppm)
            if (reference_width, reference_height) != (width, height):
                raise CaptureError(f"reference decode geometry drifted: {case_id}")
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
                    f"ImageCraft emitted diagnostics: {case_id}: "
                    f"{imagecraft_completed.stderr.strip()}"
                )
            imagecraft_report = parse_json_stdout(imagecraft_completed, f"ImageCraft {case_id}")
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
            libjpeg_models = fitted_context_errors(
                libjpeg_blue["meanBlueByRow"],
                global_cb,
                clamped_cb,
                output_imcu_rows=output_imcu_rows,
            )
            imagecraft_models = fitted_context_errors(
                imagecraft_blue["meanBlueByRow"],
                global_cb,
                clamped_cb,
                output_imcu_rows=output_imcu_rows,
            )
            if not prefers_global(libjpeg_models):
                raise CaptureError(
                    f"libjpeg does not prefer global held-out iMCU context: {case_id}"
                )
            if not prefers_clamped(imagecraft_models):
                raise CaptureError(
                    f"ImageCraft/ImageIO does not prefer clamped held-out iMCU context: {case_id}"
                )

            generated_results.append(
                {
                    "id": case_id,
                    "codingMode": coding_mode,
                    "sampling": sampling,
                    "input": {
                        "byteCount": len(encoded),
                        "sha256": sha256_bytes(encoded),
                        "samplingFactors": actual_sampling,
                    },
                    "generator": generator_report,
                    "imageCraftFrameSamplingGeometry": frame_report,
                    "rawProbe": raw_report,
                    "postIDCT": {
                        "Y": {"sha256": sha256_bytes(y_plane), "rowCodes": y_rows},
                        "Cb": {
                            "sha256": sha256_bytes(cb_plane),
                            "rowCodes": cb_rows,
                            "generatedToPostIDCT": generated_to_post_idct,
                        },
                        "Cr": {"sha256": sha256_bytes(cr_plane), "rowCodes": cr_rows},
                    },
                    "libjpegModels": libjpeg_models,
                    "imageCraftModels": imagecraft_models,
                    "blueRowObservations": {
                        "libjpeg": libjpeg_blue,
                        "imageCraft": imagecraft_blue,
                    },
                    "crossBackend": compare_rgb_to_opaque_rgba(reference_rgb, imagecraft_rgba),
                    "imageCraft": imagecraft_report,
                    "libjpegRGBSHA256": sha256_bytes(reference_rgb),
                    "imageCraftRGBA8SHA256": sha256_bytes(imagecraft_rgba),
                    "libjpegPrefersGlobalContext": True,
                    "imageCraftPrefersIMCUClampedContext": True,
                }
            )

        coding_modes = {str(result["codingMode"]) for result in generated_results}
        sampling_modes = {str(result["sampling"]) for result in generated_results}
        if coding_modes != {"baseline", "progressive"} or sampling_modes != {"440", "420"}:
            raise CaptureError("generated iMCU context matrix is incomplete")

        natural = profile["retainedNaturalProgressiveCase"]
        natural_path = ROOT / str(natural["file"])
        natural_bytes = natural_path.read_bytes()
        if sha256_bytes(natural_bytes) != natural["sha256"]:
            raise CaptureError("retained natural progressive JPEG identity drifted")
        natural_ppm = temp / "natural.reference.ppm"
        natural_reference_completed = run(
            [str(djpeg), "-rgb", "-pnm", "-outfile", str(natural_ppm), str(natural_path)]
        )
        if natural_reference_completed.stderr.strip():
            raise CaptureError(
                "retained natural djpeg emitted diagnostics: "
                f"{natural_reference_completed.stderr.strip()}"
            )
        natural_width, natural_height, natural_reference_rgb = parse_ppm_rgb(natural_ppm)
        if (natural_width, natural_height) != (natural["width"], natural["height"]):
            raise CaptureError("retained natural progressive geometry drifted")
        natural_frame_completed = run(
            [
                str(imagecraft_evidence),
                "--jpeg-frame-sampling-geometry",
                str(natural_path),
            ]
        )
        if natural_frame_completed.stderr.strip():
            raise CaptureError(
                "retained natural frame geometry emitted diagnostics: "
                f"{natural_frame_completed.stderr.strip()}"
            )
        natural_frame_report = parse_json_stdout(
            natural_frame_completed,
            "retained natural frame geometry",
        )
        natural_frame_geometry = natural_frame_report.get("geometry")
        if (
            not isinstance(natural_frame_geometry, dict)
            or natural_frame_geometry.get("codingMode") != "progressiveDCT"
            or natural_frame_geometry.get("samplingMode") != "threeComponent420"
            or natural_frame_geometry.get("outputIMCURowHeight") != 16
            or natural_frame_geometry.get("totalIMCURowCount") != 81
            or natural_frame_geometry.get("internalIMCUBoundaryCount") != 80
            or natural_frame_geometry.get("verticalChromaBoundaryAdjacentOutputRowCount") != 160
        ):
            raise CaptureError("retained natural frame sampling geometry drifted")
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
        if natural_imagecraft_completed.stderr.strip():
            raise CaptureError(
                "retained natural ImageCraft emitted diagnostics: "
                f"{natural_imagecraft_completed.stderr.strip()}"
            )
        natural_imagecraft_report = parse_json_stdout(
            natural_imagecraft_completed, "retained natural ImageCraft"
        )
        natural_rgba = natural_rgba_path.read_bytes()
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
            raise CaptureError("retained natural residuals are not phase-localized at iMCU boundaries")

        after = capture_source_identity(temp / "source-after.json")
        before_hash = before.get("sourceIdentitySHA256")
        if not before_hash or before_hash != after.get("sourceIdentitySHA256"):
            raise CaptureError("ImageCraft source identity changed during JPEG iMCU context capture")

        report = {
            "schemaVersion": 1,
            "evidenceVersion": "imagecraft-jpeg-imcu-chroma-context-v1",
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
            "retainedNaturalProgressiveCase": {
                "id": natural["id"],
                "file": natural["file"],
                "sha256": natural["sha256"],
                "crossBackend": compare_rgb_to_opaque_rgba(
                    natural_reference_rgb,
                    natural_rgba,
                ),
                "phaseLocalization": natural_phase,
                "imageCraftFrameSamplingGeometry": natural_frame_report,
                "imageCraft": natural_imagecraft_report,
                "libjpegRGBSHA256": sha256_bytes(natural_reference_rgb),
                "imageCraftRGBA8SHA256": sha256_bytes(natural_rgba),
            },
            "summary": {
                "generatedCaseCount": len(generated_results),
                "codingModes": sorted(coding_modes),
                "samplingModes": sorted(sampling_modes),
                "allGeneratedLibjpegPreferGlobalContext": all(
                    bool(result["libjpegPrefersGlobalContext"])
                    for result in generated_results
                ),
                "allGeneratedImageCraftPreferIMCUClampedContext": all(
                    bool(result["imageCraftPrefersIMCUClampedContext"])
                    for result in generated_results
                ),
                "imageCraftGlobalBoundaryRMSEByCase": {
                    result["id"]: result["imageCraftModels"]["globalContext"][
                        "heldOutBoundary"
                    ]["rootMeanSquareCodeDifference"]
                    for result in generated_results
                },
                "imageCraftClampedBoundaryRMSEByCase": {
                    result["id"]: result["imageCraftModels"]["imcuClampedContext"][
                        "heldOutBoundary"
                    ]["rootMeanSquareCodeDifference"]
                    for result in generated_results
                },
                "libjpegGlobalBoundaryRMSEByCase": {
                    result["id"]: result["libjpegModels"]["globalContext"][
                        "heldOutBoundary"
                    ]["rootMeanSquareCodeDifference"]
                    for result in generated_results
                },
                "libjpegClampedBoundaryRMSEByCase": {
                    result["id"]: result["libjpegModels"]["imcuClampedContext"][
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
            "JPEG iMCU chroma-context captured: "
            f"generated={len(generated_results)} source={before_hash} output={output_path}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
