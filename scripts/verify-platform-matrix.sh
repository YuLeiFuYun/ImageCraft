#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR
python3 scripts/check-swift-toolchain.py

DERIVED_DATA=${IMAGECRAFT_PLATFORM_DERIVED_DATA:-"$ROOT/.build/platform-matrix"}
rm -rf "$DERIVED_DATA"
mkdir -p "$DERIVED_DATA"

run_build() {
    label=$1
    destination=$2
    deployment_key=$3
    deployment_value=$4
    expected_target=$5
    product_directory=$6
    shift 6
    derived="$DERIVED_DATA/$label"
    log="$DERIVED_DATA/$label.log"
    if ! xcodebuild \
        -scheme ImageCraftImageIO \
        -configuration Release \
        -destination "$destination" \
        -derivedDataPath "$derived" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        "$deployment_key=$deployment_value" \
        build > "$log" 2>&1
    then
        tail -200 "$log" >&2
        exit 1
    fi
    if ! grep -F -- "$expected_target" "$log" >/dev/null; then
        echo "expected deployment target not observed for $label: $expected_target" >&2
        tail -120 "$log" >&2
        exit 1
    fi

    artifact="$derived/Build/Products/$product_directory/ImageCraftImageIO.o"
    if [ ! -f "$artifact" ]; then
        echo "missing platform artifact for $label: $artifact" >&2
        exit 1
    fi
    architectures=$(xcrun lipo -archs "$artifact")
    for required_architecture in "$@"; do
        case " $architectures " in
            *" $required_architecture "*) ;;
            *)
                echo "missing $required_architecture architecture for $label: $architectures" >&2
                exit 1
                ;;
        esac
    done
    printf 'ImageCraft platform build passed: %s [%s]\n' "$label" "$architectures"
}

run_build \
    macos \
    'generic/platform=macOS' \
    MACOSX_DEPLOYMENT_TARGET \
    12.0 \
    '-apple-macos12.0' \
    Release \
    arm64 x86_64
run_build \
    ios-simulator \
    'generic/platform=iOS Simulator' \
    IPHONEOS_DEPLOYMENT_TARGET \
    15.0 \
    '-apple-ios15.0-simulator' \
    Release-iphonesimulator \
    arm64 x86_64
run_build \
    ios-device \
    'generic/platform=iOS' \
    IPHONEOS_DEPLOYMENT_TARGET \
    15.0 \
    '-apple-ios15.0' \
    Release-iphoneos \
    arm64

printf 'ImageCraft platform matrix: cases=3 errors=0\n'
