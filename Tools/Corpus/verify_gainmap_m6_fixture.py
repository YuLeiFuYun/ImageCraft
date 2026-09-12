#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    args = parser.parse_args()

    manifest_path = args.manifest.resolve()
    root = manifest_path.parent
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

    if manifest.get("schemaVersion") != 1:
        raise AssertionError("unsupported gain-map M6 fixture schema")
    if manifest.get("fixtureSetID") != "IMAGECRAFT-GAINMAP-M6-V1":
        raise AssertionError("unexpected gain-map M6 fixture set")

    fixtures = manifest.get("fixtures")
    if not isinstance(fixtures, list) or len(fixtures) != 1:
        raise AssertionError("gain-map M6 fixture manifest must contain exactly one fixture")

    fixture = fixtures[0]
    filename = fixture.get("file")
    if filename != "heif-iso-gainmap-sdr-hdr.heic":
        raise AssertionError(f"unexpected gain-map fixture filename: {filename}")
    path = root / filename
    if not path.is_file():
        raise AssertionError(f"missing gain-map fixture: {filename}")

    byte_count = fixture.get("byteCount")
    if not isinstance(byte_count, int) or byte_count <= 0:
        raise AssertionError("invalid gain-map fixture byteCount")
    if path.stat().st_size != byte_count:
        raise AssertionError(
            f"gain-map byte count mismatch; expected={byte_count} actual={path.stat().st_size}"
        )

    digest = fixture.get("sha256")
    if not isinstance(digest, str) or len(digest) != 64:
        raise AssertionError("invalid gain-map fixture SHA-256 field")
    actual_digest = sha256(path)
    if actual_digest != digest:
        raise AssertionError(
            f"gain-map SHA-256 mismatch; expected={digest} actual={actual_digest}"
        )

    for field in ("width", "height", "primaryDepth"):
        value = fixture.get(field)
        if not isinstance(value, int) or value <= 0:
            raise AssertionError(f"invalid gain-map fixture {field}")
    if fixture["primaryDepth"] != 8:
        raise AssertionError("M6 gain-map retained fixture must keep an 8-bit SDR primary")
    if fixture.get("auxiliaryType") != "kCGImageAuxiliaryDataTypeISOGainMap":
        raise AssertionError("M6 retained fixture must use the public ISO gain-map auxiliary type")

    expected_sdr = fixture.get("expectedSDR")
    expected_hdr = fixture.get("expectedHDR")
    if not isinstance(expected_sdr, dict) or expected_sdr.get("bitsPerComponent") != 8:
        raise AssertionError("invalid SDR acceptance contract")
    if expected_sdr.get("contentHeadroom") != 1.0:
        raise AssertionError("invalid SDR headroom contract")
    if not isinstance(expected_hdr, dict) or expected_hdr.get("minimumBitsPerComponent") != 9:
        raise AssertionError("invalid HDR precision contract")
    if expected_hdr.get("contentHeadroom") != 4.0:
        raise AssertionError("invalid HDR headroom contract")

    print(f"Gain-map M6 fixture manifest passed: {manifest_path}")


if __name__ == "__main__":
    main()
