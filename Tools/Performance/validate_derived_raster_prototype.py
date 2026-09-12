#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import math
import sys
from pathlib import Path
from typing import Any


def fail(message: str) -> None:
    raise SystemExit(f"derived raster prototype validation failed: {message}")


def require_int(value: Any, name: str, minimum: int = 0) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < minimum:
        fail(f"{name} must be an integer >= {minimum}")
    return value


def median(values: list[int]) -> int:
    ordered = sorted(values)
    if not ordered:
        fail("duration samples must not be empty")
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return ordered[middle - 1] // 2 + ordered[middle] // 2 + (
        ordered[middle - 1] % 2 + ordered[middle] % 2
    ) // 2


def p95(values: list[int]) -> int:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, math.ceil(len(ordered) * 0.95) - 1)]


def validate_duration(payload: Any, name: str, iterations: int) -> None:
    if not isinstance(payload, dict):
        fail(f"{name} must be an object")
    samples = payload.get("samplesNanoseconds")
    if not isinstance(samples, list) or len(samples) != iterations:
        fail(f"{name}.samplesNanoseconds must contain {iterations} values")
    values = [require_int(value, f"{name}.samplesNanoseconds") for value in samples]
    if payload.get("medianNanoseconds") != median(values):
        fail(f"{name}.medianNanoseconds does not match samples")
    if payload.get("p95Nanoseconds") != p95(values):
        fail(f"{name}.p95Nanoseconds does not match samples")


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: validate_derived_raster_prototype.py REPORT INPUT")
    report_path = Path(sys.argv[1])
    input_path = Path(sys.argv[2])
    report = json.loads(report_path.read_text())
    source = input_path.read_bytes()
    if report.get("schemaVersion") != 6:
        fail("schemaVersion must be 6")
    if report.get("evidenceVersion") != "imagecraft-target-derived-raster-prototype-v6":
        fail("unexpected evidenceVersion")
    if report.get("inputByteCount") != len(source):
        fail("inputByteCount does not match input")
    if report.get("inputSHA256") != hashlib.sha256(source).hexdigest():
        fail("inputSHA256 does not match input")
    iterations = require_int(report.get("measuredIterations"), "measuredIterations", 1)
    targets = report.get("targets")
    if not isinstance(targets, list) or len(targets) != 3:
        fail("targets must contain the fixed three W2 sizes")

    png_total = 0
    lzfse_total = 0
    adaptive_total = 0
    expected_targets = [(390, 260), (780, 520), (1170, 780)]
    for index, target in enumerate(targets):
        if not isinstance(target, dict):
            fail(f"targets[{index}] must be an object")
        requested_width, requested_height = expected_targets[index]
        if target.get("requestedWidth") != requested_width or target.get("requestedHeight") != requested_height:
            fail(f"targets[{index}] request geometry is not the fixed W2 target")
        output_width = require_int(target.get("outputWidth"), f"targets[{index}].outputWidth", 1)
        output_height = require_int(target.get("outputHeight"), f"targets[{index}].outputHeight", 1)
        if output_width > requested_width or output_height > requested_height:
            fail(f"targets[{index}] output exceeds requested target")
        if target.get("rawRGBByteCount") != output_width * output_height * 3:
            fail(f"targets[{index}] rawRGBByteCount does not match output geometry")
        direct_hash = target.get("directPixelRGBSHA256")
        if not isinstance(direct_hash, str) or len(direct_hash) != 64:
            fail(f"targets[{index}] direct hash is invalid")
        for prefix, equality_name in (
            ("derivedPNG", "pngPixelsEqual"),
            ("derivedLZFSE", "lzfsePixelsEqual"),
            ("derivedAdaptiveLZFSE", "adaptiveLZFSEPixelsEqual"),
        ):
            pixel_hash = target.get(f"{prefix}PixelRGBSHA256")
            if pixel_hash != direct_hash or target.get(equality_name) is not True:
                fail(f"targets[{index}] {prefix} pixels differ")
        png_total += require_int(
            target.get("derivedPNGByteCount"), f"targets[{index}].derivedPNGByteCount", 1
        )
        lzfse_total += require_int(
            target.get("derivedLZFSEByteCount"),
            f"targets[{index}].derivedLZFSEByteCount",
            1,
        )
        adaptive_total += require_int(
            target.get("derivedAdaptiveLZFSEByteCount"),
            f"targets[{index}].derivedAdaptiveLZFSEByteCount",
            1,
        )
        for name in (
            "directOriginalDecode",
            "cachedImageMaterialization",
            "derivedPNGDecode",
            "derivedLZFSEDecode",
            "derivedAdaptiveLZFSEDecode",
            "derivedPNGCreationDecodeAndEncode",
            "derivedLZFSECreationDecodeDrawAndCompress",
            "derivedAdaptiveLZFSECreationDecodeDrawFilterAndCompress",
        ):
            validate_duration(target.get(name), f"targets[{index}].{name}", iterations)

        direct = target["directOriginalDecode"]
        direct_median = require_int(
            direct.get("medianNanoseconds"),
            f"targets[{index}].directOriginalDecode.medianNanoseconds",
        )
        raw_bytes = require_int(target.get("rawRGBByteCount"), f"targets[{index}].rawRGBByteCount", 1)
        expected_artifacts = [
            {
                "format": "png",
                "payload_bytes": target.get("derivedPNGByteCount"),
                "payload_sha": target.get("derivedPNGSHA256"),
                "pixel_sha": target.get("derivedPNGPixelRGBSHA256"),
                "exact": target.get("pngPixelsEqual"),
                "decode": target.get("derivedPNGDecode"),
                "authority": "framework-private-logical-transient-unknown",
                "peak": None,
                "published": target.get("derivedPNGByteCount"),
                "reclaimed": 0,
            },
            {
                "format": "lzfse-rgb8",
                "payload_bytes": target.get("derivedLZFSEByteCount"),
                "payload_sha": target.get("derivedLZFSESHA256"),
                "pixel_sha": target.get("derivedLZFSEPixelRGBSHA256"),
                "exact": target.get("lzfsePixelsEqual"),
                "decode": target.get("derivedLZFSEDecode"),
                "authority": "codec-owned-logical-bytes-exact",
                "peak": raw_bytes + max(1024, raw_bytes + raw_bytes // 8 + 65536),
                "published": target.get("derivedLZFSEByteCount"),
                "reclaimed": raw_bytes,
            },
            {
                "format": "adaptive-row-filter-lzfse-rgb8",
                "payload_bytes": target.get("derivedAdaptiveLZFSEByteCount"),
                "payload_sha": target.get("derivedAdaptiveLZFSESHA256"),
                "pixel_sha": target.get("derivedAdaptiveLZFSEPixelRGBSHA256"),
                "exact": target.get("adaptiveLZFSEPixelsEqual"),
                "decode": target.get("derivedAdaptiveLZFSEDecode"),
                "authority": "codec-owned-logical-bytes-exact",
                "peak": (
                    raw_bytes
                    + (raw_bytes + output_height)
                    + max(1024, (raw_bytes + output_height) + (raw_bytes + output_height) // 8 + 65536)
                ),
                "published": target.get("derivedAdaptiveLZFSEByteCount"),
                "reclaimed": raw_bytes + (raw_bytes + output_height),
            },
        ]
        artifacts = target.get("artifactQualifications")
        if not isinstance(artifacts, list) or len(artifacts) != len(expected_artifacts):
            fail(f"targets[{index}].artifactQualifications must contain the fixed three formats")
        artifact_by_format: dict[str, dict[str, Any]] = {}
        for artifact in artifacts:
            if not isinstance(artifact, dict) or not isinstance(artifact.get("format"), str):
                fail(f"targets[{index}].artifactQualifications contains an invalid entry")
            format_name = artifact["format"]
            if format_name in artifact_by_format:
                fail(f"targets[{index}].artifactQualifications has duplicate format {format_name}")
            artifact_by_format[format_name] = artifact
        if set(artifact_by_format) != {value["format"] for value in expected_artifacts}:
            fail(f"targets[{index}].artifactQualifications format set mismatch")

        for expected in expected_artifacts:
            format_name = expected["format"]
            artifact = artifact_by_format[format_name]
            prefix = f"targets[{index}].artifactQualifications[{format_name}]"
            if artifact.get("payloadByteCount") != expected["payload_bytes"]:
                fail(f"{prefix}.payloadByteCount mismatch")
            if artifact.get("payloadSHA256") != expected["payload_sha"]:
                fail(f"{prefix}.payloadSHA256 mismatch")
            if artifact.get("pixelRGBSHA256") != expected["pixel_sha"]:
                fail(f"{prefix}.pixelRGBSHA256 mismatch")
            if artifact.get("exactPixelIdentity") is not expected["exact"]:
                fail(f"{prefix}.exactPixelIdentity mismatch")
            validate_duration(
                artifact.get("creationFromDecodedSurface"),
                f"{prefix}.creationFromDecodedSurface",
                iterations,
            )
            if artifact.get("decode") != expected["decode"]:
                fail(f"{prefix}.decode must match the legacy decode summary")
            if artifact.get("creationAccountingAuthority") != expected["authority"]:
                fail(f"{prefix}.creationAccountingAuthority mismatch")
            if artifact.get("knownCreationLogicalLiveBytePeak") != expected["peak"]:
                fail(f"{prefix}.knownCreationLogicalLiveBytePeak mismatch")
            if artifact.get("publishedPayloadByteCount") != expected["published"]:
                fail(f"{prefix}.publishedPayloadByteCount mismatch")
            if artifact.get("reclaimedLogicalTransientByteCount") != expected["reclaimed"]:
                fail(f"{prefix}.reclaimedLogicalTransientByteCount mismatch")
            creation_median = require_int(
                artifact["creationFromDecodedSurface"].get("medianNanoseconds"),
                f"{prefix}.creationFromDecodedSurface.medianNanoseconds",
            )
            decode_median = require_int(
                artifact["decode"].get("medianNanoseconds"),
                f"{prefix}.decode.medianNanoseconds",
            )
            expected_break_even = None
            if decode_median < direct_median:
                saving = direct_median - decode_median
                expected_break_even = max(1, (creation_median + saving - 1) // saving)
            if artifact.get("minimumReuseCountForLatencyBreakEven") != expected_break_even:
                fail(f"{prefix}.minimumReuseCountForLatencyBreakEven mismatch")

        storage_best = min(
            (
                require_int(artifact.get("payloadByteCount"), "payloadByteCount", 1),
                artifact["format"],
            )
            for artifact in artifacts
            if artifact.get("exactPixelIdentity") is True
        )
        if target.get("storageEfficientPayloadByteCount") != storage_best[0]:
            fail(f"targets[{index}].storageEfficientPayloadByteCount mismatch")
        if target.get("storageEfficientFormat") != storage_best[1]:
            fail(f"targets[{index}].storageEfficientFormat mismatch")

        decisions = target.get("reuseDecisions")
        if not isinstance(decisions, list) or len(decisions) != 4:
            fail(f"targets[{index}].reuseDecisions must contain 1/2/4/8 reuse decisions")
        for decision, reuse_count in zip(decisions, (1, 2, 4, 8), strict=True):
            if not isinstance(decision, dict) or decision.get("expectedReuseCount") != reuse_count:
                fail(f"targets[{index}].reuseDecisions count/order mismatch")
            direct_total = direct_median * reuse_count
            if decision.get("directOriginalMedianTotalNanoseconds") != direct_total:
                fail(f"targets[{index}].reuseDecisions[{reuse_count}] direct total mismatch")
            candidates = []
            for artifact in artifacts:
                if artifact.get("exactPixelIdentity") is not True:
                    continue
                creation = require_int(artifact["creationFromDecodedSurface"].get("medianNanoseconds"), "creation")
                decode = require_int(artifact["decode"].get("medianNanoseconds"), "decode")
                candidates.append(
                    (
                        creation + decode * reuse_count,
                        require_int(artifact.get("payloadByteCount"), "payloadByteCount", 1),
                        artifact["format"],
                    )
                )
            best_total, _, best_format = min(candidates)
            admitted = best_total <= direct_total
            if decision.get("admitted") is not admitted:
                fail(f"targets[{index}].reuseDecisions[{reuse_count}] admission mismatch")
            if decision.get("selectedFormat") != (best_format if admitted else None):
                fail(f"targets[{index}].reuseDecisions[{reuse_count}] format mismatch")
            if decision.get("selectedArtifactMedianTotalNanoseconds") != (best_total if admitted else None):
                fail(f"targets[{index}].reuseDecisions[{reuse_count}] artifact total mismatch")

    if report.get("allTargetPNGPixelsEqual") is not True:
        fail("allTargetPNGPixelsEqual must be true")
    if report.get("allTargetLZFSEPixelsEqual") is not True:
        fail("allTargetLZFSEPixelsEqual must be true")
    if report.get("allTargetAdaptiveLZFSEPixelsEqual") is not True:
        fail("allTargetAdaptiveLZFSEPixelsEqual must be true")
    totals = {
        "PNG": png_total,
        "LZFSE": lzfse_total,
        "AdaptiveLZFSE": adaptive_total,
    }
    for label, derived_bytes in totals.items():
        if report.get(f"targetSpecificDerived{label}ByteCount") != derived_bytes:
            fail(f"targetSpecificDerived{label}ByteCount does not match targets")
        total = len(source) + derived_bytes
        if report.get(f"originalPlusDerived{label}ByteCount") != total:
            fail(f"originalPlusDerived{label}ByteCount does not match")
        if report.get(f"originalPlusDerived{label}ToOriginalPermille") != (
            total * 1000 // len(source)
        ):
            fail(f"originalPlusDerived{label}ToOriginalPermille does not match")
    print(
        "validated derived raster prototype: "
        f"inputBytes={len(source)} pngBytes={png_total} "
        f"lzfseBytes={lzfse_total} adaptiveBytes={adaptive_total}"
    )


if __name__ == "__main__":
    main()
