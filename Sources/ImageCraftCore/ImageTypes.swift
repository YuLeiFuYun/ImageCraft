import CoreGraphics
import Foundation

/// 用于图像解码的已验证非零像素目标。

public struct TargetPixels: Hashable, Sendable, Codable {
    /// 已验证的水平像素尺寸。
    public let width: Int
    /// 已验证的垂直像素尺寸。
    public let height: Int

    /// 创建非零目标像素框。
    public init(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw ImageCraftError.invalidTarget }
        self.width = width
        self.height = height
    }

    /// 目标宽高中的较大值。
    public var maximumDimension: Int { max(width, height) }

    /// 目标像素面积；乘法溢出时饱和为 `Int.max`。
    public var pixelCount: Int {
        let (result, overflow) = width.multipliedReportingOverflow(by: height)
        return overflow ? Int.max : result
    }

    private enum CodingKeys: String, CodingKey {
        case width
        case height
    }

    /// 解码并重新验证两个非零维度。
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let width = try values.decode(Int.self, forKey: .width)
        let height = try values.decode(Int.self, forKey: .height)
        guard width > 0, height > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: width <= 0 ? .width : .height,
                in: values,
                debugDescription: "TargetPixels dimensions must both be greater than zero."
            )
        }
        self.width = width
        self.height = height
    }

    /// 编码已验证的目标尺寸。
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(width, forKey: .width)
        try values.encode(height, forKey: .height)
    }
}

/// 解码器契约能够识别的编码光栅格式。

public enum EncodedImageFormat: String, CaseIterable, Codable, Hashable, Sendable {
    /// PNG（便携式网络图形）格式。
    case png
    /// JPEG 光栅数据。
    case jpeg
    /// GIF（图形交换格式）数据。
    case gif
}

/// 解码前执行的元数据、像素数、尺寸与帧数硬限制。

public struct DecodeLimits: Hashable, Sendable, Codable {
    private static let maximumSupportedEncodedBytes = 1024 * 1024 * 1024
    private static let maximumSupportedDimension = 65_536
    private static let maximumSupportedPixelCount = 1_000_000_000
    private static let maximumSupportedFrameCount = 4_096
    private static let maximumSupportedMetadataBytes = 64 * 1024 * 1024
    private static let maximumSupportedAuxiliaryAttachments = 1_024

    /// Image I/O 检查前允许的编码字节硬上限。
    public let maximumEncodedBytes: Int
    /// 方向归一化后的宽或高硬上限。
    public let maximumDimension: Int
    /// 方向归一化后的像素总数硬上限。
    public let maximumPixelCount: Int
    /// 容器允许的最大帧数。
    public let maximumFrameCount: Int
    /// 允许的最大元数据占用。
    public let maximumMetadataBytes: Int
    /// 允许的最大辅助图像附件数。
    public let maximumAuxiliaryAttachments: Int
    /// 此解码策略允许的编码容器格式。
    public let allowedFormats: Set<EncodedImageFormat>

    /// 为不可信图像输入创建归一化解码限制。
    public init(
        maximumEncodedBytes: Int = 64 * 1024 * 1024,
        maximumDimension: Int = 16_384,
        maximumPixelCount: Int = 100_000_000,
        maximumFrameCount: Int = 1,
        maximumMetadataBytes: Int = 4 * 1024 * 1024,
        maximumAuxiliaryAttachments: Int = 0,
        allowedFormats: Set<EncodedImageFormat> = Set(EncodedImageFormat.allCases)
    ) {
        self.maximumEncodedBytes = min(
            Self.maximumSupportedEncodedBytes,
            max(1, maximumEncodedBytes)
        )
        self.maximumDimension = min(
            Self.maximumSupportedDimension,
            max(1, maximumDimension)
        )
        self.maximumPixelCount = min(
            Self.maximumSupportedPixelCount,
            max(1, maximumPixelCount)
        )
        self.maximumFrameCount = min(
            Self.maximumSupportedFrameCount,
            max(1, maximumFrameCount)
        )
        self.maximumMetadataBytes = min(
            Self.maximumSupportedMetadataBytes,
            max(0, maximumMetadataBytes)
        )
        self.maximumAuxiliaryAttachments = min(
            Self.maximumSupportedAuxiliaryAttachments,
            max(0, maximumAuxiliaryAttachments)
        )
        self.allowedFormats = allowedFormats
    }

    /// 阶段 0 使用的有界默认解码配置。
    public static let coreV1 = DecodeLimits()

    private enum CodingKeys: String, CodingKey {
        case maximumEncodedBytes
        case maximumDimension
        case maximumPixelCount
        case maximumFrameCount
        case maximumMetadataBytes
        case maximumAuxiliaryAttachments
        case allowedFormats
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let maximumEncodedBytes = try values.decode(Int.self, forKey: .maximumEncodedBytes)
        let maximumDimension = try values.decode(Int.self, forKey: .maximumDimension)
        let maximumPixelCount = try values.decode(Int.self, forKey: .maximumPixelCount)
        let maximumFrameCount = try values.decode(Int.self, forKey: .maximumFrameCount)
        let maximumMetadataBytes = try values.decode(Int.self, forKey: .maximumMetadataBytes)
        let maximumAuxiliaryAttachments = try values.decode(
            Int.self,
            forKey: .maximumAuxiliaryAttachments
        )
        let allowedFormats = try values.decode(
            Set<EncodedImageFormat>.self, forKey: .allowedFormats)
        guard (1...Self.maximumSupportedEncodedBytes).contains(maximumEncodedBytes),
            (1...Self.maximumSupportedDimension).contains(maximumDimension),
            (1...Self.maximumSupportedPixelCount).contains(maximumPixelCount),
            (1...Self.maximumSupportedFrameCount).contains(maximumFrameCount),
            (0...Self.maximumSupportedMetadataBytes).contains(maximumMetadataBytes),
            (0...Self.maximumSupportedAuxiliaryAttachments).contains(maximumAuxiliaryAttachments)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .maximumEncodedBytes,
                in: values,
                debugDescription: "Decode limits contain a negative or zero hard limit."
            )
        }
        self.maximumEncodedBytes = maximumEncodedBytes
        self.maximumDimension = maximumDimension
        self.maximumPixelCount = maximumPixelCount
        self.maximumFrameCount = maximumFrameCount
        self.maximumMetadataBytes = maximumMetadataBytes
        self.maximumAuxiliaryAttachments = maximumAuxiliaryAttachments
        self.allowedFormats = allowedFormats
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(maximumEncodedBytes, forKey: .maximumEncodedBytes)
        try values.encode(maximumDimension, forKey: .maximumDimension)
        try values.encode(maximumPixelCount, forKey: .maximumPixelCount)
        try values.encode(maximumFrameCount, forKey: .maximumFrameCount)
        try values.encode(maximumMetadataBytes, forKey: .maximumMetadataBytes)
        try values.encode(maximumAuxiliaryAttachments, forKey: .maximumAuxiliaryAttachments)
        try values.encode(allowedFormats, forKey: .allowedFormats)
    }
}

/// 控制解码时保留色彩配置还是执行转换。

public enum ImageColorPolicy: String, Codable, Hashable, Sendable {
    /// 保留可用的嵌入式源色彩空间。
    case preserveSource
    /// 将解码像素转换为标准 sRGB 色彩空间。
    case convertToSRGB
}

/// 源图像色彩配置的归一化描述。

public enum SourceColorProfile: String, Codable, Hashable, Sendable {
    /// 容器携带嵌入式 ICC 配置。
    case embeddedICC
    /// 容器显式声明标准 sRGB。
    case standardSRGB
    /// 不存在可信的源色彩配置。
    case absent
    /// 无法对源色彩配置分类。
    case unknown
}

/// 一次解码操作的几何与色彩语义。

public struct ImageDecodeRequest: Codable, Hashable, Sendable {
    /// 请求的输出像素框。
    public let target: TargetPixels
    /// 完整显示或裁切填充的几何规则。
    public let contentMode: ImageContentMode
    /// 请求的色彩配置处理方式。
    public let colorPolicy: ImageColorPolicy

    /// 创建字段全部参与解码身份计算的显式解码请求。
    public init(
        target: TargetPixels,
        contentMode: ImageContentMode = .fit,
        colorPolicy: ImageColorPolicy = .preserveSource
    ) {
        self.target = target
        self.contentMode = contentMode
        self.colorPolicy = colorPolicy
    }
}

/// 在显式限制下探测并解码图像字节。

public protocol ImageDecoding: Sendable {
    func probe(data: Data, limits: DecodeLimits) throws -> ImageProbe
    func decode(
        data: Data,
        probe: ImageProbe,
        request: ImageDecodeRequest,
        limits: DecodeLimits
    ) throws -> DecodedImage
}

/// 在一次安全探测与最终解码之间传递的不透明准备令牌。
///
/// 令牌由创建它的 decoder 实例拥有；调用方不能构造一个令牌并假定另一实例能够
/// 消费。准备令牌允许管线复用同一次容器检查结果，避免对大图重复扫描元数据和重复
/// 创建底层解码源。
public struct ImageDecodePreparation: Sendable {
    /// decoder 实例内一次 prepared state 的不透明身份。
    public let identifier: UUID
    /// preparation 创建时已经验证的探测事实。
    public let probe: ImageProbe

    /// 创建一个与已验证 probe 绑定的不透明令牌。
    public init(identifier: UUID = UUID(), probe: ImageProbe) {
        self.identifier = identifier
        self.probe = probe
    }
}

/// 可在安全探测后复用底层解码状态的高性能插件能力。
///
/// 实现必须保证令牌一次性消费；取消、准入失败或不再需要解码时，调用方会通过
/// ``discard(_:)`` 释放准备状态。无法提供这一能力的自定义解码器继续走标准
/// ``ImageDecoding`` 路径，不影响兼容性。
public protocol PreparedImageDecoding: ImageDecoding {
    /// 验证输入并保留仅供同一 decoder 实例一次性消费的准备状态。
    func prepare(data: Data, limits: DecodeLimits) throws -> ImageDecodePreparation
    /// 消费准备状态并执行目标解码；成功或失败后令牌均不得再次使用。
    func decode(
        preparation: ImageDecodePreparation,
        request: ImageDecodeRequest,
        limits: DecodeLimits
    ) throws -> DecodedImage
    /// 幂等释放尚未消费的准备状态。
    func discard(_ preparation: ImageDecodePreparation)
}

/// 仅供详细诊断使用的准备阶段分解；正式解码身份与公开 API 不包含这些时长。
package struct ImageDecodePreparationDiagnostics: Sendable {
    package let containerInspectionNanoseconds: UInt64
    package let imageSourceCreationNanoseconds: UInt64
    package let imageSourceTypeNanoseconds: UInt64
    package let imageFrameCountNanoseconds: UInt64
    package let imagePropertiesReadNanoseconds: UInt64
    package let probeValidationNanoseconds: UInt64

    package init(
        containerInspectionNanoseconds: UInt64,
        imageSourceCreationNanoseconds: UInt64,
        imageSourceTypeNanoseconds: UInt64,
        imageFrameCountNanoseconds: UInt64,
        imagePropertiesReadNanoseconds: UInt64,
        probeValidationNanoseconds: UInt64
    ) {
        self.containerInspectionNanoseconds = containerInspectionNanoseconds
        self.imageSourceCreationNanoseconds = imageSourceCreationNanoseconds
        self.imageSourceTypeNanoseconds = imageSourceTypeNanoseconds
        self.imageFrameCountNanoseconds = imageFrameCountNanoseconds
        self.imagePropertiesReadNanoseconds = imagePropertiesReadNanoseconds
        self.probeValidationNanoseconds = probeValidationNanoseconds
    }
}

/// 把一次性准备令牌与同一次执行产生的阶段计时绑定，避免外层重复探测。
package struct InstrumentedImageDecodePreparation: Sendable {
    package let preparation: ImageDecodePreparation
    package let diagnostics: ImageDecodePreparationDiagnostics

    package init(
        preparation: ImageDecodePreparation,
        diagnostics: ImageDecodePreparationDiagnostics
    ) {
        self.preparation = preparation
        self.diagnostics = diagnostics
    }
}

/// 仅供详细诊断使用的 prepared decode 阶段分解。
package struct ImageDecodeExecutionDiagnostics: Sendable {
    package let sourceCreationNanoseconds: UInt64
    package let sourceTypeNanoseconds: UInt64
    package let frameCountNanoseconds: UInt64
    package let rasterCreationNanoseconds: UInt64
    package let postProcessingNanoseconds: UInt64

    package init(
        sourceCreationNanoseconds: UInt64,
        sourceTypeNanoseconds: UInt64,
        frameCountNanoseconds: UInt64,
        rasterCreationNanoseconds: UInt64,
        postProcessingNanoseconds: UInt64
    ) {
        self.sourceCreationNanoseconds = sourceCreationNanoseconds
        self.sourceTypeNanoseconds = sourceTypeNanoseconds
        self.frameCountNanoseconds = frameCountNanoseconds
        self.rasterCreationNanoseconds = rasterCreationNanoseconds
        self.postProcessingNanoseconds = postProcessingNanoseconds
    }
}

/// 把解码结果与同一次 prepared decode 的阶段计时绑定。
package struct InstrumentedDecodedImage: Sendable {
    package let image: DecodedImage
    package let diagnostics: ImageDecodeExecutionDiagnostics

    package init(image: DecodedImage, diagnostics: ImageDecodeExecutionDiagnostics) {
        self.image = image
        self.diagnostics = diagnostics
    }
}

/// 解码器可选的 package-only 诊断能力；仅在真实诊断 sink 存在时调用。
package protocol InstrumentedPreparedImageDecoding: PreparedImageDecoding {
    func prepareWithDiagnostics(
        data: Data,
        limits: DecodeLimits
    ) throws -> InstrumentedImageDecodePreparation
    func decodeWithDiagnostics(
        preparation: ImageDecodePreparation,
        request: ImageDecodeRequest,
        limits: DecodeLimits
    ) throws -> InstrumentedDecodedImage
}

/// 图像表征层公开的稳定探测与解码失败。

public enum ImageCraftError: Error, Equatable, Sendable {
    case invalidTarget
    case encodedBytesExceeded
    case unsupportedOrCorruptImage
    case unsupportedFormat
    case formatMismatch
    case metadataLimitExceeded
    case auxiliaryAttachmentLimitExceeded
    case dimensionLimitExceeded
    case pixelLimitExceeded
    case frameLimitExceeded
    case probeMismatch
    case progressiveDecodingUnsupported
    case progressiveSessionFinished
    case progressiveSessionCancelled
    case decodeFailed
}

/// 无需分配最终像素缓冲区即可获得的已验证元数据。

public struct ImageProbe: Hashable, Sendable {
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let frameCount: Int
    public let orientation: UInt32
    public let format: EncodedImageFormat
    public let metadataByteCount: Int
    public let auxiliaryAttachmentCount: Int
    public let sourceColorProfile: SourceColorProfile

    public init(
        pixelWidth: Int,
        pixelHeight: Int,
        frameCount: Int,
        orientation: UInt32 = 1,
        format: EncodedImageFormat = .png,
        metadataByteCount: Int = 0,
        auxiliaryAttachmentCount: Int = 0,
        sourceColorProfile: SourceColorProfile = .unknown
    ) throws {
        guard pixelWidth > 0, pixelHeight > 0, frameCount > 0,
            (1...8).contains(orientation),
            metadataByteCount >= 0, auxiliaryAttachmentCount >= 0
        else {
            throw ImageCraftError.unsupportedOrCorruptImage
        }
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.frameCount = frameCount
        self.orientation = orientation
        self.format = format
        self.metadataByteCount = metadataByteCount
        self.auxiliaryAttachmentCount = auxiliaryAttachmentCount
        self.sourceColorProfile = sourceColorProfile
    }

    package func validate(under limits: DecodeLimits) throws {
        guard limits.allowedFormats.contains(format) else {
            throw ImageCraftError.unsupportedFormat
        }
        guard pixelWidth <= limits.maximumDimension, pixelHeight <= limits.maximumDimension else {
            throw ImageCraftError.dimensionLimitExceeded
        }
        let pixels = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        guard !pixels.overflow, pixels.partialValue <= limits.maximumPixelCount else {
            throw ImageCraftError.pixelLimitExceeded
        }
        guard frameCount <= limits.maximumFrameCount else {
            throw ImageCraftError.frameLimitExceeded
        }
        guard metadataByteCount <= limits.maximumMetadataBytes else {
            throw ImageCraftError.metadataLimitExceeded
        }
        guard auxiliaryAttachmentCount <= limits.maximumAuxiliaryAttachments else {
            throw ImageCraftError.auxiliaryAttachmentLimitExceeded
        }
    }
}

/// 解码图像的归一化色彩特征。

public struct ImageColorDescription: Hashable, Sendable {
    public let sourceProfile: SourceColorProfile
    public let outputColorSpaceName: String

    public init(sourceProfile: SourceColorProfile, outputColorSpaceName: String) {
        self.sourceProfile = sourceProfile
        self.outputColorSpaceName = outputColorSpaceName
    }
}

/// 解码像素的 Alpha 通道表示。

public enum ImageAlphaMode: String, Codable, Hashable, Sendable {
    case none
    case premultipliedFirst
    case premultipliedLast
    case straightFirst
    case straightLast
    case alphaOnly
    case unknown
}

/// 解码像素的通道布局与位深。

public struct ImagePixelFormatDescription: Hashable, Sendable {
    public let bitsPerComponent: Int
    public let bitsPerPixel: Int
    public let bytesPerRow: Int
    public let bitmapInfoRawValue: UInt32

    public init(
        bitsPerComponent: Int,
        bitsPerPixel: Int,
        bytesPerRow: Int,
        bitmapInfoRawValue: UInt32
    ) {
        self.bitsPerComponent = bitsPerComponent
        self.bitsPerPixel = bitsPerPixel
        self.bytesPerRow = bytesPerRow
        self.bitmapInfoRawValue = bitmapInfoRawValue
    }
}

/// 不可变的解码像素。受支持 SDK 会将 CoreGraphics 的 `CGImage` 导入为 `Sendable`；
/// ImageCraft 不暴露可变的底层存储，也不会在构造后修改图像。
public struct DecodedImage: Sendable {
    public let cgImage: CGImage
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let colorDescription: ImageColorDescription
    public let alphaMode: ImageAlphaMode
    public let pixelFormat: ImagePixelFormatDescription

    public init(
        cgImage: CGImage,
        sourceColorProfile: SourceColorProfile = .unknown
    ) {
        self.cgImage = cgImage
        self.pixelWidth = cgImage.width
        self.pixelHeight = cgImage.height
        self.colorDescription = ImageColorDescription(
            sourceProfile: sourceColorProfile,
            outputColorSpaceName: (cgImage.colorSpace?.name as String?) ?? "unknown"
        )
        self.alphaMode = Self.alphaMode(for: cgImage.alphaInfo)
        self.pixelFormat = ImagePixelFormatDescription(
            bitsPerComponent: cgImage.bitsPerComponent,
            bitsPerPixel: cgImage.bitsPerPixel,
            bytesPerRow: cgImage.bytesPerRow,
            bitmapInfoRawValue: cgImage.bitmapInfo.rawValue
        )
    }

    public var estimatedByteCost: Int {
        let (result, overflow) = cgImage.bytesPerRow.multipliedReportingOverflow(by: pixelHeight)
        return overflow ? Int.max : result
    }

    private static func alphaMode(for info: CGImageAlphaInfo) -> ImageAlphaMode {
        switch info {
        case .none, .noneSkipFirst, .noneSkipLast: .none
        case .premultipliedFirst: .premultipliedFirst
        case .premultipliedLast: .premultipliedLast
        case .first: .straightFirst
        case .last: .straightLast
        case .alphaOnly: .alphaOnly
        @unknown default: .unknown
        }
    }
}
