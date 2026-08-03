#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
from pathlib import Path, PurePosixPath

SCHEMA_VERSION = 2
EXPECTED_IDENTITY_ID = 'IMAGECRAFT-SOURCE-IDENTITY-V2'
EXPECTED_COVERAGE_MODE = "explicit-top-level-complete-v2"
EXPECTED_INCLUDED_TOP_LEVEL = frozenset(['.github', '.gitignore', 'API', 'CONTRIBUTING.md', 'Evidence', 'Fixtures', 'Integration', 'LICENSE', 'Package.swift', 'README.md', 'ROADMAP.md', 'SECURITY.md', 'Sources', 'Tests', 'Tools', 'docs', 'scripts'])
EXPECTED_EXCLUDED_TOP_LEVEL = frozenset(['.artifacts', '.build', '.git', '.swiftpm'])
EXPECTED_EXCLUDED_SUBTREES = tuple(['Fixtures/ConsumerSmoke/.build', 'Fixtures/ConsumerSmoke/.swiftpm'])
EXPECTED_EXCLUDED_SUBTREE_PARTS = tuple(
    tuple(Path(value).parts) for value in EXPECTED_EXCLUDED_SUBTREES
)
EXPECTED_EXCLUDED_ANYWHERE = frozenset(['.DS_Store', '__pycache__'])


def canonical_digest(
    coverage: dict[str, object], files: list[dict[str, object]]
) -> str:
    payload = json.dumps(
        {
            "schemaVersion": SCHEMA_VERSION,
            "identityID": EXPECTED_IDENTITY_ID,
            "coverage": coverage,
            "files": files,
        },
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    return hashlib.sha256(payload).hexdigest()


def top_level_is_excluded(name: str) -> bool:
    return name in EXPECTED_EXCLUDED_TOP_LEVEL or name in EXPECTED_EXCLUDED_ANYWHERE


def path_is_excluded_subtree(relative: Path) -> bool:
    return any(
        relative.parts[: len(parts)] == parts
        for parts in EXPECTED_EXCLUDED_SUBTREE_PARTS
    )


def expected_files(source_root: Path) -> list[str]:
    unexpected = sorted(
        item.name
        for item in source_root.iterdir()
        if item.name not in EXPECTED_INCLUDED_TOP_LEVEL
        and not top_level_is_excluded(item.name)
    )
    if unexpected:
        raise ValueError("unbound top-level entries: " + ", ".join(unexpected))

    result: list[str] = []
    for name in sorted(EXPECTED_INCLUDED_TOP_LEVEL):
        path = source_root / name
        if path.is_symlink():
            raise ValueError(f"symbolic link is not allowed: {name}")
        if path.is_file():
            result.append(name)
            continue
        if not path.is_dir():
            raise FileNotFoundError(path)

        for candidate in sorted(path.rglob("*")):
            relative = candidate.relative_to(source_root)
            if path_is_excluded_subtree(relative):
                continue
            if any(part in EXPECTED_EXCLUDED_ANYWHERE for part in relative.parts):
                continue
            reserved = next(
                (part for part in relative.parts if part in EXPECTED_EXCLUDED_TOP_LEVEL),
                None,
            )
            if reserved is not None:
                raise ValueError(
                    "nested top-level exclusion name is not allowed: "
                    f"{reserved!r} at {relative.as_posix()!r}"
                )
            if candidate.is_symlink():
                raise ValueError(
                    f"symbolic link is not allowed: {relative.as_posix()}"
                )
            if candidate.is_file():
                result.append(relative.as_posix())
            elif not candidate.is_dir():
                raise ValueError(
                    "unsupported filesystem entry: "
                    f"{relative.as_posix()!r}"
                )
    result.sort()
    return result



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
        raise RuntimeError(f"source file changed while materializing: {path}")
    return data, bool(after.st_mode & 0o111)

def ensure_destination_is_external(source_root: Path, destination: Path) -> None:
    try:
        destination.relative_to(source_root)
    except ValueError:
        return
    raise ValueError("clean-copy destination must be outside the source root")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--identity", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()

    source_root = args.source_root.resolve()
    destination = args.destination.resolve()
    if not source_root.is_dir():
        raise NotADirectoryError(source_root)
    ensure_destination_is_external(source_root, destination)

    document = json.loads(args.identity.read_text())
    if document.get("schemaVersion") != SCHEMA_VERSION:
        raise ValueError("unexpected identity schema")
    if document.get("identityID") != EXPECTED_IDENTITY_ID:
        raise ValueError("unexpected identity document")

    coverage = document.get("coverage")
    if not isinstance(coverage, dict):
        raise ValueError("identity coverage is missing")
    if coverage.get("mode") != EXPECTED_COVERAGE_MODE:
        raise ValueError("unexpected identity coverage mode")
    if coverage.get("includedTopLevel") != sorted(EXPECTED_INCLUDED_TOP_LEVEL):
        raise ValueError("identity coverage roots drifted")
    if coverage.get("excludedTopLevel") != sorted(EXPECTED_EXCLUDED_TOP_LEVEL):
        raise ValueError("identity top-level exclusions drifted")
    if coverage.get("excludedSubtrees") != sorted(EXPECTED_EXCLUDED_SUBTREES):
        raise ValueError("identity excluded subtrees drifted")
    if coverage.get("excludedAnywhere") != sorted(EXPECTED_EXCLUDED_ANYWHERE):
        raise ValueError("identity recursive exclusions drifted")

    files = document.get("files")
    if not isinstance(files, list) or document.get("fileCount") != len(files):
        raise ValueError("identity file count is inconsistent")
    if document.get("sourceIdentitySHA256") != canonical_digest(coverage, files):
        raise ValueError("identity digest does not match its complete envelope")

    expected_paths = expected_files(source_root)
    observed_paths: list[str] = []
    validated: list[tuple[bytes, Path, bool]] = []
    for entry in files:
        if not isinstance(entry, dict):
            raise ValueError("invalid identity entry")
        raw_path = entry.get("path")
        byte_count = entry.get("byteCount")
        digest = entry.get("sha256")
        executable = entry.get("executable")
        if not isinstance(raw_path, str) or not raw_path:
            raise ValueError("invalid identity path")
        relative = PurePosixPath(raw_path)
        if (
            relative.is_absolute()
            or ".." in relative.parts
            or "\\" in raw_path
            or relative.as_posix() != raw_path
        ):
            raise ValueError(f"unsafe identity path: {raw_path}")
        if not isinstance(byte_count, int) or isinstance(byte_count, bool) or byte_count < 0:
            raise ValueError(f"invalid byte count: {raw_path}")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError(f"invalid file digest: {raw_path}")
        if not isinstance(executable, bool):
            raise ValueError(f"invalid executable flag: {raw_path}")

        source = source_root / Path(*relative.parts)
        if source.is_symlink() or not source.is_file():
            raise FileNotFoundError(source)
        resolved = source.resolve()
        resolved.relative_to(source_root)
        data, actual_executable = read_stable_file(source)
        if len(data) != byte_count:
            raise ValueError(f"byte count drifted: {raw_path}")
        if hashlib.sha256(data).hexdigest() != digest:
            raise ValueError(f"file digest drifted: {raw_path}")
        if actual_executable != executable:
            raise ValueError(f"executable flag drifted: {raw_path}")
        observed_paths.append(raw_path)
        validated.append((data, Path(*relative.parts), executable))

    if observed_paths != sorted(observed_paths) or len(observed_paths) != len(set(observed_paths)):
        raise ValueError("identity paths are not unique and sorted")
    if observed_paths != expected_paths:
        missing = sorted(set(expected_paths).difference(observed_paths))
        extra = sorted(set(observed_paths).difference(expected_paths))
        raise ValueError(f"identity coverage is incomplete: missing={missing} extra={extra}")

    if destination.exists():
        raise FileExistsError(destination)
    destination.mkdir(parents=True)
    for data, relative, executable in validated:
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        target.chmod(0o755 if executable else 0o644)

    print(
        "ImageCraft clean copy materialized: "
        f"files={document.get('fileCount')} destination={destination}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
