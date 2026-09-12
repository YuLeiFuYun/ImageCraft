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

    if manifest.get("schemaVersion") != 2:
        raise AssertionError("unsupported AVIF M4 fixture schema")
    if manifest.get("fixtureSetID") != "IMAGECRAFT-AVIF-M4-V1":
        raise AssertionError("unexpected AVIF M4 fixture set")

    fixtures = manifest.get("fixtures")
    if not isinstance(fixtures, list) or not fixtures:
        raise AssertionError("AVIF M4 fixture manifest has no fixtures")

    files: set[str] = set()
    for fixture in fixtures:
        filename = fixture.get("file")
        if not isinstance(filename, str) or Path(filename).name != filename:
            raise AssertionError(f"invalid AVIF fixture filename: {filename}")
        if filename in files:
            raise AssertionError(f"duplicate AVIF fixture file: {filename}")
        files.add(filename)

        path = root / filename
        if not path.is_file():
            raise AssertionError(f"missing AVIF fixture: {filename}")
        byte_count = fixture.get("byteCount")
        if not isinstance(byte_count, int) or byte_count <= 0:
            raise AssertionError(f"invalid byteCount: {filename}")
        if path.stat().st_size != byte_count:
            raise AssertionError(
                f"byte count mismatch: {filename}; expected={byte_count} actual={path.stat().st_size}"
            )

        digest = fixture.get("sha256")
        if not isinstance(digest, str) or len(digest) != 64:
            raise AssertionError(f"invalid SHA-256 field: {filename}")
        actual_digest = sha256(path)
        if actual_digest != digest:
            raise AssertionError(
                f"SHA-256 mismatch: {filename}; expected={digest} actual={actual_digest}"
            )

        for field in ("width", "height", "encodedDepth"):
            value = fixture.get(field)
            if not isinstance(value, int) or value <= 0:
                raise AssertionError(f"invalid {field}: {filename}")
        if fixture["encodedDepth"] not in {8, 10, 12}:
            raise AssertionError(f"unqualified AVIF depth in M4 fixture set: {filename}")
        if fixture["encodedDepth"] == 12:
            provenance = fixture.get("sourceProvenance")
            if not isinstance(provenance, dict):
                raise AssertionError(f"12-bit AVIF fixture lacks source provenance: {filename}")
            for field in ("repositoryURL", "revision", "path", "origin", "originProjectURL", "attribution", "license", "licenseURL", "licenseNotice", "independentProbe"):
                if not isinstance(provenance.get(field), str) or not provenance[field].strip():
                    raise AssertionError(f"12-bit AVIF fixture provenance lacks {field}: {filename}")
            if provenance["license"] != "CC-BY-SA-4.0":
                raise AssertionError(f"unexpected 12-bit AVIF fixture license: {filename}")
            if provenance.get("modified") is not False:
                raise AssertionError(f"12-bit AVIF fixture must record unchanged upstream bytes: {filename}")
            notice = root / provenance["licenseNotice"]
            notice_text = notice.read_text(encoding="utf-8") if notice.is_file() else ""
            if "Attribution-ShareAlike 4.0 International" not in notice_text:
                raise AssertionError(f"12-bit AVIF fixture license notice is missing or invalid: {filename}")

    required = {
        "avif-alpha-steps-8bit.avif",
        "avif-rgba-10bit.avif",
        "avif-rgb-10bit-svt-16x8.avif",
        "avif-rgb-12bit-aom-profile2-1204x800.avif",
        "avif-hdr-pq-10bit-imageio-2x2.avif",
    }
    if files != required:
        raise AssertionError(
            f"AVIF M4 fixture set mismatch; missing={sorted(required - files)} extra={sorted(files - required)}"
        )

    print(f"AVIF M4 fixture manifest passed: {manifest_path}")


if __name__ == "__main__":
    main()
