#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def jpeg_structure(path: Path) -> tuple[int, int, int]:
    data = path.read_bytes()
    require(data[:2] == b"\xff\xd8", f"{path}: missing SOI")
    offset = 2
    width = height = 0
    scans = 0
    inside_scan = False
    while offset < len(data):
        if inside_scan:
            marker = data.find(b"\xff", offset)
            require(marker >= 0, f"{path}: unterminated entropy data")
            cursor = marker + 1
            while cursor < len(data) and data[cursor] == 0xFF:
                cursor += 1
            require(cursor < len(data), f"{path}: truncated marker")
            value = data[cursor]
            if value == 0x00 or 0xD0 <= value <= 0xD7:
                offset = cursor + 1
                continue
            inside_scan = False
            offset = marker
            continue
        require(data[offset] == 0xFF, f"{path}: expected marker at {offset}")
        cursor = offset + 1
        while cursor < len(data) and data[cursor] == 0xFF:
            cursor += 1
        require(cursor < len(data), f"{path}: truncated marker prefix")
        marker = data[cursor]
        offset = cursor + 1
        if marker == 0xD9:
            break
        if marker == 0xD8 or marker == 0x01 or 0xD0 <= marker <= 0xD7:
            continue
        require(offset + 2 <= len(data), f"{path}: missing segment length")
        length = int.from_bytes(data[offset : offset + 2], "big")
        require(length >= 2 and offset + length <= len(data), f"{path}: bad segment")
        if marker == 0xC2:
            require(length >= 8, f"{path}: short SOF2")
            height = int.from_bytes(data[offset + 3 : offset + 5], "big")
            width = int.from_bytes(data[offset + 5 : offset + 7], "big")
        elif marker in (0xC0, 0xC1, 0xC3):
            raise AssertionError(f"{path}: not progressive SOF2")
        if marker == 0xDA:
            scans += 1
            inside_scan = True
        offset += length
    require(width > 0 and height > 0, f"{path}: missing SOF2")
    require(scans > 0, f"{path}: missing scans")
    return width, height, scans


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    args = parser.parse_args()
    manifest_path = args.manifest.resolve()
    root = manifest_path.parent
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

    require(manifest.get("schemaVersion") == 1, "unsupported schema")
    require(manifest.get("corpusVersion") == "progressive-real-photo-v1", "wrong corpus")
    sources = manifest["sources"]
    scripts = manifest["scanScripts"]
    variants = manifest["variants"]
    require(len(sources) == 4, "expected four sources")
    require(len(scripts) == 3, "expected three scripts")
    require(len(variants) == 12, "expected twelve variants")

    source_by_id = {}
    for source in sources:
        require(source["id"] not in source_by_id, "duplicate source")
        source_by_id[source["id"]] = source
        path = root / source["file"]
        require(path.is_file(), f"missing {path}")
        require(path.stat().st_size == source["byteCount"], f"size mismatch {path}")
        require(sha256(path) == source["sha256"], f"hash mismatch {path}")
        require(source["license"] == "Public domain", f"non-public-domain source {path}")
        require(source["width"] > 0 and source["height"] > 0, f"bad dimensions {path}")
        require(len(source["referenceDecodedPPMSHA256"]) == 64, f"missing reference hash {path}")

    script_by_id = {}
    for script in scripts:
        require(script["id"] not in script_by_id, "duplicate script")
        script_by_id[script["id"]] = script
        path = root / script["file"]
        require(path.is_file(), f"missing {path}")
        require(path.stat().st_size == script["byteCount"], f"size mismatch {path}")
        require(sha256(path) == script["sha256"], f"hash mismatch {path}")
        definitions = [
            entry.strip()
            for entry in "\n".join(
                line.split("#", 1)[0] for line in path.read_text(encoding="utf-8").splitlines()
            ).split(";")
            if entry.strip()
        ]
        require(len(definitions) == script["scanCount"], f"scan script count mismatch {path}")

    expected = {
        (source_id, script_id)
        for source_id in source_by_id
        for script_id in script_by_id
    }
    observed = set()
    for variant in variants:
        pair = (variant["sourceID"], variant["scanScriptID"])
        require(pair not in observed, f"duplicate variant {pair}")
        observed.add(pair)
        require(pair in expected, f"unknown variant pair {pair}")
        path = root / variant["file"]
        require(path.is_file(), f"missing {path}")
        require(path.stat().st_size == variant["byteCount"], f"size mismatch {path}")
        require(sha256(path) == variant["sha256"], f"hash mismatch {path}")
        width, height, scans = jpeg_structure(path)
        source = source_by_id[variant["sourceID"]]
        script = script_by_id[variant["scanScriptID"]]
        require((width, height) == (source["width"], source["height"]), f"dimension mismatch {path}")
        require(scans == script["scanCount"] == variant["scanCount"], f"scan mismatch {path}")
    require(observed == expected, "incomplete source/script cross product")
    print(f"Progressive photo corpus passed: {manifest_path}")


if __name__ == "__main__":
    main()
