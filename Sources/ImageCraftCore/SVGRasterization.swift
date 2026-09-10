import Foundation

/// SVG v1 光栅化的稳定失败分类。
///
/// SVG 不属于 `EncodedImageFormat`：它拥有矢量用户空间与 `viewBox`，而不是固定源像素网格。
public enum SVGRasterizationError: Error, Equatable, Sendable {
    case encodedBytesExceeded
    case unsafeMarkup
    case unsupportedDocumentSemantics
    case malformedDocument
    case missingViewBox
    case viewBoxInvalid
    case elementLimitExceeded
    case nestingDepthExceeded
    case pathCommandLimitExceeded
    case coordinateLimitExceeded
    case targetDimensionExceeded
    case targetPixelCountExceeded
    case probeMismatch
    case renderFailed
}

/// SVG v1 的输入、结构与目标资源硬限制。
public struct SVGRasterizationLimits: Hashable, Sendable {
    private static let maximumSupportedEncodedBytes = 64 * 1024 * 1024
    private static let maximumSupportedElements = 65_536
    private static let maximumSupportedPathCommands = 1_000_000
    private static let maximumSupportedNestingDepth = 256
    private static let maximumSupportedCoordinateMagnitude = 100_000_000.0
    private static let maximumSupportedTargetDimension = 65_536
    private static let maximumSupportedTargetPixelCount = 1_000_000_000

    /// 进入 XML parser 前允许的最大编码字节数。
    public let maximumEncodedBytes: Int
    /// XML 元素总数上限。
    public let maximumElements: Int
    /// 全文 path 绘制命令总数上限。
    public let maximumPathCommands: Int
    /// 元素嵌套深度上限。
    public let maximumNestingDepth: Int
    /// viewBox、shape 与 path 坐标绝对值上限。
    public let maximumCoordinateMagnitude: Double
    /// 输出光栅任一像素维度上限。
    public let maximumTargetDimension: Int
    /// 输出光栅像素总数上限。
    public let maximumTargetPixelCount: Int

    public init(
        maximumEncodedBytes: Int = 4 * 1024 * 1024,
        maximumElements: Int = 4_096,
        maximumPathCommands: Int = 65_536,
        maximumNestingDepth: Int = 32,
        maximumCoordinateMagnitude: Double = 1_000_000,
        maximumTargetDimension: Int = 16_384,
        maximumTargetPixelCount: Int = 100_000_000
    ) {
        self.maximumEncodedBytes = min(
            Self.maximumSupportedEncodedBytes,
            max(1, maximumEncodedBytes)
        )
        self.maximumElements = min(Self.maximumSupportedElements, max(1, maximumElements))
        self.maximumPathCommands = min(
            Self.maximumSupportedPathCommands,
            max(1, maximumPathCommands)
        )
        self.maximumNestingDepth = min(
            Self.maximumSupportedNestingDepth,
            max(1, maximumNestingDepth)
        )
        self.maximumCoordinateMagnitude = min(
            Self.maximumSupportedCoordinateMagnitude,
            max(1, maximumCoordinateMagnitude.isFinite ? maximumCoordinateMagnitude : 1)
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

    public static let coreV1 = SVGRasterizationLimits()
}

/// SVG `viewBox` 的已验证用户空间范围。
public struct SVGViewBox: Hashable, Sendable {
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

/// 不分配最终像素表面即可获得的 SVG v1 事实。
public struct SVGDocumentProbe: Hashable, Sendable {
    package let encodedByteCount: Int
    public let viewBox: SVGViewBox
    package let elementCount: Int
    package let pathCommandCount: Int

    package init(
        encodedByteCount: Int,
        viewBox: SVGViewBox,
        elementCount: Int,
        pathCommandCount: Int
    ) {
        self.encodedByteCount = encodedByteCount
        self.viewBox = viewBox
        self.elementCount = elementCount
        self.pathCommandCount = pathCommandCount
    }
}

/// SVG 用户空间到目标像素表面的光栅语义。
///
/// v1 输出固定为透明背景上的 8-bpc sRGB premultiplied RGBA `CGImage`。
public struct SVGRasterizationRequest: Hashable, Sendable {
    public let target: TargetPixels
    public let contentMode: ImageContentMode

    public init(target: TargetPixels, contentMode: ImageContentMode = .fit) {
        self.target = target
        self.contentMode = contentMode
    }
}

/// SVG 光栅后端参与宿主派生身份的稳定版本描述。
public struct SVGRasterizerDescriptor: Hashable, Sendable {
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

/// 与固定源像素 `ImageCodec` 分离的 SVG v1 光栅化合同。
public protocol SVGSingleDocumentRasterizing: Sendable {
    var rasterizerDescriptor: SVGRasterizerDescriptor { get }

    func probe(
        data: Data,
        limits: SVGRasterizationLimits
    ) throws -> SVGDocumentProbe

    /// 目标光栅的 modeled working-set charge；不声称覆盖 XML/Core Graphics 私有分配。
    func resourceEstimate(
        probe: SVGDocumentProbe,
        request: SVGRasterizationRequest,
        limits: SVGRasterizationLimits
    ) throws -> ImageDecodeResourceEstimate

    func rasterize(
        data: Data,
        probe: SVGDocumentProbe,
        request: SVGRasterizationRequest,
        limits: SVGRasterizationLimits
    ) throws -> DecodedImage
}

extension SVGSingleDocumentRasterizing {
    public func resourceEstimate(
        probe: SVGDocumentProbe,
        request: SVGRasterizationRequest,
        limits: SVGRasterizationLimits
    ) throws -> ImageDecodeResourceEstimate {
        try SVGRasterizationGeometry.validateTarget(request.target, limits: limits)
        let output = try SVGRasterizationGeometry.outputSize(probe: probe, request: request)
        let rowBytes = SVGRasterizationGeometry.saturatedProduct(output.width, 4)
        let surfaceBytes = SVGRasterizationGeometry.saturatedProduct(rowBytes, output.height)
        let modeledPeak = SVGRasterizationGeometry.saturatedProduct(surfaceBytes, 3)
        return try ImageDecodeResourceEstimate(workingSetBytes: modeledPeak)
    }
}

package enum SVGRasterizationGeometry {
    package static func validateTarget(
        _ target: TargetPixels,
        limits: SVGRasterizationLimits
    ) throws {
        guard target.width <= limits.maximumTargetDimension,
            target.height <= limits.maximumTargetDimension
        else {
            throw SVGRasterizationError.targetDimensionExceeded
        }
        guard target.pixelCount <= limits.maximumTargetPixelCount else {
            throw SVGRasterizationError.targetPixelCountExceeded
        }
    }

    package static func outputSize(
        probe: SVGDocumentProbe,
        request: SVGRasterizationRequest
    ) throws -> (width: Int, height: Int) {
        let sourceWidth = probe.viewBox.width
        let sourceHeight = probe.viewBox.height
        guard sourceWidth.isFinite, sourceHeight.isFinite, sourceWidth > 0, sourceHeight > 0 else {
            throw SVGRasterizationError.viewBoxInvalid
        }

        switch request.contentMode {
        case .fit:
            let widthScale = Double(request.target.width) / sourceWidth
            let heightScale = Double(request.target.height) / sourceHeight
            let scale = min(widthScale, heightScale)
            guard scale.isFinite, scale > 0 else {
                throw SVGRasterizationError.viewBoxInvalid
            }
            let width = max(1, min(request.target.width, Int(ceil(sourceWidth * scale))))
            let height = max(1, min(request.target.height, Int(ceil(sourceHeight * scale))))
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
