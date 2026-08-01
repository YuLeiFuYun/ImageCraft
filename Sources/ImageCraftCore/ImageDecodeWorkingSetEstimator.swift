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
        guard probe.pixelWidth > 0, probe.pixelHeight > 0 else { return Int.max }
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
        let thumbnailBytes = saturatedProduct([thumbnailWidth, thumbnailHeight, bytesPerPixel])
        let outputWidth = min(thumbnailWidth, request.target.width)
        let outputHeight = min(thumbnailHeight, request.target.height)
        let outputBytes = saturatedProduct([outputWidth, outputHeight, bytesPerPixel])
        return saturatedSum([thumbnailBytes, thumbnailBytes, outputBytes])
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
