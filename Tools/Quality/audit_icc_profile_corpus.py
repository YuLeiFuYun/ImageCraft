#!/usr/bin/env python3
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
from typing import Any


PROFILE_SUFFIXES = {".icc", ".icm"}
FORWARD_OR_REVERSE_PREFIXES = (b"A2B", b"B2A", b"D2B", b"B2D")
MATRIX_TRC_TAGS = {b"rXYZ", b"gXYZ", b"bXYZ", b"rTRC", b"gTRC", b"bTRC"}


class AuditError(RuntimeError):
    pass


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def profile_facts(path: Path, relative_root: Path) -> dict[str, Any]:
    data = path.read_bytes()
    if len(data) < 132:
        raise AuditError(f"ICC profile is shorter than its tag table header: {path}")
    declared_size = int.from_bytes(data[0:4], "big")
    tag_count = int.from_bytes(data[128:132], "big")
    table_end = 132 + tag_count * 12
    if declared_size > len(data) or table_end > len(data):
        raise AuditError(f"ICC profile header/table exceeds file bytes: {path}")

    tags: list[bytes] = []
    tag_types: dict[str, str] = {}
    for index in range(tag_count):
        entry = 132 + index * 12
        signature = bytes(data[entry : entry + 4])
        offset = int.from_bytes(data[entry + 4 : entry + 8], "big")
        size = int.from_bytes(data[entry + 8 : entry + 12], "big")
        if size <= 0 or offset + size > len(data):
            raise AuditError(f"ICC tag range exceeds file bytes: {path}")
        tags.append(signature)
        tag_types[signature.decode("latin1")] = data[offset : offset + 4].decode("latin1")

    profile_class = data[12:16].decode("latin1")
    data_color_space = data[16:20].decode("latin1")
    pcs = data[20:24].decode("latin1")
    tag_set = set(tags)
    has_lut_or_mpe = any(tag[:3] in FORWARD_OR_REVERSE_PREFIXES for tag in tags)
    has_matrix_trc = (
        data[16:20] == b"RGB "
        and data[20:24] == b"XYZ "
        and MATRIX_TRC_TAGS.issubset(tag_set)
    )
    transform_family = (
        "matrixTRC"
        if has_matrix_trc and not has_lut_or_mpe
        else "LUT/MPE"
        if has_lut_or_mpe
        else "other"
    )
    return {
        "path": str(path.relative_to(relative_root)),
        "sha256": sha256_bytes(data),
        "byteCount": len(data),
        "declaredProfileByteCount": declared_size,
        "profileClass": profile_class,
        "dataColorSpace": data_color_space,
        "pcs": pcs,
        "transformFamily": transform_family,
        "tags": [tag.decode("latin1") for tag in tags],
        "tagTypes": tag_types,
    }


def audit_source(label: str, root: Path) -> dict[str, Any]:
    profiles: list[dict[str, Any]] = []
    malformed_candidates: list[dict[str, str]] = []
    relative_root = root.parent if root.is_file() else root
    candidates = [root] if root.is_file() else sorted(root.rglob("*"))
    for path in candidates:
        if path.is_file() and path.suffix.lower() in PROFILE_SUFFIXES:
            try:
                profiles.append(profile_facts(path, relative_root))
            except AuditError as error:
                malformed_candidates.append(
                    {
                        "path": str(path.relative_to(relative_root)),
                        "sha256": sha256_bytes(path.read_bytes()),
                        "reason": str(error),
                    }
                )

    classes = Counter(item["profileClass"] for item in profiles)
    families = Counter(
        (item["profileClass"], item["transformFamily"])
        for item in profiles
    )
    input_profiles = [item for item in profiles if item["profileClass"] == "scnr"]
    input_matrix_trc = [item for item in input_profiles if item["transformFamily"] == "matrixTRC"]
    return {
        "label": label,
        "root": str(root),
        "candidateFileCount": len(profiles) + len(malformed_candidates),
        "profileCount": len(profiles),
        "malformedCandidateCount": len(malformed_candidates),
        "malformedCandidates": malformed_candidates,
        "profileClassCounts": dict(sorted(classes.items())),
        "profileClassTransformFamilyCounts": {
            f"{profile_class}:{family}": count
            for (profile_class, family), count in sorted(families.items())
        },
        "inputProfileCount": len(input_profiles),
        "inputMatrixTRCProfileCount": len(input_matrix_trc),
        "inputProfiles": input_profiles,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--source",
        action="append",
        required=True,
        metavar="LABEL=ROOT",
        help="One corpus root to scan; may be repeated.",
    )
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    sources: list[dict[str, Any]] = []
    for raw in args.source:
        label, separator, root_raw = raw.partition("=")
        if not separator or not label or not root_raw:
            raise AuditError(f"invalid --source {raw!r}; expected LABEL=ROOT")
        root = Path(root_raw).resolve()
        if not root.exists() or (root.is_file() and root.suffix.lower() not in PROFILE_SUFFIXES):
            raise AuditError(f"ICC corpus source is not a directory or ICC/ICM file: {root}")
        sources.append(audit_source(label, root))

    input_profiles = sum(source["inputProfileCount"] for source in sources)
    input_matrix_trc = sum(source["inputMatrixTRCProfileCount"] for source in sources)
    report = {
        "schemaVersion": 1,
        "status": "icc-profile-corpus-audit",
        "sources": sources,
        "summary": {
            "sourceCount": len(sources),
            "candidateFileCount": sum(source["candidateFileCount"] for source in sources),
            "profileCount": sum(source["profileCount"] for source in sources),
            "malformedCandidateCount": sum(
                source["malformedCandidateCount"] for source in sources
            ),
            "inputProfileCount": input_profiles,
            "inputMatrixTRCProfileCount": input_matrix_trc,
            "inputMatrixTRCObserved": input_matrix_trc > 0,
        },
        "claimBoundary": [
            "This report describes only the explicitly supplied profile corpora; absence of a profile family is not a claim that the wider ecosystem contains none.",
            "Transform-family classification is structural: RGB/XYZ matrixTRC requires rXYZ/gXYZ/bXYZ plus rTRC/gTRC/bTRC and no A2B/B2A/D2B/B2D transform tag; LUT/MPE is any profile carrying one of those transform signatures.",
        ],
    }
    payload = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output is not None:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(payload)
    else:
        print(payload, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
