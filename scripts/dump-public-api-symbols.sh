#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT=${1:?usage: dump-public-api-symbols.sh OUTPUT_DIRECTORY}

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

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT HUP INT TERM
mkdir -p "$OUTPUT"
rm -f "$OUTPUT"/*.symbols.json

cd "$ROOT"
swift build --scratch-path "$SCRATCH" --target ImageCraftImageIO >/dev/null
MODULE_PATH=$(
    find "$SCRATCH" \( -type f -o -type d \) -name ImageCraftCore.swiftmodule -print |
    while IFS= read -r CORE
    do
        CANDIDATE=$(dirname "$CORE")
        if [ -e "$CANDIDATE/ImageCraftImageIO.swiftmodule" ]; then
            printf '%s\n' "$CANDIDATE"
        fi
    done |
    head -n 1
)
if [ -z "$MODULE_PATH" ]; then
    echo 'production Swift modules were not produced in one search path' >&2
    exit 1
fi

ARCH=$(uname -m)
case "$ARCH" in
    arm64|x86_64) ;;
    *) echo "unsupported host architecture: $ARCH" >&2; exit 1 ;;
esac
TARGET="${ARCH}-apple-macosx12.0"
SDK=$(xcrun --sdk macosx --show-sdk-path)
for MODULE in ImageCraftCore ImageCraftImageIO
do
    xcrun swift-symbolgraph-extract \
        -module-name "$MODULE" \
        -target "$TARGET" \
        -sdk "$SDK" \
        -I "$MODULE_PATH" \
        -minimum-access-level public \
        -skip-synthesized-members \
        -omit-extension-block-symbols \
        -output-dir "$OUTPUT"
done
