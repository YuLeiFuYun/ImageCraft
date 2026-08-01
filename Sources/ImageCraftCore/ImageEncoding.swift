import CoreGraphics
import Foundation

/// 归一化的有损编码质量，闭区间为 `0...1`。
public struct ImageEncodeQuality: Codable, Hashable, Sendable {
  public let rawValue: Double

  public init(rawValue: Double) throws {
    guard rawValue.isFinite, (0...1).contains(rawValue) else {
      throw ImageEncodingError.invalidQuality
    }
    self.rawValue = rawValue
  }

  /// ImageCraft 的显式 JPEG 默认值。调用方可覆盖，但不得依赖 ImageIO 的隐式默认。
  public static let jpegDefault = ImageEncodeQuality(uncheckedRawValue: 0.9)

  private init(uncheckedRawValue: Double) {
    self.rawValue = uncheckedRawValue
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(Double.self)
    guard value.isFinite, (0...1).contains(value) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "ImageEncodeQuality must be finite and in the closed range 0...1."
      )
    }
    self.rawValue = value
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// 编码像素与容器压缩语义。
public enum ImageEncodeCompression: Codable, Hashable, Sendable {
  /// 格式必须提供无损编码。
  case lossless
  /// 格式必须提供指定质量的有损编码。
  case lossy(ImageEncodeQuality)
}

/// 编码时如何处理源色彩空间。
public enum ImageEncodeColorPolicy: String, Codable, CaseIterable, Hashable, Sendable {
  /// 保留可表达的源色彩空间；没有可信色彩空间时回退到 sRGB。
  case preserveSource
  /// 在编码前把像素转换为 sRGB。
  case convertToSRGB
}

/// 当前公开元数据策略只处理已经建模的方向，不接受任意 EXIF/XMP 字典。
public enum ImageEncodeMetadataPolicy: String, Codable, CaseIterable, Hashable, Sendable {
  /// 不写入调用方提供的方向信息。
  case discard
  /// 保留请求中显式给出的 EXIF/TIFF 方向。
  case preserveRecognized
}

/// EXIF/TIFF 方向值，合法范围固定为 `1...8`。
public struct ImageEncodeOrientation: Codable, Hashable, Sendable {
  public let rawValue: UInt32

  public init(rawValue: UInt32) throws {
    guard (1...8).contains(rawValue) else {
      throw ImageEncodingError.invalidOrientation
    }
    self.rawValue = rawValue
  }

  public static let up = ImageEncodeOrientation(uncheckedRawValue: 1)

  private init(uncheckedRawValue: UInt32) {
    self.rawValue = uncheckedRawValue
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(UInt32.self)
    guard (1...8).contains(value) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "ImageEncodeOrientation must be in the closed range 1...8."
      )
    }
    self.rawValue = value
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// 用于把透明像素合成到不支持 alpha 的目标格式上的不透明背景色。
/// 三个通道在请求最终选择的目标编码色彩空间中解释。
public struct ImageEncodeBackgroundColor: Codable, Hashable, Sendable {
  public let red: UInt8
  public let green: UInt8
  public let blue: UInt8

  public init(red: UInt8, green: UInt8, blue: UInt8) {
    self.red = red
    self.green = green
    self.blue = blue
  }

  public static let white = ImageEncodeBackgroundColor(red: 255, green: 255, blue: 255)
  public static let black = ImageEncodeBackgroundColor(red: 0, green: 0, blue: 0)
}

/// 编码时的 alpha 语义。JPEG 等无 alpha 格式不得隐式丢弃透明度。
public enum ImageEncodeAlphaPolicy: Codable, Hashable, Sendable {
  /// 保留源 alpha；目标格式不支持时失败关闭。
  case preserve
  /// 只接受没有 alpha 通道的源图像。
  case reject
  /// 先合成到显式不透明背景，再编码无 alpha 像素。
  case flatten(background: ImageEncodeBackgroundColor)

  public var behavior: ImageEncodeAlphaBehavior {
    switch self {
    case .preserve: .preserve
    case .reject: .reject
    case .flatten: .flatten
    }
  }
}

/// 不含背景色参数的有限 alpha 能力轴。
public enum ImageEncodeAlphaBehavior: String, Codable, CaseIterable, Hashable, Sendable {
  case preserve
  case reject
  case flatten
}

/// 一次静态主帧编码的完整语义请求。
public struct ImageEncodeRequest: Codable, Hashable, Sendable {
  public let format: EncodedImageFormat
  public let compression: ImageEncodeCompression
  public let colorPolicy: ImageEncodeColorPolicy
  public let metadataPolicy: ImageEncodeMetadataPolicy
  public let orientation: ImageEncodeOrientation?
  public let alphaPolicy: ImageEncodeAlphaPolicy

  public init(
    format: EncodedImageFormat,
    compression: ImageEncodeCompression,
    colorPolicy: ImageEncodeColorPolicy = .preserveSource,
    metadataPolicy: ImageEncodeMetadataPolicy = .discard,
    orientation: ImageEncodeOrientation? = nil,
    alphaPolicy: ImageEncodeAlphaPolicy = .preserve
  ) throws {
    guard metadataPolicy == .preserveRecognized || orientation == nil else {
      throw ImageEncodingError.orientationRequiresMetadataPreservation
    }
    self.format = format
    self.compression = compression
    self.colorPolicy = colorPolicy
    self.metadataPolicy = metadataPolicy
    self.orientation = orientation
    self.alphaPolicy = alphaPolicy
  }

  private enum CodingKeys: String, CodingKey {
    case format
    case compression
    case colorPolicy
    case metadataPolicy
    case orientation
    case alphaPolicy
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let format = try values.decode(EncodedImageFormat.self, forKey: .format)
    let compression = try values.decode(ImageEncodeCompression.self, forKey: .compression)
    let colorPolicy = try values.decode(ImageEncodeColorPolicy.self, forKey: .colorPolicy)
    let metadataPolicy = try values.decode(ImageEncodeMetadataPolicy.self, forKey: .metadataPolicy)
    let orientation = try values.decodeIfPresent(ImageEncodeOrientation.self, forKey: .orientation)
    let alphaPolicy = try values.decode(ImageEncodeAlphaPolicy.self, forKey: .alphaPolicy)
    guard metadataPolicy == .preserveRecognized || orientation == nil else {
      throw DecodingError.dataCorruptedError(
        forKey: .orientation,
        in: values,
        debugDescription: "Orientation requires preserveRecognized metadata policy."
      )
    }
    self.format = format
    self.compression = compression
    self.colorPolicy = colorPolicy
    self.metadataPolicy = metadataPolicy
    self.orientation = orientation
    self.alphaPolicy = alphaPolicy
  }

  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(format, forKey: .format)
    try values.encode(compression, forKey: .compression)
    try values.encode(colorPolicy, forKey: .colorPolicy)
    try values.encode(metadataPolicy, forKey: .metadataPolicy)
    try values.encodeIfPresent(orientation, forKey: .orientation)
    try values.encode(alphaPolicy, forKey: .alphaPolicy)
  }

  public static func png(
    colorPolicy: ImageEncodeColorPolicy = .preserveSource,
    metadataPolicy: ImageEncodeMetadataPolicy = .discard,
    orientation: ImageEncodeOrientation? = nil,
    alphaPolicy: ImageEncodeAlphaPolicy = .preserve
  ) throws -> Self {
    try ImageEncodeRequest(
      format: .png,
      compression: .lossless,
      colorPolicy: colorPolicy,
      metadataPolicy: metadataPolicy,
      orientation: orientation,
      alphaPolicy: alphaPolicy
    )
  }

  public static func jpeg(
    quality: ImageEncodeQuality = .jpegDefault,
    colorPolicy: ImageEncodeColorPolicy = .preserveSource,
    metadataPolicy: ImageEncodeMetadataPolicy = .discard,
    orientation: ImageEncodeOrientation? = nil,
    alphaPolicy: ImageEncodeAlphaPolicy = .preserve
  ) throws -> Self {
    try ImageEncodeRequest(
      format: .jpeg,
      compression: .lossy(quality),
      colorPolicy: colorPolicy,
      metadataPolicy: metadataPolicy,
      orientation: orientation,
      alphaPolicy: alphaPolicy
    )
  }
}

/// 编码前尺寸、像素数和输出 consumer 字节数限制。
///
/// `maximumEncodedBytes` 是适配器接受到内存输出缓冲区的机械硬上界；任何会越界的
/// ImageIO 写入都会被完整拒绝。它不等同于 ImageIO 编码器内部全部临时工作集上界。
public struct EncodeLimits: Codable, Hashable, Sendable {
  private static let maximumSupportedDimension = 65_536
  private static let maximumSupportedPixelCount = 1_000_000_000
  private static let maximumSupportedEncodedBytes = 1024 * 1024 * 1024

  public let maximumDimension: Int
  public let maximumPixelCount: Int
  public let maximumEncodedBytes: Int
  public let allowedFormats: Set<EncodedImageFormat>

  public init(
    maximumDimension: Int = 16_384,
    maximumPixelCount: Int = 100_000_000,
    maximumEncodedBytes: Int = 64 * 1024 * 1024,
    allowedFormats: Set<EncodedImageFormat> = [.png, .jpeg]
  ) {
    self.maximumDimension = min(Self.maximumSupportedDimension, max(1, maximumDimension))
    self.maximumPixelCount = min(Self.maximumSupportedPixelCount, max(1, maximumPixelCount))
    self.maximumEncodedBytes = min(
      Self.maximumSupportedEncodedBytes,
      max(1, maximumEncodedBytes)
    )
    self.allowedFormats = allowedFormats
  }

  public static let coreV1 = EncodeLimits()

  private enum CodingKeys: String, CodingKey {
    case maximumDimension
    case maximumPixelCount
    case maximumEncodedBytes
    case allowedFormats
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let maximumDimension = try values.decode(Int.self, forKey: .maximumDimension)
    let maximumPixelCount = try values.decode(Int.self, forKey: .maximumPixelCount)
    let maximumEncodedBytes = try values.decode(Int.self, forKey: .maximumEncodedBytes)
    let allowedFormats = try values.decode(Set<EncodedImageFormat>.self, forKey: .allowedFormats)
    guard (1...Self.maximumSupportedDimension).contains(maximumDimension),
      (1...Self.maximumSupportedPixelCount).contains(maximumPixelCount),
      (1...Self.maximumSupportedEncodedBytes).contains(maximumEncodedBytes)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .maximumDimension,
        in: values,
        debugDescription: "Encode limits must contain positive bounded values."
      )
    }
    self.maximumDimension = maximumDimension
    self.maximumPixelCount = maximumPixelCount
    self.maximumEncodedBytes = maximumEncodedBytes
    self.allowedFormats = allowedFormats
  }

  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(maximumDimension, forKey: .maximumDimension)
    try values.encode(maximumPixelCount, forKey: .maximumPixelCount)
    try values.encode(maximumEncodedBytes, forKey: .maximumEncodedBytes)
    try values.encode(allowedFormats, forKey: .allowedFormats)
  }
}

/// 编码后返回的不可变容器字节及其声明格式。
public struct EncodedImage: Hashable, Sendable {
  public let data: Data
  public let format: EncodedImageFormat

  public init(data: Data, format: EncodedImageFormat) {
    self.data = data
    self.format = format
  }

  public var byteCount: Int { data.count }
}

/// 编码器的稳定身份。
public struct ImageEncoderIdentifier: RawRepresentable, Codable, Hashable, Sendable,
  CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public var description: String { rawValue }
}

/// 编码器可兑现的有限能力集合。
public struct ImageEncoderCapabilities: Codable, Hashable, Sendable {
  public let formats: Set<EncodedImageFormat>
  public let losslessFormats: Set<EncodedImageFormat>
  public let lossyFormats: Set<EncodedImageFormat>
  public let alphaPreservingFormats: Set<EncodedImageFormat>
  public let alphaFlatteningFormats: Set<EncodedImageFormat>
  public let colorPolicies: Set<ImageEncodeColorPolicy>
  public let metadataPolicies: Set<ImageEncodeMetadataPolicy>

  public init(
    formats: Set<EncodedImageFormat>,
    losslessFormats: Set<EncodedImageFormat>,
    lossyFormats: Set<EncodedImageFormat>,
    alphaPreservingFormats: Set<EncodedImageFormat>,
    alphaFlatteningFormats: Set<EncodedImageFormat>,
    colorPolicies: Set<ImageEncodeColorPolicy>,
    metadataPolicies: Set<ImageEncodeMetadataPolicy>
  ) {
    self.formats = formats
    self.losslessFormats = losslessFormats
    self.lossyFormats = lossyFormats
    self.alphaPreservingFormats = alphaPreservingFormats
    self.alphaFlatteningFormats = alphaFlatteningFormats
    self.colorPolicies = colorPolicies
    self.metadataPolicies = metadataPolicies
  }
}

/// 编码请求与 descriptor 不匹配时的稳定原因。
public enum ImageEncoderSupportFailure: Codable, Equatable, Hashable, Sendable {
  case format(EncodedImageFormat)
  case compression(format: EncodedImageFormat, compression: ImageEncodeCompression)
  case colorPolicy(ImageEncodeColorPolicy)
  case metadataPolicy(ImageEncodeMetadataPolicy)
  case alphaPreservation(format: EncodedImageFormat)
  case alphaFlattening(format: EncodedImageFormat)
}

/// 编码器能力及参与输出身份的版本化描述。
public struct ImageEncoderDescriptor: Codable, Hashable, Sendable {
  public static let currentContractVersion: UInt16 = 1

  public let identifier: ImageEncoderIdentifier
  public let implementationVersion: UInt32
  public let contractVersion: UInt16
  public let capabilities: ImageEncoderCapabilities

  public init(
    identifier: ImageEncoderIdentifier,
    implementationVersion: UInt32,
    contractVersion: UInt16 = Self.currentContractVersion,
    capabilities: ImageEncoderCapabilities
  ) {
    self.identifier = identifier
    self.implementationVersion = implementationVersion
    self.contractVersion = contractVersion
    self.capabilities = capabilities
  }

  public var cacheFingerprint: String {
    "\(identifier.rawValue)#impl=\(implementationVersion)#contract=\(contractVersion)"
  }

  public func supportFailure(
    for request: ImageEncodeRequest,
    sourceHasAlpha: Bool
  ) -> ImageEncoderSupportFailure? {
    guard capabilities.formats.contains(request.format) else {
      return .format(request.format)
    }
    switch request.compression {
    case .lossless:
      guard capabilities.losslessFormats.contains(request.format) else {
        return .compression(format: request.format, compression: request.compression)
      }
    case .lossy:
      guard capabilities.lossyFormats.contains(request.format) else {
        return .compression(format: request.format, compression: request.compression)
      }
    }
    guard capabilities.colorPolicies.contains(request.colorPolicy) else {
      return .colorPolicy(request.colorPolicy)
    }
    guard capabilities.metadataPolicies.contains(request.metadataPolicy) else {
      return .metadataPolicy(request.metadataPolicy)
    }
    switch request.alphaPolicy {
    case .preserve:
      if sourceHasAlpha,
        !capabilities.alphaPreservingFormats.contains(request.format)
      {
        return .alphaPreservation(format: request.format)
      }
    case .reject:
      break
    case .flatten:
      guard capabilities.alphaFlatteningFormats.contains(request.format) else {
        return .alphaFlattening(format: request.format)
      }
    }
    return nil
  }

  public func supports(_ request: ImageEncodeRequest, sourceHasAlpha: Bool) -> Bool {
    supportFailure(for: request, sourceHasAlpha: sourceHasAlpha) == nil
  }

  public func requireSupport(_ request: ImageEncodeRequest, sourceHasAlpha: Bool) throws {
    if let failure = supportFailure(for: request, sourceHasAlpha: sourceHasAlpha) {
      throw ImageEncodingError.unsupportedCapability(failure)
    }
  }
}

/// 图像编码层的稳定失败分类。
public enum ImageEncodingError: Error, Equatable, Sendable {
  case invalidQuality
  case invalidOrientation
  case orientationRequiresMetadataPreservation
  case unsupportedCapability(ImageEncoderSupportFailure)
  case formatNotAllowed(EncodedImageFormat)
  case alphaRejected
  case dimensionLimitExceeded
  case pixelLimitExceeded
  case encodedBytesExceeded
  case colorConversionFailed
  case encodeFailed
}

/// 在显式请求和资源限制下编码单一 `CGImage`。
public protocol ImageEncoding: Sendable {
  var encoderDescriptor: ImageEncoderDescriptor { get }

  func encode(
    image: CGImage,
    request: ImageEncodeRequest,
    limits: EncodeLimits
  ) throws -> EncodedImage
}
