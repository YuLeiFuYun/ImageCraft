import Darwin
import Foundation
import ImageCraftCore

package enum JPEGIndependentBaseline420Error: Error, Equatable, Sendable {
  case unsupportedSourceSemantics
  case invalidOperationBudget
  case operationBudgetExceeded(requiredBytes: Int, maximumBytes: Int)
  case stateAllocationFailed(byteCount: Int)
}

package struct JPEGIndependentBaseline420StatePlan: Codable, Equatable, Sendable {
  package static let rowAlignmentBytes = 64
  package static let coefficientScratchBytes = 128
  package static let quantizationScratchBytes = 128
  package static let idctWorkspaceBytes = 256
  package static let fixedScratchBytes = 512

  package let width: Int
  package let height: Int
  package let chromaWidth: Int
  package let yRowStrideBytes: Int
  package let chromaRowStrideBytes: Int
  package let yStripBytes: Int
  package let chromaStripBytesPerComponent: Int
  package let deferredYRowBytes: Int
  package let previousChromaRowBytesPerComponent: Int
  package let reconstructedChromaRowBytesPerComponent: Int
  package let totalStateBytes: Int
  package let usesFancyGlobalContext: Bool

  package static func inspect(_ data: Data) throws -> Self {
    let frame = try JPEGFrameSamplingGeometry.inspect(data)
    guard frame.codingMode == .baselineDCT,
      frame.samplingMode == .threeComponent420,
      frame.precision == 8
    else { throw JPEGIndependentBaseline420Error.unsupportedSourceSemantics }
    return try make(width: frame.width, height: frame.height)
  }

  package static func make(width: Int, height: Int) throws -> Self {
    guard width > 0, height > 0 else { throw ImageCraftError.unsupportedOrCorruptImage }
    let chromaWidth = try ceilDiv(width, 2)
    let yStride = try roundUp(width, rowAlignmentBytes)
    let chromaStride = try roundUp(chromaWidth, rowAlignmentBytes)
    let yStrip = try multiplied(yStride, 16)
    let chromaStrip = try multiplied(chromaStride, 8)
    let deferredY = yStride
    let previousChroma = chromaStride
    let reconstructedChroma = yStride

    var total = fixedScratchBytes
    total = try added(total, yStrip)
    total = try added(total, try multiplied(chromaStrip, 2))
    total = try added(total, deferredY)
    total = try added(total, try multiplied(previousChroma, 2))
    total = try added(total, try multiplied(reconstructedChroma, 2))
    return Self(
      width: width,
      height: height,
      chromaWidth: chromaWidth,
      yRowStrideBytes: yStride,
      chromaRowStrideBytes: chromaStride,
      yStripBytes: yStrip,
      chromaStripBytesPerComponent: chromaStrip,
      deferredYRowBytes: deferredY,
      previousChromaRowBytesPerComponent: previousChroma,
      reconstructedChromaRowBytesPerComponent: reconstructedChroma,
      totalStateBytes: total,
      usesFancyGlobalContext: chromaWidth > 2
    )
  }

  private static func ceilDiv(_ value: Int, _ divisor: Int) throws -> Int {
    guard value > 0, divisor > 0 else { throw ImageCraftError.unsupportedOrCorruptImage }
    return value / divisor + (value % divisor == 0 ? 0 : 1)
  }

  private static func roundUp(_ value: Int, _ alignment: Int) throws -> Int {
    guard value >= 0, alignment > 0, alignment & (alignment - 1) == 0 else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    let adjusted = try added(value, alignment - 1)
    return adjusted & ~(alignment - 1)
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

package struct JPEGIndependentBaseline420Image: Equatable, Sendable {
  package let width: Int
  package let height: Int
  package let rgb: Data
  package let restartIntervalMCUs: Int
  package let decodedMCUCount: Int
  package let statePlan: JPEGIndependentBaseline420StatePlan
  package let operationByteCharge: Int
}

/// Package-only complete-input baseline JFIF 4:2:0 JPEG slice with ImageCraft-owned strip state.
///
/// The qualified domain is intentionally narrow: 8-bit SOF0, JFIF YCbCr authority, component IDs
/// 1/2/3 with 2x2/1x1/1x1 sampling, one interleaved sequential Huffman scan in 1/2/3 order,
/// 8-bit DQT, optional DRI/RST markers, no arithmetic coding and no DNL. The encoded `Data` is
/// caller-owned.
///
/// The decoder never retains a frame-sized coefficient or chroma surface. It owns one 16-row Y
/// iMCU strip, one 8-row Cb/Cr strip, a single deferred Y boundary row, one prior low-resolution
/// Cb/Cr context row and two reconstructed full-width chroma rows. Width-dependent state is admitted
/// exactly before allocation. For downsampled widths > 2, the bottom output row of an iMCU strip is
/// delayed until the next strip supplies the global vertical chroma context; narrower sources use
/// libjpeg's box-filter branch and require no cross-iMCU context.
package struct JPEGIndependentBaseline420Decoder: Sendable {
  private let maximumOperationByteCharge: Int
  private let maximumMetadataBytes: Int

  package init(
    maximumOperationByteCharge: Int,
    maximumMetadataBytes: Int = DecodeLimits.coreV1.maximumMetadataBytes
  ) {
    self.maximumOperationByteCharge = maximumOperationByteCharge
    self.maximumMetadataBytes = maximumMetadataBytes
  }

  package func decode(_ data: Data) throws -> JPEGIndependentBaseline420Image {
    guard maximumOperationByteCharge >= 0, maximumMetadataBytes >= 0 else {
      throw JPEGIndependentBaseline420Error.invalidOperationBudget
    }
    let security = try EncodedImageSecurityInspector.inspect(
      data,
      maximumMetadataBytes: maximumMetadataBytes,
      materializePNGICCProfile: false,
      materializeJPEGICCProfile: false
    )
    guard security.format == .jpeg else { throw ImageCraftError.formatMismatch }
    guard security.sourceColorProfile != .embeddedICC, security.embeddedICCProfile == nil else {
      throw JPEGIndependentBaseline420Error.unsupportedSourceSemantics
    }

    let statePlan = try JPEGIndependentBaseline420StatePlan.inspect(data)
    let plan = try DecodePlan.inspect(data)
    guard plan.width == statePlan.width, plan.height == statePlan.height else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    let pixelCount = try Self.multiplied(plan.width, plan.height)
    let outputByteCount = try Self.multiplied(pixelCount, 3)
    let operationByteCharge = try Self.added(outputByteCount, statePlan.totalStateBytes)
    guard operationByteCharge <= maximumOperationByteCharge else {
      throw JPEGIndependentBaseline420Error.operationBudgetExceeded(
        requiredBytes: operationByteCharge,
        maximumBytes: maximumOperationByteCharge
      )
    }

    let state = try StateArena(plan: statePlan)
    var output = Data(count: outputByteCount)
    try data.withUnsafeBytes { rawInput in
      let input = rawInput.bindMemory(to: UInt8.self)
      try output.withUnsafeMutableBytes { rawOutput in
        let destination = rawOutput.bindMemory(to: UInt8.self)
        try decodeScan(input: input, plan: plan, state: state, destination: destination)
      }
    }

    return JPEGIndependentBaseline420Image(
      width: plan.width,
      height: plan.height,
      rgb: output,
      restartIntervalMCUs: plan.restartIntervalMCUs,
      decodedMCUCount: plan.totalMCUCount,
      statePlan: statePlan,
      operationByteCharge: operationByteCharge
    )
  }

  private func decodeScan(
    input: UnsafeBufferPointer<UInt8>,
    plan: DecodePlan,
    state: StateArena,
    destination: UnsafeMutableBufferPointer<UInt8>
  ) throws {
    var reader = EntropyBitReader(bytes: input, offset: plan.entropyStartOffset)
    var yPredictor = 0
    var cbPredictor = 0
    var crPredictor = 0
    var restartIndex = 0
    var globalMCUIndex = 0
    var hasDeferredBoundaryRow = false

    for iMCURow in 0..<plan.mcuRows {
      let outputRowBase = iMCURow * 16
      let outputRowsInStrip = min(16, plan.height - outputRowBase)
      let chromaRowBase = iMCURow * 8
      let chromaRowsInStrip = min(8, plan.chromaHeight - chromaRowBase)
      guard outputRowsInStrip > 0, chromaRowsInStrip > 0 else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }

      for mcuColumn in 0..<plan.mcuColumns {
        if plan.restartIntervalMCUs > 0,
          globalMCUIndex > 0,
          globalMCUIndex % plan.restartIntervalMCUs == 0
        {
          try reader.finishEntropyByte()
          try reader.consumeMarker(expected: UInt8(0xD0 + (restartIndex & 7)))
          restartIndex += 1
          yPredictor = 0
          cbPredictor = 0
          crPredictor = 0
        }

        for yBlock in 0..<4 {
          let blockRow = yBlock / 2
          let blockColumn = yBlock % 2
          let x = mcuColumn * 16 + blockColumn * 8
          let y = blockRow * 8
          try decodeBlock(
            input: input,
            component: plan.y,
            predictor: &yPredictor,
            state: state,
            reader: &reader,
            target: state.yStrip,
            targetRowStride: state.plan.yRowStrideBytes,
            targetX: x,
            targetY: y,
            logicalWidth: plan.width,
            logicalHeight: outputRowsInStrip
          )
        }
        try decodeBlock(
          input: input,
          component: plan.cb,
          predictor: &cbPredictor,
          state: state,
          reader: &reader,
          target: state.cbStrip,
          targetRowStride: state.plan.chromaRowStrideBytes,
          targetX: mcuColumn * 8,
          targetY: 0,
          logicalWidth: plan.chromaWidth,
          logicalHeight: chromaRowsInStrip
        )
        try decodeBlock(
          input: input,
          component: plan.cr,
          predictor: &crPredictor,
          state: state,
          reader: &reader,
          target: state.crStrip,
          targetRowStride: state.plan.chromaRowStrideBytes,
          targetX: mcuColumn * 8,
          targetY: 0,
          logicalWidth: plan.chromaWidth,
          logicalHeight: chromaRowsInStrip
        )
        globalMCUIndex += 1
      }

      if hasDeferredBoundaryRow {
        try renderDeferredBoundaryRow(
          currentIMCURow: iMCURow,
          plan: plan,
          state: state,
          destination: destination
        )
        hasDeferredBoundaryRow = false
      }

      let hasNextOutputStrip = outputRowBase + outputRowsInStrip < plan.height
      for localOutputRow in 0..<outputRowsInStrip {
        let needsFutureContext = state.plan.usesFancyGlobalContext
          && localOutputRow == 15
          && hasNextOutputStrip
        if needsFutureContext {
          try state.copyYRowToDeferred(localRow: localOutputRow, logicalWidth: plan.width)
          try state.copyChromaRowToPrevious(
            localRow: 7,
            logicalWidth: plan.chromaWidth
          )
          hasDeferredBoundaryRow = true
          continue
        }
        try renderCurrentRow(
          iMCURow: iMCURow,
          localOutputRow: localOutputRow,
          outputRowsInStrip: outputRowsInStrip,
          chromaRowsInStrip: chromaRowsInStrip,
          plan: plan,
          state: state,
          destination: destination
        )
      }

      if state.plan.usesFancyGlobalContext, !hasDeferredBoundaryRow, hasNextOutputStrip {
        // This can only happen if a future qualified sampling mode changes the 16-row output-iMCU
        // relationship without updating this decoder.
        throw ImageCraftError.unsupportedOrCorruptImage
      }
    }

    guard !hasDeferredBoundaryRow, globalMCUIndex == plan.totalMCUCount else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    try reader.finishEntropyByte()
    try reader.consumeMarker(expected: 0xD9)
    guard reader.offset == input.count else {
      throw JPEGIndependentBaseline420Error.unsupportedSourceSemantics
    }
  }

  private func renderDeferredBoundaryRow(
    currentIMCURow: Int,
    plan: DecodePlan,
    state: StateArena,
    destination: UnsafeMutableBufferPointer<UInt8>
  ) throws {
    guard state.plan.usesFancyGlobalContext, currentIMCURow > 0 else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    let currentCb = state.previousCbRowPrefix(plan.chromaWidth)
    let currentCr = state.previousCrRowPrefix(plan.chromaWidth)
    let adjacentCb = state.cbRow(localRow: 0, logicalWidth: plan.chromaWidth)
    let adjacentCr = state.crRow(localRow: 0, logicalWidth: plan.chromaWidth)
    try reconstructAndWriteRow(
      y: state.deferredYRowPrefix(plan.width),
      currentCb: currentCb,
      adjacentCb: adjacentCb,
      currentCr: currentCr,
      adjacentCr: adjacentCr,
      outputRow: currentIMCURow * 16 - 1,
      plan: plan,
      state: state,
      destination: destination
    )
  }

  private func renderCurrentRow(
    iMCURow: Int,
    localOutputRow: Int,
    outputRowsInStrip: Int,
    chromaRowsInStrip: Int,
    plan: DecodePlan,
    state: StateArena,
    destination: UnsafeMutableBufferPointer<UInt8>
  ) throws {
    guard localOutputRow >= 0, localOutputRow < outputRowsInStrip else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    let sourceRow = localOutputRow / 2
    guard sourceRow < chromaRowsInStrip else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    let currentCb = state.cbRow(localRow: sourceRow, logicalWidth: plan.chromaWidth)
    let currentCr = state.crRow(localRow: sourceRow, logicalWidth: plan.chromaWidth)

    let adjacentCb: UnsafeBufferPointer<UInt8>
    let adjacentCr: UnsafeBufferPointer<UInt8>
    if !state.plan.usesFancyGlobalContext {
      adjacentCb = currentCb
      adjacentCr = currentCr
    } else if localOutputRow & 1 == 0 {
      if sourceRow > 0 {
        adjacentCb = state.cbRow(localRow: sourceRow - 1, logicalWidth: plan.chromaWidth)
        adjacentCr = state.crRow(localRow: sourceRow - 1, logicalWidth: plan.chromaWidth)
      } else if iMCURow == 0 {
        adjacentCb = currentCb
        adjacentCr = currentCr
      } else {
        adjacentCb = state.previousCbRowPrefix(plan.chromaWidth)
        adjacentCr = state.previousCrRowPrefix(plan.chromaWidth)
      }
    } else if sourceRow + 1 < chromaRowsInStrip {
      adjacentCb = state.cbRow(localRow: sourceRow + 1, logicalWidth: plan.chromaWidth)
      adjacentCr = state.crRow(localRow: sourceRow + 1, logicalWidth: plan.chromaWidth)
    } else {
      let globalOutputRow = iMCURow * 16 + localOutputRow
      guard globalOutputRow + 1 >= plan.height else {
        // Internal strip bottoms must be deferred until the next low-resolution row exists.
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      adjacentCb = currentCb
      adjacentCr = currentCr
    }

    try reconstructAndWriteRow(
      y: state.yRow(localRow: localOutputRow, logicalWidth: plan.width),
      currentCb: currentCb,
      adjacentCb: adjacentCb,
      currentCr: currentCr,
      adjacentCr: adjacentCr,
      outputRow: iMCURow * 16 + localOutputRow,
      plan: plan,
      state: state,
      destination: destination
    )
  }

  private func reconstructAndWriteRow(
    y: UnsafeBufferPointer<UInt8>,
    currentCb: UnsafeBufferPointer<UInt8>,
    adjacentCb: UnsafeBufferPointer<UInt8>,
    currentCr: UnsafeBufferPointer<UInt8>,
    adjacentCr: UnsafeBufferPointer<UInt8>,
    outputRow: Int,
    plan: DecodePlan,
    state: StateArena,
    destination: UnsafeMutableBufferPointer<UInt8>
  ) throws {
    let reconstructedCb = state.reconstructedCbRowPrefix(plan.width)
    let reconstructedCr = state.reconstructedCrRowPrefix(plan.width)
    if state.plan.usesFancyGlobalContext {
      try JPEGCenteredChromaReconstruction.writeH2V2Row(
        current: currentCb,
        adjacent: adjacentCb,
        destination: reconstructedCb,
        outputWidth: plan.width
      )
      try JPEGCenteredChromaReconstruction.writeH2V2Row(
        current: currentCr,
        adjacent: adjacentCr,
        destination: reconstructedCr,
        outputWidth: plan.width
      )
    } else {
      try JPEGCenteredChromaReconstruction.writeH2V2BoxRow(
        source: currentCb,
        destination: reconstructedCb,
        outputWidth: plan.width
      )
      try JPEGCenteredChromaReconstruction.writeH2V2BoxRow(
        source: currentCr,
        destination: reconstructedCr,
        outputWidth: plan.width
      )
    }

    let rowBytes = try Self.multiplied(plan.width, 3)
    let offset = try Self.multiplied(outputRow, rowBytes)
    guard outputRow >= 0, outputRow < plan.height,
      let base = destination.baseAddress,
      offset >= 0,
      offset + rowBytes <= destination.count
    else { throw ImageCraftError.unsupportedOrCorruptImage }
    let output = UnsafeMutableBufferPointer(
      start: base.advanced(by: offset),
      count: rowBytes
    )
    try JPEGYCbCrToRGB.writePlanarRGBRow(
      y: y,
      cb: UnsafeBufferPointer(reconstructedCb),
      cr: UnsafeBufferPointer(reconstructedCr),
      destination: output,
      writeWidth: plan.width
    )
  }

  private func decodeBlock(
    input: UnsafeBufferPointer<UInt8>,
    component: ScanComponent,
    predictor: inout Int,
    state: StateArena,
    reader: inout EntropyBitReader,
    target: UnsafeMutableBufferPointer<UInt8>,
    targetRowStride: Int,
    targetX: Int,
    targetY: Int,
    logicalWidth: Int,
    logicalHeight: Int
  ) throws {
    state.clearCoefficientBlock()
    try state.loadQuantization(from: input, range: component.quantizationRange)
    try decodeSequentialBlock(
      input: input,
      dcTable: component.dcHuffman,
      acTable: component.acHuffman,
      predictor: &predictor,
      coefficients: state.coefficients,
      reader: &reader
    )

    let writeWidth = min(8, logicalWidth - targetX)
    let writeHeight = min(8, logicalHeight - targetY)
    guard targetX >= 0, targetY >= 0 else { throw ImageCraftError.unsupportedOrCorruptImage }
    if writeWidth <= 0 || writeHeight <= 0 { return }
    let offset = try Self.added(try Self.multiplied(targetY, targetRowStride), targetX)
    guard let base = target.baseAddress,
      offset >= 0,
      offset < target.count
    else { throw ImageCraftError.unsupportedOrCorruptImage }
    let targetSlice = UnsafeMutableBufferPointer(
      start: base.advanced(by: offset),
      count: target.count - offset
    )
    try JPEGISlowIDCT.writeBlockClipped(
      coefficients: UnsafeBufferPointer(state.coefficients),
      quantization: UnsafeBufferPointer(state.quantization),
      workspace: state.workspace,
      destination: targetSlice,
      destinationRowStride: targetRowStride,
      writeWidth: writeWidth,
      writeHeight: writeHeight
    )
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
    let quantizationRange: Range<Int>
    let dcHuffman: HuffmanTableReference
    let acHuffman: HuffmanTableReference
  }

  private struct DecodePlan: Sendable {
    let width: Int
    let height: Int
    let chromaWidth: Int
    let chromaHeight: Int
    let mcuColumns: Int
    let mcuRows: Int
    let totalMCUCount: Int
    let y: ScanComponent
    let cb: ScanComponent
    let cr: ScanComponent
    let restartIntervalMCUs: Int
    let entropyStartOffset: Int

    private struct FrameComponent {
      let id: UInt8
      let sampling: UInt8
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
        var frameY: FrameComponent?
        var frameCb: FrameComponent?
        var frameCr: FrameComponent?
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
                throw JPEGIndependentBaseline420Error.unsupportedSourceSemantics
              }
              sawJFIF = true
            }
          case 0xEE:
            if JPEGIndependentJFIFColorAuthority.adobeAPP14IsQualifiedYCbCr(
              bytes,
              payload: segment.payload
            ) == false {
              throw JPEGIndependentBaseline420Error.unsupportedSourceSemantics
            }
          case 0xC0:
            guard frameY == nil, frameCb == nil, frameCr == nil else {
              throw ImageCraftError.unsupportedOrCorruptImage
            }
            let frame = try parseFrame(bytes, segment: segment)
            width = frame.width
            height = frame.height
            frameY = frame.y
            frameCb = frame.cb
            frameCr = frame.cr
          case 0xC1...0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF:
            throw JPEGIndependentBaseline420Error.unsupportedSourceSemantics
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
            throw JPEGIndependentBaseline420Error.unsupportedSourceSemantics
          case 0xDA:
            guard sawJFIF,
              let width,
              let height,
              let frameY,
              let frameCb,
              let frameCr
            else { throw JPEGIndependentBaseline420Error.unsupportedSourceSemantics }
            return try parseScan(
              bytes,
              segment: segment,
              entropyStartOffset: segment.end,
              width: width,
              height: height,
              frameY: frameY,
              frameCb: frameCb,
              frameCr: frameCr,
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
    ) throws -> (width: Int, height: Int, y: FrameComponent, cb: FrameComponent, cr: FrameComponent) {
      guard segment.payload.count == 15 else {
        throw JPEGIndependentBaseline420Error.unsupportedSourceSemantics
      }
      let start = segment.payload.lowerBound
      let precision = Int(bytes[start])
      let height = Int(bytes[start + 1]) << 8 | Int(bytes[start + 2])
      let width = Int(bytes[start + 3]) << 8 | Int(bytes[start + 4])
      guard precision == 8, width > 0, height > 0, bytes[start + 5] == 3 else {
        throw JPEGIndependentBaseline420Error.unsupportedSourceSemantics
      }
      func component(_ index: Int, expectedID: UInt8, expectedSampling: UInt8) throws -> FrameComponent {
        let base = start + 6 + index * 3
        let id = bytes[base]
        let sampling = bytes[base + 1]
        let quantization = Int(bytes[base + 2])
        guard id == expectedID, sampling == expectedSampling, (0...3).contains(quantization) else {
          throw JPEGIndependentBaseline420Error.unsupportedSourceSemantics
        }
        return FrameComponent(id: id, sampling: sampling, quantizationTableIndex: quantization)
      }
      return (
        width,
        height,
        try component(0, expectedID: 1, expectedSampling: 0x22),
        try component(1, expectedID: 2, expectedSampling: 0x11),
        try component(2, expectedID: 3, expectedSampling: 0x11)
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
        else { throw JPEGIndependentBaseline420Error.unsupportedSourceSemantics }
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
      frameY: FrameComponent,
      frameCb: FrameComponent,
      frameCr: FrameComponent,
      quantizationRanges: [Range<Int>?],
      dcTables: [HuffmanTableReference?],
      acTables: [HuffmanTableReference?],
      restartInterval: Int
    ) throws -> Self {
      guard segment.payload.count == 10 else {
        throw JPEGIndependentBaseline420Error.unsupportedSourceSemantics
      }
      let start = segment.payload.lowerBound
      guard bytes[start] == 3,
        bytes[start + 1] == 1,
        bytes[start + 3] == 2,
        bytes[start + 5] == 3,
        bytes[start + 7] == 0,
        bytes[start + 8] == 63,
        bytes[start + 9] == 0
      else { throw JPEGIndependentBaseline420Error.unsupportedSourceSemantics }

      func scanComponent(
        selectorOffset: Int,
        frame: FrameComponent
      ) throws -> ScanComponent {
        let selectors = bytes[start + selectorOffset]
        let dcIndex = Int(selectors >> 4)
        let acIndex = Int(selectors & 0x0F)
        guard (0...3).contains(dcIndex), (0...3).contains(acIndex),
          let quantization = quantizationRanges[frame.quantizationTableIndex],
          let dc = dcTables[dcIndex],
          let ac = acTables[acIndex]
        else { throw ImageCraftError.unsupportedOrCorruptImage }
        return ScanComponent(
          quantizationRange: quantization,
          dcHuffman: dc,
          acHuffman: ac
        )
      }

      let mcuColumns = try JPEGIndependentBaseline420Decoder.ceilDiv(width, 16)
      let mcuRows = try JPEGIndependentBaseline420Decoder.ceilDiv(height, 16)
      let totalMCUs = try JPEGIndependentBaseline420Decoder.multiplied(mcuColumns, mcuRows)
      let chromaWidth = try JPEGIndependentBaseline420Decoder.ceilDiv(width, 2)
      let chromaHeight = try JPEGIndependentBaseline420Decoder.ceilDiv(height, 2)
      return Self(
        width: width,
        height: height,
        chromaWidth: chromaWidth,
        chromaHeight: chromaHeight,
        mcuColumns: mcuColumns,
        mcuRows: mcuRows,
        totalMCUCount: totalMCUs,
        y: try scanComponent(selectorOffset: 2, frame: frameY),
        cb: try scanComponent(selectorOffset: 4, frame: frameCb),
        cr: try scanComponent(selectorOffset: 6, frame: frameCr),
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

  private final class StateArena {
    let plan: JPEGIndependentBaseline420StatePlan
    private let baseAddress: UnsafeMutableRawPointer
    let coefficients: UnsafeMutableBufferPointer<Int16>
    let quantization: UnsafeMutableBufferPointer<UInt16>
    let workspace: UnsafeMutableBufferPointer<Int32>
    let yStrip: UnsafeMutableBufferPointer<UInt8>
    let cbStrip: UnsafeMutableBufferPointer<UInt8>
    let crStrip: UnsafeMutableBufferPointer<UInt8>
    let deferredYRow: UnsafeMutableBufferPointer<UInt8>
    let previousCbRow: UnsafeMutableBufferPointer<UInt8>
    let previousCrRow: UnsafeMutableBufferPointer<UInt8>
    let reconstructedCbRow: UnsafeMutableBufferPointer<UInt8>
    let reconstructedCrRow: UnsafeMutableBufferPointer<UInt8>

    init(plan: JPEGIndependentBaseline420StatePlan) throws {
      var pointer: UnsafeMutableRawPointer?
      let result = posix_memalign(
        &pointer,
        JPEGIndependentBaseline420StatePlan.rowAlignmentBytes,
        max(1, plan.totalStateBytes)
      )
      guard result == 0, let pointer else {
        throw JPEGIndependentBaseline420Error.stateAllocationFailed(byteCount: plan.totalStateBytes)
      }
      self.plan = plan
      self.baseAddress = pointer
      memset(pointer, 0, plan.totalStateBytes)

      var offset = 0
      coefficients = UnsafeMutableBufferPointer(
        start: pointer.advanced(by: offset).assumingMemoryBound(to: Int16.self),
        count: 64
      )
      offset += JPEGIndependentBaseline420StatePlan.coefficientScratchBytes
      quantization = UnsafeMutableBufferPointer(
        start: pointer.advanced(by: offset).assumingMemoryBound(to: UInt16.self),
        count: 64
      )
      offset += JPEGIndependentBaseline420StatePlan.quantizationScratchBytes
      workspace = UnsafeMutableBufferPointer(
        start: pointer.advanced(by: offset).assumingMemoryBound(to: Int32.self),
        count: 64
      )
      offset += JPEGIndependentBaseline420StatePlan.idctWorkspaceBytes
      yStrip = UnsafeMutableBufferPointer(
        start: pointer.advanced(by: offset).assumingMemoryBound(to: UInt8.self),
        count: plan.yStripBytes
      )
      offset += plan.yStripBytes
      cbStrip = UnsafeMutableBufferPointer(
        start: pointer.advanced(by: offset).assumingMemoryBound(to: UInt8.self),
        count: plan.chromaStripBytesPerComponent
      )
      offset += plan.chromaStripBytesPerComponent
      crStrip = UnsafeMutableBufferPointer(
        start: pointer.advanced(by: offset).assumingMemoryBound(to: UInt8.self),
        count: plan.chromaStripBytesPerComponent
      )
      offset += plan.chromaStripBytesPerComponent
      deferredYRow = UnsafeMutableBufferPointer(
        start: pointer.advanced(by: offset).assumingMemoryBound(to: UInt8.self),
        count: plan.deferredYRowBytes
      )
      offset += plan.deferredYRowBytes
      previousCbRow = UnsafeMutableBufferPointer(
        start: pointer.advanced(by: offset).assumingMemoryBound(to: UInt8.self),
        count: plan.previousChromaRowBytesPerComponent
      )
      offset += plan.previousChromaRowBytesPerComponent
      previousCrRow = UnsafeMutableBufferPointer(
        start: pointer.advanced(by: offset).assumingMemoryBound(to: UInt8.self),
        count: plan.previousChromaRowBytesPerComponent
      )
      offset += plan.previousChromaRowBytesPerComponent
      reconstructedCbRow = UnsafeMutableBufferPointer(
        start: pointer.advanced(by: offset).assumingMemoryBound(to: UInt8.self),
        count: plan.reconstructedChromaRowBytesPerComponent
      )
      offset += plan.reconstructedChromaRowBytesPerComponent
      reconstructedCrRow = UnsafeMutableBufferPointer(
        start: pointer.advanced(by: offset).assumingMemoryBound(to: UInt8.self),
        count: plan.reconstructedChromaRowBytesPerComponent
      )
      offset += plan.reconstructedChromaRowBytesPerComponent
      guard offset == plan.totalStateBytes else {
        free(pointer)
        throw ImageCraftError.unsupportedOrCorruptImage
      }
    }

    deinit { free(baseAddress) }

    func clearCoefficientBlock() {
      memset(coefficients.baseAddress!, 0, JPEGIndependentBaseline420StatePlan.coefficientScratchBytes)
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
        quantization[JPEGIndependentBaseline420Decoder.jpegNaturalOrder[zigzagIndex]] = value
      }
    }

    func yRow(localRow: Int, logicalWidth: Int) -> UnsafeBufferPointer<UInt8> {
      row(yStrip, row: localRow, stride: plan.yRowStrideBytes, count: logicalWidth)
    }

    func cbRow(localRow: Int, logicalWidth: Int) -> UnsafeBufferPointer<UInt8> {
      row(cbStrip, row: localRow, stride: plan.chromaRowStrideBytes, count: logicalWidth)
    }

    func crRow(localRow: Int, logicalWidth: Int) -> UnsafeBufferPointer<UInt8> {
      row(crStrip, row: localRow, stride: plan.chromaRowStrideBytes, count: logicalWidth)
    }

    func deferredYRowPrefix(_ logicalWidth: Int) -> UnsafeBufferPointer<UInt8> {
      prefix(deferredYRow, count: logicalWidth)
    }

    func previousCbRowPrefix(_ logicalWidth: Int) -> UnsafeBufferPointer<UInt8> {
      prefix(previousCbRow, count: logicalWidth)
    }

    func previousCrRowPrefix(_ logicalWidth: Int) -> UnsafeBufferPointer<UInt8> {
      prefix(previousCrRow, count: logicalWidth)
    }

    func reconstructedCbRowPrefix(_ logicalWidth: Int) -> UnsafeMutableBufferPointer<UInt8> {
      mutablePrefix(reconstructedCbRow, count: logicalWidth)
    }

    func reconstructedCrRowPrefix(_ logicalWidth: Int) -> UnsafeMutableBufferPointer<UInt8> {
      mutablePrefix(reconstructedCrRow, count: logicalWidth)
    }

    func copyYRowToDeferred(localRow: Int, logicalWidth: Int) throws {
      let source = yRow(localRow: localRow, logicalWidth: logicalWidth)
      guard logicalWidth <= deferredYRow.count,
        let sourceBase = source.baseAddress,
        let destinationBase = deferredYRow.baseAddress
      else { throw ImageCraftError.unsupportedOrCorruptImage }
      memcpy(destinationBase, sourceBase, logicalWidth)
    }

    func copyChromaRowToPrevious(localRow: Int, logicalWidth: Int) throws {
      let cb = cbRow(localRow: localRow, logicalWidth: logicalWidth)
      let cr = crRow(localRow: localRow, logicalWidth: logicalWidth)
      guard logicalWidth <= previousCbRow.count,
        logicalWidth <= previousCrRow.count,
        let cbBase = cb.baseAddress,
        let crBase = cr.baseAddress,
        let previousCbBase = previousCbRow.baseAddress,
        let previousCrBase = previousCrRow.baseAddress
      else { throw ImageCraftError.unsupportedOrCorruptImage }
      memcpy(previousCbBase, cbBase, logicalWidth)
      memcpy(previousCrBase, crBase, logicalWidth)
    }

    private func row(
      _ buffer: UnsafeMutableBufferPointer<UInt8>,
      row: Int,
      stride: Int,
      count: Int
    ) -> UnsafeBufferPointer<UInt8> {
      guard row >= 0, stride > 0, count > 0, count <= stride,
        let base = buffer.baseAddress
      else { return UnsafeBufferPointer(start: nil, count: 0) }
      let offset = row * stride
      guard offset >= 0, offset + count <= buffer.count else {
        return UnsafeBufferPointer(start: nil, count: 0)
      }
      return UnsafeBufferPointer(start: base.advanced(by: offset), count: count)
    }

    private func prefix(
      _ buffer: UnsafeMutableBufferPointer<UInt8>,
      count: Int
    ) -> UnsafeBufferPointer<UInt8> {
      guard count > 0, count <= buffer.count, let base = buffer.baseAddress else {
        return UnsafeBufferPointer(start: nil, count: 0)
      }
      return UnsafeBufferPointer(start: base, count: count)
    }

    private func mutablePrefix(
      _ buffer: UnsafeMutableBufferPointer<UInt8>,
      count: Int
    ) -> UnsafeMutableBufferPointer<UInt8> {
      guard count > 0, count <= buffer.count, let base = buffer.baseAddress else {
        return UnsafeMutableBufferPointer(start: nil, count: 0)
      }
      return UnsafeMutableBufferPointer(start: base, count: count)
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
