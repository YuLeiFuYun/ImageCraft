import CoreGraphics
import Darwin
import Foundation
import ImageCraftCore

/// Qualification-only output ownership mode. The public decoder keeps framework-native `CGImage`
/// output until the owned payload path has broader conformance and device evidence.
package enum ImageIOOutputMaterializationMode: String, Codable, Hashable, Sendable {
    case frameworkNative
    case ownedRGBA8
}

/// Exact byte-owned RGBA8 payload used to remove framework-chosen row stride from the transfer
/// charge. Core Graphics may still allocate wrapper metadata; this type proves only the pixel
/// payload and its lifetime.
private final class ImageIOOwnedRGBAStorage: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
    let byteCount: Int

    init(byteCount: Int) throws {
        guard byteCount > 0, let pointer = malloc(byteCount) else {
            throw ImageCraftError.decodeFailed
        }
        self.pointer = pointer
        self.byteCount = byteCount
    }

    deinit {
        free(pointer)
    }
}

package enum ImageIOOwnedRGBAOutputMaterializer {
    /// Conservative pre-decode payload charge. Final fit/fill output cannot exceed both the
    /// oriented source dimensions and the requested target box.
    package static func maximumPayloadByteCharge(
        probe: ImageProbe,
        request: ImageDecodeRequest
    ) -> Int {
        let width = min(probe.pixelWidth, request.target.width)
        let height = min(probe.pixelHeight, request.target.height)
        let pixels = width.multipliedReportingOverflow(by: height)
        guard !pixels.overflow else { return Int.max }
        let bytes = pixels.partialValue.multipliedReportingOverflow(by: 4)
        return bytes.overflow ? Int.max : bytes.partialValue
    }

    package static func materialize(_ image: DecodedImage) throws -> DecodedImage {
        let cgImage = image.cgImage
        let rowBytes = cgImage.width.multipliedReportingOverflow(by: 4)
        guard !rowBytes.overflow else { throw ImageCraftError.decodeFailed }
        let byteCount = rowBytes.partialValue.multipliedReportingOverflow(by: cgImage.height)
        guard !byteCount.overflow, byteCount.partialValue > 0 else {
            throw ImageCraftError.decodeFailed
        }
        let storage = try ImageIOOwnedRGBAStorage(byteCount: byteCount.partialValue)
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ImageCraftError.decodeFailed
        }
        let outputColorSpace: CGColorSpace
        if let colorSpace = cgImage.colorSpace, colorSpace.model == .rgb {
            outputColorSpace = colorSpace
        } else {
            outputColorSpace = srgb
        }
        let alphaInfo: CGImageAlphaInfo
        switch cgImage.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            alphaInfo = .noneSkipLast
        default:
            alphaInfo = .premultipliedLast
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: alphaInfo.rawValue)
        )
        guard let context = CGContext(
            data: storage.pointer,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: rowBytes.partialValue,
            space: outputColorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw ImageCraftError.decodeFailed
        }
        context.setBlendMode(.copy)
        context.draw(
            cgImage,
            in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        )

        let retainedStorage = Unmanaged.passRetained(storage)
        guard let provider = CGDataProvider(
            dataInfo: retainedStorage.toOpaque(),
            data: storage.pointer,
            size: byteCount.partialValue,
            releaseData: { info, _, _ in
                guard let info else { return }
                Unmanaged<ImageIOOwnedRGBAStorage>.fromOpaque(info).release()
            }
        ) else {
            retainedStorage.release()
            throw ImageCraftError.decodeFailed
        }
        guard let ownedImage = CGImage(
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: rowBytes.partialValue,
            space: outputColorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: cgImage.shouldInterpolate,
            intent: cgImage.renderingIntent
        ) else {
            throw ImageCraftError.decodeFailed
        }
        guard ownedImage.dataProvider === provider,
            ownedImage.bytesPerRow == rowBytes.partialValue
        else {
            throw ImageCraftError.decodeFailed
        }
        return DecodedImage(
            cgImage: ownedImage,
            sourceColorProfile: image.colorDescription.sourceProfile
        )
    }

    package static func materializePacked(
        _ image: DecodedImage,
        colorEncoding: ImagePackedPixelColorEncoding
    ) throws -> ImagePackedRGBA8 {
        let cgImage = image.cgImage
        let rowBytes = cgImage.width.multipliedReportingOverflow(by: 4)
        guard !rowBytes.overflow else { throw ImagePackedPixelContractError.invalidBuffer }
        let byteCount = rowBytes.partialValue.multipliedReportingOverflow(by: cgImage.height)
        guard !byteCount.overflow, byteCount.partialValue > 0 else {
            throw ImagePackedPixelContractError.invalidBuffer
        }
        var data = Data(repeating: 0, count: byteCount.partialValue)
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ImageCraftError.decodeFailed
        }
        let colorSpace: CGColorSpace
        switch colorEncoding {
        case .sRGB:
            colorSpace = srgb
        case .embeddedICC(let profile):
            guard let embedded = CGColorSpace(iccData: profile as CFData), embedded.model == .rgb else {
                throw ImagePackedPixelContractError.invalidColorEncoding
            }
            colorSpace = embedded
        case .cicp:
            // Raw cICP-qualified packed values deliberately do not imply a CoreGraphics
            // materialization/transform contract. That requires a separately qualified mapping.
            throw ImagePackedPixelContractError.rasterizationUnavailable
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        let rendered = data.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                let context = CGContext(
                    data: baseAddress,
                    width: cgImage.width,
                    height: cgImage.height,
                    bitsPerComponent: 8,
                    bytesPerRow: rowBytes.partialValue,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo.rawValue
                )
            else { return false }
            // Qualification fixes row order by observed byte semantics, not by importing UIKit or
            // AppKit coordinate assumptions. Drawing a CGImage directly into this bitmap context
            // writes its first logical row to byte row zero; retained tests use asymmetric rows so
            // an accidental vertical flip is detected byte-for-byte.
            context.setBlendMode(.copy)
            context.draw(
                cgImage,
                in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
            )
            return true
        }
        guard rendered else {
            throw ImagePackedPixelContractError.rasterizationUnavailable
        }
        guard let result = ImagePackedRGBA8(
                data: data,
                pixelWidth: cgImage.width,
                pixelHeight: cgImage.height,
                colorEncoding: colorEncoding,
                sourceColorProfile: image.colorDescription.sourceProfile
            )
        else {
            throw ImagePackedPixelContractError.invalidBuffer
        }
        return result
    }
}
