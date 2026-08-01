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

rm -rf .build/out/symbolgraph
swift package dump-symbol-graph --skip-synthesized-members >/dev/null
Tools/API/normalize_public_api.py \
    --symbol-graph-directory .build/out/symbolgraph \
    --output API/PublicAPI.json
