import Darwin
import Foundation
import ImageCraftCore

package enum JPEGIndependentBaselineGrayscaleError: Error, Equatable, Sendable {
  case unsupportedSourceSemantics
  case invalidOperationBudget
  case operationBudgetExceeded(requiredBytes: Int, maximumBytes: Int)
  case scratchAllocationFailed
}

package struct JPEGIndependentBaselineGrayscaleImage: Equatable, Sendable {
  package let width: Int
  package let height: Int
  package let pixels: Data
  package let restartIntervalMCUs: Int
  package let decodedMCUCount: Int
  package let fixedScratchByteCount: Int
  package let operationByteCharge: Int
}

/// Package-only first end-to-end independent JPEG raster slice.
///
/// Qualification is intentionally narrow: complete 8-bit SOF0, one 1x1-sampled component, one
/// sequential Huffman scan (Ss=0, Se=63, Ah=Al=0), 8-bit DQT, optional DRI/RST markers and no DNL.
/// JPEG metadata structure/ceilings are validated without materializing ICC; embedded ICC semantics
/// fail closed because this raw-grayscale research value has no profile contract. The encoded `Data`
/// is caller-owned. The decoder admits `width*height + 512` before allocating
/// output or scratch, then decodes one MCU block at a time directly into the final grayscale raster;
/// it never creates a frame-sized coefficient surface.  The 512-byte codec-owned scratch is one
/// explicitly allocated backing: 128 B coefficients + 128 B quantization + 256 B ISLOW workspace.
/// Small parser/control values are fixed-cardinality value state and are kept
/// separate from this payload charge.
package struct JPEGIndependentBaselineGrayscaleDecoder: Sendable {
  package static let fixedScratchByteCount = 512
  private let maximumOperationByteCharge: Int
  private let maximumMetadataBytes: Int

  package init(
    maximumOperationByteCharge: Int,
    maximumMetadataBytes: Int = DecodeLimits.coreV1.maximumMetadataBytes
  ) {
    self.maximumOperationByteCharge = maximumOperationByteCharge
    self.maximumMetadataBytes = maximumMetadataBytes
  }

  package func decode(_ data: Data) throws -> JPEGIndependentBaselineGrayscaleImage {
    guard maximumOperationByteCharge >= 0, maximumMetadataBytes >= 0 else {
      throw JPEGIndependentBaselineGrayscaleError.invalidOperationBudget
    }
    let security = try EncodedImageSecurityInspector.inspect(
      data,
      maximumMetadataBytes: maximumMetadataBytes,
      materializePNGICCProfile: false,
      materializeJPEGICCProfile: false
    )
    guard security.format == .jpeg else { throw ImageCraftError.formatMismatch }
    guard security.sourceColorProfile != .embeddedICC, security.embeddedICCProfile == nil else {
      throw JPEGIndependentBaselineGrayscaleError.unsupportedSourceSemantics
    }

    let plan = try DecodePlan.inspect(data)
    let outputByteCount = try Self.multiplied(plan.width, plan.height)
    let operationByteCharge = try Self.added(outputByteCount, Self.fixedScratchByteCount)
    guard operationByteCharge <= maximumOperationByteCharge else {
      throw JPEGIndependentBaselineGrayscaleError.operationBudgetExceeded(
        requiredBytes: operationByteCharge,
        maximumBytes: maximumOperationByteCharge
      )
    }

    let scratch = try Scratch()
    var output = Data(count: outputByteCount)
    try data.withUnsafeBytes { rawInput in
      let input = rawInput.bindMemory(to: UInt8.self)
      try scratch.loadQuantization(from: input, range: plan.quantizationRange)
      try output.withUnsafeMutableBytes { rawOutput in
        let destination = rawOutput.bindMemory(to: UInt8.self)
        guard destination.count == outputByteCount else {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
        try decodeScan(
          input: input,
          plan: plan,
          scratch: scratch,
          destination: destination
        )
      }
    }

    return JPEGIndependentBaselineGrayscaleImage(
      width: plan.width,
      height: plan.height,
      pixels: output,
      restartIntervalMCUs: plan.restartIntervalMCUs,
      decodedMCUCount: plan.totalMCUCount,
      fixedScratchByteCount: Self.fixedScratchByteCount,
      operationByteCharge: operationByteCharge
    )
  }

  private func decodeScan(
    input: UnsafeBufferPointer<UInt8>,
    plan: DecodePlan,
    scratch: Scratch,
    destination: UnsafeMutableBufferPointer<UInt8>
  ) throws {
    var bitReader = EntropyBitReader(bytes: input, offset: plan.entropyStartOffset)
    var dcPredictor = 0
    var expectedRestartIndex = 0

    for mcuIndex in 0..<plan.totalMCUCount {
      if plan.restartIntervalMCUs > 0,
        mcuIndex > 0,
        mcuIndex % plan.restartIntervalMCUs == 0
      {
        try bitReader.finishEntropyByte()
        try bitReader.consumeMarker(expected: UInt8(0xD0 + (expectedRestartIndex & 7)))
        expectedRestartIndex += 1
        dcPredictor = 0
      }

      scratch.clearCoefficientBlock()
      let dcCategory = try decodeHuffmanSymbol(
        bytes: input,
        table: plan.dcHuffman,
        reader: &bitReader
      )
      guard dcCategory <= 11 else { throw ImageCraftError.unsupportedOrCorruptImage }
      let dcDifference = try receiveExtend(bitCount: Int(dcCategory), reader: &bitReader)
      let nextDC = dcPredictor.addingReportingOverflow(dcDifference)
      guard !nextDC.overflow,
        nextDC.partialValue >= Int(Int16.min),
        nextDC.partialValue <= Int(Int16.max)
      else { throw ImageCraftError.unsupportedOrCorruptImage }
      dcPredictor = nextDC.partialValue
      scratch.coefficients[0] = Int16(dcPredictor)

      var zigzagIndex = 1
      while zigzagIndex < 64 {
        let symbol = try decodeHuffmanSymbol(
          bytes: input,
          table: plan.acHuffman,
          reader: &bitReader
        )
        let zeroRun = Int(symbol >> 4)
        let valueBitCount = Int(symbol & 0x0F)
        if valueBitCount == 0 {
          if zeroRun == 0 { break }
          guard zeroRun == 15 else { throw ImageCraftError.unsupportedOrCorruptImage }
          zigzagIndex += 16
          guard zigzagIndex <= 64 else { throw ImageCraftError.unsupportedOrCorruptImage }
          continue
        }
        guard valueBitCount <= 10 else { throw ImageCraftError.unsupportedOrCorruptImage }
        zigzagIndex += zeroRun
        guard zigzagIndex < 64 else { throw ImageCraftError.unsupportedOrCorruptImage }
        let coefficient = try receiveExtend(bitCount: valueBitCount, reader: &bitReader)
        guard coefficient >= Int(Int16.min), coefficient <= Int(Int16.max) else {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
        scratch.coefficients[Self.jpegNaturalOrder[zigzagIndex]] = Int16(coefficient)
        zigzagIndex += 1
      }

      let blockX = mcuIndex % plan.blocksAcross
      let blockY = mcuIndex / plan.blocksAcross
      let pixelX = blockX * 8
      let pixelY = blockY * 8
      let writeWidth = min(8, plan.width - pixelX)
      let writeHeight = min(8, plan.height - pixelY)
      guard writeWidth > 0, writeHeight > 0, let destinationBase = destination.baseAddress else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      let destinationOffset = pixelY * plan.width + pixelX
      guard destinationOffset >= 0, destinationOffset < destination.count else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      let blockDestination = UnsafeMutableBufferPointer(
        start: destinationBase.advanced(by: destinationOffset),
        count: destination.count - destinationOffset
      )
      try JPEGISlowIDCT.writeBlockClipped(
        coefficients: UnsafeBufferPointer(scratch.coefficients),
        quantization: UnsafeBufferPointer(scratch.quantization),
        workspace: scratch.workspace,
        destination: blockDestination,
        destinationRowStride: plan.width,
        writeWidth: writeWidth,
        writeHeight: writeHeight
      )
    }

    try bitReader.finishEntropyByte()
    try bitReader.consumeMarker(expected: 0xD9)
    guard bitReader.offset == input.count else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
  }

  private func decodeHuffmanSymbol(
    bytes: UnsafeBufferPointer<UInt8>,
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
    if value >= threshold { return value }
    return value - ((1 << bitCount) - 1)
  }

  private struct HuffmanTableReference: Sendable {
    let countsRange: Range<Int>
    let symbolsRange: Range<Int>
    let symbolCount: Int
  }

  private struct DecodePlan: Sendable {
    let width: Int
    let height: Int
    let blocksAcross: Int
    let totalMCUCount: Int
    let quantizationRange: Range<Int>
    let dcHuffman: HuffmanTableReference
    let acHuffman: HuffmanTableReference
    let restartIntervalMCUs: Int
    let entropyStartOffset: Int

    static func inspect(_ data: Data) throws -> Self {
      try data.withUnsafeBytes { raw in
        let bytes = raw.bindMemory(to: UInt8.self)
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else {
          throw ImageCraftError.formatMismatch
        }

        var offset = 2
        var frame: Frame?
        var quantizationRanges = [Range<Int>?](repeating: nil, count: 4)
        var dcTables = [HuffmanTableReference?](repeating: nil, count: 4)
        var acTables = [HuffmanTableReference?](repeating: nil, count: 4)
        var restartInterval = 0

        while offset < bytes.count {
          let marker = try readMarker(bytes, offset: &offset)
          switch marker {
          case 0xD9:
            throw ImageCraftError.unsupportedOrCorruptImage
          case 0x01:
            continue
          case 0xD0...0xD7, 0xD8:
            throw ImageCraftError.unsupportedOrCorruptImage
          default:
            break
          }

          let segment = try segmentRange(bytes, lengthOffset: offset)
          offset = segment.end
          switch marker {
          case 0xC0:
            guard frame == nil else { throw ImageCraftError.unsupportedOrCorruptImage }
            frame = try parseFrame(bytes, segment: segment)
          case 0xC1...0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF:
            throw JPEGIndependentBaselineGrayscaleError.unsupportedSourceSemantics
          case 0xDB:
            try parseQuantizationTables(
              bytes,
              segment: segment,
              ranges: &quantizationRanges
            )
          case 0xC4:
            try parseHuffmanTables(
              bytes,
              segment: segment,
              dcTables: &dcTables,
              acTables: &acTables
            )
          case 0xDD:
            guard segment.payload.count == 2 else {
              throw ImageCraftError.unsupportedOrCorruptImage
            }
            restartInterval = Int(bytes[segment.payload.lowerBound]) << 8
              | Int(bytes[segment.payload.lowerBound + 1])
          case 0xCC, 0xDC:
            throw JPEGIndependentBaselineGrayscaleError.unsupportedSourceSemantics
          case 0xDA:
            guard let frame else { throw ImageCraftError.unsupportedOrCorruptImage }
            return try parseScan(
              bytes,
              segment: segment,
              entropyStartOffset: segment.end,
              frame: frame,
              quantizationRanges: quantizationRanges,
              dcTables: dcTables,
              acTables: acTables,
              restartInterval: restartInterval
            )
          default:
            continue
          }
        }
        throw ImageCraftError.unsupportedOrCorruptImage
      }
    }

    private struct Frame: Sendable {
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
        throw JPEGIndependentBaselineGrayscaleError.unsupportedSourceSemantics
      }
      let start = segment.payload.lowerBound
      let precision = Int(bytes[start])
      let height = Int(bytes[start + 1]) << 8 | Int(bytes[start + 2])
      let width = Int(bytes[start + 3]) << 8 | Int(bytes[start + 4])
      let componentCount = Int(bytes[start + 5])
      guard precision == 8, width > 0, height > 0, componentCount == 1 else {
        throw JPEGIndependentBaselineGrayscaleError.unsupportedSourceSemantics
      }
      let componentID = bytes[start + 6]
      let sampling = bytes[start + 7]
      let quantizationTableIndex = Int(bytes[start + 8])
      guard sampling == 0x11, (0...3).contains(quantizationTableIndex) else {
        throw JPEGIndependentBaselineGrayscaleError.unsupportedSourceSemantics
      }
      return Frame(
        width: width,
        height: height,
        componentID: componentID,
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
        else { throw JPEGIndependentBaselineGrayscaleError.unsupportedSourceSemantics }
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
        for index in countsRange {
          symbolCount += Int(bytes[index])
        }
        cursor += 16
        guard symbolCount > 0, symbolCount <= 256,
          cursor + symbolCount <= segment.payload.upperBound
        else { throw ImageCraftError.unsupportedOrCorruptImage }
        let reference = HuffmanTableReference(
          countsRange: countsRange,
          symbolsRange: cursor..<(cursor + symbolCount),
          symbolCount: symbolCount
        )
        try validateHuffmanTree(bytes, table: reference)
        if tableClass == 0 {
          dcTables[tableIndex] = reference
        } else {
          acTables[tableIndex] = reference
        }
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
          // JPEG forbids an all-ones Huffman code, matching jpeg_make_d_derived_tbl().
          throw ImageCraftError.unsupportedOrCorruptImage
        }
        nextCode = after.partialValue << 1
      }
    }

    private static func parseScan(
      _ bytes: UnsafeBufferPointer<UInt8>,
      segment: Segment,
      entropyStartOffset: Int,
      frame: Frame,
      quantizationRanges: [Range<Int>?],
      dcTables: [HuffmanTableReference?],
      acTables: [HuffmanTableReference?],
      restartInterval: Int
    ) throws -> Self {
      guard segment.payload.count == 6 else {
        throw JPEGIndependentBaselineGrayscaleError.unsupportedSourceSemantics
      }
      let start = segment.payload.lowerBound
      guard bytes[start] == 1,
        bytes[start + 1] == frame.componentID,
        bytes[start + 3] == 0,
        bytes[start + 4] == 63,
        bytes[start + 5] == 0
      else { throw JPEGIndependentBaselineGrayscaleError.unsupportedSourceSemantics }

      // Payload layout is Ns, Cs1, TdTa, Ss, Se, AhAl.
      let tableSelectors = bytes[start + 2]
      let dcIndex = Int(tableSelectors >> 4)
      let acIndex = Int(tableSelectors & 0x0F)
      guard (0...3).contains(dcIndex), (0...3).contains(acIndex),
        let quantizationRange = quantizationRanges[frame.quantizationTableIndex],
        let dcHuffman = dcTables[dcIndex],
        let acHuffman = acTables[acIndex]
      else { throw ImageCraftError.unsupportedOrCorruptImage }
      let blocksAcross = try ceilDiv(frame.width, 8)
      let blocksDown = try ceilDiv(frame.height, 8)
      let totalMCUCount = try multiplied(blocksAcross, blocksDown)
      return Self(
        width: frame.width,
        height: frame.height,
        blocksAcross: blocksAcross,
        totalMCUCount: totalMCUCount,
        quantizationRange: quantizationRange,
        dcHuffman: dcHuffman,
        acHuffman: acHuffman,
        restartIntervalMCUs: restartInterval,
        entropyStartOffset: entropyStartOffset
      )
    }

    private static func ceilDiv(_ value: Int, _ divisor: Int) throws -> Int {
      guard value > 0, divisor > 0 else { throw ImageCraftError.unsupportedOrCorruptImage }
      return value / divisor + (value % divisor == 0 ? 0 : 1)
    }
  }

  private final class Scratch {
    private let baseAddress: UnsafeMutableRawPointer
    let coefficients: UnsafeMutableBufferPointer<Int16>
    let quantization: UnsafeMutableBufferPointer<UInt16>
    let workspace: UnsafeMutableBufferPointer<Int32>

    init() throws {
      var pointer: UnsafeMutableRawPointer?
      guard posix_memalign(&pointer, 64, JPEGIndependentBaselineGrayscaleDecoder.fixedScratchByteCount) == 0,
        let pointer
      else { throw JPEGIndependentBaselineGrayscaleError.scratchAllocationFailed }
      baseAddress = pointer
      memset(pointer, 0, JPEGIndependentBaselineGrayscaleDecoder.fixedScratchByteCount)
      coefficients = UnsafeMutableBufferPointer(
        start: pointer.assumingMemoryBound(to: Int16.self),
        count: 64
      )
      quantization = UnsafeMutableBufferPointer(
        start: pointer.advanced(by: 128).assumingMemoryBound(to: UInt16.self),
        count: 64
      )
      workspace = UnsafeMutableBufferPointer(
        start: pointer.advanced(by: 256).assumingMemoryBound(to: Int32.self),
        count: 64
      )
    }

    deinit { free(baseAddress) }

    func clearCoefficientBlock() {
      memset(coefficients.baseAddress!, 0, 128)
    }

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
        quantization[JPEGIndependentBaselineGrayscaleDecoder.jpegNaturalOrder[zigzagIndex]] = value
      }
    }
  }

  private struct EntropyBitReader {
    let bytes: UnsafeBufferPointer<UInt8>
    var offset: Int
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
      for _ in 0..<count {
        value = (value << 1) | UInt32(try readBit())
      }
      return value
    }

    mutating func finishEntropyByte() throws {
      if bitsRemaining > 0 {
        let mask = UInt8((1 << bitsRemaining) - 1)
        guard currentByte & mask == mask else {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
      }
      currentByte = 0
      bitsRemaining = 0
    }

    mutating func consumeMarker(expected: UInt8) throws {
      guard bitsRemaining == 0, offset < bytes.count, bytes[offset] == 0xFF else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      while offset < bytes.count, bytes[offset] == 0xFF { offset += 1 }
      guard offset < bytes.count, bytes[offset] == expected else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      offset += 1
    }

    private mutating func readEntropyByte() throws -> UInt8 {
      guard offset < bytes.count else { throw ImageCraftError.unsupportedOrCorruptImage }
      let value = bytes[offset]
      offset += 1
      if value != 0xFF { return value }
      while offset < bytes.count, bytes[offset] == 0xFF { offset += 1 }
      guard offset < bytes.count, bytes[offset] == 0x00 else {
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
