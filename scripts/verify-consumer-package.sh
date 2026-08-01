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

FIXTURE="$ROOT/Fixtures/ConsumerSmoke"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
SWIFTPM_SCRATCH="$WORK/swiftpm"
DERIVED_ROOT=${IMAGECRAFT_CONSUMER_DERIVED_DATA:-"$WORK/derived-data"}
DERIVED_DATA="$DERIVED_ROOT/run-$$"

swift build --package-path "$FIXTURE" --scratch-path "$SWIFTPM_SCRATCH" -c release

run_xcode_build() {
    label=$1
    destination=$2
    deployment_key=$3
    deployment_value=$4
    derived="$DERIVED_DATA/$label"
    log="$DERIVED_DATA/$label.log"
    mkdir -p "$DERIVED_DATA"
    if ! (
        cd "$FIXTURE"
        xcodebuild \
            -scheme ImageCraftConsumerSmoke \
            -configuration Release \
            -destination "$destination" \
            -derivedDataPath "$derived" \
            CODE_SIGNING_ALLOWED=NO \
            CODE_SIGNING_REQUIRED=NO \
            "$deployment_key=$deployment_value" \
            build
    ) > "$log" 2>&1; then
        tail -200 "$log" >&2
        exit 1
    fi
}

run_xcode_build ios-simulator 'generic/platform=iOS Simulator' IPHONEOS_DEPLOYMENT_TARGET 15.0
run_xcode_build ios-device 'generic/platform=iOS' IPHONEOS_DEPLOYMENT_TARGET 15.0
