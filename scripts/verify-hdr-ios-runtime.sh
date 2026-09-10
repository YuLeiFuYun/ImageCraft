#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

DEVELOPER_DIR=${DEVELOPER_DIR:-$(scripts/select-xcode.sh)}
export DEVELOPER_DIR

SDR_HEIF_FIXTURE="$ROOT/Tests/ImageCraftImageIOTests/Resources/Corpus/FormatBreadthV1/heif-rgba.heic"
GAINMAP_HEIF_FIXTURE="$ROOT/Tests/ImageCraftImageIOTests/Resources/Corpus/FormatBreadthV1/heif-iso-gainmap-sdr-hdr.heic"
if [ ! -f "$SDR_HEIF_FIXTURE" ] || [ ! -f "$GAINMAP_HEIF_FIXTURE" ]; then
    echo "HDR runtime fixtures are missing." >&2
    exit 1
fi

SIMULATOR_UDID=${IMAGECRAFT_IOS_HDR_SIMULATOR_UDID:-}
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

TMPDIR_ROOT=$(mktemp -d /private/tmp/imagecraft-hdr-ios-runtime.XXXXXX)
BOOTED_BY_SCRIPT=0
cleanup() {
    if [ "$BOOTED_BY_SCRIPT" -eq 1 ]; then
        xcrun simctl shutdown "$SIMULATOR_UDID" >/dev/null 2>&1 || true
    fi
    rm -rf "$TMPDIR_ROOT"
}
trap cleanup EXIT HUP INT TERM

cat > "$TMPDIR_ROOT/make-hdr.swift" <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO

@main
enum HDRFixtureGenerator {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("output path required") }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.itur_2100_PQ) else {
            fatalError("PQ color space")
        }
        guard
            let context = CGContext(
                data: nil,
                width: 2,
                height: 1,
                bitsPerComponent: 16,
                bytesPerRow: 16,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder16Little.rawValue
            )
        else { fatalError("HDR context") }
        context.setFillColor(red: 0.8, green: 0.5, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 1))
        guard let image = context.makeImage(), image.colorSpace?.isHDR() == true else {
            fatalError("HDR source image")
        }

        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output,
                "public.heic" as CFString,
                1,
                nil
            )
        else { fatalError("HEIC destination") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("HEIC finalize") }
        let data = output as Data
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
            decoded.bitsPerComponent > 8,
            decoded.colorSpace?.isHDR() == true
        else { fatalError("host HDR round trip") }
        if #available(macOS 15.0, *) {
            guard decoded.contentHeadroom > 1 else { fatalError("host HDR headroom") }
        }
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
    }
}
SWIFT

xcrun --sdk macosx swiftc \
    -parse-as-library \
    "$TMPDIR_ROOT/make-hdr.swift" \
    -o "$TMPDIR_ROOT/make-hdr"
"$TMPDIR_ROOT/make-hdr" "$TMPDIR_ROOT/direct-hdr.heic"

HDR_BASE64=$(base64 -i "$TMPDIR_ROOT/direct-hdr.heic")
SDR_BASE64=$(base64 -i "$SDR_HEIF_FIXTURE")
GAINMAP_BASE64=$(base64 -i "$GAINMAP_HEIF_FIXTURE")

mkdir -p "$TMPDIR_ROOT/consumer/Sources/HDRProbe"
cat > "$TMPDIR_ROOT/consumer/Package.swift" <<EOF
// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "ImageCraftHDRRuntimeProbe",
    platforms: [.iOS(.v15)],
    dependencies: [
        .package(path: "$ROOT"),
    ],
    targets: [
        .executableTarget(
            name: "HDRProbe",
            dependencies: [
                .product(name: "ImageCraftCore", package: "ImageCraft"),
                .product(name: "ImageCraftImageIO", package: "ImageCraft"),
            ]
        ),
    ]
)
EOF

cat > "$TMPDIR_ROOT/consumer/Sources/HDRProbe/main.swift" <<EOF
import CoreGraphics
import Darwin
import Foundation
import ImageCraftCore
import ImageCraftImageIO
import ImageIO

private let directHDRHEIC = "$HDR_BASE64"
private let sdrHEIF = "$SDR_BASE64"
private let isoGainMapHEIC = "$GAINMAP_BASE64"

private func fail(_ message: String) -> Never {
    print("FAIL: \\(message)")
    exit(1)
}

private func data(_ encoded: String) -> Data {
    guard let value = Data(base64Encoded: encoded) else { fail("embedded base64") }
    return value
}

private func requireHighFailure(_ body: () throws -> Void, _ label: String) {
    do {
        try body()
        fail("\\(label) unexpectedly succeeded")
    } catch let error as ImageCodecContractError {
        guard error == .unsupportedCapability(.dynamicRange(.high)) else {
            fail("\\(label) error classification")
        }
    } catch {
        fail("\\(label) unexpected error type")
    }
}

private func requireAuxiliaryFailure(_ body: () throws -> Void, _ label: String) {
    do {
        try body()
        fail("\\(label) unexpectedly succeeded")
    } catch let error as ImageCraftError {
        guard error == .auxiliaryAttachmentLimitExceeded else {
            fail("\\(label) error classification")
        }
    } catch {
        fail("\\(label) unexpected error type")
    }
}

@main
struct RuntimeProbe {
    static func main() throws {
        let types = Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])
        guard types.contains("public.heic") || types.contains("public.heif") else {
            fail("HEIF source is not registered")
        }

        let decoder = ImageIOImageDecoder()
        guard decoder.codecDescriptor.implementationVersion == 11 else {
            fail("unexpected ImageIO implementation version")
        }
        guard decoder.codecDescriptor.supports(
            ImageDecodeCapabilityRequest(format: .heif, dynamicRange: .high)
        ) else {
            fail("HEIF high capability is not advertised")
        }

        let hdrData = data(directHDRHEIC)
        let hdrProbe = try decoder.probe(data: hdrData, limits: .coreV1)
        guard hdrProbe.format == .heif, (hdrProbe.sourceBitsPerComponent ?? 0) > 8 else {
            fail("HDR HEIF probe")
        }

        let legacy = ImageDecodeRequest(
            target: try TargetPixels(width: 2, height: 1),
            colorPolicy: .preserveSource
        )
        requireHighFailure({
            _ = try decoder.decode(data: hdrData, probe: hdrProbe, request: legacy, limits: .coreV1)
        }, "legacy SDR request")

        let highRequest = ImageDecodeRequest(
            target: try TargetPixels(width: 2, height: 1),
            colorPolicy: .preserveSource,
            dynamicRange: .high
        )
        let high = try decoder.decode(
            data: hdrData,
            probe: hdrProbe,
            request: highRequest,
            limits: .coreV1
        )
        guard high.pixelFormat.bitsPerComponent > 8 else { fail("HDR precision collapsed") }
        guard let colorSpace = high.cgImage.colorSpace,
            colorSpace.isHDR() || CGColorSpaceUsesExtendedRange(colorSpace)
        else { fail("HDR color-space semantic") }
        if #available(iOS 18.0, *) {
            guard high.cgImage.contentHeadroom > 1 else { fail("HDR headroom") }
        }

        for contentMode in [ImageContentMode.fit, .fill] {
            let tinyRequest = ImageDecodeRequest(
                target: try TargetPixels(width: 1, height: 1),
                contentMode: contentMode,
                colorPolicy: .preserveSource,
                dynamicRange: .high
            )
            let tiny = try decoder.decode(
                data: hdrData,
                probe: hdrProbe,
                request: tinyRequest,
                limits: .coreV1
            )
            guard tiny.pixelWidth == 1, tiny.pixelHeight == 1 else {
                fail("tiny HDR geometry")
            }
            guard tiny.pixelFormat.bitsPerComponent > 8 else {
                fail("tiny HDR precision collapsed")
            }
            guard let tinyColorSpace = tiny.cgImage.colorSpace,
                tinyColorSpace.isHDR() || CGColorSpaceUsesExtendedRange(tinyColorSpace)
            else { fail("tiny HDR color-space semantic") }
            if #available(iOS 18.0, *) {
                guard tiny.cgImage.contentHeadroom > 1 else { fail("tiny HDR headroom") }
            }
        }

        let highConvert = ImageDecodeRequest(
            target: try TargetPixels(width: 2, height: 1),
            colorPolicy: .convertToSRGB,
            dynamicRange: .high
        )
        requireHighFailure({
            _ = try decoder.decode(
                data: hdrData,
                probe: hdrProbe,
                request: highConvert,
                limits: .coreV1
            )
        }, "high convertToSRGB")

        let sdrData = data(sdrHEIF)
        let sdrProbe = try decoder.probe(data: sdrData, limits: .coreV1)
        let sdrHighRequest = ImageDecodeRequest(
            target: try TargetPixels(width: sdrProbe.pixelWidth, height: sdrProbe.pixelHeight),
            colorPolicy: .preserveSource,
            dynamicRange: .high
        )
        requireHighFailure({
            _ = try decoder.decode(
                data: sdrData,
                probe: sdrProbe,
                request: sdrHighRequest,
                limits: .coreV1
            )
        }, "SDR HEIF high request")

        guard #available(iOS 18.0, *) else {
            fail("ISO gain-map qualification requires iOS 18+")
        }
        let gainMapData = data(isoGainMapHEIC)
        requireAuxiliaryFailure({
            _ = try decoder.probe(data: gainMapData, limits: .coreV1)
        }, "gain-map default auxiliary admission")

        let gainMapLimits = DecodeLimits(maximumAuxiliaryAttachments: 1)
        let gainMapProbe = try decoder.probe(data: gainMapData, limits: gainMapLimits)
        guard gainMapProbe.format == .heif,
            gainMapProbe.auxiliaryAttachmentCount == 1,
            gainMapProbe.sourceBitsPerComponent == 8
        else { fail("gain-map probe contract") }

        let gainMapStandardRequest = ImageDecodeRequest(
            target: try TargetPixels(width: 8, height: 4),
            colorPolicy: .preserveSource,
            dynamicRange: .standard
        )
        let gainMapStandard = try decoder.decode(
            data: gainMapData,
            probe: gainMapProbe,
            request: gainMapStandardRequest,
            limits: gainMapLimits
        )
        guard gainMapStandard.pixelWidth == 8, gainMapStandard.pixelHeight == 4,
            gainMapStandard.pixelFormat.bitsPerComponent == 8
        else { fail("gain-map SDR raster contract") }
        guard let gainMapStandardColorSpace = gainMapStandard.cgImage.colorSpace,
            !gainMapStandardColorSpace.isHDR(),
            !CGColorSpaceUsesExtendedRange(gainMapStandardColorSpace),
            gainMapStandard.cgImage.contentHeadroom <= 1.000_001
        else { fail("gain-map standard request escaped SDR") }

        let gainMapHighRequest = ImageDecodeRequest(
            target: try TargetPixels(width: 8, height: 4),
            colorPolicy: .preserveSource,
            dynamicRange: .high
        )
        requireHighFailure({
            _ = try decoder.decode(
                data: gainMapData,
                probe: gainMapProbe,
                request: gainMapHighRequest,
                limits: gainMapLimits
            )
        }, "iOS simulator gain-map HDR request")

        let gainMapTinyRequest = ImageDecodeRequest(
            target: try TargetPixels(width: 1, height: 1),
            colorPolicy: .preserveSource,
            dynamicRange: .high
        )
        requireHighFailure({
            _ = try decoder.decode(
                data: gainMapData,
                probe: gainMapProbe,
                request: gainMapTinyRequest,
                limits: gainMapLimits
            )
        }, "iOS simulator tiny gain-map HDR request")

        print(
            "PASS impl=11 directHDR=\\(hdrData.count)B/\\(high.pixelFormat.bitsPerComponent)bpc gainMap=\\(gainMapData.count)B aux=\\(gainMapProbe.auxiliaryAttachmentCount) simulatorGainMapHDR=fail-closed"
        )
    }
}
EOF

swift build \
    --package-path "$TMPDIR_ROOT/consumer" \
    -j 3 \
    --triple arm64-apple-ios15.0-simulator \
    -c release \
    --product HDRProbe

BIN_DIR=$(swift build \
    --package-path "$TMPDIR_ROOT/consumer" \
    --triple arm64-apple-ios15.0-simulator \
    -c release \
    --show-bin-path)
PROBE="$BIN_DIR/HDRProbe"
if [ ! -x "$PROBE" ]; then
    echo "HDR runtime probe binary was not produced." >&2
    exit 1
fi

if ! xcrun simctl list devices | grep "$SIMULATOR_UDID" | grep -q '(Booted)'; then
    xcrun simctl boot "$SIMULATOR_UDID"
    BOOTED_BY_SCRIPT=1
fi
xcrun simctl bootstatus "$SIMULATOR_UDID" -b
xcrun simctl spawn "$SIMULATOR_UDID" "$PROBE"

echo "ImageCraft HDR iOS runtime qualification passed: simulator=$SIMULATOR_UDID"
