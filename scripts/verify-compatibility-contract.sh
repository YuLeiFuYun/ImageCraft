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

TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT HUP INT TERM
swift package describe --type json > "$TMPDIR_ROOT/root.json"
swift package --package-path Fixtures/ConsumerSmoke describe --type json \
    > "$TMPDIR_ROOT/consumer.json"
Tools/Compatibility/verify_platform_support.py \
    --contract Compatibility/PlatformSupport.json \
    --root-description "$TMPDIR_ROOT/root.json" \
    --consumer-description "$TMPDIR_ROOT/consumer.json" \
    --repository-root "$ROOT"
