#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
import platform
import tempfile
from typing import Any

from capture_libjpeg_progressive_suspension import (
    CaptureError,
    ROOT,
    build_probe,
    capture_source_identity,
    parse_json_stdout,
    parse_ppm_rgb,
    run,
    sha256_bytes,
    sha256_file,
    structural_scans,
)
from capture_progressive_jpeg_cross_backend_sampling import (
    encode_jpeg,
    jpeg_sampling_factors,
)


DEFAULT_PROFILE = (
    ROOT / "Evidence/Experiments/IndependentProgressiveJPEGAllocation/v1/profile.json"
)
DEFAULT_OUTPUT = (
    ROOT / ".artifacts/program/T101/libjpeg-progressive-allocation-topology-v1.json"
)


def ceil_div(numerator: int, denominator: int) -> int:
    if numerator < 0 or denominator <= 0:
        raise CaptureError("invalid ceil-div operands")
    return (numerator + denominator - 1) // denominator


def round_up(value: int, factor: int) -> int:
    return ceil_div(value, factor) * factor


def model_row_workspace(
    width: int,
    sampling: list[dict[str, int]],
) -> dict[str, Any]:
    if width <= 0 or not sampling:
        raise CaptureError("allocation model requires positive width and sampling")
    factors: list[tuple[int, int]] = []
    for component in sampling:
        horizontal = component.get("horizontal")
        vertical = component.get("vertical")
        if (
            not isinstance(horizontal, int)
            or horizontal <= 0
            or not isinstance(vertical, int)
            or vertical <= 0
        ):
            raise CaptureError("allocation model found invalid sampling factors")
        factors.append((horizontal, vertical))
    max_h = max(horizontal for horizontal, _ in factors)
    max_v = max(vertical for _, vertical in factors)

    upsampler_arrays: list[dict[str, int | str]] = []
    needs_context_rows = False
    rounded_output_width = round_up(width, max_h)
    for index, (horizontal, vertical) in enumerate(factors):
        need_buffer = True
        method: str
        if horizontal == max_h and vertical == max_v:
            method = "fullsize"
            need_buffer = False
        elif horizontal * 2 == max_h and vertical == max_v:
            method = "h2v1-fancy"
        elif horizontal == max_h and vertical * 2 == max_v:
            method = "h1v2-fancy"
            needs_context_rows = True
        elif horizontal * 2 == max_h and vertical * 2 == max_v:
            downsampled_width = ceil_div(width * horizontal, max_h)
            if downsampled_width > 2:
                method = "h2v2-fancy"
                needs_context_rows = True
            else:
                method = "h2v2-nearest-small-width"
        elif max_h % horizontal == 0 and max_v % vertical == 0:
            method = "integral"
        else:
            raise CaptureError(
                "allocation model encountered sampling outside the qualified integral domain"
            )
        if need_buffer:
            samples_per_row = rounded_output_width
            rows = max_v
            upsampler_arrays.append(
                {
                    "controller": "upsampler",
                    "componentIndex": index,
                    "method": method,
                    "samplesPerRow": samples_per_row,
                    "rows": rows,
                    "logicalPayloadBytes": samples_per_row * rows,
                }
            )

    # This experiment fixes full-resolution 8-bit IDCT output.  libjpeg-turbo
    # therefore has _DCT_scaled_size == _min_DCT_scaled_size == DCTSIZE == 8.
    dct_size = 8
    minimum_dct_scaled_size = 8
    ngroups = minimum_dct_scaled_size + 2 if needs_context_rows else minimum_dct_scaled_size
    main_arrays: list[dict[str, int | str]] = []
    for index, (horizontal, vertical) in enumerate(factors):
        width_in_blocks = ceil_div(width * horizontal, max_h * dct_size)
        samples_per_row = width_in_blocks * dct_size
        row_group_height = vertical
        rows = row_group_height * ngroups
        main_arrays.append(
            {
                "controller": "main",
                "componentIndex": index,
                "samplesPerRow": samples_per_row,
                "rows": rows,
                "logicalPayloadBytes": samples_per_row * rows,
            }
        )

    arrays = [*upsampler_arrays, *main_arrays]
    return {
        "maxHorizontalSamplingFactor": max_h,
        "maxVerticalSamplingFactor": max_v,
        "needsContextRows": needs_context_rows,
        "mainControllerRowGroups": ngroups,
        "arrays": arrays,
        "logicalRowWorkspaceBytes": sum(
            int(array["logicalPayloadBytes"]) for array in arrays
        ),
    }


def validate_allocation_trace(
    observation: dict[str, Any],
    *,
    variant_id: str,
) -> tuple[list[dict[str, Any]], int]:
    events = observation.get("preRealizeAllocationEvents")
    count = observation.get("preRealizeAllocationEventCount")
    overflow = observation.get("preRealizeAllocationEventOverflow")
    pool_growth = observation.get("preRealizeAllocationPoolGrowthBytes")
    header_pool = observation.get("libjpegPoolBytesAfterHeader")
    pre_realize_pool = observation.get("libjpegPoolBytesBeforeVirtualArrayRealization")
    if (
        not isinstance(events, list)
        or not isinstance(count, int)
        or count != len(events)
        or count <= 0
        or overflow is not False
        or not isinstance(pool_growth, int)
        or pool_growth < 0
        or not isinstance(header_pool, int)
        or not isinstance(pre_realize_pool, int)
        or pre_realize_pool < header_pool
    ):
        raise CaptureError(f"allocation trace envelope is malformed: {variant_id}")

    previous_pool = header_pool
    growth_sum = 0
    for event in events:
        if not isinstance(event, dict):
            raise CaptureError(f"allocation trace event is malformed: {variant_id}")
        before = event.get("poolBytesBefore")
        after = event.get("poolBytesAfter")
        growth = event.get("poolGrowthBytes")
        if (
            not isinstance(before, int)
            or not isinstance(after, int)
            or not isinstance(growth, int)
            or before != previous_pool
            or after < before
            or growth != after - before
        ):
            raise CaptureError(f"allocation trace chain drifted: {variant_id}")
        growth_sum += growth
        previous_pool = after
    if (
        previous_pool != pre_realize_pool
        or growth_sum != pool_growth
        or pool_growth != pre_realize_pool - header_pool
    ):
        raise CaptureError(f"allocation trace does not close pool ledger: {variant_id}")
    return events, pool_growth


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
        != "IMAGECRAFT-INDEPENDENT-PROGRESSIVE-JPEG-ALLOCATION-TOPOLOGY-V1"
    ):
        raise CaptureError("unexpected progressive allocation topology profile ID")

    source_spec = profile["source"]
    source_path = ROOT / str(source_spec["file"])
    source_bytes = source_path.read_bytes()
    if sha256_bytes(source_bytes) != source_spec["sha256"]:
        raise CaptureError("progressive allocation source identity drifted")

    with tempfile.TemporaryDirectory(prefix="imagecraft-progressive-allocation-") as temp_raw:
        temp = Path(temp_raw)
        before = capture_source_identity(temp / "source-before.json")
        jpeg_prefix = Path(run(["brew", "--prefix", "jpeg-turbo"]).stdout.strip())
        cjpeg = jpeg_prefix / "bin/cjpeg"
        djpeg = jpeg_prefix / "bin/djpeg"
        if not cjpeg.is_file() or not djpeg.is_file():
            raise CaptureError("pinned jpeg-turbo tools are unavailable")
        cjpeg_version = run([str(cjpeg), "-version"]).stderr.strip()
        djpeg_version = run([str(djpeg), "-version"]).stderr.strip()
        required_version = profile.get("requiredLibJPEGTurboVersionPrefix")
        if (
            not isinstance(required_version, str)
            or not cjpeg_version.startswith(required_version)
            or not djpeg_version.startswith(required_version)
        ):
            raise CaptureError(
                "jpeg-turbo runtime is outside the allocation-topology qualification"
            )
        probe = build_probe(temp, jpeg_prefix)

        source_ppm = temp / "source.ppm"
        source_decode = run(
            [str(djpeg), "-rgb", "-pnm", "-outfile", str(source_ppm), str(source_path)]
        )
        if source_decode.stderr.strip():
            raise CaptureError(
                f"allocation source djpeg emitted diagnostics: {source_decode.stderr.strip()}"
            )
        source_width, source_height, source_rgb = parse_ppm_rgb(source_ppm)

        encode = profile["encode"]
        base_cjpeg_args = ["-quality", str(int(encode["quality"]))]
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
                raise CaptureError(f"unsupported allocation variant mode: {variant_id}")
            cjpeg_args.append(str(source_ppm))
            encode_jpeg(cjpeg, cjpeg_args, generated)

            encoded = generated.read_bytes()
            sampling = jpeg_sampling_factors(encoded)
            actual_sampling = [
                (item["horizontal"], item["vertical"]) for item in sampling
            ]
            if actual_sampling != expected_sampling[variant_id]:
                raise CaptureError(
                    f"allocation variant sampling drifted for {variant_id}: {actual_sampling}"
                )
            scan_count = len(structural_scans(encoded))
            if scan_count <= 1 or scan_count > int(profile["maximumScanCount"]):
                raise CaptureError(f"allocation variant scan count is invalid: {variant_id}")

            reference_ppm = temp / f"{variant_id}.reference.ppm"
            reference_decode = run(
                [str(djpeg), "-rgb", "-pnm", "-outfile", str(reference_ppm), str(generated)]
            )
            if reference_decode.stderr.strip():
                raise CaptureError(f"allocation variant djpeg warned: {variant_id}")
            width, height, reference_rgb = parse_ppm_rgb(reference_ppm)
            if (width, height) != (source_width, source_height):
                raise CaptureError(f"allocation variant geometry drifted: {variant_id}")

            probe_prefix = temp / f"{variant_id}.probe"
            probe_completed = run(
                [
                    str(probe),
                    str(generated),
                    str(len(encoded)),
                    str(probe_prefix),
                    str(int(profile["maximumScanCount"])),
                ]
            )
            if probe_completed.stderr.strip():
                raise CaptureError(
                    f"allocation probe emitted diagnostics for {variant_id}: "
                    f"{probe_completed.stderr.strip()}"
                )
            observation = parse_json_stdout(
                probe_completed, f"allocation probe {variant_id}"
            )
            probe_rgb = Path(f"{probe_prefix}-final.rgb").read_bytes()
            if probe_rgb != reference_rgb:
                raise CaptureError(
                    f"allocation probe final RGB differs from djpeg: {variant_id}"
                )
            if observation.get("warningCount") != 0:
                raise CaptureError(f"allocation probe warned: {variant_id}")
            if observation.get("libjpegObservedVirtualSampleArrayPresent") is not False:
                raise CaptureError(
                    f"allocation probe unexpectedly used virtual sample arrays: {variant_id}"
                )

            allocation_events, pool_growth = validate_allocation_trace(
                observation, variant_id=variant_id
            )
            model = model_row_workspace(width, sampling)
            observed_sarrays = [
                event for event in allocation_events if event.get("kind") == "allocSArray"
            ]
            observed_shapes = [
                (
                    event.get("firstDimension"),
                    event.get("secondDimension"),
                    event.get("logicalPayloadBytes"),
                )
                for event in observed_sarrays
            ]
            modeled_shapes = [
                (
                    int(array["samplesPerRow"]),
                    int(array["rows"]),
                    int(array["logicalPayloadBytes"]),
                )
                for array in model["arrays"]
            ]
            if observed_shapes != modeled_shapes:
                raise CaptureError(
                    f"geometry-derived row workspace differs from allocator calls: {variant_id}; "
                    f"modeled={modeled_shapes} observed={observed_shapes}"
                )

            sarray_pool_growth = sum(
                int(event["poolGrowthBytes"]) for event in observed_sarrays
            )
            other_pool_growth = pool_growth - sarray_pool_growth
            if other_pool_growth != 0:
                raise CaptureError(
                    f"non-row allocation expanded the pre-realize pool: {variant_id} "
                    f"growth={other_pool_growth}"
                )
            logical_row_bytes = int(model["logicalRowWorkspaceBytes"])
            if sum(int(event["logicalPayloadBytes"]) for event in observed_sarrays) != logical_row_bytes:
                raise CaptureError(f"row workspace payload sum drifted: {variant_id}")

            results.append(
                {
                    "id": variant_id,
                    "generatedJPEGByteCount": len(encoded),
                    "generatedJPEGSHA256": sha256_bytes(encoded),
                    "scanCount": scan_count,
                    "samplingFactors": sampling,
                    "geometryModel": model,
                    "allocation": {
                        "poolBytesAfterHeader": observation[
                            "libjpegPoolBytesAfterHeader"
                        ],
                        "poolBytesBeforeVirtualArrayRealization": observation[
                            "libjpegPoolBytesBeforeVirtualArrayRealization"
                        ],
                        "preRealizePoolGrowthBytes": pool_growth,
                        "logicalRowWorkspaceBytes": logical_row_bytes,
                        "allocatorGrowthBeyondLogicalRowsBytes": pool_growth
                        - logical_row_bytes,
                        "allocSArrayEventCount": len(observed_sarrays),
                        "allocSArrayPoolGrowthBytes": sarray_pool_growth,
                        "nonSArrayPoolGrowthBytes": other_pool_growth,
                        "events": allocation_events,
                    },
                    "coefficientPayloadBytes": observation[
                        "minimumCoefficientArrayPayloadBytes"
                    ],
                    "fullVirtualArrayAvailabilityThresholdBytes": observation[
                        "libjpegFullVirtualArrayAvailabilityThresholdBytes"
                    ],
                    "finalRGBSHA256": sha256_bytes(probe_rgb),
                    "exactOneShotLibJPEGRGB": True,
                }
            )

        by_id = {result["id"]: result for result in results}
        required_ids = {"gray", "444", "422", "420"}
        if set(by_id) != required_ids:
            raise CaptureError("allocation topology variants are incomplete")

        def allocation_value(variant_id: str, key: str) -> int:
            return int(by_id[variant_id]["allocation"][key])

        contrasts = [
            ("gray-to-444", "gray", "444"),
            ("444-to-422", "444", "422"),
            ("422-to-420", "422", "420"),
        ]
        causal_contrasts = []
        for contrast_id, left, right in contrasts:
            causal_contrasts.append(
                {
                    "id": contrast_id,
                    "from": left,
                    "to": right,
                    "logicalRowWorkspaceDeltaBytes": allocation_value(
                        right, "logicalRowWorkspaceBytes"
                    )
                    - allocation_value(left, "logicalRowWorkspaceBytes"),
                    "preRealizePoolGrowthDeltaBytes": allocation_value(
                        right, "preRealizePoolGrowthBytes"
                    )
                    - allocation_value(left, "preRealizePoolGrowthBytes"),
                    "allocSArrayEventCountDelta": allocation_value(
                        right, "allocSArrayEventCount"
                    )
                    - allocation_value(left, "allocSArrayEventCount"),
                }
            )

        after = capture_source_identity(temp / "source-after.json")
        before_hash = before.get("sourceIdentitySHA256")
        if not before_hash or before_hash != after.get("sourceIdentitySHA256"):
            raise CaptureError(
                "ImageCraft source identity changed during allocation topology capture"
            )

        report = {
            "schemaVersion": 1,
            "evidenceVersion": "imagecraft-independent-progressive-jpeg-allocation-topology-v1",
            "status": "source-bound-mechanism-observation",
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
                "probeSHA256": sha256_file(probe),
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
            "causalContrasts": causal_contrasts,
            "summary": {
                "variantCount": len(results),
                "allExactOneShotLibJPEGRGB": all(
                    bool(result["exactOneShotLibJPEGRGB"]) for result in results
                ),
                "allGeometryModelsExact": True,
                "allPreRealizePoolGrowthAttributedToRowArrays": all(
                    result["allocation"]["nonSArrayPoolGrowthBytes"] == 0
                    for result in results
                ),
                "logicalRowWorkspaceBytesByVariant": {
                    result["id"]: result["allocation"]["logicalRowWorkspaceBytes"]
                    for result in results
                },
                "preRealizePoolGrowthBytesByVariant": {
                    result["id"]: result["allocation"]["preRealizePoolGrowthBytes"]
                    for result in results
                },
                "allocatorGrowthBeyondLogicalRowsBytesByVariant": {
                    result["id"]: result["allocation"][
                        "allocatorGrowthBeyondLogicalRowsBytes"
                    ]
                    for result in results
                },
            },
        }
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(
            "libjpeg progressive allocation topology captured: "
            f"variants={len(results)} source={before_hash} output={output_path}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
