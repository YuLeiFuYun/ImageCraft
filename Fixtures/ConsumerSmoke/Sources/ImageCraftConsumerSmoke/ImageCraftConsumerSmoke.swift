import CoreGraphics
import Foundation
import ImageCraftCore
import ImageCraftImageIO

/// 只通过 ImageCraft 的公开 SwiftPM 产品编译的外部消费者烟雾目标。
public struct ImageCraftConsumerSmoke: Sendable {
  public init() {}

  public var decoderFingerprint: String {
    ImageIOImageDecoder().codecDescriptor.cacheFingerprint
  }

  public var encoderFingerprint: String {
    ImageIOImageEncoder().encoderDescriptor.cacheFingerprint
  }

  public func decodeJPEG(_ data: Data) throws -> DecodedImage {
    let target = try TargetPixels(width: 512, height: 512)
    return try ImageIOImageDecoder().decode(
      data: data,
      request: ImageDecodeRequest(
        target: target,
        contentMode: .fit,
        colorPolicy: .convertToSRGB
      ),
      limits: DecodeLimits(
        maximumEncodedBytes: 16 * 1024 * 1024,
        maximumDimension: 8_192,
        maximumPixelCount: 40_000_000,
        maximumFrameCount: 1,
        maximumMetadataBytes: 2 * 1024 * 1024,
        maximumAuxiliaryAttachments: 0,
        allowedFormats: [.jpeg]
      )
    )
  }

  public func encodePNG(_ image: CGImage) throws -> EncodedImage {
    let request = try ImageEncodeRequest.png(
      colorPolicy: .convertToSRGB,
      metadataPolicy: .discard,
      alphaPolicy: .preserve
    )
    return try ImageIOImageEncoder().encode(
      image: image,
      request: request,
      limits: EncodeLimits(
        maximumDimension: 8_192,
        maximumPixelCount: 40_000_000,
        maximumEncodedBytes: 32 * 1024 * 1024,
        allowedFormats: [.png]
      )
    )
  }
}
