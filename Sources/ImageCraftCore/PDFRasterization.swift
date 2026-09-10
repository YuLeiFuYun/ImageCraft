import Foundation

/// PDF 单页光栅化的稳定失败分类。
///
/// PDF 不属于 `EncodedImageFormat`：它拥有页面与用户空间几何，而不是固定源像素网格。
public enum PDFRasterizationError: Error, Equatable, Sendable {
    case encodedBytesExceeded
    case unsupportedOrCorruptDocument
    case encryptedDocumentUnsupported
    case multiplePagesUnsupported
    case pageRotationUnsupported
    case pageGeometryInvalid
    case pageExtentExceeded
    case targetDimensionExceeded
    case targetPixelCountExceeded
    case probeMismatch
    case renderFailed
}

/// 单页 PDF 光栅化的输入与目标资源硬限制。
public struct PDFRasterizationLimits: Hashable, Sendable {
    private static let maximumSupportedEncodedBytes = 1024 * 1024 * 1024
    private static let maximumSupportedPageExtentUnits = 1_000_000.0
    private static let maximumSupportedTargetDimension = 65_536
    private static let maximumSupportedTargetPixelCount = 1_000_000_000

    /// 传入 Core Graphics PDF parser 前允许的编码字节上限。
    public let maximumEncodedBytes: Int
    /// 页面 crop/media box 单边在 PDF 默认用户空间中的最大跨度。
    public let maximumPageExtentUnits: Double
    /// 输出光栅任一像素维度的上限。
    public let maximumTargetDimension: Int
    /// 输出光栅像素总数上限。
    public let maximumTargetPixelCount: Int

    public init(
        maximumEncodedBytes: Int = 64 * 1024 * 1024,
        maximumPageExtentUnits: Double = 14_400,
        maximumTargetDimension: Int = 16_384,
        maximumTargetPixelCount: Int = 100_000_000
    ) {
        self.maximumEncodedBytes = min(
            Self.maximumSupportedEncodedBytes,
            max(1, maximumEncodedBytes)
        )
        self.maximumPageExtentUnits = min(
            Self.maximumSupportedPageExtentUnits,
            max(1, maximumPageExtentUnits.isFinite ? maximumPageExtentUnits : 1)
        )
        self.maximumTargetDimension = min(
            Self.maximumSupportedTargetDimension,
            max(1, maximumTargetDimension)
        )
        self.maximumTargetPixelCount = min(
            Self.maximumSupportedTargetPixelCount,
            max(1, maximumTargetPixelCount)
        )
    }

    public static let coreV1 = PDFRasterizationLimits()
}

/// 已验证单页 PDF 的有效页面 box，单位是 PDF 默认用户空间单位而不是源像素。
public struct PDFPageBounds: Hashable, Sendable {
    package let minX: Double
    package let minY: Double
    public let width: Double
    public let height: Double

    package init(minX: Double, minY: Double, width: Double, height: Double) {
        self.minX = minX
        self.minY = minY
        self.width = width
        self.height = height
    }
}

/// 不分配最终像素表面即可获得的单页 PDF 事实。
public struct PDFSinglePageProbe: Hashable, Sendable {
    package let encodedByteCount: Int
    public let pageBounds: PDFPageBounds

    package init(encodedByteCount: Int, pageBounds: PDFPageBounds) {
        self.encodedByteCount = encodedByteCount
        self.pageBounds = pageBounds
    }
}

/// 单页 PDF 的目标光栅语义。
///
/// 输出固定为透明背景上的 8-bpc sRGB premultiplied RGBA `CGImage`。PDF 页面可混用多个
/// 源颜色空间，因此本合同不伪造单一 `preserveSource` 色彩身份。
public struct PDFRasterizationRequest: Hashable, Sendable {
    public let target: TargetPixels
    public let contentMode: ImageContentMode

    public init(target: TargetPixels, contentMode: ImageContentMode = .fit) {
        self.target = target
        self.contentMode = contentMode
    }
}

/// PDF 光栅后端参与宿主派生缓存身份的稳定版本描述。
public struct PDFRasterizerDescriptor: Hashable, Sendable {
    public static let currentContractVersion: UInt16 = 1

    public let identifier: ImageCodecIdentifier
    public let implementationVersion: UInt32
    public let contractVersion: UInt16

    public init(
        identifier: ImageCodecIdentifier,
        implementationVersion: UInt32,
        contractVersion: UInt16 = Self.currentContractVersion
    ) {
        self.identifier = identifier
        self.implementationVersion = implementationVersion
        self.contractVersion = contractVersion
    }

    public var cacheFingerprint: String {
        "\(identifier.rawValue)#impl=\(implementationVersion)#contract=\(contractVersion)"
    }
}

/// 与固定源像素 `ImageCodec` 分离的单页 PDF 光栅化合同。
public protocol PDFSinglePageRasterizing: Sendable {
    var rasterizerDescriptor: PDFRasterizerDescriptor { get }

    func probe(
        data: Data,
        limits: PDFRasterizationLimits
    ) throws -> PDFSinglePageProbe

    /// 目标光栅的 modeled working-set charge；不声称覆盖 Core Graphics 私有 PDF parser
    /// 或绘制器内部工作内存。
    func resourceEstimate(
        probe: PDFSinglePageProbe,
        request: PDFRasterizationRequest,
        limits: PDFRasterizationLimits
    ) throws -> ImageDecodeResourceEstimate

    func rasterize(
        data: Data,
        probe: PDFSinglePageProbe,
        request: PDFRasterizationRequest,
        limits: PDFRasterizationLimits
    ) throws -> DecodedImage
}

extension PDFSinglePageRasterizing {
    public func resourceEstimate(
        probe: PDFSinglePageProbe,
        request: PDFRasterizationRequest,
        limits: PDFRasterizationLimits
    ) throws -> ImageDecodeResourceEstimate {
        try PDFRasterizationGeometry.validateTarget(request.target, limits: limits)
        let output = try PDFRasterizationGeometry.outputSize(probe: probe, request: request)
        let rowBytes = PDFRasterizationGeometry.saturatedProduct(output.width, 4)
        let surfaceBytes = PDFRasterizationGeometry.saturatedProduct(rowBytes, output.height)
        let modeledPeak = PDFRasterizationGeometry.saturatedProduct(surfaceBytes, 3)
        return try ImageDecodeResourceEstimate(workingSetBytes: modeledPeak)
    }
}

package enum PDFRasterizationGeometry {
    package static func validateTarget(
        _ target: TargetPixels,
        limits: PDFRasterizationLimits
    ) throws {
        guard target.width <= limits.maximumTargetDimension,
            target.height <= limits.maximumTargetDimension
        else {
            throw PDFRasterizationError.targetDimensionExceeded
        }
        guard target.pixelCount <= limits.maximumTargetPixelCount else {
            throw PDFRasterizationError.targetPixelCountExceeded
        }
    }

    package static func outputSize(
        probe: PDFSinglePageProbe,
        request: PDFRasterizationRequest
    ) throws -> (width: Int, height: Int) {
        let pageWidth = probe.pageBounds.width
        let pageHeight = probe.pageBounds.height
        guard pageWidth.isFinite, pageHeight.isFinite, pageWidth > 0, pageHeight > 0 else {
            throw PDFRasterizationError.pageGeometryInvalid
        }

        switch request.contentMode {
        case .fit:
            let widthScale = Double(request.target.width) / pageWidth
            let heightScale = Double(request.target.height) / pageHeight
            let scale = min(widthScale, heightScale)
            guard scale.isFinite, scale > 0 else {
                throw PDFRasterizationError.pageGeometryInvalid
            }
            let width = max(
                1,
                min(request.target.width, Int(ceil(pageWidth * scale)))
            )
            let height = max(
                1,
                min(request.target.height, Int(ceil(pageHeight * scale)))
            )
            return (width, height)
        case .fill:
            return (request.target.width, request.target.height)
        }
    }

    package static func saturatedProduct(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? Int.max : value
    }
}
