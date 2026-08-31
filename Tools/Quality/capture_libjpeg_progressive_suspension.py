#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_PROFILE = ROOT / "Evidence/Experiments/IndependentProgressiveJPEG/v1/profile.json"
DEFAULT_OUTPUT = ROOT / ".artifacts/program/T101/libjpeg-progressive-suspension-v1.json"
PROBE_SOURCE = ROOT / "Tools/Quality/LibJPEGTurboSuspendingProgressiveProbe/main.c"


class CaptureError(RuntimeError):
    pass


def run(argv: list[str], *, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        argv,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        raise CaptureError(
            f"command failed ({completed.returncode}): {' '.join(argv)}\n"
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )
    return completed


def build_imagecraft_evidence() -> Path:
    """Build and resolve the current ImageCraftEvidence executable through SwiftPM.

    Newer SwiftPM hosts may place products in a per-agent cache returned by
    `swift build --show-bin-path` while a repository-local `.build/release` symlink still points at
    an older product directory.  Source-bound evidence must therefore never guess the executable
    from `.build/release` after a successful build.
    """
    run(
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
    bin_path = run(
        ["swift", "build", "-c", "release", "--show-bin-path"],
        cwd=ROOT,
    ).stdout.strip()
    if not bin_path:
        raise CaptureError("SwiftPM did not report a release bin path")
    executable = Path(bin_path) / "ImageCraftEvidence"
    if not executable.is_file():
        raise CaptureError(
            f"ImageCraftEvidence is unavailable under SwiftPM release bin path: {executable}"
        )
    return executable


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def capture_source_identity(path: Path) -> dict[str, Any]:
    run(
        [
            sys.executable,
            str(ROOT / "Tools/Identity/capture_source_identity.py"),
            "--output",
            str(path),
        ]
    )
    return json.loads(path.read_text())


def parse_json_stdout(completed: subprocess.CompletedProcess[str], label: str) -> dict[str, Any]:
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise CaptureError(f"invalid JSON from {label}: {completed.stdout!r}") from error


def structural_scans(data: bytes) -> list[dict[str, int]]:
    if not data.startswith(b"\xff\xd8"):
        raise CaptureError("JPEG is missing SOI")
    offset = 2
    scans: list[dict[str, int]] = []
    while offset < len(data):
        if data[offset] != 0xFF:
            raise CaptureError(f"JPEG marker does not start with 0xFF at {offset}")
        marker_start = offset
        while offset < len(data) and data[offset] == 0xFF:
            offset += 1
        if offset >= len(data):
            raise CaptureError("truncated JPEG marker")
        marker = data[offset]
        offset += 1
        if marker == 0xD9:
            if offset != len(data):
                raise CaptureError("JPEG has trailing bytes after EOI")
            return scans
        if marker == 0xD8 or 0xD0 <= marker <= 0xD7:
            raise CaptureError("unexpected standalone marker outside entropy stream")
        if marker == 0x01:
            continue
        if offset + 2 > len(data):
            raise CaptureError("truncated JPEG segment length")
        segment_length = int.from_bytes(data[offset : offset + 2], "big")
        if segment_length < 2 or offset + segment_length > len(data):
            raise CaptureError("JPEG segment exceeds input")
        segment_end = offset + segment_length
        if marker != 0xDA:
            offset = segment_end
            continue

        entropy_start = segment_end
        search = entropy_start
        while True:
            next_ff = data.find(b"\xff", search)
            if next_ff < 0:
                raise CaptureError("JPEG scan entropy reaches EOF without marker")
            marker_offset = next_ff + 1
            while marker_offset < len(data) and data[marker_offset] == 0xFF:
                marker_offset += 1
            if marker_offset >= len(data):
                raise CaptureError("truncated marker after scan entropy")
            next_marker = data[marker_offset]
            if next_marker == 0x00 or 0xD0 <= next_marker <= 0xD7:
                search = marker_offset + 1
                continue
            scans.append(
                {
                    "scanNumber": len(scans) + 1,
                    "sosMarkerOffset": marker_start,
                    "entropyStartOffset": entropy_start,
                    "nextMarkerOffset": next_ff,
                    "nextMarkerCode": next_marker,
                    "nextMarkerAfterCodeOffset": marker_offset + 1,
                }
            )
            offset = next_ff
            break
    raise CaptureError("JPEG is missing terminal EOI")


def parse_ppm_rgb(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    if not data.startswith(b"P6"):
        raise CaptureError("djpeg reference is not binary PPM")
    position = 2
    tokens: list[bytes] = []
    while len(tokens) < 3:
        while position < len(data) and data[position : position + 1].isspace():
            position += 1
        if position < len(data) and data[position] == ord("#"):
            newline = data.find(b"\n", position)
            if newline < 0:
                raise CaptureError("unterminated PPM comment")
            position = newline + 1
            continue
        end = position
        while end < len(data) and not data[end : end + 1].isspace():
            end += 1
        if end == position:
            raise CaptureError("missing PPM header token")
        tokens.append(data[position:end])
        position = end
    try:
        width, height, maximum = (int(token) for token in tokens)
    except ValueError as error:
        raise CaptureError("PPM header contains a non-integer token") from error
    if maximum != 255:
        raise CaptureError("unexpected PPM sample precision")
    if position >= len(data) or not data[position : position + 1].isspace():
        raise CaptureError("PPM maxval is not followed by a raster separator")
    # P6 has exactly one whitespace separator between maxval and binary raster.
    # Accept CRLF as one textual line ending, but never skip arbitrary whitespace:
    # any subsequent byte is raster data and may itself legally be ASCII whitespace.
    if data[position : position + 2] == b"\r\n":
        position += 2
    else:
        position += 1
    rgb = data[position:]
    if len(rgb) != width * height * 3:
        raise CaptureError("PPM RGB payload shape mismatch")
    return width, height, rgb


def build_probe(temp: Path, jpeg_prefix: Path) -> Path:
    output = temp / "libjpeg-progressive-suspension-probe"
    run(
        [
            "cc",
            "-O2",
            "-Wall",
            "-Wextra",
            f"-I{jpeg_prefix / 'include'}",
            str(PROBE_SOURCE),
            f"-L{jpeg_prefix / 'lib'}",
            "-ljpeg",
            f"-Wl,-rpath,{jpeg_prefix / 'lib'}",
            "-o",
            str(output),
        ]
    )
    return output


def capture_no_backing_store_boundary(
    *,
    probe: Path,
    input_path: Path,
    temp: Path,
    case_id: str,
    input_size: int,
    maximum_scan_count: int,
    reference_rgb: bytes,
    threshold_bytes: int,
    pre_realize_pool_bytes: int,
    sharp_threshold_applicable: bool,
) -> dict[str, Any]:
    if threshold_bytes <= 1:
        raise CaptureError(f"invalid no-backing-store threshold: {case_id}")

    exact_prefix = temp / f"{case_id}-memory-threshold-exact"
    exact_completed = run(
        [
            str(probe),
            str(input_path),
            str(input_size),
            str(exact_prefix),
            str(maximum_scan_count),
            str(threshold_bytes),
        ]
    )
    if exact_completed.stderr.strip():
        raise CaptureError(
            f"exact memory-threshold decode emitted diagnostics for {case_id}: "
            f"{exact_completed.stderr.strip()}"
        )
    exact_observation = parse_json_stdout(
        exact_completed, f"exact memory-threshold probe {case_id}"
    )
    exact_output = Path(f"{exact_prefix}-final.rgb").read_bytes()
    if exact_output != reference_rgb:
        raise CaptureError(f"exact memory-threshold RGB drifted: {case_id}")
    if exact_observation.get("configuredMaxMemoryToUseBytes") != threshold_bytes:
        raise CaptureError(f"exact memory threshold was not applied: {case_id}")
    if (
        exact_observation.get("libjpegPoolBytesBeforeVirtualArrayRealization")
        != pre_realize_pool_bytes
    ):
        raise CaptureError(f"exact memory threshold changed pre-realize pool: {case_id}")
    if (
        exact_observation.get("libjpegFullVirtualArrayAvailabilityThresholdBytes")
        != threshold_bytes
    ):
        raise CaptureError(f"exact memory threshold did not reproduce itself: {case_id}")
    if (
        exact_observation.get("libjpegSharpNoBackingStoreThresholdApplicable")
        is not sharp_threshold_applicable
    ):
        raise CaptureError(f"memory-threshold applicability drifted: {case_id}")
    pool_after_start = exact_observation.get("libjpegPoolBytesAfterStartDecompress")
    if not isinstance(pool_after_start, int) or pool_after_start < threshold_bytes:
        raise CaptureError(f"exact memory-threshold pool report is invalid: {case_id}")

    result: dict[str, Any] = {
        "thresholdBytes": threshold_bytes,
        "preVirtualArrayPoolBytes": pre_realize_pool_bytes,
        "virtualArrayPayloadBytes": threshold_bytes - pre_realize_pool_bytes,
        "sharpThresholdApplicable": sharp_threshold_applicable,
        "thresholdExact": {
            "configuredMaxMemoryToUseBytes": threshold_bytes,
            "exactOneShotLibJPEGRGB": True,
            "poolBytesAfterStartDecompress": pool_after_start,
            "poolBytesBeyondConfiguredThreshold": pool_after_start - threshold_bytes,
        },
    }

    if sharp_threshold_applicable:
        rejected_limit = threshold_bytes - 1
        rejected_prefix = temp / f"{case_id}-memory-threshold-minus-one"
        rejected_completed = subprocess.run(
            [
                str(probe),
                str(input_path),
                str(input_size),
                str(rejected_prefix),
                str(maximum_scan_count),
                str(rejected_limit),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if rejected_completed.returncode != 4:
            raise CaptureError(
                f"threshold-minus-one did not fail through libjpeg for {case_id}: "
                f"code={rejected_completed.returncode} stderr={rejected_completed.stderr!r}"
            )
        rejected_observation = parse_json_stdout(
            rejected_completed, f"threshold-minus-one probe {case_id}"
        )
        if "Memory limit exceeded" not in rejected_completed.stderr:
            raise CaptureError(
                f"threshold-minus-one failed for the wrong reason: {case_id}: "
                f"{rejected_completed.stderr.strip()}"
            )
        if rejected_observation.get("status") != "libjpeg-error":
            raise CaptureError(f"threshold-minus-one error status drifted: {case_id}")
        if rejected_observation.get("configuredMaxMemoryToUseBytes") != rejected_limit:
            raise CaptureError(f"threshold-minus-one limit was not applied: {case_id}")
        if (
            rejected_observation.get("libjpegPoolBytesBeforeVirtualArrayRealization")
            != pre_realize_pool_bytes
        ):
            raise CaptureError(f"threshold-minus-one changed pre-realize pool: {case_id}")
        if rejected_observation.get("libjpegPoolBytesAtError") != pre_realize_pool_bytes:
            raise CaptureError(
                f"threshold-minus-one allocated pool bytes before failing closed: {case_id}"
            )
        if Path(f"{rejected_prefix}-final.rgb").exists():
            raise CaptureError(f"threshold-minus-one unexpectedly published output: {case_id}")
        result["thresholdMinusOne"] = {
            "applicable": True,
            "configuredMaxMemoryToUseBytes": rejected_limit,
            "returnCode": rejected_completed.returncode,
            "error": "Memory limit exceeded",
            "poolBytesAtError": rejected_observation["libjpegPoolBytesAtError"],
            "failedBeforeVirtualArrayPayloadAllocation": True,
            "publishedOutput": False,
        }
    else:
        minimum_limit = 1
        fallback_prefix = temp / f"{case_id}-memory-one-minheight-fallback"
        fallback_completed = run(
            [
                str(probe),
                str(input_path),
                str(input_size),
                str(fallback_prefix),
                str(maximum_scan_count),
                str(minimum_limit),
            ]
        )
        if fallback_completed.stderr.strip():
            raise CaptureError(
                f"one-minheight fallback emitted diagnostics for {case_id}: "
                f"{fallback_completed.stderr.strip()}"
            )
        fallback_observation = parse_json_stdout(
            fallback_completed, f"one-minheight fallback probe {case_id}"
        )
        fallback_output = Path(f"{fallback_prefix}-final.rgb").read_bytes()
        if fallback_output != reference_rgb:
            raise CaptureError(f"one-minheight fallback RGB drifted: {case_id}")
        if fallback_observation.get("configuredMaxMemoryToUseBytes") != minimum_limit:
            raise CaptureError(f"one-minheight fallback limit was not applied: {case_id}")
        if (
            fallback_observation.get("libjpegPoolBytesBeforeVirtualArrayRealization")
            != pre_realize_pool_bytes
        ):
            raise CaptureError(f"one-minheight fallback changed pre-realize pool: {case_id}")
        if fallback_observation.get("libjpegSharpNoBackingStoreThresholdApplicable") is not False:
            raise CaptureError(f"one-minheight fallback classification drifted: {case_id}")
        fallback_pool_after_start = fallback_observation.get(
            "libjpegPoolBytesAfterStartDecompress"
        )
        if not isinstance(fallback_pool_after_start, int):
            raise CaptureError(f"one-minheight fallback pool report is invalid: {case_id}")
        result["thresholdMinusOne"] = {
            "applicable": False,
            "reason": "all virtual coefficient arrays fit within the mandatory one-minheight fallback",
        }
        result["oneMinheightFallback"] = {
            "configuredMaxMemoryToUseBytes": minimum_limit,
            "exactOneShotLibJPEGRGB": True,
            "poolBytesAfterStartDecompress": fallback_pool_after_start,
            "poolBytesBeyondConfiguredLimit": fallback_pool_after_start - minimum_limit,
        }

    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, default=DEFAULT_PROFILE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    profile_path = args.profile if args.profile.is_absolute() else ROOT / args.profile
    output_path = args.output if args.output.is_absolute() else ROOT / args.output
    profile = json.loads(profile_path.read_text())
    if profile.get("profileID") != "IMAGECRAFT-INDEPENDENT-PROGRESSIVE-JPEG-SUSPENSION-V1":
        raise CaptureError("unexpected progressive suspension profile ID")

    with tempfile.TemporaryDirectory(prefix="imagecraft-libjpeg-progressive-") as temp_raw:
        temp = Path(temp_raw)
        before = capture_source_identity(temp / "source-before.json")
        jpeg_prefix = Path(run(["brew", "--prefix", "jpeg-turbo"]).stdout.strip())
        djpeg = jpeg_prefix / "bin/djpeg"
        if not djpeg.is_file():
            raise CaptureError(f"djpeg not found under {jpeg_prefix}")
        version = run([str(djpeg), "-version"]).stderr.strip() or run(
            [str(djpeg), "-version"]
        ).stdout.strip()
        required_version_prefix = profile.get("requiredLibJPEGTurboVersionPrefix")
        if (
            not isinstance(required_version_prefix, str)
            or not version.startswith(required_version_prefix)
        ):
            raise CaptureError(
                "libjpeg-turbo runtime is outside the private-memory ABI qualification: "
                f"required={required_version_prefix!r} actual={version!r}"
            )
        probe = build_probe(temp, jpeg_prefix)

        case_results: list[dict[str, Any]] = []
        maximum_scan_count = int(profile["maximumScanCount"])
        for case in profile["cases"]:
            case_id = str(case["id"])
            input_path = ROOT / str(case["file"])
            input_bytes = input_path.read_bytes()
            input_sha = sha256_bytes(input_bytes)
            if input_sha != case["sha256"]:
                raise CaptureError(f"input SHA drifted: {case_id}")
            scans = structural_scans(input_bytes)
            if len(scans) != int(case["scanCount"]):
                raise CaptureError(f"structural scan count drifted: {case_id}")

            reference_ppm = temp / f"{case_id}.reference.ppm"
            reference_completed = run(
                [
                    str(djpeg),
                    "-rgb",
                    "-pnm",
                    "-outfile",
                    str(reference_ppm),
                    str(input_path),
                ]
            )
            if reference_completed.stderr.strip():
                raise CaptureError(
                    f"djpeg emitted diagnostics for {case_id}: {reference_completed.stderr.strip()}"
                )
            reference_width, reference_height, reference_rgb = parse_ppm_rgb(reference_ppm)
            if reference_width != int(case["width"]) or reference_height != int(case["height"]):
                raise CaptureError(f"djpeg geometry drifted: {case_id}")
            reference_sha = sha256_bytes(reference_rgb)

            schedules: list[dict[str, Any]] = []
            canonical_event_scans: list[int] | None = None
            canonical_consumed_offsets: list[int] | None = None
            canonical_resource_signature: tuple[Any, ...] | None = None
            for raw_chunk in case["chunkSizes"]:
                chunk_size = len(input_bytes) if raw_chunk == "full" else int(raw_chunk)
                prefix = temp / f"{case_id}-{chunk_size}"
                completed = run(
                    [
                        str(probe),
                        str(input_path),
                        str(chunk_size),
                        str(prefix),
                        str(maximum_scan_count),
                    ]
                )
                if completed.stderr.strip():
                    raise CaptureError(
                        f"suspending probe emitted diagnostics for {case_id}/{chunk_size}: "
                        f"{completed.stderr.strip()}"
                    )
                observation = parse_json_stdout(completed, f"suspending probe {case_id}/{chunk_size}")
                output_rgb_path = Path(f"{prefix}-final.rgb")
                output_rgb = output_rgb_path.read_bytes()
                if output_rgb != reference_rgb:
                    raise CaptureError(
                        f"suspending final RGB differs from one-shot djpeg: {case_id}/{chunk_size}"
                    )
                if observation.get("width") != int(case["width"]) or observation.get("height") != int(case["height"]):
                    raise CaptureError(f"suspending geometry drifted: {case_id}/{chunk_size}")
                if observation.get("finalScanNumber") != len(scans):
                    raise CaptureError(f"suspending final scan count drifted: {case_id}/{chunk_size}")
                if observation.get("scanCompletedEventCount") != len(scans):
                    raise CaptureError(f"suspending scan event count drifted: {case_id}/{chunk_size}")
                if observation.get("warningCount") != 0:
                    raise CaptureError(f"suspending decode warned: {case_id}/{chunk_size}")
                if observation.get("finalOutputByteCount") != len(reference_rgb):
                    raise CaptureError(f"suspending output byte count drifted: {case_id}/{chunk_size}")
                capacity = observation.get("sourceBufferCapacityBytes")
                maximum_buffered = observation.get("maximumBufferedSourceBytes")
                if (
                    not isinstance(capacity, int)
                    or not isinstance(maximum_buffered, int)
                    or capacity <= 0
                    or maximum_buffered < 0
                    or maximum_buffered > capacity
                ):
                    raise CaptureError(f"suspending source-buffer report is invalid: {case_id}/{chunk_size}")
                coefficient_block_bytes = observation.get("coefficientBlockByteCount")
                coefficient_payload = observation.get("minimumCoefficientArrayPayloadBytes")
                persistent_payload = observation.get("minimumPersistentDecoderPayloadBytes")
                coefficient_components = observation.get("coefficientComponents")
                if (
                    not isinstance(coefficient_block_bytes, int)
                    or coefficient_block_bytes <= 0
                    or not isinstance(coefficient_payload, int)
                    or coefficient_payload <= 0
                    or not isinstance(persistent_payload, int)
                    or persistent_payload != coefficient_payload + capacity
                    or not isinstance(coefficient_components, list)
                    or not coefficient_components
                ):
                    raise CaptureError(f"suspending coefficient payload report is invalid: {case_id}/{chunk_size}")
                component_payload_sum = 0
                component_shapes: list[tuple[int, int, int]] = []
                for component in coefficient_components:
                    if not isinstance(component, dict):
                        raise CaptureError(f"suspending coefficient component is malformed: {case_id}/{chunk_size}")
                    component_payload = component.get("coefficientPayloadBytes")
                    padded_width = component.get("paddedWidthInBlocks")
                    padded_height = component.get("paddedHeightInBlocks")
                    if (
                        not isinstance(component_payload, int)
                        or component_payload <= 0
                        or not isinstance(padded_width, int)
                        or padded_width <= 0
                        or not isinstance(padded_height, int)
                        or padded_height <= 0
                    ):
                        raise CaptureError(f"suspending coefficient component payload is invalid: {case_id}/{chunk_size}")
                    component_payload_sum += component_payload
                    component_shapes.append((padded_height, padded_width, component_payload))
                if component_payload_sum != coefficient_payload:
                    raise CaptureError(f"suspending coefficient component sum drifted: {case_id}/{chunk_size}")

                virtual_coefficient_arrays = observation.get("virtualCoefficientArrays")
                observed_virtual_array_count = observation.get(
                    "libjpegObservedVirtualCoefficientArrayCount"
                )
                observed_virtual_sample_array_present = observation.get(
                    "libjpegObservedVirtualSampleArrayPresent"
                )
                if (
                    not isinstance(virtual_coefficient_arrays, list)
                    or not virtual_coefficient_arrays
                    or not isinstance(observed_virtual_array_count, int)
                    or observed_virtual_array_count != len(virtual_coefficient_arrays)
                    or observed_virtual_array_count != len(coefficient_components)
                    or observed_virtual_sample_array_present is not False
                ):
                    raise CaptureError(
                        f"suspending virtual-array inventory is malformed: {case_id}/{chunk_size}"
                    )
                virtual_maximum_space_sum = 0
                virtual_minheight_space_sum = 0
                virtual_maximum_required_minheights = 0
                virtual_shapes: list[tuple[int, int, int]] = []
                for array in virtual_coefficient_arrays:
                    if not isinstance(array, dict):
                        raise CaptureError(
                            f"suspending virtual coefficient array is malformed: {case_id}/{chunk_size}"
                        )
                    rows = array.get("rowsInArray")
                    blocks_per_row = array.get("blocksPerRow")
                    maximum_access_rows = array.get("maximumAccessRows")
                    minimum_heights = array.get("minimumHeights")
                    maximum_space_bytes = array.get("maximumSpaceBytes")
                    minheight_space_bytes = array.get("minheightSpaceBytes")
                    if (
                        not isinstance(rows, int)
                        or rows <= 0
                        or not isinstance(blocks_per_row, int)
                        or blocks_per_row <= 0
                        or not isinstance(maximum_access_rows, int)
                        or maximum_access_rows <= 0
                        or not isinstance(minimum_heights, int)
                        or minimum_heights
                        != (rows + maximum_access_rows - 1) // maximum_access_rows
                        or not isinstance(maximum_space_bytes, int)
                        or maximum_space_bytes
                        != rows * blocks_per_row * coefficient_block_bytes
                        or not isinstance(minheight_space_bytes, int)
                        or minheight_space_bytes
                        != maximum_access_rows * blocks_per_row * coefficient_block_bytes
                    ):
                        raise CaptureError(
                            f"suspending virtual coefficient geometry is malformed: {case_id}/{chunk_size}"
                        )
                    virtual_maximum_space_sum += maximum_space_bytes
                    virtual_minheight_space_sum += minheight_space_bytes
                    virtual_maximum_required_minheights = max(
                        virtual_maximum_required_minheights, minimum_heights
                    )
                    virtual_shapes.append((rows, blocks_per_row, maximum_space_bytes))
                if sorted(virtual_shapes) != sorted(component_shapes):
                    raise CaptureError(
                        f"virtual coefficient arrays do not match JPEG component geometry: {case_id}/{chunk_size}"
                    )
                private_abi = observation.get("libjpegPrivateMemoryABI")
                memory_prefix_bytes = observation.get("libjpegMemoryManagerPrefixByteCount")
                pool_after_create = observation.get("libjpegPoolBytesAfterCreate")
                pool_after_header = observation.get("libjpegPoolBytesAfterHeader")
                pool_before_virtual_arrays = observation.get(
                    "libjpegPoolBytesBeforeVirtualArrayRealization"
                )
                pool_after_start = observation.get("libjpegPoolBytesAfterStartDecompress")
                pool_after_eoi = observation.get("libjpegPoolBytesAfterEOI")
                pool_after_render = observation.get("libjpegPoolBytesAfterFinalRender")
                pool_after_finish = observation.get("libjpegPoolBytesAfterFinish")
                maximum_pool = observation.get("maximumObservedLibjpegPoolBytes")
                virtual_array_maximum_space = observation.get(
                    "libjpegVirtualArrayMaximumSpaceBytes"
                )
                virtual_array_space_per_minheight = observation.get(
                    "libjpegVirtualArraySpacePerMinheightBytes"
                )
                virtual_array_maximum_required_minheights = observation.get(
                    "libjpegVirtualArrayMaximumRequiredMinheights"
                )
                full_virtual_array_threshold = observation.get(
                    "libjpegFullVirtualArrayAvailabilityThresholdBytes"
                )
                sharp_no_backing_store_threshold = observation.get(
                    "libjpegSharpNoBackingStoreThresholdApplicable"
                )
                pre_realize_allocation_event_count = observation.get(
                    "preRealizeAllocationEventCount"
                )
                pre_realize_allocation_event_overflow = observation.get(
                    "preRealizeAllocationEventOverflow"
                )
                pre_realize_allocation_pool_growth = observation.get(
                    "preRealizeAllocationPoolGrowthBytes"
                )
                pre_realize_allocation_events = observation.get(
                    "preRealizeAllocationEvents"
                )
                source_manager_bytes = observation.get("sourceManagerStateByteCount")
                instrumentation_event_bytes = observation.get("instrumentationEventArrayByteCount")
                retained_live = observation.get("observedRetainedDecoderLiveBytesAtEOI")
                render_live = observation.get("observedFinalRenderLiveBytes")
                checkpoints = [
                    pool_after_create,
                    pool_after_header,
                    pool_after_start,
                    pool_after_eoi,
                    pool_after_render,
                    pool_after_finish,
                ]
                if (
                    private_abi != "libjpeg-turbo-3.2.0.jmemmgr.prefix-v1"
                    or not isinstance(memory_prefix_bytes, int)
                    or memory_prefix_bytes <= 0
                    or not isinstance(pool_before_virtual_arrays, int)
                    or pool_before_virtual_arrays <= 0
                    or not isinstance(virtual_array_maximum_space, int)
                    or virtual_array_maximum_space != coefficient_payload
                    or not isinstance(virtual_array_space_per_minheight, int)
                    or virtual_array_space_per_minheight != virtual_minheight_space_sum
                    or not isinstance(virtual_array_maximum_required_minheights, int)
                    or virtual_array_maximum_required_minheights
                    != virtual_maximum_required_minheights
                    or not isinstance(full_virtual_array_threshold, int)
                    or full_virtual_array_threshold
                    != pool_before_virtual_arrays + coefficient_payload
                    or not isinstance(sharp_no_backing_store_threshold, bool)
                    or sharp_no_backing_store_threshold
                    != (virtual_maximum_required_minheights > 1)
                    or not isinstance(pre_realize_allocation_event_count, int)
                    or pre_realize_allocation_event_count <= 0
                    or pre_realize_allocation_event_overflow is not False
                    or not isinstance(pre_realize_allocation_pool_growth, int)
                    or pre_realize_allocation_pool_growth < 0
                    or not isinstance(pre_realize_allocation_events, list)
                    or len(pre_realize_allocation_events)
                    != pre_realize_allocation_event_count
                    or virtual_array_maximum_space != virtual_maximum_space_sum
                    or any(not isinstance(value, int) or value <= 0 for value in checkpoints)
                    or not isinstance(maximum_pool, int)
                    or not isinstance(source_manager_bytes, int)
                    or source_manager_bytes < capacity
                    or not isinstance(instrumentation_event_bytes, int)
                    or instrumentation_event_bytes <= 0
                    or not isinstance(retained_live, int)
                    or not isinstance(render_live, int)
                ):
                    raise CaptureError(f"private libjpeg memory observation is malformed: {case_id}/{chunk_size}")
                assert isinstance(pool_after_create, int)
                assert isinstance(pool_after_header, int)
                assert isinstance(pool_before_virtual_arrays, int)
                assert isinstance(pool_after_start, int)
                assert isinstance(pool_after_eoi, int)
                assert isinstance(pool_after_render, int)
                assert isinstance(pool_after_finish, int)
                assert isinstance(maximum_pool, int)
                assert isinstance(source_manager_bytes, int)
                assert isinstance(retained_live, int)
                assert isinstance(render_live, int)
                assert isinstance(full_virtual_array_threshold, int)
                assert isinstance(pre_realize_allocation_pool_growth, int)
                assert isinstance(pre_realize_allocation_events, list)
                if not (
                    pool_after_create <= pool_after_header <= pool_before_virtual_arrays
                    <= pool_after_start
                    <= pool_after_eoi <= pool_after_render
                ):
                    raise CaptureError(f"libjpeg pool checkpoints are not monotone before finish: {case_id}/{chunk_size}")
                if pool_after_start < full_virtual_array_threshold:
                    raise CaptureError(
                        f"libjpeg pool after start is below virtual-array admission threshold: {case_id}/{chunk_size}"
                    )
                if pool_after_start < coefficient_payload or pool_after_eoi < coefficient_payload:
                    raise CaptureError(f"libjpeg pool does not cover coefficient payload: {case_id}/{chunk_size}")
                if maximum_pool != max(checkpoints):
                    raise CaptureError(f"libjpeg maximum pool observation drifted: {case_id}/{chunk_size}")
                if retained_live != pool_after_eoi + source_manager_bytes:
                    raise CaptureError(f"retained decoder live-byte composition drifted: {case_id}/{chunk_size}")
                if render_live != pool_after_render + source_manager_bytes + len(reference_rgb):
                    raise CaptureError(f"final-render live-byte composition drifted: {case_id}/{chunk_size}")

                allowed_allocation_kinds = {
                    "allocSmall",
                    "allocLarge",
                    "allocSArray",
                    "allocBArray",
                    "requestVirtSArray",
                    "requestVirtBArray",
                }
                allocation_growth_sum = 0
                previous_pool = pool_after_header
                for allocation in pre_realize_allocation_events:
                    if not isinstance(allocation, dict):
                        raise CaptureError(
                            f"pre-realize allocation event is malformed: {case_id}/{chunk_size}"
                        )
                    kind = allocation.get("kind")
                    pool_id = allocation.get("poolID")
                    logical_payload = allocation.get("logicalPayloadBytes")
                    first_dimension = allocation.get("firstDimension")
                    second_dimension = allocation.get("secondDimension")
                    pool_before = allocation.get("poolBytesBefore")
                    pool_after = allocation.get("poolBytesAfter")
                    pool_growth = allocation.get("poolGrowthBytes")
                    if (
                        kind not in allowed_allocation_kinds
                        or pool_id != 1
                        or not isinstance(logical_payload, int)
                        or logical_payload < 0
                        or not isinstance(first_dimension, int)
                        or first_dimension < 0
                        or not isinstance(second_dimension, int)
                        or second_dimension < 0
                        or not isinstance(pool_before, int)
                        or not isinstance(pool_after, int)
                        or not isinstance(pool_growth, int)
                        or pool_before != previous_pool
                        or pool_after < pool_before
                        or pool_growth != pool_after - pool_before
                    ):
                        raise CaptureError(
                            f"pre-realize allocation event contract drifted: {case_id}/{chunk_size}"
                        )
                    allocation_growth_sum += pool_growth
                    previous_pool = pool_after
                if (
                    previous_pool != pool_before_virtual_arrays
                    or allocation_growth_sum != pre_realize_allocation_pool_growth
                    or pre_realize_allocation_pool_growth
                    != pool_before_virtual_arrays - pool_after_header
                ):
                    raise CaptureError(
                        f"pre-realize allocation trace does not close the pool ledger: {case_id}/{chunk_size}"
                    )
                resource_signature = (
                    capacity,
                    coefficient_block_bytes,
                    coefficient_payload,
                    persistent_payload,
                    json.dumps(coefficient_components, sort_keys=True),
                    pool_after_create,
                    pool_after_header,
                    pool_before_virtual_arrays,
                    pool_after_start,
                    pool_after_eoi,
                    pool_after_render,
                    pool_after_finish,
                    maximum_pool,
                    virtual_array_maximum_space,
                    virtual_array_space_per_minheight,
                    virtual_array_maximum_required_minheights,
                    full_virtual_array_threshold,
                    sharp_no_backing_store_threshold,
                    pre_realize_allocation_pool_growth,
                    json.dumps(pre_realize_allocation_events, sort_keys=True),
                    source_manager_bytes,
                    retained_live,
                    render_live,
                )
                if canonical_resource_signature is None:
                    canonical_resource_signature = resource_signature
                elif resource_signature != canonical_resource_signature:
                    raise CaptureError(f"chunk partition changed decoder resource geometry: {case_id}/{chunk_size}")
                if chunk_size < len(input_bytes) and int(observation.get("suspensionCount", 0)) <= 0:
                    raise CaptureError(f"chunked case never suspended: {case_id}/{chunk_size}")

                events = observation.get("events")
                if not isinstance(events, list):
                    raise CaptureError(f"suspending events are malformed: {case_id}/{chunk_size}")
                event_scans = [int(event["scanNumber"]) for event in events]
                consumed_offsets = [int(event["consumedByteCount"]) for event in events]
                if event_scans != list(range(1, len(scans) + 1)):
                    raise CaptureError(f"suspending scan sequence is malformed: {case_id}/{chunk_size}")
                if canonical_event_scans is None:
                    canonical_event_scans = event_scans
                    canonical_consumed_offsets = consumed_offsets
                elif event_scans != canonical_event_scans or consumed_offsets != canonical_consumed_offsets:
                    raise CaptureError(f"chunk partition changed libjpeg scan state: {case_id}/{chunk_size}")

                schedules.append(
                    {
                        "requestedChunkSize": raw_chunk,
                        "resolvedChunkSize": chunk_size,
                        "finalRGBSHA256": sha256_bytes(output_rgb),
                        "exactOneShotLibJPEGRGB": True,
                        "observation": observation,
                    }
                )

            if not schedules:
                raise CaptureError(f"progressive case has no schedules: {case_id}")
            canonical_observation = schedules[0]["observation"]
            no_backing_store_boundary = capture_no_backing_store_boundary(
                probe=probe,
                input_path=input_path,
                temp=temp,
                case_id=case_id,
                input_size=len(input_bytes),
                maximum_scan_count=maximum_scan_count,
                reference_rgb=reference_rgb,
                threshold_bytes=int(
                    canonical_observation[
                        "libjpegFullVirtualArrayAvailabilityThresholdBytes"
                    ]
                ),
                pre_realize_pool_bytes=int(
                    canonical_observation["libjpegPoolBytesBeforeVirtualArrayRealization"]
                ),
                sharp_threshold_applicable=bool(
                    canonical_observation[
                        "libjpegSharpNoBackingStoreThresholdApplicable"
                    ]
                ),
            )

            case_results.append(
                {
                    **case,
                    "inputByteCount": len(input_bytes),
                    "inputSHA256": input_sha,
                    "structuralScans": scans,
                    "oneShotLibJPEG": {
                        "implementation": "djpeg.rgb.ppm",
                        "finalRGBByteCount": len(reference_rgb),
                        "finalRGBSHA256": reference_sha,
                    },
                    "schedules": schedules,
                    "chunkPartitionContractPassed": True,
                    "noBackingStoreAdmissionBoundary": no_backing_store_boundary,
                }
            )

        after = capture_source_identity(temp / "source-after.json")
        before_hash = before.get("sourceIdentitySHA256")
        if not before_hash or before_hash != after.get("sourceIdentitySHA256"):
            raise CaptureError("ImageCraft source identity changed during progressive suspension capture")

        report = {
            "schemaVersion": 1,
            "evidenceVersion": "imagecraft-independent-progressive-jpeg-suspension-v1",
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
                "jpegTurboPrefix": str(jpeg_prefix),
                "djpegVersion": version,
                "djpegSHA256": sha256_file(djpeg),
                "probeSHA256": sha256_file(probe),
                "probeSourceSHA256": sha256_file(PROBE_SOURCE),
            },
            "claimBoundary": profile["claimBoundary"],
            "cases": case_results,
            "summary": {
                "caseCount": len(case_results),
                "scheduleCount": sum(len(case["schedules"]) for case in case_results),
                "allChunkPartitionsExact": all(
                    case["chunkPartitionContractPassed"] for case in case_results
                ),
                "allOneShotLibJPEGExact": all(
                    schedule["exactOneShotLibJPEGRGB"]
                    for case in case_results
                    for schedule in case["schedules"]
                ),
                "allWarningsZero": all(
                    schedule["observation"]["warningCount"] == 0
                    for case in case_results
                    for schedule in case["schedules"]
                ),
                "allNoBackingStoreAdmissionClassificationsExact": all(
                    case["noBackingStoreAdmissionBoundary"]["thresholdExact"][
                        "exactOneShotLibJPEGRGB"
                    ]
                    and (
                        case["noBackingStoreAdmissionBoundary"]["thresholdMinusOne"].get(
                            "failedBeforeVirtualArrayPayloadAllocation", False
                        )
                        if case["noBackingStoreAdmissionBoundary"]["sharpThresholdApplicable"]
                        else case["noBackingStoreAdmissionBoundary"]["oneMinheightFallback"][
                            "exactOneShotLibJPEGRGB"
                        ]
                    )
                    for case in case_results
                ),
                "sharpNoBackingStoreThresholdCaseCount": sum(
                    1
                    for case in case_results
                    if case["noBackingStoreAdmissionBoundary"]["sharpThresholdApplicable"]
                ),
                "oneMinheightFallbackCaseCount": sum(
                    1
                    for case in case_results
                    if not case["noBackingStoreAdmissionBoundary"]["sharpThresholdApplicable"]
                ),
                "maximumPoolBytesBeforeVirtualArrayRealization": max(
                    case["noBackingStoreAdmissionBoundary"]["preVirtualArrayPoolBytes"]
                    for case in case_results
                ),
                "maximumFullVirtualArrayAvailabilityThresholdBytes": max(
                    case["noBackingStoreAdmissionBoundary"]["thresholdBytes"]
                    for case in case_results
                ),
                "maximumPoolBytesBeyondConfiguredThresholdAfterStart": max(
                    case["noBackingStoreAdmissionBoundary"]["thresholdExact"][
                        "poolBytesBeyondConfiguredThreshold"
                    ]
                    for case in case_results
                ),
                "maximumSourceBufferCapacityBytes": max(
                    schedule["observation"]["sourceBufferCapacityBytes"]
                    for case in case_results
                    for schedule in case["schedules"]
                ),
                "maximumObservedBufferedSourceBytes": max(
                    schedule["observation"]["maximumBufferedSourceBytes"]
                    for case in case_results
                    for schedule in case["schedules"]
                ),
                "maximumMinimumCoefficientArrayPayloadBytes": max(
                    schedule["observation"]["minimumCoefficientArrayPayloadBytes"]
                    for case in case_results
                    for schedule in case["schedules"]
                ),
                "maximumMinimumPersistentDecoderPayloadBytes": max(
                    schedule["observation"]["minimumPersistentDecoderPayloadBytes"]
                    for case in case_results
                    for schedule in case["schedules"]
                ),
                "maximumObservedLibjpegPoolBytes": max(
                    schedule["observation"]["maximumObservedLibjpegPoolBytes"]
                    for case in case_results
                    for schedule in case["schedules"]
                ),
                "maximumObservedRetainedDecoderLiveBytesAtEOI": max(
                    schedule["observation"]["observedRetainedDecoderLiveBytesAtEOI"]
                    for case in case_results
                    for schedule in case["schedules"]
                ),
                "maximumObservedFinalRenderLiveBytes": max(
                    schedule["observation"]["observedFinalRenderLiveBytes"]
                    for case in case_results
                    for schedule in case["schedules"]
                ),
            },
        }
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(
            "libjpeg progressive suspension captured: "
            f"cases={report['summary']['caseCount']} "
            f"schedules={report['summary']['scheduleCount']} "
            f"source={before_hash} output={output_path}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
