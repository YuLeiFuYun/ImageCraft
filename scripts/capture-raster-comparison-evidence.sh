#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
OUTPUT=${1:-.artifacts/performance/raster-path-comparison/report.json}
ITERATIONS=${2:-25}
INPUT=${3:-Evidence/Fixtures/ProgressiveJPEGRealPhoto/v1/encoded/landscape-coconino-sunflowers--default-successive-v1.jpg}
CHUNK_SIZE=${4:-32768}
DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR
python3 scripts/check-swift-toolchain.py
swift build -c release --product ImageCraftEvidence >/dev/null
BIN_DIR=$(swift build -c release --show-bin-path)
EVIDENCE_BIN="$BIN_DIR/ImageCraftEvidence"
TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT HUP INT TERM

"$EVIDENCE_BIN" --raster-comparison "$INPUT" \
    --chunk-size "$CHUNK_SIZE" \
    --iterations "$ITERATIONS" \
    > "$TMPDIR_ROOT/report.json"
python3 Tools/Performance/validate_raster_comparison_evidence.py \
    "$TMPDIR_ROOT/report.json" "$INPUT"

mkdir -p "$(dirname -- "$OUTPUT")"
cp "$TMPDIR_ROOT/report.json" "$OUTPUT"
cat "$OUTPUT"
