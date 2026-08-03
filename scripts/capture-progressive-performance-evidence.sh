#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR
python3 scripts/check-swift-toolchain.py

OUTPUT=${1:-}
ITERATIONS=${2:-7}
PROCESS_REPETITIONS=${3:-3}
TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT HUP INT TERM
CASE_DIRECTORY="$TMPDIR_ROOT/cases"
REPORT="$TMPDIR_ROOT/report.json"
mkdir -p "$CASE_DIRECTORY"

xcrun swift build -c release --product ImageCraftEvidence >/dev/null
BIN_PATH=$(xcrun swift build -c release --show-bin-path)
EXECUTABLE="$BIN_PATH/ImageCraftEvidence"
test -x "$EXECUTABLE"
for case_id in \
    progressive-jpeg-fit-512-chunk-1024 \
    progressive-jpeg-fit-512-chunk-32768
do
    repetition=1
    while [ "$repetition" -le "$PROCESS_REPETITIONS" ]; do
        "$EXECUTABLE" \
            --benchmark-case "$case_id" \
            --iterations "$ITERATIONS" \
            > "$CASE_DIRECTORY/$case_id-$repetition.json"
        repetition=$((repetition + 1))
    done
done

SWIFT_VERSION=$(xcrun swift --version | tr '\n' ' ' | sed 's/[[:space:]]*$//')
Tools/Performance/aggregate_performance.py \
    --case-directory "$CASE_DIRECTORY" \
    --swift-version "$SWIFT_VERSION" \
    --expected-case progressive-jpeg-fit-512-chunk-1024 \
    --expected-case progressive-jpeg-fit-512-chunk-32768 \
    --output "$REPORT"

if [ -n "$OUTPUT" ]; then
    mkdir -p "$(dirname "$OUTPUT")"
    cp "$REPORT" "$OUTPUT"
else
    cat "$REPORT"
fi
