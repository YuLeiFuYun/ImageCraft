#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT = ROOT / ".build/source-identity.json"
SCHEMA_VERSION = 2
IDENTITY_ID = 'IMAGECRAFT-SOURCE-IDENTITY-V2'
COVERAGE_MODE = "explicit-top-level-complete-v2"
INCLUDED_TOP_LEVEL = frozenset(['.github', '.gitignore', 'API', 'CONTRIBUTING.md', 'Evidence', 'Fixtures', 'Integration', 'LICENSE', 'Package.swift', 'README.md', 'ROADMAP.md', 'SECURITY.md', 'Sources', 'Tests', 'Tools', 'docs', 'scripts'])
EXCLUDED_TOP_LEVEL = frozenset(['.artifacts', '.build', '.git', '.swiftpm'])
EXCLUDED_SUBTREES = tuple(['Fixtures/ConsumerSmoke/.build', 'Fixtures/ConsumerSmoke/.swiftpm'])
EXCLUDED_SUBTREE_PARTS = tuple(tuple(Path(value).parts) for value in EXCLUDED_SUBTREES)
EXCLUDED_ANYWHERE = frozenset(['.DS_Store', '__pycache__'])


def read_stable_file(path: Path) -> tuple[bytes, bool]:
    with path.open("rb") as handle:
        before = os.fstat(handle.fileno())
        data = handle.read()
        after = os.fstat(handle.fileno())
    before_identity = (
        before.st_dev,
        before.st_ino,
        before.st_size,
        before.st_mtime_ns,
        before.st_mode,
    )
    after_identity = (
        after.st_dev,
        after.st_ino,
        after.st_size,
        after.st_mtime_ns,
        after.st_mode,
    )
    if before_identity != after_identity or len(data) != after.st_size:
        raise RuntimeError(f"source file changed while capturing identity: {path}")
    return data, bool(after.st_mode & 0o111)


def coverage_contract() -> dict[str, object]:
    return {
        "mode": COVERAGE_MODE,
        "includedTopLevel": sorted(INCLUDED_TOP_LEVEL),
        "excludedTopLevel": sorted(EXCLUDED_TOP_LEVEL),
        "excludedSubtrees": sorted(EXCLUDED_SUBTREES),
        "excludedAnywhere": sorted(EXCLUDED_ANYWHERE),
    }


def top_level_is_excluded(name: str) -> bool:
    return name in EXCLUDED_TOP_LEVEL or name in EXCLUDED_ANYWHERE


def path_is_excluded_subtree(relative: Path) -> bool:
    return any(
        relative.parts[: len(parts)] == parts
        for parts in EXCLUDED_SUBTREE_PARTS
    )


def included_files() -> list[Path]:
    unexpected_top_level = sorted(
        item.name
        for item in ROOT.iterdir()
        if item.name not in INCLUDED_TOP_LEVEL and not top_level_is_excluded(item.name)
    )
    if unexpected_top_level:
        raise ValueError(
            "source identity contains unbound top-level entries: "
            + ", ".join(unexpected_top_level)
        )

    result: list[Path] = []
    for name in sorted(INCLUDED_TOP_LEVEL):
        path = ROOT / name
        if path.is_symlink():
            raise ValueError(f"source identity rejects symbolic links: {path}")
        if path.is_file():
            result.append(path)
            continue
        if not path.is_dir():
            raise FileNotFoundError(path)

        for candidate in sorted(path.rglob("*")):
            relative = candidate.relative_to(ROOT)
            if path_is_excluded_subtree(relative):
                continue
            if any(part in EXCLUDED_ANYWHERE for part in relative.parts):
                continue
            reserved = next(
                (part for part in relative.parts if part in EXCLUDED_TOP_LEVEL),
                None,
            )
            if reserved is not None:
                raise ValueError(
                    "source identity rejects nested top-level exclusion name "
                    f"{reserved!r} at {relative.as_posix()!r}"
                )
            if candidate.is_symlink():
                raise ValueError(f"source identity rejects symbolic links: {candidate}")
            if candidate.is_file():
                result.append(candidate)
            elif not candidate.is_dir():
                raise ValueError(
                    "source identity rejects unsupported filesystem entry: "
                    f"{relative.as_posix()!r}"
                )
    return result


def canonical_identity(
    coverage: dict[str, object], entries: list[dict[str, object]]
) -> str:
    payload = json.dumps(
        {
            "schemaVersion": SCHEMA_VERSION,
            "identityID": IDENTITY_ID,
            "coverage": coverage,
            "files": entries,
        },
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    return hashlib.sha256(payload).hexdigest()


def capture() -> dict[str, object]:
    coverage = coverage_contract()
    entries: list[dict[str, object]] = []
    for path in included_files():
        data, executable = read_stable_file(path)
        entries.append(
            {
                "path": path.relative_to(ROOT).as_posix(),
                "byteCount": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
                "executable": executable,
            }
        )
    entries.sort(key=lambda item: str(item["path"]))
    return {
        "schemaVersion": SCHEMA_VERSION,
        "identityID": IDENTITY_ID,
        "coverage": coverage,
        "fileCount": len(entries),
        "sourceIdentitySHA256": canonical_identity(coverage, entries),
        "files": entries,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--compare", type=Path)
    args = parser.parse_args()

    report = capture()
    if args.compare is not None:
        expected = json.loads(args.compare.read_text())
        if expected != report:
            print(
                "ImageCraft source identity mismatch: "
                f"expected={expected.get('sourceIdentitySHA256')} "
                f"actual={report['sourceIdentitySHA256']}"
            )
            return 1

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(
        "ImageCraft source identity: "
        f"files={report['fileCount']} sha256={report['sourceIdentitySHA256']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
