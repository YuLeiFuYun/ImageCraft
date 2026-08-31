#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

OUTPUT_DIR=${1:-.artifacts/performance/prepared-state-retention}
PAIR_COUNT=${2:-4}
PREPARATIONS=${3:-64}
ITERATIONS=${4:-25}

case "$PAIR_COUNT" in
    ''|*[!0-9]*) echo "pair count must be a positive integer" >&2; exit 2 ;;
esac
if [ "$PAIR_COUNT" -lt 2 ]; then
    echo "pair count must be at least 2" >&2
    exit 2
fi

DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR
python3 scripts/check-swift-toolchain.py

TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT HUP INT TERM
python3 Tools/Identity/capture_source_identity.py --output "$TMPDIR_ROOT/source-identity-before.json" >/dev/null

swift build -c release --product ImageCraftEvidence >/dev/null
BIN_DIR=$(swift build -c release --show-bin-path)
EVIDENCE_BIN="$BIN_DIR/ImageCraftEvidence"

pair=0
while [ "$pair" -lt "$PAIR_COUNT" ]; do
    if [ $((pair % 2)) -eq 0 ]; then
        first=retained-source
        second=encoded-data-only
    else
        first=encoded-data-only
        second=retained-source
    fi
    pair_name=$(printf '%02d' "$pair")
    order=0
    for strategy in "$first" "$second"; do
        "$EVIDENCE_BIN" --prepared-state-retention "$strategy" \
            --preparations "$PREPARATIONS" \
            --iterations "$ITERATIONS" \
            --emit-json \
            > "$TMPDIR_ROOT/pair-$pair_name-order-$order-$strategy.json"
        order=$((order + 1))
    done
    pair=$((pair + 1))
done

python3 Tools/Identity/capture_source_identity.py \
    --output "$TMPDIR_ROOT/source-identity-after.json" \
    --compare "$TMPDIR_ROOT/source-identity-before.json" >/dev/null

python3 Tools/Performance/aggregate_prepared_state_retention.py \
    --source-identity "$TMPDIR_ROOT/source-identity-before.json" \
    --output "$TMPDIR_ROOT/aggregate.json" \
    "$TMPDIR_ROOT"/pair-*.json >/dev/null

mkdir -p "$OUTPUT_DIR/raw"
cp "$TMPDIR_ROOT/source-identity-before.json" "$OUTPUT_DIR/source-identity.json"
cp "$TMPDIR_ROOT"/pair-*.json "$OUTPUT_DIR/raw/"
cp "$TMPDIR_ROOT/aggregate.json" "$OUTPUT_DIR/aggregate.json"
cat "$OUTPUT_DIR/aggregate.json"
