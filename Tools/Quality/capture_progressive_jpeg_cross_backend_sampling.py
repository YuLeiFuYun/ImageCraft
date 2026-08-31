#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
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
    structural_scans,
)


DEFAULT_PROFILE = (
    ROOT / "Evidence/Experiments/ProgressiveJPEGCrossBackendSampling/v1/profile.json"
)
DEFAULT_OUTPUT = ROOT / ".artifacts/program/T101/progressive-jpeg-cross-backend-sampling-v1.json"


def encode_jpeg(cjpeg: Path, argv: list[str], output: Path) -> None:
    with output.open("wb") as handle:
        completed = subprocess.run(
            [str(cjpeg), *argv],
            stdout=handle,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
    if completed.returncode != 0:
        raise CaptureError(
            f"cjpeg failed ({completed.returncode}): {' '.join(argv)}\n{completed.stderr}"
        )
    if completed.stderr.strip():
        raise CaptureError(f"cjpeg emitted diagnostics: {completed.stderr.strip()}")


def jpeg_sampling_factors(data: bytes) -> list[dict[str, int]]:
    if not data.startswith(b"\xff\xd8"):
        raise CaptureError("sampling parser expected JPEG SOI")
    offset = 2
    while offset + 1 < len(data):
        if data[offset] != 0xFF:
            raise CaptureError("sampling parser lost JPEG marker synchronization")
        while offset < len(data) and data[offset] == 0xFF:
            offset += 1
        if offset >= len(data):
            raise CaptureError("sampling parser found truncated marker")
        marker = data[offset]
        offset += 1
        if marker == 0xD9:
            break
        if marker == 0x01 or marker == 0xD8 or 0xD0 <= marker <= 0xD7:
            continue
        if offset + 2 > len(data):
            raise CaptureError("sampling parser found truncated segment length")
        length = int.from_bytes(data[offset : offset + 2], "big")
        if length < 2 or offset + length > len(data):
            raise CaptureError("sampling parser found invalid segment range")
        if marker in {0xC0, 0xC1, 0xC2, 0xC9, 0xCA}:
            payload = data[offset + 2 : offset + length]
            if len(payload) < 6:
                raise CaptureError("sampling parser found short SOF")
            component_count = payload[5]
            expected = 6 + 3 * component_count
            if len(payload) != expected:
                raise CaptureError("sampling parser found malformed SOF component table")
            factors: list[dict[str, int]] = []
            for index in range(component_count):
                entry = 6 + index * 3
                packed = payload[entry + 1]
                factors.append(
                    {
                        "componentID": payload[entry],
                        "horizontal": packed >> 4,
                        "vertical": packed & 0x0F,
                    }
                )
            return factors
        offset += length
    raise CaptureError("sampling parser found no supported JPEG SOF")


def compare_rgb_to_opaque_rgba(rgb: bytes, rgba: bytes) -> dict[str, Any]:
    if len(rgba) % 4 != 0 or len(rgb) != (len(rgba) // 4) * 3:
        raise CaptureError("cross-backend RGB/RGBA payload shape mismatch")
    pixel_count = len(rgba) // 4
    histogram = [0] * 256
    maximum = 0
    per_channel = [0, 0, 0]
    sum_absolute = 0
    sum_squared = 0
    exact_pixels = 0
    alpha_opaque = True
    for pixel in range(pixel_count):
        rgb_offset = pixel * 3
        rgba_offset = pixel * 4
        pixel_maximum = 0
        for channel in range(3):
            difference = abs(rgb[rgb_offset + channel] - rgba[rgba_offset + channel])
            sum_absolute += difference
            sum_squared += difference * difference
            if difference > per_channel[channel]:
                per_channel[channel] = difference
            if difference > pixel_maximum:
                pixel_maximum = difference
            if difference > maximum:
                maximum = difference
        histogram[pixel_maximum] += 1
        if pixel_maximum == 0:
            exact_pixels += 1
        if rgba[rgba_offset + 3] != 255:
            alpha_opaque = False
    sample_count = pixel_count * 3
    mean_absolute = sum_absolute / sample_count
    rmse = math.sqrt(sum_squared / sample_count)
    psnr = math.inf if rmse == 0 else 20 * math.log10(255 / rmse)
    return {
        "pixelCount": pixel_count,
        "allAlphaOpaque": alpha_opaque,
        "maximumRGBCodeDifference": maximum,
        "maximumCodeDifferenceByChannel": {
            "red": per_channel[0],
            "green": per_channel[1],
            "blue": per_channel[2],
        },
        "meanAbsoluteRGBCodeDifference": mean_absolute,
        "rootMeanSquareRGBCodeDifference": rmse,
        "psnrDB": psnr,
        "exactPixelFraction": exact_pixels / pixel_count,
        "pixelMaximumDifferenceFractions": {
            "atMost1": sum(histogram[:2]) / pixel_count,
            "atMost2": sum(histogram[:3]) / pixel_count,
            "atMost4": sum(histogram[:5]) / pixel_count,
            "atMost8": sum(histogram[:9]) / pixel_count,
            "atMost16": sum(histogram[:17]) / pixel_count,
        },
        "pixelMaximumDifferenceHistogram": {
            str(index): count for index, count in enumerate(histogram) if count
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
    if profile.get("profileID") != "IMAGECRAFT-PROGRESSIVE-JPEG-CROSS-BACKEND-SAMPLING-V1":
        raise CaptureError("unexpected progressive cross-backend sampling profile ID")

    source_spec = profile["source"]
    source_path = ROOT / source_spec["file"]
    source_bytes = source_path.read_bytes()
    if sha256_bytes(source_bytes) != source_spec["sha256"]:
        raise CaptureError("cross-backend source JPEG identity drifted")

    with tempfile.TemporaryDirectory(prefix="imagecraft-progressive-cross-backend-") as temp_raw:
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
            raise CaptureError("ImageCraftEvidence release binary is unavailable after build")

        source_ppm = temp / "source.ppm"
        source_decode = run(
            [str(djpeg), "-rgb", "-pnm", "-outfile", str(source_ppm), str(source_path)]
        )
        if source_decode.stderr.strip():
            raise CaptureError(f"source djpeg decode emitted diagnostics: {source_decode.stderr.strip()}")
        source_width, source_height, source_rgb = parse_ppm_rgb(source_ppm)

        encode = profile["encode"]
        base_cjpeg_args = [
            "-quality",
            str(int(encode["quality"])),
        ]
        if encode.get("optimizeHuffman"):
            base_cjpeg_args.append("-optimize")
        if encode.get("progressive"):
            base_cjpeg_args.append("-progressive")

        expected_sampling = {
            "gray": [(1, 1)],
            "444": [(1, 1), (1, 1), (1, 1)],
            "422": [(2, 1), (1, 1), (1, 1)],
            "420": [(2, 2), (1, 1), (1, 1)],
        }
        results: list[dict[str, Any]] = []
        for variant in profile["variants"]:
            variant_id = str(variant["id"])
            generated = temp / f"{variant_id}.jpg"
            cjpeg_args = list(base_cjpeg_args)
            if variant["mode"] == "grayscale":
                cjpeg_args.append("-grayscale")
            elif variant["mode"] == "sampling":
                cjpeg_args.extend(["-sample", str(variant["sampling"])])
            else:
                raise CaptureError(f"unsupported sampling variant mode: {variant_id}")
            cjpeg_args.append(str(source_ppm))
            encode_jpeg(cjpeg, cjpeg_args, generated)

            encoded = generated.read_bytes()
            sampling = jpeg_sampling_factors(encoded)
            actual_sampling = [(item["horizontal"], item["vertical"]) for item in sampling]
            if actual_sampling != expected_sampling[variant_id]:
                raise CaptureError(
                    f"generated sampling factors drifted for {variant_id}: {actual_sampling}"
                )
            scan_count = len(structural_scans(encoded))
            if scan_count <= 1:
                raise CaptureError(f"generated variant is not progressive multi-scan: {variant_id}")

            reference_ppm = temp / f"{variant_id}.reference.ppm"
            reference_decode = run(
                [str(djpeg), "-rgb", "-pnm", "-outfile", str(reference_ppm), str(generated)]
            )
            if reference_decode.stderr.strip():
                raise CaptureError(f"variant djpeg emitted diagnostics: {variant_id}")
            width, height, reference_rgb = parse_ppm_rgb(reference_ppm)
            if (width, height) != (source_width, source_height):
                raise CaptureError(f"variant libjpeg geometry drifted: {variant_id}")

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
                imagecraft_completed,
                f"ImageCraft packed export {variant_id}",
            )
            imagecraft_rgba = imagecraft_raw.read_bytes()
            output = imagecraft_report.get("output")
            contract = imagecraft_report.get("contract")
            if (
                not isinstance(output, dict)
                or output.get("pixelWidth") != width
                or output.get("pixelHeight") != height
                or output.get("byteCount") != width * height * 4
                or not isinstance(contract, dict)
                or contract.get("channelOrder") != "RGBA"
                or contract.get("bitsPerChannel") != 8
                or contract.get("rowOrder") != "top-to-bottom"
                or contract.get("colorEncoding") != "sRGB"
            ):
                raise CaptureError(f"ImageCraft packed contract drifted: {variant_id}")
            differential = compare_rgb_to_opaque_rgba(reference_rgb, imagecraft_rgba)
            if not differential["allAlphaOpaque"]:
                raise CaptureError(f"ImageCraft JPEG output alpha is not opaque: {variant_id}")

            results.append(
                {
                    **variant,
                    "generatedJPEGByteCount": len(encoded),
                    "generatedJPEGSHA256": sha256_bytes(encoded),
                    "samplingFactors": sampling,
                    "scanCount": scan_count,
                    "libjpegFinalRGBSHA256": sha256_bytes(reference_rgb),
                    "imageCraftPackedRGBA8SHA256": sha256_bytes(imagecraft_rgba),
                    "imageCraft": imagecraft_report,
                    "differential": differential,
                }
            )

        by_id = {result["id"]: result for result in results}
        gray = by_id["gray"]["differential"]
        four44 = by_id["444"]["differential"]
        four22 = by_id["422"]["differential"]
        four20 = by_id["420"]["differential"]
        sampling_pressure_ordered = (
            gray["maximumRGBCodeDifference"] <= four44["maximumRGBCodeDifference"]
            <= four22["maximumRGBCodeDifference"] < four20["maximumRGBCodeDifference"]
            and gray["meanAbsoluteRGBCodeDifference"]
            < four44["meanAbsoluteRGBCodeDifference"]
            < four22["meanAbsoluteRGBCodeDifference"]
            < four20["meanAbsoluteRGBCodeDifference"]
        )

        after = capture_source_identity(temp / "source-after.json")
        source_identity = before.get("sourceIdentitySHA256")
        if not source_identity or source_identity != after.get("sourceIdentitySHA256"):
            raise CaptureError("ImageCraft source identity changed during cross-backend capture")

        report = {
            "schemaVersion": 1,
            "evidenceVersion": "imagecraft-progressive-jpeg-cross-backend-sampling-v1",
            "status": "source-bound-cross-backend-observation",
            "formalSourceBoundExecution": True,
            "productionBackendQualified": False,
            "profile": {
                "profileID": profile["profileID"],
                "path": str(profile_path.relative_to(ROOT)),
                "sha256": sha256_file(profile_path),
            },
            "sourceIdentity": {
                "sourceIdentitySHA256": source_identity,
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
                **source_spec,
                "decodedRGBByteCount": len(source_rgb),
                "decodedRGBSHA256": sha256_bytes(source_rgb),
                "width": source_width,
                "height": source_height,
            },
            "claimBoundary": profile["claimBoundary"],
            "variants": results,
            "summary": {
                "variantCount": len(results),
                "allGeometryExact": True,
                "allAlphaOpaque": True,
                "samplingPressureOrdered": sampling_pressure_ordered,
                "maximumRGBCodeDifferenceByVariant": {
                    result["id"]: result["differential"]["maximumRGBCodeDifference"]
                    for result in results
                },
                "meanAbsoluteRGBCodeDifferenceByVariant": {
                    result["id"]: result["differential"]["meanAbsoluteRGBCodeDifference"]
                    for result in results
                },
                "psnrDBByVariant": {
                    result["id"]: result["differential"]["psnrDB"]
                    for result in results
                },
            },
        }
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(
            "Progressive JPEG cross-backend sampling captured: "
            f"variants={len(results)} source={source_identity} output={output_path}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
