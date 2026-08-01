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
printf 'Using DEVELOPER_DIR=%s\n' "$DEVELOPER_DIR"

if grep -R -n -E '^import (Fovea|Akashic|FoveaHTTP|FoveaPersistence)' Sources; then
    echo 'host dependency leaked into ImageCraft sources' >&2
    exit 1
fi
if grep -R -n -E '^import ImageIO' Sources/ImageCraftCore; then
    echo 'ImageCraftCore must remain independent of ImageIO' >&2
    exit 1
fi

swift package describe >/dev/null
scripts/verify-compatibility-contract.sh
scripts/verify-public-api.sh
python3 Tools/Corpus/verify_manifest.py Tests/ImageCraftImageIOTests/Resources/Corpus/v1/manifest.json
python3 Tools/Performance/validate_performance_baseline.py Evidence/Performance/*.json
swift test
swift build -c release
scripts/verify-imageio-evidence.sh
