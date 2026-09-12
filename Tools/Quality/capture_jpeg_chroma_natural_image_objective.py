#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import platform
import tempfile
from typing import Any

import numpy as np

from capture_libjpeg_progressive_suspension import (
    CaptureError,
    ROOT,
    capture_source_identity,
    parse_json_stdout,
    parse_ppm_rgb,
    run,
    sha256_bytes,
    sha256_file,
)
from capture_progressive_jpeg_chroma_reconstruction import (
    RAW_PROBE_SOURCE,
    build_raw_probe,
    fancy_horizontal_row,
    nearest_horizontal_row,
    reconstruct_rgb,
    ycbcr_tables,
)


DEFAULT_PROFILE = ROOT / "Evidence/Experiments/JPEGChromaNaturalImageObjective/v1/profile.json"
DEFAULT_OUTPUT = ROOT / ".artifacts/program/T101/jpeg-chroma-natural-image-objective-v1.json"


def adaptive_vertical_row_v3(
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
    result = bytearray(width)
    for x in range(width):
        current = int(source[source_offset + x])
        if adjacent_y == source_y:
            result[x] = current
            continue
        low = min(source_y, adjacent_y)
        high = max(source_y, adjacent_y)
        cross = abs(
            int(source[high * width + x]) - int(source[low * width + x])
        )
        left = (
            abs(int(source[low * width + x]) - int(source[(low - 1) * width + x]))
            if low > 0
            else cross
        )
        right = (
            abs(int(source[(high + 1) * width + x]) - int(source[high * width + x]))
            if high + 1 < height
            else cross
        )
        if cross > 2 * max(left, right):
            result[x] = current
        else:
            adjacent = int(source[adjacent_offset + x])
            result[x] = (3 * current + adjacent + bias) >> 2
    return result


def reconstruct_chroma_adaptive_v3(
    source: bytes,
    *,
    chroma_width: int,
    chroma_height: int,
    output_width: int,
    output_height: int,
    horizontal: str,
) -> bytearray:
    if len(source) != chroma_width * chroma_height:
        raise CaptureError("adaptive chroma plane shape does not match metadata")
    output = bytearray(output_width * output_height)
    for output_y in range(output_height):
        vertical = adaptive_vertical_row_v3(
            source,
            width=chroma_width,
            height=chroma_height,
            output_y=output_y,
        )
        if horizontal == "fancy":
            row = fancy_horizontal_row(vertical, output_width)
        elif horizontal == "nearest":
            row = nearest_horizontal_row(vertical, output_width)
        else:
            raise CaptureError(f"unsupported adaptive horizontal mode: {horizontal}")
        if len(row) != output_width:
            raise CaptureError("adaptive reconstructed chroma row width drifted")
        start = output_y * output_width
        output[start : start + output_width] = row
    return output


def reconstruct_rgb_adaptive_v3(
    y_plane: bytes,
    cb_plane: bytes,
    cr_plane: bytes,
    *,
    width: int,
    height: int,
    chroma_width: int,
    chroma_height: int,
    horizontal: str,
) -> bytes:
    if len(y_plane) != width * height:
        raise CaptureError("adaptive luma plane shape does not match image geometry")
    cb = reconstruct_chroma_adaptive_v3(
        cb_plane,
        chroma_width=chroma_width,
        chroma_height=chroma_height,
        output_width=width,
        output_height=height,
        horizontal=horizontal,
    )
    cr = reconstruct_chroma_adaptive_v3(
        cr_plane,
        chroma_width=chroma_width,
        chroma_height=chroma_height,
        output_width=width,
        output_height=height,
        horizontal=horizontal,
    )
    cr_r, cb_b, cr_g, cb_g = ycbcr_tables()
    rgb = bytearray(width * height * 3)
    for pixel in range(width * height):
        y = y_plane[pixel]
        cb_code = cb[pixel]
        cr_code = cr[pixel]
        red = min(255, max(0, y + cr_r[cr_code]))
        green = min(255, max(0, y + ((cb_g[cb_code] + cr_g[cr_code]) >> 16)))
        blue = min(255, max(0, y + cb_b[cb_code]))
        offset = pixel * 3
        rgb[offset] = red
        rgb[offset + 1] = green
        rgb[offset + 2] = blue
    return bytes(rgb)


def block_ssim_rgb(
    reference: bytes,
    candidate: bytes,
    *,
    width: int,
    height: int,
    block_width: int,
    block_height: int,
    k1: float,
    k2: float,
    sample_range: float,
) -> dict[str, Any]:
    if len(reference) != width * height * 3 or len(candidate) != len(reference):
        raise CaptureError("block-SSIM RGB payload shape mismatch")
    cropped_width = width - width % block_width
    cropped_height = height - height % block_height
    if cropped_width <= 0 or cropped_height <= 0:
        raise CaptureError("block-SSIM image is smaller than one objective block")
    first = np.frombuffer(reference, dtype=np.uint8).reshape(height, width, 3)
    second = np.frombuffer(candidate, dtype=np.uint8).reshape(height, width, 3)
    first = first[:cropped_height, :cropped_width, :].astype(np.float64)
    second = second[:cropped_height, :cropped_width, :].astype(np.float64)
    blocks_y = cropped_height // block_height
    blocks_x = cropped_width // block_width
    first = first.reshape(blocks_y, block_height, blocks_x, block_width, 3).transpose(0, 2, 1, 3, 4)
    second = second.reshape(blocks_y, block_height, blocks_x, block_width, 3).transpose(0, 2, 1, 3, 4)
    mu_first = first.mean(axis=(2, 3))
    mu_second = second.mean(axis=(2, 3))
    centered_first = first - mu_first[:, :, None, None, :]
    centered_second = second - mu_second[:, :, None, None, :]
    variance_first = (centered_first * centered_first).mean(axis=(2, 3))
    variance_second = (centered_second * centered_second).mean(axis=(2, 3))
    covariance = (centered_first * centered_second).mean(axis=(2, 3))
    c1 = (k1 * sample_range) ** 2
    c2 = (k2 * sample_range) ** 2
    numerator = (2 * mu_first * mu_second + c1) * (2 * covariance + c2)
    denominator = (mu_first * mu_first + mu_second * mu_second + c1) * (
        variance_first + variance_second + c2
    )
    values = numerator / denominator
    channel_means = values.mean(axis=(0, 1))
    return {
        "meanRGBChannelBlockSSIM8x8": float(values.mean()),
        "meanBlockSSIMByChannel": {
            "red": float(channel_means[0]),
            "green": float(channel_means[1]),
            "blue": float(channel_means[2]),
        },
        "blockCount": int(blocks_x * blocks_y),
        "croppedWidth": int(cropped_width),
        "croppedHeight": int(cropped_height),
    }


def rgb_error(reference: bytes, candidate: bytes) -> dict[str, Any]:
    first = np.frombuffer(reference, dtype=np.uint8).astype(np.int16)
    second = np.frombuffer(candidate, dtype=np.uint8).astype(np.int16)
    if first.shape != second.shape:
        raise CaptureError("RGB objective payload shape mismatch")
    delta = np.abs(first - second).astype(np.int32)
    return {
        "meanAbsoluteRGBCodeDifference": float(delta.mean()),
        "rootMeanSquareRGBCodeDifference": float(math.sqrt(float((delta * delta).mean()))),
        "maximumRGBCodeDifference": int(delta.max(initial=0)),
        "differingByteCount": int(np.count_nonzero(delta)),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, default=DEFAULT_PROFILE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    profile_path = args.profile if args.profile.is_absolute() else ROOT / args.profile
    output_path = args.output if args.output.is_absolute() else ROOT / args.output
    profile = json.loads(profile_path.read_text())
    if profile.get("profileID") != "IMAGECRAFT-JPEG-CHROMA-NATURAL-IMAGE-OBJECTIVE-V1":
        raise CaptureError("unexpected natural-image chroma objective profile")
    objective = profile["objective"]
    if objective.get("primary") != "meanRGBChannelBlockSSIM8x8":
        raise CaptureError("unexpected natural-image objective primary metric")
    manifest_path = ROOT / str(profile["corpusManifest"])
    manifest = json.loads(manifest_path.read_text())
    sources = {item["id"]: item for item in manifest["sources"]}
    all_variants_by_source: dict[str, list[dict[str, Any]]] = {}
    for item in manifest["variants"]:
        all_variants_by_source.setdefault(str(item["sourceID"]), []).append(item)
    variants = {
        item["sourceID"]: item
        for item in manifest["variants"]
        if item["scanScriptID"] == profile["encodedVariantScanScriptID"]
    }
    source_ids = [str(item) for item in profile["sourceIDs"]]
    if set(source_ids) != set(sources) or set(source_ids) != set(variants):
        raise CaptureError("natural-image objective corpus selection drifted")

    with tempfile.TemporaryDirectory(prefix="imagecraft-jpeg-natural-objective-") as temp_raw:
        temp = Path(temp_raw)
        before = capture_source_identity(temp / "source-before.json")
        jpeg_prefix = Path(run(["brew", "--prefix", "jpeg-turbo"]).stdout.strip())
        djpeg = jpeg_prefix / "bin/djpeg"
        djpeg_version = run([str(djpeg), "-version"]).stderr.strip()
        required = str(profile["requiredLibJPEGTurboVersionPrefix"])
        if not djpeg_version.startswith(required):
            raise CaptureError("djpeg runtime is outside natural-image objective qualification")
        raw_probe = build_raw_probe(temp, jpeg_prefix)
        case_results: list[dict[str, Any]] = []
        winner_counts = {str(item["id"]): 0 for item in profile["candidates"]}

        for source_id in source_ids:
            source_spec = sources[source_id]
            variant_spec = variants[source_id]
            source_path = manifest_path.parent / str(source_spec["file"])
            variant_path = manifest_path.parent / str(variant_spec["file"])
            source_bytes = source_path.read_bytes()
            variant_bytes = variant_path.read_bytes()
            if sha256_bytes(source_bytes) != source_spec["sha256"]:
                raise CaptureError(f"source hash drifted: {source_id}")
            if sha256_bytes(variant_bytes) != variant_spec["sha256"]:
                raise CaptureError(f"variant hash drifted: {source_id}")

            source_ppm = temp / f"{source_id}.source.ppm"
            source_decode = run([str(djpeg), "-rgb", "-pnm", "-outfile", str(source_ppm), str(source_path)])
            if source_decode.stderr.strip():
                raise CaptureError(f"source djpeg emitted diagnostics: {source_id}")
            width, height, source_rgb = parse_ppm_rgb(source_ppm)
            if width != source_spec["width"] or height != source_spec["height"]:
                raise CaptureError(f"source geometry drifted: {source_id}")

            scan_script_final_ppm_hashes: dict[str, str] = {}
            selected_variant_rgb: bytes | None = None
            for scan_variant in all_variants_by_source[source_id]:
                scan_path = manifest_path.parent / str(scan_variant["file"])
                scan_bytes = scan_path.read_bytes()
                if sha256_bytes(scan_bytes) != scan_variant["sha256"]:
                    raise CaptureError(
                        f"scan-script variant hash drifted: {source_id}/{scan_variant['scanScriptID']}"
                    )
                scan_ppm = temp / f"{source_id}.{scan_variant['scanScriptID']}.ppm"
                scan_decode = run(
                    [str(djpeg), "-rgb", "-pnm", "-outfile", str(scan_ppm), str(scan_path)]
                )
                if scan_decode.stderr.strip():
                    raise CaptureError(
                        f"scan-script djpeg emitted diagnostics: {source_id}/{scan_variant['scanScriptID']}"
                    )
                scan_width, scan_height, scan_rgb = parse_ppm_rgb(scan_ppm)
                if (scan_width, scan_height) != (width, height):
                    raise CaptureError(f"scan-script geometry drifted: {source_id}")
                ppm_hash = sha256_file(scan_ppm)
                scan_script_final_ppm_hashes[str(scan_variant["scanScriptID"])] = ppm_hash
                if scan_variant["scanScriptID"] == profile["encodedVariantScanScriptID"]:
                    selected_variant_rgb = scan_rgb
            if len(set(scan_script_final_ppm_hashes.values())) != 1:
                raise CaptureError(f"scan scripts changed final pixels: {source_id}")
            invariant_ppm_hash = next(iter(scan_script_final_ppm_hashes.values()))
            if invariant_ppm_hash != source_spec["referenceDecodedPPMSHA256"]:
                raise CaptureError(f"manifest reference decoded PPM drifted: {source_id}")
            if selected_variant_rgb is None:
                raise CaptureError(f"selected scan-script RGB was not captured: {source_id}")

            raw_prefix = temp / f"{source_id}.raw"
            raw_completed = run([str(raw_probe), str(variant_path), str(raw_prefix)])
            if raw_completed.stderr.strip():
                raise CaptureError(f"raw probe emitted diagnostics: {source_id}")
            raw_report = parse_json_stdout(raw_completed, f"raw probe {source_id}")
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
                raise CaptureError(f"raw probe contract drifted: {source_id}")
            factors = [
                (item.get("horizontalSamplingFactor"), item.get("verticalSamplingFactor"))
                for item in components
            ]
            if factors != [(2, 2), (1, 1), (1, 1)]:
                raise CaptureError(f"variant is not 4:2:0: {source_id}: {factors}")
            y_plane = Path(f"{raw_prefix}-Y.raw").read_bytes()
            cb_plane = Path(f"{raw_prefix}-Cb.raw").read_bytes()
            cr_plane = Path(f"{raw_prefix}-Cr.raw").read_bytes()
            chroma_width = int(components[1]["width"])
            chroma_height = int(components[1]["height"])

            candidate_results: list[dict[str, Any]] = []
            for candidate in profile["candidates"]:
                candidate_id = str(candidate["id"])
                horizontal = str(candidate["horizontal"])
                vertical = str(candidate["vertical"])
                if vertical == "adaptive-v3":
                    reconstructed = reconstruct_rgb_adaptive_v3(
                        y_plane,
                        cb_plane,
                        cr_plane,
                        width=width,
                        height=height,
                        chroma_width=chroma_width,
                        chroma_height=chroma_height,
                        horizontal=horizontal,
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
                ssim = block_ssim_rgb(
                    source_rgb,
                    reconstructed,
                    width=width,
                    height=height,
                    block_width=int(objective["blockWidth"]),
                    block_height=int(objective["blockHeight"]),
                    k1=float(objective["ssimK1"]),
                    k2=float(objective["ssimK2"]),
                    sample_range=float(objective["sampleRange"]),
                )
                error = rgb_error(source_rgb, reconstructed)
                if candidate_id == "fancy-h-fancy-v" and reconstructed != selected_variant_rgb:
                    raise CaptureError(
                        f"centered reconstruction does not reproduce libjpeg final RGB: {source_id}"
                    )
                candidate_results.append({
                    "id": candidate_id,
                    "horizontal": horizontal,
                    "vertical": vertical,
                    "reconstructedRGBSHA256": sha256_bytes(reconstructed),
                    "objective": {**ssim, **error},
                })

            ranking = sorted(
                candidate_results,
                key=lambda item: (
                    -float(item["objective"]["meanRGBChannelBlockSSIM8x8"]),
                    float(item["objective"]["meanAbsoluteRGBCodeDifference"]),
                    str(item["id"]),
                ),
            )
            winner = str(ranking[0]["id"])
            winner_counts[winner] += 1
            case_results.append({
                "sourceID": source_id,
                "contentClass": source_spec["contentClass"],
                "source": {
                    "file": str(source_path.relative_to(ROOT)),
                    "sha256": source_spec["sha256"],
                    "decodedRGBSHA256": sha256_bytes(source_rgb),
                    "width": width,
                    "height": height,
                },
                "encodedVariant": {
                    "file": str(variant_path.relative_to(ROOT)),
                    "sha256": variant_spec["sha256"],
                    "scanScriptID": variant_spec["scanScriptID"],
                    "centeredCandidateExactFinalLibJPEG": True,
                },
                "scanScriptFinalPixelInvariance": {
                    "allRetainedScanScriptsExact": True,
                    "decodedPPMSHA256ByScanScript": scan_script_final_ppm_hashes,
                    "manifestReferenceDecodedPPMSHA256": invariant_ppm_hash,
                },
                "rawProbe": raw_report,
                "rawPlaneSHA256": {
                    "Y": sha256_bytes(y_plane),
                    "Cb": sha256_bytes(cb_plane),
                    "Cr": sha256_bytes(cr_plane),
                },
                "candidates": candidate_results,
                "ranking": [str(item["id"]) for item in ranking],
                "winner": winner,
            })

        after = capture_source_identity(temp / "source-after.json")
        source_identity = before.get("sourceIdentitySHA256")
        if not source_identity or source_identity != after.get("sourceIdentitySHA256"):
            raise CaptureError("source identity changed during natural-image objective capture")
        mean_ssim_by_candidate: dict[str, float] = {}
        mean_mae_by_candidate: dict[str, float] = {}
        for candidate in profile["candidates"]:
            candidate_id = str(candidate["id"])
            metrics = [
                next(item for item in case["candidates"] if item["id"] == candidate_id)["objective"]
                for case in case_results
            ]
            mean_ssim_by_candidate[candidate_id] = float(
                sum(float(item["meanRGBChannelBlockSSIM8x8"]) for item in metrics) / len(metrics)
            )
            mean_mae_by_candidate[candidate_id] = float(
                sum(float(item["meanAbsoluteRGBCodeDifference"]) for item in metrics) / len(metrics)
            )
        aggregate_ranking = sorted(
            mean_ssim_by_candidate,
            key=lambda candidate_id: (
                -mean_ssim_by_candidate[candidate_id],
                mean_mae_by_candidate[candidate_id],
                candidate_id,
            ),
        )
        report = {
            "schemaVersion": 1,
            "evidenceVersion": "imagecraft-jpeg-chroma-natural-image-objective-v1",
            "status": "source-bound-natural-image-objective-observation",
            "formalSourceBoundExecution": True,
            "productionBackendQualified": False,
            "profile": {
                "profileID": profile["profileID"],
                "path": str(profile_path.relative_to(ROOT)),
                "sha256": sha256_file(profile_path),
            },
            "corpus": {
                "manifest": str(manifest_path.relative_to(ROOT)),
                "manifestSHA256": sha256_file(manifest_path),
            },
            "sourceIdentity": {
                "sourceIdentitySHA256": source_identity,
                "fileCount": before.get("fileCount"),
                "stableBeforeAfter": True,
            },
            "runtime": {
                "pythonVersion": platform.python_version(),
                "numpyVersion": np.__version__,
                "architecture": platform.machine(),
                "djpegVersion": djpeg_version,
                "djpegSHA256": sha256_file(djpeg),
                "rawProbeSHA256": sha256_file(raw_probe),
                "rawProbeSourceSHA256": sha256_file(RAW_PROBE_SOURCE),
            },
            "objective": objective,
            "claimBoundary": profile["claimBoundary"],
            "cases": case_results,
            "summary": {
                "caseCount": len(case_results),
                "candidateCount": len(profile["candidates"]),
                "winnerCounts": winner_counts,
                "meanBlockSSIMByCandidate": mean_ssim_by_candidate,
                "meanRGBMAEByCandidate": mean_mae_by_candidate,
                "aggregateRanking": aggregate_ranking,
                "aggregateWinner": aggregate_ranking[0],
                "allCaseWinnersSame": len({case["winner"] for case in case_results}) == 1,
                "allCenteredCandidatesExactFinalLibJPEG": all(
                    case["encodedVariant"]["centeredCandidateExactFinalLibJPEG"]
                    for case in case_results
                ),
                "allScanScriptsFinalPixelInvariant": all(
                    case["scanScriptFinalPixelInvariance"]["allRetainedScanScriptsExact"]
                    for case in case_results
                ),
            },
        }
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(
            "JPEG chroma natural-image objective captured: "
            f"cases={len(case_results)} winner={aggregate_ranking[0]} "
            f"source={source_identity} output={output_path}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
