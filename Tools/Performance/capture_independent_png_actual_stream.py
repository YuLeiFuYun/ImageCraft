#!/usr/bin/env python3
from __future__ import annotations

import argparse
import binascii
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import struct
import subprocess
import sys
import tempfile
from typing import Any
import zlib

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_MANIFEST = ROOT / "Evidence/Fixtures/IndependentPNGActual/v1/manifest.json"
DEFAULT_OUTPUT = ROOT / ".artifacts/performance/independent-png-actual-stream-v1/formal-report.json"
EVIDENCE_VERSION = "imagecraft-independent-png-actual-stream-v1"
RUN_VERSION = "imagecraft-independent-png-decode-comparison-v1"


class CaptureError(RuntimeError):
    pass


def run(argv: list[str], *, env: dict[str, str] | None = None, timeout: int = 900) -> str:
    completed = subprocess.run(
        argv,
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )
    if completed.returncode != 0:
        raise CaptureError(
            f"command failed ({completed.returncode}): {' '.join(argv)}\n"
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )
    return completed.stdout


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def capture_source_identity(path: Path) -> dict[str, Any]:
    run([sys.executable, str(ROOT / "Tools/Identity/capture_source_identity.py"), "--output", str(path)])
    return json.loads(path.read_text())


def build_release(scratch: Path) -> tuple[Path, dict[str, str], dict[str, str]]:
    developer_dir = run([str(ROOT / "scripts/select-xcode.sh")]).strip()
    env = dict(os.environ)
    env["DEVELOPER_DIR"] = developer_dir
    run([sys.executable, str(ROOT / "scripts/check-swift-toolchain.py")], env=env)
    run(
        [
            "swift", "build", "-c", "release", "--scratch-path", str(scratch),
            "--product", "ImageCraftEvidence", "--jobs", "1",
        ],
        env=env,
    )
    bin_dir = Path(
        run(
            ["swift", "build", "-c", "release", "--scratch-path", str(scratch), "--show-bin-path"],
            env=env,
        ).strip()
    )
    binary = bin_dir / "ImageCraftEvidence"
    if not binary.is_file():
        raise CaptureError(f"missing evidence binary: {binary}")
    return binary, env, {"DEVELOPER_DIR": developer_dir}


def parse_png(path: Path) -> dict[str, Any]:
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise CaptureError(f"not a PNG: {path}")
    offset = 8
    chunks: list[tuple[str, bytes]] = []
    idat = bytearray()
    seen_idat = False
    idat_finished = False
    while offset + 12 <= len(data):
        length = int.from_bytes(data[offset : offset + 4], "big")
        kind_bytes = data[offset + 4 : offset + 8]
        payload_start = offset + 8
        payload_end = payload_start + length
        crc_end = payload_end + 4
        if crc_end > len(data):
            raise CaptureError(f"truncated PNG chunk in {path}")
        payload = data[payload_start:payload_end]
        expected_crc = int.from_bytes(data[payload_end:crc_end], "big")
        actual_crc = binascii.crc32(kind_bytes + payload) & 0xFFFFFFFF
        if actual_crc != expected_crc:
            raise CaptureError(f"CRC mismatch in {path}")
        kind = kind_bytes.decode("ascii", "strict")
        if kind == "IDAT":
            if idat_finished:
                raise CaptureError(f"non-contiguous IDAT run in {path}")
            seen_idat = True
            idat.extend(payload)
        elif seen_idat:
            idat_finished = True
        chunks.append((kind, payload))
        offset = crc_end
        if kind == "IEND":
            break
    if offset != len(data) or not chunks or chunks[-1][0] != "IEND":
        raise CaptureError(f"PNG does not end exactly at IEND: {path}")
    ihdr = next((payload for kind, payload in chunks if kind == "IHDR"), None)
    if ihdr is None or len(ihdr) != 13:
        raise CaptureError(f"missing/invalid IHDR: {path}")
    width, height, bit_depth, color_type, compression, filtering, interlace = struct.unpack(
        ">IIBBBBB", ihdr
    )
    if compression != 0 or filtering != 0:
        raise CaptureError(f"unsupported PNG method in evidence parser: {path}")
    channels = {0: 1, 2: 3, 4: 2, 6: 4}.get(color_type)
    if channels is None or bit_depth != 8 or interlace != 0:
        raise CaptureError(
            f"actual-stream evidence parser currently requires non-interlaced 8-bit direct-color PNG: {path}"
        )
    inflated = zlib.decompress(bytes(idat))
    row_bytes = width * channels
    expected_inflated = height * (row_bytes + 1)
    if len(inflated) != expected_inflated:
        raise CaptureError(f"inflated byte count mismatch in {path}")
    histogram = {str(value): 0 for value in range(5)}
    for row in range(height):
        filter_value = inflated[row * (row_bytes + 1)]
        if filter_value not in range(5):
            raise CaptureError(f"invalid filter byte {filter_value} in {path}")
        histogram[str(filter_value)] += 1
    return {
        "byteCount": len(data),
        "sha256": sha256_bytes(data),
        "width": width,
        "height": height,
        "bitDepth": bit_depth,
        "colorType": color_type,
        "interlaceMethod": interlace,
        "idatChunkCount": sum(1 for kind, _ in chunks if kind == "IDAT"),
        "compressedIDATByteCount": len(idat),
        "compressedIDATSHA256": sha256_bytes(bytes(idat)),
        "inflatedScanlineByteCount": len(inflated),
        "filterHistogram": histogram,
        "chunkTypes": [kind for kind, _ in chunks],
    }


def parse_run(
    binary: Path,
    fixture: Path,
    case: dict[str, Any],
    operation_budget: int,
    iterations: int,
    env: dict[str, str],
    expected_binary_sha256: str,
) -> dict[str, Any]:
    if sha256_file(binary) != expected_binary_sha256:
        raise CaptureError("evidence binary drifted before run")
    raw = run(
        [
            str(binary), "--independent-png-decode-comparison", str(fixture),
            "--width", str(case["width"]), "--height", str(case["height"]),
            "--operation-budget", str(operation_budget), "--iterations", str(iterations),
            "--color-policy", case["requestColorPolicy"],
        ],
        env=env,
        timeout=180,
    )
    if sha256_file(binary) != expected_binary_sha256:
        raise CaptureError("evidence binary drifted during run")
    report = json.loads(raw)
    if report.get("evidenceVersion") != RUN_VERSION:
        raise CaptureError("raw evidence version drifted")
    if report.get("requestColorPolicy") != case["requestColorPolicy"]:
        raise CaptureError("raw evidence color policy drifted")
    if report.get("inputSHA256") != case["sha256"] or report.get("inputByteCount") != case["byteCount"]:
        raise CaptureError("raw evidence input identity drifted")
    if report.get("pixelWidth") != case["width"] or report.get("pixelHeight") != case["height"]:
        raise CaptureError("raw evidence dimensions drifted")
    if report.get("exactPackedOutputMatch") is not True:
        raise CaptureError("independent/ImageIO packed output mismatch")
    if report.get("independentOperationBudgetBytes") != operation_budget:
        raise CaptureError("raw evidence operation budget drifted")
    for implementation in ("independent", "imageIO"):
        samples = report.get(implementation, {}).get("samplesNanoseconds")
        if not isinstance(samples, list) or len(samples) != iterations or any(
            not isinstance(value, int) or value <= 0 for value in samples
        ):
            raise CaptureError(f"invalid timing samples for {implementation}")
    return report


def invariant_projection(report: dict[str, Any]) -> dict[str, Any]:
    return {
        key: report[key]
        for key in (
            "runtime", "environment", "imageIODecoderFingerprint", "inputByteCount",
            "inputSHA256", "requestColorPolicy", "pixelWidth", "pixelHeight",
            "outputByteCount", "outputSHA256", "independentOperationBudgetBytes",
            "independentOperationByteChargeUpperBound",
        )
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--iterations", type=int, default=9)
    parser.add_argument("--processes", type=int, default=3)
    args = parser.parse_args()
    if not (1 <= args.iterations <= 50) or not (1 <= args.processes <= 5):
        raise CaptureError("iterations must be 1...50 and processes 1...5")

    manifest = json.loads(args.manifest.read_text())
    cases = manifest.get("cases")
    operation_budget = manifest.get("operationBudgetBytes")
    if manifest.get("schemaVersion") != 1 or not isinstance(cases, list) or not cases:
        raise CaptureError("invalid actual-stream manifest")
    if not isinstance(operation_budget, int) or operation_budget <= 0:
        raise CaptureError("manifest operationBudgetBytes must be positive")

    with tempfile.TemporaryDirectory(prefix="imagecraft-actual-png-") as temp_dir:
        temp = Path(temp_dir)
        before = capture_source_identity(temp / "source-before.json")
        binary, env, build_environment = build_release(temp / "swiftpm")
        binary_sha256 = sha256_file(binary)
        results: list[dict[str, Any]] = []
        for case in cases:
            fixture = args.manifest.parent / case["path"]
            parsed = parse_png(fixture)
            for key in (
                "byteCount", "sha256", "width", "height", "bitDepth", "colorType",
                "interlaceMethod", "idatChunkCount", "compressedIDATByteCount",
            ):
                if parsed[key] != case.get(key):
                    raise CaptureError(f"manifest drift for {case.get('id')}/{key}")
            if case.get("repositoryCopyModified") is not False:
                raise CaptureError("actual-stream fixture must declare repositoryCopyModified=false")
            reports = [
                parse_run(binary, fixture, case, operation_budget, args.iterations, env, binary_sha256)
                for _ in range(args.processes)
            ]
            reference = invariant_projection(reports[0])
            if any(invariant_projection(report) != reference for report in reports[1:]):
                raise CaptureError(f"process invariant drift for {case['id']}")
            independent_medians = [r["independent"]["duration"]["medianNanoseconds"] for r in reports]
            imageio_medians = [r["imageIO"]["duration"]["medianNanoseconds"] for r in reports]
            ratios = [r["independentToImageIOMedianRatio"] for r in reports]
            results.append(
                {
                    "id": case["id"],
                    "source": {
                        key: case[key]
                        for key in (
                            "sourcePageURL", "sourceFileURL", "sourceDescription", "sourceCreator",
                            "sourceWorkDate", "retrievedDate", "licenseStatus", "licensePageURL",
                            "sourceDerivative", "repositoryCopyModified",
                        )
                    },
                    "stream": parsed,
                    **reference,
                    "processCount": args.processes,
                    "iterationsPerImplementationPerProcess": args.iterations,
                    "independentProcessMediansNanoseconds": independent_medians,
                    "imageIOProcessMediansNanoseconds": imageio_medians,
                    "independentToImageIOProcessMedianRatios": ratios,
                    "independentMedianOfProcessMediansNanoseconds": int(statistics.median(independent_medians)),
                    "imageIOMedianOfProcessMediansNanoseconds": int(statistics.median(imageio_medians)),
                    "medianIndependentToImageIOProcessRatio": statistics.median(ratios),
                    "minimumIndependentToImageIOProcessRatio": min(ratios),
                    "maximumIndependentToImageIOProcessRatio": max(ratios),
                    "rawRuns": reports,
                }
            )
        after = capture_source_identity(temp / "source-after.json")
        if before != after:
            raise CaptureError("source identity drifted during actual-stream capture")
        report = {
            "schemaVersion": 1,
            "evidenceVersion": EVIDENCE_VERSION,
            "status": "source-bound-actual-stream-directional-performance",
            "formalSourceBoundExecution": True,
            "actualExternalStreamBytes": True,
            "performanceThresholdClaimed": False,
            "defaultBackendQualificationClaimed": False,
            "sourceIdentity": {
                "fileCount": before["fileCount"],
                "sourceIdentitySHA256": before["sourceIdentitySHA256"],
                "stableBeforeAfter": True,
            },
            "manifest": {
                "path": str(args.manifest.relative_to(ROOT)),
                "sha256": sha256_file(args.manifest),
                "fixtureSetID": manifest["fixtureSetID"],
            },
            "binary": {"sha256": binary_sha256, "builtByCapture": True, "stableAcrossRuns": True},
            "buildEnvironment": build_environment,
            "pythonVersion": platform.python_version(),
            "operationBudgetBytes": operation_budget,
            "cases": results,
            "claimBoundary": manifest["claimBoundary"],
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
