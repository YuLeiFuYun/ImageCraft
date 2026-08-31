#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_PROFILE = ROOT / "Evidence/Experiments/IndependentProgressiveJPEG420Session/v1/profile.json"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: Path) -> dict:
    return json.loads(path.read_text())


def bounded_value(bound: dict) -> int:
    bounded = bound.get("bounded")
    if not isinstance(bounded, dict) or "_0" not in bounded:
        raise ValueError(f"expected bounded resource value, got {bound!r}")
    return int(bounded["_0"])


def validate(profile_path: Path) -> dict:
    profile_path = profile_path.resolve()
    profile = load_json(profile_path)
    schema_version = int(profile.get("schemaVersion", 0))
    if schema_version not in (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17):
        raise ValueError("unsupported profile schema")
    fixed = profile["fixedSessionResources"]
    transport = int(fixed["transportCapacityBytes"])
    if schema_version == 1:
        if int(fixed["fixedSessionByteCharge"]) != (
            transport
            + int(fixed["pendingTableCapacityBytes"])
            + int(fixed["pendingTableRecordBytes"])
            + int(fixed["rollbackCoefficientBytes"])
        ):
            raise ValueError("fixed session byte charge does not compose exactly")
    else:
        preframe = int(fixed["preFrameTableStateByteCount"])
        scratch = int(fixed["operationScratchByteCharge"])
        if int(fixed["initialRetainedByteCharge"]) != transport + preframe:
            raise ValueError("initial retained charge does not compose exactly")
        if schema_version >= 11:
            expected_preframe = 4 * 64 + 8 * (16 + 256)
            if preframe != expected_preframe:
                raise ValueError("pre-frame maximum authority does not equal four DQT plus eight DHT slot capacities")
        if schema_version >= 14:
            progression = int(fixed["progressionStateByteCount"])
            if progression != (3 * 64) // 2:
                raise ValueError("progression state is not two four-bit entries per byte")
        if schema_version >= 17:
            final_sample_scratch = int(fixed["finalSampleMaterializationScratchByteCount"])
            if final_sample_scratch != 64 * 4 + 64 * 2:
                raise ValueError("final sample materialization scratch is not IDCT plus quantization widening")
        if scratch != int(fixed["rollbackCoefficientBytes"]):
            raise ValueError("operation scratch must equal transactional rollback coefficients")
        if schema_version >= 3:
            marker_bound = int(fixed["maximumMarkerSegmentEncodedBytes"])
            entropy_bound = int(fixed["maximumEntropyTransactionEncodedBytes"])
            if marker_bound != 2 + 0xFFFF:
                raise ValueError("marker transport bound is not the JPEG 16-bit segment maximum")
            if schema_version == 3:
                if entropy_bound != 2 * ((63 * (16 + 10) + 7) // 8) + 2:
                    raise ValueError("v3 entropy bound drifted from its historical model")
                if transport != max(marker_bound, entropy_bound):
                    raise ValueError("v3 transport capacity does not equal the dominant syntax bound")
            else:
                semantic_marker_bound = int(fixed["maximumMarkerSemanticUnitBytes"])
                ac_first_bits = int(fixed["maximumACFirstTransactionBitCount"])
                dc_first_bits = int(fixed["maximumInterleavedDCFirstTransactionBitCount"])
                ac_refine_bits = int(fixed["maximumACRefineTransactionBitCount"])
                if semantic_marker_bound != 1 + 16 + 256:
                    raise ValueError("marker semantic-unit bound does not match one maximum DHT table")
                if ac_first_bits != 62 * (16 + 10) + (16 + 14):
                    raise ValueError("AC-first transaction bit bound does not match the qualified syntax")
                if dc_first_bits != 6 * (16 + 11):
                    raise ValueError("DC-first transaction bit bound does not match the qualified syntax")
                if ac_refine_bits != 63 * 16 + 63 + 14:
                    raise ValueError("AC-refine transaction bit bound does not match the qualified syntax")
                expected_entropy = 2 * ((max(ac_first_bits, dc_first_bits, ac_refine_bits) + 7) // 8) + 2
                if entropy_bound != expected_entropy:
                    raise ValueError("entropy transaction byte bound does not compose from the bit bounds")
                if transport != max(semantic_marker_bound, entropy_bound):
                    raise ValueError("streaming transport does not equal the dominant semantic-unit bound")

    results = []
    for case in profile["cases"]:
        source = ROOT / case["input"]
        if sha256(source) != case["inputSHA256"]:
            raise ValueError(f"source hash drift: {case['id']}")
        report_path = profile_path.parent / case["report"]
        report = load_json(report_path)
        if int(report["schemaVersion"]) != schema_version:
            raise ValueError(f"report schema drift: {case['id']}")
        if report["source"]["sha256"] != case["inputSHA256"]:
            raise ValueError(f"report source hash mismatch: {case['id']}")
        if report["schedule"]["id"] != case["schedule"]:
            raise ValueError(f"schedule mismatch: {case['id']}")
        if report["previewCadence"] != case["previewCadence"]:
            raise ValueError(f"preview cadence mismatch: {case['id']}")
        if not report["finalMatchesCompleteDecoder"]:
            raise ValueError(f"final RGB mismatch: {case['id']}")
        if report["finalRGBSHA256"] != report["completeDecoderRGBSHA256"]:
            raise ValueError(f"final RGB hash mismatch: {case['id']}")
        if report["acceptedEncodedBytes"] != report["source"]["byteCount"]:
            raise ValueError(f"accepted source count mismatch: {case['id']}")
        if report["reclaimedEncodedBytes"] != report["source"]["byteCount"]:
            raise ValueError(f"reclaimed source count mismatch: {case['id']}")
        if report["retainedTransportBytesBeforeFinish"] != 0:
            raise ValueError(f"transport not reclaimed before finish: {case['id']}")
        if report["maximumObservedTransportBytes"] > transport:
            raise ValueError(f"transport capacity exceeded: {case['id']}")
        if schema_version == 1:
            if report["maximumPendingTableRecordCount"] != int(fixed["maximumPendingTableRecordCount"]):
                raise ValueError(f"pending-table record capacity mismatch: {case['id']}")
            if report["pendingTableRecordBytes"] != int(fixed["pendingTableRecordBytes"]):
                raise ValueError(f"pending-table record charge mismatch: {case['id']}")
        else:
            if schema_version >= 3:
                if report["maximumMarkerSegmentEncodedBytes"] != int(fixed["maximumMarkerSegmentEncodedBytes"]):
                    raise ValueError(f"marker syntax bound mismatch: {case['id']}")
                if report["maximumEntropyTransactionEncodedBytes"] != int(fixed["maximumEntropyTransactionEncodedBytes"]):
                    raise ValueError(f"entropy syntax bound mismatch: {case['id']}")
            if schema_version >= 4:
                if report["maximumMarkerSemanticUnitBytes"] != int(fixed["maximumMarkerSemanticUnitBytes"]):
                    raise ValueError(f"marker semantic-unit bound mismatch: {case['id']}")
                if report["maximumACFirstTransactionBitCount"] != int(fixed["maximumACFirstTransactionBitCount"]):
                    raise ValueError(f"AC-first bit bound mismatch: {case['id']}")
                if report["maximumInterleavedDCFirstTransactionBitCount"] != int(fixed["maximumInterleavedDCFirstTransactionBitCount"]):
                    raise ValueError(f"DC-first bit bound mismatch: {case['id']}")
                if report["maximumACRefineTransactionBitCount"] != int(fixed["maximumACRefineTransactionBitCount"]):
                    raise ValueError(f"AC-refine bit bound mismatch: {case['id']}")
            if schema_version >= 6:
                persistent = int(report["persistentStateByteCount"])
                render_scratch = int(report["renderScratchByteCount"])
                state_plan = report["statePlan"]
                if schema_version >= 9:
                    base_fixed = int(report["persistentBaseFixedStateByteCount"])
                    max_table_payload = int(report["maximumHuffmanTablePayloadByteCount"])
                    max_huffman = int(report["maximumHuffmanStateByteCount"])
                    if base_fixed != int(fixed["persistentBaseFixedStateByteCount"]):
                        raise ValueError(f"persistent base fixed charge mismatch: {case['id']}")
                    if max_table_payload != int(fixed["maximumHuffmanTablePayloadByteCount"]):
                        raise ValueError(f"maximum Huffman table payload mismatch: {case['id']}")
                    if max_huffman != int(fixed["maximumHuffmanStateByteCount"]):
                        raise ValueError(f"maximum Huffman state mismatch: {case['id']}")
                    if max_table_payload != 16 + 256 or max_huffman != 8 * max_table_payload:
                        raise ValueError(f"Huffman maximum authority does not compose: {case['id']}")
                    if schema_version == 13:
                        if base_fixed != 3 * 64 + 3 * 64:
                            raise ValueError(f"persistent base fixed state is not three UInt8 quantization tables plus progression: {case['id']}")
                    elif schema_version >= 14:
                        progression = int(report["progressionStateByteCount"])
                        if progression != int(fixed["progressionStateByteCount"]):
                            raise ValueError(f"progression state charge mismatch: {case['id']}")
                        if progression != (3 * 64) // 2:
                            raise ValueError(f"progression state is not two four-bit entries per byte: {case['id']}")
                        if base_fixed != 3 * 64 + progression:
                            raise ValueError(f"persistent base fixed state is not UInt8 quantization plus packed progression: {case['id']}")
                    if schema_version >= 13:
                        if int(fixed["renderFixedScratchByteCount"]) != 256 + 128 + 128:
                            raise ValueError(f"render fixed scratch is not IDCT + smoothing + quantization widening: {case['id']}")
                    persistent_base = int(report["persistentBaseStateByteCount"])
                    expected_base = int(state_plan["coefficientStateBytes"]) + base_fixed
                    if persistent_base != expected_base:
                        raise ValueError(f"persistent base state decomposition mismatch: {case['id']}")
                    expected_persistent = persistent_base + max_huffman
                else:
                    expected_persistent = int(state_plan["coefficientStateBytes"]) + int(
                        fixed["persistentFixedStateByteCount"]
                    )
                expected_render = int(state_plan["rowStateBytes"]) + int(
                    fixed["renderFixedScratchByteCount"]
                )
                if persistent != expected_persistent:
                    raise ValueError(f"persistent state decomposition mismatch: {case['id']}")
                if render_scratch != expected_render:
                    raise ValueError(f"render scratch decomposition mismatch: {case['id']}")
                if schema_version == 15:
                    expected_rows = (
                        18 * int(state_plan["yRowStrideBytes"])
                        + 18 * int(state_plan["chromaRowStrideBytes"])
                    )
                    if int(state_plan["rowStateBytes"]) != expected_rows:
                        raise ValueError(f"v15 render-row model drifted: {case['id']}")
                elif schema_version >= 16:
                    expected_rows = (
                        16 * int(state_plan["yRowStrideBytes"])
                        + 18 * int(state_plan["chromaRowStrideBytes"])
                    )
                    if int(state_plan["rowStateBytes"]) != expected_rows:
                        raise ValueError(f"render rows still materialize full-width chroma staging: {case['id']}")
                    historical_report_path = profile_path.parent.parent / "v15" / case["report"]
                    historical = load_json(historical_report_path)
                    y_stride = int(state_plan["yRowStrideBytes"])
                    expected_release = 2 * y_stride
                    if int(historical["persistentStateByteCount"]) != persistent:
                        raise ValueError(f"v16 changed persistent state while removing render staging: {case['id']}")
                    if int(historical["maximumRetainedByteChargeBeforeFinish"]) != int(
                        report["maximumRetainedByteChargeBeforeFinish"]
                    ):
                        raise ValueError(f"v16 changed maximum retained authority: {case['id']}")
                    if int(historical["renderScratchByteCount"]) - render_scratch != expected_release:
                        raise ValueError(f"v16 render-scratch release is not exactly two Y rows: {case['id']}")
                    if int(historical["statePlan"]["rowStateBytes"]) - int(
                        state_plan["rowStateBytes"]
                    ) != expected_release:
                        raise ValueError(f"v16 row-state release is not exactly two Y rows: {case['id']}")
                    if historical["finalRGBSHA256"] != report["finalRGBSHA256"]:
                        raise ValueError(f"v16 fused render changed final RGB: {case['id']}")
                if persistent + render_scratch != int(state_plan["totalStateBytes"]):
                    raise ValueError(f"persistent/render state does not recompose total: {case['id']}")
                if schema_version >= 17:
                    sample_bytes = int(report["finalSamplePlaneByteCount"])
                    sample_scratch = int(report["finalSampleMaterializationScratchByteCount"])
                    expected_samples = (
                        int(state_plan["width"]) * int(state_plan["height"])
                        + 2 * int(state_plan["chromaWidth"]) * int(state_plan["chromaHeight"])
                    )
                    if sample_bytes != expected_samples:
                        raise ValueError(f"final sample payload does not match tight 4:2:0 geometry: {case['id']}")
                    if sample_scratch != int(fixed["finalSampleMaterializationScratchByteCount"]):
                        raise ValueError(f"final sample materialization scratch mismatch: {case['id']}")
                    if "finalSamplePlaneByteCount" in case:
                        if sample_bytes != int(case["finalSamplePlaneByteCount"]):
                            raise ValueError(f"final sample payload witness mismatch: {case['id']}")
            if schema_version >= 7:
                quant_source = int(report["frameQuantizationSourceByteCount"])
                if quant_source != int(fixed["frameQuantizationSourceByteCount"]):
                    raise ValueError(f"frame quantization-source charge mismatch: {case['id']}")
                if schema_version <= 11:
                    if quant_source != 4 * 64 + 4:
                        raise ValueError(f"historical frame quantization-source state drifted: {case['id']}")
                else:
                    if quant_source != 4 * 64:
                        raise ValueError(f"frame quantization maximum authority is not four DQT payloads: {case['id']}")
                if int(report["retainedFrameQuantizationSourceBytesBeforeFinish"]) != 0:
                    raise ValueError(f"raw quantization-source state survived first-SOS latch: {case['id']}")
                observed_quant_source = int(report["maximumObservedFrameQuantizationSourceBytes"])
                if schema_version <= 11:
                    if observed_quant_source != quant_source:
                        raise ValueError(f"historical raw quantization-source allocation drifted: {case['id']}")
                else:
                    if observed_quant_source <= 0 or observed_quant_source > quant_source:
                        raise ValueError(f"dynamic frame quantization-source high-water is outside maximum authority: {case['id']}")
                    if "maximumObservedFrameQuantizationSourceBytes" in case:
                        if observed_quant_source != int(case["maximumObservedFrameQuantizationSourceBytes"]):
                            raise ValueError(f"frame quantization-source high-water mismatch: {case['id']}")
            if schema_version >= 8:
                dummy_scratch = int(report["dummyCoefficientScratchByteCount"])
                if dummy_scratch != int(fixed["dummyCoefficientScratchByteCount"]):
                    raise ValueError(f"dummy coefficient scratch mismatch: {case['id']}")
                if dummy_scratch != 64 * 2:
                    raise ValueError(f"dummy coefficient scratch is not one Int16 block: {case['id']}")
                if dummy_scratch > int(fixed["operationScratchByteCharge"]):
                    raise ValueError(f"dummy coefficient scratch widens operation scratch: {case['id']}")
                state_plan = report["statePlan"]
                actual_y_blocks = int(state_plan["yActualWidthBlocks"]) * int(state_plan["yActualHeightBlocks"])
                padded_y_blocks = int(state_plan["yPaddedWidthBlocks"]) * int(state_plan["yPaddedHeightBlocks"])
                y_bytes = int(state_plan["yCoefficientBytes"])
                chroma_bytes = int(state_plan["chromaCoefficientBytesPerComponent"])
                if y_bytes != actual_y_blocks * 64 * 2:
                    raise ValueError(f"persistent Y coefficients include non-image blocks: {case['id']}")
                if padded_y_blocks < actual_y_blocks:
                    raise ValueError(f"padded Y syntax geometry is smaller than actual image geometry: {case['id']}")
                if int(state_plan["coefficientStateBytes"]) != y_bytes + 2 * chroma_bytes:
                    raise ValueError(f"coefficient state does not recompose from component planes: {case['id']}")
                released_padding = (padded_y_blocks - actual_y_blocks) * 64 * 2
                if "minimumReleasedPaddedYCoefficientBytes" in case:
                    if released_padding < int(case["minimumReleasedPaddedYCoefficientBytes"]):
                        raise ValueError(f"padded-Y release witness disappeared: {case['id']}")
            if schema_version >= 9:
                retained_huffman = int(report["retainedHuffmanTableBytesBeforeFinish"])
                maximum_observed_huffman = int(report["maximumObservedHuffmanTableBytes"])
                maximum_huffman = int(report["maximumHuffmanStateByteCount"])
                if retained_huffman < 0 or retained_huffman > maximum_huffman:
                    raise ValueError(f"retained Huffman payload is outside maximum authority: {case['id']}")
                if maximum_observed_huffman < retained_huffman or maximum_observed_huffman > maximum_huffman:
                    raise ValueError(f"Huffman high-water is outside exact authority: {case['id']}")
                if "retainedHuffmanTableBytes" in case:
                    if retained_huffman != int(case["retainedHuffmanTableBytes"]):
                        raise ValueError(f"retained Huffman payload mismatch: {case['id']}")
                if "maximumObservedHuffmanTableBytes" in case:
                    if maximum_observed_huffman != int(case["maximumObservedHuffmanTableBytes"]):
                        raise ValueError(f"Huffman high-water mismatch: {case['id']}")
                if schema_version >= 10:
                    final_huffman = int(report["finalHuffmanTableBytesBeforeCompaction"])
                    if retained_huffman != 0:
                        raise ValueError(f"final-ready state still retains Huffman payload: {case['id']}")
                    if final_huffman <= 0 or final_huffman > maximum_observed_huffman:
                        raise ValueError(f"captured final Huffman payload is outside observed history: {case['id']}")
                    if "finalHuffmanTableBytesBeforeCompaction" in case:
                        if final_huffman != int(case["finalHuffmanTableBytesBeforeCompaction"]):
                            raise ValueError(f"captured final Huffman payload mismatch: {case['id']}")
            if report["preFrameTableStateByteCount"] != int(fixed["preFrameTableStateByteCount"]):
                raise ValueError(f"pre-frame table charge mismatch: {case['id']}")
            if report["initialRetainedByteCharge"] != int(fixed["initialRetainedByteCharge"]):
                raise ValueError(f"initial retained charge mismatch: {case['id']}")
            if schema_version >= 11:
                actual_initial = int(report["actualInitialRetainedByteCharge"])
                retained_preframe = int(report["retainedPreFrameTableBytesBeforeFinish"])
                maximum_observed_preframe = int(report["maximumObservedPreFrameTableBytes"])
                if actual_initial != transport:
                    raise ValueError(f"initial actual retained state is not transport-only: {case['id']}")
                if retained_preframe != 0:
                    raise ValueError(f"pre-frame table payload survived SOF transition: {case['id']}")
                if maximum_observed_preframe < 0 or maximum_observed_preframe > preframe:
                    raise ValueError(f"pre-frame table high-water is outside maximum authority: {case['id']}")
                if "maximumObservedPreFrameTableBytes" in case:
                    if maximum_observed_preframe != int(case["maximumObservedPreFrameTableBytes"]):
                        raise ValueError(f"pre-frame table high-water mismatch: {case['id']}")
            if report["operationScratchByteCharge"] != int(fixed["operationScratchByteCharge"]):
                raise ValueError(f"operation scratch charge mismatch: {case['id']}")
            if report["rollbackCoefficientBytes"] != int(fixed["rollbackCoefficientBytes"]):
                raise ValueError(f"rollback coefficient charge mismatch: {case['id']}")
            expected_preview_count = report["scanCount"] if report["previewCadence"] == "every-completed-scan" else 0
            if report["observedPreviewCount"] != expected_preview_count:
                raise ValueError(f"preview observation count mismatch: {case['id']}")
            if not report["previewBackingWasStable"]:
                raise ValueError(f"preview output backing was not stable: {case['id']}")
        completed = report["schedule"]["completedScans"]
        if completed != list(range(1, report["scanCount"] + 1)):
            raise ValueError(f"non-contiguous completed scans: {case['id']}")
        terminal = report["terminalResourceLedger"]
        if not terminal["isTerminal"]:
            raise ValueError(f"terminal ledger missing: {case['id']}")
        if any(
            value != 0
            for value in (
                terminal["retainedKnownBytes"],
                bounded_value(terminal["retainedBetweenCalls"]),
                bounded_value(terminal["operationPeak"]),
                bounded_value(terminal["transferredOutput"]),
            )
        ):
            raise ValueError(f"terminal ledger retains resource charge: {case['id']}")
        prefinish = report["preFinishResourceLedger"]
        if schema_version == 1:
            if bounded_value(prefinish["retainedBetweenCalls"]) != report["codecOwnedByteCharge"]:
                raise ValueError(f"retained ledger mismatch: {case['id']}")
            if bounded_value(prefinish["operationPeak"]) != report["codecOwnedByteCharge"]:
                raise ValueError(f"operation ledger mismatch: {case['id']}")
        else:
            retained = int(report["retainedByteChargeBeforeFinish"])
            operation_peak = int(report["operationPeakByteCharge"])
            if bounded_value(prefinish["retainedBetweenCalls"]) != retained:
                raise ValueError(f"retained ledger mismatch: {case['id']}")
            if bounded_value(prefinish["operationPeak"]) != operation_peak:
                raise ValueError(f"operation ledger mismatch: {case['id']}")
            state_bytes = int(report["statePlan"]["totalStateBytes"])
            output_bytes = int(report["finalRGBByteCount"])
            if schema_version >= 6:
                persistent = int(report["persistentStateByteCount"])
                render_scratch = int(report["renderScratchByteCount"])
                if schema_version >= 9:
                    persistent_base = int(report["persistentBaseStateByteCount"])
                    retained_huffman = int(report["retainedHuffmanTableBytesBeforeFinish"])
                    if schema_version >= 10:
                        expected_retained = output_bytes
                        if report["previewCadence"] == "final-only":
                            maximum_retained = transport + persistent
                        else:
                            maximum_retained = transport + persistent + output_bytes
                    else:
                        if report["previewCadence"] == "final-only":
                            expected_retained = transport + persistent_base + retained_huffman
                            maximum_retained = transport + persistent
                        else:
                            expected_retained = transport + persistent_base + retained_huffman + output_bytes
                            maximum_retained = transport + persistent + output_bytes
                    if int(report["maximumRetainedByteChargeBeforeFinish"]) != maximum_retained:
                        raise ValueError(f"maximum retained authority mismatch: {case['id']}")
                else:
                    if report["previewCadence"] == "final-only":
                        expected_retained = transport + persistent
                    else:
                        expected_retained = transport + persistent + output_bytes
            elif schema_version >= 5 and report["previewCadence"] == "final-only":
                expected_retained = transport + state_bytes
            else:
                expected_retained = transport + state_bytes + output_bytes
            if retained != expected_retained:
                raise ValueError(f"post-frame retained phase does not compose: {case['id']}")
            transition_peak = int(fixed["initialRetainedByteCharge"]) + (
                int(report["persistentStateByteCount"]) if schema_version >= 6 else state_bytes
            )
            if 7 <= schema_version <= 11:
                transition_peak += int(fixed["frameQuantizationSourceByteCount"])
            retained_for_peak = (
                int(report["maximumRetainedByteChargeBeforeFinish"])
                if schema_version >= 9
                else retained
            )
            entropy_peak = retained_for_peak + int(fixed["operationScratchByteCharge"])
            if schema_version >= 6:
                render_scratch = int(report["renderScratchByteCount"])
                if schema_version >= 17 and report["previewCadence"] == "final-only":
                    sample_bytes = int(report["finalSamplePlaneByteCount"])
                    sample_scratch = int(report["finalSampleMaterializationScratchByteCount"])
                    sample_materialization_peak = persistent + sample_bytes + sample_scratch
                    final_rgb_peak = sample_bytes + output_bytes
                    render_peak = max(sample_materialization_peak, final_rgb_peak)
                elif report["previewCadence"] == "final-only":
                    render_peak = retained_for_peak + output_bytes + render_scratch
                else:
                    render_peak = retained_for_peak + render_scratch
                if schema_version >= 9:
                    huffman_mutation_peak = (
                        transport
                        + int(report["persistentStateByteCount"])
                        + int(report["maximumHuffmanTablePayloadByteCount"])
                    )
                    expected_peak = max(
                        transition_peak,
                        entropy_peak,
                        render_peak,
                        huffman_mutation_peak,
                    )
                else:
                    expected_peak = max(transition_peak, entropy_peak, render_peak)
            elif schema_version >= 5 and report["previewCadence"] == "final-only":
                final_render_peak = retained + output_bytes
                expected_peak = max(transition_peak, entropy_peak, final_render_peak)
            else:
                expected_peak = max(transition_peak, entropy_peak)
            if operation_peak != expected_peak:
                raise ValueError(f"operation peak does not match phase maximum: {case['id']}")
            if schema_version >= 17:
                historical_path = profile_path.parent.parent / "v16" / case["report"]
                historical = load_json(historical_path)
                if int(historical["persistentStateByteCount"]) != int(report["persistentStateByteCount"]):
                    raise ValueError(f"v17 changed persistent state: {case['id']}")
                if int(historical["maximumRetainedByteChargeBeforeFinish"]) != int(
                    report["maximumRetainedByteChargeBeforeFinish"]
                ):
                    raise ValueError(f"v17 changed maximum retained authority: {case['id']}")
                if historical["finalRGBSHA256"] != report["finalRGBSHA256"]:
                    raise ValueError(f"v17 final-only phase split changed RGB: {case['id']}")
                historical_peak = int(historical["operationPeakByteCharge"])
                if report["previewCadence"] == "final-only":
                    if operation_peak >= historical_peak:
                        raise ValueError(f"v17 final-only phase split did not lower operation peak: {case['id']}")
                elif operation_peak != historical_peak:
                    raise ValueError(f"v17 changed every-scan operation peak: {case['id']}")
        if bounded_value(prefinish["transferredOutput"]) != report["finalRGBByteCount"]:
            raise ValueError(f"transfer ledger mismatch: {case['id']}")
        if prefinish["outputLayoutAuthority"] != "codecOwnedRGB8":
            raise ValueError(f"output authority mismatch: {case['id']}")

        if "maximumEntropyScanByteCount" in case:
            observed = int(report["source"]["maximumEntropyScanByteCount"])
            if observed != int(case["maximumEntropyScanByteCount"]):
                raise ValueError(f"maximum scan size mismatch: {case['id']}")
            if observed <= transport:
                raise ValueError(f"large-scan case no longer exceeds transport: {case['id']}")
        if "restartMarkerCount" in case:
            observed = int(report["source"]["restartMarkerCount"])
            if observed != int(case["restartMarkerCount"]):
                raise ValueError(f"restart marker count mismatch: {case['id']}")

        summary = {
            "id": case["id"],
            "sourceByteCount": report["source"]["byteCount"],
            "maximumEntropyScanByteCount": report["source"]["maximumEntropyScanByteCount"],
            "restartMarkerCount": report["source"]["restartMarkerCount"],
            "maximumObservedTransportBytes": report["maximumObservedTransportBytes"],
            "finalRGBSHA256": report["finalRGBSHA256"],
        }
        if schema_version == 1:
            summary["codecOwnedByteCharge"] = report["codecOwnedByteCharge"]
        else:
            summary["retainedByteChargeBeforeFinish"] = report["retainedByteChargeBeforeFinish"]
            summary["operationPeakByteCharge"] = report["operationPeakByteCharge"]
            summary["previewBackingWasStable"] = report["previewBackingWasStable"]
        results.append(summary)
    return {
        "schemaVersion": schema_version,
        "profileID": profile["profileID"],
        "validatedCases": results,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, default=DEFAULT_PROFILE)
    args = parser.parse_args()
    print(json.dumps(validate(args.profile), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
