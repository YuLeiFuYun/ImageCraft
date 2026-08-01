#!/usr/bin/env python3
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXCLUDED_DIRECTORY_NAMES = {".artifacts", ".build", ".git", ".swiftpm", ".workflow"}
EXPECTED_TOOLS_DIRECTIVE = "// swift-tools-version: 6.4"


def package_manifests() -> list[Path]:
    return [
        path
        for path in sorted(ROOT.rglob("Package.swift"))
        if not any(part in EXCLUDED_DIRECTORY_NAMES for part in path.relative_to(ROOT).parts)
    ]


def run(command: list[str]) -> str:
    return subprocess.check_output(
        command,
        cwd=ROOT,
        env=os.environ.copy(),
        stderr=subprocess.STDOUT,
        text=True,
        timeout=30,
    )


def main() -> int:
    errors: list[str] = []
    manifests = package_manifests()
    if not manifests:
        errors.append("no active Package.swift manifest found")
    for manifest in manifests:
        lines = manifest.read_text().splitlines()
        first_line = lines[0].strip() if lines else ""
        if first_line != EXPECTED_TOOLS_DIRECTIVE:
            relative = manifest.relative_to(ROOT)
            errors.append(
                f"{relative} declares {first_line!r}, expected {EXPECTED_TOOLS_DIRECTIVE}"
            )

    try:
        xcode_output = run(["xcodebuild", "-version"])
        swift_output = run(["xcrun", "swift", "--version"])
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f"Swift 6.4 toolchain check failed: {error}", file=sys.stderr)
        return 1

    xcode_match = re.search(r"^Xcode\s+(\d+)(?:\.(\d+))?", xcode_output, re.MULTILINE)
    swift_match = re.search(r"Apple Swift version\s+(\d+)\.(\d+)(?:\.([0-9]+))?", swift_output)
    if xcode_match is None:
        errors.append("unable to parse xcodebuild -version")
    elif int(xcode_match.group(1)) < 27:
        errors.append(f"Xcode {xcode_match.group(0).split()[-1]} is older than Xcode 27")
    if swift_match is None:
        errors.append("unable to parse Apple Swift compiler version")
    elif (int(swift_match.group(1)), int(swift_match.group(2))) != (6, 4):
        errors.append(
            f"Apple Swift {swift_match.group(1)}.{swift_match.group(2)} is not the required 6.4"
        )

    if errors:
        print("Swift 6.4 toolchain check failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    xcode_version = xcode_match.group(0).split()[-1] if xcode_match else "unknown"
    swift_version = swift_match.group(0).split("version", 1)[1].strip() if swift_match else "unknown"
    print(
        f"Swift toolchain: Xcode {xcode_version}, Apple Swift {swift_version}, "
        f"tools 6.4, manifests={len(manifests)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
