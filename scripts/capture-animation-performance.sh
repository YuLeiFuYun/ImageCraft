#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
if [ "$#" -lt 4 ] || [ "$#" -gt 5 ]; then
    echo "usage: $0 GIF APNG JPEG_SEQUENCE_DIRECTORY OUTPUT_DIRECTORY [ITERATIONS]" >&2
    exit 64
fi
GIF=$1
APNG=$2
JPEG_SEQUENCE=$3
OUTPUT=$4
ITERATIONS=${5:-18}
mkdir -p "$OUTPUT"
xcrun swift build -c release --product ImageCraftEvidence >/dev/null
BIN=$(xcrun swift build -c release --show-bin-path)/ImageCraftEvidence
COMMON="--target-width 256 --target-height 256 --frame-index 12 --iterations $ITERATIONS --warmups 3"
# shellcheck disable=SC2086
"$BIN" --animation-performance --input "$GIF" --output "$OUTPUT/gif.json" $COMMON
# shellcheck disable=SC2086
"$BIN" --animation-performance --input "$APNG" --output "$OUTPUT/apng.json" $COMMON
# shellcheck disable=SC2086
"$BIN" --animation-performance --jpeg-sequence-directory "$JPEG_SEQUENCE" --output "$OUTPUT/jpeg-sequence.json" $COMMON
python3 Tools/Performance/validate_animation_performance_evidence.py \
    "$OUTPUT/gif.json" "$OUTPUT/apng.json" "$OUTPUT/jpeg-sequence.json"
