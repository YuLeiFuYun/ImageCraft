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
    if report.get("schemaVersion") != 5:
        fail("schemaVersion must be 5")
    if report.get("evidenceVersion") != "imagecraft-target-derived-raster-prototype-v5":
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
