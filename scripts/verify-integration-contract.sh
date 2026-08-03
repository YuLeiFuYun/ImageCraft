#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR
python3 scripts/check-swift-toolchain.py

TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT HUP INT TERM
xcrun swift package describe --type json > "$TMPDIR_ROOT/root.json"
xcrun swift package --package-path Fixtures/ConsumerSmoke describe --type json \
    > "$TMPDIR_ROOT/consumer.json"
Tools/Integration/verify_platform_support.py \
    --contract Integration/PlatformSupport.json \
    --root-description "$TMPDIR_ROOT/root.json" \
    --consumer-description "$TMPDIR_ROOT/consumer.json" \
    --repository-root "$ROOT"
