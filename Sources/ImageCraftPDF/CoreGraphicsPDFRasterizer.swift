import CoreGraphics
import Foundation
import ImageCraftCore

/// 基于公开 Core Graphics PDF API 的单页 PDF 光栅参考实现。
///
/// v1 只接受未加密、单页、零 page rotation 的 PDF。页面没有固定源像素，因此该实现
/// 不实现 `ImageCodec`，也不会把 PDF 伪装成 `EncodedImageFormat`。
public struct CoreGraphicsPDFRasterizer: PDFSinglePageRasterizing, Sendable {
    private static let maximumPageCoordinateMagnitude = 10_000_000.0

    public let rasterizerDescriptor: PDFRasterizerDescriptor

    public init() {
        self.rasterizerDescriptor = PDFRasterizerDescriptor(
            identifier: ImageCodecIdentifier(rawValue: "dev.imagecraft.coregraphics-pdf"),
            implementationVersion: 1
        )
    }

    public func probe(
        data: Data,
        limits: PDFRasterizationLimits
    ) throws -> PDFSinglePageProbe {
        try loadDocument(data: data, limits: limits).probe
    }

    public func rasterize(
        data: Data,
        probe: PDFSinglePageProbe,
        request: PDFRasterizationRequest,
        limits: PDFRasterizationLimits
    ) throws -> DecodedImage {
        try PDFRasterizationGeometry.validateTarget(request.target, limits: limits)
        let loaded = try loadDocument(data: data, limits: limits)
        guard loaded.probe == probe else {
            throw PDFRasterizationError.probeMismatch
        }

        let output = try PDFRasterizationGeometry.outputSize(probe: probe, request: request)
        let rowBytes = PDFRasterizationGeometry.saturatedProduct(output.width, 4)
        let byteCount = PDFRasterizationGeometry.saturatedProduct(rowBytes, output.height)
        guard rowBytes != Int.max, byteCount != Int.max else {
            throw PDFRasterizationError.targetPixelCountExceeded
        }

        var pixels = [UInt8](repeating: 0, count: byteCount)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw PDFRasterizationError.renderFailed
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )

        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: output.width,
                height: output.height,
                bitsPerComponent: 8,
                bytesPerRow: rowBytes,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else {
                return false
            }

            let outputRect = CGRect(
                x: 0,
                y: 0,
                width: output.width,
                height: output.height
            )
            context.clear(outputRect)
            context.clip(to: outputRect)

            let bounds = loaded.bounds
            let widthScale = CGFloat(output.width) / bounds.width
            let heightScale = CGFloat(output.height) / bounds.height
            let scale: CGFloat
            switch request.contentMode {
            case .fit:
                scale = min(widthScale, heightScale)
            case .fill:
                scale = max(widthScale, heightScale)
            }
            guard scale.isFinite, scale > 0 else {
                return false
            }

            let renderedWidth = bounds.width * scale
            let renderedHeight = bounds.height * scale
            let offsetX = (CGFloat(output.width) - renderedWidth) / 2
            let offsetY = (CGFloat(output.height) - renderedHeight) / 2

            context.translateBy(x: offsetX, y: offsetY)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            context.drawPDFPage(loaded.page)
            return true
        }
        guard rendered else {
            throw PDFRasterizationError.renderFailed
        }

        let rasterData = Data(pixels)
        guard let provider = CGDataProvider(data: rasterData as CFData),
            let image = CGImage(
                width: output.width,
                height: output.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: rowBytes,
                space: colorSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        else {
            throw PDFRasterizationError.renderFailed
        }

        let estimate = try resourceEstimate(probe: probe, request: request, limits: limits)
        let result = DecodedImage(cgImage: image, sourceColorProfile: .unknown)
        guard result.estimatedByteCost <= estimate.workingSetBytes else {
            throw PDFRasterizationError.renderFailed
        }
        return result
    }

    private func loadDocument(
        data: Data,
        limits: PDFRasterizationLimits
    ) throws -> LoadedPDFDocument {
        guard data.count <= limits.maximumEncodedBytes else {
            throw PDFRasterizationError.encodedBytesExceeded
        }
        guard data.count >= 5,
            data.prefix(5).elementsEqual([0x25, 0x50, 0x44, 0x46, 0x2D])
        else {
            throw PDFRasterizationError.unsupportedOrCorruptDocument
        }
        guard let provider = CGDataProvider(data: data as CFData),
            let document = CGPDFDocument(provider)
        else {
            throw PDFRasterizationError.unsupportedOrCorruptDocument
        }
        guard !document.isEncrypted else {
            throw PDFRasterizationError.encryptedDocumentUnsupported
        }
        guard document.numberOfPages == 1 else {
            throw PDFRasterizationError.multiplePagesUnsupported
        }
        guard let page = document.page(at: 1) else {
            throw PDFRasterizationError.unsupportedOrCorruptDocument
        }

        let normalizedRotation = ((page.rotationAngle % 360) + 360) % 360
        guard normalizedRotation == 0 else {
            throw PDFRasterizationError.pageRotationUnsupported
        }

        let cropBox = page.getBoxRect(.cropBox)
        let mediaBox = page.getBoxRect(.mediaBox)
        let bounds = isUsable(box: cropBox) ? cropBox : mediaBox
        try validate(bounds: bounds, limits: limits)

        let probe = PDFSinglePageProbe(
            encodedByteCount: data.count,
            pageBounds: PDFPageBounds(
                minX: Double(bounds.minX),
                minY: Double(bounds.minY),
                width: Double(bounds.width),
                height: Double(bounds.height)
            )
        )
        return LoadedPDFDocument(document: document, page: page, bounds: bounds, probe: probe)
    }

    private func isUsable(box: CGRect) -> Bool {
        box.minX.isFinite && box.minY.isFinite && box.width.isFinite && box.height.isFinite
            && box.width > 0 && box.height > 0
    }

    private func validate(
        bounds: CGRect,
        limits: PDFRasterizationLimits
    ) throws {
        guard isUsable(box: bounds) else {
            throw PDFRasterizationError.pageGeometryInvalid
        }
        guard Double(bounds.width) <= limits.maximumPageExtentUnits,
            Double(bounds.height) <= limits.maximumPageExtentUnits
        else {
            throw PDFRasterizationError.pageExtentExceeded
        }
        let coordinates = [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY]
        guard coordinates.allSatisfy({
            $0.isFinite && abs(Double($0)) <= Self.maximumPageCoordinateMagnitude
        }) else {
            throw PDFRasterizationError.pageGeometryInvalid
        }
    }
}

private struct LoadedPDFDocument {
    let document: CGPDFDocument
    let page: CGPDFPage
    let bounds: CGRect
    let probe: PDFSinglePageProbe
}
