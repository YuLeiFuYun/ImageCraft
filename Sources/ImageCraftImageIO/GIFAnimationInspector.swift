import Foundation
import ImageCraftCore

enum GIFAnimationInspector {
  private struct GIFControl {
    let duration: ImageAnimationFrameDuration
    let disposal: ImageAnimationDisposalMethod
    let blend: ImageAnimationBlendOperation
  }

  static func inspect(
    _ bytes: UnsafeBufferPointer<UInt8>,
    byteCount: Int,
    maximumFrameCount: Int
  ) throws -> EncodedAnimationInspection {
    guard bytes.count >= 13,
      let rawWidth = readUInt16LE(bytes, at: 6),
      let rawHeight = readUInt16LE(bytes, at: 8),
      rawWidth > 0, rawHeight > 0
    else { throw ImageCraftError.animationTimelineInvalid }
    let canvasWidth = Int(rawWidth)
    let canvasHeight = Int(rawHeight)
    var offset = 13
    if bytes[10] & 0x80 != 0 {
      offset = try advancing(
        offset,
        by: 3 * (1 << (Int(bytes[10] & 0x07) + 1)),
        limit: bytes.count
      )
    }
    var loopCount = ImageAnimationLoopCount.playOnce
    var frames: [ImageAnimationFrameDescriptor] = []
    var pendingControl: GIFControl?

    while offset < bytes.count {
      let marker = bytes[offset]
      offset += 1
      switch marker {
      case 0x3B:
        guard offset == bytes.count, !frames.isEmpty, pendingControl == nil else {
          throw ImageCraftError.animationTimelineInvalid
        }
        return EncodedAnimationInspection(
          container: .gif,
          sourceColorProfile: .absent,
          embeddedICCProfile: nil,
          canvasWidth: canvasWidth,
          canvasHeight: canvasHeight,
          loopCount: loopCount,
          frames: frames,
          imageIOSourceIndicesMatchTimeline: true,
          encodedByteCount: byteCount
        )
      case 0x21:
        guard offset < bytes.count else {
          throw ImageCraftError.animationTimelineInvalid
        }
        let label = bytes[offset]
        offset += 1
        switch label {
        case 0xF9:
          guard pendingControl == nil else {
            throw ImageCraftError.animationTimelineInvalid
          }
          let result = try gifControl(bytes, at: offset)
          pendingControl = result.control
          offset = result.nextOffset
        case 0xFF:
          let result = try gifApplicationExtension(bytes, at: offset)
          if let parsed = result.loopCount { loopCount = parsed }
          offset = result.nextOffset
        case 0x01:
          throw ImageCraftError.animationUnsupported
        default:
          offset = try skipSubBlocks(bytes, from: offset).nextOffset
        }
      case 0x2C:
        guard offset + 9 <= bytes.count,
          let left = readUInt16LE(bytes, at: offset),
          let top = readUInt16LE(bytes, at: offset + 2),
          let width = readUInt16LE(bytes, at: offset + 4),
          let height = readUInt16LE(bytes, at: offset + 6)
        else { throw ImageCraftError.animationTimelineInvalid }
        let packed = bytes[offset + 8]
        guard packed & 0x18 == 0 else {
          throw ImageCraftError.animationTimelineInvalid
        }
        offset += 9
        let rect = try ImageAnimationFrameRect(
          x: Int(left),
          y: Int(top),
          width: Int(width),
          height: Int(height)
        )
        guard contains(rect, canvasWidth: canvasWidth, canvasHeight: canvasHeight) else {
          throw ImageCraftError.animationFrameRectInvalid
        }
        if packed & 0x80 != 0 {
          offset = try advancing(
            offset,
            by: 3 * (1 << (Int(packed & 0x07) + 1)),
            limit: bytes.count
          )
        }
        guard offset < bytes.count, (2...8).contains(bytes[offset]) else {
          throw ImageCraftError.animationTimelineInvalid
        }
        offset = try advancing(offset, by: 1, limit: bytes.count)
        let imageData = try skipSubBlocks(bytes, from: offset)
        guard imageData.payloadBytes > 0 else {
          throw ImageCraftError.animationTimelineInvalid
        }
        offset = imageData.nextOffset
        guard frames.count < maximumFrameCount else {
          throw ImageCraftError.frameLimitExceeded
        }
        let control =
          try pendingControl
          ?? GIFControl(
            duration: ImageAnimationFrameDuration(numerator: 0, denominator: 100),
            disposal: .none,
            blend: .source
          )
        frames.append(
          try ImageAnimationFrameDescriptor(
            index: frames.count,
            duration: control.duration,
            rect: rect,
            disposal: control.disposal,
            blend: control.blend
          )
        )
        pendingControl = nil
      default:
        throw ImageCraftError.animationTimelineInvalid
      }
    }
    throw ImageCraftError.animationTimelineInvalid
  }

  private static func gifControl(
    _ bytes: UnsafeBufferPointer<UInt8>,
    at offset: Int
  ) throws -> (control: GIFControl, nextOffset: Int) {
    guard offset + 6 <= bytes.count, bytes[offset] == 4,
      bytes[offset + 5] == 0,
      let delay = readUInt16LE(bytes, at: offset + 2)
    else { throw ImageCraftError.animationTimelineInvalid }
    let packed = bytes[offset + 1]
    guard packed & 0xE2 == 0 else {
      throw ImageCraftError.animationTimelineInvalid
    }
    let disposal: ImageAnimationDisposalMethod
    switch (packed >> 2) & 0x07 {
    case 0, 1: disposal = .none
    case 2: disposal = .background
    case 3: disposal = .previous
    default: throw ImageCraftError.animationTimelineInvalid
    }
    return (
      GIFControl(
        duration: try ImageAnimationFrameDuration(
          numerator: UInt32(delay),
          denominator: 100
        ),
        disposal: disposal,
        blend: packed & 0x01 == 0 ? .source : .over
      ),
      offset + 6
    )
  }

  private static func gifApplicationExtension(
    _ bytes: UnsafeBufferPointer<UInt8>,
    at offset: Int
  ) throws -> (loopCount: ImageAnimationLoopCount?, nextOffset: Int) {
    guard offset < bytes.count else { throw ImageCraftError.animationTimelineInvalid }
    let identifierLength = Int(bytes[offset])
    let identifierStart = offset + 1
    let identifierEnd = try advancing(identifierStart, by: identifierLength, limit: bytes.count)
    let identifier = String(decoding: bytes[identifierStart..<identifierEnd], as: UTF8.self)
    let blocks = try firstSubBlock(bytes, from: identifierEnd)
    guard identifier == "NETSCAPE2.0" || identifier == "ANIMEXTS1.0" else {
      return (nil, blocks.nextOffset)
    }
    guard let first = blocks.firstPayload, first.count == 3, first[0] == 1 else {
      throw ImageCraftError.animationTimelineInvalid
    }
    let low = UInt16(first[1])
    let high = UInt16(first[2])
    let raw = low | high << 8
    return (
      raw == 0 ? .infinite : ImageAnimationLoopCount(additionalRepeatCount: UInt32(raw)),
      blocks.nextOffset
    )
  }

  private static func firstSubBlock(
    _ bytes: UnsafeBufferPointer<UInt8>,
    from initialOffset: Int
  ) throws -> (nextOffset: Int, firstPayload: [UInt8]?) {
    var offset = initialOffset
    var firstPayload: [UInt8]?
    while true {
      guard offset < bytes.count else { throw ImageCraftError.animationTimelineInvalid }
      let length = Int(bytes[offset])
      offset += 1
      if length == 0 { return (offset, firstPayload) }
      let end = try advancing(offset, by: length, limit: bytes.count)
      if firstPayload == nil { firstPayload = Array(bytes[offset..<end]) }
      offset = end
    }
  }

  private static func skipSubBlocks(
    _ bytes: UnsafeBufferPointer<UInt8>,
    from initialOffset: Int
  ) throws -> (nextOffset: Int, payloadBytes: Int) {
    var offset = initialOffset
    var payloadBytes = 0
    while true {
      guard offset < bytes.count else { throw ImageCraftError.animationTimelineInvalid }
      let length = Int(bytes[offset])
      offset += 1
      if length == 0 { return (offset, payloadBytes) }
      offset = try advancing(offset, by: length, limit: bytes.count)
      payloadBytes = try adding(payloadBytes, length)
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

  private static func readUInt16LE(
    _ bytes: UnsafeBufferPointer<UInt8>,
    at offset: Int
  ) -> UInt16? {
    guard offset >= 0, offset + 2 <= bytes.count else { return nil }
    return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
  }

  private static func advancing(_ offset: Int, by count: Int, limit: Int) throws -> Int {
    let result = offset.addingReportingOverflow(count)
    guard count >= 0, !result.overflow, result.partialValue <= limit else {
      throw ImageCraftError.animationTimelineInvalid
    }
    return result.partialValue
  }

  private static func adding(_ lhs: Int, _ rhs: Int) throws -> Int {
    let result = lhs.addingReportingOverflow(rhs)
    guard !result.overflow else { throw ImageCraftError.animationTimelineInvalid }
    return result.partialValue
  }
}
