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

MANIFEST=Tests/ImageCraftImageIOTests/Resources/Corpus/v1/manifest.json
python3 Tools/Corpus/verify_manifest.py "$MANIFEST"
swift test --filter RetainedCorpusTests
