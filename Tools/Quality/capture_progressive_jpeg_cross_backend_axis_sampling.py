#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
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
    structural_scans,
)
from capture_progressive_jpeg_cross_backend_sampling import (
    compare_rgb_to_opaque_rgba,
    encode_jpeg,
    jpeg_sampling_factors,
)


DEFAULT_PROFILE = (
    ROOT / "Evidence/Experiments/ProgressiveJPEGCrossBackendAxisSampling/v1/profile.json"
)
DEFAULT_OUTPUT = (
    ROOT / ".artifacts/program/T101/progressive-jpeg-cross-backend-axis-sampling-v1.json"
)


def compare_rgb_payloads(reference: bytes, candidate: bytes) -> dict[str, Any]:
    if len(reference) != len(candidate) or len(reference) % 3 != 0:
        raise CaptureError("RGB source-fidelity payload shape mismatch")
    maximum = 0
    absolute_sum = 0
    squared_sum = 0
    differing = 0
    for expected, actual in zip(reference, candidate):
        difference = abs(expected - actual)
        if difference:
            differing += 1
        maximum = max(maximum, difference)
        absolute_sum += difference
        squared_sum += difference * difference
    sample_count = len(reference)
    mse = squared_sum / sample_count
    return {
        "sampleCount": sample_count,
        "differingSampleCount": differing,
        "maximumRGBCodeDifference": maximum,
        "meanAbsoluteRGBCodeDifference": absolute_sum / sample_count,
        "rootMeanSquareRGBCodeDifference": math.sqrt(mse),
        "psnrDB": math.inf
        if mse == 0
        else 10.0 * math.log10((255.0 * 255.0) / mse),
    }


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
        != "IMAGECRAFT-PROGRESSIVE-JPEG-CROSS-BACKEND-AXIS-SAMPLING-V1"
    ):
        raise CaptureError("unexpected progressive JPEG axis-sampling profile ID")

    source_spec = profile["source"]
    source_path = ROOT / str(source_spec["file"])
    source_bytes = source_path.read_bytes()
    if sha256_bytes(source_bytes) != source_spec["sha256"]:
        raise CaptureError("axis-sampling source JPEG identity drifted")

    with tempfile.TemporaryDirectory(prefix="imagecraft-progressive-axis-sampling-") as temp_raw:
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

        source_ppm = temp / "source.ppm"
        source_decode = run(
            [str(djpeg), "-rgb", "-pnm", "-outfile", str(source_ppm), str(source_path)]
        )
        if source_decode.stderr.strip():
            raise CaptureError(
                f"axis-sampling source decode emitted diagnostics: {source_decode.stderr.strip()}"
            )
        source_width, source_height, source_rgb = parse_ppm_rgb(source_ppm)

        encode = profile["encode"]
        base_cjpeg_args = ["-quality", str(int(encode["quality"]))]
        if encode.get("optimizeHuffman"):
            base_cjpeg_args.append("-optimize")
        if encode.get("progressive"):
            base_cjpeg_args.append("-progressive")

        expected_sampling = {
            "444": [(1, 1), (1, 1), (1, 1)],
            "422": [(2, 1), (1, 1), (1, 1)],
            "440": [(1, 2), (1, 1), (1, 1)],
            "420": [(2, 2), (1, 1), (1, 1)],
        }
        results: list[dict[str, Any]] = []
        for variant in profile["variants"]:
            variant_id = str(variant["id"])
            generated = temp / f"{variant_id}.jpg"
            cjpeg_args = [*base_cjpeg_args, "-sample", str(variant["sampling"]), str(source_ppm)]
            encode_jpeg(cjpeg, cjpeg_args, generated)
            encoded = generated.read_bytes()
            sampling = jpeg_sampling_factors(encoded)
            actual_sampling = [
                (item["horizontal"], item["vertical"]) for item in sampling
            ]
            if actual_sampling != expected_sampling[variant_id]:
                raise CaptureError(
                    f"axis-sampling factors drifted for {variant_id}: {actual_sampling}"
                )
            scan_count = len(structural_scans(encoded))
            if scan_count <= 1:
                raise CaptureError(f"axis-sampling variant is not progressive: {variant_id}")

            reference_ppm = temp / f"{variant_id}.reference.ppm"
            reference_decode = run(
                [str(djpeg), "-rgb", "-pnm", "-outfile", str(reference_ppm), str(generated)]
            )
            if reference_decode.stderr.strip():
                raise CaptureError(f"axis-sampling djpeg warned: {variant_id}")
            width, height, reference_rgb = parse_ppm_rgb(reference_ppm)
            if (width, height) != (source_width, source_height):
                raise CaptureError(f"axis-sampling geometry drifted: {variant_id}")

            imagecraft_raw = temp / f"{variant_id}.imagecraft.rgba"
            imagecraft_completed = run(
                [
                    str(imagecraft_evidence),
                    "--packed-rgba-export",
                    str(generated),
                    "--output",
                    str(imagecraft_raw),
                ]
            )
            imagecraft_report = parse_json_stdout(
                imagecraft_completed, f"axis-sampling ImageCraft {variant_id}"
            )
            rgba = imagecraft_raw.read_bytes()
            output = imagecraft_report.get("output")
            contract = imagecraft_report.get("contract")
            if (
                not isinstance(output, dict)
                or output.get("pixelWidth") != width
                or output.get("pixelHeight") != height
                or output.get("byteCount") != width * height * 4
                or len(rgba) != width * height * 4
                or not isinstance(contract, dict)
                or contract.get("channelOrder") != "RGBA"
                or contract.get("bitsPerChannel") != 8
                or contract.get("rowOrder") != "top-to-bottom"
                or contract.get("bytesPerRow") != width * 4
            ):
                raise CaptureError(f"axis-sampling ImageCraft contract drifted: {variant_id}")
            differential = compare_rgb_to_opaque_rgba(reference_rgb, rgba)
            if differential["allAlphaOpaque"] is not True:
                raise CaptureError(f"axis-sampling alpha is not opaque: {variant_id}")
            libjpeg_source_fidelity = compare_rgb_payloads(source_rgb, reference_rgb)
            imagecraft_source_fidelity = compare_rgb_to_opaque_rgba(source_rgb, rgba)
            if imagecraft_source_fidelity["allAlphaOpaque"] is not True:
                raise CaptureError(
                    f"axis-sampling source-fidelity alpha is not opaque: {variant_id}"
                )

            results.append(
                {
                    "id": variant_id,
                    "axis": variant["axis"],
                    "sampling": variant["sampling"],
                    "samplingFactors": sampling,
                    "generatedJPEGByteCount": len(encoded),
                    "generatedJPEGSHA256": sha256_bytes(encoded),
                    "scanCount": scan_count,
                    "libjpegFinalRGBSHA256": sha256_bytes(reference_rgb),
                    "imageCraftPackedRGBA8SHA256": sha256_bytes(rgba),
                    "imageCraft": imagecraft_report,
                    "differential": differential,
                    "sourceFidelity": {
                        "encoderInputRGBSHA256": sha256_bytes(source_rgb),
                        "libjpeg": libjpeg_source_fidelity,
                        "imageCraftImageIO": imagecraft_source_fidelity,
                    },
                }
            )

        by_id = {result["id"]: result for result in results}
        if set(by_id) != {"444", "422", "440", "420"}:
            raise CaptureError("axis-sampling result set is incomplete")
        def mae(variant_id: str) -> float:
            return float(by_id[variant_id]["differential"]["meanAbsoluteRGBCodeDifference"])
        def max_code(variant_id: str) -> int:
            return int(by_id[variant_id]["differential"]["maximumRGBCodeDifference"])
        def source_mae(variant_id: str, backend: str) -> float:
            return float(
                by_id[variant_id]["sourceFidelity"][backend][
                    "meanAbsoluteRGBCodeDifference"
                ]
            )
        def source_psnr(variant_id: str, backend: str) -> float:
            return float(by_id[variant_id]["sourceFidelity"][backend]["psnrDB"])

        after = capture_source_identity(temp / "source-after.json")
        before_hash = before.get("sourceIdentitySHA256")
        if not before_hash or before_hash != after.get("sourceIdentitySHA256"):
            raise CaptureError("ImageCraft source identity changed during axis-sampling capture")

        report = {
            "schemaVersion": 1,
            "evidenceVersion": "imagecraft-progressive-jpeg-cross-backend-axis-sampling-v1",
            "status": "source-bound-cross-backend-observation",
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
            "source": {
                "file": str(source_path.relative_to(ROOT)),
                "sha256": sha256_bytes(source_bytes),
                "width": source_width,
                "height": source_height,
                "decodedRGBSHA256": sha256_bytes(source_rgb),
            },
            "claimBoundary": profile["claimBoundary"],
            "variants": results,
            "summary": {
                "variantCount": len(results),
                "maximumRGBCodeDifferenceByVariant": {
                    variant_id: max_code(variant_id)
                    for variant_id in ("444", "422", "440", "420")
                },
                "meanAbsoluteRGBCodeDifferenceByVariant": {
                    variant_id: mae(variant_id)
                    for variant_id in ("444", "422", "440", "420")
                },
                "verticalOnlyMAEIncreaseOver444": mae("440") - mae("444"),
                "horizontalOnlyMAEIncreaseOver444": mae("422") - mae("444"),
                "bothAxesMAEIncreaseOver444": mae("420") - mae("444"),
                "verticalOnlyMaximumIncreaseOver444": max_code("440") - max_code("444"),
                "horizontalOnlyMaximumIncreaseOver444": max_code("422") - max_code("444"),
                "bothAxesMaximumIncreaseOver444": max_code("420") - max_code("444"),
                "sourceFidelityMAEByVariant": {
                    variant_id: {
                        "libjpeg": source_mae(variant_id, "libjpeg"),
                        "imageCraftImageIO": source_mae(
                            variant_id, "imageCraftImageIO"
                        ),
                    }
                    for variant_id in ("444", "422", "440", "420")
                },
                "sourceFidelityPSNRDBByVariant": {
                    variant_id: {
                        "libjpeg": source_psnr(variant_id, "libjpeg"),
                        "imageCraftImageIO": source_psnr(
                            variant_id, "imageCraftImageIO"
                        ),
                    }
                    for variant_id in ("444", "422", "440", "420")
                },
                "sourceFidelityMAEImageCraftMinusLibjpegByVariant": {
                    variant_id: source_mae(variant_id, "imageCraftImageIO")
                    - source_mae(variant_id, "libjpeg")
                    for variant_id in ("444", "422", "440", "420")
                },
            },
        }
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(
            "progressive JPEG axis-sampling captured: "
            f"variants={len(results)} source={before_hash} output={output_path}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
