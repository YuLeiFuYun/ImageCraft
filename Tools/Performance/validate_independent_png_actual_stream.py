#!/usr/bin/env python3
from __future__ import annotations

import argparse
import binascii
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
from typing import Any
import zlib

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_MANIFEST = ROOT / "Evidence/Fixtures/IndependentPNGActual/v1/manifest.json"
EVIDENCE_VERSION = "imagecraft-independent-png-actual-stream-v1"
RUN_VERSION = "imagecraft-independent-png-decode-comparison-v1"


class ValidationError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise ValidationError(message)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def require_positive_int(value: Any, label: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        fail(f"{label} must be a positive integer")
    return value


def inspect_png(path: Path) -> dict[str, Any]:
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        fail(f"invalid PNG signature: {path}")
    pos = 8
    ihdr: bytes | None = None
    idat_parts: list[bytes] = []
    chunk_types: list[str] = []
    idat_closed = False
    while pos + 12 <= len(data):
        length = int.from_bytes(data[pos : pos + 4], "big")
        kind_bytes = data[pos + 4 : pos + 8]
        payload_start = pos + 8
        payload_end = payload_start + length
        crc_end = payload_end + 4
        if crc_end > len(data):
            fail(f"truncated chunk: {path}")
        payload = data[payload_start:payload_end]
        stored_crc = int.from_bytes(data[payload_end:crc_end], "big")
        if (binascii.crc32(kind_bytes + payload) & 0xFFFFFFFF) != stored_crc:
            fail(f"CRC mismatch: {path}")
        kind = kind_bytes.decode("ascii", "strict")
        if kind == "IHDR":
            if ihdr is not None:
                fail(f"duplicate IHDR: {path}")
            ihdr = payload
        if kind == "IDAT":
            if idat_closed:
                fail(f"non-contiguous IDAT: {path}")
            idat_parts.append(payload)
        elif idat_parts:
            idat_closed = True
        chunk_types.append(kind)
        pos = crc_end
        if kind == "IEND":
            break
    if pos != len(data) or not chunk_types or chunk_types[-1] != "IEND":
        fail(f"trailing/truncated PNG structure: {path}")
    if ihdr is None or len(ihdr) != 13 or not idat_parts:
        fail(f"missing IHDR/IDAT: {path}")
    width, height, bit_depth, color_type, compression, filtering, interlace = struct.unpack(
        ">IIBBBBB", ihdr
    )
    if (compression, filtering, interlace) != (0, 0, 0) or bit_depth != 8:
        fail(f"validator supports only qualified non-interlaced 8-bit actual fixtures: {path}")
    channels = {0: 1, 2: 3, 4: 2, 6: 4}.get(color_type)
    if channels is None:
        fail(f"unsupported color type in actual fixture: {color_type}")
    compressed = b"".join(idat_parts)
    inflated = zlib.decompress(compressed)
    row_bytes = width * channels
    if len(inflated) != height * (row_bytes + 1):
        fail(f"inflated geometry mismatch: {path}")
    histogram = {str(i): 0 for i in range(5)}
    for row in range(height):
        value = inflated[row * (row_bytes + 1)]
        if value not in range(5):
            fail(f"invalid PNG filter {value}: {path}")
        histogram[str(value)] += 1
    return {
        "byteCount": len(data),
        "sha256": sha256(data),
        "width": width,
        "height": height,
        "bitDepth": bit_depth,
        "colorType": color_type,
        "interlaceMethod": interlace,
        "idatChunkCount": len(idat_parts),
        "compressedIDATByteCount": len(compressed),
        "compressedIDATSHA256": sha256(compressed),
        "inflatedScanlineByteCount": len(inflated),
        "filterHistogram": histogram,
        "chunkTypes": chunk_types,
    }


def current_source_identity() -> dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix="imagecraft-actual-png-validate-") as temp_dir:
        output = Path(temp_dir) / "identity.json"
        completed = subprocess.run(
            [sys.executable, str(ROOT / "Tools/Identity/capture_source_identity.py"), "--output", str(output)],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
            timeout=180,
        )
        if completed.returncode != 0:
            fail(f"source identity capture failed: {completed.stderr}")
        return json.loads(output.read_text())


def validate_run(run: dict[str, Any], case: dict[str, Any], operation_budget: int, iterations: int) -> None:
    if run.get("evidenceVersion") != RUN_VERSION or run.get("schemaVersion") != 1:
        fail("raw run version mismatch")
    if run.get("exactPackedOutputMatch") is not True:
        fail("raw run lost exact packed cross-backend equality")
    for key in ("inputByteCount", "inputSHA256", "pixelWidth", "pixelHeight", "requestColorPolicy"):
        expected = {
            "inputByteCount": case["byteCount"],
            "inputSHA256": case["sha256"],
            "pixelWidth": case["width"],
            "pixelHeight": case["height"],
            "requestColorPolicy": case["requestColorPolicy"],
        }[key]
        if run.get(key) != expected:
            fail(f"raw run {key} mismatch")
    if run.get("independentOperationBudgetBytes") != operation_budget:
        fail("raw run operation budget mismatch")
    bound = require_positive_int(run.get("independentOperationByteChargeUpperBound"), "operation bound")
    if bound > operation_budget:
        fail("raw run exceeds operation budget")
    for implementation in ("independent", "imageIO"):
        section = run.get(implementation)
        if not isinstance(section, dict):
            fail(f"missing {implementation} timing section")
        samples = section.get("samplesNanoseconds")
        if not isinstance(samples, list) or len(samples) != iterations or any(
            not isinstance(value, int) or value <= 0 for value in samples
        ):
            fail(f"invalid {implementation} samples")
        duration = section.get("duration")
        if not isinstance(duration, dict) or duration.get("medianNanoseconds") != sorted(samples)[len(samples) // 2]:
            fail(f"{implementation} median does not match samples")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("report", type=Path)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    args = parser.parse_args()
    report = json.loads(args.report.read_text())
    manifest = json.loads(args.manifest.read_text())
    if report.get("schemaVersion") != 1 or report.get("evidenceVersion") != EVIDENCE_VERSION:
        fail("unexpected actual-stream report version")
    for key, expected in (
        ("formalSourceBoundExecution", True),
        ("actualExternalStreamBytes", True),
        ("performanceThresholdClaimed", False),
        ("defaultBackendQualificationClaimed", False),
    ):
        if report.get(key) is not expected:
            fail(f"report claim boundary mismatch: {key}")
    manifest_info = report.get("manifest")
    if not isinstance(manifest_info, dict):
        fail("missing report manifest identity")
    if manifest_info.get("sha256") != sha256(args.manifest.read_bytes()):
        fail("manifest SHA mismatch")
    if manifest_info.get("fixtureSetID") != manifest.get("fixtureSetID"):
        fail("fixture set ID mismatch")
    if report.get("claimBoundary") != manifest.get("claimBoundary"):
        fail("claim boundary drift")
    operation_budget = require_positive_int(manifest.get("operationBudgetBytes"), "manifest operation budget")
    if report.get("operationBudgetBytes") != operation_budget:
        fail("report operation budget mismatch")

    manifest_cases = manifest.get("cases")
    report_cases = report.get("cases")
    if not isinstance(manifest_cases, list) or not isinstance(report_cases, list):
        fail("missing case arrays")
    if len(manifest_cases) != len(report_cases) or not manifest_cases:
        fail("case count mismatch")
    report_by_id = {case.get("id"): case for case in report_cases if isinstance(case, dict)}
    if len(report_by_id) != len(report_cases):
        fail("duplicate/invalid report case IDs")
    for case in manifest_cases:
        case_id = case.get("id")
        actual = report_by_id.get(case_id)
        if not isinstance(case_id, str) or not isinstance(actual, dict):
            fail("missing actual-stream report case")
        if case.get("repositoryCopyModified") is not False:
            fail(f"{case_id}: repository copy must be unchanged")
        if case.get("licenseStatus") != "public-domain-US-NASA":
            fail(f"{case_id}: unexpected license status")
        fixture = args.manifest.parent / case["path"]
        stream = inspect_png(fixture)
        for key in (
            "byteCount", "sha256", "width", "height", "bitDepth", "colorType",
            "interlaceMethod", "idatChunkCount", "compressedIDATByteCount",
        ):
            if stream[key] != case.get(key):
                fail(f"{case_id}: manifest fixture {key} mismatch")
        if actual.get("stream") != stream:
            fail(f"{case_id}: report stream facts mismatch")
        source = actual.get("source")
        if not isinstance(source, dict) or source.get("repositoryCopyModified") is not False:
            fail(f"{case_id}: report source provenance mismatch")
        process_count = require_positive_int(actual.get("processCount"), f"{case_id} processCount")
        iterations = require_positive_int(
            actual.get("iterationsPerImplementationPerProcess"), f"{case_id} iterations"
        )
        raw_runs = actual.get("rawRuns")
        if not isinstance(raw_runs, list) or len(raw_runs) != process_count:
            fail(f"{case_id}: raw run count mismatch")
        for raw in raw_runs:
            if not isinstance(raw, dict):
                fail(f"{case_id}: invalid raw run")
            validate_run(raw, case, operation_budget, iterations)
        independent_medians = [raw["independent"]["duration"]["medianNanoseconds"] for raw in raw_runs]
        imageio_medians = [raw["imageIO"]["duration"]["medianNanoseconds"] for raw in raw_runs]
        ratios = [raw["independentToImageIOMedianRatio"] for raw in raw_runs]
        if actual.get("independentProcessMediansNanoseconds") != independent_medians:
            fail(f"{case_id}: independent median vector mismatch")
        if actual.get("imageIOProcessMediansNanoseconds") != imageio_medians:
            fail(f"{case_id}: ImageIO median vector mismatch")
        if actual.get("independentToImageIOProcessMedianRatios") != ratios:
            fail(f"{case_id}: ratio vector mismatch")
        for raw in raw_runs[1:]:
            for key in (
                "inputByteCount", "inputSHA256", "requestColorPolicy", "pixelWidth", "pixelHeight",
                "outputByteCount", "outputSHA256", "independentOperationByteChargeUpperBound",
                "imageIODecoderFingerprint",
            ):
                if raw.get(key) != raw_runs[0].get(key):
                    fail(f"{case_id}: process invariant drift: {key}")

    identity = current_source_identity()
    recorded_identity = report.get("sourceIdentity")
    if not isinstance(recorded_identity, dict) or recorded_identity.get("stableBeforeAfter") is not True:
        fail("missing stable source identity witness")
    if recorded_identity.get("fileCount") != identity.get("fileCount") or recorded_identity.get(
        "sourceIdentitySHA256"
    ) != identity.get("sourceIdentitySHA256"):
        fail("report is stale for the current source identity")
    print(
        f"PASS cases={len(report_cases)} source={identity['sourceIdentitySHA256'][:12]} "
        f"files={identity['fileCount']}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValidationError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
