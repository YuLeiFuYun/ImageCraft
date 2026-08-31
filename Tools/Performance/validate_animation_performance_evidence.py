#!/usr/bin/env python3
import hashlib
import json
import math
import pathlib
import sys
from collections import Counter

EXPECTED_CONTAINERS = {"gif", "apng", "jpegSequence"}
TIMING_FIELDS = [
    "imageCraftPrepare",
    "directImageIOPrepareLowerBound",
    "imageCraftSelectedFrame",
    "directImageIOColdSelectedFrame",
    "directImageIORetainedSourceSelectedFrame",
    "imageCraftSequentialAllFrames",
    "directImageIORetainedSourceAllFrames",
    "directImageIOUnboundedCachedAllFrames",
]


def fail(message: str) -> None:
    raise SystemExit(message)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def input_identity(path: pathlib.Path, container: str) -> tuple[int, str]:
    if container != "jpegSequence":
        data = path.read_bytes()
        return len(data), sha256(data)
    files = sorted(
        p for p in path.iterdir() if p.is_file() and p.suffix.lower() in {".jpg", ".jpeg"}
    )
    if not files:
        fail(f"JPEG sequence directory is empty: {path}")
    canonical = bytearray()
    total = 0
    for file in files:
        data = file.read_bytes()
        total += len(data)
        canonical.extend(len(data).to_bytes(8, "big"))
        canonical.extend(data)
    return total, sha256(bytes(canonical))


def percentile95(samples: list[int]) -> int:
    ordered = sorted(samples)
    return ordered[min(len(ordered) - 1, math.ceil(len(ordered) * 0.95) - 1)]


def validate_report(path: pathlib.Path) -> dict:
    report = json.loads(path.read_text())
    if report.get("schemaVersion") != 3:
        fail(f"{path}: expected schemaVersion 3")
    container = report.get("container")
    if container not in EXPECTED_CONTAINERS:
        fail(f"{path}: unexpected container {container!r}")
    if report.get("frameCount") != 24 or report.get("frameDecodeWindowSize") != 8:
        fail(f"{path}: expected 24 frames and window 8")
    if (report.get("targetWidth"), report.get("targetHeight")) != (256, 256):
        fail(f"{path}: expected 256x256 target")
    if report.get("selectedFrameIndex") != 12:
        fail(f"{path}: expected selected frame 12")
    if report.get("selectedFramePixelSHA256") != report.get("directFramePixelSHA256"):
        fail(f"{path}: selected frame pixels differ")

    input_path = pathlib.Path(report["inputPath"])
    byte_count, digest = input_identity(input_path, container)
    if report.get("inputByteCount") != byte_count or report.get("inputSHA256") != digest:
        fail(f"{path}: input identity mismatch")

    sample_count = None
    for field in TIMING_FIELDS:
        timing = report.get(field, {})
        samples = timing.get("samplesNanoseconds")
        if not isinstance(samples, list) or not samples or any(
            not isinstance(value, int) or value <= 0 for value in samples
        ):
            fail(f"{path}: invalid samples for {field}")
        sample_count = sample_count or len(samples)
        if len(samples) != sample_count:
            fail(f"{path}: inconsistent sample counts")
        ordered = sorted(samples)
        if timing.get("medianNanoseconds") != ordered[len(ordered) // 2]:
            fail(f"{path}: median mismatch for {field}")
        if timing.get("p95Nanoseconds") != percentile95(samples):
            fail(f"{path}: p95 mismatch for {field}")
    if sample_count != 18:
        fail(f"{path}: expected 18 retained samples")

    orders = report.get("measurementOrders", {})
    if Counter(orders.get("preparation", [])) != Counter(
        {"imagecraft>direct-imageio": 9, "direct-imageio>imagecraft": 9}
    ):
        fail(f"{path}: unbalanced preparation order")
    if Counter(orders.get("sequentialFrames", [])) != Counter(
        {"imagecraft-windowed>direct-retained": 9, "direct-retained>imagecraft-windowed": 9}
    ):
        fail(f"{path}: unbalanced sequential order")
    expected_selected = Counter(
        {
            "imagecraft>direct-cold>direct-retained": 6,
            "direct-cold>direct-retained>imagecraft": 6,
            "direct-retained>imagecraft>direct-cold": 6,
        }
    )
    if Counter(orders.get("selectedFrame", [])) != expected_selected:
        fail(f"{path}: unbalanced selected-frame order")

    def ratio(numerator: str, denominator: str) -> float:
        return report[numerator]["medianNanoseconds"] / report[denominator]["medianNanoseconds"]

    return {
        "container": container,
        "prepareRatio": ratio("imageCraftPrepare", "directImageIOPrepareLowerBound"),
        "selectedFrameRatio": ratio(
            "imageCraftSelectedFrame", "directImageIORetainedSourceSelectedFrame"
        ),
        "sequentialRatio": ratio(
            "imageCraftSequentialAllFrames", "directImageIORetainedSourceAllFrames"
        ),
    }


def main() -> None:
    if len(sys.argv) != 4:
        fail("usage: validate_animation_performance_evidence.py GIF.json APNG.json JPEG.json")
    results = [validate_report(pathlib.Path(value)) for value in sys.argv[1:]]
    if {result["container"] for result in results} != EXPECTED_CONTAINERS:
        fail("reports must cover gif, apng, and jpegSequence exactly once")
    for result in sorted(results, key=lambda value: value["container"]):
        print(
            f"{result['container']}: prepare={result['prepareRatio']:.3f}x "
            f"frame={result['selectedFrameRatio']:.3f}x "
            f"sequence={result['sequentialRatio']:.3f}x"
        )


if __name__ == "__main__":
    main()
