import Darwin
import Foundation
import ImageCraftCore

package enum JPEGIndependentBaseline422Error: Error, Equatable, Sendable {
  case unsupportedSourceSemantics
  case invalidOperationBudget
  case operationBudgetExceeded(requiredBytes: Int, maximumBytes: Int)
  case stateAllocationFailed(byteCount: Int)
}

package struct JPEGIndependentBaseline422StatePlan: Codable, Equatable, Sendable {
  package static let rowAlignmentBytes = 64
  package static let fixedScratchBytes = 512

  package let width: Int
  package let height: Int
  package let chromaWidth: Int
  package let yRowStrideBytes: Int
  package let chromaRowStrideBytes: Int
  package let yStripBytes: Int
  package let chromaStripBytesPerComponent: Int
  package let reconstructedChromaRowBytesPerComponent: Int
  package let totalStateBytes: Int

  package static func inspect(_ data: Data) throws -> Self {
    let frame = try JPEGFrameSamplingGeometry.inspect(data)
    guard frame.codingMode == .baselineDCT,
      frame.samplingMode == .threeComponent422,
      frame.precision == 8
    else { throw JPEGIndependentBaseline422Error.unsupportedSourceSemantics }
    return try make(width: frame.width, height: frame.height)
  }

  package static func make(width: Int, height: Int) throws -> Self {
    guard width > 0, height > 0 else { throw ImageCraftError.unsupportedOrCorruptImage }
    let chromaWidth = try ceilDiv(width, 2)
    let yStride = try roundUp(width, rowAlignmentBytes)
    let chromaStride = try roundUp(chromaWidth, rowAlignmentBytes)
    let yStrip = try multiplied(yStride, 8)
    let chromaStrip = try multiplied(chromaStride, 8)
    var total = fixedScratchBytes
    total = try added(total, yStrip)
    total = try added(total, try multiplied(chromaStrip, 2))
    total = try added(total, try multiplied(yStride, 2))
    return Self(
      width: width,
      height: height,
      chromaWidth: chromaWidth,
      yRowStrideBytes: yStride,
      chromaRowStrideBytes: chromaStride,
      yStripBytes: yStrip,
      chromaStripBytesPerComponent: chromaStrip,
      reconstructedChromaRowBytesPerComponent: yStride,
      totalStateBytes: total
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

package struct JPEGIndependentBaseline422Image: Equatable, Sendable {
  package let width: Int
  package let height: Int
  package let rgb: Data
  package let restartIntervalMCUs: Int
  package let decodedMCUCount: Int
  package let statePlan: JPEGIndependentBaseline422StatePlan
  package let operationByteCharge: Int
}

/// Package-only complete-input baseline JFIF 4:2:2 JPEG slice.
///
/// The source domain deliberately mirrors the strict baseline color marker authority: exact first
/// JFIF APP0, optional qualified Adobe transform=1, metadata-budgeted COM, 8-bit SOF0 with
/// 2x1/1x1/1x1 sampling, one interleaved sequential Huffman scan, 8-bit DQT, optional DRI/RST,
/// and no DNL/arithmetic or unqualified APP/structural markers. The encoded Data is caller-owned.
/// ImageCraft owns one 8-row Y strip, one 8-row low-resolution Cb/Cr strip, two full-width
/// reconstructed chroma rows and 512 B of coefficient/quantization/ISLOW scratch.
package struct JPEGIndependentBaseline422Decoder: Sendable {
  private let maximumOperationByteCharge: Int
  private let maximumMetadataBytes: Int

  package init(
    maximumOperationByteCharge: Int,
    maximumMetadataBytes: Int = DecodeLimits.coreV1.maximumMetadataBytes
  ) {
    self.maximumOperationByteCharge = maximumOperationByteCharge
    self.maximumMetadataBytes = maximumMetadataBytes
  }

  package func decode(_ data: Data) throws -> JPEGIndependentBaseline422Image {
    guard maximumOperationByteCharge >= 0, maximumMetadataBytes >= 0 else {
      throw JPEGIndependentBaseline422Error.invalidOperationBudget
    }
    let security = try EncodedImageSecurityInspector.inspect(
      data,
      maximumMetadataBytes: maximumMetadataBytes,
      materializePNGICCProfile: false,
      materializeJPEGICCProfile: false
    )
    guard security.format == .jpeg else { throw ImageCraftError.formatMismatch }
    guard security.sourceColorProfile != .embeddedICC, security.embeddedICCProfile == nil else {
      throw JPEGIndependentBaseline422Error.unsupportedSourceSemantics
    }

    let statePlan = try JPEGIndependentBaseline422StatePlan.inspect(data)
    let plan: JPEGIndependentBaseline420Decoder.DecodePlan
    do {
      plan = try JPEGIndependentBaseline420Decoder.DecodePlan.inspect(data, sampling: .h2v1)
    } catch JPEGIndependentBaseline420Error.unsupportedSourceSemantics {
      throw JPEGIndependentBaseline422Error.unsupportedSourceSemantics
    }
    guard plan.width == statePlan.width, plan.height == statePlan.height else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    let outputByteCount = try Self.multiplied(try Self.multiplied(plan.width, plan.height), 3)
    let operationByteCharge = try Self.added(outputByteCount, statePlan.totalStateBytes)
    guard operationByteCharge <= maximumOperationByteCharge else {
      throw JPEGIndependentBaseline422Error.operationBudgetExceeded(
        requiredBytes: operationByteCharge,
        maximumBytes: maximumOperationByteCharge
      )
    }

    let state = try StateArena(plan: statePlan)
    var output = Data(count: outputByteCount)
    try data.withUnsafeBytes { rawInput in
      let input = rawInput.bindMemory(to: UInt8.self)
      try output.withUnsafeMutableBytes { rawOutput in
        try decodeScan(
          input: input,
          plan: plan,
          state: state,
          destination: rawOutput.bindMemory(to: UInt8.self)
        )
      }
    }
    return JPEGIndependentBaseline422Image(
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
    plan: JPEGIndependentBaseline420Decoder.DecodePlan,
    state: StateArena,
    destination: UnsafeMutableBufferPointer<UInt8>
  ) throws {
    var reader = JPEGIndependentBaseline420Decoder.EntropyBitReader(
      bytes: input,
      offset: plan.entropyStartOffset
    )
    var yPredictor = 0
    var cbPredictor = 0
    var crPredictor = 0
    var restartIndex = 0
    var globalMCUIndex = 0

    for mcuRow in 0..<plan.mcuRows {
      let outputRowBase = mcuRow * 8
      let rowsInStrip = min(8, plan.height - outputRowBase)
      guard rowsInStrip > 0 else { throw ImageCraftError.unsupportedOrCorruptImage }

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

        for yBlock in 0..<2 {
          try decodeBlock(
            input: input,
            component: plan.y,
            predictor: &yPredictor,
            state: state,
            reader: &reader,
            target: state.yStrip,
            targetRowStride: state.plan.yRowStrideBytes,
            targetX: mcuColumn * 16 + yBlock * 8,
            logicalWidth: plan.width,
            logicalHeight: rowsInStrip
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
          logicalWidth: plan.chromaWidth,
          logicalHeight: rowsInStrip
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
          logicalWidth: plan.chromaWidth,
          logicalHeight: rowsInStrip
        )
        globalMCUIndex += 1
      }

      for localRow in 0..<rowsInStrip {
        try renderRow(
          outputRow: outputRowBase + localRow,
          localRow: localRow,
          plan: plan,
          state: state,
          destination: destination
        )
      }
    }

    guard globalMCUIndex == plan.totalMCUCount else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    try reader.finishEntropyByte()
    try reader.consumeMarker(expected: 0xD9)
    guard reader.offset == input.count else {
      throw JPEGIndependentBaseline422Error.unsupportedSourceSemantics
    }
  }

  private func decodeBlock(
    input: UnsafeBufferPointer<UInt8>,
    component: JPEGIndependentBaseline420Decoder.ScanComponent,
    predictor: inout Int,
    state: StateArena,
    reader: inout JPEGIndependentBaseline420Decoder.EntropyBitReader,
    target: UnsafeMutableBufferPointer<UInt8>,
    targetRowStride: Int,
    targetX: Int,
    logicalWidth: Int,
    logicalHeight: Int
  ) throws {
    state.clearCoefficientBlock()
    try state.loadQuantization(from: input, range: component.quantizationRange)
    try JPEGIndependentBaseline420Decoder.decodeSequentialBlock(
      input: input,
      dcTable: component.dcHuffman,
      acTable: component.acHuffman,
      predictor: &predictor,
      coefficients: state.coefficients,
      reader: &reader
    )
    let writeWidth = min(8, logicalWidth - targetX)
    let writeHeight = min(8, logicalHeight)
    if writeWidth <= 0 || writeHeight <= 0 { return }
    guard targetX >= 0, let base = target.baseAddress, targetX < target.count else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    try JPEGISlowIDCT.writeBlockClipped(
      coefficients: UnsafeBufferPointer(state.coefficients),
      quantization: UnsafeBufferPointer(state.quantization),
      workspace: state.workspace,
      destination: UnsafeMutableBufferPointer(
        start: base.advanced(by: targetX),
        count: target.count - targetX
      ),
      destinationRowStride: targetRowStride,
      writeWidth: writeWidth,
      writeHeight: writeHeight
    )
  }

  private func renderRow(
    outputRow: Int,
    localRow: Int,
    plan: JPEGIndependentBaseline420Decoder.DecodePlan,
    state: StateArena,
    destination: UnsafeMutableBufferPointer<UInt8>
  ) throws {
    let y = state.yRow(localRow: localRow, logicalWidth: plan.width)
    let cb = state.cbRow(localRow: localRow, logicalWidth: plan.chromaWidth)
    let cr = state.crRow(localRow: localRow, logicalWidth: plan.chromaWidth)
    let reconstructedCb = state.reconstructedCbPrefix(plan.width)
    let reconstructedCr = state.reconstructedCrPrefix(plan.width)
    if plan.chromaWidth <= 2 {
      try JPEGCenteredChromaReconstruction.writeH2V1Box(
        source: cb,
        sourceWidth: plan.chromaWidth,
        sourceHeight: 1,
        destination: reconstructedCb,
        outputWidth: plan.width
      )
      try JPEGCenteredChromaReconstruction.writeH2V1Box(
        source: cr,
        sourceWidth: plan.chromaWidth,
        sourceHeight: 1,
        destination: reconstructedCr,
        outputWidth: plan.width
      )
    } else {
      try JPEGCenteredChromaReconstruction.writeH2V1(
        source: cb,
        sourceWidth: plan.chromaWidth,
        sourceHeight: 1,
        destination: reconstructedCb,
        outputWidth: plan.width
      )
      try JPEGCenteredChromaReconstruction.writeH2V1(
        source: cr,
        sourceWidth: plan.chromaWidth,
        sourceHeight: 1,
        destination: reconstructedCr,
        outputWidth: plan.width
      )
    }

    let rowBytes = try Self.multiplied(plan.width, 3)
    let destinationOffset = try Self.multiplied(outputRow, rowBytes)
    guard outputRow >= 0, outputRow < plan.height,
      let base = destination.baseAddress,
      destinationOffset + rowBytes <= destination.count
    else { throw ImageCraftError.unsupportedOrCorruptImage }
    try JPEGYCbCrToRGB.writePlanarRGBRow(
      y: y,
      cb: UnsafeBufferPointer(reconstructedCb),
      cr: UnsafeBufferPointer(reconstructedCr),
      destination: UnsafeMutableBufferPointer(
        start: base.advanced(by: destinationOffset),
        count: rowBytes
      ),
      writeWidth: plan.width
    )
  }

  private final class StateArena {
    let plan: JPEGIndependentBaseline422StatePlan
    private let baseAddress: UnsafeMutableRawPointer
    let coefficients: UnsafeMutableBufferPointer<Int16>
    let quantization: UnsafeMutableBufferPointer<UInt16>
    let workspace: UnsafeMutableBufferPointer<Int32>
    let yStrip: UnsafeMutableBufferPointer<UInt8>
    let cbStrip: UnsafeMutableBufferPointer<UInt8>
    let crStrip: UnsafeMutableBufferPointer<UInt8>
    private let reconstructedCbRow: UnsafeMutableBufferPointer<UInt8>
    private let reconstructedCrRow: UnsafeMutableBufferPointer<UInt8>

    init(plan: JPEGIndependentBaseline422StatePlan) throws {
      var pointer: UnsafeMutableRawPointer?
      let result = posix_memalign(
        &pointer,
        JPEGIndependentBaseline422StatePlan.rowAlignmentBytes,
        max(1, plan.totalStateBytes)
      )
      guard result == 0, let pointer else {
        throw JPEGIndependentBaseline422Error.stateAllocationFailed(byteCount: plan.totalStateBytes)
      }
      self.plan = plan
      self.baseAddress = pointer
      var cursor = 0

      func take<T>(_ type: T.Type, count: Int) -> UnsafeMutableBufferPointer<T> {
        let byteCount = MemoryLayout<T>.stride * count
        let start = pointer.advanced(by: cursor).assumingMemoryBound(to: T.self)
        cursor += byteCount
        return UnsafeMutableBufferPointer(start: start, count: count)
      }

      coefficients = take(Int16.self, count: 64)
      quantization = take(UInt16.self, count: 64)
      workspace = take(Int32.self, count: 64)
      yStrip = take(UInt8.self, count: plan.yStripBytes)
      cbStrip = take(UInt8.self, count: plan.chromaStripBytesPerComponent)
      crStrip = take(UInt8.self, count: plan.chromaStripBytesPerComponent)
      reconstructedCbRow = take(UInt8.self, count: plan.reconstructedChromaRowBytesPerComponent)
      reconstructedCrRow = take(UInt8.self, count: plan.reconstructedChromaRowBytesPerComponent)
      guard cursor == plan.totalStateBytes else {
        free(pointer)
        throw ImageCraftError.unsupportedOrCorruptImage
      }
    }

    deinit { free(baseAddress) }

    func clearCoefficientBlock() {
      coefficients.initialize(repeating: 0)
    }

    func loadQuantization(
      from input: UnsafeBufferPointer<UInt8>,
      range: Range<Int>
    ) throws {
      guard range.count == 64 else { throw ImageCraftError.unsupportedOrCorruptImage }
      for zigzag in 0..<64 {
        let value = input[range.lowerBound + zigzag]
        guard value > 0 else { throw ImageCraftError.unsupportedOrCorruptImage }
        quantization[JPEGIndependentBaseline422Decoder.jpegNaturalOrder[zigzag]] = UInt16(value)
      }
    }

    func yRow(localRow: Int, logicalWidth: Int) -> UnsafeBufferPointer<UInt8> {
      row(yStrip, localRow: localRow, stride: plan.yRowStrideBytes, width: logicalWidth)
    }

    func cbRow(localRow: Int, logicalWidth: Int) -> UnsafeBufferPointer<UInt8> {
      row(cbStrip, localRow: localRow, stride: plan.chromaRowStrideBytes, width: logicalWidth)
    }

    func crRow(localRow: Int, logicalWidth: Int) -> UnsafeBufferPointer<UInt8> {
      row(crStrip, localRow: localRow, stride: plan.chromaRowStrideBytes, width: logicalWidth)
    }

    func reconstructedCbPrefix(_ width: Int) -> UnsafeMutableBufferPointer<UInt8> {
      mutablePrefix(reconstructedCbRow, count: width)
    }

    func reconstructedCrPrefix(_ width: Int) -> UnsafeMutableBufferPointer<UInt8> {
      mutablePrefix(reconstructedCrRow, count: width)
    }

    private func row(
      _ buffer: UnsafeMutableBufferPointer<UInt8>,
      localRow: Int,
      stride: Int,
      width: Int
    ) -> UnsafeBufferPointer<UInt8> {
      guard localRow >= 0, localRow < 8, width > 0, width <= stride,
        let base = buffer.baseAddress
      else { return UnsafeBufferPointer(start: nil, count: 0) }
      return UnsafeBufferPointer(start: base.advanced(by: localRow * stride), count: width)
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
    let result = lhs.addingReportingOverflow(rhs)
    guard !result.overflow, result.partialValue >= 0 else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    return result.partialValue
  }

  private static func multiplied(_ lhs: Int, _ rhs: Int) throws -> Int {
    let result = lhs.multipliedReportingOverflow(by: rhs)
    guard !result.overflow, result.partialValue >= 0 else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    return result.partialValue
  }
}
