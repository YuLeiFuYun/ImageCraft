import Foundation
import ImageCraftCore

struct EncodedAnimationInspection: Sendable {
  let container: ImageAnimationContainer
  let sourceColorProfile: SourceColorProfile
  let embeddedICCProfile: Data?
  let canvasWidth: Int
  let canvasHeight: Int
  let loopCount: ImageAnimationLoopCount
  let frames: [ImageAnimationFrameDescriptor]
  let imageIOSourceIndicesMatchTimeline: Bool
  let encodedByteCount: Int
}

enum AnimatedContainerInspector {
  private static let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
  private static let gif87aSignature = Array("GIF87a".utf8)
  private static let gif89aSignature = Array("GIF89a".utf8)

  static func inspect(
    _ data: Data,
    limits: ImageAnimationDecodeLimits
  ) throws -> EncodedAnimationInspection {
    guard data.count <= limits.imageLimits.maximumEncodedBytes else {
      throw ImageCraftError.encodedBytesExceeded
    }

    // Preserve animation-domain failure precedence for PNG/APNG structure. The APNG inspector owns
    // chunk CRC/type/sequence semantics and can distinguish a static PNG (`animationUnsupported`)
    // from a malformed animation timeline (`animationTimelineInvalid`). Running the generic PNG
    // security scan first would collapse both into `unsupportedOrCorruptImage` now that it also
    // validates every PNG CRC. After structural qualification, the generic scan still supplies the
    // bounded ICC/color facts used by the prepared animation value.
    if data.starts(with: pngSignature) {
      let structural = try data.withUnsafeBytes { raw in
        try APNGAnimationInspector.inspect(
          raw.bindMemory(to: UInt8.self),
          byteCount: data.count,
          sourceColorProfile: .unknown,
          embeddedICCProfile: nil,
          maximumFrameCount: limits.imageLimits.maximumFrameCount
        )
      }
      let security = try EncodedImageSecurityInspector.inspect(
        data,
        maximumMetadataBytes: limits.imageLimits.maximumMetadataBytes
      )
      guard security.format == .png,
        limits.imageLimits.allowedFormats.contains(.png)
      else { throw ImageCraftError.unsupportedFormat }
      return EncodedAnimationInspection(
        container: structural.container,
        sourceColorProfile: security.sourceColorProfile,
        embeddedICCProfile: security.embeddedICCProfile,
        canvasWidth: structural.canvasWidth,
        canvasHeight: structural.canvasHeight,
        loopCount: structural.loopCount,
        frames: structural.frames,
        imageIOSourceIndicesMatchTimeline: structural.imageIOSourceIndicesMatchTimeline,
        encodedByteCount: structural.encodedByteCount
      )
    }

    let security = try EncodedImageSecurityInspector.inspect(
      data,
      maximumMetadataBytes: limits.imageLimits.maximumMetadataBytes
    )
    guard limits.imageLimits.allowedFormats.contains(security.format) else {
      throw ImageCraftError.unsupportedFormat
    }
    return try data.withUnsafeBytes { raw in
      let bytes = raw.bindMemory(to: UInt8.self)
      if hasPrefix(bytes, gif87aSignature) || hasPrefix(bytes, gif89aSignature) {
        return try GIFAnimationInspector.inspect(
          bytes,
          byteCount: data.count,
          maximumFrameCount: limits.imageLimits.maximumFrameCount
        )
      }
      throw ImageCraftError.animationUnsupported
    }
  }

  private static func hasPrefix(
    _ bytes: UnsafeBufferPointer<UInt8>,
    _ prefix: [UInt8]
  ) -> Bool {
    guard bytes.count >= prefix.count else { return false }
    return prefix.indices.allSatisfy { bytes[$0] == prefix[$0] }
  }
}
