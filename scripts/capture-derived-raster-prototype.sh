#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
OUTPUT=${1:-.artifacts/performance/derived-raster-prototype}
ITERATIONS=${2:-7}
shift 2 || true
DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR
python3 scripts/check-swift-toolchain.py
xcrun swift build -c release --product ImageCraftEvidence >/dev/null
BIN=$(xcrun swift build -c release --show-bin-path)/ImageCraftEvidence
if [ "$#" -eq 0 ]; then
  set -- \
    Evidence/Fixtures/ProgressiveJPEGRealPhoto/v1/sources/animal-usda-cow-sunset.jpg \
    Evidence/Fixtures/ProgressiveJPEGRealPhoto/v1/sources/architecture-usda-snow.jpg \
    Evidence/Fixtures/ProgressiveJPEGRealPhoto/v1/sources/landscape-coconino-sunflowers.jpg \
    Evidence/Fixtures/ProgressiveJPEGRealPhoto/v1/sources/people-usda-meeting.jpg
fi
rm -rf "$OUTPUT"
mkdir -p "$OUTPUT"
for input in "$@"; do
  name=$(basename "$input" .jpg)
  report="$OUTPUT/$name.json"
  "$BIN" --derived-raster-prototype "$input" --iterations "$ITERATIONS" > "$report"
  python3 Tools/Performance/validate_derived_raster_prototype.py "$report" "$input"
done
