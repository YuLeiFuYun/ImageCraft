import Darwin
import Foundation
import ImageCraftCore

package enum JPEGIndependentProgressiveGrayscaleError: Error, Equatable, Sendable {
  case unsupportedSourceSemantics
  case invalidOperationBudget
  case operationBudgetExceeded(requiredBytes: Int, maximumBytes: Int)
  case stateAllocationFailed
}

package struct JPEGIndependentProgressiveGrayscaleImage: Equatable, Sendable {
  package let width: Int
  package let height: Int
  package let pixels: Data
  package let scanCount: Int
  package let coefficientStateByteCount: Int
  package let fixedStateByteCount: Int
  package let operationByteCharge: Int
}

/// Package-only complete-input progressive grayscale JPEG slice.
///
/// Unlike sequential baseline decode, progressive spectral/successive scans necessarily retain a
/// full quantized coefficient plane between scans.  ImageCraft therefore admits the final grayscale
/// raster plus `blockCount * 64 * 2` coefficient bytes plus 448 fixed bytes before allocation.  The
/// fixed state is one natural-order UInt16 quantization table (128 B), one Int32 ISLOW workspace
/// (256 B) and 64 bytes of per-coefficient progression state.  Entropy/Huffman controller values
/// remain fixed-cardinality value state; the caller-owned encoded `Data` is borrowed without a copy.
///
/// The qualified source domain is intentionally narrow: complete 8-bit SOF2, one 1x1 component,
/// Huffman coding, 8-bit DQT, noninterleaved progressive scans, optional DRI/RST markers and no DNL.
/// DQT must be established before the first scan and is latched for the component; later DQT
/// redefinition fails closed.  The implementation covers DC first/refine and AC first/refine and
/// validates successive-approximation order before accepting the final raster.
package struct JPEGIndependentProgressiveGrayscaleDecoder: Sendable {
  package static let fixedStateByteCount = 448

  private let maximumOperationByteCharge: Int
  private let maximumMetadataBytes: Int

  package init(
    maximumOperationByteCharge: Int,
    maximumMetadataBytes: Int = DecodeLimits.coreV1.maximumMetadataBytes
  ) {
    self.maximumOperationByteCharge = maximumOperationByteCharge
    self.maximumMetadataBytes = maximumMetadataBytes
  }

  package func decode(_ data: Data) throws -> JPEGIndependentProgressiveGrayscaleImage {
    try decode(data, finalCoefficientObserver: nil)
  }

  /// Evidence-only synchronous observation seam. The buffer aliases the decoder-owned coefficient
  /// state and is valid only for the duration of the callback; ImageCraft does not copy it or add it
  /// to the product resource charge. A throwing observer aborts before final rendering.
  package func decode(
    _ data: Data,
    finalCoefficientObserver: ((UnsafeBufferPointer<Int16>) throws -> Void)?
  ) throws -> JPEGIndependentProgressiveGrayscaleImage {
    guard maximumOperationByteCharge >= 0, maximumMetadataBytes >= 0 else {
      throw JPEGIndependentProgressiveGrayscaleError.invalidOperationBudget
    }
    let security = try EncodedImageSecurityInspector.inspect(
      data,
      maximumMetadataBytes: maximumMetadataBytes,
      materializePNGICCProfile: false,
      materializeJPEGICCProfile: false
    )
    guard security.format == .jpeg else { throw ImageCraftError.formatMismatch }
    guard security.sourceColorProfile != .embeddedICC, security.embeddedICCProfile == nil else {
      throw JPEGIndependentProgressiveGrayscaleError.unsupportedSourceSemantics
    }

    let frame = try JPEGFrameSamplingGeometry.inspect(data)
    guard frame.codingMode == .progressiveDCT,
      frame.samplingMode == .singleComponent,
      frame.precision == 8
    else { throw JPEGIndependentProgressiveGrayscaleError.unsupportedSourceSemantics }

    let blocksAcross = try Self.ceilDiv(frame.width, 8)
    let blocksDown = try Self.ceilDiv(frame.height, 8)
    let blockCount = try Self.multiplied(blocksAcross, blocksDown)
    let coefficientCount = try Self.multiplied(blockCount, 64)
    let coefficientBytes = try Self.multiplied(coefficientCount, MemoryLayout<Int16>.stride)
    let stateBytes = try Self.added(coefficientBytes, Self.fixedStateByteCount)
    let outputBytes = try Self.multiplied(frame.width, frame.height)
    let operationByteCharge = try Self.added(outputBytes, stateBytes)
    guard operationByteCharge <= maximumOperationByteCharge else {
      throw JPEGIndependentProgressiveGrayscaleError.operationBudgetExceeded(
        requiredBytes: operationByteCharge,
        maximumBytes: maximumOperationByteCharge
      )
    }

    let state = try StateArena(coefficientCount: coefficientCount)
    var output = Data(count: outputBytes)
    let scanCount = try data.withUnsafeBytes { rawInput in
      let input = rawInput.bindMemory(to: UInt8.self)
      var parser = Parser(
        bytes: input,
        expectedWidth: frame.width,
        expectedHeight: frame.height,
        expectedBlocksAcross: blocksAcross,
        expectedBlockCount: blockCount
      )
      let scans = try parser.decodeAll(state: state)
      if let finalCoefficientObserver {
        try finalCoefficientObserver(UnsafeBufferPointer(state.coefficients))
      }
      try output.withUnsafeMutableBytes { rawOutput in
        let destination = rawOutput.bindMemory(to: UInt8.self)
        try render(
          state: state,
          blocksAcross: blocksAcross,
          blockCount: blockCount,
          width: frame.width,
          height: frame.height,
          destination: destination
        )
      }
      return scans
    }

    return JPEGIndependentProgressiveGrayscaleImage(
      width: frame.width,
      height: frame.height,
      pixels: output,
      scanCount: scanCount,
      coefficientStateByteCount: coefficientBytes,
      fixedStateByteCount: Self.fixedStateByteCount,
      operationByteCharge: operationByteCharge
    )
  }

  private func render(
    state: StateArena,
    blocksAcross: Int,
    blockCount: Int,
    width: Int,
    height: Int,
    destination: UnsafeMutableBufferPointer<UInt8>
  ) throws {
    guard let coefficientBase = state.coefficients.baseAddress,
      let destinationBase = destination.baseAddress
    else { throw ImageCraftError.unsupportedOrCorruptImage }
    for blockIndex in 0..<blockCount {
      let blockX = blockIndex % blocksAcross
      let blockY = blockIndex / blocksAcross
      let pixelX = blockX * 8
      let pixelY = blockY * 8
      let writeWidth = min(8, width - pixelX)
      let writeHeight = min(8, height - pixelY)
      guard writeWidth > 0, writeHeight > 0 else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      let destinationOffset = pixelY * width + pixelX
      guard destinationOffset >= 0, destinationOffset < destination.count else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      let coefficients = UnsafeBufferPointer(
        start: coefficientBase.advanced(by: blockIndex * 64),
        count: 64
      )
      let blockDestination = UnsafeMutableBufferPointer(
        start: destinationBase.advanced(by: destinationOffset),
        count: destination.count - destinationOffset
      )
      try JPEGISlowIDCT.writeBlockClipped(
        coefficients: coefficients,
        quantization: UnsafeBufferPointer(state.quantization),
        workspace: state.workspace,
        destination: blockDestination,
        destinationRowStride: width,
        writeWidth: writeWidth,
        writeHeight: writeHeight
      )
    }
  }

  private final class StateArena {
    private let baseAddress: UnsafeMutableRawPointer
    let coefficients: UnsafeMutableBufferPointer<Int16>
    let quantization: UnsafeMutableBufferPointer<UInt16>
    let workspace: UnsafeMutableBufferPointer<Int32>
    let progression: UnsafeMutableBufferPointer<Int8>

    init(coefficientCount: Int) throws {
      let coefficientBytes = try JPEGIndependentProgressiveGrayscaleDecoder.multiplied(
        coefficientCount,
        MemoryLayout<Int16>.stride
      )
      let totalBytes = try JPEGIndependentProgressiveGrayscaleDecoder.added(
        coefficientBytes,
        JPEGIndependentProgressiveGrayscaleDecoder.fixedStateByteCount
      )
      var pointer: UnsafeMutableRawPointer?
      guard posix_memalign(&pointer, 64, max(1, totalBytes)) == 0, let pointer else {
        throw JPEGIndependentProgressiveGrayscaleError.stateAllocationFailed
      }
      baseAddress = pointer
      memset(pointer, 0, totalBytes)
      coefficients = UnsafeMutableBufferPointer(
        start: pointer.assumingMemoryBound(to: Int16.self),
        count: coefficientCount
      )
      quantization = UnsafeMutableBufferPointer(
        start: pointer.advanced(by: coefficientBytes).assumingMemoryBound(to: UInt16.self),
        count: 64
      )
      workspace = UnsafeMutableBufferPointer(
        start: pointer.advanced(by: coefficientBytes + 128).assumingMemoryBound(to: Int32.self),
        count: 64
      )
      progression = UnsafeMutableBufferPointer(
        start: pointer.advanced(by: coefficientBytes + 384).assumingMemoryBound(to: Int8.self),
        count: 64
      )
      memset(progression.baseAddress!, 0xFF, 64)
    }

    deinit { free(baseAddress) }

    func loadQuantization(
      from bytes: UnsafeBufferPointer<UInt8>,
      range: Range<Int>
    ) throws {
      guard range.count == 64, range.lowerBound >= 0, range.upperBound <= bytes.count else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      for zigzagIndex in 0..<64 {
        let value = UInt16(bytes[range.lowerBound + zigzagIndex])
        guard value > 0 else { throw ImageCraftError.unsupportedOrCorruptImage }
        quantization[JPEGIndependentProgressiveGrayscaleDecoder.jpegNaturalOrder[zigzagIndex]] = value
      }
    }
  }

  private struct HuffmanTableReference: Sendable {
    let countsRange: Range<Int>
    let symbolsRange: Range<Int>
    let symbolCount: Int
  }

  private struct ScanHeader {
    let dcTableIndex: Int
    let acTableIndex: Int
    let spectralStart: Int
    let spectralEnd: Int
    let successiveHigh: Int
    let successiveLow: Int
  }

  private struct Parser {
    let bytes: UnsafeBufferPointer<UInt8>
    let expectedWidth: Int
    let expectedHeight: Int
    let expectedBlocksAcross: Int
    let expectedBlockCount: Int
    var offset = 2
    var frameComponentID: UInt8?
    var frameQuantizationTableIndex: Int?
    var quantizationRanges = [Range<Int>?](repeating: nil, count: 4)
    var dcTables = [HuffmanTableReference?](repeating: nil, count: 4)
    var acTables = [HuffmanTableReference?](repeating: nil, count: 4)
    var restartIntervalMCUs = 0
    var quantizationLatched = false
    var scanCount = 0

    init(
      bytes: UnsafeBufferPointer<UInt8>,
      expectedWidth: Int,
      expectedHeight: Int,
      expectedBlocksAcross: Int,
      expectedBlockCount: Int
    ) {
      self.bytes = bytes
      self.expectedWidth = expectedWidth
      self.expectedHeight = expectedHeight
      self.expectedBlocksAcross = expectedBlocksAcross
      self.expectedBlockCount = expectedBlockCount
    }

    mutating func decodeAll(state: StateArena) throws -> Int {
      guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else {
        throw ImageCraftError.formatMismatch
      }
      var sawEOI = false
      while offset < bytes.count {
        let marker = try Self.readMarker(bytes, offset: &offset)
        switch marker {
        case 0xD9:
          guard frameComponentID != nil, scanCount > 0, offset == bytes.count else {
            throw ImageCraftError.unsupportedOrCorruptImage
          }
          sawEOI = true
          break
        case 0x01:
          continue
        case 0xD0...0xD8:
          throw ImageCraftError.unsupportedOrCorruptImage
        default:
          break
        }
        if sawEOI { break }

        let segment = try Self.segmentRange(bytes, lengthOffset: offset)
        offset = segment.end
        switch marker {
        case 0xC2:
          guard frameComponentID == nil else { throw ImageCraftError.unsupportedOrCorruptImage }
          let frame = try Self.parseFrame(bytes, segment: segment)
          guard frame.width == expectedWidth,
            frame.height == expectedHeight,
            try JPEGIndependentProgressiveGrayscaleDecoder.ceilDiv(frame.width, 8)
              == expectedBlocksAcross
          else { throw ImageCraftError.unsupportedOrCorruptImage }
          frameComponentID = frame.componentID
          frameQuantizationTableIndex = frame.quantizationTableIndex
        case 0xC0, 0xC1, 0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF:
          throw JPEGIndependentProgressiveGrayscaleError.unsupportedSourceSemantics
        case 0xDB:
          guard !quantizationLatched else {
            throw JPEGIndependentProgressiveGrayscaleError.unsupportedSourceSemantics
          }
          try Self.parseQuantizationTables(bytes, segment: segment, ranges: &quantizationRanges)
        case 0xC4:
          try Self.parseHuffmanTables(
            bytes,
            segment: segment,
            dcTables: &dcTables,
            acTables: &acTables
          )
        case 0xDD:
          guard segment.payload.count == 2 else {
            throw ImageCraftError.unsupportedOrCorruptImage
          }
          restartIntervalMCUs = Int(bytes[segment.payload.lowerBound]) << 8
            | Int(bytes[segment.payload.lowerBound + 1])
        case 0xCC, 0xDC:
          throw JPEGIndependentProgressiveGrayscaleError.unsupportedSourceSemantics
        case 0xDA:
          guard let componentID = frameComponentID,
            let quantizationTableIndex = frameQuantizationTableIndex
          else { throw ImageCraftError.unsupportedOrCorruptImage }
          scanCount += 1
          guard scanCount <= 500 else { throw ImageCraftError.unsupportedOrCorruptImage }
          let scan = try Self.parseScan(
            bytes,
            segment: segment,
            componentID: componentID
          )
          if !quantizationLatched {
            guard let quantizationRange = quantizationRanges[quantizationTableIndex] else {
              throw ImageCraftError.unsupportedOrCorruptImage
            }
            try state.loadQuantization(from: bytes, range: quantizationRange)
            quantizationLatched = true
          }
          try validateProgression(scan, state: state)
          let entropyEnd = try Self.nextStructuralMarkerOffset(bytes, start: segment.end)
          try decodeScan(
            scan,
            entropyStart: segment.end,
            entropyEnd: entropyEnd,
            state: state
          )
          updateProgression(scan, state: state)
          offset = entropyEnd
        default:
          continue
        }
      }
      guard sawEOI, quantizationLatched, state.progression[0] == 0 else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      for index in 1..<64 where state.progression[index] >= 0 {
        guard state.progression[index] == 0 else {
          throw JPEGIndependentProgressiveGrayscaleError.unsupportedSourceSemantics
        }
      }
      return scanCount
    }

    private mutating func decodeScan(
      _ scan: ScanHeader,
      entropyStart: Int,
      entropyEnd: Int,
      state: StateArena
    ) throws {
      var reader = EntropyBitReader(bytes: bytes, offset: entropyStart, endOffset: entropyEnd)
      var dcPredictor = 0
      var eobRun = 0
      var restartIndex = 0
      guard let coefficientBase = state.coefficients.baseAddress else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }

      for blockIndex in 0..<expectedBlockCount {
        if restartIntervalMCUs > 0,
          blockIndex > 0,
          blockIndex % restartIntervalMCUs == 0
        {
          guard eobRun == 0 else { throw ImageCraftError.unsupportedOrCorruptImage }
          try reader.finishEntropyByte()
          try reader.consumeMarker(expected: UInt8(0xD0 + (restartIndex & 7)))
          restartIndex += 1
          dcPredictor = 0
          eobRun = 0
        }
        let block = UnsafeMutableBufferPointer(
          start: coefficientBase.advanced(by: blockIndex * 64),
          count: 64
        )
        if scan.spectralStart == 0 {
          if scan.successiveHigh == 0 {
            guard let table = dcTables[scan.dcTableIndex] else {
              throw ImageCraftError.unsupportedOrCorruptImage
            }
            try decodeDCFirst(
              table: table,
              successiveLow: scan.successiveLow,
              predictor: &dcPredictor,
              block: block,
              reader: &reader
            )
          } else {
            try decodeDCRefine(
              successiveLow: scan.successiveLow,
              block: block,
              reader: &reader
            )
          }
        } else {
          guard let table = acTables[scan.acTableIndex] else {
            throw ImageCraftError.unsupportedOrCorruptImage
          }
          if scan.successiveHigh == 0 {
            try decodeACFirst(
              table: table,
              scan: scan,
              eobRun: &eobRun,
              block: block,
              reader: &reader
            )
          } else {
            try decodeACRefine(
              table: table,
              scan: scan,
              eobRun: &eobRun,
              block: block,
              reader: &reader
            )
          }
        }
      }
      guard eobRun == 0 else { throw ImageCraftError.unsupportedOrCorruptImage }
      try reader.finish()
    }

    private func decodeDCFirst(
      table: HuffmanTableReference,
      successiveLow: Int,
      predictor: inout Int,
      block: UnsafeMutableBufferPointer<Int16>,
      reader: inout EntropyBitReader
    ) throws {
      let category = try decodeHuffmanSymbol(table: table, reader: &reader)
      guard category <= 11 else { throw ImageCraftError.unsupportedOrCorruptImage }
      let difference = try receiveExtend(bitCount: Int(category), reader: &reader)
      let next = predictor.addingReportingOverflow(difference)
      guard !next.overflow else { throw ImageCraftError.unsupportedOrCorruptImage }
      predictor = next.partialValue
      let shifted = predictor.multipliedReportingOverflow(by: 1 << successiveLow)
      guard !shifted.overflow,
        shifted.partialValue >= Int(Int16.min),
        shifted.partialValue <= Int(Int16.max)
      else { throw ImageCraftError.unsupportedOrCorruptImage }
      block[0] = Int16(shifted.partialValue)
    }

    private func decodeDCRefine(
      successiveLow: Int,
      block: UnsafeMutableBufferPointer<Int16>,
      reader: inout EntropyBitReader
    ) throws {
      if try reader.readBit() != 0 {
        let mask = UInt16(1 << successiveLow)
        block[0] = Int16(bitPattern: UInt16(bitPattern: block[0]) | mask)
      }
    }

    private func decodeACFirst(
      table: HuffmanTableReference,
      scan: ScanHeader,
      eobRun: inout Int,
      block: UnsafeMutableBufferPointer<Int16>,
      reader: inout EntropyBitReader
    ) throws {
      if eobRun > 0 {
        eobRun -= 1
        return
      }
      var zigzag = scan.spectralStart
      while zigzag <= scan.spectralEnd {
        let symbol = try decodeHuffmanSymbol(table: table, reader: &reader)
        let zeroRun = Int(symbol >> 4)
        let bitCount = Int(symbol & 0x0F)
        if bitCount == 0 {
          if zeroRun == 15 {
            zigzag += 16
            guard zigzag <= scan.spectralEnd + 1 else {
              throw ImageCraftError.unsupportedOrCorruptImage
            }
            continue
          }
          eobRun = 1 << zeroRun
          if zeroRun > 0 {
            eobRun += Int(try reader.readBits(zeroRun))
          }
          eobRun -= 1
          break
        }
        guard bitCount <= 10 else { throw ImageCraftError.unsupportedOrCorruptImage }
        zigzag += zeroRun
        guard zigzag <= scan.spectralEnd else {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
        let value = try receiveExtend(bitCount: bitCount, reader: &reader)
        let shifted = value.multipliedReportingOverflow(by: 1 << scan.successiveLow)
        guard !shifted.overflow,
          shifted.partialValue >= Int(Int16.min),
          shifted.partialValue <= Int(Int16.max)
        else { throw ImageCraftError.unsupportedOrCorruptImage }
        block[JPEGIndependentProgressiveGrayscaleDecoder.jpegNaturalOrder[zigzag]] =
          Int16(shifted.partialValue)
        zigzag += 1
      }
    }

    private func decodeACRefine(
      table: HuffmanTableReference,
      scan: ScanHeader,
      eobRun: inout Int,
      block: UnsafeMutableBufferPointer<Int16>,
      reader: inout EntropyBitReader
    ) throws {
      let p1 = 1 << scan.successiveLow
      let m1 = (-1) << scan.successiveLow
      var zigzag = scan.spectralStart

      if eobRun == 0 {
        while zigzag <= scan.spectralEnd {
          let symbol = try decodeHuffmanSymbol(table: table, reader: &reader)
          var zeroRun = Int(symbol >> 4)
          let bitCount = Int(symbol & 0x0F)
          var newCoefficient = 0
          if bitCount != 0 {
            guard bitCount == 1 else { throw ImageCraftError.unsupportedOrCorruptImage }
            newCoefficient = try reader.readBit() != 0 ? p1 : m1
          } else if zeroRun != 15 {
            eobRun = 1 << zeroRun
            if zeroRun > 0 {
              eobRun += Int(try reader.readBits(zeroRun))
            }
            break
          }

          while zigzag <= scan.spectralEnd {
            let natural = JPEGIndependentProgressiveGrayscaleDecoder.jpegNaturalOrder[zigzag]
            if block[natural] != 0 {
              try refineExisting(
                coefficient: &block[natural],
                p1: p1,
                m1: m1,
                reader: &reader
              )
            } else {
              if zeroRun == 0 { break }
              zeroRun -= 1
            }
            zigzag += 1
          }
          if newCoefficient != 0 {
            guard zigzag <= scan.spectralEnd else {
              throw ImageCraftError.unsupportedOrCorruptImage
            }
            let natural = JPEGIndependentProgressiveGrayscaleDecoder.jpegNaturalOrder[zigzag]
            block[natural] = Int16(newCoefficient)
          }
          if zigzag <= scan.spectralEnd {
            zigzag += 1
          }
        }
      }

      if eobRun > 0 {
        while zigzag <= scan.spectralEnd {
          let natural = JPEGIndependentProgressiveGrayscaleDecoder.jpegNaturalOrder[zigzag]
          if block[natural] != 0 {
            try refineExisting(
              coefficient: &block[natural],
              p1: p1,
              m1: m1,
              reader: &reader
            )
          }
          zigzag += 1
        }
        eobRun -= 1
      }
    }

    private func refineExisting(
      coefficient: inout Int16,
      p1: Int,
      m1: Int,
      reader: inout EntropyBitReader
    ) throws {
      guard try reader.readBit() != 0 else { return }
      let current = Int(coefficient)
      if current & p1 == 0 {
        let refined = current.addingReportingOverflow(current >= 0 ? p1 : m1)
        guard !refined.overflow,
          refined.partialValue >= Int(Int16.min),
          refined.partialValue <= Int(Int16.max)
        else { throw ImageCraftError.unsupportedOrCorruptImage }
        coefficient = Int16(refined.partialValue)
      }
    }

    private func decodeHuffmanSymbol(
      table: HuffmanTableReference,
      reader: inout EntropyBitReader
    ) throws -> UInt8 {
      var code = 0
      var firstCode = 0
      var symbolBase = 0
      for length in 1...16 {
        code = (code << 1) | Int(try reader.readBit())
        let count = Int(bytes[table.countsRange.lowerBound + length - 1])
        if count > 0, code >= firstCode, code < firstCode + count {
          let symbolIndex = symbolBase + (code - firstCode)
          guard symbolIndex >= 0, symbolIndex < table.symbolCount else {
            throw ImageCraftError.unsupportedOrCorruptImage
          }
          return bytes[table.symbolsRange.lowerBound + symbolIndex]
        }
        symbolBase += count
        firstCode = (firstCode + count) << 1
      }
      throw ImageCraftError.unsupportedOrCorruptImage
    }

    private func receiveExtend(
      bitCount: Int,
      reader: inout EntropyBitReader
    ) throws -> Int {
      guard (0...16).contains(bitCount) else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      if bitCount == 0 { return 0 }
      let value = Int(try reader.readBits(bitCount))
      let threshold = 1 << (bitCount - 1)
      return value >= threshold ? value : value - ((1 << bitCount) - 1)
    }

    private func validateProgression(_ scan: ScanHeader, state: StateArena) throws {
      guard (0...63).contains(scan.spectralStart),
        (0...63).contains(scan.spectralEnd),
        scan.spectralStart <= scan.spectralEnd,
        scan.successiveHigh <= 13,
        scan.successiveLow <= 13,
        (scan.successiveHigh == 0 || scan.successiveHigh == scan.successiveLow + 1),
        (scan.spectralStart != 0 || scan.spectralEnd == 0)
      else { throw JPEGIndependentProgressiveGrayscaleError.unsupportedSourceSemantics }
      for index in scan.spectralStart...scan.spectralEnd {
        let previous = Int(state.progression[index])
        if previous < 0 {
          guard scan.successiveHigh == 0 else {
            throw JPEGIndependentProgressiveGrayscaleError.unsupportedSourceSemantics
          }
        } else {
          guard scan.successiveHigh == previous else {
            throw JPEGIndependentProgressiveGrayscaleError.unsupportedSourceSemantics
          }
        }
      }
    }

    private func updateProgression(_ scan: ScanHeader, state: StateArena) {
      for index in scan.spectralStart...scan.spectralEnd {
        state.progression[index] = Int8(scan.successiveLow)
      }
    }

    private struct Frame {
      let width: Int
      let height: Int
      let componentID: UInt8
      let quantizationTableIndex: Int
    }

    private struct Segment {
      let payload: Range<Int>
      let end: Int
    }

    private static func readMarker(
      _ bytes: UnsafeBufferPointer<UInt8>,
      offset: inout Int
    ) throws -> UInt8 {
      guard offset < bytes.count, bytes[offset] == 0xFF else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      while offset < bytes.count, bytes[offset] == 0xFF { offset += 1 }
      guard offset < bytes.count else { throw ImageCraftError.unsupportedOrCorruptImage }
      let marker = bytes[offset]
      offset += 1
      guard marker != 0x00 else { throw ImageCraftError.unsupportedOrCorruptImage }
      return marker
    }

    private static func segmentRange(
      _ bytes: UnsafeBufferPointer<UInt8>,
      lengthOffset: Int
    ) throws -> Segment {
      guard lengthOffset + 2 <= bytes.count else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      let length = Int(bytes[lengthOffset]) << 8 | Int(bytes[lengthOffset + 1])
      guard length >= 2 else { throw ImageCraftError.unsupportedOrCorruptImage }
      let end = lengthOffset.addingReportingOverflow(length)
      guard !end.overflow, end.partialValue <= bytes.count else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      return Segment(payload: (lengthOffset + 2)..<end.partialValue, end: end.partialValue)
    }

    private static func parseFrame(
      _ bytes: UnsafeBufferPointer<UInt8>,
      segment: Segment
    ) throws -> Frame {
      guard segment.payload.count == 9 else {
        throw JPEGIndependentProgressiveGrayscaleError.unsupportedSourceSemantics
      }
      let start = segment.payload.lowerBound
      let precision = Int(bytes[start])
      let height = Int(bytes[start + 1]) << 8 | Int(bytes[start + 2])
      let width = Int(bytes[start + 3]) << 8 | Int(bytes[start + 4])
      guard precision == 8, width > 0, height > 0, bytes[start + 5] == 1,
        bytes[start + 7] == 0x11
      else { throw JPEGIndependentProgressiveGrayscaleError.unsupportedSourceSemantics }
      let quantizationTableIndex = Int(bytes[start + 8])
      guard (0...3).contains(quantizationTableIndex) else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      return Frame(
        width: width,
        height: height,
        componentID: bytes[start + 6],
        quantizationTableIndex: quantizationTableIndex
      )
    }

    private static func parseQuantizationTables(
      _ bytes: UnsafeBufferPointer<UInt8>,
      segment: Segment,
      ranges: inout [Range<Int>?]
    ) throws {
      var cursor = segment.payload.lowerBound
      while cursor < segment.payload.upperBound {
        let info = bytes[cursor]
        cursor += 1
        let precision = Int(info >> 4)
        let tableIndex = Int(info & 0x0F)
        guard precision == 0, (0...3).contains(tableIndex),
          cursor + 64 <= segment.payload.upperBound
        else { throw JPEGIndependentProgressiveGrayscaleError.unsupportedSourceSemantics }
        ranges[tableIndex] = cursor..<(cursor + 64)
        cursor += 64
      }
      guard cursor == segment.payload.upperBound else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
    }

    private static func parseHuffmanTables(
      _ bytes: UnsafeBufferPointer<UInt8>,
      segment: Segment,
      dcTables: inout [HuffmanTableReference?],
      acTables: inout [HuffmanTableReference?]
    ) throws {
      var cursor = segment.payload.lowerBound
      while cursor < segment.payload.upperBound {
        let info = bytes[cursor]
        cursor += 1
        let tableClass = Int(info >> 4)
        let tableIndex = Int(info & 0x0F)
        guard (0...1).contains(tableClass), (0...3).contains(tableIndex),
          cursor + 16 <= segment.payload.upperBound
        else { throw ImageCraftError.unsupportedOrCorruptImage }
        let countsRange = cursor..<(cursor + 16)
        var symbolCount = 0
        for index in countsRange { symbolCount += Int(bytes[index]) }
        cursor += 16
        guard symbolCount > 0, symbolCount <= 256,
          cursor + symbolCount <= segment.payload.upperBound
        else { throw ImageCraftError.unsupportedOrCorruptImage }
        let table = HuffmanTableReference(
          countsRange: countsRange,
          symbolsRange: cursor..<(cursor + symbolCount),
          symbolCount: symbolCount
        )
        try validateHuffmanTree(bytes, table: table)
        if tableClass == 0 { dcTables[tableIndex] = table }
        else { acTables[tableIndex] = table }
        cursor += symbolCount
      }
      guard cursor == segment.payload.upperBound else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
    }

    private static func validateHuffmanTree(
      _ bytes: UnsafeBufferPointer<UInt8>,
      table: HuffmanTableReference
    ) throws {
      var nextCode = 0
      for length in 1...16 {
        let count = Int(bytes[table.countsRange.lowerBound + length - 1])
        let after = nextCode.addingReportingOverflow(count)
        guard !after.overflow, after.partialValue < (1 << length) else {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
        nextCode = after.partialValue << 1
      }
    }

    private static func parseScan(
      _ bytes: UnsafeBufferPointer<UInt8>,
      segment: Segment,
      componentID: UInt8
    ) throws -> ScanHeader {
      guard segment.payload.count == 6 else {
        throw JPEGIndependentProgressiveGrayscaleError.unsupportedSourceSemantics
      }
      let start = segment.payload.lowerBound
      guard bytes[start] == 1, bytes[start + 1] == componentID else {
        throw JPEGIndependentProgressiveGrayscaleError.unsupportedSourceSemantics
      }
      let selectors = bytes[start + 2]
      let dcTableIndex = Int(selectors >> 4)
      let acTableIndex = Int(selectors & 0x0F)
      guard (0...3).contains(dcTableIndex), (0...3).contains(acTableIndex) else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      let approximation = bytes[start + 5]
      return ScanHeader(
        dcTableIndex: dcTableIndex,
        acTableIndex: acTableIndex,
        spectralStart: Int(bytes[start + 3]),
        spectralEnd: Int(bytes[start + 4]),
        successiveHigh: Int(approximation >> 4),
        successiveLow: Int(approximation & 0x0F)
      )
    }

    private static func nextStructuralMarkerOffset(
      _ bytes: UnsafeBufferPointer<UInt8>,
      start: Int
    ) throws -> Int {
      var cursor = start
      while cursor < bytes.count {
        if bytes[cursor] != 0xFF {
          cursor += 1
          continue
        }
        let markerStart = cursor
        while cursor < bytes.count, bytes[cursor] == 0xFF { cursor += 1 }
        guard cursor < bytes.count else { throw ImageCraftError.unsupportedOrCorruptImage }
        let code = bytes[cursor]
        cursor += 1
        if code == 0x00 || (0xD0...0xD7).contains(code) { continue }
        return markerStart
      }
      throw ImageCraftError.unsupportedOrCorruptImage
    }
  }

  private struct EntropyBitReader {
    let bytes: UnsafeBufferPointer<UInt8>
    var offset: Int
    let endOffset: Int
    private var currentByte: UInt8 = 0
    private var bitsRemaining = 0

    mutating func readBit() throws -> UInt8 {
      if bitsRemaining == 0 {
        currentByte = try readEntropyByte()
        bitsRemaining = 8
      }
      bitsRemaining -= 1
      return (currentByte >> bitsRemaining) & 1
    }

    mutating func readBits(_ count: Int) throws -> UInt32 {
      guard (0...16).contains(count) else { throw ImageCraftError.unsupportedOrCorruptImage }
      var value: UInt32 = 0
      for _ in 0..<count { value = (value << 1) | UInt32(try readBit()) }
      return value
    }

    mutating func finishEntropyByte() throws {
      if bitsRemaining > 0 {
        let mask = UInt8((1 << bitsRemaining) - 1)
        guard currentByte & mask == mask else { throw ImageCraftError.unsupportedOrCorruptImage }
      }
      currentByte = 0
      bitsRemaining = 0
    }

    mutating func consumeMarker(expected: UInt8) throws {
      guard bitsRemaining == 0, offset < endOffset, bytes[offset] == 0xFF else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      while offset < endOffset, bytes[offset] == 0xFF { offset += 1 }
      guard offset < endOffset, bytes[offset] == expected else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      offset += 1
    }

    mutating func finish() throws {
      try finishEntropyByte()
      guard offset == endOffset else { throw ImageCraftError.unsupportedOrCorruptImage }
    }

    private mutating func readEntropyByte() throws -> UInt8 {
      guard offset < endOffset else { throw ImageCraftError.unsupportedOrCorruptImage }
      let value = bytes[offset]
      offset += 1
      if value != 0xFF { return value }
      while offset < endOffset, bytes[offset] == 0xFF { offset += 1 }
      guard offset < endOffset, bytes[offset] == 0x00 else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      offset += 1
      return 0xFF
    }
  }

  private static let jpegNaturalOrder: [Int] = [
    0, 1, 8, 16, 9, 2, 3, 10,
    17, 24, 32, 25, 18, 11, 4, 5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6, 7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
  ]

  private static func ceilDiv(_ value: Int, _ divisor: Int) throws -> Int {
    guard value > 0, divisor > 0 else { throw ImageCraftError.unsupportedOrCorruptImage }
    return value / divisor + (value % divisor == 0 ? 0 : 1)
  }

  private static func added(_ lhs: Int, _ rhs: Int) throws -> Int {
    let value = lhs.addingReportingOverflow(rhs)
    guard !value.overflow, value.partialValue >= 0 else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    return value.partialValue
  }

  private static func multiplied(_ lhs: Int, _ rhs: Int) throws -> Int {
    let value = lhs.multipliedReportingOverflow(by: rhs)
    guard !value.overflow, value.partialValue >= 0 else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    return value.partialValue
  }
}
