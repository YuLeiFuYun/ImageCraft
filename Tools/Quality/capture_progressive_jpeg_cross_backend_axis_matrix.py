#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
import platform
import statistics
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
    structural_scans,
)
from capture_progressive_jpeg_cross_backend_axis_sampling import compare_rgb_payloads
from capture_progressive_jpeg_cross_backend_sampling import (
    compare_rgb_to_opaque_rgba,
    encode_jpeg,
    jpeg_sampling_factors,
)


DEFAULT_PROFILE = (
    ROOT / "Evidence/Experiments/ProgressiveJPEGCrossBackendAxisMatrix/v1/profile.json"
)
DEFAULT_OUTPUT = (
    ROOT / ".artifacts/program/T101/progressive-jpeg-cross-backend-axis-matrix-v1.json"
)


def mean(values: list[float]) -> float:
    if not values:
        raise CaptureError("cannot aggregate an empty value set")
    return statistics.fmean(values)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, default=DEFAULT_PROFILE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    profile_path = args.profile if args.profile.is_absolute() else ROOT / args.profile
    output_path = args.output if args.output.is_absolute() else ROOT / args.output
    profile = json.loads(profile_path.read_text())
    if (
        profile.get("profileID")
        != "IMAGECRAFT-PROGRESSIVE-JPEG-CROSS-BACKEND-AXIS-MATRIX-V1"
    ):
        raise CaptureError("unexpected progressive JPEG axis-matrix profile ID")

    expected_sampling = {
        "444": [(1, 1), (1, 1), (1, 1)],
        "422": [(2, 1), (1, 1), (1, 1)],
        "440": [(1, 2), (1, 1), (1, 1)],
        "420": [(2, 2), (1, 1), (1, 1)],
    }
    variants = profile["variants"]
    if [variant["id"] for variant in variants] != ["444", "422", "440", "420"]:
        raise CaptureError("axis-matrix variants drifted")

    with tempfile.TemporaryDirectory(prefix="imagecraft-progressive-axis-matrix-") as temp_raw:
        temp = Path(temp_raw)
        before = capture_source_identity(temp / "source-before.json")
        jpeg_prefix = Path(run(["brew", "--prefix", "jpeg-turbo"]).stdout.strip())
        cjpeg = jpeg_prefix / "bin/cjpeg"
        djpeg = jpeg_prefix / "bin/djpeg"
        if not cjpeg.is_file() or not djpeg.is_file():
            raise CaptureError("pinned jpeg-turbo tools are unavailable")
        cjpeg_version = run([str(cjpeg), "-version"]).stderr.strip()
        djpeg_version = run([str(djpeg), "-version"]).stderr.strip()

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
            raise CaptureError("ImageCraftEvidence binary is unavailable")

        encode = profile["encode"]
        base_cjpeg_args = ["-quality", str(int(encode["quality"]))]
        if encode.get("optimizeHuffman"):
            base_cjpeg_args.append("-optimize")
        if encode.get("progressive"):
            base_cjpeg_args.append("-progressive")

        source_results: list[dict[str, Any]] = []
        for source_spec in profile["sources"]:
            source_id = str(source_spec["id"])
            source_path = ROOT / str(source_spec["file"])
            source_bytes = source_path.read_bytes()
            if sha256_bytes(source_bytes) != source_spec["sha256"]:
                raise CaptureError(f"axis-matrix source identity drifted: {source_id}")
            source_ppm = temp / f"{source_id}.source.ppm"
            source_decode = run(
                [str(djpeg), "-rgb", "-pnm", "-outfile", str(source_ppm), str(source_path)]
            )
            if source_decode.stderr.strip():
                raise CaptureError(f"axis-matrix source decode warned: {source_id}")
            source_width, source_height, source_rgb = parse_ppm_rgb(source_ppm)

            variant_results: list[dict[str, Any]] = []
            for variant in variants:
                variant_id = str(variant["id"])
                generated = temp / f"{source_id}-{variant_id}.jpg"
                cjpeg_args = [
                    *base_cjpeg_args,
                    "-sample",
                    str(variant["sampling"]),
                    str(source_ppm),
                ]
                encode_jpeg(cjpeg, cjpeg_args, generated)
                encoded = generated.read_bytes()
                sampling = jpeg_sampling_factors(encoded)
                actual_sampling = [
                    (item["horizontal"], item["vertical"]) for item in sampling
                ]
                if actual_sampling != expected_sampling[variant_id]:
                    raise CaptureError(
                        f"axis-matrix sampling drifted: {source_id}/{variant_id}"
                    )
                scan_count = len(structural_scans(encoded))
                if scan_count <= 1:
                    raise CaptureError(
                        f"axis-matrix output is not progressive: {source_id}/{variant_id}"
                    )

                reference_ppm = temp / f"{source_id}-{variant_id}.reference.ppm"
                reference_decode = run(
                    [str(djpeg), "-rgb", "-pnm", "-outfile", str(reference_ppm), str(generated)]
                )
                if reference_decode.stderr.strip():
                    raise CaptureError(
                        f"axis-matrix djpeg warned: {source_id}/{variant_id}"
                    )
                width, height, reference_rgb = parse_ppm_rgb(reference_ppm)
                if (width, height) != (source_width, source_height):
                    raise CaptureError(
                        f"axis-matrix geometry drifted: {source_id}/{variant_id}"
                    )

                imagecraft_path = temp / f"{source_id}-{variant_id}.rgba"
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
                    imagecraft_completed,
                    f"axis-matrix ImageCraft {source_id}/{variant_id}",
                )
                rgba = imagecraft_path.read_bytes()
                if len(rgba) != width * height * 4:
                    raise CaptureError(
                        f"axis-matrix ImageCraft byte count drifted: {source_id}/{variant_id}"
                    )
                cross_backend = compare_rgb_to_opaque_rgba(reference_rgb, rgba)
                source_libjpeg = compare_rgb_payloads(source_rgb, reference_rgb)
                source_imageio = compare_rgb_to_opaque_rgba(source_rgb, rgba)
                if (
                    cross_backend["allAlphaOpaque"] is not True
                    or source_imageio["allAlphaOpaque"] is not True
                ):
                    raise CaptureError(
                        f"axis-matrix ImageCraft alpha drifted: {source_id}/{variant_id}"
                    )
                variant_results.append(
                    {
                        "id": variant_id,
                        "axis": variant["axis"],
                        "sampling": variant["sampling"],
                        "samplingFactors": sampling,
                        "generatedJPEGByteCount": len(encoded),
                        "generatedJPEGSHA256": sha256_bytes(encoded),
                        "scanCount": scan_count,
                        "crossBackend": cross_backend,
                        "sourceFidelity": {
                            "libjpeg": source_libjpeg,
                            "imageCraftImageIO": source_imageio,
                        },
                        "libjpegFinalRGBSHA256": sha256_bytes(reference_rgb),
                        "imageCraftPackedRGBA8SHA256": sha256_bytes(rgba),
                        "imageCraft": imagecraft_report,
                    }
                )

            by_id = {result["id"]: result for result in variant_results}
            def cross_mae(variant_id: str) -> float:
                return float(by_id[variant_id]["crossBackend"]["meanAbsoluteRGBCodeDifference"])
            def source_mae(variant_id: str, backend: str) -> float:
                return float(
                    by_id[variant_id]["sourceFidelity"][backend][
                        "meanAbsoluteRGBCodeDifference"
                    ]
                )
            source_results.append(
                {
                    "id": source_id,
                    "file": str(source_path.relative_to(ROOT)),
                    "sha256": sha256_bytes(source_bytes),
                    "width": source_width,
                    "height": source_height,
                    "encoderInputRGBSHA256": sha256_bytes(source_rgb),
                    "variants": variant_results,
                    "axisContrast": {
                        "horizontalOnlyMAEIncreaseOver444": cross_mae("422")
                        - cross_mae("444"),
                        "verticalOnlyMAEIncreaseOver444": cross_mae("440")
                        - cross_mae("444"),
                        "bothAxesMAEIncreaseOver444": cross_mae("420")
                        - cross_mae("444"),
                        "verticalCrossBackendMAEDominatesHorizontal": (
                            cross_mae("440") - cross_mae("444")
                            > cross_mae("422") - cross_mae("444")
                        ),
                    },
                    "sourceFidelity420": {
                        "libjpegMAE": source_mae("420", "libjpeg"),
                        "imageCraftImageIOMAE": source_mae(
                            "420", "imageCraftImageIO"
                        ),
                        "imageCraftMinusLibjpegMAE": source_mae(
                            "420", "imageCraftImageIO"
                        )
                        - source_mae("420", "libjpeg"),
                        "libjpegCloserByMAE": source_mae("420", "libjpeg")
                        < source_mae("420", "imageCraftImageIO"),
                    },
                }
            )

        after = capture_source_identity(temp / "source-after.json")
        before_hash = before.get("sourceIdentitySHA256")
        if not before_hash or before_hash != after.get("sourceIdentitySHA256"):
            raise CaptureError("ImageCraft source identity changed during axis-matrix capture")

        cross_mae_by_variant: dict[str, list[float]] = {
            variant_id: [] for variant_id in expected_sampling
        }
        source_mae_by_variant_backend: dict[str, dict[str, list[float]]] = {
            variant_id: {"libjpeg": [], "imageCraftImageIO": []}
            for variant_id in expected_sampling
        }
        for source in source_results:
            by_id = {result["id"]: result for result in source["variants"]}
            for variant_id in expected_sampling:
                cross_mae_by_variant[variant_id].append(
                    float(by_id[variant_id]["crossBackend"]["meanAbsoluteRGBCodeDifference"])
                )
                for backend in ("libjpeg", "imageCraftImageIO"):
                    source_mae_by_variant_backend[variant_id][backend].append(
                        float(
                            by_id[variant_id]["sourceFidelity"][backend][
                                "meanAbsoluteRGBCodeDifference"
                            ]
                        )
                    )

        report = {
            "schemaVersion": 1,
            "evidenceVersion": "imagecraft-progressive-jpeg-cross-backend-axis-matrix-v1",
            "status": "source-bound-cross-backend-matrix-observation",
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
                "jpegTurboPrefix": str(jpeg_prefix),
                "cjpegVersion": cjpeg_version,
                "djpegVersion": djpeg_version,
                "cjpegSHA256": sha256_file(cjpeg),
                "djpegSHA256": sha256_file(djpeg),
                "imageCraftEvidenceSHA256": sha256_file(imagecraft_evidence),
            },
            "claimBoundary": profile["claimBoundary"],
            "sources": source_results,
            "summary": {
                "sourceCount": len(source_results),
                "variantCountPerSource": len(variants),
                "caseCount": sum(len(source["variants"]) for source in source_results),
                "allVerticalCrossBackendMAEDominatesHorizontal": all(
                    bool(source["axisContrast"]["verticalCrossBackendMAEDominatesHorizontal"])
                    for source in source_results
                ),
                "all420LibjpegCloserToEncoderInputByMAE": all(
                    bool(source["sourceFidelity420"]["libjpegCloserByMAE"])
                    for source in source_results
                ),
                "meanCrossBackendMAEByVariant": {
                    variant_id: mean(values)
                    for variant_id, values in cross_mae_by_variant.items()
                },
                "meanSourceFidelityMAEByVariant": {
                    variant_id: {
                        backend: mean(values)
                        for backend, values in backend_values.items()
                    }
                    for variant_id, backend_values in source_mae_by_variant_backend.items()
                },
                "source420ImageCraftMinusLibjpegMAE": {
                    source["id"]: source["sourceFidelity420"][
                        "imageCraftMinusLibjpegMAE"
                    ]
                    for source in source_results
                },
            },
        }
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(
            "progressive JPEG axis matrix captured: "
            f"cases={report['summary']['caseCount']} source={before_hash} output={output_path}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
