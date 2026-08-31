#!/usr/bin/env python3
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
from typing import Any


JPEG_SUFFIXES = {".jpg", ".jpeg"}
DEFAULT_LIMIT = 500


class AuditError(RuntimeError):
    pass


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def scan_count(data: bytes) -> int:
    if not data.startswith(b"\xff\xd8"):
        raise AuditError("missing JPEG SOI")
    offset = 2
    inside_scan = False
    scans = 0
    while offset < len(data):
        if inside_scan:
            while True:
                marker_start = data.find(b"\xff", offset)
                if marker_start < 0:
                    raise AuditError("scan entropy reaches EOF without marker")
                marker_offset = marker_start + 1
                while marker_offset < len(data) and data[marker_offset] == 0xFF:
                    marker_offset += 1
                if marker_offset >= len(data):
                    raise AuditError("truncated marker after scan entropy")
                marker = data[marker_offset]
                offset = marker_offset + 1
                if marker == 0x00 or 0xD0 <= marker <= 0xD7:
                    continue
                inside_scan = False
                break
        else:
            if data[offset] != 0xFF:
                raise AuditError("marker does not start with 0xFF")
            while offset < len(data) and data[offset] == 0xFF:
                offset += 1
            if offset >= len(data):
                raise AuditError("truncated marker")
            marker = data[offset]
            offset += 1

        if marker == 0xD9:
            if offset != len(data):
                raise AuditError("trailing bytes after JPEG EOI")
            return scans
        if marker == 0xD8 or 0xD0 <= marker <= 0xD7:
            raise AuditError("unexpected standalone JPEG marker")
        if marker == 0x01:
            continue
        if offset + 2 > len(data):
            raise AuditError("truncated JPEG segment length")
        segment_length = int.from_bytes(data[offset : offset + 2], "big")
        if segment_length < 2 or offset + segment_length > len(data):
            raise AuditError("JPEG segment exceeds file bytes")
        if marker == 0xDA:
            scans += 1
            inside_scan = True
        offset += segment_length
    raise AuditError("JPEG has no terminal EOI")


def source_report(label: str, root: Path, limit: int) -> dict[str, Any]:
    candidates = [root] if root.is_file() else sorted(root.rglob("*"))
    relative_root = root.parent if root.is_file() else root
    files: list[dict[str, Any]] = []
    malformed: list[dict[str, str]] = []
    for path in candidates:
        if not path.is_file() or path.suffix.lower() not in JPEG_SUFFIXES:
            continue
        data = path.read_bytes()
        try:
            count = scan_count(data)
        except AuditError as error:
            malformed.append(
                {
                    "path": str(path.relative_to(relative_root)),
                    "sha256": sha256_bytes(data),
                    "reason": str(error),
                }
            )
            continue
        files.append(
            {
                "path": str(path.relative_to(relative_root)),
                "sha256": sha256_bytes(data),
                "byteCount": len(data),
                "scanCount": count,
                "withinLimit": count <= limit,
            }
        )
    histogram = Counter(item["scanCount"] for item in files)
    maximum = max((item["scanCount"] for item in files), default=0)
    return {
        "label": label,
        "root": str(root),
        "candidateFileCount": len(files) + len(malformed),
        "validJPEGCount": len(files),
        "malformedCandidateCount": len(malformed),
        "malformedCandidates": malformed,
        "scanCountHistogram": {str(key): value for key, value in sorted(histogram.items())},
        "maximumObservedScanCount": maximum,
        "allValidJPEGsWithinLimit": all(item["withinLimit"] for item in files),
        "files": files,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", action="append", required=True, metavar="LABEL=PATH")
    parser.add_argument("--limit", type=int, default=DEFAULT_LIMIT)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.limit <= 0:
        raise AuditError("scan limit must be positive")

    sources: list[dict[str, Any]] = []
    for raw in args.source:
        label, separator, path_raw = raw.partition("=")
        if not separator or not label or not path_raw:
            raise AuditError(f"invalid --source {raw!r}; expected LABEL=PATH")
        path = Path(path_raw).resolve()
        if not path.exists():
            raise AuditError(f"JPEG source does not exist: {path}")
        sources.append(source_report(label, path, args.limit))

    valid_files = [item for source in sources for item in source["files"]]
    maximum = max((item["scanCount"] for item in valid_files), default=0)
    report = {
        "schemaVersion": 1,
        "status": "jpeg-scan-count-audit",
        "scanLimit": args.limit,
        "sources": sources,
        "summary": {
            "sourceCount": len(sources),
            "candidateFileCount": sum(source["candidateFileCount"] for source in sources),
            "validJPEGCount": len(valid_files),
            "malformedCandidateCount": sum(
                source["malformedCandidateCount"] for source in sources
            ),
            "maximumObservedScanCount": maximum,
            "minimumLimitHeadroomFactor": (
                args.limit / maximum if maximum > 0 else None
            ),
            "allValidJPEGsWithinLimit": all(item["withinLimit"] for item in valid_files),
        },
        "claimBoundary": [
            "This report only measures SOS marker count in the explicitly supplied JPEG corpora; it is not a survey of all legitimate JPEG scan organizations.",
            "The 500-scan admission limit is a denial-of-service safety bound aligned with libjpeg-turbo's historical TJFLAG_LIMITSCANS behavior, not a JPEG conformance limit from the format specification.",
        ],
    }
    payload = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output is None:
        print(payload, end="")
    else:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
