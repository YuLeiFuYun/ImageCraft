import Foundation
import ImageCraftCore

enum WebPAnimationInspector {
  private static let riff: UInt32 = 0x5249_4646
  private static let webp: UInt32 = 0x5745_4250
  private static let vp8x: UInt32 = 0x5650_3858
  private static let anim: UInt32 = 0x414E_494D
  private static let anmf: UInt32 = 0x414E_4D46
  private static let iccp: UInt32 = 0x4943_4350
  private static let exif: UInt32 = 0x4558_4946
  private static let xmp: UInt32 = 0x584D_5020
  private static let alpha: UInt32 = 0x414C_5048
  private static let vp8: UInt32 = 0x5650_3820
  private static let vp8l: UInt32 = 0x5650_384C

  static func inspect(
    _ bytes: UnsafeBufferPointer<UInt8>,
    byteCount: Int,
    sourceColorProfile: SourceColorProfile,
    embeddedICCProfile: Data?,
    maximumFrameCount: Int
  ) throws -> EncodedAnimationInspection {
    guard bytes.count == byteCount,
      bytes.count >= 30,
      let riffSignature = readUInt32BE(bytes, at: 0),
      riffSignature == riff,
      let webpSignature = readUInt32BE(bytes, at: 8),
      webpSignature == webp,
      let riffPayloadSize = readUInt32LE(bytes, at: 4),
      UInt64(riffPayloadSize) + 8 == UInt64(bytes.count)
    else { throw ImageCraftError.animationTimelineInvalid }

    var offset = 12
    var canvasWidth: Int?
    var canvasHeight: Int?
    var featureFlags: UInt8?
    var loopCount: ImageAnimationLoopCount?
    var frames: [ImageAnimationFrameDescriptor] = []
    var sawAnimationHeader = false
    var sawICC = false
    var sawEXIF = false
    var sawXMP = false
    var sawFrameAlpha = false

    while offset < bytes.count {
      let chunk = try readChunk(bytes, at: offset, limit: bytes.count)
      switch chunk.type {
      case vp8x:
        guard offset == 12,
          featureFlags == nil,
          chunk.payloadLength == 10,
          bytes[chunk.payloadStart + 1] == 0,
          bytes[chunk.payloadStart + 2] == 0,
          bytes[chunk.payloadStart + 3] == 0
        else { throw ImageCraftError.animationTimelineInvalid }
        let flags = bytes[chunk.payloadStart]
        guard flags & 0xC1 == 0 else {
          throw ImageCraftError.animationTimelineInvalid
        }
        guard flags & 0x02 != 0 else {
          throw ImageCraftError.animationUnsupported
        }
        let width = 1 + Int(readUInt24LE(bytes, at: chunk.payloadStart + 4))
        let height = 1 + Int(readUInt24LE(bytes, at: chunk.payloadStart + 7))
        guard width > 0, height > 0 else {
          throw ImageCraftError.animationTimelineInvalid
        }
        featureFlags = flags
        canvasWidth = width
        canvasHeight = height

      case anim:
        guard featureFlags != nil,
          !sawAnimationHeader,
          frames.isEmpty,
          chunk.payloadLength == 6,
          let rawLoopCount = readUInt16LE(bytes, at: chunk.payloadStart + 4)
        else { throw ImageCraftError.animationTimelineInvalid }
        sawAnimationHeader = true
        loopCount =
          rawLoopCount == 0
          ? .infinite
          : ImageAnimationLoopCount(
            additionalRepeatCount: UInt32(rawLoopCount - 1)
          )

      case anmf:
        guard featureFlags != nil,
          sawAnimationHeader,
          let canvasWidth,
          let canvasHeight,
          frames.count < maximumFrameCount,
          chunk.payloadLength >= 16
        else {
          if frames.count >= maximumFrameCount { throw ImageCraftError.frameLimitExceeded }
          throw ImageCraftError.animationTimelineInvalid
        }
        let payload = chunk.payloadStart
        let x = 2 * Int(readUInt24LE(bytes, at: payload))
        let y = 2 * Int(readUInt24LE(bytes, at: payload + 3))
        let width = 1 + Int(readUInt24LE(bytes, at: payload + 6))
        let height = 1 + Int(readUInt24LE(bytes, at: payload + 9))
        let durationMilliseconds = readUInt24LE(bytes, at: payload + 12)
        let flags = bytes[payload + 15]
        guard flags & 0xFC == 0 else {
          throw ImageCraftError.animationTimelineInvalid
        }
        let rect = try ImageAnimationFrameRect(
          x: x,
          y: y,
          width: width,
          height: height
        )
        guard contains(rect, canvasWidth: canvasWidth, canvasHeight: canvasHeight) else {
          throw ImageCraftError.animationFrameRectInvalid
        }
        let frameUsesAlpha = try validateFrameBitstream(
          bytes,
          from: payload + 16,
          to: chunk.payloadEnd,
          width: width,
          height: height
        )
        sawFrameAlpha = sawFrameAlpha || frameUsesAlpha
        frames.append(
          try ImageAnimationFrameDescriptor(
            index: frames.count,
            duration: ImageAnimationFrameDuration(
              numerator: durationMilliseconds,
              denominator: 1_000
            ),
            rect: rect,
            disposal: flags & 0x01 == 0 ? .none : .background,
            blend: flags & 0x02 == 0 ? .over : .source
          )
        )

      case iccp:
        guard let featureFlags,
          featureFlags & 0x20 != 0,
          !sawICC
        else {
          throw ImageCraftError.animationTimelineInvalid
        }
        sawICC = true

      case exif:
        guard let featureFlags,
          featureFlags & 0x08 != 0,
          !sawEXIF
        else {
          throw ImageCraftError.animationTimelineInvalid
        }
        sawEXIF = true

      case xmp:
        guard let featureFlags,
          featureFlags & 0x04 != 0,
          !sawXMP
        else {
          throw ImageCraftError.animationTimelineInvalid
        }
        sawXMP = true

      case vp8, vp8l, alpha:
        if featureFlags == nil || !sawAnimationHeader {
          throw ImageCraftError.animationUnsupported
        }
        throw ImageCraftError.animationTimelineInvalid

      default:
        throw ImageCraftError.animationUnsupported
      }
      offset = chunk.nextOffset
    }

    guard offset == bytes.count,
      let featureFlags,
      sawAnimationHeader,
      let canvasWidth,
      let canvasHeight,
      let loopCount,
      !frames.isEmpty
    else { throw ImageCraftError.animationTimelineInvalid }
    guard (featureFlags & 0x20 != 0) == sawICC,
      (featureFlags & 0x08 != 0) == sawEXIF,
      (featureFlags & 0x04 != 0) == sawXMP,
      (featureFlags & 0x10 != 0) == sawFrameAlpha
    else { throw ImageCraftError.animationTimelineInvalid }

    return EncodedAnimationInspection(
      container: .webp,
      sourceColorProfile: sourceColorProfile,
      embeddedICCProfile: embeddedICCProfile,
      canvasWidth: canvasWidth,
      canvasHeight: canvasHeight,
      loopCount: loopCount,
      frames: frames,
      imageIOSourceIndicesMatchTimeline: true,
      encodedByteCount: byteCount
    )
  }

  private static func validateFrameBitstream(
    _ bytes: UnsafeBufferPointer<UInt8>,
    from initialOffset: Int,
    to limit: Int,
    width: Int,
    height: Int
  ) throws -> Bool {
    var offset = initialOffset
    var sawAlpha = false
    var sawImage = false
    while offset < limit {
      let chunk = try readChunk(bytes, at: offset, limit: limit)
      switch chunk.type {
      case alpha:
        guard !sawAlpha, !sawImage, chunk.payloadLength > 0 else {
          throw ImageCraftError.animationTimelineInvalid
        }
        sawAlpha = true
      case vp8:
        guard !sawImage,
          chunk.payloadLength >= 10,
          bytes[chunk.payloadStart + 3] == 0x9D,
          bytes[chunk.payloadStart + 4] == 0x01,
          bytes[chunk.payloadStart + 5] == 0x2A,
          let rawWidth = readUInt16LE(bytes, at: chunk.payloadStart + 6),
          let rawHeight = readUInt16LE(bytes, at: chunk.payloadStart + 8),
          Int(rawWidth & 0x3FFF) == width,
          Int(rawHeight & 0x3FFF) == height
        else { throw ImageCraftError.animationTimelineInvalid }
        sawImage = true
      case vp8l:
        guard !sawImage,
          !sawAlpha,
          chunk.payloadLength >= 5,
          bytes[chunk.payloadStart] == 0x2F,
          let bits = readUInt32LE(bytes, at: chunk.payloadStart + 1),
          Int(bits & 0x3FFF) + 1 == width,
          Int((bits >> 14) & 0x3FFF) + 1 == height,
          (bits >> 29) == 0
        else { throw ImageCraftError.animationTimelineInvalid }
        sawAlpha = bits & (1 << 28) != 0
        sawImage = true
      default:
        throw ImageCraftError.animationUnsupported
      }
      offset = chunk.nextOffset
    }
    guard offset == limit, sawImage else {
      throw ImageCraftError.animationTimelineInvalid
    }
    return sawAlpha
  }

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

  private static func readChunk(
    _ bytes: UnsafeBufferPointer<UInt8>,
    at offset: Int,
    limit: Int
  ) throws -> (
    type: UInt32,
    payloadStart: Int,
    payloadEnd: Int,
    payloadLength: Int,
    nextOffset: Int
  ) {
    guard offset >= 0,
      limit <= bytes.count,
      offset + 8 <= limit,
      let type = readUInt32BE(bytes, at: offset),
      let rawPayloadLength = readUInt32LE(bytes, at: offset + 4),
      UInt64(rawPayloadLength) <= UInt64(Int.max)
    else { throw ImageCraftError.animationTimelineInvalid }
    let payloadLength = Int(rawPayloadLength)
    let payloadStart = offset + 8
    let payloadEnd = payloadStart.addingReportingOverflow(payloadLength)
    guard !payloadEnd.overflow, payloadEnd.partialValue <= limit else {
      throw ImageCraftError.animationTimelineInvalid
    }
    let paddedLength = payloadLength.addingReportingOverflow(payloadLength & 1)
    guard !paddedLength.overflow else {
      throw ImageCraftError.animationTimelineInvalid
    }
    let nextOffset = payloadStart.addingReportingOverflow(paddedLength.partialValue)
    guard !nextOffset.overflow, nextOffset.partialValue <= limit else {
      throw ImageCraftError.animationTimelineInvalid
    }
    if payloadLength & 1 != 0 {
      guard payloadEnd.partialValue < limit, bytes[payloadEnd.partialValue] == 0 else {
        throw ImageCraftError.animationTimelineInvalid
      }
    }
    return (
      type,
      payloadStart,
      payloadEnd.partialValue,
      payloadLength,
      nextOffset.partialValue
    )
  }

  private static func readUInt16LE(
    _ bytes: UnsafeBufferPointer<UInt8>,
    at offset: Int
  ) -> UInt16? {
    guard offset >= 0, offset + 2 <= bytes.count else { return nil }
    return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
  }

  private static func readUInt24LE(
    _ bytes: UnsafeBufferPointer<UInt8>,
    at offset: Int
  ) -> UInt32 {
    precondition(offset >= 0 && offset + 3 <= bytes.count)
    return UInt32(bytes[offset])
      | UInt32(bytes[offset + 1]) << 8
      | UInt32(bytes[offset + 2]) << 16
  }

  private static func readUInt32LE(
    _ bytes: UnsafeBufferPointer<UInt8>,
    at offset: Int
  ) -> UInt32? {
    guard offset >= 0, offset + 4 <= bytes.count else { return nil }
    return UInt32(bytes[offset])
      | UInt32(bytes[offset + 1]) << 8
      | UInt32(bytes[offset + 2]) << 16
      | UInt32(bytes[offset + 3]) << 24
  }

  private static func readUInt32BE(
    _ bytes: UnsafeBufferPointer<UInt8>,
    at offset: Int
  ) -> UInt32? {
    guard offset >= 0, offset + 4 <= bytes.count else { return nil }
    return UInt32(bytes[offset]) << 24
      | UInt32(bytes[offset + 1]) << 16
      | UInt32(bytes[offset + 2]) << 8
      | UInt32(bytes[offset + 3])
  }
}
