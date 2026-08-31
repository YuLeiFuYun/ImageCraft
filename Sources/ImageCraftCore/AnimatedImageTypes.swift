import Foundation

/// 动画容器或帧序列的稳定类别。
public enum ImageAnimationContainer: String, Codable, CaseIterable, Hashable, Sendable {
  /// GIF89a 多帧容器。
  case gif
  /// 带 acTL/fcTL/fdAT 动画块的 PNG。
  case apng
  /// 由独立 JPEG 完整帧组成的 Motion-JPEG 风格序列。
  case jpegSequence
}

/// 精确保留容器帧时长的有理数秒值。
public struct ImageAnimationFrameDuration: Codable, Hashable, Sendable {
  public let numerator: UInt32
  public let denominator: UInt32

  public init(numerator: UInt32, denominator: UInt32) throws {
    guard denominator > 0 else { throw ImageCraftError.animationTimelineInvalid }
    let divisor = Self.greatestCommonDivisor(numerator, denominator)
    self.numerator = numerator / divisor
    self.denominator = denominator / divisor
  }

  /// 向上取整到纳秒，避免非零源时长在整数换算时退化为零。
  public var roundedUpNanoseconds: UInt64 {
    let product = UInt64(numerator).multipliedReportingOverflow(by: 1_000_000_000)
    guard !product.overflow else { return UInt64.max }
    let divisor = UInt64(denominator)
    let quotient = product.partialValue / divisor
    let remainder = product.partialValue % divisor
    return remainder == 0 ? quotient : quotient &+ 1
  }

  private enum CodingKeys: String, CodingKey {
    case numerator
    case denominator
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let numerator = try values.decode(UInt32.self, forKey: .numerator)
    let denominator = try values.decode(UInt32.self, forKey: .denominator)
    do {
      self = try Self(numerator: numerator, denominator: denominator)
    } catch {
      throw DecodingError.dataCorruptedError(
        forKey: .denominator,
        in: values,
        debugDescription: "Animation frame duration requires a nonzero denominator."
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(numerator, forKey: .numerator)
    try values.encode(denominator, forKey: .denominator)
  }

  private static func greatestCommonDivisor(_ lhs: UInt32, _ rhs: UInt32) -> UInt32 {
    var a = lhs
    var b = rhs
    while b != 0 {
      let remainder = a % b
      a = b
      b = remainder
    }
    return max(1, a)
  }
}

/// 统一为“首轮播放后额外重复次数”；`nil` 表示无限重复。
public struct ImageAnimationLoopCount: Codable, Hashable, Sendable {
  public let additionalRepeatCount: UInt32?

  public init(additionalRepeatCount: UInt32?) {
    self.additionalRepeatCount = additionalRepeatCount
  }

  public static let infinite = ImageAnimationLoopCount(additionalRepeatCount: nil)
  public static let playOnce = ImageAnimationLoopCount(additionalRepeatCount: 0)
  public var isInfinite: Bool { additionalRepeatCount == nil }

  private enum CodingKeys: String, CodingKey {
    case additionalRepeatCount
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    guard values.contains(.additionalRepeatCount) else {
      throw DecodingError.keyNotFound(
        CodingKeys.additionalRepeatCount,
        DecodingError.Context(
          codingPath: values.codingPath,
          debugDescription: "Animation loop count requires an explicit finite value or null."
        )
      )
    }
    if try values.decodeNil(forKey: .additionalRepeatCount) {
      self = .infinite
    } else {
      self.init(
        additionalRepeatCount: try values.decode(
          UInt32.self,
          forKey: .additionalRepeatCount
        )
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    if let additionalRepeatCount {
      try values.encode(additionalRepeatCount, forKey: .additionalRepeatCount)
    } else {
      try values.encodeNil(forKey: .additionalRepeatCount)
    }
  }
}

/// 动画帧在源 canvas 中、以左上角为原点的整数矩形。
public struct ImageAnimationFrameRect: Codable, Hashable, Sendable {
  public let x: Int
  public let y: Int
  public let width: Int
  public let height: Int

  public init(x: Int, y: Int, width: Int, height: Int) throws {
    guard x >= 0, y >= 0, width > 0, height > 0 else {
      throw ImageCraftError.animationFrameRectInvalid
    }
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  private enum CodingKeys: String, CodingKey {
    case x
    case y
    case width
    case height
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let x = try values.decode(Int.self, forKey: .x)
    let y = try values.decode(Int.self, forKey: .y)
    let width = try values.decode(Int.self, forKey: .width)
    let height = try values.decode(Int.self, forKey: .height)
    do {
      self = try Self(x: x, y: y, width: width, height: height)
    } catch {
      throw DecodingError.dataCorruptedError(
        forKey: .width,
        in: values,
        debugDescription: "Animation frame rectangle requires nonnegative origin and positive size."
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(x, forKey: .x)
    try values.encode(y, forKey: .y)
    try values.encode(width, forKey: .width)
    try values.encode(height, forKey: .height)
  }
}

/// 一帧显示结束后对其覆盖区域执行的 disposal 语义。
public enum ImageAnimationDisposalMethod: String, Codable, CaseIterable, Hashable, Sendable {
  case none
  case background
  case previous
}

/// 当前帧像素与已有 canvas 的组合方式。
public enum ImageAnimationBlendOperation: String, Codable, CaseIterable, Hashable, Sendable {
  case source
  case over
}

/// 一帧的精确时间、区域和合成元数据。
public struct ImageAnimationFrameDescriptor: Codable, Hashable, Sendable {
  public let index: Int
  public let duration: ImageAnimationFrameDuration
  public let rect: ImageAnimationFrameRect
  public let disposal: ImageAnimationDisposalMethod
  public let blend: ImageAnimationBlendOperation

  public init(
    index: Int,
    duration: ImageAnimationFrameDuration,
    rect: ImageAnimationFrameRect,
    disposal: ImageAnimationDisposalMethod,
    blend: ImageAnimationBlendOperation
  ) throws {
    guard index >= 0 else { throw ImageCraftError.animationTimelineInvalid }
    self.index = index
    self.duration = duration
    self.rect = rect
    self.disposal = disposal
    self.blend = blend
  }

  private enum CodingKeys: String, CodingKey {
    case index
    case duration
    case rect
    case disposal
    case blend
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let index = try values.decode(Int.self, forKey: .index)
    let duration = try values.decode(ImageAnimationFrameDuration.self, forKey: .duration)
    let rect = try values.decode(ImageAnimationFrameRect.self, forKey: .rect)
    let disposal = try values.decode(ImageAnimationDisposalMethod.self, forKey: .disposal)
    let blend = try values.decode(ImageAnimationBlendOperation.self, forKey: .blend)
    do {
      self = try Self(
        index: index,
        duration: duration,
        rect: rect,
        disposal: disposal,
        blend: blend
      )
    } catch {
      throw DecodingError.dataCorruptedError(
        forKey: .index,
        in: values,
        debugDescription: "Animation frame descriptor requires a nonnegative index."
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(index, forKey: .index)
    try values.encode(duration, forKey: .duration)
    try values.encode(rect, forKey: .rect)
    try values.encode(disposal, forKey: .disposal)
    try values.encode(blend, forKey: .blend)
  }
}

/// 已验证动画轨道的不可变元数据。
public struct ImageAnimationMetadata: Hashable, Sendable {
  public let container: ImageAnimationContainer
  public let canvasWidth: Int
  public let canvasHeight: Int
  public let loopCount: ImageAnimationLoopCount
  public let frames: [ImageAnimationFrameDescriptor]
  public let encodedByteCount: Int
  public let codecFingerprint: String

  public init(
    container: ImageAnimationContainer,
    canvasWidth: Int,
    canvasHeight: Int,
    loopCount: ImageAnimationLoopCount,
    frames: [ImageAnimationFrameDescriptor],
    encodedByteCount: Int,
    codecFingerprint: String
  ) throws {
    guard canvasWidth > 0, canvasHeight > 0,
      encodedByteCount > 0,
      !codecFingerprint.isEmpty,
      codecFingerprint.utf8.count <= 1_024,
      codecFingerprint.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }),
      !frames.isEmpty
    else { throw ImageCraftError.animationTimelineInvalid }
    for (expected, frame) in frames.enumerated() {
      guard frame.index == expected,
        Self.contains(frame.rect, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
      else { throw ImageCraftError.animationFrameRectInvalid }
    }
    self.container = container
    self.canvasWidth = canvasWidth
    self.canvasHeight = canvasHeight
    self.loopCount = loopCount
    self.frames = frames
    self.encodedByteCount = encodedByteCount
    self.codecFingerprint = codecFingerprint
  }

  public var frameCount: Int { frames.count }

  private static func contains(
    _ rect: ImageAnimationFrameRect,
    canvasWidth: Int,
    canvasHeight: Int
  ) -> Bool {
    let right = rect.x.addingReportingOverflow(rect.width)
    let bottom = rect.y.addingReportingOverflow(rect.height)
    return !right.overflow && !bottom.overflow
      && right.partialValue <= canvasWidth
      && bottom.partialValue <= canvasHeight
  }
}

/// 动画轨道的独立资源边界；不会改变静态图默认 `DecodeLimits.coreV1`。
public struct ImageAnimationDecodeLimits: Hashable, Sendable {
  public let imageLimits: DecodeLimits
  public let maximumTimelineDecodedBytes: Int
  public let maximumFrameDecodeWindow: Int

  public init(
    imageLimits: DecodeLimits = DecodeLimits(
      maximumEncodedBytes: 64 * 1024 * 1024,
      maximumDimension: 8_192,
      maximumPixelCount: 32_000_000,
      maximumFrameCount: 256,
      maximumMetadataBytes: 4 * 1024 * 1024,
      maximumAuxiliaryAttachments: 0,
      allowedFormats: Set(EncodedImageFormat.allCases)
    ),
    maximumTimelineDecodedBytes: Int = 512 * 1024 * 1024,
    maximumFrameDecodeWindow: Int = 8
  ) {
    self.imageLimits = imageLimits
    self.maximumTimelineDecodedBytes = min(
      4 * 1024 * 1024 * 1024,
      max(1, maximumTimelineDecodedBytes)
    )
    self.maximumFrameDecodeWindow = min(64, max(1, maximumFrameDecodeWindow))
  }
}

/// Motion-JPEG 风格序列中的一个完整 JPEG 帧与显示时长。
public struct ImageJPEGAnimationFrame: Sendable {
  public let data: Data
  public let duration: ImageAnimationFrameDuration

  public init(data: Data, duration: ImageAnimationFrameDuration) {
    self.data = data
    self.duration = duration
  }
}

/// 动画输入既可为单一 GIF/APNG 容器，也可为上层已完成分帧的 JPEG 序列。
public enum ImageAnimationSource: Sendable {
  case encoded(Data)
  case jpegSequence(
    frames: [ImageJPEGAnimationFrame],
    loopCount: ImageAnimationLoopCount
  )
}

/// 一次按需解码得到的完整合成帧。
public struct DecodedAnimationFrame: Sendable {
  public let image: DecodedImage
  public let descriptor: ImageAnimationFrameDescriptor

  public init(image: DecodedImage, descriptor: ImageAnimationFrameDescriptor) {
    self.image = image
    self.descriptor = descriptor
  }
}

package protocol ImageAnimationFrameProviding: Sendable {
  func frame(at index: Int, request: ImageDecodeRequest) async throws -> DecodedAnimationFrame
  func frames(
    in range: Range<Int>,
    request: ImageDecodeRequest
  ) async throws -> [DecodedAnimationFrame]
  func cancel() async
}

/// Proven cost bounds for decoding an entire animation track under one request.
///
/// `residentDecodedByteCostUpperBound` bounds the sum of `DecodedImage.estimatedByteCost` for the
/// returned track. `providerRetainedByteCostUpperBound` separately bounds retained encoded payload,
/// palette/checkpoint bytes, or equivalent backend state that remains alive with the prepared asset.
/// `predecodePeakByteCostUpperBound` additionally includes conservative transient/materialization
/// costs for the backend's configured frame-decode window. These are admission costs, not
/// measurements of process RSS or system energy.
public struct ImageAnimationWholeTrackCostEstimate: Hashable, Sendable {
  public let residentDecodedByteCostUpperBound: Int
  public let providerRetainedByteCostUpperBound: Int
  public let predecodePeakByteCostUpperBound: Int

  package init?(
    residentDecodedByteCostUpperBound: Int,
    providerRetainedByteCostUpperBound: Int,
    predecodePeakByteCostUpperBound: Int
  ) {
    let steadyState = residentDecodedByteCostUpperBound.addingReportingOverflow(
      providerRetainedByteCostUpperBound
    )
    guard residentDecodedByteCostUpperBound > 0,
      providerRetainedByteCostUpperBound >= 0,
      !steadyState.overflow,
      predecodePeakByteCostUpperBound >= steadyState.partialValue
    else { return nil }
    self.residentDecodedByteCostUpperBound = residentDecodedByteCostUpperBound
    self.providerRetainedByteCostUpperBound = providerRetainedByteCostUpperBound
    self.predecodePeakByteCostUpperBound = predecodePeakByteCostUpperBound
  }
}

/// 已准备的动画资产；元数据不可变，帧按需解码且可整体取消。
public struct AnimatedImageAsset: Sendable {
  public let metadata: ImageAnimationMetadata
  private let provider: any ImageAnimationFrameProviding
  private let wholeTrackCostEstimateProvider:
    @Sendable (ImageDecodeRequest) -> ImageAnimationWholeTrackCostEstimate?

  package init(
    metadata: ImageAnimationMetadata,
    provider: any ImageAnimationFrameProviding,
    wholeTrackCostEstimateProvider:
      @escaping @Sendable (ImageDecodeRequest)
      -> ImageAnimationWholeTrackCostEstimate? = { _ in nil }
  ) {
    self.metadata = metadata
    self.provider = provider
    self.wholeTrackCostEstimateProvider = wholeTrackCostEstimateProvider
  }

  /// Returns no-decode whole-track admission bounds when the selected backend can prove both
  /// resident decoded cost and bounded predecode peak cost. `nil` is a deliberate fail-closed
  /// result: callers must not infer either cost from target geometry alone.
  public func wholeTrackCostEstimate(
    for request: ImageDecodeRequest
  ) -> ImageAnimationWholeTrackCostEstimate? {
    wholeTrackCostEstimateProvider(request)
  }

  public func frame(
    at index: Int,
    request: ImageDecodeRequest
  ) async throws -> DecodedAnimationFrame {
    try await provider.frame(at: index, request: request)
  }

  /// 在后端配置的有界窗口内批量解码连续帧，减少逐帧调度开销。
  public func frames(
    in range: Range<Int>,
    request: ImageDecodeRequest
  ) async throws -> [DecodedAnimationFrame] {
    try await provider.frames(in: range, request: request)
  }

  public func cancel() async {
    await provider.cancel()
  }
}

/// 与静态 `ImageDecoding` 分离的动画轨道解码契约。
public protocol ImageAnimationDecoding: Sendable {
  var codecDescriptor: ImageCodecDescriptor { get }

  func prepareAnimation(
    source: ImageAnimationSource,
    limits: ImageAnimationDecodeLimits
  ) async throws -> AnimatedImageAsset
}
