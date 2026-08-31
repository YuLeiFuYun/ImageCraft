#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from capture_libjpeg_progressive_allocation_geometry import (
    modeled_coefficient_pool_growth,
    modeled_large_pool_growth,
)
from capture_libjpeg_progressive_allocation_topology import model_row_workspace
from capture_libjpeg_progressive_suspension import (
    build_imagecraft_evidence,
    CaptureError,
    ROOT,
    parse_json_stdout,
    run,
    sha256_file,
)


DEFAULT_INPUT = ROOT / ".artifacts/program/T101/libjpeg-progressive-suspension-v1.json"
DEFAULT_OUTPUT = (
    ROOT / ".artifacts/program/T101/libjpeg-progressive-allocation-heldout-v1.json"
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    input_path = args.input if args.input.is_absolute() else ROOT / args.input
    output_path = args.output if args.output.is_absolute() else ROOT / args.output
    source_report = json.loads(input_path.read_text())
    if source_report.get("evidenceVersion") != "imagecraft-independent-progressive-jpeg-suspension-v1":
        raise CaptureError("unexpected progressive suspension evidence version")
    if source_report.get("formalSourceBoundExecution") is not True:
        raise CaptureError("heldout validation requires source-bound suspension evidence")
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

    results: list[dict[str, Any]] = []
    for case in source_report.get("cases", []):
        if not isinstance(case, dict):
            raise CaptureError("heldout suspension case is malformed")
        case_id = str(case["id"])
        schedules = case.get("schedules")
        if not isinstance(schedules, list) or not schedules:
            raise CaptureError(f"heldout case has no schedules: {case_id}")
        observation = schedules[0].get("observation")
        if not isinstance(observation, dict):
            raise CaptureError(f"heldout observation is malformed: {case_id}")
        width = observation.get("width")
        if not isinstance(width, int) or width <= 0:
            raise CaptureError(f"heldout width is invalid: {case_id}")
        components = observation.get("coefficientComponents")
        if not isinstance(components, list) or not components:
            raise CaptureError(f"heldout component geometry is missing: {case_id}")
        sampling: list[dict[str, int]] = []
        for component in components:
            if not isinstance(component, dict):
                raise CaptureError(f"heldout component is malformed: {case_id}")
            horizontal = component.get("horizontalSamplingFactor")
            vertical = component.get("verticalSamplingFactor")
            if (
                not isinstance(horizontal, int)
                or horizontal <= 0
                or not isinstance(vertical, int)
                or vertical <= 0
            ):
                raise CaptureError(f"heldout sampling is invalid: {case_id}")
            sampling.append({"horizontal": horizontal, "vertical": vertical})

        row_model = model_row_workspace(width, sampling)
        allocation_events = observation.get("preRealizeAllocationEvents")
        if not isinstance(allocation_events, list):
            raise CaptureError(f"heldout allocation events are missing: {case_id}")
        observed_sarrays = [
            event
            for event in allocation_events
            if isinstance(event, dict) and event.get("kind") == "allocSArray"
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
                f"heldout row workspace model drifted: {case_id}; "
                f"modeled={modeled_shapes} observed={observed_shapes}"
            )

        max_alloc_chunk = observation.get("libjpegMaxAllocChunkBytes")
        if not isinstance(max_alloc_chunk, int) or max_alloc_chunk <= 0:
            raise CaptureError(f"heldout max_alloc_chunk is missing: {case_id}")
        row_allocator = modeled_large_pool_growth(
            row_model, max_alloc_chunk=max_alloc_chunk
        )
        coefficient_allocator = modeled_coefficient_pool_growth(
            observation, max_alloc_chunk=max_alloc_chunk
        )
        header_pool = observation.get("libjpegPoolBytesAfterHeader")
        observed_start_pool = observation.get("libjpegPoolBytesAfterStartDecompress")
        if not isinstance(header_pool, int) or not isinstance(observed_start_pool, int):
            raise CaptureError(f"heldout pool checkpoints are invalid: {case_id}")
        modeled_start_pool = (
            header_pool
            + int(row_allocator["expectedPoolGrowthBytes"])
            + int(coefficient_allocator["expectedPoolGrowthBytes"])
        )
        if modeled_start_pool != observed_start_pool:
            raise CaptureError(
                f"heldout post-start pool model drifted: {case_id}; "
                f"modeled={modeled_start_pool} observed={observed_start_pool}"
            )
        non_sarray_growth = int(observation["preRealizeAllocationPoolGrowthBytes"]) - sum(
            int(event["poolGrowthBytes"]) for event in observed_sarrays
        )
        if non_sarray_growth != 0:
            raise CaptureError(
                f"heldout small/control allocations expanded pre-realize pool: {case_id}"
            )

        source_path = ROOT / str(case["file"])
        imagecraft_completed = run(
            [
                str(imagecraft_evidence),
                "--progressive-jpeg-resource-geometry",
                str(source_path),
            ]
        )
        if imagecraft_completed.stderr.strip():
            raise CaptureError(
                f"heldout ImageCraft resource geometry emitted diagnostics: {case_id}: "
                f"{imagecraft_completed.stderr.strip()}"
            )
        imagecraft_report = parse_json_stdout(
            imagecraft_completed, f"heldout ImageCraft resource geometry {case_id}"
        )
        imagecraft_geometry = imagecraft_report.get("geometry")
        if not isinstance(imagecraft_geometry, dict):
            raise CaptureError(f"heldout ImageCraft resource geometry is malformed: {case_id}")
        expected_context = bool(row_model["needsContextRows"])
        if (
            imagecraft_geometry.get("width") != width
            or imagecraft_geometry.get("height") != observation.get("height")
            or imagecraft_geometry.get("precision") != 8
            or imagecraft_geometry.get("fullScaleFancyRowWorkspaceBytes")
            != row_model["logicalRowWorkspaceBytes"]
            or imagecraft_geometry.get("fancyVerticalContextRowsRequired") is not expected_context
            or imagecraft_geometry.get("coefficientArrayPayloadBytes")
            != observation.get("minimumCoefficientArrayPayloadBytes")
        ):
            raise CaptureError(
                f"heldout ImageCraft resource geometry disagrees with source model: {case_id}"
            )
        imagecraft_components = imagecraft_geometry.get("components")
        if not isinstance(imagecraft_components, list) or len(imagecraft_components) != len(
            components
        ):
            raise CaptureError(f"heldout ImageCraft component geometry is malformed: {case_id}")
        for component_index, (imagecraft_component, observed_component) in enumerate(
            zip(imagecraft_components, components)
        ):
            if not isinstance(imagecraft_component, dict) or not isinstance(
                observed_component, dict
            ):
                raise CaptureError(
                    f"heldout component geometry is malformed: {case_id}/{component_index}"
                )
            expected_component = {
                "componentID": observed_component.get("componentID"),
                "horizontalSamplingFactor": observed_component.get(
                    "horizontalSamplingFactor"
                ),
                "verticalSamplingFactor": observed_component.get("verticalSamplingFactor"),
                "widthInBlocks": observed_component.get("widthInBlocks"),
                "heightInBlocks": observed_component.get("heightInBlocks"),
                "paddedWidthInBlocks": observed_component.get("paddedWidthInBlocks"),
                "paddedHeightInBlocks": observed_component.get("paddedHeightInBlocks"),
                "coefficientPayloadBytes": observed_component.get("coefficientPayloadBytes"),
            }
            if imagecraft_component != expected_component:
                raise CaptureError(
                    f"heldout ImageCraft/libjpeg component geometry disagrees: "
                    f"{case_id}/{component_index}"
                )

        owned_completed = run(
            [
                str(imagecraft_evidence),
                "--progressive-jpeg-owned-variable-state",
                str(source_path),
            ]
        )
        if owned_completed.stderr.strip():
            raise CaptureError(
                f"heldout ImageCraft owned variable state emitted diagnostics: {case_id}: "
                f"{owned_completed.stderr.strip()}"
            )
        owned_report = parse_json_stdout(
            owned_completed, f"heldout ImageCraft owned variable state {case_id}"
        )
        owned_plan = owned_report.get("plan")
        if not isinstance(owned_plan, dict):
            raise CaptureError(f"heldout owned variable-state plan is malformed: {case_id}")
        expected_owned_variable_bytes = (
            int(row_allocator["alignedRowPayloadBytes"])
            + int(coefficient_allocator["coefficientPayloadBytes"])
        )
        if (
            owned_report.get("evidenceVersion")
            != "imagecraft-progressive-jpeg-owned-variable-state-v1"
            or owned_report.get("exactBudgetAccepted") is not True
            or owned_report.get("thresholdMinusOneRejectedBeforeAllocation") is not True
            or owned_report.get("allBuffersAligned") is not True
            or owned_report.get("allBuffersInitiallyZero") is not True
            or owned_plan.get("coefficientStorageBytes")
            != coefficient_allocator["coefficientPayloadBytes"]
            or owned_plan.get("logicalRowWorkspaceBytes")
            != row_model["logicalRowWorkspaceBytes"]
            or owned_plan.get("rowWorkspaceStorageBytes")
            != row_allocator["alignedRowPayloadBytes"]
            or owned_plan.get("totalVariableStateBytes") != expected_owned_variable_bytes
        ):
            raise CaptureError(
                f"heldout ImageCraft owned variable state disagrees with proven geometry: {case_id}"
            )

        results.append(
            {
                "id": case_id,
                "width": width,
                "height": observation["height"],
                "samplingFactors": sampling,
                "rowWorkspaceModel": row_model,
                "rowAllocatorModel": row_allocator,
                "coefficientAllocatorModel": coefficient_allocator,
                "poolBytesAfterHeader": header_pool,
                "modeledPoolBytesAfterStartDecompress": modeled_start_pool,
                "observedPoolBytesAfterStartDecompress": observed_start_pool,
                "exactPostStartPoolModel": True,
                "imageCraftResourceGeometry": imagecraft_report,
                "exactImageCraftResourceGeometryModel": True,
                "imageCraftOwnedVariableState": owned_report,
                "expectedOwnedVariableStateBytes": expected_owned_variable_bytes,
                "exactImageCraftOwnedVariableStateModel": True,
            }
        )

    if not results:
        raise CaptureError("heldout allocation validation has no cases")
    report = {
        "schemaVersion": 1,
        "evidenceVersion": "imagecraft-independent-progressive-jpeg-allocation-heldout-v1",
        "status": "source-bound-heldout-mechanism-conformance",
        "formalSourceBoundExecution": True,
        "productionBackendQualified": False,
        "sourceEvidence": {
            "path": str(input_path.relative_to(ROOT)),
            "sha256": sha256_file(input_path),
            "sourceIdentity": source_report["sourceIdentity"],
            "runtime": source_report["runtime"],
            "imageCraftEvidenceSHA256": sha256_file(imagecraft_evidence),
        },
        "claimBoundary": [
            "This validator applies the allocation formula derived from pinned libjpeg-turbo 3.2.0 source and the separate width/sampling geometry matrix to retained progressive-JPEG cases that were not generated by the geometry matrix.",
            "Exact agreement is required for allocSArray request shapes and total libjpeg pool bytes immediately after jpeg_start_decompress. No heldout residual is converted into a fitted constant.",
            "The result remains private-ABI, source-bound mechanism evidence and does not qualify a production ImageCraft backend, physical RSS bound, or cross-version libjpeg contract."
        ],
        "cases": results,
        "summary": {
            "caseCount": len(results),
            "allPostStartPoolModelsExact": all(
                bool(result["exactPostStartPoolModel"]) for result in results
            ),
            "allImageCraftResourceGeometryModelsExact": all(
                bool(result["exactImageCraftResourceGeometryModel"])
                for result in results
            ),
            "allImageCraftOwnedVariableStateModelsExact": all(
                bool(result["exactImageCraftOwnedVariableStateModel"])
                for result in results
            ),
            "maximumModeledPoolBytesAfterStartDecompress": max(
                int(result["modeledPoolBytesAfterStartDecompress"])
                for result in results
            ),
            "maximumOwnedVariableStateBytes": max(
                int(result["expectedOwnedVariableStateBytes"])
                for result in results
            ),
        },
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(
        "libjpeg progressive allocation heldout validation passed: "
        f"cases={len(results)} output={output_path}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
