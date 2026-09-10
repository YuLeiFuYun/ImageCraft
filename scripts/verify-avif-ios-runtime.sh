#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

DEVELOPER_DIR=${DEVELOPER_DIR:-$(scripts/select-xcode.sh)}
export DEVELOPER_DIR

ALPHA_FIXTURE="$ROOT/Tests/ImageCraftImageIOTests/Resources/Corpus/FormatBreadthV1/avif-alpha-steps-8bit.avif"
TEN_BIT_FIXTURE="$ROOT/Tests/ImageCraftImageIOTests/Resources/Corpus/FormatBreadthV1/avif-rgb-10bit-svt-16x8.avif"

if [ ! -f "$ALPHA_FIXTURE" ] || [ ! -f "$TEN_BIT_FIXTURE" ]; then
    echo "AVIF runtime fixtures are missing." >&2
    exit 1
fi

SIMULATOR_UDID=${IMAGECRAFT_IOS_AVIF_SIMULATOR_UDID:-}
if [ -z "$SIMULATOR_UDID" ]; then
    SIMULATOR_UDID=$(
        xcrun simctl list -j devices available | python3 -c '
import json
import re
import sys

payload = json.load(sys.stdin)
devices = payload.get("devices", {})

def runtime_version(identifier):
    match = re.search(r"iOS-(\d+)(?:-(\d+))?", identifier)
    if match is None:
        return (-1, -1)
    return (int(match.group(1)), int(match.group(2) or 0))

for runtime in sorted(
    (key for key in devices if ".iOS-" in key),
    key=runtime_version,
    reverse=True,
):
    available = [
        item for item in devices[runtime]
        if item.get("isAvailable", True) and item.get("udid")
    ]
    iphones = [item for item in available if str(item.get("name", "")).startswith("iPhone")]
    candidates = iphones or available
    if candidates:
        print(candidates[0]["udid"])
        raise SystemExit(0)
raise SystemExit(1)
'
    )
fi

if [ -z "$SIMULATOR_UDID" ]; then
    echo "No available iOS simulator was found." >&2
    exit 1
fi

TMPDIR_ROOT=$(mktemp -d /private/tmp/imagecraft-avif-ios-runtime.XXXXXX)
BOOTED_BY_SCRIPT=0
cleanup() {
    if [ "$BOOTED_BY_SCRIPT" -eq 1 ]; then
        xcrun simctl shutdown "$SIMULATOR_UDID" >/dev/null 2>&1 || true
    fi
    rm -rf "$TMPDIR_ROOT"
}
trap cleanup EXIT HUP INT TERM

ALPHA_BASE64=$(base64 -i "$ALPHA_FIXTURE")
TEN_BIT_BASE64=$(base64 -i "$TEN_BIT_FIXTURE")

cat > "$TMPDIR_ROOT/probe.swift" <<EOF
import CoreGraphics
import Darwin
import Foundation
import ImageIO

private let alphaAVIF = "$ALPHA_BASE64"
private let tenBitAVIF = "$TEN_BIT_BASE64"

private func fail(_ message: String) -> Never {
    print("FAIL: \\(message)")
    exit(1)
}

private func source(_ encoded: String) -> CGImageSource {
    guard let data = Data(base64Encoded: encoded) else { fail("invalid embedded base64") }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
        fail("CGImageSourceCreateWithData")
    }
    return source
}

private func depth(_ source: CGImageSource) -> Int {
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let value = properties[kCGImagePropertyDepth] as? NSNumber
    else { return -1 }
    return value.intValue
}

private func carriesAlpha(_ image: CGImage) -> Bool {
    switch image.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast:
        return false
    default:
        return true
    }
}

@main
struct RuntimeProbe {
    static func main() {
        let types = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
        guard types.contains("public.avif") else { fail("public.avif is not registered") }

        let alphaSource = source(alphaAVIF)
        guard depth(alphaSource) == 8 else { fail("8-bit alpha fixture depth != 8") }
        guard let alphaImage = CGImageSourceCreateImageAtIndex(alphaSource, 0, nil) else {
            fail("8-bit alpha decode")
        }
        guard alphaImage.width == 4, alphaImage.height == 1, alphaImage.bitsPerComponent == 8 else {
            fail("8-bit alpha raster contract")
        }
        guard carriesAlpha(alphaImage) else { fail("8-bit alpha was dropped") }

        let highSource = source(tenBitAVIF)
        guard depth(highSource) == 10 else { fail("10-bit fixture depth != 10") }
        guard let full = CGImageSourceCreateImageAtIndex(highSource, 0, nil) else {
            fail("10-bit full decode")
        }
        guard full.width == 16, full.height == 8, full.bitsPerComponent > 8 else {
            fail("10-bit full raster contract")
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 8,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(highSource, 0, options as CFDictionary) else {
            fail("10-bit thumbnail decode")
        }
        guard thumb.width == 8, thumb.height == 4, thumb.bitsPerComponent > 8 else {
            fail("10-bit thumbnail raster contract")
        }

        print(
            "PASS public.avif=true alpha=4x1/8bpc high=\\(full.width)x\\(full.height)/\\(full.bitsPerComponent)bpc/\\(full.bitsPerPixel)bpp thumb=\\(thumb.width)x\\(thumb.height)/\\(thumb.bitsPerComponent)bpc/\\(thumb.bitsPerPixel)bpp"
        )
    }
}
EOF

xcrun --sdk iphonesimulator swiftc \
    -target arm64-apple-ios15.0-simulator \
    -parse-as-library \
    "$TMPDIR_ROOT/probe.swift" \
    -o "$TMPDIR_ROOT/probe"

if ! xcrun simctl list devices | grep "$SIMULATOR_UDID" | grep -q '(Booted)'; then
    xcrun simctl boot "$SIMULATOR_UDID"
    BOOTED_BY_SCRIPT=1
fi
xcrun simctl bootstatus "$SIMULATOR_UDID" -b
xcrun simctl spawn "$SIMULATOR_UDID" "$TMPDIR_ROOT/probe"

echo "ImageCraft AVIF iOS runtime qualification passed: simulator=$SIMULATOR_UDID"
