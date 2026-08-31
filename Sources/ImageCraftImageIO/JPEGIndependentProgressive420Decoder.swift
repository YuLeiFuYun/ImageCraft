import Darwin
import Foundation
import ImageCraftCore

package enum JPEGIndependentProgressive420Error: Error, Equatable, Sendable {
  case unsupportedSourceSemantics
  case invalidOperationBudget
  case operationBudgetExceeded(requiredBytes: Int, maximumBytes: Int)
  case stateAllocationFailed(byteCount: Int)
}

package enum JPEGIndependentProgressive420ScanPreviewPolicy: Sendable {
  /// Render exactly the coefficients retained after the completed scan.
  case rawCoefficients
  /// Apply libjpeg-turbo's optional progressive block-smoothing estimator before IDCT. The
  /// estimator modifies only one decoder-owned 64-coefficient scratch block; retained coefficient
  /// planes remain the exact entropy-decoded values.
  case libjpegBlockSmoothing
}

package struct JPEGIndependentProgressive420StatePlan: Codable, Equatable, Sendable {
  package static let rowAlignmentBytes = 64
  /// State that is present independent of which Huffman slots the source actually defines: three
  /// bound 8-bit component quantization tables plus per-coefficient progression precision. The
  /// progression domain has only 15 states (unseen plus successive-low 0...13), so two entries fit
  /// in one byte. The qualified source domain accepts only 8-bit DQT precision, so widening those
  /// tables to UInt16 is render-only.
  package static let progressionStateByteCount = (3 * 64) / 2
  package static let persistentBaseFixedStateByteCount = 3 * 64 + progressionStateByteCount
  package static func progressionNibble(for value: Int) -> UInt8? {
    if value == -1 { return 0x0F }
    guard (0...13).contains(value) else { return nil }
    return UInt8(value)
  }

  package static func progressionValue(forNibble nibble: UInt8) -> Int8? {
    guard nibble <= 0x0F else { return nil }
    switch nibble {
    case 0...13: return Int8(nibble)
    case 0x0F: return -1
    default: return nil
    }
  }
  /// One retained Huffman slot stores exactly the 16 code-length counts plus the currently defined
  /// symbols. The selector is its slot identity and is not duplicated in the payload.
  package static let maximumHuffmanTablePayloadByteCount = 16 + 256
  package static let maximumHuffmanStateByteCount = 8 * maximumHuffmanTablePayloadByteCount
  /// Worst-case persistent fixed authority used for admission before future DHT definitions are
  /// known. Actual retained state is base fixed state plus only the currently present table payloads.
  package static let persistentFixedStateByteCount =
    persistentBaseFixedStateByteCount + maximumHuffmanStateByteCount
  package static let quantizationSourceStateByteCount = 4 * 64
  /// IDCT workspace, one block-smoothing coefficient block and one UInt16 quantization widening
  /// table are needed only while rasterizing a preview/final image. They never survive between
  /// entropy-decoding calls.
  package static let renderFixedScratchByteCount = 512
  /// Historical aggregate state authority retained for one-shot decode accounting and evidence.
  package static let fixedStateByteCount =
    persistentFixedStateByteCount + renderFixedScratchByteCount

  package let width: Int
  package let height: Int
  package let mcuColumns: Int
  package let mcuRows: Int
  package let yActualWidthBlocks: Int
  package let yActualHeightBlocks: Int
  package let yPaddedWidthBlocks: Int
  package let yPaddedHeightBlocks: Int
  package let chromaWidth: Int
  package let chromaHeight: Int
  package let chromaWidthBlocks: Int
  package let chromaHeightBlocks: Int
  package let yCoefficientBytes: Int
  package let chromaCoefficientBytesPerComponent: Int
  package let coefficientStateBytes: Int
  package let yRowStrideBytes: Int
  package let chromaRowStrideBytes: Int
  package let rowStateBytes: Int
  package let persistentBaseStateBytes: Int
  package let persistentStateBytes: Int
  package let renderScratchBytes: Int
  package let totalStateBytes: Int
  package let usesFancyGlobalContext: Bool

  package static func inspect(_ data: Data) throws -> Self {
    try data.withUnsafeBytes { raw in
      let bytes = raw.bindMemory(to: UInt8.self)
      guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else {
        throw ImageCraftError.formatMismatch
      }
      var offset = 2
      while offset < bytes.count {
        guard bytes[offset] == 0xFF else { throw ImageCraftError.unsupportedOrCorruptImage }
        while offset < bytes.count, bytes[offset] == 0xFF { offset += 1 }
        guard offset < bytes.count else { throw ImageCraftError.unsupportedOrCorruptImage }
        let marker = bytes[offset]
        offset += 1
        if marker == 0xD9 || marker == 0xDA {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
        if marker == 0x01 { continue }
        if marker == 0xD8 || (0xD0...0xD7).contains(marker) {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
        guard offset + 2 <= bytes.count else { throw ImageCraftError.unsupportedOrCorruptImage }
        let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
        guard length >= 2 else { throw ImageCraftError.unsupportedOrCorruptImage }
        let end = offset.addingReportingOverflow(length)
        guard !end.overflow, end.partialValue <= bytes.count else {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
        let payloadStart = offset + 2
        let payloadCount = length - 2
        if marker == 0xC2 {
          guard payloadCount == 15,
            bytes[payloadStart] == 8,
            bytes[payloadStart + 5] == 3
          else { throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics }
          let height = Int(bytes[payloadStart + 1]) << 8 | Int(bytes[payloadStart + 2])
          let width = Int(bytes[payloadStart + 3]) << 8 | Int(bytes[payloadStart + 4])
          guard width > 0, height > 0 else { throw ImageCraftError.unsupportedOrCorruptImage }
          let y = payloadStart + 6
          let cb = y + 3
          let cr = cb + 3
          guard bytes[y] == 1, bytes[y + 1] == 0x22, bytes[y + 2] <= 3,
            bytes[cb] == 2, bytes[cb + 1] == 0x11, bytes[cb + 2] <= 3,
            bytes[cr] == 3, bytes[cr + 1] == 0x11, bytes[cr + 2] <= 3
          else { throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics }
          return try make(width: width, height: height)
        }
        if marker == 0xC0 || marker == 0xC1 || marker == 0xC3
          || (0xC5...0xC7).contains(marker)
          || (0xC9...0xCB).contains(marker)
          || (0xCD...0xCF).contains(marker)
        {
          throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
        }
        offset = end.partialValue
      }
      throw ImageCraftError.unsupportedOrCorruptImage
    }
  }

  package static func make(width: Int, height: Int) throws -> Self {
    guard width > 0, height > 0 else { throw ImageCraftError.unsupportedOrCorruptImage }
    let mcuColumns = try ceilDiv(width, 16)
    let mcuRows = try ceilDiv(height, 16)
    let yActualWidthBlocks = try ceilDiv(width, 8)
    let yActualHeightBlocks = try ceilDiv(height, 8)
    let yPaddedWidthBlocks = try multiplied(mcuColumns, 2)
    let yPaddedHeightBlocks = try multiplied(mcuRows, 2)
    let chromaWidth = try ceilDiv(width, 2)
    let chromaHeight = try ceilDiv(height, 2)
    let chromaWidthBlocks = mcuColumns
    let chromaHeightBlocks = mcuRows
    // Interleaved 4:2:0 DC scans still carry entropy-coded dummy Y blocks at the right/bottom MCU
    // fringe, but those blocks are not part of the image coefficient plane: AC scans, smoothing and
    // rasterization all address only actual image blocks. Dummy DC blocks are decoded into
    // transaction-local scratch instead of being retained across scans.
    let yBlockCount = try multiplied(yActualWidthBlocks, yActualHeightBlocks)
    let chromaBlockCount = try multiplied(chromaWidthBlocks, chromaHeightBlocks)
    let yCoefficientBytes = try multiplied(yBlockCount, 128)
    let chromaCoefficientBytes = try multiplied(chromaBlockCount, 128)
    let coefficientStateBytes = try added(yCoefficientBytes, try multiplied(chromaCoefficientBytes, 2))

    let yStride = try roundUp(width, rowAlignmentBytes)
    let chromaStride = try roundUp(chromaWidth, rowAlignmentBytes)
    // 16 Y rows + 8 Cb + 8 Cr + prior Cb/Cr. Full-width reconstructed Cb/Cr rows are fused into
    // YCbCr -> RGB conversion and never materialized. The final Y row of an iMCU strip stays live
    // in yStrip until the next strip's chroma has been rendered, so the fancy vertical boundary
    // also does not need a copied/deferred Y row.
    let yRows = try multiplied(yStride, 16)
    let chromaRows = try multiplied(chromaStride, 18)
    let rowStateBytes = try added(yRows, chromaRows)
    let persistentBaseStateBytes = try added(
      coefficientStateBytes,
      Self.persistentBaseFixedStateByteCount
    )
    let persistentStateBytes = try added(
      persistentBaseStateBytes,
      Self.maximumHuffmanStateByteCount
    )
    let renderScratchBytes = try added(Self.renderFixedScratchByteCount, rowStateBytes)
    let totalStateBytes = try added(persistentStateBytes, renderScratchBytes)
    return Self(
      width: width,
      height: height,
      mcuColumns: mcuColumns,
      mcuRows: mcuRows,
      yActualWidthBlocks: yActualWidthBlocks,
      yActualHeightBlocks: yActualHeightBlocks,
      yPaddedWidthBlocks: yPaddedWidthBlocks,
      yPaddedHeightBlocks: yPaddedHeightBlocks,
      chromaWidth: chromaWidth,
      chromaHeight: chromaHeight,
      chromaWidthBlocks: chromaWidthBlocks,
      chromaHeightBlocks: chromaHeightBlocks,
      yCoefficientBytes: yCoefficientBytes,
      chromaCoefficientBytesPerComponent: chromaCoefficientBytes,
      coefficientStateBytes: coefficientStateBytes,
      yRowStrideBytes: yStride,
      chromaRowStrideBytes: chromaStride,
      rowStateBytes: rowStateBytes,
      persistentBaseStateBytes: persistentBaseStateBytes,
      persistentStateBytes: persistentStateBytes,
      renderScratchBytes: renderScratchBytes,
      totalStateBytes: totalStateBytes,
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

package struct JPEGIndependentProgressive420Image: Equatable, Sendable {
  package let width: Int
  package let height: Int
  package let rgb: Data
  package let scanCount: Int
  package let statePlan: JPEGIndependentProgressive420StatePlan
  package let operationByteCharge: Int
}

/// Package-only complete-input progressive JFIF 4:2:0 JPEG research backend.
///
/// Progressive entropy necessarily retains quantized coefficients across scans. ImageCraft owns one
/// actual-image Int16 coefficient plane per component, fixed per-component quantization/progression
/// state, and width-bounded render scratch. Interleaved MCU dummy Y blocks are transaction-local;
/// the caller-owned encoded bytes are borrowed.
/// Exact output + state bytes are admitted before either payload allocation.
///
/// The qualified source shape is deliberately narrow: 8-bit SOF2 JFIF YCbCr, component IDs 1/2/3
/// with 2x2/1x1/1x1 sampling, Huffman coding, 8-bit DQT established before the first scan, optional
/// DRI/RST markers and no DNL/arithmetic coding. Interleaved scans are DC-only; AC scans are single
/// component. DC/AC first and refinement scans are accepted only when successive approximation is
/// monotone and every introduced coefficient reaches Al=0 before final rendering.
package struct JPEGIndependentProgressive420Decoder: Sendable {
  private let maximumOperationByteCharge: Int
  private let maximumMetadataBytes: Int

  package init(
    maximumOperationByteCharge: Int,
    maximumMetadataBytes: Int = DecodeLimits.coreV1.maximumMetadataBytes
  ) {
    self.maximumOperationByteCharge = maximumOperationByteCharge
    self.maximumMetadataBytes = maximumMetadataBytes
  }

  package func decode(_ data: Data) throws -> JPEGIndependentProgressive420Image {
    try decode(data, scanPreviewObserver: nil, finalCoefficientObserver: nil)
  }

  /// Evidence-only synchronous observation seam over the single decoder-owned coefficient backing.
  /// The callback is valid only during decode and does not widen the operation charge.
  package func decode(
    _ data: Data,
    finalCoefficientObserver: ((UnsafeBufferPointer<Int16>) throws -> Void)?
  ) throws -> JPEGIndependentProgressive420Image {
    try decode(
      data,
      scanPreviewObserver: nil,
      finalCoefficientObserver: finalCoefficientObserver
    )
  }

  /// Evidence-only synchronous scan-generation seam. The RGB buffer aliases the decoder's one
  /// admitted output backing and is overwritten by the next generation. Generations are
  /// provisional: a later scan/container failure still terminates the decode. No generation copy
  /// is retained by ImageCraft, so enabling this observer does not widen the operation charge.
  package func decode(
    _ data: Data,
    scanPreviewObserver: ((Int, UnsafeBufferPointer<UInt8>) throws -> Void)?,
    finalCoefficientObserver: ((UnsafeBufferPointer<Int16>) throws -> Void)?
  ) throws -> JPEGIndependentProgressive420Image {
    try decode(
      data,
      scanPreviewPolicy: .rawCoefficients,
      scanPreviewObserver: scanPreviewObserver,
      finalCoefficientObserver: finalCoefficientObserver
    )
  }

  package func decode(
    _ data: Data,
    scanPreviewPolicy: JPEGIndependentProgressive420ScanPreviewPolicy,
    scanPreviewObserver: ((Int, UnsafeBufferPointer<UInt8>) throws -> Void)?,
    finalCoefficientObserver: ((UnsafeBufferPointer<Int16>) throws -> Void)?
  ) throws -> JPEGIndependentProgressive420Image {
    guard maximumOperationByteCharge >= 0, maximumMetadataBytes >= 0 else {
      throw JPEGIndependentProgressive420Error.invalidOperationBudget
    }
    let security = try EncodedImageSecurityInspector.inspect(
      data,
      maximumMetadataBytes: maximumMetadataBytes,
      materializePNGICCProfile: false,
      materializeJPEGICCProfile: false
    )
    guard security.format == .jpeg else { throw ImageCraftError.formatMismatch }
    guard security.sourceColorProfile != .embeddedICC, security.embeddedICCProfile == nil else {
      throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
    }

    let statePlan = try JPEGIndependentProgressive420StatePlan.inspect(data)
    let outputBytes = try Self.multiplied(
      try Self.multiplied(statePlan.width, statePlan.height),
      3
    )
    let operationByteCharge = try Self.added(outputBytes, statePlan.totalStateBytes)
    guard operationByteCharge <= maximumOperationByteCharge else {
      throw JPEGIndependentProgressive420Error.operationBudgetExceeded(
        requiredBytes: operationByteCharge,
        maximumBytes: maximumOperationByteCharge
      )
    }

    let state = try StateArena(plan: statePlan)
    var output = Data(count: outputBytes)
    let scanCount = try data.withUnsafeBytes { rawInput in
      let input = rawInput.bindMemory(to: UInt8.self)
      return try output.withUnsafeMutableBytes { rawOutput in
        let destination = rawOutput.bindMemory(to: UInt8.self)
        var parser = Parser(
          bytes: input,
          plan: statePlan,
          quantizationSource: FrameQuantizationSourceState()
        )
        let scans = try parser.decodeAll(state: state) { completedScan in
          guard let scanPreviewObserver else { return }
          try render(
            state: state,
            destination: destination,
            blockSmoothing: scanPreviewPolicy == .libjpegBlockSmoothing
          )
          try scanPreviewObserver(completedScan, UnsafeBufferPointer(destination))
        }
        if let finalCoefficientObserver {
          try finalCoefficientObserver(state.allCoefficients)
        }
        if scanPreviewObserver == nil {
          try render(state: state, destination: destination, blockSmoothing: false)
        }
        return scans
      }
    }
    return JPEGIndependentProgressive420Image(
      width: statePlan.width,
      height: statePlan.height,
      rgb: output,
      scanCount: scanCount,
      statePlan: statePlan,
      operationByteCharge: operationByteCharge
    )
  }

  private func render(
    state: StateArena,
    destination: UnsafeMutableBufferPointer<UInt8>,
    blockSmoothing: Bool
  ) throws {
    let plan = state.plan
    let renderArena = try RenderArena(plan: plan)
    var hasDeferredBoundaryRow = false
    for iMCURow in 0..<plan.mcuRows {
      let outputRowBase = iMCURow * 16
      let outputRowsInStrip = min(16, plan.height - outputRowBase)
      let chromaRowBase = iMCURow * 8
      let chromaRowsInStrip = min(8, plan.chromaHeight - chromaRowBase)
      guard outputRowsInStrip > 0, chromaRowsInStrip > 0 else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }

      for blockX in 0..<plan.chromaWidthBlocks {
        try state.renderBlock(
          component: 1,
          blockX: blockX,
          blockY: iMCURow,
          target: renderArena.cbStrip,
          targetRowStride: plan.chromaRowStrideBytes,
          targetX: blockX * 8,
          targetY: 0,
          logicalWidth: plan.chromaWidth,
          logicalHeight: chromaRowsInStrip,
          blockSmoothing: blockSmoothing,
          workspace: renderArena.workspace,
          smoothingScratch: renderArena.smoothingScratch,
          quantizationScratch: renderArena.quantizationScratch
        )
        try state.renderBlock(
          component: 2,
          blockX: blockX,
          blockY: iMCURow,
          target: renderArena.crStrip,
          targetRowStride: plan.chromaRowStrideBytes,
          targetX: blockX * 8,
          targetY: 0,
          logicalWidth: plan.chromaWidth,
          logicalHeight: chromaRowsInStrip,
          blockSmoothing: blockSmoothing,
          workspace: renderArena.workspace,
          smoothingScratch: renderArena.smoothingScratch,
          quantizationScratch: renderArena.quantizationScratch
        )
      }

      if hasDeferredBoundaryRow {
        try renderDeferredBoundaryRow(
          currentIMCURow: iMCURow,
          state: state,
          renderArena: renderArena,
          destination: destination
        )
        hasDeferredBoundaryRow = false
      }

      // Keep the prior strip's Y row 15 live until the new chroma row 0 exists. This lets the
      // fancy vertical boundary consume its future chroma context without copying the Y row into
      // separate scratch. Only now may the next Y strip overwrite yStrip.
      for localBlockRow in 0..<2 {
        let blockY = iMCURow * 2 + localBlockRow
        if blockY >= plan.yActualHeightBlocks { continue }
        let targetY = localBlockRow * 8
        for blockX in 0..<plan.yActualWidthBlocks {
          try state.renderBlock(
            component: 0,
            blockX: blockX,
            blockY: blockY,
            target: renderArena.yStrip,
            targetRowStride: plan.yRowStrideBytes,
            targetX: blockX * 8,
            targetY: targetY,
            logicalWidth: plan.width,
            logicalHeight: outputRowsInStrip,
            blockSmoothing: blockSmoothing,
            workspace: renderArena.workspace,
            smoothingScratch: renderArena.smoothingScratch,
            quantizationScratch: renderArena.quantizationScratch
          )
        }
      }

      let hasNextOutputStrip = outputRowBase + outputRowsInStrip < plan.height
      for localOutputRow in 0..<outputRowsInStrip {
        let needsFutureContext = plan.usesFancyGlobalContext
          && localOutputRow == 15
          && hasNextOutputStrip
        if needsFutureContext {
          try renderArena.copyChromaRowToPrevious(localRow: 7, plan: plan)
          hasDeferredBoundaryRow = true
          continue
        }
        try renderCurrentRow(
          iMCURow: iMCURow,
          localOutputRow: localOutputRow,
          outputRowsInStrip: outputRowsInStrip,
          chromaRowsInStrip: chromaRowsInStrip,
          state: state,
          renderArena: renderArena,
          destination: destination
        )
      }
    }
    guard !hasDeferredBoundaryRow else { throw ImageCraftError.unsupportedOrCorruptImage }
  }

  private func renderDeferredBoundaryRow(
    currentIMCURow: Int,
    state: StateArena,
    renderArena: RenderArena,
    destination: UnsafeMutableBufferPointer<UInt8>
  ) throws {
    guard state.plan.usesFancyGlobalContext, currentIMCURow > 0 else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    try reconstructAndWriteRow(
      y: renderArena.yRow(localRow: 15, plan: state.plan),
      currentCb: renderArena.previousCbRowPrefix(plan: state.plan),
      adjacentCb: renderArena.cbRow(localRow: 0, plan: state.plan),
      currentCr: renderArena.previousCrRowPrefix(plan: state.plan),
      adjacentCr: renderArena.crRow(localRow: 0, plan: state.plan),
      outputRow: currentIMCURow * 16 - 1,
      state: state,
      renderArena: renderArena,
      destination: destination
    )
  }

  private func renderCurrentRow(
    iMCURow: Int,
    localOutputRow: Int,
    outputRowsInStrip: Int,
    chromaRowsInStrip: Int,
    state: StateArena,
    renderArena: RenderArena,
    destination: UnsafeMutableBufferPointer<UInt8>
  ) throws {
    let plan = state.plan
    guard localOutputRow >= 0, localOutputRow < outputRowsInStrip else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    let sourceRow = localOutputRow / 2
    guard sourceRow < chromaRowsInStrip else { throw ImageCraftError.unsupportedOrCorruptImage }
    let currentCb = renderArena.cbRow(localRow: sourceRow, plan: plan)
    let currentCr = renderArena.crRow(localRow: sourceRow, plan: plan)
    let adjacentCb: UnsafeBufferPointer<UInt8>
    let adjacentCr: UnsafeBufferPointer<UInt8>
    if !plan.usesFancyGlobalContext {
      adjacentCb = currentCb
      adjacentCr = currentCr
    } else if localOutputRow & 1 == 0 {
      if sourceRow > 0 {
        adjacentCb = renderArena.cbRow(localRow: sourceRow - 1, plan: plan)
        adjacentCr = renderArena.crRow(localRow: sourceRow - 1, plan: plan)
      } else if iMCURow == 0 {
        adjacentCb = currentCb
        adjacentCr = currentCr
      } else {
        adjacentCb = renderArena.previousCbRowPrefix(plan: plan)
        adjacentCr = renderArena.previousCrRowPrefix(plan: plan)
      }
    } else if sourceRow + 1 < chromaRowsInStrip {
      adjacentCb = renderArena.cbRow(localRow: sourceRow + 1, plan: plan)
      adjacentCr = renderArena.crRow(localRow: sourceRow + 1, plan: plan)
    } else {
      let globalOutputRow = iMCURow * 16 + localOutputRow
      guard globalOutputRow + 1 >= plan.height else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      adjacentCb = currentCb
      adjacentCr = currentCr
    }
    try reconstructAndWriteRow(
      y: renderArena.yRow(localRow: localOutputRow, plan: plan),
      currentCb: currentCb,
      adjacentCb: adjacentCb,
      currentCr: currentCr,
      adjacentCr: adjacentCr,
      outputRow: iMCURow * 16 + localOutputRow,
      state: state,
      renderArena: renderArena,
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
    state: StateArena,
    renderArena: RenderArena,
    destination: UnsafeMutableBufferPointer<UInt8>
  ) throws {
    let plan = state.plan
    let rowBytes = try Self.multiplied(plan.width, 3)
    let offset = try Self.multiplied(outputRow, rowBytes)
    guard outputRow >= 0, outputRow < plan.height,
      offset <= destination.count,
      rowBytes <= destination.count - offset,
      let base = destination.baseAddress
    else { throw ImageCraftError.unsupportedOrCorruptImage }
    let row = UnsafeMutableBufferPointer(start: base.advanced(by: offset), count: rowBytes)
    try JPEGYCbCrToRGB.writeCenteredH2V2RGBRow(
      y: y,
      currentCb: currentCb,
      adjacentCb: adjacentCb,
      currentCr: currentCr,
      adjacentCr: adjacentCr,
      destination: row,
      writeWidth: plan.width,
      usesFancyGlobalContext: plan.usesFancyGlobalContext
    )
  }

  private protocol JPEGQuantizationTableInstalling: AnyObject {
    func installQuantizationTable(
      tableIndex: Int,
      values: UnsafeBufferPointer<UInt8>
    ) throws
  }

  private protocol JPEGHuffmanTableInstalling: AnyObject {
    func installHuffmanTable(
      tableClass: Int,
      tableIndex: Int,
      counts: UnsafeBufferPointer<UInt8>,
      symbols: UnsafeBufferPointer<UInt8>
    ) throws
  }

  private final class FrameQuantizationSourceState: JPEGQuantizationTableInstalling {
    private var q0: UnsafeMutableRawPointer?
    private var q1: UnsafeMutableRawPointer?
    private var q2: UnsafeMutableRawPointer?
    private var q3: UnsafeMutableRawPointer?

    private(set) var retainedByteCount = 0
    private(set) var maximumObservedRetainedByteCount = 0

    deinit {
      for index in 0..<4 {
        if let pointer = pointer(for: index) { free(pointer) }
      }
    }

    func installQuantizationTable(
      tableIndex: Int,
      values: UnsafeBufferPointer<UInt8>
    ) throws {
      guard (0..<4).contains(tableIndex), values.count == 64,
        let sourceBase = values.baseAddress
      else { throw ImageCraftError.unsupportedOrCorruptImage }
      for value in values where value == 0 {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      var destination = pointer(for: tableIndex)
      if destination == nil {
        destination = malloc(64)
        guard let destination else {
          throw JPEGIndependentProgressive420Error.stateAllocationFailed(byteCount: 64)
        }
        setPointer(destination, for: tableIndex)
        retainedByteCount += 64
        maximumObservedRetainedByteCount = max(
          maximumObservedRetainedByteCount,
          retainedByteCount
        )
      }
      memcpy(destination!, sourceBase, 64)
    }

    func values(tableIndex: Int) throws -> UnsafeBufferPointer<UInt8> {
      guard (0..<4).contains(tableIndex), let base = pointer(for: tableIndex)
      else { throw ImageCraftError.unsupportedOrCorruptImage }
      return UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: 64)
    }

    func adoptQuantizationTable(
      tableIndex: Int,
      pointer: UnsafeMutableRawPointer
    ) throws {
      guard (0..<4).contains(tableIndex), self.pointer(for: tableIndex) == nil else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      setPointer(pointer, for: tableIndex)
      retainedByteCount += 64
      maximumObservedRetainedByteCount = max(
        maximumObservedRetainedByteCount,
        retainedByteCount
      )
    }

    private func pointer(for index: Int) -> UnsafeMutableRawPointer? {
      switch index {
      case 0: return q0
      case 1: return q1
      case 2: return q2
      case 3: return q3
      default: return nil
      }
    }

    private func setPointer(_ pointer: UnsafeMutableRawPointer?, for index: Int) {
      switch index {
      case 0: q0 = pointer
      case 1: q1 = pointer
      case 2: q2 = pointer
      case 3: q3 = pointer
      default: break
      }
    }
  }

  package enum IncrementalSessionError: Error, Equatable, Sendable {
    case invalidBudget
    case codecOwnedBudgetExceeded(requiredBytes: Int, maximumBytes: Int)
    case transportWindowExceeded
    case pendingTableStateExceeded
    case sessionTerminal
  }

  package enum IncrementalSessionPhase: String, Equatable, Sendable {
    case awaitingHeader
    case awaitingMarker
    case decodingEntropy
    case complete
    case terminal
  }

  package enum IncrementalSessionPreviewCadence: String, Equatable, Sendable {
    case everyCompletedScan
    case finalOnly
  }

  package struct IncrementalSessionSnapshot: Equatable, Sendable {
    package let phase: IncrementalSessionPhase
    package let acceptedEncodedBytes: Int
    package let reclaimedEncodedBytes: Int
    package let retainedTransportBytes: Int
    package let maximumObservedTransportBytes: Int
    package let retainedFrameQuantizationSourceBytes: Int
    package let maximumObservedFrameQuantizationSourceBytes: Int
    package let retainedPreFrameTableBytes: Int
    package let maximumObservedPreFrameTableBytes: Int
    package let retainedHuffmanTableBytes: Int
    package let maximumObservedHuffmanTableBytes: Int
    package let finalHuffmanTableBytesBeforeCompaction: Int?
    package let metadataByteCount: Int
    package let completedScanCount: Int
    package let lastRenderedScanCount: Int?
    package let currentScanMCUIndex: Int?
    package let currentScanMCUCount: Int?
    package let initialRetainedByteCharge: Int
    package let operationScratchByteCharge: Int
    package let codecOwnedByteCharge: Int
    package let statePlan: JPEGIndependentProgressive420StatePlan?
    package let resourceLedger: ImageDecodeResourceLedgerSnapshot
  }

  package final class IncrementalSession {
    /// A length-bearing JPEG marker occupies one retained `0xFF` prefix byte, one marker-code byte,
    /// and at most `UInt16.max` bytes beginning with the two-byte length field. Marker fill is
    /// normalized eagerly, so its cardinality does not widen this bound.
    package static let maximumMarkerSegmentEncodedBytes = 2 + Int(UInt16.max)
    /// The largest marker payload unit that must coexist before it can be committed is one DHT
    /// definition: table selector + 16 code-length counts + at most 256 symbols. DQT needs 65 B;
    /// JFIF/ICC/Adobe probes need only 14/12/12 B, and other APP/COM payloads stream-skip.
    package static let maximumMarkerSemanticUnitBytes = 1 + 16 + 256
    /// In the qualified progressive 4:2:0 domain, an interleaved MCU is DC-only (six blocks), while
    /// an AC scan has one block per MCU. AC-first is the largest transaction. With 63 spectral AC
    /// positions, the bit-maximizing terminal form is 62 newly nonzero coefficients at a 16-bit
    /// Huffman code + 10 magnitude bits each, followed by one EOBRUN symbol at a 16-bit code + the
    /// maximum 14 run bits. (Filling all 63 coefficients uses 4 fewer bits.) Byte stuffing can
    /// double the resulting entropy-byte count, and a restart transaction may additionally consume
    /// one two-byte marker before the MCU.
    package static let maximumACFirstTransactionBitCount =
      62 * (16 + 10) + (16 + 14)
    package static let maximumInterleavedDCFirstTransactionBitCount =
      6 * (16 + 11)
    package static let maximumACRefineTransactionBitCount =
      63 * 16 + 63 + 14
    package static let maximumEntropyTransactionEncodedBytes =
      2 * ((max(
        maximumACFirstTransactionBitCount,
        maximumInterleavedDCFirstTransactionBitCount,
        maximumACRefineTransactionBitCount
      ) + 7) / 8) + 2
    package static let transportCapacityBytes = max(
      maximumMarkerSemanticUnitBytes,
      maximumEntropyTransactionEncodedBytes
    )
    /// Maximum pre-frame table authority. Slots are allocated only when first defined, but each
    /// present pre-SOF Huffman slot owns a fixed 272-byte `16 counts + 256 symbol capacity` payload
    /// so redefinition can overwrite in place without a transient replacement allocation. Selector
    /// identity lives in the store's pointer fields and is not duplicated in semantic byte charge.
    package static let preFrameTableStateByteCount =
      4 * 64 + 8 * JPEGIndependentProgressive420StatePlan.maximumHuffmanTablePayloadByteCount
    package static let maximumRollbackBlockCount = 6
    package static let rollbackCoefficientBytes =
      maximumRollbackBlockCount * 64 * MemoryLayout<Int16>.stride
    /// One syntax-level padded Y block is decoded at a time. Streaming reuses one unoccupied block
    /// at the tail of the 6-block rollback arena; one-shot decode uses an equivalent temporary
    /// block. This is a sub-allocation of an already-dominant phase scratch, not an added peak.
    package static let dummyCoefficientScratchByteCount =
      64 * MemoryLayout<Int16>.stride
    package static let initialRetainedByteCharge =
      transportCapacityBytes + preFrameTableStateByteCount
    package static let operationScratchByteCharge = rollbackCoefficientBytes
    package static let frameQuantizationSourceByteCount =
      JPEGIndependentProgressive420StatePlan.quantizationSourceStateByteCount
    /// Final-only EOI materialization needs only one IDCT workspace plus one widened quantization
    /// table. No smoothing state is required because validated final coefficients are rendered
    /// without progressive preview smoothing.
    package static let finalSampleMaterializationScratchByteCount =
      64 * MemoryLayout<Int32>.stride + 64 * MemoryLayout<UInt16>.stride

    package static func finalSamplePlaneByteCount(
      statePlan: JPEGIndependentProgressive420StatePlan
    ) throws -> Int {
      let y = try JPEGIndependentProgressive420Decoder.multiplied(
        statePlan.width,
        statePlan.height
      )
      let chroma = try JPEGIndependentProgressive420Decoder.multiplied(
        statePlan.chromaWidth,
        statePlan.chromaHeight
      )
      return try JPEGIndependentProgressive420Decoder.added(
        y,
        try JPEGIndependentProgressive420Decoder.multiplied(chroma, 2)
      )
    }

    package static func retainedByteChargeAfterFrame(
      statePlan: JPEGIndependentProgressive420StatePlan,
      outputByteCount: Int
    ) throws -> Int {
      guard outputByteCount >= 0 else { throw ImageCraftError.unsupportedOrCorruptImage }
      return try JPEGIndependentProgressive420Decoder.added(
        try JPEGIndependentProgressive420Decoder.added(
          transportCapacityBytes,
          statePlan.persistentStateBytes
        ),
        outputByteCount
      )
    }

    package static func retainedByteChargeBeforeFinalOnlyFinish(
      statePlan: JPEGIndependentProgressive420StatePlan
    ) throws -> Int {
      try JPEGIndependentProgressive420Decoder.added(
        transportCapacityBytes,
        statePlan.persistentStateBytes
      )
    }

    package static func retainedByteChargeBeforeQuantizationLatch(
      statePlan: JPEGIndependentProgressive420StatePlan
    ) throws -> Int {
      try JPEGIndependentProgressive420Decoder.added(
        try JPEGIndependentProgressive420Decoder.added(
          transportCapacityBytes,
          statePlan.persistentStateBytes
        ),
        frameQuantizationSourceByteCount
      )
    }

    package static func requiredOperationPeakByteCharge(
      statePlan: JPEGIndependentProgressive420StatePlan,
      outputByteCount: Int,
      previewCadence: IncrementalSessionPreviewCadence = .everyCompletedScan
    ) throws -> Int {
      guard outputByteCount >= 0 else { throw ImageCraftError.unsupportedOrCorruptImage }
      // Pre-frame DQT ownership is transferred into the frame quantization source store rather than
      // copied, so the full pre-frame authority and frame qsource never coexist as separate charges.
      let transitionPeak = try JPEGIndependentProgressive420Decoder.added(
        initialRetainedByteCharge,
        statePlan.persistentStateBytes
      )
      switch previewCadence {
      case .everyCompletedScan:
        let retainedAfterPreview = try retainedByteChargeAfterFrame(
          statePlan: statePlan,
          outputByteCount: outputByteCount
        )
        let entropyOperationPeak = try JPEGIndependentProgressive420Decoder.added(
          retainedAfterPreview,
          operationScratchByteCharge
        )
        let previewRenderPeak = try JPEGIndependentProgressive420Decoder.added(
          retainedAfterPreview,
          statePlan.renderScratchBytes
        )
        let huffmanMutationPeak = try JPEGIndependentProgressive420Decoder.added(
          retainedAfterPreview,
          JPEGIndependentProgressive420StatePlan.maximumHuffmanTablePayloadByteCount
        )
        return max(
          transitionPeak,
          entropyOperationPeak,
          previewRenderPeak,
          huffmanMutationPeak
        )
      case .finalOnly:
        let retainedBeforeFinish = try retainedByteChargeBeforeFinalOnlyFinish(
          statePlan: statePlan
        )
        let entropyOperationPeak = try JPEGIndependentProgressive420Decoder.added(
          retainedBeforeFinish,
          operationScratchByteCharge
        )
        let finalSampleBytes = try finalSamplePlaneByteCount(statePlan: statePlan)
        // EOI has already consumed and reclaimed the complete transport window. The final-only
        // path releases the fixed transport backing before sample materialization, so this phase
        // coexists only with persistent coefficient/control authority and tight spatial samples.
        let finalSampleMaterializationPeak = try JPEGIndependentProgressive420Decoder.added(
          try JPEGIndependentProgressive420Decoder.added(
            statePlan.persistentStateBytes,
            finalSampleBytes
          ),
          finalSampleMaterializationScratchByteCount
        )
        // materialize-and-release is a lexical phase boundary: RGB allocation begins only after
        // coefficient/control state has been released by the helper that returns these samples.
        let finalRGBPeak = try JPEGIndependentProgressive420Decoder.added(
          finalSampleBytes,
          outputByteCount
        )
        let huffmanMutationPeak = try JPEGIndependentProgressive420Decoder.added(
          retainedBeforeFinish,
          JPEGIndependentProgressive420StatePlan.maximumHuffmanTablePayloadByteCount
        )
        return max(
          transitionPeak,
          entropyOperationPeak,
          finalSampleMaterializationPeak,
          finalRGBPeak,
          huffmanMutationPeak
        )
      }
    }

    private struct FinalSamplePlanes {
      let plan: JPEGIndependentProgressive420StatePlan
      private(set) var storage: Data
      let yByteCount: Int
      let chromaByteCount: Int

      init(plan: JPEGIndependentProgressive420StatePlan) throws {
        self.plan = plan
        yByteCount = try JPEGIndependentProgressive420Decoder.multiplied(
          plan.width,
          plan.height
        )
        chromaByteCount = try JPEGIndependentProgressive420Decoder.multiplied(
          plan.chromaWidth,
          plan.chromaHeight
        )
        storage = Data(
          count: try JPEGIndependentProgressive420Decoder.added(
            yByteCount,
            try JPEGIndependentProgressive420Decoder.multiplied(chromaByteCount, 2)
          )
        )
      }

      var byteCount: Int { storage.count }

      mutating func withMutablePlanes<R>(
        _ body: (
          UnsafeMutableBufferPointer<UInt8>,
          UnsafeMutableBufferPointer<UInt8>,
          UnsafeMutableBufferPointer<UInt8>
        ) throws -> R
      ) rethrows -> R {
        try storage.withUnsafeMutableBytes { raw in
          let bytes = raw.bindMemory(to: UInt8.self)
          guard let base = bytes.baseAddress else {
            preconditionFailure("non-empty final sample storage has no base address")
          }
          let y = UnsafeMutableBufferPointer(start: base, count: yByteCount)
          let cb = UnsafeMutableBufferPointer(
            start: base.advanced(by: yByteCount),
            count: chromaByteCount
          )
          let cr = UnsafeMutableBufferPointer(
            start: base.advanced(by: yByteCount + chromaByteCount),
            count: chromaByteCount
          )
          return try body(y, cb, cr)
        }
      }

      func withPlanes<R>(
        _ body: (
          UnsafeBufferPointer<UInt8>,
          UnsafeBufferPointer<UInt8>,
          UnsafeBufferPointer<UInt8>
        ) throws -> R
      ) rethrows -> R {
        try storage.withUnsafeBytes { raw in
          let bytes = raw.bindMemory(to: UInt8.self)
          guard let base = bytes.baseAddress else {
            preconditionFailure("non-empty final sample storage has no base address")
          }
          let y = UnsafeBufferPointer(start: base, count: yByteCount)
          let cb = UnsafeBufferPointer(
            start: base.advanced(by: yByteCount),
            count: chromaByteCount
          )
          let cr = UnsafeBufferPointer(
            start: base.advanced(by: yByteCount + chromaByteCount),
            count: chromaByteCount
          )
          return try body(y, cb, cr)
        }
      }
    }

    private struct PendingMarkerSegment {
      let marker: UInt8
      let declaredPayloadByteCount: Int
      let wasFirstMarkerAfterSOI: Bool
      var remainingPayloadBytes: Int
      var semanticPrefixHandled = false
    }

    private enum Phase {
      case needsSOI
      case markers
      case markerPayload(PendingMarkerSegment)
      case entropy(scan: ScanHeader, runtime: ProgressiveScanRuntime)
      case complete
      case terminal
    }

    private final class TransportBuffer {
      let baseAddress: UnsafeMutableRawPointer
      let bytes: UnsafeMutableBufferPointer<UInt8>

      init() throws {
        var pointer: UnsafeMutableRawPointer?
        let result = posix_memalign(
          &pointer,
          JPEGIndependentProgressive420StatePlan.rowAlignmentBytes,
          IncrementalSession.transportCapacityBytes
        )
        guard result == 0, let pointer else {
          throw JPEGIndependentProgressive420Error.stateAllocationFailed(
            byteCount: IncrementalSession.transportCapacityBytes
          )
        }
        baseAddress = pointer
        memset(pointer, 0, IncrementalSession.transportCapacityBytes)
        bytes = UnsafeMutableBufferPointer(
          start: pointer.assumingMemoryBound(to: UInt8.self),
          count: IncrementalSession.transportCapacityBytes
        )
      }

      deinit { free(baseAddress) }
    }

    private final class PreFrameTableState:
      JPEGQuantizationTableInstalling,
      JPEGHuffmanTableInstalling
    {
      private var q0: UnsafeMutableRawPointer?
      private var q1: UnsafeMutableRawPointer?
      private var q2: UnsafeMutableRawPointer?
      private var q3: UnsafeMutableRawPointer?
      private var h0: UnsafeMutableRawPointer?
      private var h1: UnsafeMutableRawPointer?
      private var h2: UnsafeMutableRawPointer?
      private var h3: UnsafeMutableRawPointer?
      private var h4: UnsafeMutableRawPointer?
      private var h5: UnsafeMutableRawPointer?
      private var h6: UnsafeMutableRawPointer?
      private var h7: UnsafeMutableRawPointer?

      private(set) var retainedByteCount = 0
      private(set) var maximumObservedRetainedByteCount = 0

      func installQuantizationTable(
        tableIndex: Int,
        values: UnsafeBufferPointer<UInt8>
      ) throws {
        guard (0..<4).contains(tableIndex), values.count == 64,
          let sourceBase = values.baseAddress
        else { throw ImageCraftError.unsupportedOrCorruptImage }
        for value in values where value == 0 {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
        var destination = quantizationPointer(for: tableIndex)
        if destination == nil {
          destination = malloc(64)
          guard let destination else {
            throw JPEGIndependentProgressive420Error.stateAllocationFailed(byteCount: 64)
          }
          setQuantizationPointer(destination, for: tableIndex)
          retainedByteCount += 64
          maximumObservedRetainedByteCount = max(
            maximumObservedRetainedByteCount,
            retainedByteCount
          )
        }
        memcpy(destination!, sourceBase, 64)
      }

      func installHuffmanTable(
        tableClass: Int,
        tableIndex: Int,
        counts: UnsafeBufferPointer<UInt8>,
        symbols: UnsafeBufferPointer<UInt8>
      ) throws {
        guard (0...1).contains(tableClass), (0...3).contains(tableIndex),
          counts.count == 16, !symbols.isEmpty, symbols.count <= 256,
          let countsSource = counts.baseAddress,
          let symbolsSource = symbols.baseAddress
        else { throw ImageCraftError.unsupportedOrCorruptImage }
        var declaredSymbolCount = 0
        for value in counts { declaredSymbolCount += Int(value) }
        guard declaredSymbolCount == symbols.count else {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
        let slot = tableClass * 4 + tableIndex
        var destination = huffmanPointer(for: slot)
        if destination == nil {
          let byteCount = JPEGIndependentProgressive420StatePlan.maximumHuffmanTablePayloadByteCount
          destination = malloc(byteCount)
          guard let destination else {
            throw JPEGIndependentProgressive420Error.stateAllocationFailed(byteCount: byteCount)
          }
          setHuffmanPointer(destination, for: slot)
          retainedByteCount += byteCount
          maximumObservedRetainedByteCount = max(
            maximumObservedRetainedByteCount,
            retainedByteCount
          )
        }
        memcpy(destination!, countsSource, 16)
        memset(destination!.advanced(by: 16), 0, 256)
        memcpy(destination!.advanced(by: 16), symbolsSource, symbols.count)
      }

      func quantizationTable(_ tableIndex: Int) -> UnsafeBufferPointer<UInt8>? {
        guard let pointer = quantizationPointer(for: tableIndex) else { return nil }
        return UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: UInt8.self), count: 64)
      }

      func transferQuantizationTables(
        to destination: FrameQuantizationSourceState
      ) throws {
        for tableIndex in 0..<4 {
          guard let pointer = quantizationPointer(for: tableIndex) else { continue }
          try destination.adoptQuantizationTable(
            tableIndex: tableIndex,
            pointer: pointer
          )
          setQuantizationPointer(nil, for: tableIndex)
          retainedByteCount -= 64
        }
        guard retainedByteCount >= 0 else {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
      }

      func huffmanTable(_ slot: Int) -> OwnedHuffmanTable? {
        guard let pointer = huffmanPointer(for: slot) else { return nil }
        let base = pointer.assumingMemoryBound(to: UInt8.self)
        var symbolCount = 0
        for index in 0..<16 { symbolCount += Int(base[index]) }
        guard symbolCount > 0, symbolCount <= 256 else { return nil }
        return OwnedHuffmanTable(
          counts: UnsafeBufferPointer(start: base, count: 16),
          symbols: UnsafeBufferPointer(start: base.advanced(by: 16), count: symbolCount),
          symbolCount: symbolCount
        )
      }

      deinit {
        for index in 0..<4 {
          if let pointer = quantizationPointer(for: index) { free(pointer) }
        }
        for slot in 0..<8 {
          if let pointer = huffmanPointer(for: slot) { free(pointer) }
        }
      }

      private func quantizationPointer(for index: Int) -> UnsafeMutableRawPointer? {
        switch index {
        case 0: return q0
        case 1: return q1
        case 2: return q2
        case 3: return q3
        default: return nil
        }
      }

      private func setQuantizationPointer(_ pointer: UnsafeMutableRawPointer?, for index: Int) {
        switch index {
        case 0: q0 = pointer
        case 1: q1 = pointer
        case 2: q2 = pointer
        case 3: q3 = pointer
        default: break
        }
      }

      private func huffmanPointer(for slot: Int) -> UnsafeMutableRawPointer? {
        switch slot {
        case 0: return h0
        case 1: return h1
        case 2: return h2
        case 3: return h3
        case 4: return h4
        case 5: return h5
        case 6: return h6
        case 7: return h7
        default: return nil
        }
      }

      private func setHuffmanPointer(_ pointer: UnsafeMutableRawPointer?, for slot: Int) {
        switch slot {
        case 0: h0 = pointer
        case 1: h1 = pointer
        case 2: h2 = pointer
        case 3: h3 = pointer
        case 4: h4 = pointer
        case 5: h5 = pointer
        case 6: h6 = pointer
        case 7: h7 = pointer
        default: break
        }
      }
    }

    private let maximumCodecOwnedByteCharge: Int
    private let limits: DecodeLimits
    private let previewCadence: IncrementalSessionPreviewCadence
    private var transportBuffer: TransportBuffer?
    private var preFrameTables: PreFrameTableState?
    private var frameQuantizationTables: FrameQuantizationSourceState?
    private var state: StateArena?
    private var output: Data?
    private var admittedOutputByteCount: Int?
    private var statePlan: JPEGIndependentProgressive420StatePlan?
    private var admittedOperationPeakByteCharge: Int?
    private var frame: Frame?
    private var phase: Phase = .needsSOI
    private var transportStart = 0
    private var transportEnd = 0
    private var acceptedEncodedBytes = 0
    private var reclaimedEncodedBytes = 0
    private var maximumObservedTransportBytes = 0
    private var maximumObservedFrameQuantizationSourceBytes = 0
    private var maximumObservedPreFrameTableBytes = 0
    private var maximumObservedHuffmanTableBytes = 0
    private var finalHuffmanTableBytesBeforeCompaction: Int?
    private var metadataBytes = 0
    private var restartIntervalMCUs = 0
    private var startedScanCount = 0
    private var completedScanCount = 0
    private var lastRenderedScanCount: Int?
    private var sawJFIF = false
    private var hasProcessedMarkerAfterSOI = false
    private var quantizationLatched = false

    package init(
      maximumCodecOwnedByteCharge: Int,
      limits: DecodeLimits = .coreV1,
      previewCadence: IncrementalSessionPreviewCadence = .everyCompletedScan
    ) throws {
      guard maximumCodecOwnedByteCharge >= 0 else {
        throw IncrementalSessionError.invalidBudget
      }
      guard limits.allowedFormats.contains(.jpeg) else {
        throw ImageCraftError.unsupportedFormat
      }
      guard maximumCodecOwnedByteCharge >= Self.initialRetainedByteCharge else {
        throw IncrementalSessionError.codecOwnedBudgetExceeded(
          requiredBytes: Self.initialRetainedByteCharge,
          maximumBytes: maximumCodecOwnedByteCharge
        )
      }
      self.maximumCodecOwnedByteCharge = maximumCodecOwnedByteCharge
      self.limits = limits
      self.previewCadence = previewCadence
      self.transportBuffer = try TransportBuffer()
      self.preFrameTables = PreFrameTableState()
    }

    package func snapshot() -> IncrementalSessionSnapshot {
      let activePlan = statePlan
      let retained = codecOwnedByteCharge
      let ledger: ImageDecodeResourceLedgerSnapshot
      if case .terminal = phase {
        ledger = .terminal
      } else {
        let operationUpperBound = admittedOperationPeakByteCharge ?? maximumCodecOwnedByteCharge
        ledger = ImageDecodeResourceLedgerSnapshot(
          retainedKnownBytes: retained,
          retainedBetweenCalls: .bounded(retained),
          operationPeak: .bounded(operationUpperBound),
          transferredOutput: .bounded(admittedOutputByteCount ?? 0),
          outputLayoutAuthority: activePlan == nil ? .none : .codecOwnedRGB8
        )!
      }
      let currentMCUs: (Int?, Int?)
      switch phase {
      case .entropy(_, let runtime):
        currentMCUs = (runtime.scanMCUIndex, runtime.scanMCUCount)
      default:
        currentMCUs = (nil, nil)
      }
      return IncrementalSessionSnapshot(
        phase: publishedPhase,
        acceptedEncodedBytes: acceptedEncodedBytes,
        reclaimedEncodedBytes: reclaimedEncodedBytes,
        retainedTransportBytes: retainedTransportByteCount,
        maximumObservedTransportBytes: maximumObservedTransportBytes,
        retainedFrameQuantizationSourceBytes:
          frameQuantizationTables?.retainedByteCount ?? 0,
        maximumObservedFrameQuantizationSourceBytes:
          maximumObservedFrameQuantizationSourceBytes,
        retainedPreFrameTableBytes: preFrameTables?.retainedByteCount ?? 0,
        maximumObservedPreFrameTableBytes: max(
          maximumObservedPreFrameTableBytes,
          preFrameTables?.maximumObservedRetainedByteCount ?? 0
        ),
        retainedHuffmanTableBytes: state?.retainedHuffmanTableByteCount ?? 0,
        maximumObservedHuffmanTableBytes: max(
          maximumObservedHuffmanTableBytes,
          state?.maximumObservedHuffmanTableByteCount ?? 0
        ),
        finalHuffmanTableBytesBeforeCompaction: finalHuffmanTableBytesBeforeCompaction,
        metadataByteCount: metadataBytes,
        completedScanCount: completedScanCount,
        lastRenderedScanCount: lastRenderedScanCount,
        currentScanMCUIndex: currentMCUs.0,
        currentScanMCUCount: currentMCUs.1,
        initialRetainedByteCharge: Self.initialRetainedByteCharge,
        operationScratchByteCharge: Self.operationScratchByteCharge,
        codecOwnedByteCharge: retained,
        statePlan: activePlan,
        resourceLedger: ledger
      )
    }

    package func cancel() {
      guard !isTerminal else { return }
      releaseCodecOwnedState()
      phase = .terminal
    }

    /// Accepts caller-owned bytes without retaining the caller's `Data` value. Completed scan
    /// numbers are returned only after every MCU in that scan has committed transactionally.
    /// Encoded-byte admission is pre-acceptance and therefore retryable; every parser/semantic
    /// failure after acceptance terminalizes the session and reclaims all codec-owned state.
    package func append(_ data: Data) throws -> Range<Int> {
      guard !isTerminal else { throw IncrementalSessionError.sessionTerminal }
      let accepted = acceptedEncodedBytes.addingReportingOverflow(data.count)
      guard !accepted.overflow, accepted.partialValue <= limits.maximumEncodedBytes else {
        throw ImageCraftError.encodedBytesExceeded
      }
      let firstNewScan = completedScanCount + 1
      if case .complete = phase, data.isEmpty { return firstNewScan..<firstNewScan }

      acceptedEncodedBytes = accepted.partialValue
      do {
        if case .complete = phase, !data.isEmpty {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
        try data.withUnsafeBytes { rawInput in
          let input = rawInput.bindMemory(to: UInt8.self)
          var inputOffset = 0
          while inputOffset < input.count {
            if case .complete = phase {
              throw ImageCraftError.unsupportedOrCorruptImage
            }
            try makeTransportWriteSpace()
            guard let transportBuffer,
              let inputBase = input.baseAddress,
              let transportBase = transportBuffer.bytes.baseAddress
            else { throw ImageCraftError.unsupportedOrCorruptImage }
            let writable = transportBuffer.bytes.count - transportEnd
            guard writable > 0 else { throw IncrementalSessionError.transportWindowExceeded }
            let copyCount = min(writable, input.count - inputOffset)
            memcpy(
              transportBase.advanced(by: transportEnd),
              inputBase.advanced(by: inputOffset),
              copyCount
            )
            transportEnd += copyCount
            inputOffset += copyCount
            maximumObservedTransportBytes = max(
              maximumObservedTransportBytes,
              retainedTransportByteCount
            )
            try processAvailable(finalInput: false)
          }
        }
        try processAvailable(finalInput: false)
        return firstNewScan..<(completedScanCount + 1)
      } catch {
        terminalizeFailure()
        throw error
      }
    }

    /// Declares end-of-input, transfers the already-compacted codec-owned RGB value, and releases
    /// the remaining final-ready value/state bookkeeping before returning. A validated EOI compacts
    /// entropy/control state eagerly so `finish()` itself does not need decoder state to rasterize.
    package func finish() throws -> JPEGIndependentProgressive420Image {
      guard !isTerminal else { throw IncrementalSessionError.sessionTerminal }
      do {
        try processAvailable(finalInput: true)
        guard case .complete = phase,
          let finalPlan = statePlan,
          completedScanCount > 0
        else { throw ImageCraftError.unsupportedOrCorruptImage }
        guard let finalOutput = output else {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
        guard let operationPeak = admittedOperationPeakByteCharge else {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
        let result = JPEGIndependentProgressive420Image(
          width: finalPlan.width,
          height: finalPlan.height,
          rgb: finalOutput,
          scanCount: completedScanCount,
          statePlan: finalPlan,
          operationByteCharge: operationPeak
        )
        releaseCodecOwnedState()
        phase = .terminal
        return result
      } catch {
        terminalizeFailure()
        throw error
      }
    }

    package func withCurrentPreview<R>(
      _ body: (Int, UnsafeBufferPointer<UInt8>) throws -> R
    ) throws -> R {
      guard !isTerminal, let renderedScan = lastRenderedScanCount, let output else {
        throw ImageCraftError.progressiveDecodingUnsupported
      }
      return try output.withUnsafeBytes { raw in
        try body(renderedScan, raw.bindMemory(to: UInt8.self))
      }
    }

    private func makeTransportWriteSpace() throws {
      guard let transportBuffer else { throw IncrementalSessionError.sessionTerminal }
      if transportEnd < transportBuffer.bytes.count { return }
      if transportStart > 0 {
        let count = retainedTransportByteCount
        if count > 0,
          let base = transportBuffer.bytes.baseAddress
        {
          memmove(base, base.advanced(by: transportStart), count)
        }
        transportStart = 0
        transportEnd = count
      }
      if transportEnd < transportBuffer.bytes.count { return }
      if reclaimRedundantMarkerFillPrefix() { return }

      let beforeStart = transportStart
      try processAvailable(finalInput: false)
      if transportEnd == transportBuffer.bytes.count,
        transportStart == beforeStart,
        reclaimRedundantMarkerFillPrefix()
      {
        return
      }
      guard transportStart != beforeStart || retainedTransportByteCount == 0 else {
        throw IncrementalSessionError.transportWindowExceeded
      }
      if transportStart > 0 {
        let count = retainedTransportByteCount
        if count > 0,
          let base = transportBuffer.bytes.baseAddress
        {
          memmove(base, base.advanced(by: transportStart), count)
        }
        transportStart = 0
        transportEnd = count
      }
    }

    /// JPEG permits any number of `0xFF` fill bytes before a marker code. While waiting for that
    /// code, all but one trailing `0xFF` are irrevocably redundant: one byte is sufficient to retain
    /// the unresolved marker prefix across calls. Reclaiming the proven pad prefix prevents valid
    /// marker fill from turning the fixed transport window into an accidental format limit.
    private func reclaimRedundantMarkerFillPrefix() -> Bool {
      let isProvenMarkerContext: Bool
      switch phase {
      case .markers:
        isProvenMarkerContext = true
      case .entropy(_, let runtime):
        isProvenMarkerContext = restartIntervalMCUs > 0
          && runtime.scanMCUIndex > 0
          && runtime.scanMCUIndex % restartIntervalMCUs == 0
          && runtime.eobRun == 0
      default:
        isProvenMarkerContext = false
      }
      guard isProvenMarkerContext,
        let transportBuffer,
        transportStart == 0,
        transportEnd > 1,
        let base = transportBuffer.bytes.baseAddress
      else { return false }
      for index in 0..<transportEnd where base[index] != 0xFF {
        return false
      }
      let reclaimed = transportEnd - 1
      base[0] = 0xFF
      transportStart = 0
      transportEnd = 1
      reclaimedEncodedBytes += reclaimed
      return true
    }

    /// Collapses a proven marker-fill prefix as soon as enough input is present to distinguish the
    /// trailing marker prefix from earlier duplicate `0xFF` pad bytes. This prevents a short fill
    /// run from coexisting with an otherwise maximum-length marker segment in the transport arena.
    @discardableResult
    private func normalizeRedundantMarkerFillPrefix() -> Bool {
      let isProvenMarkerContext: Bool
      switch phase {
      case .markers:
        isProvenMarkerContext = true
      case .entropy(_, let runtime):
        isProvenMarkerContext = restartIntervalMCUs > 0
          && runtime.scanMCUIndex > 0
          && runtime.scanMCUIndex % restartIntervalMCUs == 0
          && runtime.eobRun == 0
      default:
        isProvenMarkerContext = false
      }
      guard isProvenMarkerContext,
        let transportBuffer,
        transportStart == 0,
        transportEnd > 1,
        let base = transportBuffer.bytes.baseAddress
      else { return false }

      var firstNonFill = 0
      while firstNonFill < transportEnd, base[firstNonFill] == 0xFF {
        firstNonFill += 1
      }
      guard firstNonFill > 1 else { return false }

      let keepFrom = firstNonFill == transportEnd ? transportEnd - 1 : firstNonFill - 1
      let retained = transportEnd - keepFrom
      memmove(base, base.advanced(by: keepFrom), retained)
      reclaimedEncodedBytes += keepFrom
      transportStart = 0
      transportEnd = retained
      return true
    }

    private func processAvailable(finalInput: Bool) throws {
      while true {
        _ = normalizeRedundantMarkerFillPrefix()
        let beforeTransportStart = transportStart
        let beforePhase = publishedPhase
        var semanticProgress = false
        switch phase {
        case .needsSOI:
          let available = retainedTransportByteCount
          if available < 2 {
            if finalInput { throw ImageCraftError.unsupportedOrCorruptImage }
            return
          }
          try withAvailableTransportBytes { bytes in
            guard bytes[0] == 0xFF, bytes[1] == 0xD8 else {
              throw ImageCraftError.formatMismatch
            }
          }
          try consumeTransportBytes(2)
          phase = .markers

        case .markers:
          let didConsume = try processOneMarker(finalInput: finalInput)
          if !didConsume { return }

        case .markerPayload(let pending):
          let didConsume = try processPendingMarkerSegment(
            pending,
            finalInput: finalInput
          )
          if !didConsume { return }

        case .entropy(let scan, var runtime):
          let result = try processEntropyMCU(
            scan: scan,
            runtime: &runtime,
            finalInput: finalInput
          )
          switch result {
          case .needsMoreInput:
            phase = .entropy(scan: scan, runtime: runtime)
            if finalInput { throw ImageCraftError.unsupportedOrCorruptImage }
            return
          case .committed(let consumedBytes):
            semanticProgress = true
            try consumeTransportBytes(consumedBytes)
            if runtime.scanMCUIndex == runtime.scanMCUCount {
              try finishCompletedScan(scan: scan, runtime: &runtime)
              completedScanCount += 1
              if previewCadence == .everyCompletedScan {
                try renderCurrentCoefficients()
                lastRenderedScanCount = completedScanCount
              }
              phase = .markers
            } else {
              phase = .entropy(scan: scan, runtime: runtime)
            }
          }

        case .complete:
          if retainedTransportByteCount != 0 {
            throw ImageCraftError.unsupportedOrCorruptImage
          }
          try compactFinalReadyState()
          return

        case .terminal:
          throw IncrementalSessionError.sessionTerminal
        }

        let madeProgress = semanticProgress
          || transportStart != beforeTransportStart
          || publishedPhase != beforePhase
        if !madeProgress {
          if finalInput { throw ImageCraftError.unsupportedOrCorruptImage }
          return
        }
      }
    }

    private func withAvailableTransportBytes<R>(
      _ body: (UnsafeBufferPointer<UInt8>) throws -> R
    ) throws -> R {
      guard let transportBuffer, let base = transportBuffer.bytes.baseAddress else {
        throw IncrementalSessionError.sessionTerminal
      }
      let count = retainedTransportByteCount
      return try body(
        UnsafeBufferPointer(start: base.advanced(by: transportStart), count: count)
      )
    }

    private func consumeTransportBytes(_ count: Int) throws {
      guard count >= 0, count <= retainedTransportByteCount else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      transportStart += count
      reclaimedEncodedBytes += count
      if transportStart == transportEnd {
        transportStart = 0
        transportEnd = 0
      }
    }

    private struct ParsedMarker {
      let marker: UInt8
      let encodedHeaderByteCount: Int
      let payloadByteCount: Int?
    }

    private func processOneMarker(finalInput: Bool) throws -> Bool {
      guard let parsed = try inspectNextMarker() else {
        if finalInput { throw ImageCraftError.unsupportedOrCorruptImage }
        return false
      }
      let wasFirstMarkerAfterSOI = !hasProcessedMarkerAfterSOI
      switch parsed.marker {
      case 0xD9:
        hasProcessedMarkerAfterSOI = true
        try consumeTransportBytes(parsed.encodedHeaderByteCount)
        try validateFinalProgressionAndEOI()
        phase = .complete
      case 0x01:
        hasProcessedMarkerAfterSOI = true
        try consumeTransportBytes(parsed.encodedHeaderByteCount)
      case 0xD0...0xD8:
        throw ImageCraftError.unsupportedOrCorruptImage
      default:
        guard let payloadByteCount = parsed.payloadByteCount else {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
        if (0xE0...0xEF).contains(parsed.marker) || parsed.marker == 0xFE {
          let next = metadataBytes.addingReportingOverflow(payloadByteCount)
          guard !next.overflow, next.partialValue <= limits.maximumMetadataBytes else {
            throw ImageCraftError.metadataLimitExceeded
          }
          metadataBytes = next.partialValue
        }
        hasProcessedMarkerAfterSOI = true
        try consumeTransportBytes(parsed.encodedHeaderByteCount)
        phase = .markerPayload(
          PendingMarkerSegment(
            marker: parsed.marker,
            declaredPayloadByteCount: payloadByteCount,
            wasFirstMarkerAfterSOI: wasFirstMarkerAfterSOI,
            remainingPayloadBytes: payloadByteCount
          )
        )
      }
      return true
    }

    private func inspectNextMarker() throws -> ParsedMarker? {
      try withAvailableTransportBytes { bytes in
        guard !bytes.isEmpty else { return nil }
        guard bytes[0] == 0xFF else { throw ImageCraftError.unsupportedOrCorruptImage }
        var cursor = 0
        while cursor < bytes.count, bytes[cursor] == 0xFF { cursor += 1 }
        guard cursor < bytes.count else { return nil }
        let marker = bytes[cursor]
        guard marker != 0x00 else { throw ImageCraftError.unsupportedOrCorruptImage }
        let markerByteCount = cursor + 1
        if marker == 0xD9 || marker == 0x01 || (0xD0...0xD8).contains(marker) {
          return ParsedMarker(
            marker: marker,
            encodedHeaderByteCount: markerByteCount,
            payloadByteCount: nil
          )
        }
        guard markerByteCount + 2 <= bytes.count else { return nil }
        let length = Int(bytes[markerByteCount]) << 8 | Int(bytes[markerByteCount + 1])
        guard length >= 2 else { throw ImageCraftError.unsupportedOrCorruptImage }
        return ParsedMarker(
          marker: marker,
          encodedHeaderByteCount: markerByteCount + 2,
          payloadByteCount: length - 2
        )
      }
    }

    private func processPendingMarkerSegment(
      _ original: PendingMarkerSegment,
      finalInput: Bool
    ) throws -> Bool {
      var pending = original
      if pending.remainingPayloadBytes == 0 {
        phase = .markers
        return true
      }

      switch pending.marker {
      case 0xC0, 0xC1, 0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF,
        0xCC, 0xDC:
        throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics

      case 0xC2:
        guard pending.declaredPayloadByteCount == 15 else {
          throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
        }
        return try processWholePendingSegment(pending, finalInput: finalInput)

      case 0xDA:
        guard pending.declaredPayloadByteCount == 6 || pending.declaredPayloadByteCount == 10 else {
          throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
        }
        return try processWholePendingSegment(pending, finalInput: finalInput)

      case 0xDD:
        guard pending.declaredPayloadByteCount == 2 else {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
        return try processWholePendingSegment(pending, finalInput: finalInput)

      case 0xDB:
        guard !quantizationLatched else {
          throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
        }
        guard pending.remainingPayloadBytes >= 65 else {
          throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
        }
        guard retainedTransportByteCount >= 1 else {
          if finalInput { throw ImageCraftError.unsupportedOrCorruptImage }
          return false
        }
        let precisionAndIndex = try withAvailableTransportBytes { $0[0] }
        guard precisionAndIndex >> 4 == 0, precisionAndIndex & 0x0F <= 3 else {
          throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
        }
        guard retainedTransportByteCount >= 65 else {
          if finalInput { throw ImageCraftError.unsupportedOrCorruptImage }
          return false
        }
        try withAvailableTransportBytes { bytes in
          try acceptTableSegment(
            marker: 0xDB,
            bytes: bytes,
            segment: Segment(payload: 0..<65, end: 65)
          )
        }
        try consumeTransportBytes(65)
        pending.remainingPayloadBytes -= 65
        phase = pending.remainingPayloadBytes == 0 ? .markers : .markerPayload(pending)
        return true

      case 0xC4:
        guard pending.remainingPayloadBytes >= 17 else {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
        guard retainedTransportByteCount >= 17 else {
          if finalInput { throw ImageCraftError.unsupportedOrCorruptImage }
          return false
        }
        let semanticUnitByteCount = try withAvailableTransportBytes { bytes -> Int in
          let info = bytes[0]
          guard info >> 4 <= 1, info & 0x0F <= 3 else {
            throw ImageCraftError.unsupportedOrCorruptImage
          }
          var symbolCount = 0
          for index in 1...16 { symbolCount += Int(bytes[index]) }
          guard symbolCount > 0, symbolCount <= 256 else {
            throw ImageCraftError.unsupportedOrCorruptImage
          }
          return 17 + symbolCount
        }
        guard semanticUnitByteCount <= pending.remainingPayloadBytes else {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
        guard retainedTransportByteCount >= semanticUnitByteCount else {
          if finalInput { throw ImageCraftError.unsupportedOrCorruptImage }
          return false
        }
        try withAvailableTransportBytes { bytes in
          try acceptTableSegment(
            marker: 0xC4,
            bytes: bytes,
            segment: Segment(
              payload: 0..<semanticUnitByteCount,
              end: semanticUnitByteCount
            )
          )
        }
        try consumeTransportBytes(semanticUnitByteCount)
        pending.remainingPayloadBytes -= semanticUnitByteCount
        phase = pending.remainingPayloadBytes == 0 ? .markers : .markerPayload(pending)
        return true

      case 0xE0:
        return try processStreamingJFIFAPP0(pending, finalInput: finalInput)

      case 0xE1:
        return try processStreamingAPP1ProbeAuthority(pending, finalInput: finalInput)

      case 0xE2:
        return try processStreamingICCAPP2(pending, finalInput: finalInput)

      case 0xEE:
        return try processStreamingAdobeAPP14(pending, finalInput: finalInput)

      default:
        return try skipPendingMarkerPayload(pending, finalInput: finalInput)
      }
    }

    private func processWholePendingSegment(
      _ pending: PendingMarkerSegment,
      finalInput: Bool
    ) throws -> Bool {
      let count = pending.remainingPayloadBytes
      guard count == pending.declaredPayloadByteCount else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      guard retainedTransportByteCount >= count else {
        if finalInput { throw ImageCraftError.unsupportedOrCorruptImage }
        return false
      }
      try withAvailableTransportBytes { bytes in
        try processSegment(
          marker: pending.marker,
          bytes: bytes,
          segment: Segment(payload: 0..<count, end: count)
        )
      }
      try consumeTransportBytes(count)
      if case .markerPayload = phase {
        phase = .markers
      }
      return true
    }

    private func processStreamingJFIFAPP0(
      _ original: PendingMarkerSegment,
      finalInput: Bool
    ) throws -> Bool {
      var pending = original
      if pending.semanticPrefixHandled {
        return try skipPendingMarkerPayload(pending, finalInput: finalInput)
      }
      if pending.declaredPayloadByteCount < 5 {
        pending.semanticPrefixHandled = true
        return try skipPendingMarkerPayload(pending, finalInput: finalInput)
      }
      guard retainedTransportByteCount >= 5 else {
        if finalInput { throw ImageCraftError.unsupportedOrCorruptImage }
        return false
      }
      let isJFIF = try withAvailableTransportBytes { bytes in
        bytes[0] == 0x4A && bytes[1] == 0x46 && bytes[2] == 0x49
          && bytes[3] == 0x46 && bytes[4] == 0x00
      }
      guard isJFIF else {
        pending.semanticPrefixHandled = true
        return try skipPendingMarkerPayload(pending, finalInput: finalInput)
      }
      guard pending.wasFirstMarkerAfterSOI,
        pending.declaredPayloadByteCount >= 14
      else {
        throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
      }
      guard retainedTransportByteCount >= 14 else {
        if finalInput { throw ImageCraftError.unsupportedOrCorruptImage }
        return false
      }
      let qualified = try withAvailableTransportBytes { bytes in
        JPEGIndependentJFIFColorAuthority.jfifHeaderIsStructurallyQualified(
          bytes,
          header: 0..<14,
          declaredPayloadByteCount: pending.declaredPayloadByteCount
        )
      }
      guard qualified else {
        throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
      }
      sawJFIF = true
      pending.semanticPrefixHandled = true
      try consumeTransportBytes(14)
      pending.remainingPayloadBytes -= 14
      phase = pending.remainingPayloadBytes == 0 ? .markers : .markerPayload(pending)
      return true
    }

    private func processStreamingICCAPP2(
      _ original: PendingMarkerSegment,
      finalInput: Bool
    ) throws -> Bool {
      var pending = original
      if pending.semanticPrefixHandled {
        return try skipPendingMarkerPayload(pending, finalInput: finalInput)
      }
      let prefixByteCount = min(pending.declaredPayloadByteCount, 12)
      guard retainedTransportByteCount >= prefixByteCount else {
        if finalInput { throw ImageCraftError.unsupportedOrCorruptImage }
        return false
      }
      let unsupportedAuthority = try withAvailableTransportBytes { bytes in
        let payload = 0..<prefixByteCount
        return hasJPEGICCSignature(bytes, payload: payload)
          || JPEGIndependentProgressive420Decoder.jpegAPP2CarriesAuxiliaryAuthority(
            bytes,
            payload: payload
          )
      }
      if unsupportedAuthority {
        throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
      }
      pending.semanticPrefixHandled = true
      try consumeTransportBytes(prefixByteCount)
      pending.remainingPayloadBytes -= prefixByteCount
      phase = pending.remainingPayloadBytes == 0 ? .markers : .markerPayload(pending)
      return true
    }

    private func processStreamingAPP1ProbeAuthority(
      _ original: PendingMarkerSegment,
      finalInput: Bool
    ) throws -> Bool {
      var pending = original
      if pending.semanticPrefixHandled {
        return try skipPendingMarkerPayload(pending, finalInput: finalInput)
      }
      let prefixByteCount = min(pending.declaredPayloadByteCount, 35)
      guard retainedTransportByteCount >= prefixByteCount else {
        if finalInput { throw ImageCraftError.unsupportedOrCorruptImage }
        return false
      }
      let hasProbeAuthority = try withAvailableTransportBytes { bytes in
        JPEGIndependentProgressive420Decoder.jpegAPP1CarriesProbeSemanticAuthority(
          bytes,
          payload: 0..<prefixByteCount
        )
      }
      if hasProbeAuthority {
        throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
      }
      pending.semanticPrefixHandled = true
      try consumeTransportBytes(prefixByteCount)
      pending.remainingPayloadBytes -= prefixByteCount
      phase = pending.remainingPayloadBytes == 0 ? .markers : .markerPayload(pending)
      return true
    }

    private func processStreamingAdobeAPP14(
      _ original: PendingMarkerSegment,
      finalInput: Bool
    ) throws -> Bool {
      var pending = original
      if pending.semanticPrefixHandled {
        return try skipPendingMarkerPayload(pending, finalInput: finalInput)
      }
      if pending.declaredPayloadByteCount < 5 {
        pending.semanticPrefixHandled = true
        return try skipPendingMarkerPayload(pending, finalInput: finalInput)
      }
      guard retainedTransportByteCount >= 5 else {
        if finalInput { throw ImageCraftError.unsupportedOrCorruptImage }
        return false
      }
      let isAdobe = try withAvailableTransportBytes { bytes in
        bytes[0] == 0x41 && bytes[1] == 0x64 && bytes[2] == 0x6F
          && bytes[3] == 0x62 && bytes[4] == 0x65
      }
      guard isAdobe else {
        pending.semanticPrefixHandled = true
        return try skipPendingMarkerPayload(pending, finalInput: finalInput)
      }
      guard pending.declaredPayloadByteCount == 12 else {
        throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
      }
      guard retainedTransportByteCount >= 12 else {
        if finalInput { throw ImageCraftError.unsupportedOrCorruptImage }
        return false
      }
      let qualified = try withAvailableTransportBytes { bytes in
        JPEGIndependentJFIFColorAuthority.adobeAPP14IsQualifiedYCbCr(
          bytes,
          payload: 0..<12
        ) == true
      }
      guard qualified else {
        throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
      }
      pending.semanticPrefixHandled = true
      try consumeTransportBytes(12)
      pending.remainingPayloadBytes -= 12
      phase = pending.remainingPayloadBytes == 0 ? .markers : .markerPayload(pending)
      return true
    }

    private func skipPendingMarkerPayload(
      _ original: PendingMarkerSegment,
      finalInput: Bool
    ) throws -> Bool {
      var pending = original
      if pending.remainingPayloadBytes == 0 {
        phase = .markers
        return true
      }
      let available = retainedTransportByteCount
      guard available > 0 else {
        if finalInput { throw ImageCraftError.unsupportedOrCorruptImage }
        return false
      }
      let consumed = min(available, pending.remainingPayloadBytes)
      try consumeTransportBytes(consumed)
      pending.remainingPayloadBytes -= consumed
      phase = pending.remainingPayloadBytes == 0 ? .markers : .markerPayload(pending)
      return true
    }

    private func processSegment(
      marker: UInt8,
      bytes: UnsafeBufferPointer<UInt8>,
      segment: Segment
    ) throws {
      switch marker {
      case 0xE0:
        if let qualified = JPEGIndependentJFIFColorAuthority.jfifAPP0IsStructurallyQualified(
          bytes,
          payload: segment.payload
        ) {
          guard qualified, !hasProcessedMarkerAfterSOI else {
            throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
          }
          sawJFIF = true
        }
      case 0xE1:
        if JPEGIndependentProgressive420Decoder.jpegAPP1CarriesProbeSemanticAuthority(
          bytes,
          payload: segment.payload
        ) {
          throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
        }
      case 0xE2:
        if hasJPEGICCSignature(bytes, payload: segment.payload)
          || JPEGIndependentProgressive420Decoder.jpegAPP2CarriesAuxiliaryAuthority(
            bytes,
            payload: segment.payload
          )
        {
          throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
        }
      case 0xEE:
        if JPEGIndependentJFIFColorAuthority.adobeAPP14IsQualifiedYCbCr(
          bytes,
          payload: segment.payload
        ) == false {
          throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
        }
      case 0xC2:
        try acceptFrame(bytes: bytes, segment: segment)
      case 0xC0, 0xC1, 0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF:
        throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
      case 0xDB:
        guard !quantizationLatched else {
          throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
        }
        try acceptTableSegment(marker: marker, bytes: bytes, segment: segment)
      case 0xC4:
        try acceptTableSegment(marker: marker, bytes: bytes, segment: segment)
      case 0xDD:
        guard segment.payload.count == 2 else {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
        restartIntervalMCUs = Int(bytes[segment.payload.lowerBound]) << 8
          | Int(bytes[segment.payload.lowerBound + 1])
      case 0xCC, 0xDC:
        throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
      case 0xDA:
        try beginScan(bytes: bytes, segment: segment)
      default:
        break
      }
    }

    private func hasJPEGICCSignature(
      _ bytes: UnsafeBufferPointer<UInt8>,
      payload: Range<Int>
    ) -> Bool {
      guard payload.count >= 12 else { return false }
      let start = payload.lowerBound
      return bytes[start] == 0x49
        && bytes[start + 1] == 0x43
        && bytes[start + 2] == 0x43
        && bytes[start + 3] == 0x5F
        && bytes[start + 4] == 0x50
        && bytes[start + 5] == 0x52
        && bytes[start + 6] == 0x4F
        && bytes[start + 7] == 0x46
        && bytes[start + 8] == 0x49
        && bytes[start + 9] == 0x4C
        && bytes[start + 10] == 0x45
        && bytes[start + 11] == 0x00
    }

    private func acceptFrame(
      bytes: UnsafeBufferPointer<UInt8>,
      segment: Segment
    ) throws {
      guard frame == nil, state == nil, statePlan == nil else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      let parsed = try Parser.parseFrame(bytes, segment: segment)
      guard parsed.y.id == 1,
        parsed.cb.id == 2,
        parsed.cr.id == 3,
        parsed.y.horizontalSampling == 2,
        parsed.cb.horizontalSampling == 1,
        parsed.cr.horizontalSampling == 1,
        parsed.y.verticalSampling == 2,
        parsed.cb.verticalSampling == 1,
        parsed.cr.verticalSampling == 1
      else { throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics }
      guard parsed.width <= limits.maximumDimension, parsed.height <= limits.maximumDimension else {
        throw ImageCraftError.dimensionLimitExceeded
      }
      let pixelCount = try JPEGIndependentProgressive420Decoder.multiplied(
        parsed.width,
        parsed.height
      )
      guard pixelCount <= limits.maximumPixelCount else { throw ImageCraftError.pixelLimitExceeded }
      let plan = try JPEGIndependentProgressive420StatePlan.make(
        width: parsed.width,
        height: parsed.height
      )
      let outputBytes = try JPEGIndependentProgressive420Decoder.multiplied(pixelCount, 3)
      let required = try Self.requiredOperationPeakByteCharge(
        statePlan: plan,
        outputByteCount: outputBytes,
        previewCadence: previewCadence
      )
      guard required <= maximumCodecOwnedByteCharge else {
        throw IncrementalSessionError.codecOwnedBudgetExceeded(
          requiredBytes: required,
          maximumBytes: maximumCodecOwnedByteCharge
        )
      }

      let newState = try StateArena(plan: plan)
      let newQuantizationSource = FrameQuantizationSourceState()
      try installPreFrameTables(
        into: newState,
        quantizationSource: newQuantizationSource
      )
      preFrameTables = nil
      frame = parsed
      statePlan = plan
      state = newState
      frameQuantizationTables = newQuantizationSource
      maximumObservedFrameQuantizationSourceBytes = max(
        maximumObservedFrameQuantizationSourceBytes,
        newQuantizationSource.maximumObservedRetainedByteCount
      )
      output = nil
      admittedOutputByteCount = outputBytes
      admittedOperationPeakByteCharge = required
    }

    private func acceptTableSegment(
      marker: UInt8,
      bytes: UnsafeBufferPointer<UInt8>,
      segment: Segment
    ) throws {
      switch marker {
      case 0xDB:
        let installer: any JPEGQuantizationTableInstalling
        if let frameQuantizationTables {
          installer = frameQuantizationTables
        } else if let preFrameTables {
          installer = preFrameTables
        } else {
          throw IncrementalSessionError.sessionTerminal
        }
        try Parser.parseQuantizationTables(bytes, segment: segment, state: installer)
        if let preFrameTables {
          maximumObservedPreFrameTableBytes = max(
            maximumObservedPreFrameTableBytes,
            preFrameTables.maximumObservedRetainedByteCount
          )
        }
        if let frameQuantizationTables {
          maximumObservedFrameQuantizationSourceBytes = max(
            maximumObservedFrameQuantizationSourceBytes,
            frameQuantizationTables.maximumObservedRetainedByteCount
          )
        }
      case 0xC4:
        let installer: any JPEGHuffmanTableInstalling
        if let state {
          installer = state
        } else if let preFrameTables {
          installer = preFrameTables
        } else {
          throw IncrementalSessionError.sessionTerminal
        }
        try Parser.parseHuffmanTables(bytes, segment: segment, state: installer)
        if let preFrameTables {
          maximumObservedPreFrameTableBytes = max(
            maximumObservedPreFrameTableBytes,
            preFrameTables.maximumObservedRetainedByteCount
          )
        }
      default:
        throw ImageCraftError.unsupportedOrCorruptImage
      }
    }

    private func installPreFrameTables(
      into state: StateArena,
      quantizationSource: FrameQuantizationSourceState
    ) throws {
      guard let preFrameTables else { throw IncrementalSessionError.sessionTerminal }

      try preFrameTables.transferQuantizationTables(to: quantizationSource)
      for slot in 0..<8 {
        if let table = preFrameTables.huffmanTable(slot) {
          try state.installHuffmanTable(
            tableClass: slot / 4,
            tableIndex: slot % 4,
            counts: table.counts,
            symbols: table.symbols
          )
        }
      }
    }

    private func beginScan(
      bytes: UnsafeBufferPointer<UInt8>,
      segment: Segment
    ) throws {
      guard sawJFIF,
        let frame,
        let plan = statePlan,
        let state
      else { throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics }
      if !quantizationLatched {
        guard let frameQuantizationTables else {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
        for componentIndex in 0..<3 {
          let tableIndex = try frame.component(at: componentIndex).quantizationTableIndex
          try state.bindQuantization(
            component: componentIndex,
            values: try frameQuantizationTables.values(tableIndex: tableIndex)
          )
        }
        self.frameQuantizationTables = nil
        quantizationLatched = true
      }
      let nextScanCount = startedScanCount + 1
      guard nextScanCount <= EncodedImageSecurityInspector.maximumJPEGScanCount else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      let scan = try Parser.parseScan(bytes, segment: segment, frame: frame)
      var parser = Parser(bytes: bytes, plan: plan)
      parser.restartIntervalMCUs = restartIntervalMCUs
      try parser.validateProgression(scan, state: state)
      let runtime = try parser.makeScanRuntime(scan)
      startedScanCount = nextScanCount
      phase = .entropy(scan: scan, runtime: runtime)
    }

    private func processEntropyMCU(
      scan: ScanHeader,
      runtime: inout ProgressiveScanRuntime,
      finalInput _: Bool
    ) throws -> TransactionalMCUResult {
      guard let frame,
        let plan = statePlan,
        let state
      else { throw ImageCraftError.unsupportedOrCorruptImage }
      return try withUnsafeTemporaryAllocation(
        of: Int16.self,
        capacity: Self.maximumRollbackBlockCount * 64
      ) { rollbackCoefficients in
        try withAvailableTransportBytes { bytes in
          var parser = Parser(bytes: bytes, plan: plan)
          parser.restartIntervalMCUs = restartIntervalMCUs
          return try parser.transactionallyDecodeNextMCU(
            scan,
            frame: frame,
            state: state,
            runtime: &runtime,
            rollbackCoefficients: rollbackCoefficients
          )
        }
      }
    }

    private func finishCompletedScan(
      scan: ScanHeader,
      runtime: inout ProgressiveScanRuntime
    ) throws {
      guard let plan = statePlan, let state else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      try withAvailableTransportBytes { bytes in
        var parser = Parser(bytes: bytes, plan: plan)
        parser.restartIntervalMCUs = restartIntervalMCUs
        try parser.finishStreamingScan(runtime: &runtime)
        try parser.updateProgression(scan, state: state)
      }
    }

    private func renderCurrentCoefficients() throws {
      guard let state, let admittedOutputByteCount else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      if output == nil {
        output = Data(count: admittedOutputByteCount)
      }
      let renderer = JPEGIndependentProgressive420Decoder(
        maximumOperationByteCharge: maximumCodecOwnedByteCharge,
        maximumMetadataBytes: limits.maximumMetadataBytes
      )
      try output!.withUnsafeMutableBytes { rawOutput in
        try renderer.render(
          state: state,
          destination: rawOutput.bindMemory(to: UInt8.self),
          blockSmoothing: false
        )
      }
    }

    private func materializeFinalSamplePlanesAndReleaseState() throws -> FinalSamplePlanes {
      guard let liveState = state, let plan = statePlan else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }

      finalHuffmanTableBytesBeforeCompaction = liveState.retainedHuffmanTableByteCount
      maximumObservedHuffmanTableBytes = max(
        maximumObservedHuffmanTableBytes,
        liveState.maximumObservedHuffmanTableByteCount
      )

      // EOI and same-window trailing-byte checks have already completed. No future codec action can
      // consume encoded transport, so release that backing before allocating final spatial samples.
      transportBuffer = nil
      preFrameTables = nil
      frameQuantizationTables = nil
      transportStart = 0
      transportEnd = 0

      var planes = try FinalSamplePlanes(plan: plan)
      try planes.withMutablePlanes { y, cb, cr in
        try withUnsafeTemporaryAllocation(of: Int32.self, capacity: 64) { workspace in
          try withUnsafeTemporaryAllocation(of: UInt16.self, capacity: 64) { quantization in
            try materializeFinalComponent(
              component: 0,
              state: liveState,
              destination: y,
              logicalWidth: plan.width,
              logicalHeight: plan.height,
              widthBlocks: plan.yActualWidthBlocks,
              heightBlocks: plan.yActualHeightBlocks,
              workspace: workspace,
              quantizationScratch: quantization
            )
            try materializeFinalComponent(
              component: 1,
              state: liveState,
              destination: cb,
              logicalWidth: plan.chromaWidth,
              logicalHeight: plan.chromaHeight,
              widthBlocks: plan.chromaWidthBlocks,
              heightBlocks: plan.chromaHeightBlocks,
              workspace: workspace,
              quantizationScratch: quantization
            )
            try materializeFinalComponent(
              component: 2,
              state: liveState,
              destination: cr,
              logicalWidth: plan.chromaWidth,
              logicalHeight: plan.chromaHeight,
              widthBlocks: plan.chromaWidthBlocks,
              heightBlocks: plan.chromaHeightBlocks,
              workspace: workspace,
              quantizationScratch: quantization
            )
          }
        }
      }

      // The caller allocates RGB only after this helper returns. `liveState` therefore cannot keep
      // the coefficient/control arena alive into the sample+RGB phase through a local strong owner.
      state = nil
      frame = nil
      return planes
    }

    private func materializeFinalComponent(
      component: Int,
      state: StateArena,
      destination: UnsafeMutableBufferPointer<UInt8>,
      logicalWidth: Int,
      logicalHeight: Int,
      widthBlocks: Int,
      heightBlocks: Int,
      workspace: UnsafeMutableBufferPointer<Int32>,
      quantizationScratch: UnsafeMutableBufferPointer<UInt16>
    ) throws {
      guard logicalWidth > 0, logicalHeight > 0,
        destination.count == logicalWidth * logicalHeight
      else { throw ImageCraftError.unsupportedOrCorruptImage }
      for blockY in 0..<heightBlocks {
        for blockX in 0..<widthBlocks {
          try state.renderBlock(
            component: component,
            blockX: blockX,
            blockY: blockY,
            target: destination,
            targetRowStride: logicalWidth,
            targetX: blockX * 8,
            targetY: blockY * 8,
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            blockSmoothing: false,
            workspace: workspace,
            smoothingScratch: nil,
            quantizationScratch: quantizationScratch
          )
        }
      }
    }

    private func renderFinalSamplePlanes(_ planes: FinalSamplePlanes) throws {
      guard let plan = statePlan, plan == planes.plan,
        let admittedOutputByteCount,
        output == nil
      else { throw ImageCraftError.unsupportedOrCorruptImage }

      var finalOutput = Data(count: admittedOutputByteCount)
      try planes.withPlanes { y, cb, cr in
        try finalOutput.withUnsafeMutableBytes { rawOutput in
          let destination = rawOutput.bindMemory(to: UInt8.self)
          guard let yBase = y.baseAddress,
            let cbBase = cb.baseAddress,
            let crBase = cr.baseAddress,
            let destinationBase = destination.baseAddress
          else { throw ImageCraftError.unsupportedOrCorruptImage }
          let rowBytes = try JPEGIndependentProgressive420Decoder.multiplied(plan.width, 3)
          for outputRow in 0..<plan.height {
            let yOffset = try JPEGIndependentProgressive420Decoder.multiplied(
              outputRow,
              plan.width
            )
            let sourceRow = outputRow / 2
            guard sourceRow >= 0, sourceRow < plan.chromaHeight else {
              throw ImageCraftError.unsupportedOrCorruptImage
            }
            let chromaOffset = try JPEGIndependentProgressive420Decoder.multiplied(
              sourceRow,
              plan.chromaWidth
            )
            let adjacentRow: Int
            if !plan.usesFancyGlobalContext {
              adjacentRow = sourceRow
            } else if outputRow & 1 == 0 {
              adjacentRow = max(0, sourceRow - 1)
            } else {
              adjacentRow = min(plan.chromaHeight - 1, sourceRow + 1)
            }
            let adjacentOffset = try JPEGIndependentProgressive420Decoder.multiplied(
              adjacentRow,
              plan.chromaWidth
            )
            let outputOffset = try JPEGIndependentProgressive420Decoder.multiplied(
              outputRow,
              rowBytes
            )
            guard yOffset + plan.width <= y.count,
              chromaOffset + plan.chromaWidth <= cb.count,
              chromaOffset + plan.chromaWidth <= cr.count,
              adjacentOffset + plan.chromaWidth <= cb.count,
              adjacentOffset + plan.chromaWidth <= cr.count,
              outputOffset + rowBytes <= destination.count
            else { throw ImageCraftError.unsupportedOrCorruptImage }
            try JPEGYCbCrToRGB.writeCenteredH2V2RGBRow(
              y: UnsafeBufferPointer(
                start: yBase.advanced(by: yOffset),
                count: plan.width
              ),
              currentCb: UnsafeBufferPointer(
                start: cbBase.advanced(by: chromaOffset),
                count: plan.chromaWidth
              ),
              adjacentCb: UnsafeBufferPointer(
                start: cbBase.advanced(by: adjacentOffset),
                count: plan.chromaWidth
              ),
              currentCr: UnsafeBufferPointer(
                start: crBase.advanced(by: chromaOffset),
                count: plan.chromaWidth
              ),
              adjacentCr: UnsafeBufferPointer(
                start: crBase.advanced(by: adjacentOffset),
                count: plan.chromaWidth
              ),
              destination: UnsafeMutableBufferPointer(
                start: destinationBase.advanced(by: outputOffset),
                count: rowBytes
              ),
              writeWidth: plan.width,
              usesFancyGlobalContext: plan.usesFancyGlobalContext
            )
          }
        }
      }
      output = finalOutput
    }

    private func validateFinalProgressionAndEOI() throws {
      guard frame != nil,
        let state,
        quantizationLatched,
        startedScanCount > 0,
        startedScanCount == completedScanCount
      else { throw ImageCraftError.unsupportedOrCorruptImage }
      for component in 0..<3 {
        guard state.progressionValue(component: component, index: 0) == 0 else {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
        for index in 1..<64
        where state.progressionValue(component: component, index: index) >= 0 {
          guard state.progressionValue(component: component, index: index) == 0 else {
            throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
          }
        }
      }
    }

    /// After EOI and progression are validated, entropy state can never become live again. Keep the
    /// final RGB value plus immutable final facts, and release all transport/coefficient/table state
    /// before the caller invokes `finish()`.
    ///
    /// `.finalOnly` renders here but deliberately does not publish a preview generation. The RGB
    /// backing exists for final transfer, while `lastRenderedScanCount` remains nil so
    /// `withCurrentPreview` preserves its final-only contract.
    private func compactFinalReadyState() throws {
      guard case .complete = phase,
        retainedTransportByteCount == 0,
        statePlan != nil,
        completedScanCount > 0
      else { throw ImageCraftError.unsupportedOrCorruptImage }

      if state == nil {
        guard output != nil else { throw ImageCraftError.unsupportedOrCorruptImage }
        return
      }

      if previewCadence == .finalOnly {
        let finalSamples = try materializeFinalSamplePlanesAndReleaseState()
        try renderFinalSamplePlanes(finalSamples)
        return
      } else {
        guard output != nil, lastRenderedScanCount == completedScanCount else {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
      }

      if let state {
        finalHuffmanTableBytesBeforeCompaction = state.retainedHuffmanTableByteCount
        maximumObservedHuffmanTableBytes = max(
          maximumObservedHuffmanTableBytes,
          state.maximumObservedHuffmanTableByteCount
        )
      }
      state = nil
      frame = nil
      transportBuffer = nil
      preFrameTables = nil
      frameQuantizationTables = nil
      transportStart = 0
      transportEnd = 0
    }

    private func terminalizeFailure() {
      releaseCodecOwnedState()
      phase = .terminal
    }

    private var retainedTransportByteCount: Int {
      max(0, transportEnd - transportStart)
    }

    private var codecOwnedByteCharge: Int {
      var charge = 0
      if transportBuffer != nil {
        charge = Self.transportCapacityBytes
      }
      if let preFrameTables {
        charge = ImageDecodeResourceLedgerSnapshot.saturatedAdding(
          charge,
          preFrameTables.retainedByteCount
        )
      }
      if let state {
        charge = ImageDecodeResourceLedgerSnapshot.saturatedAdding(
          charge,
          state.retainedStateByteCount
        )
      }
      if let frameQuantizationTables {
        charge = ImageDecodeResourceLedgerSnapshot.saturatedAdding(
          charge,
          frameQuantizationTables.retainedByteCount
        )
      }
      charge = ImageDecodeResourceLedgerSnapshot.saturatedAdding(charge, output?.count ?? 0)
      return charge
    }

    private var isTerminal: Bool {
      if case .terminal = phase { return true }
      return false
    }

    private var publishedPhase: IncrementalSessionPhase {
      switch phase {
      case .needsSOI:
        return .awaitingHeader
      case .markers:
        return frame == nil ? .awaitingHeader : .awaitingMarker
      case .markerPayload:
        return frame == nil ? .awaitingHeader : .awaitingMarker
      case .entropy:
        return .decodingEntropy
      case .complete:
        return .complete
      case .terminal:
        return .terminal
      }
    }

    private func releaseCodecOwnedState() {
      state = nil
      output = nil
      admittedOutputByteCount = nil
      statePlan = nil
      frame = nil
      transportBuffer = nil
      preFrameTables = nil
      frameQuantizationTables = nil
      admittedOperationPeakByteCharge = nil
      transportStart = 0
      transportEnd = 0
    }
  }

  private struct OwnedHuffmanTable {
    let counts: UnsafeBufferPointer<UInt8>
    let symbols: UnsafeBufferPointer<UInt8>
    let symbolCount: Int
  }

  private struct ScanComponentHeader: Sendable {
    let componentIndex: Int
    let dcTableIndex: Int
    let acTableIndex: Int
  }

  private struct ScanHeader: Sendable {
    let componentCount: Int
    let first: ScanComponentHeader
    let second: ScanComponentHeader?
    let third: ScanComponentHeader?
    let spectralStart: Int
    let spectralEnd: Int
    let successiveHigh: Int
    let successiveLow: Int

    func component(at index: Int) throws -> ScanComponentHeader {
      switch index {
      case 0:
        return first
      case 1:
        guard let second else { throw ImageCraftError.unsupportedOrCorruptImage }
        return second
      case 2:
        guard let third else { throw ImageCraftError.unsupportedOrCorruptImage }
        return third
      default:
        throw ImageCraftError.unsupportedOrCorruptImage
      }
    }
  }

  private struct FrameComponent: Sendable {
    let id: UInt8
    let horizontalSampling: Int
    let verticalSampling: Int
    let quantizationTableIndex: Int
  }

  private struct Frame: Sendable {
    let width: Int
    let height: Int
    let y: FrameComponent
    let cb: FrameComponent
    let cr: FrameComponent

    func component(at index: Int) throws -> FrameComponent {
      switch index {
      case 0: return y
      case 1: return cb
      case 2: return cr
      default: throw ImageCraftError.unsupportedOrCorruptImage
      }
    }

    func componentIndex(forID id: UInt8) -> Int? {
      if y.id == id { return 0 }
      if cb.id == id { return 1 }
      if cr.id == id { return 2 }
      return nil
    }
  }

  private struct DCPredictors {
    var y = 0
    var cb = 0
    var cr = 0

    mutating func reset() {
      y = 0
      cb = 0
      cr = 0
    }

    subscript(component index: Int) -> Int {
      get {
        switch index {
        case 0: return y
        case 1: return cb
        case 2: return cr
        default: return 0
        }
      }
      set {
        switch index {
        case 0: y = newValue
        case 1: cb = newValue
        case 2: cr = newValue
        default: break
        }
      }
    }
  }

  private struct EntropyBitState: Equatable, Sendable {
    var currentByte: UInt8 = 0
    var bitsRemaining = 0
  }

  private enum EntropyReadError: Error {
    case needMoreInput
  }

  private struct ProgressiveScanRuntime {
    let scanMCUCount: Int
    var scanMCUIndex = 0
    var predictors = DCPredictors()
    var eobRun = 0
    var restartIndex = 0
    var entropyBitState = EntropyBitState()
  }

  private enum TransactionalMCUResult {
    case committed(consumedBytes: Int)
    case needsMoreInput
  }

  private struct Segment {
    let payload: Range<Int>
    let end: Int
  }

  private struct Parser {
    let bytes: UnsafeBufferPointer<UInt8>
    let plan: JPEGIndependentProgressive420StatePlan
    var quantizationSource: FrameQuantizationSourceState? = nil
    var offset = 2
    var frame: Frame?
    var restartIntervalMCUs = 0
    var quantizationLatched = false
    var scanCount = 0
    var sawJFIF = false
    var hasProcessedMarkerAfterSOI = false

    mutating func decodeAll(
      state: StateArena,
      scanCompleted: ((Int) throws -> Void)? = nil
    ) throws -> Int {
      guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else {
        throw ImageCraftError.formatMismatch
      }
      var sawEOI = false
      while offset < bytes.count {
        let marker = try Self.readMarker(bytes, offset: &offset)
        let isFirstMarkerAfterSOI = !hasProcessedMarkerAfterSOI
        hasProcessedMarkerAfterSOI = true
        switch marker {
        case 0xD9:
          guard frame != nil, scanCount > 0, offset == bytes.count else {
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
        case 0xE0:
          if let qualified = JPEGIndependentJFIFColorAuthority.jfifAPP0IsStructurallyQualified(
            bytes,
            payload: segment.payload
          ) {
            guard qualified, isFirstMarkerAfterSOI else {
              throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
            }
            sawJFIF = true
          }
        case 0xE1:
          if JPEGIndependentProgressive420Decoder.jpegAPP1CarriesProbeSemanticAuthority(
            bytes,
            payload: segment.payload
          ) {
            throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
          }
        case 0xE2:
          if JPEGIndependentProgressive420Decoder.jpegAPP2CarriesAuxiliaryAuthority(
            bytes,
            payload: segment.payload
          ) {
            throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
          }
        case 0xEE:
          if JPEGIndependentJFIFColorAuthority.adobeAPP14IsQualifiedYCbCr(
            bytes,
            payload: segment.payload
          ) == false {
            throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
          }
        case 0xC2:
          guard frame == nil else { throw ImageCraftError.unsupportedOrCorruptImage }
          let parsed = try Self.parseFrame(bytes, segment: segment)
          guard parsed.width == plan.width,
            parsed.height == plan.height,
            parsed.y.id == 1,
            parsed.cb.id == 2,
            parsed.cr.id == 3,
            parsed.y.horizontalSampling == 2,
            parsed.cb.horizontalSampling == 1,
            parsed.cr.horizontalSampling == 1,
            parsed.y.verticalSampling == 2,
            parsed.cb.verticalSampling == 1,
            parsed.cr.verticalSampling == 1
          else { throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics }
          frame = parsed
        case 0xC0, 0xC1, 0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF:
          throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
        case 0xDB:
          guard !quantizationLatched else {
            throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
          }
          guard let quantizationSource else {
            throw ImageCraftError.unsupportedOrCorruptImage
          }
          try Self.parseQuantizationTables(
            bytes,
            segment: segment,
            state: quantizationSource
          )
        case 0xC4:
          try Self.parseHuffmanTables(
            bytes,
            segment: segment,
            state: state
          )
        case 0xDD:
          guard segment.payload.count == 2 else { throw ImageCraftError.unsupportedOrCorruptImage }
          restartIntervalMCUs = Int(bytes[segment.payload.lowerBound]) << 8
            | Int(bytes[segment.payload.lowerBound + 1])
        case 0xCC, 0xDC:
          throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
        case 0xDA:
          guard sawJFIF, let frame else {
            throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
          }
          if !quantizationLatched {
            guard let quantizationSource else {
              throw ImageCraftError.unsupportedOrCorruptImage
            }
            for componentIndex in 0..<3 {
              let q = try frame.component(at: componentIndex).quantizationTableIndex
              try state.bindQuantization(
                component: componentIndex,
                values: try quantizationSource.values(tableIndex: q)
              )
            }
            self.quantizationSource = nil
            quantizationLatched = true
          }
          scanCount += 1
          guard scanCount <= 500 else { throw ImageCraftError.unsupportedOrCorruptImage }
          let scan = try Self.parseScan(bytes, segment: segment, frame: frame)
          try validateProgression(scan, state: state)
          let entropyEnd = try Self.nextStructuralMarkerOffset(bytes, start: segment.end)
          try decodeScan(
            scan,
            entropyStart: segment.end,
            entropyEnd: entropyEnd,
            frame: frame,
            state: state
          )
          try updateProgression(scan, state: state)
          if let scanCompleted {
            try scanCompleted(scanCount)
          }
          offset = entropyEnd
        default:
          continue
        }
      }
      guard sawEOI, quantizationLatched else { throw ImageCraftError.unsupportedOrCorruptImage }
      for component in 0..<3 {
        guard state.progressionValue(component: component, index: 0) == 0 else {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
        for index in 1..<64
        where state.progressionValue(component: component, index: index) >= 0 {
          guard state.progressionValue(component: component, index: index) == 0 else {
            throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
          }
        }
      }
      return scanCount
    }

    private mutating func decodeScan(
      _ scan: ScanHeader,
      entropyStart: Int,
      entropyEnd: Int,
      frame: Frame,
      state: StateArena
    ) throws {
      var reader = EntropyBitReader(bytes: bytes, offset: entropyStart, endOffset: entropyEnd)
      var runtime = try makeScanRuntime(scan)
      try withUnsafeTemporaryAllocation(of: Int16.self, capacity: 64) { dummyBlock in
        while runtime.scanMCUIndex < runtime.scanMCUCount {
          try decodeNextMCU(
            scan,
            frame: frame,
            state: state,
            runtime: &runtime,
            reader: &reader,
            dummyCoefficientBlock: dummyBlock
          )
        }
      }
      guard runtime.eobRun == 0 else { throw ImageCraftError.unsupportedOrCorruptImage }
      try reader.finish()
    }

    fileprivate func makeScanRuntime(_ scan: ScanHeader) throws -> ProgressiveScanRuntime {
      let interleaved = scan.componentCount > 1
      let scanMCUCount: Int
      if interleaved {
        guard scan.componentCount == 3,
          try scan.component(at: 0).componentIndex == 0,
          try scan.component(at: 1).componentIndex == 1,
          try scan.component(at: 2).componentIndex == 2,
          scan.spectralStart == 0,
          scan.spectralEnd == 0
        else { throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics }
        scanMCUCount = try JPEGIndependentProgressive420Decoder.multiplied(
          plan.mcuColumns,
          plan.mcuRows
        )
      } else {
        let only = try scan.component(at: 0)
        let geometry = componentGeometry(only.componentIndex)
        scanMCUCount = try JPEGIndependentProgressive420Decoder.multiplied(
          geometry.actualWidthBlocks,
          geometry.actualHeightBlocks
        )
      }
      return ProgressiveScanRuntime(scanMCUCount: scanMCUCount)
    }

    private func decodeNextMCU(
      _ scan: ScanHeader,
      frame: Frame,
      state: StateArena,
      runtime: inout ProgressiveScanRuntime,
      reader: inout EntropyBitReader,
      dummyCoefficientBlock: UnsafeMutableBufferPointer<Int16>?
    ) throws {
      let scanMCUIndex = runtime.scanMCUIndex
      guard scanMCUIndex >= 0, scanMCUIndex < runtime.scanMCUCount else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      if restartIntervalMCUs > 0,
        scanMCUIndex > 0,
        scanMCUIndex % restartIntervalMCUs == 0
      {
        guard runtime.eobRun == 0 else { throw ImageCraftError.unsupportedOrCorruptImage }
        try reader.finishEntropyByte()
        try reader.consumeMarker(expected: UInt8(0xD0 + (runtime.restartIndex & 7)))
        runtime.restartIndex += 1
        runtime.predictors.reset()
        runtime.eobRun = 0
      }

      if scan.componentCount > 1 {
        let mcuX = scanMCUIndex % plan.mcuColumns
        let mcuY = scanMCUIndex / plan.mcuColumns
        for componentOffset in 0..<scan.componentCount {
          let header = try scan.component(at: componentOffset)
          let component = try frame.component(at: header.componentIndex)
          for blockYInMCU in 0..<component.verticalSampling {
            for blockXInMCU in 0..<component.horizontalSampling {
              let blockX = mcuX * component.horizontalSampling + blockXInMCU
              let blockY = mcuY * component.verticalSampling + blockYInMCU
              let block: UnsafeMutableBufferPointer<Int16>
              if let persistent = try persistentCoefficientBlockIfPresent(
                state: state,
                component: header.componentIndex,
                blockX: blockX,
                blockY: blockY
              ) {
                block = persistent
              } else {
                guard let dummyCoefficientBlock,
                  dummyCoefficientBlock.count >= 64,
                  let dummyBase = dummyCoefficientBlock.baseAddress
                else { throw ImageCraftError.unsupportedOrCorruptImage }
                memset(dummyBase, 0, 64 * MemoryLayout<Int16>.stride)
                block = UnsafeMutableBufferPointer(start: dummyBase, count: 64)
              }
              try decodeProgressiveBlock(
                scan: scan,
                header: header,
                state: state,
                predictor: &runtime.predictors[component: header.componentIndex],
                eobRun: &runtime.eobRun,
                block: block,
                reader: &reader
              )
            }
          }
        }
      } else {
        let header = try scan.component(at: 0)
        let geometry = componentGeometry(header.componentIndex)
        let blockX = scanMCUIndex % geometry.actualWidthBlocks
        let blockY = scanMCUIndex / geometry.actualWidthBlocks
        let block = try state.coefficientBlock(
          component: header.componentIndex,
          blockX: blockX,
          blockY: blockY
        )
        try decodeProgressiveBlock(
          scan: scan,
          header: header,
          state: state,
          predictor: &runtime.predictors[component: header.componentIndex],
          eobRun: &runtime.eobRun,
          block: block,
          reader: &reader
        )
      }
      runtime.scanMCUIndex += 1
    }

    private func persistentCoefficientBlockIfPresent(
      state: StateArena,
      component: Int,
      blockX: Int,
      blockY: Int
    ) throws -> UnsafeMutableBufferPointer<Int16>? {
      let geometry = componentGeometry(component)
      guard blockX >= 0, blockY >= 0 else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      if blockX < geometry.actualWidthBlocks, blockY < geometry.actualHeightBlocks {
        return try state.coefficientBlock(
          component: component,
          blockX: blockX,
          blockY: blockY
        )
      }
      // Only the Y component can have syntax-level padding in the qualified 4:2:0 domain.
      // Dummy blocks still participate in interleaved DC entropy/predictor semantics, but they are
      // not image coefficients and therefore have no lifetime beyond the current MCU transaction.
      guard component == 0,
        blockX < plan.yPaddedWidthBlocks,
        blockY < plan.yPaddedHeightBlocks
      else { throw ImageCraftError.unsupportedOrCorruptImage }
      return nil
    }

    fileprivate func transactionallyDecodeNextMCU(
      _ scan: ScanHeader,
      frame: Frame,
      state: StateArena,
      runtime: inout ProgressiveScanRuntime,
      rollbackCoefficients: UnsafeMutableBufferPointer<Int16>
    ) throws -> TransactionalMCUResult {
      let runtimeBefore = runtime
      let rollbackBlockCount = try snapshotCurrentMCUCoefficients(
        scan,
        frame: frame,
        state: state,
        runtime: runtime,
        destination: rollbackCoefficients
      )
      var reader = EntropyBitReader(
        bytes: bytes,
        offset: 0,
        endOffset: bytes.count,
        state: runtime.entropyBitState,
        allowsSuspension: true
      )
      let dummyCoefficientBlock: UnsafeMutableBufferPointer<Int16>?
      let dummyOffset = rollbackBlockCount * 64
      if dummyOffset + 64 <= rollbackCoefficients.count,
        let rollbackBase = rollbackCoefficients.baseAddress
      {
        dummyCoefficientBlock = UnsafeMutableBufferPointer(
          start: rollbackBase.advanced(by: dummyOffset),
          count: 64
        )
      } else {
        dummyCoefficientBlock = nil
      }
      do {
        try decodeNextMCU(
          scan,
          frame: frame,
          state: state,
          runtime: &runtime,
          reader: &reader,
          dummyCoefficientBlock: dummyCoefficientBlock
        )
        runtime.entropyBitState = reader.state
        return .committed(consumedBytes: reader.offset)
      } catch EntropyReadError.needMoreInput {
        runtime = runtimeBefore
        try restoreCurrentMCUCoefficients(
          scan,
          frame: frame,
          state: state,
          runtime: runtime,
          source: rollbackCoefficients,
          blockCount: rollbackBlockCount
        )
        return .needsMoreInput
      } catch {
        runtime = runtimeBefore
        try restoreCurrentMCUCoefficients(
          scan,
          frame: frame,
          state: state,
          runtime: runtime,
          source: rollbackCoefficients,
          blockCount: rollbackBlockCount
        )
        throw error
      }
    }

    fileprivate func finishStreamingScan(runtime: inout ProgressiveScanRuntime) throws {
      guard runtime.scanMCUIndex == runtime.scanMCUCount, runtime.eobRun == 0 else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      var reader = EntropyBitReader(
        bytes: bytes,
        offset: 0,
        endOffset: bytes.count,
        state: runtime.entropyBitState,
        allowsSuspension: true
      )
      try reader.finishEntropyByte()
      runtime.entropyBitState = reader.state
    }

    private func snapshotCurrentMCUCoefficients(
      _ scan: ScanHeader,
      frame: Frame,
      state: StateArena,
      runtime: ProgressiveScanRuntime,
      destination: UnsafeMutableBufferPointer<Int16>
    ) throws -> Int {
      var blockCount = 0
      try forEachCurrentMCUBlock(scan, frame: frame, state: state, runtime: runtime) { block in
        let destinationOffset = blockCount * 64
        guard destinationOffset + 64 <= destination.count,
          let sourceBase = block.baseAddress,
          let destinationBase = destination.baseAddress
        else { throw ImageCraftError.unsupportedOrCorruptImage }
        memcpy(
          destinationBase.advanced(by: destinationOffset),
          sourceBase,
          64 * MemoryLayout<Int16>.stride
        )
        blockCount += 1
      }
      return blockCount
    }

    private func restoreCurrentMCUCoefficients(
      _ scan: ScanHeader,
      frame: Frame,
      state: StateArena,
      runtime: ProgressiveScanRuntime,
      source: UnsafeMutableBufferPointer<Int16>,
      blockCount expectedBlockCount: Int
    ) throws {
      var blockCount = 0
      try forEachCurrentMCUBlock(scan, frame: frame, state: state, runtime: runtime) { block in
        let sourceOffset = blockCount * 64
        guard sourceOffset + 64 <= source.count,
          let sourceBase = source.baseAddress,
          let destinationBase = block.baseAddress
        else { throw ImageCraftError.unsupportedOrCorruptImage }
        memcpy(
          destinationBase,
          sourceBase.advanced(by: sourceOffset),
          64 * MemoryLayout<Int16>.stride
        )
        blockCount += 1
      }
      guard blockCount == expectedBlockCount else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
    }

    private func forEachCurrentMCUBlock(
      _ scan: ScanHeader,
      frame: Frame,
      state: StateArena,
      runtime: ProgressiveScanRuntime,
      body: (UnsafeMutableBufferPointer<Int16>) throws -> Void
    ) throws {
      let scanMCUIndex = runtime.scanMCUIndex
      guard scanMCUIndex >= 0, scanMCUIndex < runtime.scanMCUCount else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      if scan.componentCount > 1 {
        let mcuX = scanMCUIndex % plan.mcuColumns
        let mcuY = scanMCUIndex / plan.mcuColumns
        for componentOffset in 0..<scan.componentCount {
          let header = try scan.component(at: componentOffset)
          let component = try frame.component(at: header.componentIndex)
          for blockYInMCU in 0..<component.verticalSampling {
            for blockXInMCU in 0..<component.horizontalSampling {
              let blockX = mcuX * component.horizontalSampling + blockXInMCU
              let blockY = mcuY * component.verticalSampling + blockYInMCU
              if let block = try persistentCoefficientBlockIfPresent(
                state: state,
                component: header.componentIndex,
                blockX: blockX,
                blockY: blockY
              ) {
                try body(block)
              }
            }
          }
        }
      } else {
        let header = try scan.component(at: 0)
        let geometry = componentGeometry(header.componentIndex)
        try body(
          state.coefficientBlock(
            component: header.componentIndex,
            blockX: scanMCUIndex % geometry.actualWidthBlocks,
            blockY: scanMCUIndex / geometry.actualWidthBlocks
          )
        )
      }
    }

    private func componentGeometry(_ index: Int) -> (
      actualWidthBlocks: Int,
      actualHeightBlocks: Int
    ) {
      if index == 0 {
        return (plan.yActualWidthBlocks, plan.yActualHeightBlocks)
      }
      return (plan.chromaWidthBlocks, plan.chromaHeightBlocks)
    }

    private func decodeProgressiveBlock(
      scan: ScanHeader,
      header: ScanComponentHeader,
      state: StateArena,
      predictor: inout Int,
      eobRun: inout Int,
      block: UnsafeMutableBufferPointer<Int16>,
      reader: inout EntropyBitReader
    ) throws {
      if scan.spectralStart == 0 {
        if scan.successiveHigh == 0 {
          guard let table = state.huffmanTable(
            tableClass: 0,
            tableIndex: header.dcTableIndex
          ) else {
            throw ImageCraftError.unsupportedOrCorruptImage
          }
          try decodeDCFirst(
            table: table,
            successiveLow: scan.successiveLow,
            predictor: &predictor,
            block: block,
            reader: &reader
          )
        } else {
          try decodeDCRefine(successiveLow: scan.successiveLow, block: block, reader: &reader)
        }
      } else {
        guard scan.componentCount == 1,
          let table = state.huffmanTable(tableClass: 1, tableIndex: header.acTableIndex)
        else { throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics }
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

    private func decodeDCFirst(
      table: OwnedHuffmanTable,
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
      table: OwnedHuffmanTable,
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
          if zeroRun > 0 { eobRun += Int(try reader.readBits(zeroRun)) }
          eobRun -= 1
          break
        }
        guard bitCount <= 10 else { throw ImageCraftError.unsupportedOrCorruptImage }
        zigzag += zeroRun
        guard zigzag <= scan.spectralEnd else { throw ImageCraftError.unsupportedOrCorruptImage }
        let value = try receiveExtend(bitCount: bitCount, reader: &reader)
        let shifted = value.multipliedReportingOverflow(by: 1 << scan.successiveLow)
        guard !shifted.overflow,
          shifted.partialValue >= Int(Int16.min),
          shifted.partialValue <= Int(Int16.max)
        else { throw ImageCraftError.unsupportedOrCorruptImage }
        block[JPEGIndependentProgressive420Decoder.jpegNaturalOrder[zigzag]] =
          Int16(shifted.partialValue)
        zigzag += 1
      }
    }

    private func decodeACRefine(
      table: OwnedHuffmanTable,
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
            if zeroRun > 0 { eobRun += Int(try reader.readBits(zeroRun)) }
            break
          }
          while zigzag <= scan.spectralEnd {
            let natural = JPEGIndependentProgressive420Decoder.jpegNaturalOrder[zigzag]
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
            guard zigzag <= scan.spectralEnd else { throw ImageCraftError.unsupportedOrCorruptImage }
            block[JPEGIndependentProgressive420Decoder.jpegNaturalOrder[zigzag]] =
              Int16(newCoefficient)
          }
          if zigzag <= scan.spectralEnd { zigzag += 1 }
        }
      }
      if eobRun > 0 {
        while zigzag <= scan.spectralEnd {
          let natural = JPEGIndependentProgressive420Decoder.jpegNaturalOrder[zigzag]
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
      table: OwnedHuffmanTable,
      reader: inout EntropyBitReader
    ) throws -> UInt8 {
      var code = 0
      var firstCode = 0
      var symbolBase = 0
      for length in 1...16 {
        code = (code << 1) | Int(try reader.readBit())
        let count = Int(table.counts[length - 1])
        if count > 0, code >= firstCode, code < firstCode + count {
          let symbolIndex = symbolBase + (code - firstCode)
          guard symbolIndex >= 0, symbolIndex < table.symbolCount else {
            throw ImageCraftError.unsupportedOrCorruptImage
          }
          return table.symbols[symbolIndex]
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

    fileprivate func validateProgression(_ scan: ScanHeader, state: StateArena) throws {
      guard scan.componentCount > 0,
        (0...63).contains(scan.spectralStart),
        (0...63).contains(scan.spectralEnd),
        scan.spectralStart <= scan.spectralEnd,
        scan.successiveHigh <= 13,
        scan.successiveLow <= 13,
        (scan.successiveHigh == 0 || scan.successiveHigh == scan.successiveLow + 1),
        (scan.spectralStart != 0 || scan.spectralEnd == 0),
        (scan.componentCount == 1 || (scan.spectralStart == 0 && scan.spectralEnd == 0))
      else { throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics }
      for componentOffset in 0..<scan.componentCount {
        let header = try scan.component(at: componentOffset)
        for index in scan.spectralStart...scan.spectralEnd {
          let previous = Int(
            state.progressionValue(component: header.componentIndex, index: index)
          )
          if previous < 0 {
            guard scan.successiveHigh == 0 else {
              throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
            }
          } else {
            // Ah=0 denotes the first scan for a coefficient. Once an entry has been established,
            // only a refinement scan may touch it again; previous==0 is therefore terminal and
            // cannot legally be reopened by another first scan. Keeping that invariant explicit
            // also makes an Al=0 component immutable for later lifecycle reasoning.
            guard previous > 0, scan.successiveHigh == previous else {
              throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
            }
          }
        }
      }
    }

    fileprivate func updateProgression(_ scan: ScanHeader, state: StateArena) throws {
      for componentOffset in 0..<scan.componentCount {
        let header = try scan.component(at: componentOffset)
        for index in scan.spectralStart...scan.spectralEnd {
          state.setProgressionValue(
            component: header.componentIndex,
            index: index,
            value: scan.successiveLow
          )
        }
      }
    }

    fileprivate static func parseFrame(
      _ bytes: UnsafeBufferPointer<UInt8>,
      segment: Segment
    ) throws -> Frame {
      guard segment.payload.count == 15 else {
        throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
      }
      let start = segment.payload.lowerBound
      let precision = Int(bytes[start])
      let height = Int(bytes[start + 1]) << 8 | Int(bytes[start + 2])
      let width = Int(bytes[start + 3]) << 8 | Int(bytes[start + 4])
      guard precision == 8, width > 0, height > 0, bytes[start + 5] == 3 else {
        throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
      }
      func component(_ index: Int) throws -> FrameComponent {
        let base = start + 6 + index * 3
        let sampling = bytes[base + 1]
        let h = Int(sampling >> 4)
        let v = Int(sampling & 0x0F)
        let q = Int(bytes[base + 2])
        guard (1...4).contains(h), (1...4).contains(v), (0...3).contains(q) else {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
        return FrameComponent(
          id: bytes[base],
          horizontalSampling: h,
          verticalSampling: v,
          quantizationTableIndex: q
        )
      }
      return Frame(
        width: width,
        height: height,
        y: try component(0),
        cb: try component(1),
        cr: try component(2)
      )
    }

    fileprivate static func parseScan(
      _ bytes: UnsafeBufferPointer<UInt8>,
      segment: Segment,
      frame: Frame
    ) throws -> ScanHeader {
      guard !segment.payload.isEmpty else { throw ImageCraftError.unsupportedOrCorruptImage }
      let start = segment.payload.lowerBound
      let count = Int(bytes[start])
      guard count == 1 || count == 3,
        segment.payload.count == 1 + count * 2 + 3
      else { throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics }
      var seenMask = 0
      var cursor = start + 1
      func nextComponent() throws -> ScanComponentHeader {
        let id = bytes[cursor]
        guard let componentIndex = frame.componentIndex(forID: id) else {
          throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
        }
        let bit = 1 << componentIndex
        guard seenMask & bit == 0 else {
          throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics
        }
        seenMask |= bit
        let selectors = bytes[cursor + 1]
        let dc = Int(selectors >> 4)
        let ac = Int(selectors & 0x0F)
        guard (0...3).contains(dc), (0...3).contains(ac) else {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
        cursor += 2
        return ScanComponentHeader(
          componentIndex: componentIndex,
          dcTableIndex: dc,
          acTableIndex: ac
        )
      }
      let first = try nextComponent()
      let second = count == 3 ? try nextComponent() : nil
      let third = count == 3 ? try nextComponent() : nil
      let approximation = bytes[cursor + 2]
      return ScanHeader(
        componentCount: count,
        first: first,
        second: second,
        third: third,
        spectralStart: Int(bytes[cursor]),
        spectralEnd: Int(bytes[cursor + 1]),
        successiveHigh: Int(approximation >> 4),
        successiveLow: Int(approximation & 0x0F)
      )
    }

    fileprivate static func parseQuantizationTables(
      _ bytes: UnsafeBufferPointer<UInt8>,
      segment: Segment,
      state: any JPEGQuantizationTableInstalling
    ) throws {
      var cursor = segment.payload.lowerBound
      while cursor < segment.payload.upperBound {
        let info = bytes[cursor]
        cursor += 1
        let precision = Int(info >> 4)
        let tableIndex = Int(info & 0x0F)
        guard precision == 0, (0...3).contains(tableIndex),
          cursor + 64 <= segment.payload.upperBound,
          let base = bytes.baseAddress
        else { throw JPEGIndependentProgressive420Error.unsupportedSourceSemantics }
        let values = UnsafeBufferPointer(start: base.advanced(by: cursor), count: 64)
        try state.installQuantizationTable(
          tableIndex: tableIndex,
          values: values
        )
        cursor += 64
      }
      guard cursor == segment.payload.upperBound else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
    }

    fileprivate static func parseHuffmanTables(
      _ bytes: UnsafeBufferPointer<UInt8>,
      segment: Segment,
      state: any JPEGHuffmanTableInstalling
    ) throws {
      var cursor = segment.payload.lowerBound
      while cursor < segment.payload.upperBound {
        let info = bytes[cursor]
        cursor += 1
        let tableClass = Int(info >> 4)
        let tableIndex = Int(info & 0x0F)
        guard (0...1).contains(tableClass), (0...3).contains(tableIndex),
          cursor + 16 <= segment.payload.upperBound,
          let base = bytes.baseAddress
        else { throw ImageCraftError.unsupportedOrCorruptImage }
        let counts = UnsafeBufferPointer(start: base.advanced(by: cursor), count: 16)
        var symbolCount = 0
        for count in counts { symbolCount += Int(count) }
        cursor += 16
        guard symbolCount > 0, symbolCount <= 256,
          cursor + symbolCount <= segment.payload.upperBound
        else { throw ImageCraftError.unsupportedOrCorruptImage }
        let symbols = UnsafeBufferPointer(start: base.advanced(by: cursor), count: symbolCount)
        try validateHuffmanTree(counts)
        try state.installHuffmanTable(
          tableClass: tableClass,
          tableIndex: tableIndex,
          counts: counts,
          symbols: symbols
        )
        cursor += symbolCount
      }
      guard cursor == segment.payload.upperBound else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
    }

    private static func validateHuffmanTree(
      _ counts: UnsafeBufferPointer<UInt8>
    ) throws {
      guard counts.count == 16 else { throw ImageCraftError.unsupportedOrCorruptImage }
      var nextCode = 0
      for length in 1...16 {
        let count = Int(counts[length - 1])
        let after = nextCode.addingReportingOverflow(count)
        guard !after.overflow, after.partialValue < (1 << length) else {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
        nextCode = after.partialValue << 1
      }
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
      guard lengthOffset + 2 <= bytes.count else { throw ImageCraftError.unsupportedOrCorruptImage }
      let length = Int(bytes[lengthOffset]) << 8 | Int(bytes[lengthOffset + 1])
      guard length >= 2 else { throw ImageCraftError.unsupportedOrCorruptImage }
      let end = lengthOffset.addingReportingOverflow(length)
      guard !end.overflow, end.partialValue <= bytes.count else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      return Segment(payload: (lengthOffset + 2)..<end.partialValue, end: end.partialValue)
    }

    private static func nextStructuralMarkerOffset(
      _ bytes: UnsafeBufferPointer<UInt8>,
      start: Int
    ) throws -> Int {
      var cursor = start
      while cursor < bytes.count {
        if bytes[cursor] != 0xFF { cursor += 1; continue }
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

  private final class RenderArena {
    private let baseAddress: UnsafeMutableRawPointer
    let workspace: UnsafeMutableBufferPointer<Int32>
    let smoothingScratch: UnsafeMutableBufferPointer<Int16>
    let quantizationScratch: UnsafeMutableBufferPointer<UInt16>
    let yStrip: UnsafeMutableBufferPointer<UInt8>
    let cbStrip: UnsafeMutableBufferPointer<UInt8>
    let crStrip: UnsafeMutableBufferPointer<UInt8>
    let previousCbRow: UnsafeMutableBufferPointer<UInt8>
    let previousCrRow: UnsafeMutableBufferPointer<UInt8>

    init(plan: JPEGIndependentProgressive420StatePlan) throws {
      var pointer: UnsafeMutableRawPointer?
      let result = posix_memalign(
        &pointer,
        JPEGIndependentProgressive420StatePlan.rowAlignmentBytes,
        max(1, plan.renderScratchBytes)
      )
      guard result == 0, let pointer else {
        throw JPEGIndependentProgressive420Error.stateAllocationFailed(
          byteCount: plan.renderScratchBytes
        )
      }
      baseAddress = pointer
      memset(pointer, 0, plan.renderScratchBytes)

      var offset = 0
      workspace = UnsafeMutableBufferPointer(
        start: pointer.advanced(by: offset).assumingMemoryBound(to: Int32.self),
        count: 64
      )
      offset += 256
      smoothingScratch = UnsafeMutableBufferPointer(
        start: pointer.advanced(by: offset).assumingMemoryBound(to: Int16.self),
        count: 64
      )
      offset += 128
      quantizationScratch = UnsafeMutableBufferPointer(
        start: pointer.advanced(by: offset).assumingMemoryBound(to: UInt16.self),
        count: 64
      )
      offset += 128
      guard offset == JPEGIndependentProgressive420StatePlan.renderFixedScratchByteCount else {
        free(pointer)
        throw ImageCraftError.unsupportedOrCorruptImage
      }

      yStrip = UnsafeMutableBufferPointer(
        start: pointer.advanced(by: offset).assumingMemoryBound(to: UInt8.self),
        count: plan.yRowStrideBytes * 16
      )
      offset += plan.yRowStrideBytes * 16
      cbStrip = UnsafeMutableBufferPointer(
        start: pointer.advanced(by: offset).assumingMemoryBound(to: UInt8.self),
        count: plan.chromaRowStrideBytes * 8
      )
      offset += plan.chromaRowStrideBytes * 8
      crStrip = UnsafeMutableBufferPointer(
        start: pointer.advanced(by: offset).assumingMemoryBound(to: UInt8.self),
        count: plan.chromaRowStrideBytes * 8
      )
      offset += plan.chromaRowStrideBytes * 8
      previousCbRow = UnsafeMutableBufferPointer(
        start: pointer.advanced(by: offset).assumingMemoryBound(to: UInt8.self),
        count: plan.chromaRowStrideBytes
      )
      offset += plan.chromaRowStrideBytes
      previousCrRow = UnsafeMutableBufferPointer(
        start: pointer.advanced(by: offset).assumingMemoryBound(to: UInt8.self),
        count: plan.chromaRowStrideBytes
      )
      offset += plan.chromaRowStrideBytes
      guard offset == plan.renderScratchBytes else {
        free(pointer)
        throw ImageCraftError.unsupportedOrCorruptImage
      }
    }

    deinit { free(baseAddress) }

    func yRow(
      localRow: Int,
      plan: JPEGIndependentProgressive420StatePlan
    ) -> UnsafeBufferPointer<UInt8> {
      row(yStrip, row: localRow, stride: plan.yRowStrideBytes, count: plan.width)
    }

    func cbRow(
      localRow: Int,
      plan: JPEGIndependentProgressive420StatePlan
    ) -> UnsafeBufferPointer<UInt8> {
      row(cbStrip, row: localRow, stride: plan.chromaRowStrideBytes, count: plan.chromaWidth)
    }

    func crRow(
      localRow: Int,
      plan: JPEGIndependentProgressive420StatePlan
    ) -> UnsafeBufferPointer<UInt8> {
      row(crStrip, row: localRow, stride: plan.chromaRowStrideBytes, count: plan.chromaWidth)
    }

    func previousCbRowPrefix(
      plan: JPEGIndependentProgressive420StatePlan
    ) -> UnsafeBufferPointer<UInt8> {
      prefix(previousCbRow, count: plan.chromaWidth)
    }

    func previousCrRowPrefix(
      plan: JPEGIndependentProgressive420StatePlan
    ) -> UnsafeBufferPointer<UInt8> {
      prefix(previousCrRow, count: plan.chromaWidth)
    }

    func copyChromaRowToPrevious(
      localRow: Int,
      plan: JPEGIndependentProgressive420StatePlan
    ) throws {
      try copy(
        cbRow(localRow: localRow, plan: plan),
        to: previousCbRow,
        count: plan.chromaWidth
      )
      try copy(
        crRow(localRow: localRow, plan: plan),
        to: previousCrRow,
        count: plan.chromaWidth
      )
    }

    private func row(
      _ buffer: UnsafeMutableBufferPointer<UInt8>,
      row: Int,
      stride: Int,
      count: Int
    ) -> UnsafeBufferPointer<UInt8> {
      guard row >= 0, count > 0, count <= stride,
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

    private func copy(
      _ source: UnsafeBufferPointer<UInt8>,
      to destination: UnsafeMutableBufferPointer<UInt8>,
      count: Int
    ) throws {
      guard count > 0, count <= source.count, count <= destination.count,
        let sourceBase = source.baseAddress,
        let destinationBase = destination.baseAddress
      else { throw ImageCraftError.unsupportedOrCorruptImage }
      memcpy(destinationBase, sourceBase, count)
    }
  }

  /// Exact retained DHT payload state. Each slot is allocated only when present and resized to the
  /// current `16 counts + N symbols` payload on redefinition. The eight optional pointer fields are
  /// control identity on the Swift object, consistent with the rest of the package's exclusion of
  /// object/allocator headers from codec-owned semantic byte charge.
  private final class HuffmanTableStore: JPEGHuffmanTableInstalling {
    private var slot0: UnsafeMutableRawPointer?
    private var slot1: UnsafeMutableRawPointer?
    private var slot2: UnsafeMutableRawPointer?
    private var slot3: UnsafeMutableRawPointer?
    private var slot4: UnsafeMutableRawPointer?
    private var slot5: UnsafeMutableRawPointer?
    private var slot6: UnsafeMutableRawPointer?
    private var slot7: UnsafeMutableRawPointer?

    private(set) var retainedByteCount = 0
    private(set) var maximumObservedRetainedByteCount = 0

    deinit {
      for slot in 0..<8 {
        if let pointer = pointer(for: slot) { free(pointer) }
      }
    }

    func installHuffmanTable(
      tableClass: Int,
      tableIndex: Int,
      counts: UnsafeBufferPointer<UInt8>,
      symbols: UnsafeBufferPointer<UInt8>
    ) throws {
      guard (0...1).contains(tableClass), (0...3).contains(tableIndex),
        counts.count == 16, !symbols.isEmpty, symbols.count <= 256,
        let countsSource = counts.baseAddress,
        let symbolsSource = symbols.baseAddress
      else { throw ImageCraftError.unsupportedOrCorruptImage }
      var declaredSymbolCount = 0
      for value in counts { declaredSymbolCount += Int(value) }
      guard declaredSymbolCount == symbols.count else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }

      let slot = tableClass * 4 + tableIndex
      let byteCount = 16 + symbols.count
      let oldPointer = pointer(for: slot)
      let oldByteCount = oldPointer.map(tableByteCount) ?? 0
      let resized: UnsafeMutableRawPointer?
      if let oldPointer {
        resized = realloc(oldPointer, byteCount)
      } else {
        resized = malloc(byteCount)
      }
      guard let destination = resized else {
        throw JPEGIndependentProgressive420Error.stateAllocationFailed(byteCount: byteCount)
      }
      setPointer(destination, for: slot)
      memcpy(destination, countsSource, 16)
      memcpy(destination.advanced(by: 16), symbolsSource, symbols.count)
      retainedByteCount += byteCount - oldByteCount
      maximumObservedRetainedByteCount = max(
        maximumObservedRetainedByteCount,
        retainedByteCount
      )
    }

    func huffmanTable(tableClass: Int, tableIndex: Int) -> OwnedHuffmanTable? {
      guard (0...1).contains(tableClass), (0...3).contains(tableIndex),
        let pointer = pointer(for: tableClass * 4 + tableIndex)
      else { return nil }
      let countsBase = pointer.assumingMemoryBound(to: UInt8.self)
      var symbolCount = 0
      for index in 0..<16 { symbolCount += Int(countsBase[index]) }
      guard symbolCount > 0, symbolCount <= 256 else { return nil }
      return OwnedHuffmanTable(
        counts: UnsafeBufferPointer(start: countsBase, count: 16),
        symbols: UnsafeBufferPointer(start: countsBase.advanced(by: 16), count: symbolCount),
        symbolCount: symbolCount
      )
    }

    private func tableByteCount(_ pointer: UnsafeMutableRawPointer) -> Int {
      let counts = pointer.assumingMemoryBound(to: UInt8.self)
      var symbolCount = 0
      for index in 0..<16 { symbolCount += Int(counts[index]) }
      return 16 + symbolCount
    }

    private func pointer(for slot: Int) -> UnsafeMutableRawPointer? {
      switch slot {
      case 0: return slot0
      case 1: return slot1
      case 2: return slot2
      case 3: return slot3
      case 4: return slot4
      case 5: return slot5
      case 6: return slot6
      case 7: return slot7
      default: return nil
      }
    }

    private func setPointer(_ pointer: UnsafeMutableRawPointer?, for slot: Int) {
      switch slot {
      case 0: slot0 = pointer
      case 1: slot1 = pointer
      case 2: slot2 = pointer
      case 3: slot3 = pointer
      case 4: slot4 = pointer
      case 5: slot5 = pointer
      case 6: slot6 = pointer
      case 7: slot7 = pointer
      default: break
      }
    }
  }

  private final class StateArena: JPEGHuffmanTableInstalling {
    let plan: JPEGIndependentProgressive420StatePlan
    private let baseAddress: UnsafeMutableRawPointer
    let allCoefficients: UnsafeBufferPointer<Int16>
    private let mutableCoefficients: UnsafeMutableBufferPointer<Int16>
    private let quantizationStorage: UnsafeMutableBufferPointer<UInt8>
    private let progressionStorage: UnsafeMutableBufferPointer<UInt8>
    private let huffmanStore = HuffmanTableStore()

    init(plan: JPEGIndependentProgressive420StatePlan) throws {
      var pointer: UnsafeMutableRawPointer?
      let result = posix_memalign(
        &pointer,
        JPEGIndependentProgressive420StatePlan.rowAlignmentBytes,
        max(1, plan.persistentBaseStateBytes)
      )
      guard result == 0, let pointer else {
        throw JPEGIndependentProgressive420Error.stateAllocationFailed(
          byteCount: plan.persistentBaseStateBytes
        )
      }
      self.plan = plan
      self.baseAddress = pointer
      memset(pointer, 0, plan.persistentBaseStateBytes)

      let coefficientCount = plan.coefficientStateBytes / MemoryLayout<Int16>.stride
      let mutableCoefficients = UnsafeMutableBufferPointer(
        start: pointer.assumingMemoryBound(to: Int16.self),
        count: coefficientCount
      )
      self.mutableCoefficients = mutableCoefficients
      self.allCoefficients = UnsafeBufferPointer(mutableCoefficients)
      var offset = plan.coefficientStateBytes
      quantizationStorage = UnsafeMutableBufferPointer(
        start: pointer.advanced(by: offset).assumingMemoryBound(to: UInt8.self),
        count: 3 * 64
      )
      offset += 3 * 64
      progressionStorage = UnsafeMutableBufferPointer(
        start: pointer.advanced(by: offset).assumingMemoryBound(to: UInt8.self),
        count: JPEGIndependentProgressive420StatePlan.progressionStateByteCount
      )
      // 0xF is the unseen sentinel, so 0xFF initializes both packed entries in every byte.
      memset(
        progressionStorage.baseAddress!,
        0xFF,
        JPEGIndependentProgressive420StatePlan.progressionStateByteCount
      )
      offset += JPEGIndependentProgressive420StatePlan.progressionStateByteCount
      guard offset == plan.persistentBaseStateBytes else {
        free(pointer)
        throw ImageCraftError.unsupportedOrCorruptImage
      }
    }

    deinit { free(baseAddress) }

    var retainedStateByteCount: Int {
      plan.persistentBaseStateBytes + huffmanStore.retainedByteCount
    }

    var retainedHuffmanTableByteCount: Int { huffmanStore.retainedByteCount }
    var maximumObservedHuffmanTableByteCount: Int {
      huffmanStore.maximumObservedRetainedByteCount
    }

    func bindQuantization(
      component: Int,
      values: UnsafeBufferPointer<UInt8>
    ) throws {
      guard (0..<3).contains(component), values.count == 64 else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      let table = quantization(component: component)
      for zigzagIndex in 0..<64 {
        let value = values[zigzagIndex]
        guard value != 0 else { throw ImageCraftError.unsupportedOrCorruptImage }
        table[JPEGIndependentProgressive420Decoder.jpegNaturalOrder[zigzagIndex]] = value
      }
    }

    func quantization(component: Int) -> UnsafeMutableBufferPointer<UInt8> {
      let base = quantizationStorage.baseAddress!.advanced(by: component * 64)
      return UnsafeMutableBufferPointer(start: base, count: 64)
    }

    @inline(__always)
    func progressionValue(component: Int, index: Int) -> Int8 {
      precondition((0..<3).contains(component) && (0..<64).contains(index))
      let linearIndex = component * 64 + index
      let byte = progressionStorage[linearIndex >> 1]
      let shift = (linearIndex & 1) * 4
      let nibble = (byte >> UInt8(shift)) & 0x0F
      guard let value = JPEGIndependentProgressive420StatePlan.progressionValue(
        forNibble: nibble
      ) else {
        preconditionFailure("invalid internal progression nibble")
      }
      return value
    }

    @inline(__always)
    func setProgressionValue(component: Int, index: Int, value: Int) {
      precondition((0..<3).contains(component) && (0..<64).contains(index))
      guard let nibble = JPEGIndependentProgressive420StatePlan.progressionNibble(for: value) else {
        preconditionFailure("invalid internal progression value")
      }
      let linearIndex = component * 64 + index
      let byteIndex = linearIndex >> 1
      let shift = (linearIndex & 1) * 4
      let mask = UInt8(0x0F << shift)
      let encoded = nibble << UInt8(shift)
      progressionStorage[byteIndex] = (progressionStorage[byteIndex] & ~mask) | encoded
    }

    func installHuffmanTable(
      tableClass: Int,
      tableIndex: Int,
      counts: UnsafeBufferPointer<UInt8>,
      symbols: UnsafeBufferPointer<UInt8>
    ) throws {
      try huffmanStore.installHuffmanTable(
        tableClass: tableClass,
        tableIndex: tableIndex,
        counts: counts,
        symbols: symbols
      )
    }

    func huffmanTable(tableClass: Int, tableIndex: Int) -> OwnedHuffmanTable? {
      huffmanStore.huffmanTable(tableClass: tableClass, tableIndex: tableIndex)
    }

    var blockSmoothingIsUseful: Bool {
      for component in 0..<3 where progressionValue(component: component, index: 0) < 0 {
        return false
      }
      for component in 0..<3 {
        for zigzag in 1..<10 where progressionValue(component: component, index: zigzag) != 0 {
          return true
        }
      }
      return false
    }

    private func smoothBlock(
      component: Int,
      blockX: Int,
      blockY: Int,
      source: UnsafeBufferPointer<Int16>,
      smoothingScratch: UnsafeMutableBufferPointer<Int16>
    ) throws {
      guard source.count == 64,
        let sourceBase = source.baseAddress,
        let scratchBase = smoothingScratch.baseAddress
      else { throw ImageCraftError.unsupportedOrCorruptImage }
      memcpy(scratchBase, sourceBase, 64 * MemoryLayout<Int16>.stride)

      let geometry = actualCoefficientGeometry(component: component)
      guard blockX >= 0, blockX < geometry.widthBlocks,
        blockY >= 0, blockY < geometry.heightBlocks
      else { throw ImageCraftError.unsupportedOrCorruptImage }
      let verticalSampling = component == 0 ? 2 : 1
      let outputIMCURow = blockY / verticalSampling
      let localBlockRow = blockY - outputIMCURow * verticalSampling
      let lastIMCURow = plan.mcuRows - 1
      let blockRows: Int
      if outputIMCURow < lastIMCURow {
        blockRows = verticalSampling
      } else {
        let remainder = geometry.heightBlocks % verticalSampling
        blockRows = remainder == 0 ? verticalSampling : remainder
      }
      let imageBlockRows = blockRows * plan.mcuRows
      let imageBlockRow = outputIMCURow * blockRows + localBlockRow
      let previousBlockY = imageBlockRow > 0 ? blockY - 1 : blockY
      let previousPreviousBlockY = imageBlockRow > 1 ? blockY - 2 : previousBlockY
      let nextBlockY = imageBlockRow < imageBlockRows - 1 ? blockY + 1 : blockY
      let nextNextBlockY = imageBlockRow < imageBlockRows - 2 ? blockY + 2 : nextBlockY
      guard progressionValue(component: component, index: 0) >= 0 else { return }
      let changeDC = (1..<10).allSatisfy {
        progressionValue(component: component, index: $0) == -1
      }
      let quant = quantization(component: component)

      @inline(__always)
      func dc(_ deltaX: Int, _ deltaY: Int) throws -> Int64 {
        let x = min(max(blockX + deltaX, 0), geometry.widthBlocks - 1)
        let y: Int
        switch deltaY {
        case -2: y = previousPreviousBlockY
        case -1: y = previousBlockY
        case 0: y = blockY
        case 1: y = nextBlockY
        case 2: y = nextNextBlockY
        default: throw ImageCraftError.unsupportedOrCorruptImage
        }
        return Int64(try coefficientBlock(component: component, blockX: x, blockY: y)[0])
      }

      let dc01 = try dc(-2, -2), dc02 = try dc(-1, -2), dc03 = try dc(0, -2)
      let dc04 = try dc(1, -2), dc05 = try dc(2, -2)
      let dc06 = try dc(-2, -1), dc07 = try dc(-1, -1), dc08 = try dc(0, -1)
      let dc09 = try dc(1, -1), dc10 = try dc(2, -1)
      let dc11 = try dc(-2, 0), dc12 = try dc(-1, 0), dc13 = try dc(0, 0)
      let dc14 = try dc(1, 0), dc15 = try dc(2, 0)
      let dc16 = try dc(-2, 1), dc17 = try dc(-1, 1), dc18 = try dc(0, 1)
      let dc19 = try dc(1, 1), dc20 = try dc(2, 1)
      let dc21 = try dc(-2, 2), dc22 = try dc(-1, 2), dc23 = try dc(0, 2)
      let dc24 = try dc(1, 2), dc25 = try dc(2, 2)

      @inline(__always)
      func estimatedCoefficient(num: Int64, quantizer: Int64, al: Int) -> Int16 {
        precondition(quantizer > 0)
        let rounding = quantizer << 7
        let divisor = quantizer << 8
        var magnitude = Int((rounding + (num >= 0 ? num : -num)) / divisor)
        if al > 0 {
          magnitude = min(magnitude, (1 << al) - 1)
        }
        let signed = num >= 0 ? magnitude : -magnitude
        return Int16(clamping: signed)
      }

      let q00 = Int64(quant[0])
      func estimate(
        zigzag: Int,
        natural: Int,
        quantNatural: Int,
        numerator: Int64
      ) {
        let al = Int(progressionValue(component: component, index: zigzag))
        if al != 0, smoothingScratch[natural] == 0 {
          smoothingScratch[natural] = estimatedCoefficient(
            num: q00 * numerator,
            quantizer: Int64(quant[quantNatural]),
            al: al
          )
        }
      }

      estimate(
        zigzag: 1, natural: 1, quantNatural: 1,
        numerator: changeDC
          ? (-dc01 - dc02 + dc04 + dc05 - 3 * dc06 + 13 * dc07 - 13 * dc09
            + 3 * dc10 - 3 * dc11 + 38 * dc12 - 38 * dc14 + 3 * dc15
            - 3 * dc16 + 13 * dc17 - 13 * dc19 + 3 * dc20 - dc21 - dc22
            + dc24 + dc25)
          : (-7 * dc11 + 50 * dc12 - 50 * dc14 + 7 * dc15)
      )
      estimate(
        zigzag: 2, natural: 8, quantNatural: 8,
        numerator: changeDC
          ? (-dc01 - 3 * dc02 - 3 * dc03 - 3 * dc04 - dc05 - dc06 + 13 * dc07
            + 38 * dc08 + 13 * dc09 - dc10 + dc16 - 13 * dc17 - 38 * dc18
            - 13 * dc19 + dc20 + dc21 + 3 * dc22 + 3 * dc23 + 3 * dc24 + dc25)
          : (-7 * dc03 + 50 * dc08 - 50 * dc18 + 7 * dc23)
      )
      estimate(
        zigzag: 3, natural: 16, quantNatural: 16,
        numerator: changeDC
          ? (dc03 + 2 * dc07 + 7 * dc08 + 2 * dc09 - 5 * dc12 - 14 * dc13
            - 5 * dc14 + 2 * dc17 + 7 * dc18 + 2 * dc19 + dc23)
          : (-dc03 + 13 * dc08 - 24 * dc13 + 13 * dc18 - dc23)
      )
      estimate(
        zigzag: 4, natural: 9, quantNatural: 9,
        numerator: changeDC
          ? (-dc01 + dc05 + 9 * dc07 - 9 * dc09 - 9 * dc17 + 9 * dc19 + dc21 - dc25)
          : (dc10 + dc16 - 10 * dc17 + 10 * dc19 - dc02 - dc20 + dc22 - dc24
            + dc04 - dc06 + 10 * dc07 - 10 * dc09)
      )
      estimate(
        zigzag: 5, natural: 2, quantNatural: 2,
        numerator: changeDC
          ? (2 * dc07 - 5 * dc08 + 2 * dc09 + dc11 + 7 * dc12 - 14 * dc13
            + 7 * dc14 + dc15 + 2 * dc17 - 5 * dc18 + 2 * dc19)
          : (-dc11 + 13 * dc12 - 24 * dc13 + 13 * dc14 - dc15)
      )

      if changeDC {
        estimate(
          zigzag: 6, natural: 3, quantNatural: 3,
          numerator: dc07 - dc09 + 2 * dc12 - 2 * dc14 + dc17 - dc19
        )
        estimate(
          zigzag: 7, natural: 10, quantNatural: 10,
          numerator: dc07 - 3 * dc08 + dc09 - dc17 + 3 * dc18 - dc19
        )
        estimate(
          zigzag: 8, natural: 17, quantNatural: 17,
          numerator: dc07 - dc09 - 3 * dc12 + 3 * dc14 + dc17 - dc19
        )
        estimate(
          zigzag: 9, natural: 24, quantNatural: 24,
          numerator: dc07 + 2 * dc08 + dc09 - dc17 - 2 * dc18 - dc19
        )
        let dcNumerator =
          -2 * dc01 - 6 * dc02 - 8 * dc03 - 6 * dc04 - 2 * dc05
          - 6 * dc06 + 6 * dc07 + 42 * dc08 + 6 * dc09 - 6 * dc10
          - 8 * dc11 + 42 * dc12 + 152 * dc13 + 42 * dc14 - 8 * dc15
          - 6 * dc16 + 6 * dc17 + 42 * dc18 + 6 * dc19 - 6 * dc20
          - 2 * dc21 - 6 * dc22 - 8 * dc23 - 6 * dc24 - 2 * dc25
        smoothingScratch[0] = estimatedCoefficient(
          num: q00 * dcNumerator,
          quantizer: q00,
          al: 0
        )
      }
    }

    func coefficientBlock(
      component: Int,
      blockX: Int,
      blockY: Int
    ) throws -> UnsafeMutableBufferPointer<Int16> {
      let geometry = coefficientGeometry(component: component)
      guard blockX >= 0, blockX < geometry.widthBlocks,
        blockY >= 0, blockY < geometry.heightBlocks
      else { throw ImageCraftError.unsupportedOrCorruptImage }
      let blockIndex = try JPEGIndependentProgressive420Decoder.added(
        geometry.startBlock,
        try JPEGIndependentProgressive420Decoder.added(
          try JPEGIndependentProgressive420Decoder.multiplied(blockY, geometry.widthBlocks),
          blockX
        )
      )
      let coefficientIndex = try JPEGIndependentProgressive420Decoder.multiplied(blockIndex, 64)
      guard let base = mutableCoefficients.baseAddress,
        coefficientIndex >= 0,
        coefficientIndex + 64 <= mutableCoefficients.count
      else { throw ImageCraftError.unsupportedOrCorruptImage }
      return UnsafeMutableBufferPointer(start: base.advanced(by: coefficientIndex), count: 64)
    }

    func renderBlock(
      component: Int,
      blockX: Int,
      blockY: Int,
      target: UnsafeMutableBufferPointer<UInt8>,
      targetRowStride: Int,
      targetX: Int,
      targetY: Int,
      logicalWidth: Int,
      logicalHeight: Int,
      blockSmoothing: Bool,
      workspace: UnsafeMutableBufferPointer<Int32>,
      smoothingScratch: UnsafeMutableBufferPointer<Int16>?,
      quantizationScratch: UnsafeMutableBufferPointer<UInt16>
    ) throws {
      let writeWidth = min(8, logicalWidth - targetX)
      let writeHeight = min(8, logicalHeight - targetY)
      if writeWidth <= 0 || writeHeight <= 0 { return }
      let offset = try JPEGIndependentProgressive420Decoder.added(
        try JPEGIndependentProgressive420Decoder.multiplied(targetY, targetRowStride),
        targetX
      )
      guard let targetBase = target.baseAddress,
        offset >= 0,
        offset < target.count
      else { throw ImageCraftError.unsupportedOrCorruptImage }
      let block = try coefficientBlock(component: component, blockX: blockX, blockY: blockY)
      let idctCoefficients: UnsafeBufferPointer<Int16>
      if blockSmoothing, blockSmoothingIsUseful {
        guard let smoothingScratch else { throw ImageCraftError.unsupportedOrCorruptImage }
        try smoothBlock(
          component: component,
          blockX: blockX,
          blockY: blockY,
          source: UnsafeBufferPointer(block),
          smoothingScratch: smoothingScratch
        )
        idctCoefficients = UnsafeBufferPointer(smoothingScratch)
      } else {
        idctCoefficients = UnsafeBufferPointer(block)
      }
      let persistentQuantization = quantization(component: component)
      guard persistentQuantization.count == 64, quantizationScratch.count == 64 else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      for index in 0..<64 {
        quantizationScratch[index] = UInt16(persistentQuantization[index])
      }
      let targetSlice = UnsafeMutableBufferPointer(
        start: targetBase.advanced(by: offset),
        count: target.count - offset
      )
      try JPEGISlowIDCT.writeBlockClipped(
        coefficients: idctCoefficients,
        quantization: UnsafeBufferPointer(quantizationScratch),
        workspace: workspace,
        destination: targetSlice,
        destinationRowStride: targetRowStride,
        writeWidth: writeWidth,
        writeHeight: writeHeight
      )
    }

    private func coefficientGeometry(component: Int) -> (
      startBlock: Int,
      widthBlocks: Int,
      heightBlocks: Int
    ) {
      let yBlocks = plan.yActualWidthBlocks * plan.yActualHeightBlocks
      let chromaBlocks = plan.chromaWidthBlocks * plan.chromaHeightBlocks
      switch component {
      case 0:
        return (0, plan.yActualWidthBlocks, plan.yActualHeightBlocks)
      case 1:
        return (yBlocks, plan.chromaWidthBlocks, plan.chromaHeightBlocks)
      case 2:
        return (yBlocks + chromaBlocks, plan.chromaWidthBlocks, plan.chromaHeightBlocks)
      default:
        return (-1, 0, 0)
      }
    }

    private func actualCoefficientGeometry(component: Int) -> (
      widthBlocks: Int,
      heightBlocks: Int
    ) {
      switch component {
      case 0:
        return (plan.yActualWidthBlocks, plan.yActualHeightBlocks)
      case 1, 2:
        return (plan.chromaWidthBlocks, plan.chromaHeightBlocks)
      default:
        return (0, 0)
      }
    }

  }

  private struct EntropyBitReader {
    let bytes: UnsafeBufferPointer<UInt8>
    var offset: Int
    let endOffset: Int
    let allowsSuspension: Bool
    private(set) var state: EntropyBitState

    init(
      bytes: UnsafeBufferPointer<UInt8>,
      offset: Int,
      endOffset: Int,
      state: EntropyBitState = EntropyBitState(),
      allowsSuspension: Bool = false
    ) {
      self.bytes = bytes
      self.offset = offset
      self.endOffset = endOffset
      self.state = state
      self.allowsSuspension = allowsSuspension
    }

    mutating func readBit() throws -> UInt8 {
      if state.bitsRemaining == 0 {
        state.currentByte = try readEntropyByte()
        state.bitsRemaining = 8
      }
      state.bitsRemaining -= 1
      return (state.currentByte >> state.bitsRemaining) & 1
    }

    mutating func readBits(_ count: Int) throws -> UInt32 {
      guard (0...16).contains(count) else { throw ImageCraftError.unsupportedOrCorruptImage }
      var value: UInt32 = 0
      for _ in 0..<count { value = (value << 1) | UInt32(try readBit()) }
      return value
    }

    mutating func finishEntropyByte() throws {
      if state.bitsRemaining > 0 {
        let mask = UInt8((1 << state.bitsRemaining) - 1)
        guard state.currentByte & mask == mask else {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
      }
      state.currentByte = 0
      state.bitsRemaining = 0
    }

    mutating func consumeMarker(expected: UInt8) throws {
      guard state.bitsRemaining == 0 else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      guard offset < endOffset else { throw inputExhaustedError() }
      guard bytes[offset] == 0xFF else { throw ImageCraftError.unsupportedOrCorruptImage }
      while offset < endOffset, bytes[offset] == 0xFF { offset += 1 }
      guard offset < endOffset else { throw inputExhaustedError() }
      guard bytes[offset] == expected else { throw ImageCraftError.unsupportedOrCorruptImage }
      offset += 1
    }

    mutating func finish() throws {
      try finishEntropyByte()
      guard offset == endOffset else { throw ImageCraftError.unsupportedOrCorruptImage }
    }

    private mutating func readEntropyByte() throws -> UInt8 {
      guard offset < endOffset else { throw inputExhaustedError() }
      let value = bytes[offset]
      offset += 1
      if value != 0xFF { return value }
      guard offset < endOffset else { throw inputExhaustedError() }
      // Within entropy-coded data, an FF data byte is represented by exactly FF 00. Duplicate FF
      // bytes are legal only as marker fill; accepting FF FF ... 00 here would admit a non-standard
      // unbounded run into one MCU transaction and blur the transport/resource boundary.
      guard bytes[offset] == 0x00 else { throw ImageCraftError.unsupportedOrCorruptImage }
      offset += 1
      return 0xFF
    }

    private func inputExhaustedError() -> Error {
      allowsSuspension ? EntropyReadError.needMoreInput : ImageCraftError.unsupportedOrCorruptImage
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

  private static func jpegAPP1CarriesProbeSemanticAuthority(
    _ bytes: UnsafeBufferPointer<UInt8>,
    payload: Range<Int>
  ) -> Bool {
    jpegPayload(payload, in: bytes, hasPrefix: [0x45, 0x78, 0x69, 0x66, 0x00, 0x00])
      || jpegPayload(
        payload,
        in: bytes,
        hasPrefix: Array("http://ns.adobe.com/xap/1.0/\u{0}".utf8)
      )
      || jpegPayload(
        payload,
        in: bytes,
        hasPrefix: Array("http://ns.adobe.com/xmp/extension/\u{0}".utf8)
      )
  }

  private static func jpegAPP2CarriesAuxiliaryAuthority(
    _ bytes: UnsafeBufferPointer<UInt8>,
    payload: Range<Int>
  ) -> Bool {
    jpegPayload(payload, in: bytes, hasPrefix: [0x4D, 0x50, 0x46, 0x00])
  }

  private static func jpegPayload(
    _ payload: Range<Int>,
    in bytes: UnsafeBufferPointer<UInt8>,
    hasPrefix prefix: [UInt8]
  ) -> Bool {
    guard payload.count >= prefix.count else { return false }
    let start = payload.lowerBound
    for index in prefix.indices where bytes[start + index] != prefix[index] {
      return false
    }
    return true
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
