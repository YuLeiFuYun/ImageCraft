import Foundation

/// 对当前 ImageIO 静态图路径的峰值像素工作集做保守上界估算。
///
/// 估算包含缩略表面、可能发生的颜色转换表面以及 fill 裁剪/最终表面；编码数据、
/// RenderedMemory 和系统框架内部固定开销由各自预算单独管理。
package enum ImageDecodeWorkingSetEstimator {
    package static func estimatedBytes(
        probe: ImageProbe,
        request: ImageDecodeRequest,
        bytesPerPixel: Int = 4
    ) -> Int {
        guard let geometry = estimatedGeometry(probe: probe, request: request) else {
            return Int.max
        }
        let sourceBytesPerComponent: Int
        switch probe.sourceBitsPerComponent {
        case .some(...8):
            sourceBytesPerComponent = 1
        case .some(...16):
            sourceBytesPerComponent = 2
        default:
            // Unknown source precision and values wider than 16 bits use the conservative
            // 32-bit component lane. This avoids silently preserving the old 4-B/px
            // under-reservation for third-party backends that still use the legacy probe init.
            sourceBytesPerComponent = 4
        }
        let sourceRGBABytesPerPixel = saturatedProduct([sourceBytesPerComponent, 4])
        // A gain-map-backed source may have an 8-bit SDR primary raster while an explicit `.high`
        // request materializes a 10/16-bpc HDR CGImage. The primary source precision therefore
        // cannot by itself bound HDR output storage. Reserve at least 16-bit RGBA lanes for every
        // high-range request; this also remains conservative for packed 10-bpc/32-bpp ImageIO
        // layouts observed on other high-depth sources.
        let dynamicRangeBytesPerPixel = request.dynamicRange == .high ? 8 : bytesPerPixel
        let effectiveBytesPerPixel = max(
            bytesPerPixel,
            sourceRGBABytesPerPixel,
            dynamicRangeBytesPerPixel
        )
        let thumbnailBytes = saturatedProduct(
            [geometry.thumbnailWidth, geometry.thumbnailHeight, effectiveBytesPerPixel]
        )
        let outputBytes = saturatedProduct(
            [geometry.outputWidth, geometry.outputHeight, effectiveBytesPerPixel]
        )
        let ordinaryPeak = saturatedSum([thumbnailBytes, thumbnailBytes, outputBytes])

        // Some ImageIO backends (currently HEIF/HEIC on the pinned Apple runtime) can refuse
        // thumbnail requests below a small implementation floor even though a slightly larger
        // bounded thumbnail succeeds. The ImageIO adapter may therefore hold one <=4x4 fallback
        // surface while materializing the true requested raster. Keep that constant-size path in
        // the generic host estimate so a tiny target never under-reserves its actual peak.
        let smallFallbackBytes = saturatedProduct(
            [min(probe.pixelWidth, 4), min(probe.pixelHeight, 4), effectiveBytesPerPixel]
        )
        let smallFallbackPeak = saturatedSum([smallFallbackBytes, outputBytes])
        return max(ordinaryPeak, smallFallbackPeak)
    }

    private static func estimatedGeometry(
        probe: ImageProbe,
        request: ImageDecodeRequest
    ) -> (thumbnailWidth: Int, thumbnailHeight: Int, outputWidth: Int, outputHeight: Int)? {
        guard probe.pixelWidth > 0, probe.pixelHeight > 0 else { return nil }
        let widthScale = Double(request.target.width) / Double(probe.pixelWidth)
        let heightScale = Double(request.target.height) / Double(probe.pixelHeight)
        let requestedScale: Double
        switch request.contentMode {
        case .fit:
            requestedScale = min(widthScale, heightScale)
        case .fill:
            requestedScale = max(widthScale, heightScale)
        }
        let scale = min(1, max(0, requestedScale))
        let thumbnailWidth = max(
            1,
            min(probe.pixelWidth, Int(ceil(Double(probe.pixelWidth) * scale)))
        )
        let thumbnailHeight = max(
            1,
            min(probe.pixelHeight, Int(ceil(Double(probe.pixelHeight) * scale)))
        )
        let outputWidth = min(thumbnailWidth, request.target.width)
        let outputHeight = min(thumbnailHeight, request.target.height)
        return (thumbnailWidth, thumbnailHeight, outputWidth, outputHeight)
    }

    /// Progressive qualification uses a pre-probe tight-RGBA model. This intentionally does not
    /// claim a complete ImageIO operation bound: framework-private allocation and returned
    /// `CGImage.bytesPerRow` are represented as unknown by the phase resource ledger.
    package static func maximumModeledPixelWorkingSetBytes(
        limits: DecodeLimits,
        bytesPerPixel: Int = 4
    ) -> Int {
        saturatedProduct([limits.maximumPixelCount, max(1, bytesPerPixel), 3])
    }

    package static func maximumTightRGBABytes(
        limits: DecodeLimits,
        bytesPerPixel: Int = 4
    ) -> Int {
        saturatedProduct([limits.maximumPixelCount, max(1, bytesPerPixel)])
    }

    private static func saturatedProduct(_ values: [Int]) -> Int {
        values.reduce(1) { partial, value in
            let (result, overflow) = partial.multipliedReportingOverflow(by: max(0, value))
            return overflow ? Int.max : result
        }
    }

    private static func saturatedSum(_ values: [Int]) -> Int {
        values.reduce(0) { partial, value in
            let (result, overflow) = partial.addingReportingOverflow(value)
            return overflow ? Int.max : result
        }
    }
}
