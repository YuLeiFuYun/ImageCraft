import Foundation

/// 解码后端的稳定身份。它参与解码派生物与缓存身份，不能只描述容器格式。
public struct ImageCodecIdentifier: RawRepresentable, Codable, Hashable, Sendable,
    CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// 一次解码需要的交付语义。
public enum ImageDecodeDeliveryMode: String, Codable, CaseIterable, Hashable, Sendable {
    /// 只返回当前帧的完整像素。
    case completeFrame
    /// 同一帧可按严格递增的代次返回更高细节结果。
    case progressiveGenerations
}

/// 一次解码需要的轨道语义。
public enum ImageDecodeTrackMode: String, Codable, CaseIterable, Hashable, Sendable {
    /// 只消费容器的主帧；不承诺动画时间轴。
    case primaryFrame
    /// 消费带时间戳和持续时间的动画序列。
    case animatedSequence
}

/// 调用方依赖的已验证元数据。
public enum ImageDecodeMetadataCapability: String, Codable, CaseIterable, Hashable, Sendable {
    /// EXIF/TIFF 方向已经验证并参与输出语义。
    case orientation
    /// 源颜色配置已经验证并可供颜色策略使用。
    case sourceColorProfile
    /// HDR 元数据与像素语义可被可靠交付。
    case highDynamicRange
    /// 动画帧时间轴可被可靠交付。
    case frameTiming
}

/// 解码结果的动态范围语义。
public enum ImageDecodeDynamicRange: String, Codable, CaseIterable, Hashable, Sendable {
    /// 标准动态范围输出。
    case standard
    /// 保留高动态范围语义的输出。
    case high
}

/// 解码器能够交付的像素所有权/互操作表示。
public enum ImageDecodeOutputRepresentation: String, Codable, CaseIterable, Hashable, Sendable {
    /// 以不可变 `CGImage` 交付。
    case coreGraphicsImage
    /// 以平台 pixel buffer 交付。
    case pixelBuffer
    /// 以 codec 定义、contract 约束的平面像素交付。
    case planarPixels
}

/// 同步后端的取消保证。枚举顺序表示从弱到强的保证。
public enum ImageDecodeCancellationMode: Int, Codable, CaseIterable, Comparable, Hashable, Sendable
{
    /// 调用方只保证在同步后端操作前后观察取消。
    case operationBoundary = 0
    /// 后端能够中断正在执行的解码工作并释放关联资源。
    case interruptible = 1

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// codec 能力契约自身的失败，不与具体管线阶段或容器错误混为一谈。
public enum ImageCodecContractError: Error, Equatable, Sendable {
    /// 后端 descriptor 无法满足请求语义。
    case unsupportedCapability(ImageCodecSupportFailure)
    /// 后端资源估计为零、负数或无法保守表达。
    case invalidResourceEstimate
}

/// 调用方向后端提出的、与尺寸策略无关的能力需求。
public struct ImageDecodeCapabilityRequest: Codable, Hashable, Sendable {
    public let format: EncodedImageFormat
    public let deliveryMode: ImageDecodeDeliveryMode
    public let trackMode: ImageDecodeTrackMode
    public let requiredMetadata: Set<ImageDecodeMetadataCapability>
    public let dynamicRange: ImageDecodeDynamicRange
    public let outputRepresentation: ImageDecodeOutputRepresentation
    public let cancellationMode: ImageDecodeCancellationMode

    public init(
        format: EncodedImageFormat,
        deliveryMode: ImageDecodeDeliveryMode = .completeFrame,
        trackMode: ImageDecodeTrackMode = .primaryFrame,
        requiredMetadata: Set<ImageDecodeMetadataCapability> = [.orientation],
        dynamicRange: ImageDecodeDynamicRange = .standard,
        outputRepresentation: ImageDecodeOutputRepresentation = .coreGraphicsImage,
        cancellationMode: ImageDecodeCancellationMode = .operationBoundary
    ) {
        self.format = format
        self.deliveryMode = deliveryMode
        self.trackMode = trackMode
        self.requiredMetadata = requiredMetadata
        self.dynamicRange = dynamicRange
        self.outputRepresentation = outputRepresentation
        self.cancellationMode = cancellationMode
    }
}

/// 一个后端能够兑现的有限能力集合。
public struct ImageCodecCapabilities: Codable, Hashable, Sendable {
    public let formats: Set<EncodedImageFormat>
    public let deliveryModes: Set<ImageDecodeDeliveryMode>
    /// 能够交付渐进代次的格式；避免把 delivery mode 与 format 误当作笛卡尔积。
    public let progressiveFormats: Set<EncodedImageFormat>
    public let trackModes: Set<ImageDecodeTrackMode>
    public let metadata: Set<ImageDecodeMetadataCapability>
    public let dynamicRanges: Set<ImageDecodeDynamicRange>
    public let outputRepresentations: Set<ImageDecodeOutputRepresentation>
    public let cancellationMode: ImageDecodeCancellationMode

    public init(
        formats: Set<EncodedImageFormat>,
        deliveryModes: Set<ImageDecodeDeliveryMode>,
        progressiveFormats: Set<EncodedImageFormat>,
        trackModes: Set<ImageDecodeTrackMode>,
        metadata: Set<ImageDecodeMetadataCapability>,
        dynamicRanges: Set<ImageDecodeDynamicRange>,
        outputRepresentations: Set<ImageDecodeOutputRepresentation>,
        cancellationMode: ImageDecodeCancellationMode
    ) {
        self.formats = formats
        self.deliveryModes = deliveryModes
        self.progressiveFormats = progressiveFormats
        self.trackModes = trackModes
        self.metadata = metadata
        self.dynamicRanges = dynamicRanges
        self.outputRepresentations = outputRepresentations
        self.cancellationMode = cancellationMode
    }

    private enum CodingKeys: String, CodingKey {
        case formats
        case deliveryModes
        case progressiveFormats
        case trackModes
        case metadata
        case dynamicRanges
        case outputRepresentations
        case cancellationMode
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        formats = try values.decode(Set<EncodedImageFormat>.self, forKey: .formats)
        deliveryModes = try values.decode(Set<ImageDecodeDeliveryMode>.self, forKey: .deliveryModes)
        progressiveFormats = try values.decodeIfPresent(
            Set<EncodedImageFormat>.self,
            forKey: .progressiveFormats
        ) ?? []
        trackModes = try values.decode(Set<ImageDecodeTrackMode>.self, forKey: .trackModes)
        metadata = try values.decode(
            Set<ImageDecodeMetadataCapability>.self,
            forKey: .metadata
        )
        dynamicRanges = try values.decode(
            Set<ImageDecodeDynamicRange>.self,
            forKey: .dynamicRanges
        )
        outputRepresentations = try values.decode(
            Set<ImageDecodeOutputRepresentation>.self,
            forKey: .outputRepresentations
        )
        cancellationMode = try values.decode(
            ImageDecodeCancellationMode.self,
            forKey: .cancellationMode
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(formats, forKey: .formats)
        try values.encode(deliveryModes, forKey: .deliveryModes)
        try values.encode(progressiveFormats, forKey: .progressiveFormats)
        try values.encode(trackModes, forKey: .trackModes)
        try values.encode(metadata, forKey: .metadata)
        try values.encode(dynamicRanges, forKey: .dynamicRanges)
        try values.encode(outputRepresentations, forKey: .outputRepresentations)
        try values.encode(cancellationMode, forKey: .cancellationMode)
    }
}

/// 能力协商失败的可枚举原因。顺序固定，便于属性测试和稳定诊断。
public enum ImageCodecSupportFailure: Codable, Equatable, Hashable, Sendable {
    case format(EncodedImageFormat)
    case deliveryMode(ImageDecodeDeliveryMode)
    case trackMode(ImageDecodeTrackMode)
    case metadata(ImageDecodeMetadataCapability)
    case dynamicRange(ImageDecodeDynamicRange)
    case outputRepresentation(ImageDecodeOutputRepresentation)
    case cancellation(required: ImageDecodeCancellationMode, available: ImageDecodeCancellationMode)
}

/// 后端能力及其参与缓存身份的版本化描述。
public struct ImageCodecDescriptor: Codable, Hashable, Sendable {
    public static let currentContractVersion: UInt16 = 2

    public let identifier: ImageCodecIdentifier
    public let implementationVersion: UInt32
    public let contractVersion: UInt16
    public let capabilities: ImageCodecCapabilities

    public init(
        identifier: ImageCodecIdentifier,
        implementationVersion: UInt32,
        contractVersion: UInt16 = Self.currentContractVersion,
        capabilities: ImageCodecCapabilities
    ) {
        self.identifier = identifier
        self.implementationVersion = implementationVersion
        self.contractVersion = contractVersion
        self.capabilities = capabilities
    }

    /// 任何会改变像素、元数据解释或能力语义的版本变化都必须改变该值。
    public var cacheFingerprint: String {
        "\(identifier.rawValue)#impl=\(implementationVersion)#contract=\(contractVersion)"
    }

    /// 返回第一个稳定排序的能力缺口；`nil` 表示后端声明能够满足需求。
    public func supportFailure(
        for request: ImageDecodeCapabilityRequest
    ) -> ImageCodecSupportFailure? {
        guard capabilities.formats.contains(request.format) else {
            return .format(request.format)
        }
        guard capabilities.deliveryModes.contains(request.deliveryMode) else {
            return .deliveryMode(request.deliveryMode)
        }
        if request.deliveryMode == .progressiveGenerations,
            !capabilities.progressiveFormats.contains(request.format)
        {
            return .deliveryMode(request.deliveryMode)
        }
        guard capabilities.trackModes.contains(request.trackMode) else {
            return .trackMode(request.trackMode)
        }
        let missingMetadata = request.requiredMetadata
            .subtracting(capabilities.metadata)
            .sorted { $0.rawValue < $1.rawValue }
        if let missing = missingMetadata.first { return .metadata(missing) }
        guard capabilities.dynamicRanges.contains(request.dynamicRange) else {
            return .dynamicRange(request.dynamicRange)
        }
        guard capabilities.outputRepresentations.contains(request.outputRepresentation) else {
            return .outputRepresentation(request.outputRepresentation)
        }
        guard capabilities.cancellationMode >= request.cancellationMode else {
            return .cancellation(
                required: request.cancellationMode,
                available: capabilities.cancellationMode
            )
        }
        return nil
    }

    /// 判断 descriptor 是否声明支持全部请求语义。
    public func supports(_ request: ImageDecodeCapabilityRequest) -> Bool {
        supportFailure(for: request) == nil
    }

    /// 不支持时抛出稳定、可枚举的 contract failure。
    public func requireSupport(_ request: ImageDecodeCapabilityRequest) throws {
        if let failure = supportFailure(for: request) {
            throw ImageCodecContractError.unsupportedCapability(failure)
        }
    }
}

/// 解码阶段用于内存准入的保守估计。
public struct ImageDecodeResourceEstimate: Codable, Hashable, Sendable {
    public let workingSetBytes: Int

    public init(workingSetBytes: Int) throws {
        guard workingSetBytes > 0 else { throw ImageCodecContractError.invalidResourceEstimate }
        self.workingSetBytes = workingSetBytes
    }

    /// 管线永远采用通用下界与后端估计中的较大者，后端低报不能放宽准入。
    public static func conservativeMaximum(
        genericBytes: Int,
        backendBytes: Int
    ) throws -> Self {
        guard genericBytes > 0, backendBytes > 0 else {
            throw ImageCodecContractError.invalidResourceEstimate
        }
        return try ImageDecodeResourceEstimate(workingSetBytes: max(genericBytes, backendBytes))
    }
}

/// 解码后端在最低 `ImageDecoding` 之上声明稳定身份、能力和资源估计。
public protocol ImageCodec: ImageDecoding {
    /// 稳定身份、版本和能力声明；会进入派生缓存身份。
    var codecDescriptor: ImageCodecDescriptor { get }
    /// 返回该 probe/request 组合的保守峰值工作集估计。
    func resourceEstimate(
        probe: ImageProbe,
        request: ImageDecodeRequest
    ) throws -> ImageDecodeResourceEstimate
}

extension ImageCodec {
    public func resourceEstimate(
        probe: ImageProbe,
        request: ImageDecodeRequest
    ) throws -> ImageDecodeResourceEstimate {
        try ImageDecodeResourceEstimate(
            workingSetBytes: ImageDecodeWorkingSetEstimator.estimatedBytes(
                probe: probe,
                request: request
            )
        )
    }
}


/// 增量解码器产生的一个非最终像素代次。
///
/// `generation` 只表达同一会话内的严格递增顺序，不是感知质量分数，也不能在两个
/// 会话之间比较。容器 scan 排列、后端和调用方如何切分 `append(_:)` 都可能改变代次
/// 数量、返回时机和像素。`sourceByteCount` 是产生该像素的 append 结束后累计接收的
/// 字节数，可能越过真实容器边界；它不是总进度、精确 scan offset 或质量等级。
/// 最终像素仍必须由完整、已验证正文通过常规 `ImageDecoding` 路径产生。
public struct ImageProgressiveDecodeGeneration: Sendable {
    public let image: DecodedImage
    public let generation: UInt32
    public let sourceByteCount: Int

    public init(image: DecodedImage, generation: UInt32, sourceByteCount: Int) {
        self.image = image
        self.generation = generation
        self.sourceByteCount = sourceByteCount
    }
}

/// 单个编码流的状态化增量解码会话。
///
/// 会话必须并发安全，保留字节不得超过创建时的 `DecodeLimits`，取消后不得再产生像素。
/// 每次 `append(_:)` 最多返回一个代次；后端可以为控制解码放大而合并多个容器 scan。
/// 代次数量不等于容器 scan 数量，也不保证不同 chunk partition 产生相同数量。若完整
/// 正文和结束标记在产生中间像素前已经到达，会话可以不返回任何代次。`finish()` 只封闭
/// 增量会话，不替代完整正文的安全检查与最终解码。
public protocol ImageProgressiveDecodeSession: AnyObject, Sendable {
    var receivedByteCount: Int { get }
    func append(_ chunk: Data) throws -> ImageProgressiveDecodeGeneration?
    func finish() throws
    func cancel()
}

/// codec 可选的真实增量像素能力。
public protocol ProgressiveImageDecoding: ImageCodec {
    func makeProgressiveSession(
        format: EncodedImageFormat,
        request: ImageDecodeRequest,
        limits: DecodeLimits
    ) throws -> any ImageProgressiveDecodeSession
}
