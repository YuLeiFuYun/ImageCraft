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

OUTPUT=${1:-}
ITERATIONS=${2:-7}
PROCESS_REPETITIONS=${3:-3}
TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT HUP INT TERM
CASE_DIRECTORY="$TMPDIR_ROOT/cases"
REPORT="$TMPDIR_ROOT/report.json"
mkdir -p "$CASE_DIRECTORY"

swift build -c release >/dev/null
EXECUTABLE=.build/release/ImageCraftEvidence
for case_id in \
    decode-jpeg-full \
    decode-jpeg-fit-512 \
    decode-jpeg-fit-1024 \
    decode-jpeg-fill-1024 \
    probe-then-decode-jpeg-fit-512 \
    prepare-then-decode-jpeg-fit-512 \
    encode-png \
    encode-jpeg-q75
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

SWIFT_VERSION=$(swift --version | tr '\n' ' ' | sed 's/[[:space:]]*$//')
Tools/Performance/aggregate_performance.py \
    --case-directory "$CASE_DIRECTORY" \
    --swift-version "$SWIFT_VERSION" \
    --output "$REPORT"

if [ -n "$OUTPUT" ]; then
    mkdir -p "$(dirname "$OUTPUT")"
    cp "$REPORT" "$OUTPUT"
else
    cat "$REPORT"
fi
