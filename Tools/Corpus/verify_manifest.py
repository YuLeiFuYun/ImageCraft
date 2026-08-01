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
        raise AssertionError("unsupported retained corpus schema")
    if manifest.get("corpusVersion") != "v1":
        raise AssertionError("unexpected retained corpus version")
    cases = manifest.get("cases")
    if not isinstance(cases, list) or not cases:
        raise AssertionError("retained corpus has no cases")

    ids: set[str] = set()
    files: set[str] = set()
    valid_kinds = {"valid", "failure", "metadataBoundary", "frameBoundary"}
    for case in cases:
        identifier = case.get("id")
        filename = case.get("file")
        kind = case.get("kind")
        if not isinstance(identifier, str) or not identifier:
            raise AssertionError("case id must be a non-empty string")
        if identifier in ids:
            raise AssertionError(f"duplicate case id: {identifier}")
        ids.add(identifier)
        if not isinstance(filename, str) or Path(filename).name != filename:
            raise AssertionError(f"invalid case filename: {filename}")
        if filename in files:
            raise AssertionError(f"duplicate case file: {filename}")
        files.add(filename)
        if kind not in valid_kinds:
            raise AssertionError(f"invalid kind for {identifier}: {kind}")

        path = root / filename
        if not path.is_file():
            raise AssertionError(f"missing corpus file: {filename}")
        if path.stat().st_size != case.get("byteCount"):
            raise AssertionError(f"byte count mismatch: {filename}")
        digest = case.get("sha256")
        if not isinstance(digest, str) or len(digest) != 64:
            raise AssertionError(f"invalid SHA-256 field: {filename}")
        if sha256(path) != digest:
            raise AssertionError(f"SHA-256 mismatch: {filename}")

        if kind in {"valid", "metadataBoundary", "frameBoundary"}:
            for field in ("format", "width", "height", "frames", "orientation", "sourceColorProfile"):
                if field not in case:
                    raise AssertionError(f"{identifier} is missing {field}")
        if kind == "failure" and case.get("expectedError") != "unsupportedOrCorruptImage":
            raise AssertionError(f"{identifier} has an unsupported failure contract")
        if kind == "metadataBoundary" and not isinstance(case.get("containerMetadataBytes"), int):
            raise AssertionError(f"{identifier} has no metadata boundary")
        if kind == "frameBoundary" and case.get("expectedCoreError") != "frameLimitExceeded":
            raise AssertionError(f"{identifier} has an unsupported frame contract")

    actual_files = {path.name for path in root.iterdir() if path.is_file() and path.name != manifest_path.name}
    if actual_files != files:
        missing = sorted(files - actual_files)
        extra = sorted(actual_files - files)
        raise AssertionError(f"corpus file set mismatch; missing={missing}, extra={extra}")


if __name__ == "__main__":
    main()
