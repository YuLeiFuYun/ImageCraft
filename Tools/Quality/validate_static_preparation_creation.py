#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_PROFILE = ROOT / "Evidence/Experiments/StaticPreparationCreation/v1/profile.json"


def load_json(path: Path) -> dict:
    return json.loads(path.read_text())


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def bounded_value(bound: dict) -> int:
    value = bound.get("bounded")
    if not isinstance(value, dict) or "_0" not in value:
        raise ValueError(f"expected bounded resource value, got {bound!r}")
    return int(value["_0"])


def unknown_reason(bound: dict) -> str:
    value = bound.get("unknown")
    if not isinstance(value, dict) or "_0" not in value:
        raise ValueError(f"expected unknown resource value, got {bound!r}")
    return str(value["_0"])


def jpeg_metadata_byte_count(path: Path) -> int:
    data = path.read_bytes()
    if len(data) < 4 or data[:2] != b"\xff\xd8":
        raise ValueError("expected JPEG SOI")
    offset = 2
    metadata = 0
    while offset < len(data):
        if data[offset] != 0xFF:
            raise ValueError(f"expected JPEG marker at {offset}")
        while offset < len(data) and data[offset] == 0xFF:
            offset += 1
        if offset >= len(data):
            raise ValueError("unterminated JPEG marker")
        marker = data[offset]
        offset += 1
        if marker == 0xD9:
            break
        if marker == 0xD8 or marker == 0x01 or 0xD0 <= marker <= 0xD7:
            continue
        if offset + 2 > len(data):
            raise ValueError("truncated JPEG segment length")
        length = int.from_bytes(data[offset : offset + 2], "big")
        if length < 2:
            raise ValueError("invalid JPEG segment length")
        payload_start = offset + 2
        payload_end = offset + length
        if payload_end > len(data):
            raise ValueError("truncated JPEG segment payload")
        if 0xE0 <= marker <= 0xEF or marker == 0xFE:
            metadata += payload_end - payload_start
        if marker != 0xDA:
            offset = payload_end
            continue

        cursor = payload_end
        while cursor < len(data):
            if data[cursor] != 0xFF:
                cursor += 1
                continue
            code_offset = cursor + 1
            while code_offset < len(data) and data[code_offset] == 0xFF:
                code_offset += 1
            if code_offset >= len(data):
                raise ValueError("unterminated entropy marker")
            code = data[code_offset]
            if code == 0x00 or 0xD0 <= code <= 0xD7:
                cursor = code_offset + 1
                continue
            offset = cursor
            break
        else:
            raise ValueError("JPEG scan missing following marker")
    return metadata


def validate(profile_path: Path) -> dict:
    profile_path = profile_path.resolve()
    profile = load_json(profile_path)
    if int(profile.get("schemaVersion", 0)) != 1:
        raise ValueError("unsupported static preparation-creation profile schema")
    case = profile["case"]
    source = ROOT / case["input"]
    if sha256(source) != case["inputSHA256"]:
        raise ValueError("source hash drift")
    source_bytes = source.stat().st_size
    report = load_json(profile_path.parent / case["report"])
    if int(report["schemaVersion"]) != 1:
        raise ValueError("report schema drift")
    if report["evidenceVersion"] != "imagecraft-static-preparation-creation-v1":
        raise ValueError("evidence version drift")
    if report["source"]["sha256"] != case["inputSHA256"]:
        raise ValueError("report source hash mismatch")
    if int(report["source"]["byteCount"]) != source_bytes:
        raise ValueError("report source byte count mismatch")
    if not report["preflightStoreUnchanged"]:
        raise ValueError("static preflight mutated prepared-store state")

    authority = report["authority"]
    operation = authority["operationResourceLedger"]
    if operation["isTerminal"]:
        raise ValueError("static creation operation ledger is terminal")
    if int(operation["retainedKnownBytes"]) != 0:
        raise ValueError("caller-owned static input was charged as codec-retained state")
    if bounded_value(operation["retainedBetweenCalls"]) != 0:
        raise ValueError("static creation call boundary retained bound is non-zero")
    if unknown_reason(operation["operationPeak"]) != "frameworkPrivateOperationAllocation":
        raise ValueError("static ImageIO creation falsely became operation-bounded")
    if bounded_value(operation["transferredOutput"]) != 0:
        raise ValueError("decoder-retained preparation was mislabeled as caller transfer")
    if operation["outputLayoutAuthority"] != "none":
        raise ValueError("static preparation creation unexpectedly published pixel layout")

    if int(authority["resultingPreparationRetainedKnownBytes"]) != source_bytes:
        raise ValueError("profile-absent static preparation retained known bytes drifted")
    if bounded_value(authority["resultingPreparationRetainedBetweenCalls"]) != source_bytes:
        raise ValueError("profile-absent static preparation retained bound drifted")
    if not report["postTokenRetainedMatchesPreflightResult"]:
        raise ValueError("post-token retained authority differs from static preflight")

    prepared = report["postTokenResourceLedger"]
    if int(prepared["retainedKnownBytes"]) != source_bytes:
        raise ValueError("prepared token retained known bytes drifted")
    if bounded_value(prepared["retainedBetweenCalls"]) != source_bytes:
        raise ValueError("prepared token retained bound drifted")
    if unknown_reason(prepared["operationPeak"]) != "frameworkPrivateOperationAllocation":
        raise ValueError("prepared decode operation unknown reason drifted")
    if unknown_reason(prepared["transferredOutput"]) != "frameworkChosenOutputLayout":
        raise ValueError("prepared output-layout unknown reason drifted")
    if prepared["outputLayoutAuthority"] != "frameworkChosen":
        raise ValueError("prepared output layout authority drifted")
    if not report["postDiscardPreparationLedgerAbsent"]:
        raise ValueError("discard did not reclaim static preparation token")

    probe = report["preparedProbe"]
    expected = case["probe"]
    for key in ("pixelWidth", "pixelHeight", "frameCount", "orientation", "auxiliaryAttachmentCount"):
        if int(probe[key]) != int(expected[key]):
            raise ValueError(f"prepared probe {key} drifted")
    if probe["format"] != "jpeg":
        raise ValueError("prepared probe format drifted")
    if probe["sourceColorProfile"] != "absent":
        raise ValueError("prepared probe source profile drifted")

    encoded_metadata = jpeg_metadata_byte_count(source)
    if encoded_metadata != int(case["encodedMetadataByteCount"]):
        raise ValueError("independent JPEG metadata count drifted")
    imageio_metadata = int(probe["metadataByteCount"])
    if not imageio_metadata > encoded_metadata:
        raise ValueError(
            "current ImageIO property-derived metadata no longer exceeds container metadata; "
            "re-evaluate the pure-JPEG preparation fast-path hypothesis"
        )

    return {
        "sourceByteCount": source_bytes,
        "operationUnknownReason": unknown_reason(operation["operationPeak"]),
        "resultingPreparationRetainedKnownBytes": source_bytes,
        "encodedMetadataByteCount": encoded_metadata,
        "imageIOProbeMetadataByteCount": imageio_metadata,
        "pureProbeSubstitutionCurrentlyFalsified": True,
        "postDiscardPreparationLedgerAbsent": True,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, default=DEFAULT_PROFILE)
    args = parser.parse_args()
    print(json.dumps(validate(args.profile), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
