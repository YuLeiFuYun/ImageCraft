import CoreGraphics
import Foundation
import ImageCraftCore

/// Qualification-only RGB8 -> `DecodedImage` materialization.
///
/// Pixel payload ownership stays with the standard packed `Data`: `CGDataProvider(data:)` retains
/// the bridged CFData and therefore can reuse the same byte backing. The result reports whether the
/// provider actually retained that backing on the current runtime instead of assuming no-copy.
/// Core Graphics wrapper allocations remain opaque, so `operationPeak` intentionally stays unknown
/// even when the byte payload itself is shared. This type is not a public decoder path.
package enum ImagePackedRGB8DecodedImageMaterializer {
    package struct Result: Sendable {
        package let image: DecodedImage
        package let resourceLedger: ImageDecodeResourceLedgerSnapshot
        package let copiedPixelPayloadByteCount: Int
        package let providerBackingWasShared: Bool
    }

    package static func materialize(_ packed: ImagePackedRGB8) throws -> Result {
        guard packed.colorEncoding == .sRGB else {
            throw ImagePackedPixelContractError.rasterizationUnavailable
        }
        let packedAddress = packed.data.withUnsafeBytes { raw -> UInt? in
            raw.baseAddress.map { UInt(bitPattern: $0) }
        }
        guard let provider = CGDataProvider(data: packed.data as CFData),
            let providerData = provider.data
        else { throw ImageCraftError.decodeFailed }
        let providerAddress = CFDataGetBytePtr(providerData).map { UInt(bitPattern: $0) }
        let providerBackingWasShared = packedAddress != nil && packedAddress == providerAddress
        let copiedPixelPayloadByteCount = providerBackingWasShared ? 0 : packed.pixelByteCharge
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ImageCraftError.decodeFailed
        }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        guard let cgImage = CGImage(
            width: packed.pixelWidth,
            height: packed.pixelHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 24,
            bytesPerRow: packed.bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ),
        cgImage.dataProvider === provider,
        cgImage.bytesPerRow == packed.bytesPerRow,
        cgImage.bitsPerPixel == 24,
        cgImage.alphaInfo == .none
        else { throw ImageCraftError.decodeFailed }

        guard let ledger = ImageDecodeResourceLedgerSnapshot(
            retainedKnownBytes: 0,
            retainedBetweenCalls: .bounded(0),
            operationPeak: .unknown(.frameworkPrivateOperationAllocation),
            transferredOutput: .bounded(packed.transferredByteCharge),
            outputLayoutAuthority: .codecOwnedRGB8
        ) else { throw ImageCraftError.decodeFailed }

        return Result(
            image: DecodedImage(
                cgImage: cgImage,
                sourceColorProfile: packed.sourceColorProfile
            ),
            resourceLedger: ledger,
            copiedPixelPayloadByteCount: copiedPixelPayloadByteCount,
            providerBackingWasShared: providerBackingWasShared
        )
    }
}
