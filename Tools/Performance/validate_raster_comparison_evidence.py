#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import math
import sys
from pathlib import Path
from typing import Any


def fail(message: str) -> None:
    raise SystemExit(f"raster comparison validation failed: {message}")


def median(values: list[int]) -> int:
    ordered = sorted(values)
    if not ordered:
        return 0
    middle = len(ordered) // 2
    if len(ordered) % 2 == 0:
        return (ordered[middle - 1] + ordered[middle]) // 2
    return ordered[middle]


def percentile95(values: list[int]) -> int:
    ordered = sorted(values)
    if not ordered:
        return 0
    index = min(len(ordered) - 1, math.ceil(len(ordered) * 0.95) - 1)
    return ordered[index]


def require_int(value: Any, name: str, minimum: int = 0) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < minimum:
        fail(f"{name} must be an integer >= {minimum}")
    return value


def validate_path(name: str, payload: dict[str, Any], iterations: int) -> set[str]:
    samples = payload.get("samples")
    summary = payload.get("summary")
    if not isinstance(samples, list) or len(samples) != iterations:
        fail(f"{name}.samples must contain exactly {iterations} entries")
    if not isinstance(summary, dict):
        fail(f"{name}.summary is missing")

    hashes: set[str] = set()
    widths: set[int] = set()
    heights: set[int] = set()
    final_updates: list[int] = []
    finalizations: list[int] = []
    rasters: list[int] = []
    post_processing: list[int] = []
    totals: list[int] = []

    for index, sample in enumerate(samples):
        if not isinstance(sample, dict):
            fail(f"{name}.samples[{index}] must be an object")
        final_update = require_int(
            sample.get("finalSourceUpdateNanoseconds"),
            f"{name}.samples[{index}].finalSourceUpdateNanoseconds",
        )
        finalization = sample.get("preparationFinalizationNanoseconds")
        if finalization is not None:
            finalizations.append(
                require_int(
                    finalization,
                    f"{name}.samples[{index}].preparationFinalizationNanoseconds",
                )
            )
        raster = require_int(
            sample.get("rasterCreationNanoseconds"),
            f"{name}.samples[{index}].rasterCreationNanoseconds",
        )
        post = require_int(
            sample.get("postProcessingNanoseconds"),
            f"{name}.samples[{index}].postProcessingNanoseconds",
        )
        total = require_int(
            sample.get("totalAfterLastChunkNanoseconds"),
            f"{name}.samples[{index}].totalAfterLastChunkNanoseconds",
        )
        if total < max(final_update, finalization or 0, raster, post):
            fail(f"{name}.samples[{index}] has a component larger than total duration")

        pixel_hash = sample.get("pixelRGBSHA256")
        if not isinstance(pixel_hash, str) or len(pixel_hash) != 64:
            fail(f"{name}.samples[{index}].pixelRGBSHA256 is invalid")
        hashes.add(pixel_hash)
        widths.add(require_int(sample.get("pixelWidth"), f"{name}.samples[{index}].pixelWidth", 1))
        heights.add(require_int(sample.get("pixelHeight"), f"{name}.samples[{index}].pixelHeight", 1))
        final_updates.append(final_update)
        rasters.append(raster)
        post_processing.append(post)
        totals.append(total)

    if len(hashes) != 1 or len(widths) != 1 or len(heights) != 1:
        fail(f"{name} output identity or dimensions changed across iterations")

    expected = {
        "medianFinalSourceUpdateNanoseconds": median(final_updates),
        "medianPreparationFinalizationNanoseconds": (
            median(finalizations) if finalizations else None
        ),
        "medianRasterCreationNanoseconds": median(rasters),
        "medianPostProcessingNanoseconds": median(post_processing),
        "medianTotalAfterLastChunkNanoseconds": median(totals),
        "p95TotalAfterLastChunkNanoseconds": percentile95(totals),
    }
    for key, expected_value in expected.items():
        if summary.get(key) != expected_value:
            fail(f"{name}.summary.{key} does not match raw samples")
    return hashes


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: validate_raster_comparison_evidence.py REPORT INPUT_JPEG")
    report_path = Path(sys.argv[1])
    input_path = Path(sys.argv[2])
    report = json.loads(report_path.read_text())
    if report.get("schemaVersion") != 2:
        fail("schemaVersion must be 2")
    if report.get("evidenceVersion") != "imagecraft-raster-comparison-v2":
        fail("unexpected evidenceVersion")
    if report.get("measurementOrder") != "alternating-apple-first-imagecraft-first":
        fail("measurement order is not alternating")

    source = input_path.read_bytes()
    if report.get("inputByteCount") != len(source):
        fail("inputByteCount does not match source")
    if report.get("inputSHA256") != hashlib.sha256(source).hexdigest():
        fail("inputSHA256 does not match source")

    iterations = require_int(report.get("measuredIterations"), "measuredIterations", 1)
    apple_first = require_int(
        report.get("appleFirstMeasuredIterations"), "appleFirstMeasuredIterations"
    )
    imagecraft_first = require_int(
        report.get("imageCraftFirstMeasuredIterations"),
        "imageCraftFirstMeasuredIterations",
    )
    if apple_first + imagecraft_first != iterations or abs(apple_first - imagecraft_first) > 1:
        fail("measured order counts are not balanced")

    apple_hashes = validate_path("apple", report.get("apple", {}), iterations)
    imagecraft_hashes = validate_path(
        "imageCraft", report.get("imageCraft", {}), iterations
    )
    if report.get("outputPixelsEqualAcrossPaths") is not True:
        fail("outputPixelsEqualAcrossPaths must be true")
    if apple_hashes != imagecraft_hashes:
        fail("Apple and ImageCraft pixel hashes differ")

    print(
        "validated raster comparison: "
        f"iterations={iterations}, inputBytes={len(source)}, pixelSHA256={next(iter(apple_hashes))}"
    )


if __name__ == "__main__":
    main()
