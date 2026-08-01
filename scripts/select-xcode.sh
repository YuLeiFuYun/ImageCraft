#!/bin/sh
set -eu

if [ -n "${DEVELOPER_DIR:-}" ] && [ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]; then
    candidate=$DEVELOPER_DIR
else
    candidate=
fi

python3 - "$candidate" <<'PY'
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

required_xcode = (27, 0)
required_swift = (6, 4)
explicit = Path(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1] else None
candidates: list[tuple[tuple[int, ...], bool, str]] = []
found: list[str] = []


def inspect(developer: Path) -> tuple[tuple[int, ...], tuple[int, int], str] | None:
    xcodebuild = developer / "usr" / "bin" / "xcodebuild"
    if not xcodebuild.is_file():
        return None
    env = os.environ.copy()
    env["DEVELOPER_DIR"] = str(developer)
    try:
        xcode_output = subprocess.check_output(
            [str(xcodebuild), "-version"], stderr=subprocess.STDOUT, text=True, timeout=10
        )
        swift_output = subprocess.check_output(
            ["xcrun", "swift", "--version"],
            stderr=subprocess.STDOUT,
            text=True,
            timeout=10,
            env=env,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None
    xcode_match = re.search(r"^Xcode\s+(\d+(?:\.\d+)*)", xcode_output, re.MULTILINE)
    swift_match = re.search(r"Apple Swift version\s+(\d+)\.(\d+)", swift_output)
    if xcode_match is None or swift_match is None:
        return None
    xcode_version = tuple(int(part) for part in xcode_match.group(1).split("."))
    swift_version = (int(swift_match.group(1)), int(swift_match.group(2)))
    return xcode_version, swift_version, xcode_match.group(1)


def accept(developer: Path) -> bool:
    inspected = inspect(developer)
    if inspected is None:
        return False
    xcode_version, swift_version, xcode_string = inspected
    found.append(f"{developer.parent.parent.name}=Xcode {xcode_string}/Swift {swift_version[0]}.{swift_version[1]}")
    if xcode_version >= required_xcode and swift_version == required_swift:
        candidates.append(
            (xcode_version, "beta" not in developer.parent.parent.name.lower(), str(developer))
        )
        return True
    return False

if explicit is not None:
    if accept(explicit):
        print(explicit)
        raise SystemExit(0)
    print(
        f"DEVELOPER_DIR does not provide Xcode 27+ with Swift 6.4: {explicit}",
        file=sys.stderr,
    )
    raise SystemExit(1)

try:
    active = Path(
        subprocess.check_output(
            ["xcode-select", "-p"], stderr=subprocess.STDOUT, text=True, timeout=5
        ).strip()
    )
except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
    active = None
if active is not None and accept(active):
    print(active)
    raise SystemExit(0)

for app in sorted(Path("/Applications").glob("Xcode*.app")):
    developer = app / "Contents" / "Developer"
    if active is not None and developer == active:
        continue
    accept(developer)

if not candidates:
    detail = ", ".join(found) if found else "none"
    print(
        "No complete Xcode 27.0 or newer installation with Apple Swift 6.4 found "
        f"(detected: {detail}).",
        file=sys.stderr,
    )
    raise SystemExit(1)

print(max(candidates)[2])
PY
