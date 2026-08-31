#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
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
from capture_progressive_jpeg_cross_backend_sampling import compare_rgb_to_opaque_rgba


DEFAULT_PROFILE = (
    ROOT / "Evidence/Experiments/ProgressiveJPEGChromaReconstruction/v1/profile.json"
)
DEFAULT_OUTPUT = (
    ROOT / ".artifacts/program/T101/progressive-jpeg-chroma-reconstruction-v1.json"
)
RAW_PROBE_SOURCE = ROOT / "Tools/Quality/LibJPEGTurboRawYCbCrProbe/main.c"


def build_raw_probe(temp: Path, jpeg_prefix: Path) -> Path:
    output = temp / "libjpeg-raw-ycbcr-probe"
    run(
        [
            "cc",
            "-O2",
            "-Wall",
            "-Wextra",
            f"-I{jpeg_prefix / 'include'}",
            str(RAW_PROBE_SOURCE),
            f"-L{jpeg_prefix / 'lib'}",
            "-ljpeg",
            f"-Wl,-rpath,{jpeg_prefix / 'lib'}",
            "-o",
            str(output),
        ]
    )
    return output


def fixed(value: float) -> int:
    return int(value * (1 << 16) + 0.5)


def ycbcr_tables() -> tuple[list[int], list[int], list[int], list[int]]:
    one_half = 1 << 15
    cr_r = [0] * 256
    cb_b = [0] * 256
    cr_g = [0] * 256
    cb_g = [0] * 256
    for code in range(256):
        centered = code - 128
        cr_r[code] = (fixed(1.40200) * centered + one_half) >> 16
        cb_b[code] = (fixed(1.77200) * centered + one_half) >> 16
        cr_g[code] = -fixed(0.71414) * centered
        cb_g[code] = -fixed(0.34414) * centered + one_half
    return cr_r, cb_b, cr_g, cb_g


def fancy_horizontal_row(row: bytes | bytearray | memoryview, output_width: int) -> bytearray:
    count = len(row)
    if count <= 2:
        raise CaptureError("fancy horizontal oracle requires more than two chroma samples")
    output = bytearray(count * 2)
    first = int(row[0])
    output[0] = first
    output[1] = (first * 3 + int(row[1]) + 2) >> 2
    for index in range(1, count - 1):
        value3 = int(row[index]) * 3
        output[2 * index] = (value3 + int(row[index - 1]) + 1) >> 2
        output[2 * index + 1] = (value3 + int(row[index + 1]) + 2) >> 2
    last = int(row[-1])
    output[-2] = (last * 3 + int(row[-2]) + 1) >> 2
    output[-1] = last
    return output[:output_width]


def nearest_horizontal_row(row: bytes | bytearray | memoryview, output_width: int) -> bytearray:
    output = bytearray(min(len(row) * 2, output_width))
    out_index = 0
    for value in row:
        if out_index < output_width:
            output[out_index] = value
            out_index += 1
        if out_index < output_width:
            output[out_index] = value
            out_index += 1
    return output


def fancy_vertical_row(
    source: bytes,
    *,
    width: int,
    height: int,
    output_y: int,
) -> bytearray:
    source_y = output_y // 2
    lower_half = (output_y & 1) != 0
    adjacent_y = source_y + 1 if lower_half else source_y - 1
    adjacent_y = min(height - 1, max(0, adjacent_y))
    bias = 2 if lower_half else 1
    source_offset = source_y * width
    adjacent_offset = adjacent_y * width
    return bytearray(
        (
            int(source[source_offset + x]) * 3
            + int(source[adjacent_offset + x])
            + bias
        )
        >> 2
        for x in range(width)
    )


def raw_vertical_row(
    source: bytes,
    *,
    width: int,
    output_y: int,
) -> memoryview:
    source_y = output_y // 2
    start = source_y * width
    return memoryview(source)[start : start + width]


def fancy_both_row(
    source: bytes,
    *,
    chroma_width: int,
    chroma_height: int,
    output_width: int,
    output_y: int,
) -> bytearray:
    if chroma_width <= 2:
        raise CaptureError("fancy h2v2 oracle requires more than two chroma samples")
    source_y = output_y // 2
    lower_half = (output_y & 1) != 0
    adjacent_y = source_y + 1 if lower_half else source_y - 1
    adjacent_y = min(chroma_height - 1, max(0, adjacent_y))
    source_offset = source_y * chroma_width
    adjacent_offset = adjacent_y * chroma_width
    sums = [
        int(source[source_offset + x]) * 3 + int(source[adjacent_offset + x])
        for x in range(chroma_width)
    ]
    output = bytearray(chroma_width * 2)
    this_sum = sums[0]
    next_sum = sums[1]
    output[0] = (this_sum * 4 + 8) >> 4
    output[1] = (this_sum * 3 + next_sum + 7) >> 4
    last_sum = this_sum
    this_sum = next_sum
    for index in range(1, chroma_width - 1):
        next_sum = sums[index + 1]
        output[2 * index] = (this_sum * 3 + last_sum + 8) >> 4
        output[2 * index + 1] = (this_sum * 3 + next_sum + 7) >> 4
        last_sum = this_sum
        this_sum = next_sum
    output[-2] = (this_sum * 3 + last_sum + 8) >> 4
    output[-1] = (this_sum * 4 + 7) >> 4
    return output[:output_width]


def reconstruct_chroma(
    source: bytes,
    *,
    chroma_width: int,
    chroma_height: int,
    output_width: int,
    output_height: int,
    horizontal: str,
    vertical: str,
) -> bytearray:
    if len(source) != chroma_width * chroma_height:
        raise CaptureError("raw chroma plane shape does not match metadata")
    output = bytearray(output_width * output_height)
    for output_y in range(output_height):
        if horizontal == "fancy" and vertical == "fancy":
            row = fancy_both_row(
                source,
                chroma_width=chroma_width,
                chroma_height=chroma_height,
                output_width=output_width,
                output_y=output_y,
            )
        elif vertical == "fancy":
            vertical_row = fancy_vertical_row(
                source,
                width=chroma_width,
                height=chroma_height,
                output_y=output_y,
            )
            if horizontal == "nearest":
                row = nearest_horizontal_row(vertical_row, output_width)
            else:
                row = fancy_horizontal_row(vertical_row, output_width)
        else:
            source_row = raw_vertical_row(
                source,
                width=chroma_width,
                output_y=output_y,
            )
            if horizontal == "fancy":
                row = fancy_horizontal_row(source_row, output_width)
            elif horizontal == "nearest":
                row = nearest_horizontal_row(source_row, output_width)
            else:
                raise CaptureError(f"unsupported horizontal reconstruction: {horizontal}")
        if len(row) != output_width:
            raise CaptureError("reconstructed chroma row width drifted")
        start = output_y * output_width
        output[start : start + output_width] = row
    return output


def reconstruct_rgb(
    y_plane: bytes,
    cb_plane: bytes,
    cr_plane: bytes,
    *,
    width: int,
    height: int,
    chroma_width: int,
    chroma_height: int,
    horizontal: str,
    vertical: str,
) -> bytes:
    if len(y_plane) != width * height:
        raise CaptureError("raw luma plane shape does not match image geometry")
    cb = reconstruct_chroma(
        cb_plane,
        chroma_width=chroma_width,
        chroma_height=chroma_height,
        output_width=width,
        output_height=height,
        horizontal=horizontal,
        vertical=vertical,
    )
    cr = reconstruct_chroma(
        cr_plane,
        chroma_width=chroma_width,
        chroma_height=chroma_height,
        output_width=width,
        output_height=height,
        horizontal=horizontal,
        vertical=vertical,
    )
    cr_r, cb_b, cr_g, cb_g = ycbcr_tables()
    rgb = bytearray(width * height * 3)
    for pixel in range(width * height):
        y = y_plane[pixel]
        cb_code = cb[pixel]
        cr_code = cr[pixel]
        red = y + cr_r[cr_code]
        green = y + ((cb_g[cb_code] + cr_g[cr_code]) >> 16)
        blue = y + cb_b[cb_code]
        red = min(255, max(0, red))
        green = min(255, max(0, green))
        blue = min(255, max(0, blue))
        offset = pixel * 3
        rgb[offset] = red
        rgb[offset + 1] = green
        rgb[offset + 2] = blue
    return bytes(rgb)


def reconstruct_rgb_float_triangle_quantized_idct(
    y_plane: bytes,
    cb_plane: bytes,
    cr_plane: bytes,
    *,
    width: int,
    height: int,
    chroma_width: int,
    chroma_height: int,
) -> bytes:
    """Project only post-IDCT reconstruction into a continuous triangle path.

    The input planes are already 8-bit results from libjpeg raw_data_out, so this
    intentionally does *not* model a float dequantizer or float IDCT.  It removes
    integer rounding from vertical/horizontal 3/4-1/4 interpolation and from the
    YCbCr transform until the final output-code quantization.  This is therefore a
    falsifier for rounding placement, not a jpegli implementation.
    """
    if len(y_plane) != width * height:
        raise CaptureError("float triangle luma plane shape does not match image geometry")
    if len(cb_plane) != chroma_width * chroma_height or len(cr_plane) != len(cb_plane):
        raise CaptureError("float triangle chroma plane shape does not match metadata")
    if chroma_width <= 2:
        raise CaptureError("float triangle projection requires more than two chroma samples")

    rgb = bytearray(width * height * 3)
    for output_y in range(height):
        source_y = output_y // 2
        adjacent_y = source_y + 1 if output_y & 1 else source_y - 1
        adjacent_y = min(chroma_height - 1, max(0, adjacent_y))
        source_offset = source_y * chroma_width
        adjacent_offset = adjacent_y * chroma_width
        cb_vertical = [
            0.75 * cb_plane[source_offset + x] + 0.25 * cb_plane[adjacent_offset + x]
            for x in range(chroma_width)
        ]
        cr_vertical = [
            0.75 * cr_plane[source_offset + x] + 0.25 * cr_plane[adjacent_offset + x]
            for x in range(chroma_width)
        ]
        for output_x in range(width):
            source_x = output_x // 2
            adjacent_x = source_x + 1 if output_x & 1 else source_x - 1
            adjacent_x = min(chroma_width - 1, max(0, adjacent_x))
            cb = 0.75 * cb_vertical[source_x] + 0.25 * cb_vertical[adjacent_x]
            cr = 0.75 * cr_vertical[source_x] + 0.25 * cr_vertical[adjacent_x]
            cb_centered = cb - 128.0
            cr_centered = cr - 128.0
            y = float(y_plane[output_y * width + output_x])
            red = y + 1.402 * cr_centered
            green = (
                y
                - (0.114 * 1.772 / 0.587) * cb_centered
                - (0.299 * 1.402 / 0.587) * cr_centered
            )
            blue = y + 1.772 * cb_centered
            output_offset = (output_y * width + output_x) * 3
            rgb[output_offset] = round(min(255.0, max(0.0, red)))
            rgb[output_offset + 1] = round(min(255.0, max(0.0, green)))
            rgb[output_offset + 2] = round(min(255.0, max(0.0, blue)))
    return bytes(rgb)


def compare_rgb(left: bytes, right: bytes) -> dict[str, Any]:
    if len(left) != len(right) or len(left) % 3 != 0:
        raise CaptureError("RGB differential payload shape mismatch")
    maximum = 0
    absolute = 0
    squared = 0
    differing = 0
    for first, second in zip(left, right):
        difference = abs(first - second)
        if difference:
            differing += 1
        maximum = max(maximum, difference)
        absolute += difference
        squared += difference * difference
    count = len(left)
    return {
        "byteCount": count,
        "differingByteCount": differing,
        "maximumCodeDifference": maximum,
        "meanAbsoluteCodeDifference": absolute / count,
        "meanSquaredCodeDifference": squared / count,
        "exact": differing == 0,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, default=DEFAULT_PROFILE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    profile_path = args.profile if args.profile.is_absolute() else ROOT / args.profile
    output_path = args.output if args.output.is_absolute() else ROOT / args.output
    profile = json.loads(profile_path.read_text())
    if profile.get("profileID") != "IMAGECRAFT-PROGRESSIVE-JPEG-CHROMA-RECONSTRUCTION-V1":
        raise CaptureError("unexpected chroma reconstruction profile ID")

    source_spec = profile["source"]
    source_path = ROOT / str(source_spec["file"])
    source_bytes = source_path.read_bytes()
    if sha256_bytes(source_bytes) != source_spec["sha256"]:
        raise CaptureError("chroma reconstruction source identity drifted")

    with tempfile.TemporaryDirectory(prefix="imagecraft-chroma-reconstruction-") as temp_raw:
        temp = Path(temp_raw)
        before = capture_source_identity(temp / "source-before.json")
        jpeg_prefix = Path(run(["brew", "--prefix", "jpeg-turbo"]).stdout.strip())
        djpeg = jpeg_prefix / "bin/djpeg"
        if not djpeg.is_file():
            raise CaptureError("pinned djpeg is unavailable")
        djpeg_version = run([str(djpeg), "-version"]).stderr.strip()
        required_version = profile.get("requiredLibJPEGTurboVersionPrefix")
        if not isinstance(required_version, str) or not djpeg_version.startswith(required_version):
            raise CaptureError("djpeg runtime is outside chroma reconstruction qualification")
        raw_probe = build_raw_probe(temp, jpeg_prefix)

        reference_ppm = temp / "reference.ppm"
        reference_decode = run(
            [str(djpeg), "-rgb", "-pnm", "-outfile", str(reference_ppm), str(source_path)]
        )
        if reference_decode.stderr.strip():
            raise CaptureError(
                f"chroma reconstruction djpeg emitted diagnostics: {reference_decode.stderr.strip()}"
            )
        width, height, reference_rgb = parse_ppm_rgb(reference_ppm)

        raw_prefix = temp / "raw"
        raw_completed = run([str(raw_probe), str(source_path), str(raw_prefix)])
        if raw_completed.stderr.strip():
            raise CaptureError(
                f"raw-plane probe emitted diagnostics: {raw_completed.stderr.strip()}"
            )
        raw_report = parse_json_stdout(raw_completed, "raw YCbCr probe")
        components = raw_report.get("components")
        if (
            raw_report.get("warningCount") != 0
            or raw_report.get("width") != width
            or raw_report.get("height") != height
            or raw_report.get("maxHorizontalSamplingFactor") != 2
            or raw_report.get("maxVerticalSamplingFactor") != 2
            or not isinstance(components, list)
            or len(components) != 3
        ):
            raise CaptureError("raw-plane probe contract drifted")
        expected_sampling = [(2, 2), (1, 1), (1, 1)]
        actual_sampling = [
            (component.get("horizontalSamplingFactor"), component.get("verticalSamplingFactor"))
            for component in components
            if isinstance(component, dict)
        ]
        if actual_sampling != expected_sampling:
            raise CaptureError(f"raw-plane source is not expected 4:2:0: {actual_sampling}")

        y_plane = Path(f"{raw_prefix}-Y.raw").read_bytes()
        cb_plane = Path(f"{raw_prefix}-Cb.raw").read_bytes()
        cr_plane = Path(f"{raw_prefix}-Cr.raw").read_bytes()
        chroma_width = int(components[1]["width"])
        chroma_height = int(components[1]["height"])
        if (
            components[2].get("width") != chroma_width
            or components[2].get("height") != chroma_height
        ):
            raise CaptureError("Cb/Cr raw plane geometry differs")

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
        imagecraft_raw = temp / "imagecraft.rgba"
        imagecraft_completed = run(
            [
                str(imagecraft_evidence),
                "--packed-rgba-export",
                str(source_path),
                "--output",
                str(imagecraft_raw),
            ]
        )
        imagecraft_report = parse_json_stdout(imagecraft_completed, "ImageCraft packed RGBA")
        imagecraft_rgba = imagecraft_raw.read_bytes()
        if len(imagecraft_rgba) != width * height * 4:
            raise CaptureError("ImageCraft packed RGBA byte count drifted")

        candidate_results: list[dict[str, Any]] = []
        for candidate in profile["candidates"]:
            candidate_id = str(candidate["id"])
            horizontal = str(candidate["horizontal"])
            vertical = str(candidate["vertical"])
            if candidate_id == "float-triangle-quantized-idct":
                reconstructed = reconstruct_rgb_float_triangle_quantized_idct(
                    y_plane,
                    cb_plane,
                    cr_plane,
                    width=width,
                    height=height,
                    chroma_width=chroma_width,
                    chroma_height=chroma_height,
                )
            else:
                reconstructed = reconstruct_rgb(
                    y_plane,
                    cb_plane,
                    cr_plane,
                    width=width,
                    height=height,
                    chroma_width=chroma_width,
                    chroma_height=chroma_height,
                    horizontal=horizontal,
                    vertical=vertical,
                )
            libjpeg_differential = compare_rgb(reconstructed, reference_rgb)
            if candidate_id == "fancy-h-fancy-v" and libjpeg_differential["exact"] is not True:
                raise CaptureError(
                    "independent fancy h2v2 reconstruction does not exactly reproduce djpeg"
                )
            imageio_differential = compare_rgb_to_opaque_rgba(reconstructed, imagecraft_rgba)
            if imageio_differential["allAlphaOpaque"] is not True:
                raise CaptureError("ImageCraft output alpha is not opaque")
            candidate_results.append(
                {
                    "id": candidate_id,
                    "horizontal": horizontal,
                    "vertical": vertical,
                    "reconstructedRGBSHA256": sha256_bytes(reconstructed),
                    "againstOneShotLibJPEG": libjpeg_differential,
                    "againstImageCraftImageIO": imageio_differential,
                }
            )

        by_id = {result["id"]: result for result in candidate_results}
        if set(by_id) != {
            "fancy-h-fancy-v",
            "float-triangle-quantized-idct",
            "fancy-h-nearest-v",
            "nearest-h-fancy-v",
            "nearest-h-nearest-v",
        }:
            raise CaptureError("chroma reconstruction candidate set is incomplete")
        ranking = sorted(
            candidate_results,
            key=lambda result: float(
                result["againstImageCraftImageIO"]["meanAbsoluteRGBCodeDifference"]
            ),
        )

        after = capture_source_identity(temp / "source-after.json")
        before_hash = before.get("sourceIdentitySHA256")
        if not before_hash or before_hash != after.get("sourceIdentitySHA256"):
            raise CaptureError("ImageCraft source identity changed during chroma reconstruction capture")

        report = {
            "schemaVersion": 1,
            "evidenceVersion": "imagecraft-progressive-jpeg-chroma-reconstruction-v1",
            "status": "source-bound-reconstruction-mechanism-observation",
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
                "djpegVersion": djpeg_version,
                "djpegSHA256": sha256_file(djpeg),
                "rawProbeSHA256": sha256_file(raw_probe),
                "rawProbeSourceSHA256": sha256_file(RAW_PROBE_SOURCE),
                "imageCraftEvidenceSHA256": sha256_file(imagecraft_evidence),
            },
            "source": {
                "file": str(source_path.relative_to(ROOT)),
                "sha256": sha256_bytes(source_bytes),
                "width": width,
                "height": height,
                "oneShotLibJPEGRGBSHA256": sha256_bytes(reference_rgb),
                "imageCraftPackedRGBA8SHA256": sha256_bytes(imagecraft_rgba),
            },
            "mechanismReference": profile.get("mechanismReference"),
            "rawPlanes": {
                "probe": raw_report,
                "Y": {"byteCount": len(y_plane), "sha256": sha256_bytes(y_plane)},
                "Cb": {"byteCount": len(cb_plane), "sha256": sha256_bytes(cb_plane)},
                "Cr": {"byteCount": len(cr_plane), "sha256": sha256_bytes(cr_plane)},
            },
            "imageCraft": imagecraft_report,
            "claimBoundary": profile["claimBoundary"],
            "candidates": candidate_results,
            "summary": {
                "candidateCount": len(candidate_results),
                "independentFancyH2V2ExactOneShotLibJPEG": by_id[
                    "fancy-h-fancy-v"
                ]["againstOneShotLibJPEG"]["exact"],
                "floatTriangleQuantizedIDCTMovesTowardImageCraft": (
                    float(
                        by_id["float-triangle-quantized-idct"][
                            "againstImageCraftImageIO"
                        ]["meanAbsoluteRGBCodeDifference"]
                    )
                    < float(
                        by_id["fancy-h-fancy-v"]["againstImageCraftImageIO"][
                            "meanAbsoluteRGBCodeDifference"
                        ]
                    )
                ),
                "candidateRankingByImageCraftMAE": [result["id"] for result in ranking],
                "imageCraftMAEByCandidate": {
                    result["id"]: result["againstImageCraftImageIO"][
                        "meanAbsoluteRGBCodeDifference"
                    ]
                    for result in candidate_results
                },
                "imageCraftMaximumDifferenceByCandidate": {
                    result["id"]: result["againstImageCraftImageIO"][
                        "maximumRGBCodeDifference"
                    ]
                    for result in candidate_results
                },
            },
        }
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(
            "progressive JPEG chroma reconstruction captured: "
            f"candidates={len(candidate_results)} source={before_hash} output={output_path}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
