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
rm -rf .build/out/symbolgraph
scripts/dump-public-api-symbols.sh .build/out/symbolgraph
Tools/API/normalize_public_api.py \
    --symbol-graph-directory .build/out/symbolgraph \
    --output "$TMPDIR_ROOT/PublicAPI.json"
cmp API/PublicAPI.json "$TMPDIR_ROOT/PublicAPI.json"
