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
        let thumbnailBytes = saturatedProduct(
            [geometry.thumbnailWidth, geometry.thumbnailHeight, bytesPerPixel]
        )
        let outputBytes = saturatedProduct(
            [geometry.outputWidth, geometry.outputHeight, bytesPerPixel]
        )
        return saturatedSum([thumbnailBytes, thumbnailBytes, outputBytes])
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
