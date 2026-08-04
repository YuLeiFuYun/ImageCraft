#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR
printf 'Using DEVELOPER_DIR=%s\n' "$DEVELOPER_DIR"
xcodebuild -version
xcrun swift --version
python3 scripts/check-swift-toolchain.py

if grep -R -n -E '^import (Fovea|Akashic|FoveaHTTP|FoveaPersistence)' Sources; then
    echo 'host dependency leaked into ImageCraft sources' >&2
    exit 1
fi
if grep -R -n -E '^import ImageIO' Sources/ImageCraftCore; then
    echo 'ImageCraftCore must remain independent of ImageIO' >&2
    exit 1
fi

xcrun swift package describe >/dev/null
scripts/verify-integration-contract.sh
scripts/verify-public-api.sh
scripts/verify-source-identity.sh
python3 Tools/Corpus/verify_manifest.py Tests/ImageCraftImageIOTests/Resources/Corpus/v1/manifest.json
python3 Tools/Performance/validate_performance_baseline.py Evidence/Performance/*.json
python3 Tools/Performance/validate_progressive_experiment.py \
    Evidence/Experiments/progressive-jpeg-bounded-preview-ab-2026-08-04.json
python3 Tools/Performance/validate_progressive_timeline_experiment.py \
    Evidence/Experiments/progressive-jpeg-first-preview-timeline-2026-08-04.json
python3 Tools/Performance/validate_progressive_quality_experiment.py \
    Evidence/Experiments/progressive-jpeg-generation-quality-2026-08-04.json
xcrun swift test
xcrun swift build -c release
scripts/verify-imageio-evidence.sh
