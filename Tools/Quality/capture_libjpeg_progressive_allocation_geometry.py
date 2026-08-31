#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ctypes
import json
from pathlib import Path
import platform
import struct
import tempfile
from typing import Any

from capture_libjpeg_progressive_allocation_topology import (
    model_row_workspace,
    validate_allocation_trace,
)
from capture_libjpeg_progressive_suspension import (
    build_imagecraft_evidence,
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
    ROOT
    / "Evidence/Experiments/IndependentProgressiveJPEGAllocationGeometry/v1/profile.json"
)
DEFAULT_OUTPUT = (
    ROOT / ".artifacts/program/T101/libjpeg-progressive-allocation-geometry-v1.json"
)

# Pinned libjpeg-turbo 3.2.0 jmemmgr.c with WITH_SIMD uses ALIGN_SIZE=32.
# alloc_sarray rounds row width to 2*ALIGN_SIZE/sample_size.  The private
# large_pool_hdr is one pointer plus two size_t fields.
PINNED_ALIGNMENT_BYTES = 32
SAMPLE_SIZE_BYTES = 1
ROW_ALIGNMENT_SAMPLES = (2 * PINNED_ALIGNMENT_BYTES) // SAMPLE_SIZE_BYTES


def ceil_div(numerator: int, denominator: int) -> int:
    if numerator < 0 or denominator <= 0:
        raise CaptureError("invalid ceil-div operands")
    return (numerator + denominator - 1) // denominator


def round_up(value: int, factor: int) -> int:
    return ceil_div(value, factor) * factor


def write_synthetic_ppm(path: Path, width: int, height: int) -> str:
    if width <= 0 or height <= 0:
        raise CaptureError("synthetic PPM geometry must be positive")
    payload = bytearray(width * height * 3)
    offset = 0
    for y in range(height):
        for x in range(width):
            payload[offset] = (x * 17 + y * 13 + 19) & 0xFF
            payload[offset + 1] = (x * 7 + y * 29 + 73) & 0xFF
            payload[offset + 2] = (x * 3 + y * 5 + ((x ^ y) * 11) + 151) & 0xFF
            offset += 3
    data = f"P6\n{width} {height}\n255\n".encode("ascii") + bytes(payload)
    path.write_bytes(data)
    return sha256_bytes(data)


def modeled_large_pool_growth(
    model: dict[str, Any],
    *,
    max_alloc_chunk: int,
) -> dict[str, Any]:
    if max_alloc_chunk <= 0:
        raise CaptureError("libjpeg max_alloc_chunk must be positive")
    pointer_bytes = struct.calcsize("P")
    size_t_bytes = ctypes.sizeof(ctypes.c_size_t)
    pool_header_bytes = pointer_bytes + 2 * size_t_bytes
    large_allocation_overhead = (
        pool_header_bytes + PINNED_ALIGNMENT_BYTES - 1
    )
    arrays: list[dict[str, Any]] = []
    total_growth = 0
    total_aligned_payload = 0
    total_chunk_count = 0
    for array in model["arrays"]:
        samples_per_row = int(array["samplesPerRow"])
        rows = int(array["rows"])
        aligned_samples_per_row = round_up(samples_per_row, ROW_ALIGNMENT_SAMPLES)
        row_bytes = aligned_samples_per_row * SAMPLE_SIZE_BYTES
        rows_per_chunk = (max_alloc_chunk - pool_header_bytes) // row_bytes
        if rows_per_chunk <= 0:
            raise CaptureError("modeled alloc_sarray width exceeds max_alloc_chunk")
        remaining = rows
        chunk_payloads: list[int] = []
        while remaining > 0:
            chunk_rows = min(rows_per_chunk, remaining)
            payload_bytes = chunk_rows * row_bytes
            # row_bytes is 64-byte aligned, therefore alloc_large's 32-byte
            # size rounding does not change this payload in the qualified model.
            if payload_bytes % PINNED_ALIGNMENT_BYTES != 0:
                raise CaptureError("modeled large payload lost allocator alignment")
            chunk_payloads.append(payload_bytes)
            remaining -= chunk_rows
        aligned_payload = sum(chunk_payloads)
        growth = aligned_payload + len(chunk_payloads) * large_allocation_overhead
        total_aligned_payload += aligned_payload
        total_chunk_count += len(chunk_payloads)
        total_growth += growth
        arrays.append(
            {
                "controller": array["controller"],
                "componentIndex": array["componentIndex"],
                "requestedSamplesPerRow": samples_per_row,
                "rows": rows,
                "alignedSamplesPerRow": aligned_samples_per_row,
                "alignedPayloadBytes": aligned_payload,
                "largeAllocationChunkCount": len(chunk_payloads),
                "largeAllocationChunkPayloadBytes": chunk_payloads,
                "expectedPoolGrowthBytes": growth,
            }
        )
    return {
        "alignmentBytes": PINNED_ALIGNMENT_BYTES,
        "rowAlignmentSamples": ROW_ALIGNMENT_SAMPLES,
        "pointerBytes": pointer_bytes,
        "sizeTBytes": size_t_bytes,
        "poolHeaderBytes": pool_header_bytes,
        "largeAllocationOverheadBytes": large_allocation_overhead,
        "arrays": arrays,
        "alignedRowPayloadBytes": total_aligned_payload,
        "largeAllocationChunkCount": total_chunk_count,
        "expectedPoolGrowthBytes": total_growth,
    }


def modeled_coefficient_pool_growth(
    observation: dict[str, Any],
    *,
    max_alloc_chunk: int,
) -> dict[str, Any]:
    arrays = observation.get("virtualCoefficientArrays")
    block_bytes = observation.get("coefficientBlockByteCount")
    if (
        not isinstance(arrays, list)
        or not arrays
        or not isinstance(block_bytes, int)
        or block_bytes <= 0
    ):
        raise CaptureError("coefficient allocator model lacks virtual-array geometry")
    pointer_bytes = struct.calcsize("P")
    size_t_bytes = ctypes.sizeof(ctypes.c_size_t)
    pool_header_bytes = pointer_bytes + 2 * size_t_bytes
    large_allocation_overhead = pool_header_bytes + PINNED_ALIGNMENT_BYTES - 1
    modeled_arrays: list[dict[str, Any]] = []
    total_payload = 0
    total_growth = 0
    total_chunks = 0
    for array in arrays:
        if not isinstance(array, dict):
            raise CaptureError("coefficient allocator model found malformed array")
        rows = array.get("rowsInArray")
        blocks_per_row = array.get("blocksPerRow")
        if (
            not isinstance(rows, int)
            or rows <= 0
            or not isinstance(blocks_per_row, int)
            or blocks_per_row <= 0
        ):
            raise CaptureError("coefficient allocator model found invalid dimensions")
        row_bytes = blocks_per_row * block_bytes
        if row_bytes % PINNED_ALIGNMENT_BYTES != 0:
            raise CaptureError("coefficient block row lost allocator alignment")
        rows_per_chunk = (max_alloc_chunk - pool_header_bytes) // row_bytes
        if rows_per_chunk <= 0:
            raise CaptureError("coefficient row exceeds max_alloc_chunk")
        remaining = rows
        chunk_payloads: list[int] = []
        while remaining > 0:
            chunk_rows = min(rows_per_chunk, remaining)
            chunk_payloads.append(chunk_rows * row_bytes)
            remaining -= chunk_rows
        payload = sum(chunk_payloads)
        growth = payload + len(chunk_payloads) * large_allocation_overhead
        total_payload += payload
        total_growth += growth
        total_chunks += len(chunk_payloads)
        modeled_arrays.append(
            {
                "rows": rows,
                "blocksPerRow": blocks_per_row,
                "rowBytes": row_bytes,
                "largeAllocationChunkCount": len(chunk_payloads),
                "largeAllocationChunkPayloadBytes": chunk_payloads,
                "payloadBytes": payload,
                "expectedPoolGrowthBytes": growth,
            }
        )
    return {
        "arrays": modeled_arrays,
        "coefficientPayloadBytes": total_payload,
        "largeAllocationChunkCount": total_chunks,
        "expectedPoolGrowthBytes": total_growth,
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
        != "IMAGECRAFT-INDEPENDENT-PROGRESSIVE-JPEG-ALLOCATION-GEOMETRY-V1"
    ):
        raise CaptureError("unexpected progressive allocation geometry profile ID")
    if platform.machine() != "arm64":
        raise CaptureError(
            "allocation geometry v1 pins the current arm64 SIMD allocator layout"
        )

    geometry = profile["geometry"]
    height = int(geometry["height"])
    widths = [int(width) for width in geometry["widths"]]
    if height <= 0 or not widths or any(width <= 0 for width in widths):
        raise CaptureError("allocation geometry matrix is malformed")

    expected_sampling = {
        "gray": [(1, 1)],
        "444": [(1, 1), (1, 1), (1, 1)],
        "422": [(2, 1), (1, 1), (1, 1)],
        "420": [(2, 2), (1, 1), (1, 1)],
    }
    expected_imagecraft_sampling_mode = {
        "gray": "singleComponent",
        "444": "threeComponent444",
        "422": "threeComponent422",
        "420": "threeComponent420",
    }

    with tempfile.TemporaryDirectory(prefix="imagecraft-progressive-allocation-geometry-") as temp_raw:
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
            raise CaptureError("jpeg-turbo runtime is outside geometry qualification")
        probe = build_probe(temp, jpeg_prefix)
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

        encode = profile["encode"]
        base_cjpeg_args = ["-quality", str(int(encode["quality"]))]
        if encode.get("optimizeHuffman"):
            base_cjpeg_args.append("-optimize")
        if encode.get("progressive"):
            base_cjpeg_args.append("-progressive")

        cases: list[dict[str, Any]] = []
        for width in widths:
            source_ppm = temp / f"source-{width}x{height}.ppm"
            source_ppm_sha = write_synthetic_ppm(source_ppm, width, height)
            for variant in profile["variants"]:
                variant_id = str(variant["id"])
                generated = temp / f"{width}x{height}-{variant_id}.jpg"
                cjpeg_args = list(base_cjpeg_args)
                if variant["mode"] == "grayscale":
                    cjpeg_args.append("-grayscale")
                elif variant["mode"] == "sampling":
                    cjpeg_args.extend(["-sample", str(variant["sampling"])])
                else:
                    raise CaptureError(
                        f"unsupported geometry variant mode: {variant_id}"
                    )
                cjpeg_args.append(str(source_ppm))
                encode_jpeg(cjpeg, cjpeg_args, generated)

                encoded = generated.read_bytes()
                sampling = jpeg_sampling_factors(encoded)
                actual_sampling = [
                    (item["horizontal"], item["vertical"]) for item in sampling
                ]
                if actual_sampling != expected_sampling[variant_id]:
                    raise CaptureError(
                        f"geometry sampling drifted: width={width} variant={variant_id}"
                    )
                scan_count = len(structural_scans(encoded))
                if scan_count <= 1 or scan_count > int(profile["maximumScanCount"]):
                    raise CaptureError(
                        f"geometry progressive scan count drifted: width={width} variant={variant_id}"
                    )

                reference_ppm = temp / f"reference-{width}-{variant_id}.ppm"
                reference_decode = run(
                    [
                        str(djpeg),
                        "-rgb",
                        "-pnm",
                        "-outfile",
                        str(reference_ppm),
                        str(generated),
                    ]
                )
                if reference_decode.stderr.strip():
                    raise CaptureError(
                        f"geometry djpeg warned: width={width} variant={variant_id}"
                    )
                decoded_width, decoded_height, reference_rgb = parse_ppm_rgb(reference_ppm)
                if (decoded_width, decoded_height) != (width, height):
                    raise CaptureError(
                        f"geometry decode dimensions drifted: width={width} variant={variant_id}"
                    )

                probe_prefix = temp / f"probe-{width}-{variant_id}"
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
                        f"geometry probe warned: width={width} variant={variant_id}: "
                        f"{probe_completed.stderr.strip()}"
                    )
                observation = parse_json_stdout(
                    probe_completed, f"geometry probe {width}/{variant_id}"
                )
                probe_rgb = Path(f"{probe_prefix}-final.rgb").read_bytes()
                if probe_rgb != reference_rgb:
                    raise CaptureError(
                        f"geometry probe RGB differs from djpeg: width={width} variant={variant_id}"
                    )
                if observation.get("warningCount") != 0:
                    raise CaptureError(
                        f"geometry probe warning count drifted: width={width} variant={variant_id}"
                    )

                allocation_events, pool_growth = validate_allocation_trace(
                    observation, variant_id=f"{width}/{variant_id}"
                )
                row_model = model_row_workspace(width, sampling)
                observed_sarrays = [
                    event
                    for event in allocation_events
                    if event.get("kind") == "allocSArray"
                ]
                observed_shapes = [
                    (
                        int(event["firstDimension"]),
                        int(event["secondDimension"]),
                        int(event["logicalPayloadBytes"]),
                    )
                    for event in observed_sarrays
                ]
                modeled_shapes = [
                    (
                        int(array["samplesPerRow"]),
                        int(array["rows"]),
                        int(array["logicalPayloadBytes"]),
                    )
                    for array in row_model["arrays"]
                ]
                if observed_shapes != modeled_shapes:
                    raise CaptureError(
                        f"geometry row model drifted: width={width} variant={variant_id}; "
                        f"modeled={modeled_shapes} observed={observed_shapes}"
                    )

                imagecraft_completed = run(
                    [
                        str(imagecraft_evidence),
                        "--progressive-jpeg-resource-geometry",
                        str(generated),
                    ]
                )
                if imagecraft_completed.stderr.strip():
                    raise CaptureError(
                        f"ImageCraft resource geometry emitted diagnostics: "
                        f"width={width} variant={variant_id}: "
                        f"{imagecraft_completed.stderr.strip()}"
                    )
                imagecraft_report = parse_json_stdout(
                    imagecraft_completed,
                    f"ImageCraft resource geometry {width}/{variant_id}",
                )
                imagecraft_geometry = imagecraft_report.get("geometry")
                if not isinstance(imagecraft_geometry, dict):
                    raise CaptureError(
                        f"ImageCraft resource geometry is malformed: width={width} "
                        f"variant={variant_id}"
                    )
                imagecraft_input = imagecraft_report.get("input")
                if (
                    imagecraft_report.get("evidenceVersion")
                    != "imagecraft-progressive-jpeg-resource-geometry-v1"
                    or not isinstance(imagecraft_input, dict)
                    or imagecraft_input.get("byteCount") != len(encoded)
                    or imagecraft_input.get("sha256") != sha256_bytes(encoded)
                    or imagecraft_geometry.get("width") != width
                    or imagecraft_geometry.get("height") != height
                    or imagecraft_geometry.get("precision") != 8
                    or imagecraft_geometry.get("samplingMode")
                    != expected_imagecraft_sampling_mode[variant_id]
                    or imagecraft_geometry.get("fullScaleFancyRowWorkspaceBytes")
                    != row_model["logicalRowWorkspaceBytes"]
                    or imagecraft_geometry.get("fancyVerticalContextRowsRequired")
                    is not row_model["needsContextRows"]
                ):
                    raise CaptureError(
                        f"ImageCraft resource geometry disagrees with source model: "
                        f"width={width} variant={variant_id}"
                    )

                max_alloc_chunk = observation.get("libjpegMaxAllocChunkBytes")
                if not isinstance(max_alloc_chunk, int) or max_alloc_chunk <= 0:
                    raise CaptureError("probe did not report max_alloc_chunk")
                allocator_model = modeled_large_pool_growth(
                    row_model, max_alloc_chunk=max_alloc_chunk
                )
                expected_growth = int(allocator_model["expectedPoolGrowthBytes"])
                non_sarray_growth = pool_growth - sum(
                    int(event["poolGrowthBytes"]) for event in observed_sarrays
                )
                if non_sarray_growth != 0:
                    raise CaptureError(
                        f"small/control pool unexpectedly grew: width={width} "
                        f"variant={variant_id} growth={non_sarray_growth}"
                    )
                if pool_growth != expected_growth:
                    raise CaptureError(
                        f"allocator source model drifted: width={width} variant={variant_id} "
                        f"expected={expected_growth} observed={pool_growth}"
                    )

                coefficient_allocator_model = modeled_coefficient_pool_growth(
                    observation, max_alloc_chunk=max_alloc_chunk
                )
                coefficient_payload = observation.get(
                    "minimumCoefficientArrayPayloadBytes"
                )
                if (
                    not isinstance(coefficient_payload, int)
                    or coefficient_payload
                    != coefficient_allocator_model["coefficientPayloadBytes"]
                ):
                    raise CaptureError(
                        f"coefficient allocator payload drifted: width={width} "
                        f"variant={variant_id}"
                    )
                if imagecraft_geometry.get("coefficientArrayPayloadBytes") != coefficient_payload:
                    raise CaptureError(
                        f"ImageCraft coefficient payload disagrees with libjpeg geometry: "
                        f"width={width} variant={variant_id}"
                    )

                owned_completed = run(
                    [
                        str(imagecraft_evidence),
                        "--progressive-jpeg-owned-variable-state",
                        str(generated),
                    ]
                )
                if owned_completed.stderr.strip():
                    raise CaptureError(
                        f"ImageCraft owned variable state emitted diagnostics: "
                        f"width={width} variant={variant_id}: "
                        f"{owned_completed.stderr.strip()}"
                    )
                owned_report = parse_json_stdout(
                    owned_completed,
                    f"ImageCraft owned variable state {width}/{variant_id}",
                )
                owned_plan = owned_report.get("plan")
                expected_owned_variable_bytes = (
                    int(allocator_model["alignedRowPayloadBytes"])
                    + int(coefficient_allocator_model["coefficientPayloadBytes"])
                )
                if (
                    owned_report.get("evidenceVersion")
                    != "imagecraft-progressive-jpeg-owned-variable-state-v1"
                    or owned_report.get("exactBudgetAccepted") is not True
                    or owned_report.get("thresholdMinusOneRejectedBeforeAllocation") is not True
                    or owned_report.get("allBuffersAligned") is not True
                    or owned_report.get("allBuffersInitiallyZero") is not True
                    or not isinstance(owned_plan, dict)
                    or owned_plan.get("coefficientStorageBytes") != coefficient_payload
                    or owned_plan.get("logicalRowWorkspaceBytes")
                    != row_model["logicalRowWorkspaceBytes"]
                    or owned_plan.get("rowWorkspaceStorageBytes")
                    != allocator_model["alignedRowPayloadBytes"]
                    or owned_plan.get("totalVariableStateBytes")
                    != expected_owned_variable_bytes
                ):
                    raise CaptureError(
                        f"ImageCraft owned variable state disagrees with source model: "
                        f"width={width} variant={variant_id}"
                    )
                imagecraft_components = imagecraft_geometry.get("components")
                observed_components = observation.get("coefficientComponents")
                if (
                    not isinstance(imagecraft_components, list)
                    or not isinstance(observed_components, list)
                    or len(imagecraft_components) != len(observed_components)
                ):
                    raise CaptureError(
                        f"ImageCraft component geometry is malformed: width={width} "
                        f"variant={variant_id}"
                    )
                for component_index, (imagecraft_component, observed_component) in enumerate(
                    zip(imagecraft_components, observed_components)
                ):
                    if not isinstance(imagecraft_component, dict) or not isinstance(
                        observed_component, dict
                    ):
                        raise CaptureError(
                            f"component geometry is malformed: width={width} "
                            f"variant={variant_id} component={component_index}"
                        )
                    expected_component = {
                        "componentID": observed_component.get("componentID"),
                        "horizontalSamplingFactor": observed_component.get(
                            "horizontalSamplingFactor"
                        ),
                        "verticalSamplingFactor": observed_component.get(
                            "verticalSamplingFactor"
                        ),
                        "widthInBlocks": observed_component.get("widthInBlocks"),
                        "heightInBlocks": observed_component.get("heightInBlocks"),
                        "paddedWidthInBlocks": observed_component.get(
                            "paddedWidthInBlocks"
                        ),
                        "paddedHeightInBlocks": observed_component.get(
                            "paddedHeightInBlocks"
                        ),
                        "coefficientPayloadBytes": observed_component.get(
                            "coefficientPayloadBytes"
                        ),
                    }
                    if imagecraft_component != expected_component:
                        raise CaptureError(
                            f"ImageCraft/libjpeg component geometry disagrees: width={width} "
                            f"variant={variant_id} component={component_index}; "
                            f"imagecraft={imagecraft_component} observed={expected_component}"
                        )
                pool_after_header = int(observation["libjpegPoolBytesAfterHeader"])
                expected_pool_after_start = (
                    pool_after_header
                    + expected_growth
                    + int(coefficient_allocator_model["expectedPoolGrowthBytes"])
                )
                observed_pool_after_start = observation.get(
                    "libjpegPoolBytesAfterStartDecompress"
                )
                if (
                    not isinstance(observed_pool_after_start, int)
                    or observed_pool_after_start != expected_pool_after_start
                ):
                    raise CaptureError(
                        f"post-start allocator model drifted: width={width} "
                        f"variant={variant_id} expected={expected_pool_after_start} "
                        f"observed={observed_pool_after_start}"
                    )

                cases.append(
                    {
                        "id": f"w{width}-{variant_id}",
                        "width": width,
                        "height": height,
                        "variant": variant_id,
                        "sourcePPMSHA256": source_ppm_sha,
                        "generatedJPEGByteCount": len(encoded),
                        "generatedJPEGSHA256": sha256_bytes(encoded),
                        "scanCount": scan_count,
                        "samplingFactors": sampling,
                        "rowWorkspaceModel": row_model,
                        "allocatorModel": allocator_model,
                        "coefficientAllocatorModel": coefficient_allocator_model,
                        "imageCraftResourceGeometry": imagecraft_report,
                        "imageCraftOwnedVariableState": owned_report,
                        "expectedOwnedVariableStateBytes": expected_owned_variable_bytes,
                        "exactImageCraftOwnedVariableStateModel": True,
                        "observed": {
                            "poolBytesAfterHeader": observation[
                                "libjpegPoolBytesAfterHeader"
                            ],
                            "poolBytesBeforeVirtualArrayRealization": observation[
                                "libjpegPoolBytesBeforeVirtualArrayRealization"
                            ],
                            "preRealizePoolGrowthBytes": pool_growth,
                            "poolBytesAfterStartDecompress": observed_pool_after_start,
                            "modeledPoolBytesAfterStartDecompress": expected_pool_after_start,
                            "maximumCoefficientArrayPayloadBytes": observation[
                                "libjpegVirtualArrayMaximumSpaceBytes"
                            ],
                            "maximumRequiredMinheights": observation[
                                "libjpegVirtualArrayMaximumRequiredMinheights"
                            ],
                            "sharpNoBackingStoreThresholdApplicable": observation[
                                "libjpegSharpNoBackingStoreThresholdApplicable"
                            ],
                            "allocSArrayEvents": observed_sarrays,
                            "nonSArrayPoolGrowthBytes": non_sarray_growth,
                        },
                        "finalRGBSHA256": sha256_bytes(probe_rgb),
                        "exactOneShotLibJPEGRGB": True,
                    }
                )

        after = capture_source_identity(temp / "source-after.json")
        before_hash = before.get("sourceIdentitySHA256")
        if not before_hash or before_hash != after.get("sourceIdentitySHA256"):
            raise CaptureError(
                "ImageCraft source identity changed during allocation geometry capture"
            )

        by_key = {(case["width"], case["variant"]): case for case in cases}
        width4_420 = by_key[(4, "420")]
        width5_420 = by_key[(5, "420")]
        if (
            width4_420["rowWorkspaceModel"]["needsContextRows"] is not False
            or width5_420["rowWorkspaceModel"]["needsContextRows"] is not True
        ):
            raise CaptureError("h2v2 fancy context boundary did not occur at width 5")

        report = {
            "schemaVersion": 1,
            "evidenceVersion": "imagecraft-independent-progressive-jpeg-allocation-geometry-v1",
            "status": "source-bound-mechanism-conformance",
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
                "cjpegVersion": cjpeg_version,
                "djpegVersion": djpeg_version,
                "cjpegSHA256": sha256_file(cjpeg),
                "djpegSHA256": sha256_file(djpeg),
                "probeSHA256": sha256_file(probe),
                "imageCraftEvidenceSHA256": sha256_file(imagecraft_evidence),
            },
            "claimBoundary": profile["claimBoundary"],
            "cases": cases,
            "summary": {
                "caseCount": len(cases),
                "widthCount": len(widths),
                "variantCountPerWidth": len(profile["variants"]),
                "allExactOneShotLibJPEGRGB": all(
                    bool(case["exactOneShotLibJPEGRGB"]) for case in cases
                ),
                "allRowWorkspaceModelsExact": True,
                "allAllocatorModelsExact": True,
                "allPostStartPoolModelsExact": True,
                "allImageCraftResourceGeometryModelsExact": True,
                "allImageCraftOwnedVariableStateModelsExact": all(
                    bool(case["exactImageCraftOwnedVariableStateModel"])
                    for case in cases
                ),
                "allNonSArrayPoolGrowthZero": all(
                    case["observed"]["nonSArrayPoolGrowthBytes"] == 0
                    for case in cases
                ),
                "h2v2FancyContextBoundary": {
                    "width4NeedsContextRows": width4_420["rowWorkspaceModel"][
                        "needsContextRows"
                    ],
                    "width5NeedsContextRows": width5_420["rowWorkspaceModel"][
                        "needsContextRows"
                    ],
                    "width4LogicalRowWorkspaceBytes": width4_420[
                        "rowWorkspaceModel"
                    ]["logicalRowWorkspaceBytes"],
                    "width5LogicalRowWorkspaceBytes": width5_420[
                        "rowWorkspaceModel"
                    ]["logicalRowWorkspaceBytes"],
                    "width4PreRealizePoolGrowthBytes": width4_420["observed"][
                        "preRealizePoolGrowthBytes"
                    ],
                    "width5PreRealizePoolGrowthBytes": width5_420["observed"][
                        "preRealizePoolGrowthBytes"
                    ],
                },
                "maximumPreRealizePoolGrowthBytes": max(
                    int(case["observed"]["preRealizePoolGrowthBytes"])
                    for case in cases
                ),
                "maximumAlignedRowPayloadBytes": max(
                    int(case["allocatorModel"]["alignedRowPayloadBytes"])
                    for case in cases
                ),
                "maximumOwnedVariableStateBytes": max(
                    int(case["expectedOwnedVariableStateBytes"]) for case in cases
                ),
                "maximumModeledPoolBytesAfterStartDecompress": max(
                    int(case["observed"]["modeledPoolBytesAfterStartDecompress"])
                    for case in cases
                ),
            },
        }
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(
            "libjpeg progressive allocation geometry captured: "
            f"cases={len(cases)} source={before_hash} output={output_path}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
