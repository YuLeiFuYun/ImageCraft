import Foundation
import ImageCraftCore

enum APNGAnimationInspector {
  private static let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
  private static let pngIHDR: UInt32 = 0x4948_4452
  private static let pngPLTE: UInt32 = 0x504C_5445
  private static let pngIDAT: UInt32 = 0x4944_4154
  private static let pngIEND: UInt32 = 0x4945_4E44
  private static let pngACTL: UInt32 = 0x6163_544C
  private static let pngFCTL: UInt32 = 0x6663_544C
  private static let pngFDAT: UInt32 = 0x6664_4154

  static func inspect(
    _ bytes: UnsafeBufferPointer<UInt8>,
    byteCount: Int,
    sourceColorProfile: SourceColorProfile,
    embeddedICCProfile: Data?,
    maximumFrameCount: Int
  ) throws -> EncodedAnimationInspection {
    var offset = pngSignature.count
    var canvasWidth: Int?
    var canvasHeight: Int?
    var declaredFrameCount: UInt32?
    var loopCount = ImageAnimationLoopCount.playOnce
    var frames: [ImageAnimationFrameDescriptor] = []
    var expectedSequence: UInt32 = 0
    var foundIDAT = false
    var idatSequenceClosed = false
    var currentFrameHasData = false
    var firstFrameUsesIDAT = false
    var foundEnd = false

    while offset < bytes.count {
      guard let lengthValue = readUInt32BE(bytes, at: offset),
        let type = readUInt32BE(bytes, at: offset + 4)
      else { throw ImageCraftError.animationTimelineInvalid }
      let payloadLength = Int(lengthValue)
      let payloadStart = try advancing(offset, by: 8, limit: bytes.count)
      let payloadEnd = try advancing(payloadStart, by: payloadLength, limit: bytes.count)
      let chunkEnd = try advancing(payloadEnd, by: 4, limit: bytes.count)
      let typeStart = payloadStart - 4
      try validatePNGChunk(
        bytes,
        typeStart: typeStart,
        payloadEnd: payloadEnd
      )
      try validatePNGChunkType(bytes, type: type, typeStart: typeStart)
      if foundIDAT, type != pngIDAT {
        idatSequenceClosed = true
      }

      switch type {
      case pngIHDR:
        guard offset == pngSignature.count, payloadLength == 13,
          let width = readUInt32BE(bytes, at: payloadStart),
          let height = readUInt32BE(bytes, at: payloadStart + 4),
          width > 0, height > 0,
          let validatedWidth = Int(exactly: width),
          let validatedHeight = Int(exactly: height)
        else { throw ImageCraftError.animationTimelineInvalid }
        canvasWidth = validatedWidth
        canvasHeight = validatedHeight
      case pngACTL:
        guard !foundIDAT, declaredFrameCount == nil, payloadLength == 8,
          let frameCount = readUInt32BE(bytes, at: payloadStart),
          let playCount = readUInt32BE(bytes, at: payloadStart + 4),
          frameCount > 0
        else { throw ImageCraftError.animationTimelineInvalid }
        guard frameCount <= UInt32(maximumFrameCount) else {
          throw ImageCraftError.frameLimitExceeded
        }
        declaredFrameCount = frameCount
        loopCount =
          playCount == 0
          ? .infinite
          : ImageAnimationLoopCount(additionalRepeatCount: playCount - 1)
      case pngFCTL:
        guard declaredFrameCount != nil, payloadLength == 26,
          let width = canvasWidth, let height = canvasHeight
        else { throw ImageCraftError.animationTimelineInvalid }
        guard frames.count < maximumFrameCount else {
          throw ImageCraftError.frameLimitExceeded
        }
        if !frames.isEmpty, !currentFrameHasData {
          throw ImageCraftError.animationTimelineInvalid
        }
        guard let sequence = readUInt32BE(bytes, at: payloadStart),
          sequence == expectedSequence
        else { throw ImageCraftError.animationTimelineInvalid }
        expectedSequence &+= 1
        let descriptor = try apngFrame(
          bytes,
          payloadStart: payloadStart,
          index: frames.count,
          canvasWidth: width,
          canvasHeight: height
        )
        if frames.isEmpty, !foundIDAT { firstFrameUsesIDAT = true }
        frames.append(descriptor)
        currentFrameHasData = false
      case pngIDAT:
        guard !idatSequenceClosed,
          frames.isEmpty || (firstFrameUsesIDAT && frames.count == 1)
        else { throw ImageCraftError.animationTimelineInvalid }
        foundIDAT = true
        if firstFrameUsesIDAT { currentFrameHasData = true }
      case pngFDAT:
        guard foundIDAT, !frames.isEmpty, payloadLength >= 4,
          !(firstFrameUsesIDAT && frames.count == 1),
          let sequence = readUInt32BE(bytes, at: payloadStart),
          sequence == expectedSequence
        else { throw ImageCraftError.animationTimelineInvalid }
        expectedSequence &+= 1
        currentFrameHasData = true
      case pngIEND:
        guard payloadLength == 0 else { throw ImageCraftError.animationTimelineInvalid }
        foundEnd = true
      default:
        break
      }
      offset = chunkEnd
      if foundEnd { break }
    }

    guard foundEnd, offset == bytes.count,
      let canvasWidth, let canvasHeight,
      let declaredFrameCount,
      foundIDAT,
      currentFrameHasData,
      UInt32(frames.count) == declaredFrameCount
    else { throw ImageCraftError.animationUnsupported }
    return EncodedAnimationInspection(
      container: .apng,
      sourceColorProfile: sourceColorProfile,
      embeddedICCProfile: embeddedICCProfile,
      canvasWidth: canvasWidth,
      canvasHeight: canvasHeight,
      loopCount: loopCount,
      frames: frames,
      imageIOSourceIndicesMatchTimeline: firstFrameUsesIDAT || frames.count == 1,
      encodedByteCount: byteCount
    )
  }

  private static func apngFrame(
    _ bytes: UnsafeBufferPointer<UInt8>,
    payloadStart: Int,
    index: Int,
    canvasWidth: Int,
    canvasHeight: Int
  ) throws -> ImageAnimationFrameDescriptor {
    guard let rawWidth = readUInt32BE(bytes, at: payloadStart + 4),
      let rawHeight = readUInt32BE(bytes, at: payloadStart + 8),
      let rawX = readUInt32BE(bytes, at: payloadStart + 12),
      let rawY = readUInt32BE(bytes, at: payloadStart + 16),
      let delayNumerator = readUInt16BE(bytes, at: payloadStart + 20),
      let delayDenominator = readUInt16BE(bytes, at: payloadStart + 22),
      let width = Int(exactly: rawWidth),
      let height = Int(exactly: rawHeight),
      let x = Int(exactly: rawX),
      let y = Int(exactly: rawY)
    else { throw ImageCraftError.animationTimelineInvalid }
    let rect = try ImageAnimationFrameRect(x: x, y: y, width: width, height: height)
    guard contains(rect, canvasWidth: canvasWidth, canvasHeight: canvasHeight) else {
      throw ImageCraftError.animationFrameRectInvalid
    }
    let duration = try ImageAnimationFrameDuration(
      numerator: UInt32(delayNumerator),
      denominator: delayDenominator == 0 ? 100 : UInt32(delayDenominator)
    )
    let disposal: ImageAnimationDisposalMethod
    switch bytes[payloadStart + 24] {
    case 0: disposal = .none
    case 1: disposal = .background
    case 2: disposal = .previous
    default: throw ImageCraftError.animationTimelineInvalid
    }
    let blend: ImageAnimationBlendOperation
    switch bytes[payloadStart + 25] {
    case 0: blend = .source
    case 1: blend = .over
    default: throw ImageCraftError.animationTimelineInvalid
    }
    return try ImageAnimationFrameDescriptor(
      index: index,
      duration: duration,
      rect: rect,
      disposal: disposal,
      blend: blend
    )
  }

  private static func validatePNGChunkType(
    _ bytes: UnsafeBufferPointer<UInt8>,
    type: UInt32,
    typeStart: Int
  ) throws {
    guard typeStart >= 0, typeStart + 4 <= bytes.count else {
      throw ImageCraftError.animationTimelineInvalid
    }
    let isCritical = bytes[typeStart] & 0x20 == 0
    let hasValidReservedBit = bytes[typeStart + 2] & 0x20 == 0
    guard hasValidReservedBit else {
      throw ImageCraftError.animationTimelineInvalid
    }
    if isCritical {
      guard type == pngIHDR || type == pngPLTE || type == pngIDAT || type == pngIEND else {
        throw ImageCraftError.animationTimelineInvalid
      }
    }
  }

  private static func validatePNGChunk(
    _ bytes: UnsafeBufferPointer<UInt8>,
    typeStart: Int,
    payloadEnd: Int
  ) throws {
    guard typeStart >= 0, typeStart + 4 <= payloadEnd,
      let storedCRC = readUInt32BE(bytes, at: payloadEnd)
    else { throw ImageCraftError.animationTimelineInvalid }
    for index in typeStart..<(typeStart + 4) {
      let value = bytes[index]
      guard (65...90).contains(value) || (97...122).contains(value) else {
        throw ImageCraftError.animationTimelineInvalid
      }
    }
    guard let crc = PNGCRC32.checksum(
      bytes,
      start: typeStart,
      count: payloadEnd - typeStart
    ), crc == storedCRC else {
      throw ImageCraftError.animationTimelineInvalid
    }
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

  private static func readUInt16BE(
    _ bytes: UnsafeBufferPointer<UInt8>,
    at offset: Int
  ) -> UInt16? {
    guard offset >= 0, offset + 2 <= bytes.count else { return nil }
    return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
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

  private static func advancing(_ offset: Int, by count: Int, limit: Int) throws -> Int {
    let result = offset.addingReportingOverflow(count)
    guard count >= 0, !result.overflow, result.partialValue <= limit else {
      throw ImageCraftError.animationTimelineInvalid
    }
    return result.partialValue
  }
}
