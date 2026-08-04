#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
OUTPUT=${1:-.artifacts/performance/progressive-pipeline}
ITERATIONS=${2:-7}
MANIFEST=Evidence/Fixtures/ProgressiveJPEGRealPhoto/v1/manifest.json
VARIANT=people-usda-meeting--default-successive-v1
DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR
python3 scripts/check-swift-toolchain.py
swift build -c release --product ImageCraftEvidence >/dev/null
BIN_DIR=$(swift build -c release --show-bin-path)
EVIDENCE_BIN="$BIN_DIR/ImageCraftEvidence"
TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT HUP INT TERM

"$EVIDENCE_BIN" --progressive-pipeline-profile \
    "$MANIFEST" "$VARIANT" 16384 --iterations "$ITERATIONS" \
    > "$TMPDIR_ROOT/profile-16k.json"
"$EVIDENCE_BIN" --progressive-pipeline-profile \
    "$MANIFEST" "$VARIANT" 32768 --iterations "$ITERATIONS" \
    > "$TMPDIR_ROOT/profile-32k.json"

python3 Tools/Performance/validate_progressive_pipeline_profile.py \
    "$TMPDIR_ROOT/profile-16k.json"
python3 Tools/Performance/validate_progressive_pipeline_profile.py \
    "$TMPDIR_ROOT/profile-32k.json"
python3 Tools/Performance/test_progressive_pipeline_simulation.py
python3 Tools/Performance/simulate_progressive_pipeline.py \
    --profile-16k "$TMPDIR_ROOT/profile-16k.json" \
    --profile-32k "$TMPDIR_ROOT/profile-32k.json" \
    > "$TMPDIR_ROOT/simulation.json"

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT"
cp "$TMPDIR_ROOT/profile-16k.json" "$OUTPUT/profile-16k.json"
cp "$TMPDIR_ROOT/profile-32k.json" "$OUTPUT/profile-32k.json"
cp "$TMPDIR_ROOT/simulation.json" "$OUTPUT/simulation.json"
cat "$OUTPUT/simulation.json"
