import Foundation

struct APNGRawSubrectDecodePolicy: Equatable, Sendable {
  static let bounded1024 = APNGRawSubrectDecodePolicy(
    maximumEncodedBytes: 64 * 1_024 * 1_024,
    maximumCanvasDimension: 1_024,
    maximumFrameCount: 512,
    maximumTotalRawRGBABytes: 512 * 1_024 * 1_024,
    maximumAncillaryBytes: 1 * 1_024 * 1_024
  )

  let maximumEncodedBytes: Int
  let maximumCanvasDimension: Int
  let maximumFrameCount: Int
  let maximumTotalRawRGBABytes: Int
  let maximumAncillaryBytes: Int

  func validate() throws {
    guard maximumEncodedBytes > 0,
      maximumEncodedBytes <= 64 * 1_024 * 1_024,
      maximumCanvasDimension > 0,
      maximumCanvasDimension <= 1_024,
      maximumFrameCount > 0,
      maximumFrameCount <= 512,
      maximumTotalRawRGBABytes > 0,
      maximumTotalRawRGBABytes <= 512 * 1_024 * 1_024,
      maximumAncillaryBytes >= 0,
      maximumAncillaryBytes <= maximumEncodedBytes
    else { throw APNGRawSubrectDecodeError.invalidPolicy }
  }
}

enum APNGRawSubrectDecodeError: Error, Equatable, Sendable {
  case invalidPolicy
  case encodedBytesExceeded
  case invalidSignature
  case truncatedChunk
  case invalidChunkType
  case crcMismatch
  case invalidChunkOrder
  case metadataBudgetExceeded
  case unsupportedFormat
  case frameLimitExceeded
  case sequenceMismatch
  case invalidFrameControl
  case frameRectOutOfBounds
  case frameDataMissing
  case inflateFailed
  case invalidFilter
  case decodedByteCountMismatch
  case decodedBudgetExceeded
}

struct APNGRawSubrectFrameControl: Equatable, Sendable {
  let sequenceNumber: UInt32
  let width: Int
  let height: Int
  let xOffset: Int
  let yOffset: Int
  let delayNumerator: UInt16
  let delayDenominator: UInt16
  let disposal: UInt8
  let blend: UInt8

  var durationNanoseconds: UInt64 {
    let denominator = UInt64(delayDenominator == 0 ? 100 : delayDenominator)
    let numerator = UInt64(delayNumerator) * 1_000_000_000
    return (numerator + denominator - 1) / denominator
  }
}

struct APNGEncodedSubrectFrame: Equatable, Sendable {
  let control: APNGRawSubrectFrameControl
  let compressedPayload: Data
}

struct APNGEncodedSubrectImage: Equatable, Sendable {
  let canvasWidth: Int
  let canvasHeight: Int
  let numPlays: UInt32
  let firstAnimationFrameUsesIDAT: Bool
  let frames: [APNGEncodedSubrectFrame]

  func decodeFrame(at index: Int) throws -> APNGRawSubrectFrame {
    guard frames.indices.contains(index) else {
      throw APNGRawSubrectDecodeError.invalidFrameControl
    }
    return try APNGRawSubrectDecoder.decodeFrame(frames[index])
  }
}

struct APNGRawSubrectFrame: Equatable, Sendable {
  let control: APNGRawSubrectFrameControl
  let straightAlphaRGBA: Data
}

struct APNGRawSubrectImage: Equatable, Sendable {
  let canvasWidth: Int
  let canvasHeight: Int
  let numPlays: UInt32
  let firstAnimationFrameUsesIDAT: Bool
  let frames: [APNGRawSubrectFrame]
}

enum APNGRawSubrectDecoder {
  private static let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])
  private static let ihdr = Data("IHDR".utf8)
  private static let plte = Data("PLTE".utf8)
  private static let idat = Data("IDAT".utf8)
  private static let iend = Data("IEND".utf8)
  private static let actl = Data("acTL".utf8)
  private static let fctl = Data("fcTL".utf8)
  private static let fdat = Data("fdAT".utf8)
  private static let trns = Data("tRNS".utf8)

  private struct PendingFrame {
    let control: APNGRawSubrectFrameControl
    let usesIDAT: Bool
    var compressed = Data()
  }

  static func parseEncoded(
    _ data: Data,
    policy: APNGRawSubrectDecodePolicy = .bounded1024
  ) throws -> APNGEncodedSubrectImage {
    try policy.validate()
    guard data.count <= policy.maximumEncodedBytes else {
      throw APNGRawSubrectDecodeError.encodedBytesExceeded
    }
    guard data.count >= signature.count, data.prefix(signature.count) == signature else {
      throw APNGRawSubrectDecodeError.invalidSignature
    }

    var offset = signature.count
    var canvasWidth: Int?
    var canvasHeight: Int?
    var declaredFrameCount: Int?
    var numPlays = UInt32(0)
    var expectedSequence = UInt32(0)
    var seenIHDR = false
    var seenACTL = false
    var seenIDAT = false
    var idatClosed = false
    var seenIEND = false
    var ancillaryBytes = 0
    var pending: PendingFrame?
    var pendingFrames: [PendingFrame] = []
    var firstAnimationFrameUsesIDAT: Bool?

    func advanceSequence(_ sequence: UInt32) throws -> UInt32 {
      guard sequence == expectedSequence else {
        throw APNGRawSubrectDecodeError.sequenceMismatch
      }
      let next = expectedSequence.addingReportingOverflow(1)
      guard !next.overflow else {
        throw APNGRawSubrectDecodeError.sequenceMismatch
      }
      return next.partialValue
    }

    func finalizePending() throws {
      guard let current = pending else { return }
      guard !current.compressed.isEmpty else {
        throw APNGRawSubrectDecodeError.frameDataMissing
      }
      pendingFrames.append(current)
      pending = nil
    }

    while offset < data.count {
      guard !seenIEND, offset <= data.count - 12,
        let payloadLengthValue = readUInt32BE(data, at: offset),
        let payloadLength = Int(exactly: payloadLengthValue)
      else { throw APNGRawSubrectDecodeError.truncatedChunk }
      let typeStart = offset + 4
      let payloadStart = typeStart + 4
      let payloadEndResult = payloadStart.addingReportingOverflow(payloadLength)
      guard !payloadEndResult.overflow else {
        throw APNGRawSubrectDecodeError.truncatedChunk
      }
      let payloadEnd = payloadEndResult.partialValue
      let crcEndResult = payloadEnd.addingReportingOverflow(4)
      guard !crcEndResult.overflow, crcEndResult.partialValue <= data.count else {
        throw APNGRawSubrectDecodeError.truncatedChunk
      }
      let crcEnd = crcEndResult.partialValue
      let kind = data[typeStart..<payloadStart]
      guard isValidChunkType(kind) else {
        throw APNGRawSubrectDecodeError.invalidChunkType
      }
      guard let expectedCRC = readUInt32BE(data, at: payloadEnd) else {
        throw APNGRawSubrectDecodeError.truncatedChunk
      }
      guard
        ImageCraftCRC32.checksum(
          data,
          from: typeStart,
          to: payloadEnd
        ) == expectedCRC
      else {
        throw APNGRawSubrectDecodeError.crcMismatch
      }
      offset = crcEnd

      if kind != idat, seenIDAT { idatClosed = true }
      switch kind {
      case ihdr:
        guard !seenIHDR, offset == signature.count + 25, payloadLength == 13 else {
          throw APNGRawSubrectDecodeError.invalidChunkOrder
        }
        guard let widthValue = readUInt32BE(data, at: payloadStart),
          let heightValue = readUInt32BE(data, at: payloadStart + 4),
          let width = Int(exactly: widthValue),
          let height = Int(exactly: heightValue),
          width > 0,
          height > 0,
          width <= policy.maximumCanvasDimension,
          height <= policy.maximumCanvasDimension,
          data[payloadStart + 8] == 8,
          data[payloadStart + 9] == 6,
          data[payloadStart + 10] == 0,
          data[payloadStart + 11] == 0,
          data[payloadStart + 12] == 0
        else { throw APNGRawSubrectDecodeError.unsupportedFormat }
        let pixels = width.multipliedReportingOverflow(by: height)
        guard !pixels.overflow,
          pixels.partialValue <= policy.maximumCanvasDimension * policy.maximumCanvasDimension
        else {
          throw APNGRawSubrectDecodeError.unsupportedFormat
        }
        canvasWidth = width
        canvasHeight = height
        seenIHDR = true
      case actl:
        guard seenIHDR, !seenACTL, !seenIDAT, payloadLength == 8,
          let frameCountValue = readUInt32BE(data, at: payloadStart),
          let repeatCount = readUInt32BE(data, at: payloadStart + 4),
          let frameCount = Int(exactly: frameCountValue),
          frameCount > 0
        else { throw APNGRawSubrectDecodeError.invalidChunkOrder }
        guard frameCount <= policy.maximumFrameCount else {
          throw APNGRawSubrectDecodeError.frameLimitExceeded
        }
        declaredFrameCount = frameCount
        numPlays = repeatCount
        seenACTL = true
      case fctl:
        guard seenIHDR, seenACTL, payloadLength == 26,
          let width = canvasWidth,
          let height = canvasHeight
        else { throw APNGRawSubrectDecodeError.invalidChunkOrder }
        try finalizePending()
        let control = try parseControl(data, at: payloadStart)
        expectedSequence = try advanceSequence(control.sequenceNumber)
        guard control.xOffset <= width - control.width,
          control.yOffset <= height - control.height
        else { throw APNGRawSubrectDecodeError.frameRectOutOfBounds }
        let usesIDAT = !seenIDAT
        if firstAnimationFrameUsesIDAT == nil {
          firstAnimationFrameUsesIDAT = usesIDAT
          if usesIDAT,
            control.width != width || control.height != height
              || control.xOffset != 0 || control.yOffset != 0
          {
            throw APNGRawSubrectDecodeError.invalidFrameControl
          }
        }
        pending = PendingFrame(control: control, usesIDAT: usesIDAT)
      case idat:
        guard seenIHDR, seenACTL, !idatClosed else {
          throw APNGRawSubrectDecodeError.invalidChunkOrder
        }
        seenIDAT = true
        if pending?.usesIDAT == true {
          pending?.compressed.append(data[payloadStart..<payloadEnd])
        } else if pending != nil {
          throw APNGRawSubrectDecodeError.invalidChunkOrder
        }
      case fdat:
        guard seenIHDR, seenACTL, seenIDAT, payloadLength > 4,
          pending != nil,
          pending?.usesIDAT == false,
          let sequence = readUInt32BE(data, at: payloadStart)
        else { throw APNGRawSubrectDecodeError.invalidChunkOrder }
        expectedSequence = try advanceSequence(sequence)
        pending?.compressed.append(data[(payloadStart + 4)..<payloadEnd])
      case iend:
        guard seenIHDR, seenACTL, seenIDAT, payloadLength == 0, offset == data.count else {
          throw APNGRawSubrectDecodeError.invalidChunkOrder
        }
        try finalizePending()
        seenIEND = true
      case trns:
        throw APNGRawSubrectDecodeError.unsupportedFormat
      case plte:
        ancillaryBytes = try addingMetadata(
          payloadLength,
          current: ancillaryBytes,
          limit: policy.maximumAncillaryBytes
        )
      default:
        guard !isCritical(kind) else {
          throw APNGRawSubrectDecodeError.unsupportedFormat
        }
        ancillaryBytes = try addingMetadata(
          payloadLength,
          current: ancillaryBytes,
          limit: policy.maximumAncillaryBytes
        )
      }
    }

    guard seenIEND, let width = canvasWidth, let height = canvasHeight,
      let expectedFrames = declaredFrameCount,
      let firstUsesIDAT = firstAnimationFrameUsesIDAT,
      pendingFrames.count == expectedFrames
    else { throw APNGRawSubrectDecodeError.invalidChunkOrder }

    var totalRawBytes = 0
    var encodedFrames: [APNGEncodedSubrectFrame] = []
    encodedFrames.reserveCapacity(pendingFrames.count)
    for pendingFrame in pendingFrames {
      let counts = try byteCounts(for: pendingFrame.control)
      let nextTotal = totalRawBytes.addingReportingOverflow(counts.raw)
      guard !nextTotal.overflow,
        nextTotal.partialValue <= policy.maximumTotalRawRGBABytes
      else { throw APNGRawSubrectDecodeError.decodedBudgetExceeded }
      totalRawBytes = nextTotal.partialValue
      encodedFrames.append(
        APNGEncodedSubrectFrame(
          control: pendingFrame.control,
          compressedPayload: pendingFrame.compressed
        )
      )
    }
    return APNGEncodedSubrectImage(
      canvasWidth: width,
      canvasHeight: height,
      numPlays: numPlays,
      firstAnimationFrameUsesIDAT: firstUsesIDAT,
      frames: encodedFrames
    )
  }

  static func decode(
    _ data: Data,
    policy: APNGRawSubrectDecodePolicy = .bounded1024
  ) throws -> APNGRawSubrectImage {
    let encoded = try parseEncoded(data, policy: policy)
    return APNGRawSubrectImage(
      canvasWidth: encoded.canvasWidth,
      canvasHeight: encoded.canvasHeight,
      numPlays: encoded.numPlays,
      firstAnimationFrameUsesIDAT: encoded.firstAnimationFrameUsesIDAT,
      frames: try encoded.frames.map(decodeFrame)
    )
  }

  static func decodeFrame(
    _ frame: APNGEncodedSubrectFrame
  ) throws -> APNGRawSubrectFrame {
    let counts = try byteCounts(for: frame.control)
    let inflated: Data
    do {
      inflated = try RFC1950BoundedInflate.inflate(
        frame.compressedPayload,
        expectedByteCount: counts.inflated
      )
    } catch {
      throw APNGRawSubrectDecodeError.inflateFailed
    }
    let rgba = try unfilterRGBA8(
      inflated,
      width: frame.control.width,
      height: frame.control.height
    )
    guard rgba.count == counts.raw else {
      throw APNGRawSubrectDecodeError.decodedByteCountMismatch
    }
    return APNGRawSubrectFrame(
      control: frame.control,
      straightAlphaRGBA: rgba
    )
  }

  private static func byteCounts(
    for control: APNGRawSubrectFrameControl
  ) throws -> (inflated: Int, raw: Int) {
    let rowBytesResult = control.width.multipliedReportingOverflow(by: 4)
    guard !rowBytesResult.overflow else {
      throw APNGRawSubrectDecodeError.decodedByteCountMismatch
    }
    let rowBytes = rowBytesResult.partialValue
    let scanlineResult = rowBytes.addingReportingOverflow(1)
    guard !scanlineResult.overflow else {
      throw APNGRawSubrectDecodeError.decodedByteCountMismatch
    }
    let inflatedResult = scanlineResult.partialValue.multipliedReportingOverflow(
      by: control.height
    )
    let rawResult = rowBytes.multipliedReportingOverflow(by: control.height)
    guard !inflatedResult.overflow, !rawResult.overflow else {
      throw APNGRawSubrectDecodeError.decodedByteCountMismatch
    }
    return (inflatedResult.partialValue, rawResult.partialValue)
  }

  private static func parseControl(
    _ data: Data,
    at offset: Int
  ) throws -> APNGRawSubrectFrameControl {
    guard let sequence = readUInt32BE(data, at: offset),
      let widthValue = readUInt32BE(data, at: offset + 4),
      let heightValue = readUInt32BE(data, at: offset + 8),
      let xValue = readUInt32BE(data, at: offset + 12),
      let yValue = readUInt32BE(data, at: offset + 16),
      let delayNumerator = readUInt16BE(data, at: offset + 20),
      let delayDenominator = readUInt16BE(data, at: offset + 22),
      let width = Int(exactly: widthValue),
      let height = Int(exactly: heightValue),
      let x = Int(exactly: xValue),
      let y = Int(exactly: yValue),
      width > 0,
      height > 0,
      data[offset + 24] <= 2,
      data[offset + 25] <= 1
    else { throw APNGRawSubrectDecodeError.invalidFrameControl }
    return APNGRawSubrectFrameControl(
      sequenceNumber: sequence,
      width: width,
      height: height,
      xOffset: x,
      yOffset: y,
      delayNumerator: delayNumerator,
      delayDenominator: delayDenominator,
      disposal: data[offset + 24],
      blend: data[offset + 25]
    )
  }

  private static func unfilterRGBA8(
    _ inflated: Data,
    width: Int,
    height: Int
  ) throws -> Data {
    do {
      return try PNGScanlineRGBA8Decoder.decode(inflated, width: width, height: height)
    } catch PNGScanlineRGBA8Error.invalidFilter {
      throw APNGRawSubrectDecodeError.invalidFilter
    } catch {
      throw APNGRawSubrectDecodeError.decodedByteCountMismatch
    }
  }

  private static func addingMetadata(
    _ count: Int,
    current: Int,
    limit: Int
  ) throws -> Int {
    let next = current.addingReportingOverflow(count)
    guard !next.overflow, next.partialValue <= limit else {
      throw APNGRawSubrectDecodeError.metadataBudgetExceeded
    }
    return next.partialValue
  }

  private static func isValidChunkType(_ kind: Data) -> Bool {
    guard kind.count == 4 else { return false }
    let bytes = Array(kind)
    guard
      bytes.allSatisfy({
        (65...90).contains($0) || (97...122).contains($0)
      })
    else { return false }
    return (65...90).contains(bytes[2])
  }

  private static func isCritical(_ kind: Data) -> Bool {
    guard let first = kind.first else { return true }
    return (65...90).contains(first)
  }

  private static func readUInt16BE(_ data: Data, at offset: Int) -> UInt16? {
    guard offset >= 0, offset + 2 <= data.count else { return nil }
    return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
  }

  private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= data.count else { return nil }
    return UInt32(data[offset]) << 24
      | UInt32(data[offset + 1]) << 16
      | UInt32(data[offset + 2]) << 8
      | UInt32(data[offset + 3])
  }
}
