#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
OUTPUT=${1:-.artifacts/performance/progressive-photo-matrix.json}
RAW_OUTPUT=${2:-}
MANIFEST=Evidence/Fixtures/ProgressiveJPEGRealPhoto/v1/manifest.json
DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR
python3 scripts/check-swift-toolchain.py
swift build -c release --product ImageCraftEvidence >/dev/null
BIN_DIR=$(swift build -c release --show-bin-path)
EVIDENCE_BIN="$BIN_DIR/ImageCraftEvidence"
TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT HUP INT TERM
python3 - "$MANIFEST" <<'PY' > "$TMPDIR_ROOT/variants.txt"
import json, sys
manifest=json.load(open(sys.argv[1]))
for variant in manifest['variants']:
    print(variant['id'])
PY
while IFS= read -r variant; do
    for chunk in 1024 32768; do
        base="$TMPDIR_ROOT/$variant--chunk-$chunk"
        "$EVIDENCE_BIN" --progressive-photo-case "$MANIFEST" "$variant" "$chunk" > "$base-a.json"
        "$EVIDENCE_BIN" --progressive-photo-case "$MANIFEST" "$variant" "$chunk" > "$base-b.json"
    done
done < "$TMPDIR_ROOT/variants.txt"
mkdir -p "$(dirname "$OUTPUT")"
python3 Tools/Performance/aggregate_progressive_photo_matrix.py \
    --manifest "$MANIFEST" \
    "$TMPDIR_ROOT"/*.json > "$OUTPUT"
if [ -n "$RAW_OUTPUT" ]; then
    rm -rf "$RAW_OUTPUT"
    mkdir -p "$RAW_OUTPUT"
    cp "$TMPDIR_ROOT"/*.json "$RAW_OUTPUT"/
fi
cat "$OUTPUT"
