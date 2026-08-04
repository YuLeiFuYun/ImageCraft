#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR
python3 scripts/check-swift-toolchain.py

OUTPUT=${1:-}
TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT HUP INT TERM
CASE_DIRECTORY="$TMPDIR_ROOT/cases"
mkdir -p "$CASE_DIRECTORY"

xcrun swift build -c release --product ImageCraftEvidence >/dev/null
BIN_PATH=$(xcrun swift build -c release --show-bin-path)
EXECUTABLE="$BIN_PATH/ImageCraftEvidence"
test -x "$EXECUTABLE"
for case_id in \
    progressive-jpeg-quality-fit-512-chunk-1024 \
    progressive-jpeg-quality-fit-512-chunk-32768
do
    "$EXECUTABLE" --progressive-quality-case "$case_id" \
        > "$CASE_DIRECTORY/$case_id.json"
    "$EXECUTABLE" --progressive-quality-case "$case_id" \
        > "$CASE_DIRECTORY/$case_id-repeat.json"
    cmp "$CASE_DIRECTORY/$case_id.json" "$CASE_DIRECTORY/$case_id-repeat.json"
    rm "$CASE_DIRECTORY/$case_id-repeat.json"
done

REPORT="$TMPDIR_ROOT/report.json"
Tools/Performance/aggregate_progressive_quality.py \
    --case-directory "$CASE_DIRECTORY" \
    --output "$REPORT"
if [ -n "$OUTPUT" ]; then
    mkdir -p "$(dirname "$OUTPUT")"
    cp "$REPORT" "$OUTPUT"
else
    cat "$REPORT"
fi
