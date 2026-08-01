#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if [ -z "${DEVELOPER_DIR:-}" ] || [ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]; then
    for candidate in \
        /Applications/Xcode.app/Contents/Developer \
        /Applications/Xcode-beta.app/Contents/Developer
    do
        if [ -x "$candidate/usr/bin/xcodebuild" ]; then
            DEVELOPER_DIR=$candidate
            break
        fi
    done
fi
: "${DEVELOPER_DIR:?A full Xcode installation is required}"
export DEVELOPER_DIR

TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT HUP INT TERM
FIRST="$TMPDIR_ROOT/first.json"
SECOND="$TMPDIR_ROOT/second.json"

swift build -c release --product ImageCraftEvidence >/dev/null
BIN_DIR=$(swift build -c release --show-bin-path)
"$BIN_DIR/ImageCraftEvidence" > "$FIRST"
"$BIN_DIR/ImageCraftEvidence" > "$SECOND"
cmp "$FIRST" "$SECOND"

python3 - "$FIRST" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    report = json.load(handle)

assert report["schemaVersion"] == 1
runtime = report["runtime"]
assert runtime["schemaVersion"] == 1
assert runtime["platform"] != "unknown"
assert runtime["architecture"] != "unknown"
assert runtime["operatingSystemBuild"] != "unknown"
assert runtime["imageIOBundleVersion"] != "unknown"
assert runtime["coreGraphicsBundleVersion"] != "unknown"

outputs = report["outputs"]
assert len(outputs) == 5
assert len({item["name"] for item in outputs}) == len(outputs)
for item in outputs:
    assert item["byteCount"] > 0
    assert len(item["sha256"]) == 64
    if item["format"] == "jpeg":
        frame = item["jpegStructure"]
        assert frame["width"] == report["source"]["width"]
        assert frame["height"] == report["source"]["height"]
        assert frame["samplePrecision"] > 0
        assert len(frame["components"]) > 0
        assert len(frame["quantizationPayloadSHA256"]) == 64
PY

if [ "$#" -gt 0 ]; then
    cmp "$FIRST" "$1"
fi
