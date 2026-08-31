import Darwin
import Foundation
import ImageCraftCore

package enum JPEGIndependentBaseline444Error: Error, Equatable, Sendable {
  case unsupportedSourceSemantics
  case invalidOperationBudget
  case operationBudgetExceeded(requiredBytes: Int, maximumBytes: Int)
  case scratchAllocationFailed
}

package struct JPEGIndependentBaseline444Image: Equatable, Sendable {
  package let width: Int
  package let height: Int
  package let rgb: Data
  package let restartIntervalMCUs: Int
  package let decodedMCUCount: Int
  package let fixedScratchByteCount: Int
  package let operationByteCharge: Int
}

/// Package-only complete-input baseline JFIF 4:4:4 JPEG slice.
///
/// The qualified domain is deliberately narrow: 8-bit SOF0, exactly three components with IDs
/// 1/2/3, 1x1 sampling for every component, JFIF APP0 authority, one interleaved sequential Huffman
/// scan, 8-bit DQT, optional DRI/RST, and no DNL/arithmetic coding. The encoded Data is caller-owned.
/// ImageCraft admits tight RGB output plus one fixed 704-byte scratch backing before allocation:
/// 128 B current quantized coefficient block + 128 B current natural-order quantization table +
/// 256 B ISLOW workspace + three 64-byte full-resolution Y/Cb/Cr sample blocks. No frame-sized
/// coefficient or sample surface is retained.
package struct JPEGIndependentBaseline444Decoder: Sendable {
  package static let fixedScratchByteCount = 704
  private let maximumOperationByteCharge: Int
  private let maximumMetadataBytes: Int

  package init(
    maximumOperationByteCharge: Int,
    maximumMetadataBytes: Int = DecodeLimits.coreV1.maximumMetadataBytes
  ) {
    self.maximumOperationByteCharge = maximumOperationByteCharge
    self.maximumMetadataBytes = maximumMetadataBytes
  }

  package func decode(_ data: Data) throws -> JPEGIndependentBaseline444Image {
    guard maximumOperationByteCharge >= 0, maximumMetadataBytes >= 0 else {
      throw JPEGIndependentBaseline444Error.invalidOperationBudget
    }
    let security = try EncodedImageSecurityInspector.inspect(
      data,
      maximumMetadataBytes: maximumMetadataBytes,
      materializePNGICCProfile: false,
      materializeJPEGICCProfile: false
    )
    guard security.format == .jpeg else { throw ImageCraftError.formatMismatch }
    guard security.sourceColorProfile != .embeddedICC, security.embeddedICCProfile == nil else {
      throw JPEGIndependentBaseline444Error.unsupportedSourceSemantics
    }

    let plan = try DecodePlan.inspect(data)
    let pixelCount = try Self.multiplied(plan.width, plan.height)
    let outputByteCount = try Self.multiplied(pixelCount, 3)
    let operationByteCharge = try Self.added(outputByteCount, Self.fixedScratchByteCount)
    guard operationByteCharge <= maximumOperationByteCharge else {
      throw JPEGIndependentBaseline444Error.operationBudgetExceeded(
        requiredBytes: operationByteCharge,
        maximumBytes: maximumOperationByteCharge
      )
    }

    let scratch = try Scratch()
    var output = Data(count: outputByteCount)
    try data.withUnsafeBytes { rawInput in
      let input = rawInput.bindMemory(to: UInt8.self)
      try output.withUnsafeMutableBytes { rawOutput in
        let destination = rawOutput.bindMemory(to: UInt8.self)
        try decodeScan(
          input: input,
          plan: plan,
          scratch: scratch,
          destination: destination
        )
      }
    }

    return JPEGIndependentBaseline444Image(
      width: plan.width,
      height: plan.height,
      rgb: output,
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
    var reader = EntropyBitReader(bytes: input, offset: plan.entropyStartOffset)
    var predictors = [Int](repeating: 0, count: 3)
    var restartIndex = 0

    for mcuIndex in 0..<plan.totalMCUCount {
      if plan.restartIntervalMCUs > 0,
        mcuIndex > 0,
        mcuIndex % plan.restartIntervalMCUs == 0
      {
        try reader.finishEntropyByte()
        try reader.consumeMarker(expected: UInt8(0xD0 + (restartIndex & 7)))
        restartIndex += 1
        predictors = [0, 0, 0]
      }

      for scanComponent in plan.scanComponents {
        scratch.clearCoefficientBlock()
        try scratch.loadQuantization(
          from: input,
          range: scanComponent.quantizationRange
        )
        try decodeSequentialBlock(
          input: input,
          dcTable: scanComponent.dcHuffman,
          acTable: scanComponent.acHuffman,
          predictor: &predictors[scanComponent.componentIndex],
          coefficients: scratch.coefficients,
          reader: &reader
        )
        let target: UnsafeMutableBufferPointer<UInt8>
        switch scanComponent.componentIndex {
        case 0: target = scratch.y
        case 1: target = scratch.cb
        case 2: target = scratch.cr
        default: throw ImageCraftError.unsupportedOrCorruptImage
        }
        try JPEGISlowIDCT.writeBlock(
          coefficients: UnsafeBufferPointer(scratch.coefficients),
          quantization: UnsafeBufferPointer(scratch.quantization),
          workspace: scratch.workspace,
          destination: target
        )
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
      let destinationOffset = (pixelY * plan.width + pixelX) * 3
      guard destinationOffset >= 0, destinationOffset < destination.count else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      let blockDestination = UnsafeMutableBufferPointer(
        start: destinationBase.advanced(by: destinationOffset),
        count: destination.count - destinationOffset
      )
      try JPEGYCbCrToRGB.writePlanarRGB(
        y: UnsafeBufferPointer(scratch.y),
        cb: UnsafeBufferPointer(scratch.cb),
        cr: UnsafeBufferPointer(scratch.cr),
        destination: blockDestination,
        destinationPixelStride: 3,
        destinationRowStride: plan.width * 3,
        writeWidth: writeWidth,
        writeHeight: writeHeight,
        sourceRowStride: 8
      )
    }

    try reader.finishEntropyByte()
    try reader.consumeMarker(expected: 0xD9)
    guard reader.offset == input.count else {
      throw JPEGIndependentBaseline444Error.unsupportedSourceSemantics
    }
  }

  private func decodeSequentialBlock(
    input: UnsafeBufferPointer<UInt8>,
    dcTable: HuffmanTableReference,
    acTable: HuffmanTableReference,
    predictor: inout Int,
    coefficients: UnsafeMutableBufferPointer<Int16>,
    reader: inout EntropyBitReader
  ) throws {
    let dcCategory = try decodeHuffmanSymbol(input: input, table: dcTable, reader: &reader)
    guard dcCategory <= 11 else { throw ImageCraftError.unsupportedOrCorruptImage }
    let dcDifference = try receiveExtend(bitCount: Int(dcCategory), reader: &reader)
    let next = predictor.addingReportingOverflow(dcDifference)
    guard !next.overflow,
      next.partialValue >= Int(Int16.min),
      next.partialValue <= Int(Int16.max)
    else { throw ImageCraftError.unsupportedOrCorruptImage }
    predictor = next.partialValue
    coefficients[0] = Int16(predictor)

    var zigzagIndex = 1
    while zigzagIndex < 64 {
      let symbol = try decodeHuffmanSymbol(input: input, table: acTable, reader: &reader)
      let zeroRun = Int(symbol >> 4)
      let bitCount = Int(symbol & 0x0F)
      if bitCount == 0 {
        if zeroRun == 0 { break }
        guard zeroRun == 15 else { throw ImageCraftError.unsupportedOrCorruptImage }
        zigzagIndex += 16
        guard zigzagIndex <= 64 else { throw ImageCraftError.unsupportedOrCorruptImage }
        continue
      }
      guard bitCount <= 10 else { throw ImageCraftError.unsupportedOrCorruptImage }
      zigzagIndex += zeroRun
      guard zigzagIndex < 64 else { throw ImageCraftError.unsupportedOrCorruptImage }
      let value = try receiveExtend(bitCount: bitCount, reader: &reader)
      guard value >= Int(Int16.min), value <= Int(Int16.max) else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      coefficients[Self.jpegNaturalOrder[zigzagIndex]] = Int16(value)
      zigzagIndex += 1
    }
  }

  private func decodeHuffmanSymbol(
    input: UnsafeBufferPointer<UInt8>,
    table: HuffmanTableReference,
    reader: inout EntropyBitReader
  ) throws -> UInt8 {
    var code = 0
    var firstCode = 0
    var symbolBase = 0
    for length in 1...16 {
      code = (code << 1) | Int(try reader.readBit())
      let count = Int(input[table.countsRange.lowerBound + length - 1])
      if count > 0, code >= firstCode, code < firstCode + count {
        let symbolIndex = symbolBase + (code - firstCode)
        guard symbolIndex >= 0, symbolIndex < table.symbolCount else {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
        return input[table.symbolsRange.lowerBound + symbolIndex]
      }
      symbolBase += count
      firstCode = (firstCode + count) << 1
    }
    throw ImageCraftError.unsupportedOrCorruptImage
  }

  private func receiveExtend(bitCount: Int, reader: inout EntropyBitReader) throws -> Int {
    guard (0...16).contains(bitCount) else { throw ImageCraftError.unsupportedOrCorruptImage }
    if bitCount == 0 { return 0 }
    let value = Int(try reader.readBits(bitCount))
    let threshold = 1 << (bitCount - 1)
    return value >= threshold ? value : value - ((1 << bitCount) - 1)
  }

  private struct HuffmanTableReference: Sendable {
    let countsRange: Range<Int>
    let symbolsRange: Range<Int>
    let symbolCount: Int
  }

  private struct ScanComponent: Sendable {
    let componentIndex: Int
    let quantizationRange: Range<Int>
    let dcHuffman: HuffmanTableReference
    let acHuffman: HuffmanTableReference
  }

  private struct DecodePlan: Sendable {
    let width: Int
    let height: Int
    let blocksAcross: Int
    let totalMCUCount: Int
    let scanComponents: [ScanComponent]
    let restartIntervalMCUs: Int
    let entropyStartOffset: Int

    private struct FrameComponent {
      let id: UInt8
      let quantizationTableIndex: Int
    }

    private struct Segment {
      let payload: Range<Int>
      let end: Int
    }

    static func inspect(_ data: Data) throws -> Self {
      try data.withUnsafeBytes { raw in
        let bytes = raw.bindMemory(to: UInt8.self)
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else {
          throw ImageCraftError.formatMismatch
        }
        var offset = 2
        var sawJFIF = false
        var hasProcessedMarkerAfterSOI = false
        var width: Int?
        var height: Int?
        var frameComponents: [FrameComponent]?
        var quantizationRanges = [Range<Int>?](repeating: nil, count: 4)
        var dcTables = [HuffmanTableReference?](repeating: nil, count: 4)
        var acTables = [HuffmanTableReference?](repeating: nil, count: 4)
        var restartInterval = 0

        while offset < bytes.count {
          let marker = try readMarker(bytes, offset: &offset)
          let isFirstMarkerAfterSOI = !hasProcessedMarkerAfterSOI
          hasProcessedMarkerAfterSOI = true
          switch marker {
          case 0xD9:
            throw ImageCraftError.unsupportedOrCorruptImage
          case 0x01:
            continue
          case 0xD0...0xD8:
            throw ImageCraftError.unsupportedOrCorruptImage
          default:
            break
          }
          let segment = try segmentRange(bytes, lengthOffset: offset)
          offset = segment.end
          switch marker {
          case 0xE0:
            if let qualified = JPEGIndependentJFIFColorAuthority.jfifAPP0IsStructurallyQualified(
              bytes,
              payload: segment.payload
            ) {
              guard qualified, isFirstMarkerAfterSOI else {
                throw JPEGIndependentBaseline444Error.unsupportedSourceSemantics
              }
              sawJFIF = true
            }
          case 0xEE:
            if JPEGIndependentJFIFColorAuthority.adobeAPP14IsQualifiedYCbCr(
              bytes,
              payload: segment.payload
            ) == false {
              throw JPEGIndependentBaseline444Error.unsupportedSourceSemantics
            }
          case 0xC0:
            guard frameComponents == nil else { throw ImageCraftError.unsupportedOrCorruptImage }
            let frame = try parseFrame(bytes, segment: segment)
            width = frame.width
            height = frame.height
            frameComponents = frame.components
          case 0xC1...0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF:
            throw JPEGIndependentBaseline444Error.unsupportedSourceSemantics
          case 0xDB:
            try parseQuantizationTables(bytes, segment: segment, ranges: &quantizationRanges)
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
            throw JPEGIndependentBaseline444Error.unsupportedSourceSemantics
          case 0xDA:
            guard sawJFIF, let width, let height, let frameComponents else {
              throw JPEGIndependentBaseline444Error.unsupportedSourceSemantics
            }
            return try parseScan(
              bytes,
              segment: segment,
              entropyStartOffset: segment.end,
              width: width,
              height: height,
              frameComponents: frameComponents,
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

    private static func parseFrame(
      _ bytes: UnsafeBufferPointer<UInt8>,
      segment: Segment
    ) throws -> (width: Int, height: Int, components: [FrameComponent]) {
      guard segment.payload.count == 15 else {
        throw JPEGIndependentBaseline444Error.unsupportedSourceSemantics
      }
      let start = segment.payload.lowerBound
      let precision = Int(bytes[start])
      let height = Int(bytes[start + 1]) << 8 | Int(bytes[start + 2])
      let width = Int(bytes[start + 3]) << 8 | Int(bytes[start + 4])
      guard precision == 8, width > 0, height > 0, bytes[start + 5] == 3 else {
        throw JPEGIndependentBaseline444Error.unsupportedSourceSemantics
      }
      var components: [FrameComponent] = []
      for index in 0..<3 {
        let base = start + 6 + index * 3
        let id = bytes[base]
        let sampling = bytes[base + 1]
        let quantization = Int(bytes[base + 2])
        guard id == UInt8(index + 1), sampling == 0x11, (0...3).contains(quantization) else {
          throw JPEGIndependentBaseline444Error.unsupportedSourceSemantics
        }
        components.append(FrameComponent(id: id, quantizationTableIndex: quantization))
      }
      return (width, height, components)
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
        else { throw JPEGIndependentBaseline444Error.unsupportedSourceSemantics }
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
      entropyStartOffset: Int,
      width: Int,
      height: Int,
      frameComponents: [FrameComponent],
      quantizationRanges: [Range<Int>?],
      dcTables: [HuffmanTableReference?],
      acTables: [HuffmanTableReference?],
      restartInterval: Int
    ) throws -> Self {
      guard segment.payload.count == 10 else {
        throw JPEGIndependentBaseline444Error.unsupportedSourceSemantics
      }
      let start = segment.payload.lowerBound
      guard bytes[start] == 3,
        bytes[start + 7] == 0,
        bytes[start + 8] == 63,
        bytes[start + 9] == 0
      else { throw JPEGIndependentBaseline444Error.unsupportedSourceSemantics }

      var scanComponents: [ScanComponent] = []
      var seen = Set<Int>()
      for scanIndex in 0..<3 {
        let base = start + 1 + scanIndex * 2
        let componentID = bytes[base]
        guard let componentIndex = frameComponents.firstIndex(where: { $0.id == componentID }),
          !seen.contains(componentIndex)
        else { throw ImageCraftError.unsupportedOrCorruptImage }
        seen.insert(componentIndex)
        let selectors = bytes[base + 1]
        let dcIndex = Int(selectors >> 4)
        let acIndex = Int(selectors & 0x0F)
        let quantIndex = frameComponents[componentIndex].quantizationTableIndex
        guard (0...3).contains(dcIndex), (0...3).contains(acIndex),
          let quantizationRange = quantizationRanges[quantIndex],
          let dc = dcTables[dcIndex],
          let ac = acTables[acIndex]
        else { throw ImageCraftError.unsupportedOrCorruptImage }
        scanComponents.append(
          ScanComponent(
            componentIndex: componentIndex,
            quantizationRange: quantizationRange,
            dcHuffman: dc,
            acHuffman: ac
          )
        )
      }
      guard seen.count == 3 else { throw ImageCraftError.unsupportedOrCorruptImage }
      let blocksAcross = try JPEGIndependentBaseline444Decoder.ceilDiv(width, 8)
      let blocksDown = try JPEGIndependentBaseline444Decoder.ceilDiv(height, 8)
      let totalMCUCount = try JPEGIndependentBaseline444Decoder.multiplied(
        blocksAcross,
        blocksDown
      )
      return Self(
        width: width,
        height: height,
        blocksAcross: blocksAcross,
        totalMCUCount: totalMCUCount,
        scanComponents: scanComponents,
        restartIntervalMCUs: restartInterval,
        entropyStartOffset: entropyStartOffset
      )
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
  }

  private final class Scratch {
    private let baseAddress: UnsafeMutableRawPointer
    let coefficients: UnsafeMutableBufferPointer<Int16>
    let quantization: UnsafeMutableBufferPointer<UInt16>
    let workspace: UnsafeMutableBufferPointer<Int32>
    let y: UnsafeMutableBufferPointer<UInt8>
    let cb: UnsafeMutableBufferPointer<UInt8>
    let cr: UnsafeMutableBufferPointer<UInt8>

    init() throws {
      var pointer: UnsafeMutableRawPointer?
      guard posix_memalign(&pointer, 64, JPEGIndependentBaseline444Decoder.fixedScratchByteCount) == 0,
        let pointer
      else { throw JPEGIndependentBaseline444Error.scratchAllocationFailed }
      baseAddress = pointer
      memset(pointer, 0, JPEGIndependentBaseline444Decoder.fixedScratchByteCount)
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
      y = UnsafeMutableBufferPointer(
        start: pointer.advanced(by: 512).assumingMemoryBound(to: UInt8.self),
        count: 64
      )
      cb = UnsafeMutableBufferPointer(
        start: pointer.advanced(by: 576).assumingMemoryBound(to: UInt8.self),
        count: 64
      )
      cr = UnsafeMutableBufferPointer(
        start: pointer.advanced(by: 640).assumingMemoryBound(to: UInt8.self),
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
        quantization[JPEGIndependentBaseline444Decoder.jpegNaturalOrder[zigzagIndex]] = value
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
