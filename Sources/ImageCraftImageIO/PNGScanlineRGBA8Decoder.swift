import Foundation

enum PNGScanlineRGBA8Error: Error, Equatable, Sendable {
  case decodedByteCountMismatch
  case invalidFilter
  case invalidPaletteIndex
}

/// Shared PNG filter/row decoder for the qualified static PNG source domain. Filtering operates on
/// encoded row bytes with PNG's byte-based `bpp`; indexed 1/2/4-bit samples are unpacked MSB-first
/// only after unfiltering. Published bytes are always tight premultiplied RGBA8 in PNG file row order
/// (top logical row first). Container parsing and resource policy stay with the calling backend.
enum PNGScanlineRGBA8Decoder {
  struct TransparentRGB8: Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
  }

  struct IndexedPaletteView {
    let rgbBase: UnsafePointer<UInt8>
    let entryCount: Int
    let alphaBase: UnsafePointer<UInt8>?
    let alphaCount: Int
  }

  /// Persistent non-interlaced RGBA8 row state for input-suspendable PNG decoding. Arbitrary
  /// inflater slices are consumed directly into two straight-alpha rows and immediately
  /// premultiplied into the final tight RGBA8 backing; the complete filtered scanline stream is
  /// never retained.
  package final class IncrementalRGBA8Session {
    package let expectedInflatedByteCount: Int
    package let outputByteCount: Int
    package let retainedRowStateByteCount: Int
    package private(set) var consumedInflatedByteCount = 0
    package private(set) var completedRowCount = 0

    private let height: Int
    private let rowBytes: Int
    private let rowStorage: UnsafeMutablePointer<UInt8>
    private var previous: UnsafeMutablePointer<UInt8>
    private var current: UnsafeMutablePointer<UInt8>
    private var output: Data
    private var positionInFilteredRow = 0
    private var filter = UInt8(0)
    private var terminal = false

    package init(width: Int, height: Int) throws {
      let counts = try PNGScanlineRGBA8Decoder.expectedByteCounts(
        width: width,
        height: height,
        sourceBytesPerPixel: 4
      )
      let rowBytesResult = width.multipliedReportingOverflow(by: 4)
      guard !rowBytesResult.overflow, rowBytesResult.partialValue > 0 else {
        throw PNGScanlineRGBA8Error.decodedByteCountMismatch
      }
      let rowState = rowBytesResult.partialValue.multipliedReportingOverflow(by: 2)
      guard !rowState.overflow else {
        throw PNGScanlineRGBA8Error.decodedByteCountMismatch
      }

      self.height = height
      rowBytes = rowBytesResult.partialValue
      expectedInflatedByteCount = counts.inflated
      outputByteCount = counts.raw
      retainedRowStateByteCount = rowState.partialValue
      rowStorage = UnsafeMutablePointer<UInt8>.allocate(capacity: rowState.partialValue)
      memset(rowStorage, 0, rowState.partialValue)
      previous = rowStorage
      current = rowStorage.advanced(by: rowBytesResult.partialValue)
      output = Data(count: counts.raw)
    }

    deinit {
      rowStorage.deallocate()
    }

    package func consume(_ bytes: UnsafeBufferPointer<UInt8>) throws {
      guard !terminal else { throw PNGScanlineRGBA8Error.decodedByteCountMismatch }
      if bytes.isEmpty { return }
      let total = consumedInflatedByteCount.addingReportingOverflow(bytes.count)
      guard !total.overflow, total.partialValue <= expectedInflatedByteCount else {
        terminal = true
        throw PNGScanlineRGBA8Error.decodedByteCountMismatch
      }

      do {
        try output.withUnsafeMutableBytes { outputRaw in
          let destination = outputRaw.bindMemory(to: UInt8.self)
          var inputOffset = 0
          while inputOffset < bytes.count {
            guard completedRowCount < height else {
              throw PNGScanlineRGBA8Error.decodedByteCountMismatch
            }
            if positionInFilteredRow == 0 {
              filter = bytes[inputOffset]
              guard filter <= 4 else { throw PNGScanlineRGBA8Error.invalidFilter }
              inputOffset += 1
              positionInFilteredRow = 1
              if inputOffset == bytes.count { continue }
            }

            let column = positionInFilteredRow - 1
            guard column < rowBytes else {
              throw PNGScanlineRGBA8Error.decodedByteCountMismatch
            }
            let copyCount = min(rowBytes - column, bytes.count - inputOffset)
            guard copyCount > 0, let inputBase = bytes.baseAddress else {
              throw PNGScanlineRGBA8Error.decodedByteCountMismatch
            }
            memcpy(
              current.advanced(by: column),
              inputBase.advanced(by: inputOffset),
              copyCount
            )
            inputOffset += copyCount
            positionInFilteredRow += copyCount

            if positionInFilteredRow == rowBytes + 1 {
              try PNGScanlineRGBA8Decoder.unfilterCurrentRowInPlace(
                current,
                previous: UnsafePointer(previous),
                count: rowBytes,
                filter: filter,
                bytesPerPixel: 4
              )
              PNGScanlineRGBA8Decoder.writePremultipliedRow(
                UnsafePointer(current),
                to: destination,
                outputRowStart: completedRowCount * rowBytes,
                rowBytes: rowBytes
              )
              swap(&previous, &current)
              completedRowCount += 1
              positionInFilteredRow = 0
            }
          }
        }
        consumedInflatedByteCount = total.partialValue
      } catch {
        terminal = true
        throw error
      }
    }

    package func finish() throws -> Data {
      guard !terminal,
        consumedInflatedByteCount == expectedInflatedByteCount,
        completedRowCount == height,
        positionInFilteredRow == 0
      else {
        terminal = true
        throw PNGScanlineRGBA8Error.decodedByteCountMismatch
      }
      terminal = true
      let result = output
      output = Data()
      return result
    }
  }

  static func expectedByteCounts(width: Int, height: Int) throws -> (inflated: Int, raw: Int) {
    try expectedByteCounts(width: width, height: height, sourceBytesPerPixel: 4)
  }

  static func expectedByteCounts(
    width: Int,
    height: Int,
    sourceBytesPerPixel: Int
  ) throws -> (inflated: Int, raw: Int) {
    guard (1...4).contains(sourceBytesPerPixel) else {
      throw PNGScanlineRGBA8Error.decodedByteCountMismatch
    }
    return try expectedByteCounts(
      width: width,
      height: height,
      sourceBitsPerPixel: sourceBytesPerPixel * 8
    )
  }

  static func expectedByteCounts(
    width: Int,
    height: Int,
    sourceBitsPerPixel: Int
  ) throws -> (inflated: Int, raw: Int) {
    guard width > 0, height > 0 else {
      throw PNGScanlineRGBA8Error.decodedByteCountMismatch
    }
    let sourceRowBytes = try sourceRowByteCount(
      width: width,
      sourceBitsPerPixel: sourceBitsPerPixel
    )
    let outputRowBytes = width.multipliedReportingOverflow(by: 4)
    guard !outputRowBytes.overflow else {
      throw PNGScanlineRGBA8Error.decodedByteCountMismatch
    }
    let filteredRowBytes = sourceRowBytes.addingReportingOverflow(1)
    let inflated = filteredRowBytes.partialValue.multipliedReportingOverflow(by: height)
    let raw = outputRowBytes.partialValue.multipliedReportingOverflow(by: height)
    guard !filteredRowBytes.overflow, !inflated.overflow, !raw.overflow else {
      throw PNGScanlineRGBA8Error.decodedByteCountMismatch
    }
    return (inflated.partialValue, raw.partialValue)
  }

  static func sourceRowByteCount(width: Int, sourceBitsPerPixel: Int) throws -> Int {
    guard width > 0, [1, 2, 4, 8, 16, 24, 32].contains(sourceBitsPerPixel) else {
      throw PNGScanlineRGBA8Error.decodedByteCountMismatch
    }
    let rowBits = width.multipliedReportingOverflow(by: sourceBitsPerPixel)
    guard !rowBits.overflow else { throw PNGScanlineRGBA8Error.decodedByteCountMismatch }
    let rounded = rowBits.partialValue.addingReportingOverflow(7)
    guard !rounded.overflow else { throw PNGScanlineRGBA8Error.decodedByteCountMismatch }
    return rounded.partialValue / 8
  }

  static func filterBytesPerPixel(sourceBitsPerPixel: Int) throws -> Int {
    guard [1, 2, 4, 8, 16, 24, 32].contains(sourceBitsPerPixel) else {
      throw PNGScanlineRGBA8Error.decodedByteCountMismatch
    }
    return max(1, (sourceBitsPerPixel + 7) / 8)
  }

  static func decode(_ inflated: Data, width: Int, height: Int) throws -> Data {
    let counts = try expectedByteCounts(width: width, height: height)
    guard inflated.count == counts.inflated else {
      throw PNGScanlineRGBA8Error.decodedByteCountMismatch
    }
    let rowBytes = width * 4
    var output = Data(count: counts.raw)
    try inflated.withUnsafeBytes { inputRaw in
      try output.withUnsafeMutableBytes { outputRaw in
        let input = inputRaw.bindMemory(to: UInt8.self)
        let decoded = outputRaw.bindMemory(to: UInt8.self)
        guard let inputBase = input.baseAddress, let decodedBase = decoded.baseAddress else {
          throw PNGScanlineRGBA8Error.decodedByteCountMismatch
        }
        var inputOffset = 0
        for row in 0..<height {
          let filter = input[inputOffset]
          inputOffset += 1
          let rowStart = row * rowBytes
          let previousStart = rowStart - rowBytes
          switch filter {
          case 0:
            memcpy(
              decodedBase.advanced(by: rowStart),
              inputBase.advanced(by: inputOffset),
              rowBytes
            )
          case 1:
            unfilterSub(
              input: input,
              inputOffset: inputOffset,
              decoded: decoded,
              rowStart: rowStart,
              rowBytes: rowBytes
            )
          case 2:
            if row == 0 {
              memcpy(
                decodedBase.advanced(by: rowStart),
                inputBase.advanced(by: inputOffset),
                rowBytes
              )
            } else {
              for column in 0..<rowBytes {
                decoded[rowStart + column] =
                  input[inputOffset + column] &+ decoded[previousStart + column]
              }
            }
          case 3:
            unfilterAverage(
              input: input,
              inputOffset: inputOffset,
              decoded: decoded,
              rowStart: rowStart,
              previousStart: row == 0 ? nil : previousStart,
              rowBytes: rowBytes
            )
          case 4:
            unfilterPaeth(
              input: input,
              inputOffset: inputOffset,
              decoded: decoded,
              rowStart: rowStart,
              previousStart: row == 0 ? nil : previousStart,
              rowBytes: rowBytes
            )
          default:
            throw PNGScanlineRGBA8Error.invalidFilter
          }
          inputOffset += rowBytes
        }
      }
    }
    return output
  }

  /// Unfilters into two bounded straight-alpha row buffers and immediately writes a premultiplied
  /// final row. This is equivalent to `premultiplyStraightAlpha(decode(...))` but avoids retaining a
  /// second full-frame straight RGBA surface alongside the published packed output.
  static func decodePremultipliedRowwise(
    _ inflated: Data,
    width: Int,
    height: Int
  ) throws -> Data {
    let counts = try expectedByteCounts(width: width, height: height)
    guard inflated.count == counts.inflated else {
      throw PNGScanlineRGBA8Error.decodedByteCountMismatch
    }
    let rowBytes = width * 4
    var previous = [UInt8](repeating: 0, count: rowBytes)
    var current = [UInt8](repeating: 0, count: rowBytes)
    var output = Data(count: counts.raw)

    try inflated.withUnsafeBytes { inputRaw in
      try output.withUnsafeMutableBytes { outputRaw in
        let input = inputRaw.bindMemory(to: UInt8.self)
        let destination = outputRaw.bindMemory(to: UInt8.self)
        var inputOffset = 0

        for row in 0..<height {
          let filter = input[inputOffset]
          inputOffset += 1
          for column in 0..<rowBytes {
            let left = column >= 4 ? current[column - 4] : 0
            let above = previous[column]
            let upperLeft = column >= 4 ? previous[column - 4] : 0
            let predictor: UInt8
            switch filter {
            case 0:
              predictor = 0
            case 1:
              predictor = left
            case 2:
              predictor = above
            case 3:
              predictor = UInt8((UInt16(left) + UInt16(above)) >> 1)
            case 4:
              predictor = paeth(left: left, above: above, upperLeft: upperLeft)
            default:
              throw PNGScanlineRGBA8Error.invalidFilter
            }
            current[column] = input[inputOffset + column] &+ predictor
          }

          let outputRowStart = row * rowBytes
          writePremultipliedRow(
            current,
            to: destination,
            outputRowStart: outputRowStart,
            rowBytes: rowBytes
          )

          swap(&previous, &current)
          inputOffset += rowBytes
        }
      }
    }
    return output
  }

  /// Streams RFC 1950 output directly into the PNG row state machine. Only the DEFLATE history,
  /// bounded inflater staging, two straight-alpha rows and the final packed output coexist; the
  /// complete filtered scanline stream is never materialized.
  static func inflateAndDecodePremultipliedRowwise(
    _ compressedZlib: Data,
    width: Int,
    height: Int,
    sourceBytesPerPixel: Int = 4,
    transparentRGB8: TransparentRGB8? = nil,
    transparentGray8: UInt8? = nil,
    indexedPalette: IndexedPaletteView? = nil
  ) throws -> Data {
    try inflateAndDecodePremultipliedRowwiseImpl(
      width: width,
      height: height,
      sourceBitsPerPixel: sourceBytesPerPixel * 8,
      indexedBitDepth: indexedPalette == nil ? nil : 8,
      grayscaleBitDepth: nil,
      transparentGraySample: nil,
      transparentRGB8: transparentRGB8,
      transparentGray8: transparentGray8,
      indexedPalette: indexedPalette
    ) {
      expectedByteCount,
      consume in
      try RFC1950BoundedInflate.inflateStreaming(
        compressedZlib,
        expectedByteCount: expectedByteCount,
        consume: consume
      )
    }
  }

  static func inflateAndDecodePremultipliedRowwise<Cursor: RFC1950StreamingByteCursor>(
    cursor: Cursor,
    width: Int,
    height: Int,
    sourceBytesPerPixel: Int = 4,
    transparentRGB8: TransparentRGB8? = nil,
    transparentGray8: UInt8? = nil,
    indexedPalette: IndexedPaletteView? = nil
  ) throws -> Data {
    try inflateAndDecodePremultipliedRowwiseImpl(
      width: width,
      height: height,
      sourceBitsPerPixel: sourceBytesPerPixel * 8,
      indexedBitDepth: indexedPalette == nil ? nil : 8,
      grayscaleBitDepth: nil,
      transparentGraySample: nil,
      transparentRGB8: transparentRGB8,
      transparentGray8: transparentGray8,
      indexedPalette: indexedPalette
    ) {
      expectedByteCount,
      consume in
      try RFC1950BoundedInflate.inflateStreaming(
        cursor: cursor,
        expectedByteCount: expectedByteCount,
        consume: consume
      )
    }
  }

  static func inflateAndDecodePremultipliedGrayscaleRowwise(
    _ compressedZlib: Data,
    width: Int,
    height: Int,
    bitDepth: Int,
    transparentSample: UInt16?
  ) throws -> Data {
    try inflateAndDecodePremultipliedRowwiseImpl(
      width: width,
      height: height,
      sourceBitsPerPixel: bitDepth,
      indexedBitDepth: nil,
      grayscaleBitDepth: bitDepth,
      transparentGraySample: transparentSample,
      transparentRGB8: nil,
      transparentGray8: nil,
      indexedPalette: nil
    ) {
      expectedByteCount,
      consume in
      try RFC1950BoundedInflate.inflateStreaming(
        compressedZlib,
        expectedByteCount: expectedByteCount,
        consume: consume
      )
    }
  }

  static func inflateAndDecodePremultipliedGrayscaleRowwise<Cursor: RFC1950StreamingByteCursor>(
    cursor: Cursor,
    width: Int,
    height: Int,
    bitDepth: Int,
    transparentSample: UInt16?
  ) throws -> Data {
    try inflateAndDecodePremultipliedRowwiseImpl(
      width: width,
      height: height,
      sourceBitsPerPixel: bitDepth,
      indexedBitDepth: nil,
      grayscaleBitDepth: bitDepth,
      transparentGraySample: transparentSample,
      transparentRGB8: nil,
      transparentGray8: nil,
      indexedPalette: nil
    ) {
      expectedByteCount,
      consume in
      try RFC1950BoundedInflate.inflateStreaming(
        cursor: cursor,
        expectedByteCount: expectedByteCount,
        consume: consume
      )
    }
  }

  static func inflateAndDecodePremultipliedIndexedRowwise(
    _ compressedZlib: Data,
    width: Int,
    height: Int,
    bitDepth: Int,
    indexedPalette: IndexedPaletteView
  ) throws -> Data {
    try inflateAndDecodePremultipliedRowwiseImpl(
      width: width,
      height: height,
      sourceBitsPerPixel: bitDepth,
      indexedBitDepth: bitDepth,
      grayscaleBitDepth: nil,
      transparentGraySample: nil,
      transparentRGB8: nil,
      transparentGray8: nil,
      indexedPalette: indexedPalette
    ) {
      expectedByteCount,
      consume in
      try RFC1950BoundedInflate.inflateStreaming(
        compressedZlib,
        expectedByteCount: expectedByteCount,
        consume: consume
      )
    }
  }

  static func inflateAndDecodePremultipliedIndexedRowwise<Cursor: RFC1950StreamingByteCursor>(
    cursor: Cursor,
    width: Int,
    height: Int,
    bitDepth: Int,
    indexedPalette: IndexedPaletteView
  ) throws -> Data {
    try inflateAndDecodePremultipliedRowwiseImpl(
      width: width,
      height: height,
      sourceBitsPerPixel: bitDepth,
      indexedBitDepth: bitDepth,
      grayscaleBitDepth: nil,
      transparentGraySample: nil,
      transparentRGB8: nil,
      transparentGray8: nil,
      indexedPalette: indexedPalette
    ) {
      expectedByteCount,
      consume in
      try RFC1950BoundedInflate.inflateStreaming(
        cursor: cursor,
        expectedByteCount: expectedByteCount,
        consume: consume
      )
    }
  }

  static func inflateAndDecodePremultipliedRGBA8Adam7(
    _ compressedZlib: Data,
    width: Int,
    height: Int
  ) throws -> Data {
    try inflateAndDecodePremultipliedRGBA8Adam7Impl(width: width, height: height) {
      expectedByteCount,
      consume in
      try RFC1950BoundedInflate.inflateStreaming(
        compressedZlib,
        expectedByteCount: expectedByteCount,
        consume: consume
      )
    }
  }

  static func inflateAndDecodePremultipliedRGBA8Adam7<Cursor: RFC1950StreamingByteCursor>(
    cursor: Cursor,
    width: Int,
    height: Int
  ) throws -> Data {
    try inflateAndDecodePremultipliedRGBA8Adam7Impl(width: width, height: height) {
      expectedByteCount,
      consume in
      try RFC1950BoundedInflate.inflateStreaming(
        cursor: cursor,
        expectedByteCount: expectedByteCount,
        consume: consume
      )
    }
  }

  private static func inflateAndDecodePremultipliedRGBA8Adam7Impl(
    width: Int,
    height: Int,
    inflate: (
      _ expectedByteCount: Int,
      _ consume: (UnsafeBufferPointer<UInt8>) throws -> Void
    ) throws -> Void
  ) throws -> Data {
    guard width > 0, height > 0 else {
      throw PNGScanlineRGBA8Error.decodedByteCountMismatch
    }
    guard let passes = PNGAdam7Geometry.passes(width: width, height: height),
      let expectedInflatedByteCount = PNGAdam7Geometry.expectedInflatedByteCount(
        passes: passes,
        bytesPerPixel: 4
      )
    else { throw PNGScanlineRGBA8Error.decodedByteCountMismatch }
    let fullRowBytes = width.multipliedReportingOverflow(by: 4)
    let outputByteCount = fullRowBytes.partialValue.multipliedReportingOverflow(by: height)
    guard !fullRowBytes.overflow, !outputByteCount.overflow else {
      throw PNGScanlineRGBA8Error.decodedByteCountMismatch
    }
    let rowStorageByteCount = fullRowBytes.partialValue.multipliedReportingOverflow(by: 2)
    guard !rowStorageByteCount.overflow else {
      throw PNGScanlineRGBA8Error.decodedByteCountMismatch
    }
    let rowStorage = UnsafeMutablePointer<UInt8>.allocate(capacity: rowStorageByteCount.partialValue)
    defer { rowStorage.deallocate() }
    memset(rowStorage, 0, rowStorageByteCount.partialValue)
    var previous = rowStorage
    var current = rowStorage.advanced(by: fullRowBytes.partialValue)
    var output = Data(count: outputByteCount.partialValue)
    var passIndex = 0
    var passRow = 0
    var positionInFilteredRow = 0
    var filter = UInt8(0)

    try output.withUnsafeMutableBytes { outputRaw in
      let destination = outputRaw.bindMemory(to: UInt8.self)
      try inflate(expectedInflatedByteCount) { bytes in
        var inputOffset = 0
        while inputOffset < bytes.count {
          guard passIndex < passes.count else {
            throw PNGScanlineRGBA8Error.decodedByteCountMismatch
          }
          let pass = passes[passIndex]
          let passRowBytes = pass.width * 4
          if positionInFilteredRow == 0 {
            filter = bytes[inputOffset]
            guard filter <= 4 else { throw PNGScanlineRGBA8Error.invalidFilter }
            inputOffset += 1
            positionInFilteredRow = 1
            if inputOffset == bytes.count { continue }
          }

          let column = positionInFilteredRow - 1
          guard column < passRowBytes else {
            throw PNGScanlineRGBA8Error.decodedByteCountMismatch
          }
          let copyCount = min(passRowBytes - column, bytes.count - inputOffset)
          guard copyCount > 0, let inputBase = bytes.baseAddress else {
            throw PNGScanlineRGBA8Error.decodedByteCountMismatch
          }
          memcpy(
            current.advanced(by: column),
            inputBase.advanced(by: inputOffset),
            copyCount
          )
          inputOffset += copyCount
          positionInFilteredRow += copyCount

          if positionInFilteredRow == passRowBytes + 1 {
            try unfilterCurrentRowInPlace(
              current,
              previous: UnsafePointer(previous),
              count: passRowBytes,
              filter: filter,
              bytesPerPixel: 4
            )
            try writePremultipliedAdam7RGBA8Row(
              UnsafePointer(current),
              to: destination,
              fullWidth: width,
              pass: pass,
              passRow: passRow
            )
            swap(&previous, &current)
            passRow += 1
            positionInFilteredRow = 0
            if passRow == pass.height {
              passIndex += 1
              passRow = 0
              if passIndex < passes.count {
                memset(previous, 0, fullRowBytes.partialValue)
              }
            }
          }
        }
      }
    }
    guard passIndex == passes.count, passRow == 0, positionInFilteredRow == 0 else {
      throw PNGScanlineRGBA8Error.decodedByteCountMismatch
    }
    return output
  }

  @inline(__always)
  private static func writePremultipliedAdam7RGBA8Row(
    _ straight: UnsafePointer<UInt8>,
    to destination: UnsafeMutableBufferPointer<UInt8>,
    fullWidth: Int,
    pass: PNGAdam7Geometry.Pass,
    passRow: Int
  ) throws {
    guard passRow >= 0, passRow < pass.height else {
      throw PNGScanlineRGBA8Error.decodedByteCountMismatch
    }
    let y = pass.yStart + passRow * pass.yStep
    var sourceOffset = 0
    for passColumn in 0..<pass.width {
      let x = pass.xStart + passColumn * pass.xStep
      let destinationOffset = (y * fullWidth + x) * 4
      guard destinationOffset >= 0, destinationOffset + 3 < destination.count else {
        throw PNGScanlineRGBA8Error.decodedByteCountMismatch
      }
      let alpha = UInt16(straight[sourceOffset + 3])
      if alpha == 0 {
        destination[destinationOffset] = 0
        destination[destinationOffset + 1] = 0
        destination[destinationOffset + 2] = 0
      } else if alpha == 255 {
        destination[destinationOffset] = straight[sourceOffset]
        destination[destinationOffset + 1] = straight[sourceOffset + 1]
        destination[destinationOffset + 2] = straight[sourceOffset + 2]
      } else {
        destination[destinationOffset] =
          UInt8((UInt16(straight[sourceOffset]) * alpha + 127) / 255)
        destination[destinationOffset + 1] =
          UInt8((UInt16(straight[sourceOffset + 1]) * alpha + 127) / 255)
        destination[destinationOffset + 2] =
          UInt8((UInt16(straight[sourceOffset + 2]) * alpha + 127) / 255)
      }
      destination[destinationOffset + 3] = straight[sourceOffset + 3]
      sourceOffset += 4
    }
  }

  private static func inflateAndDecodePremultipliedRowwiseImpl(
    width: Int,
    height: Int,
    sourceBitsPerPixel: Int,
    indexedBitDepth: Int?,
    grayscaleBitDepth: Int?,
    transparentGraySample: UInt16?,
    transparentRGB8: TransparentRGB8?,
    transparentGray8: UInt8?,
    indexedPalette: IndexedPaletteView?,
    inflate: (
      _ expectedByteCount: Int,
      _ consume: (UnsafeBufferPointer<UInt8>) throws -> Void
    ) throws -> Void
  ) throws -> Data {
    let sourceBytesPerPixel = try filterBytesPerPixel(
      sourceBitsPerPixel: sourceBitsPerPixel
    )
    if indexedPalette != nil {
      guard let indexedBitDepth,
        [1, 2, 4, 8].contains(indexedBitDepth),
        sourceBitsPerPixel == indexedBitDepth,
        sourceBytesPerPixel == 1,
        grayscaleBitDepth == nil,
        transparentGraySample == nil,
        transparentRGB8 == nil,
        transparentGray8 == nil
      else { throw PNGScanlineRGBA8Error.decodedByteCountMismatch }
    } else if let grayscaleBitDepth {
      guard [1, 2, 4].contains(grayscaleBitDepth),
        sourceBitsPerPixel == grayscaleBitDepth,
        sourceBytesPerPixel == 1,
        indexedBitDepth == nil,
        transparentRGB8 == nil,
        transparentGray8 == nil
      else { throw PNGScanlineRGBA8Error.decodedByteCountMismatch }
    } else {
      guard indexedBitDepth == nil,
        transparentGraySample == nil,
        [8, 16, 24, 32].contains(sourceBitsPerPixel)
      else { throw PNGScanlineRGBA8Error.decodedByteCountMismatch }
    }
    guard transparentRGB8 == nil || sourceBitsPerPixel == 24 else {
      throw PNGScanlineRGBA8Error.decodedByteCountMismatch
    }
    guard transparentGray8 == nil || sourceBitsPerPixel == 8 else {
      throw PNGScanlineRGBA8Error.decodedByteCountMismatch
    }
    let counts = try expectedByteCounts(
      width: width,
      height: height,
      sourceBitsPerPixel: sourceBitsPerPixel
    )
    let sourceRowBytes = try sourceRowByteCount(
      width: width,
      sourceBitsPerPixel: sourceBitsPerPixel
    )
    let outputRowBytes = width * 4
    let rowStorageByteCount = sourceRowBytes * 2
    let rowStorage = UnsafeMutablePointer<UInt8>.allocate(capacity: rowStorageByteCount)
    defer { rowStorage.deallocate() }
    memset(rowStorage, 0, rowStorageByteCount)
    var previous = rowStorage
    var current = rowStorage.advanced(by: sourceRowBytes)
    var output = Data(count: counts.raw)
    var row = 0
    var positionInFilteredRow = 0
    var filter = UInt8(0)

    try output.withUnsafeMutableBytes { outputRaw in
      let destination = outputRaw.bindMemory(to: UInt8.self)
      try inflate(counts.inflated) { bytes in
        var inputOffset = 0
        while inputOffset < bytes.count {
          guard row < height else {
            throw PNGScanlineRGBA8Error.decodedByteCountMismatch
          }
          if positionInFilteredRow == 0 {
            filter = bytes[inputOffset]
            guard filter <= 4 else { throw PNGScanlineRGBA8Error.invalidFilter }
            inputOffset += 1
            positionInFilteredRow = 1
            if inputOffset == bytes.count { continue }
          }

          let column = positionInFilteredRow - 1
          guard column < sourceRowBytes else {
            throw PNGScanlineRGBA8Error.decodedByteCountMismatch
          }
          let copyCount = min(sourceRowBytes - column, bytes.count - inputOffset)
          guard copyCount > 0, let inputBase = bytes.baseAddress else {
            throw PNGScanlineRGBA8Error.decodedByteCountMismatch
          }
          memcpy(
            current.advanced(by: column),
            inputBase.advanced(by: inputOffset),
            copyCount
          )
          inputOffset += copyCount
          positionInFilteredRow += copyCount

          if positionInFilteredRow == sourceRowBytes + 1 {
            try unfilterCurrentRowInPlace(
              current,
              previous: UnsafePointer(previous),
              count: sourceRowBytes,
              filter: filter,
              bytesPerPixel: sourceBytesPerPixel
            )
            try writePackedRow(
              UnsafePointer(current),
              to: destination,
              outputRowStart: row * outputRowBytes,
              sourceBytesPerPixel: sourceBytesPerPixel,
              width: width,
              transparentRGB8: transparentRGB8,
              transparentGray8: transparentGray8,
              indexedPalette: indexedPalette,
              indexedBitDepth: indexedBitDepth,
              grayscaleBitDepth: grayscaleBitDepth,
              transparentGraySample: transparentGraySample
            )
            swap(&previous, &current)
            row += 1
            positionInFilteredRow = 0
          }
        }
      }
    }
    guard row == height, positionInFilteredRow == 0 else {
      throw PNGScanlineRGBA8Error.decodedByteCountMismatch
    }
    return output
  }

  @inline(__always)
  static func unfilterCurrentRowInPlace(
    _ current: UnsafeMutablePointer<UInt8>,
    previous: UnsafePointer<UInt8>,
    count: Int,
    filter: UInt8,
    bytesPerPixel: Int
  ) throws {
    guard count >= 0, bytesPerPixel > 0 else {
      throw PNGScanlineRGBA8Error.decodedByteCountMismatch
    }
    guard filter <= 4 else { throw PNGScanlineRGBA8Error.invalidFilter }
    if filter == 0 { return }
    switch filter {
    case 1:
      if bytesPerPixel == 4 {
        unfilterSub4(current, count: count)
      } else if bytesPerPixel == 3 {
        unfilterSub3(current, count: count)
      } else if bytesPerPixel == 2 {
        unfilterSub2(current, count: count)
      } else if bytesPerPixel == 1 {
        unfilterSub1(current, count: count)
      } else {
        unfilterSubGeneric(current, count: count, bytesPerPixel: bytesPerPixel)
      }
    case 2:
      var column = 0
      while column < count {
        current[column] &+= previous[column]
        column += 1
      }
    case 3:
      if bytesPerPixel == 4 {
        unfilterAverage4(current, previous: previous, count: count)
      } else if bytesPerPixel == 3 {
        unfilterAverage3(current, previous: previous, count: count)
      } else if bytesPerPixel == 2 {
        unfilterAverage2(current, previous: previous, count: count)
      } else if bytesPerPixel == 1 {
        unfilterAverage1(current, previous: previous, count: count)
      } else {
        unfilterAverageGeneric(
          current,
          previous: previous,
          count: count,
          bytesPerPixel: bytesPerPixel
        )
      }
    case 4:
      if bytesPerPixel == 4 {
        unfilterPaeth4(current, previous: previous, count: count)
      } else if bytesPerPixel == 3 {
        unfilterPaeth3(current, previous: previous, count: count)
      } else if bytesPerPixel == 2 {
        unfilterPaeth2(current, previous: previous, count: count)
      } else if bytesPerPixel == 1 {
        unfilterPaeth1(current, previous: previous, count: count)
      } else {
        unfilterPaethGeneric(
          current,
          previous: previous,
          count: count,
          bytesPerPixel: bytesPerPixel
        )
      }
    default:
      break
    }
  }

  @inline(__always)
  private static func unfilterSubGeneric(
    _ row: UnsafeMutablePointer<UInt8>,
    count: Int,
    bytesPerPixel: Int
  ) {
    guard count > bytesPerPixel else { return }
    var column = bytesPerPixel
    while column < count {
      row[column] &+= row[column - bytesPerPixel]
      column += 1
    }
  }

  @inline(__always)
  private static func unfilterAverageGeneric(
    _ row: UnsafeMutablePointer<UInt8>,
    previous: UnsafePointer<UInt8>,
    count: Int,
    bytesPerPixel: Int
  ) {
    var column = 0
    while column < count {
      let left = column >= bytesPerPixel ? row[column - bytesPerPixel] : 0
      let above = previous[column]
      row[column] &+= UInt8((UInt16(left) + UInt16(above)) >> 1)
      column += 1
    }
  }

  @inline(__always)
  private static func unfilterPaethGeneric(
    _ row: UnsafeMutablePointer<UInt8>,
    previous: UnsafePointer<UInt8>,
    count: Int,
    bytesPerPixel: Int
  ) {
    var column = 0
    while column < count {
      let left = column >= bytesPerPixel ? row[column - bytesPerPixel] : 0
      let above = previous[column]
      let upperLeft = column >= bytesPerPixel ? previous[column - bytesPerPixel] : 0
      row[column] &+= paeth(left: left, above: above, upperLeft: upperLeft)
      column += 1
    }
  }

  @inline(__always)
  private static func unfilterSub1(
    _ row: UnsafeMutablePointer<UInt8>,
    count: Int
  ) {
    var left = UInt8(0)
    var column = 0
    while column < count {
      left = row[column] &+ left
      row[column] = left
      column += 1
    }
  }

  @inline(__always)
  private static func unfilterSub2(
    _ row: UnsafeMutablePointer<UInt8>,
    count: Int
  ) {
    assert(count % 2 == 0)
    var left0 = UInt8(0)
    var left1 = UInt8(0)
    var column = 0
    while column < count {
      left0 = row[column] &+ left0
      left1 = row[column + 1] &+ left1
      row[column] = left0
      row[column + 1] = left1
      column += 2
    }
  }

  @inline(__always)
  private static func unfilterSub3(
    _ row: UnsafeMutablePointer<UInt8>,
    count: Int
  ) {
    assert(count % 3 == 0)
    var left0 = UInt8(0)
    var left1 = UInt8(0)
    var left2 = UInt8(0)
    var column = 0
    while column < count {
      left0 = row[column] &+ left0
      left1 = row[column + 1] &+ left1
      left2 = row[column + 2] &+ left2
      row[column] = left0
      row[column + 1] = left1
      row[column + 2] = left2
      column += 3
    }
  }

  @inline(__always)
  private static func unfilterSub4(
    _ row: UnsafeMutablePointer<UInt8>,
    count: Int
  ) {
    assert(count % 4 == 0)
    var left0 = UInt8(0)
    var left1 = UInt8(0)
    var left2 = UInt8(0)
    var left3 = UInt8(0)
    var column = 0
    while column < count {
      left0 = row[column] &+ left0
      left1 = row[column + 1] &+ left1
      left2 = row[column + 2] &+ left2
      left3 = row[column + 3] &+ left3
      row[column] = left0
      row[column + 1] = left1
      row[column + 2] = left2
      row[column + 3] = left3
      column += 4
    }
  }

  @inline(__always)
  private static func unfilterAverage1(
    _ row: UnsafeMutablePointer<UInt8>,
    previous: UnsafePointer<UInt8>,
    count: Int
  ) {
    var left = UInt8(0)
    var column = 0
    while column < count {
      let above = previous[column]
      left = row[column] &+ UInt8((UInt16(left) + UInt16(above)) >> 1)
      row[column] = left
      column += 1
    }
  }

  @inline(__always)
  private static func unfilterAverage2(
    _ row: UnsafeMutablePointer<UInt8>,
    previous: UnsafePointer<UInt8>,
    count: Int
  ) {
    assert(count % 2 == 0)
    var left0 = UInt8(0)
    var left1 = UInt8(0)
    var column = 0
    while column < count {
      let above0 = previous[column]
      let above1 = previous[column + 1]
      left0 = row[column] &+ UInt8((UInt16(left0) + UInt16(above0)) >> 1)
      left1 = row[column + 1] &+ UInt8((UInt16(left1) + UInt16(above1)) >> 1)
      row[column] = left0
      row[column + 1] = left1
      column += 2
    }
  }

  @inline(__always)
  private static func unfilterAverage3(
    _ row: UnsafeMutablePointer<UInt8>,
    previous: UnsafePointer<UInt8>,
    count: Int
  ) {
    assert(count % 3 == 0)
    var left0 = UInt8(0)
    var left1 = UInt8(0)
    var left2 = UInt8(0)
    var column = 0
    while column < count {
      let above0 = previous[column]
      let above1 = previous[column + 1]
      let above2 = previous[column + 2]
      left0 = row[column] &+ UInt8((UInt16(left0) + UInt16(above0)) >> 1)
      left1 = row[column + 1] &+ UInt8((UInt16(left1) + UInt16(above1)) >> 1)
      left2 = row[column + 2] &+ UInt8((UInt16(left2) + UInt16(above2)) >> 1)
      row[column] = left0
      row[column + 1] = left1
      row[column + 2] = left2
      column += 3
    }
  }

  @inline(__always)
  private static func unfilterAverage4(
    _ row: UnsafeMutablePointer<UInt8>,
    previous: UnsafePointer<UInt8>,
    count: Int
  ) {
    assert(count % 4 == 0)
    var left0 = UInt8(0)
    var left1 = UInt8(0)
    var left2 = UInt8(0)
    var left3 = UInt8(0)
    var column = 0
    while column < count {
      let above0 = previous[column]
      let above1 = previous[column + 1]
      let above2 = previous[column + 2]
      let above3 = previous[column + 3]
      left0 = row[column] &+ UInt8((UInt16(left0) + UInt16(above0)) >> 1)
      left1 = row[column + 1] &+ UInt8((UInt16(left1) + UInt16(above1)) >> 1)
      left2 = row[column + 2] &+ UInt8((UInt16(left2) + UInt16(above2)) >> 1)
      left3 = row[column + 3] &+ UInt8((UInt16(left3) + UInt16(above3)) >> 1)
      row[column] = left0
      row[column + 1] = left1
      row[column + 2] = left2
      row[column + 3] = left3
      column += 4
    }
  }

  @inline(__always)
  private static func unfilterPaeth1(
    _ row: UnsafeMutablePointer<UInt8>,
    previous: UnsafePointer<UInt8>,
    count: Int
  ) {
    var left = UInt8(0)
    var upperLeft = UInt8(0)
    var column = 0
    while column < count {
      let above = previous[column]
      let value = row[column] &+ paeth(left: left, above: above, upperLeft: upperLeft)
      row[column] = value
      left = value
      upperLeft = above
      column += 1
    }
  }

  @inline(__always)
  private static func unfilterPaeth2(
    _ row: UnsafeMutablePointer<UInt8>,
    previous: UnsafePointer<UInt8>,
    count: Int
  ) {
    assert(count % 2 == 0)
    var left0 = UInt8(0)
    var left1 = UInt8(0)
    var upperLeft0 = UInt8(0)
    var upperLeft1 = UInt8(0)
    var column = 0
    while column < count {
      let above0 = previous[column]
      let above1 = previous[column + 1]
      let value0 = row[column] &+ paeth(left: left0, above: above0, upperLeft: upperLeft0)
      let value1 = row[column + 1]
        &+ paeth(left: left1, above: above1, upperLeft: upperLeft1)
      row[column] = value0
      row[column + 1] = value1
      left0 = value0
      left1 = value1
      upperLeft0 = above0
      upperLeft1 = above1
      column += 2
    }
  }

  @inline(__always)
  private static func unfilterPaeth3(
    _ row: UnsafeMutablePointer<UInt8>,
    previous: UnsafePointer<UInt8>,
    count: Int
  ) {
    assert(count % 3 == 0)
    var left0 = UInt8(0)
    var left1 = UInt8(0)
    var left2 = UInt8(0)
    var upperLeft0 = UInt8(0)
    var upperLeft1 = UInt8(0)
    var upperLeft2 = UInt8(0)
    var column = 0
    while column < count {
      let above0 = previous[column]
      let above1 = previous[column + 1]
      let above2 = previous[column + 2]
      let value0 = row[column] &+ paeth(left: left0, above: above0, upperLeft: upperLeft0)
      let value1 = row[column + 1]
        &+ paeth(left: left1, above: above1, upperLeft: upperLeft1)
      let value2 = row[column + 2]
        &+ paeth(left: left2, above: above2, upperLeft: upperLeft2)
      row[column] = value0
      row[column + 1] = value1
      row[column + 2] = value2
      left0 = value0
      left1 = value1
      left2 = value2
      upperLeft0 = above0
      upperLeft1 = above1
      upperLeft2 = above2
      column += 3
    }
  }

  @inline(__always)
  private static func unfilterPaeth4(
    _ row: UnsafeMutablePointer<UInt8>,
    previous: UnsafePointer<UInt8>,
    count: Int
  ) {
    assert(count % 4 == 0)
    var left0 = UInt8(0)
    var left1 = UInt8(0)
    var left2 = UInt8(0)
    var left3 = UInt8(0)
    var upperLeft0 = UInt8(0)
    var upperLeft1 = UInt8(0)
    var upperLeft2 = UInt8(0)
    var upperLeft3 = UInt8(0)
    var column = 0
    while column < count {
      let above0 = previous[column]
      let above1 = previous[column + 1]
      let above2 = previous[column + 2]
      let above3 = previous[column + 3]
      let value0 = row[column] &+ paeth(left: left0, above: above0, upperLeft: upperLeft0)
      let value1 = row[column + 1]
        &+ paeth(left: left1, above: above1, upperLeft: upperLeft1)
      let value2 = row[column + 2]
        &+ paeth(left: left2, above: above2, upperLeft: upperLeft2)
      let value3 = row[column + 3]
        &+ paeth(left: left3, above: above3, upperLeft: upperLeft3)
      row[column] = value0
      row[column + 1] = value1
      row[column + 2] = value2
      row[column + 3] = value3
      left0 = value0
      left1 = value1
      left2 = value2
      left3 = value3
      upperLeft0 = above0
      upperLeft1 = above1
      upperLeft2 = above2
      upperLeft3 = above3
      column += 4
    }
  }

  @inline(__always)
  private static func writePackedRow(
    _ source: UnsafePointer<UInt8>,
    to destination: UnsafeMutableBufferPointer<UInt8>,
    outputRowStart: Int,
    sourceBytesPerPixel: Int,
    width: Int,
    transparentRGB8: TransparentRGB8?,
    transparentGray8: UInt8?,
    indexedPalette: IndexedPaletteView?,
    indexedBitDepth: Int?,
    grayscaleBitDepth: Int?,
    transparentGraySample: UInt16?
  ) throws {
    if let indexedPalette {
      guard let indexedBitDepth, [1, 2, 4, 8].contains(indexedBitDepth) else {
        throw PNGScanlineRGBA8Error.decodedByteCountMismatch
      }
      let mask = UInt8((1 << indexedBitDepth) - 1)
      var destinationOffset = outputRowStart
      for pixel in 0..<width {
        let index: Int
        if indexedBitDepth == 8 {
          index = Int(source[pixel])
        } else {
          let bitOffset = pixel * indexedBitDepth
          let byteOffset = bitOffset >> 3
          let shift = 8 - indexedBitDepth - (bitOffset & 7)
          index = Int((source[byteOffset] >> UInt8(shift)) & mask)
        }
        guard index < indexedPalette.entryCount else {
          throw PNGScanlineRGBA8Error.invalidPaletteIndex
        }
        let paletteOffset = index * 3
        let alpha = index < indexedPalette.alphaCount
          ? indexedPalette.alphaBase![index]
          : UInt8(255)
        let red = indexedPalette.rgbBase[paletteOffset]
        let green = indexedPalette.rgbBase[paletteOffset + 1]
        let blue = indexedPalette.rgbBase[paletteOffset + 2]
        if alpha == 0 {
          destination[destinationOffset] = 0
          destination[destinationOffset + 1] = 0
          destination[destinationOffset + 2] = 0
        } else if alpha == 255 {
          destination[destinationOffset] = red
          destination[destinationOffset + 1] = green
          destination[destinationOffset + 2] = blue
        } else {
          let alpha16 = UInt16(alpha)
          destination[destinationOffset] = UInt8((UInt16(red) * alpha16 + 127) / 255)
          destination[destinationOffset + 1] = UInt8((UInt16(green) * alpha16 + 127) / 255)
          destination[destinationOffset + 2] = UInt8((UInt16(blue) * alpha16 + 127) / 255)
        }
        destination[destinationOffset + 3] = alpha
        destinationOffset += 4
      }
      return
    }
    if let grayscaleBitDepth {
      guard [1, 2, 4].contains(grayscaleBitDepth) else {
        throw PNGScanlineRGBA8Error.decodedByteCountMismatch
      }
      let maximumSample = (1 << grayscaleBitDepth) - 1
      let mask = UInt8(maximumSample)
      let transparentSample = transparentGraySample.map { Int($0) & maximumSample }
      var destinationOffset = outputRowStart
      for pixel in 0..<width {
        let bitOffset = pixel * grayscaleBitDepth
        let byteOffset = bitOffset >> 3
        let shift = 8 - grayscaleBitDepth - (bitOffset & 7)
        let sample = Int((source[byteOffset] >> UInt8(shift)) & mask)
        if sample == transparentSample {
          destination[destinationOffset] = 0
          destination[destinationOffset + 1] = 0
          destination[destinationOffset + 2] = 0
          destination[destinationOffset + 3] = 0
        } else {
          let scaled = UInt8((sample * 255) / maximumSample)
          destination[destinationOffset] = scaled
          destination[destinationOffset + 1] = scaled
          destination[destinationOffset + 2] = scaled
          destination[destinationOffset + 3] = 255
        }
        destinationOffset += 4
      }
      return
    }
    if sourceBytesPerPixel == 4 {
      writePremultipliedRow(
        source,
        to: destination,
        outputRowStart: outputRowStart,
        rowBytes: width * 4
      )
      return
    }
    if sourceBytesPerPixel == 2 {
      assert(transparentRGB8 == nil)
      assert(transparentGray8 == nil)
      var sourceOffset = 0
      var destinationOffset = outputRowStart
      for _ in 0..<width {
        let gray = source[sourceOffset]
        let alpha = source[sourceOffset + 1]
        let premultiplied: UInt8
        if alpha == 0 {
          premultiplied = 0
        } else if alpha == 255 {
          premultiplied = gray
        } else {
          premultiplied = UInt8((UInt16(gray) * UInt16(alpha) + 127) / 255)
        }
        destination[destinationOffset] = premultiplied
        destination[destinationOffset + 1] = premultiplied
        destination[destinationOffset + 2] = premultiplied
        destination[destinationOffset + 3] = alpha
        sourceOffset += 2
        destinationOffset += 4
      }
      return
    }
    if sourceBytesPerPixel == 1 {
      assert(transparentRGB8 == nil)
      var destinationOffset = outputRowStart
      for sourceOffset in 0..<width {
        let gray = source[sourceOffset]
        if gray == transparentGray8 {
          destination[destinationOffset] = 0
          destination[destinationOffset + 1] = 0
          destination[destinationOffset + 2] = 0
          destination[destinationOffset + 3] = 0
        } else {
          destination[destinationOffset] = gray
          destination[destinationOffset + 1] = gray
          destination[destinationOffset + 2] = gray
          destination[destinationOffset + 3] = 255
        }
        destinationOffset += 4
      }
      return
    }
    assert(sourceBytesPerPixel == 3)
    var sourceOffset = 0
    var destinationOffset = outputRowStart
    for _ in 0..<width {
      let red = source[sourceOffset]
      let green = source[sourceOffset + 1]
      let blue = source[sourceOffset + 2]
      if let transparentRGB8,
        red == transparentRGB8.red,
        green == transparentRGB8.green,
        blue == transparentRGB8.blue
      {
        destination[destinationOffset] = 0
        destination[destinationOffset + 1] = 0
        destination[destinationOffset + 2] = 0
        destination[destinationOffset + 3] = 0
      } else {
        destination[destinationOffset] = red
        destination[destinationOffset + 1] = green
        destination[destinationOffset + 2] = blue
        destination[destinationOffset + 3] = 255
      }
      sourceOffset += 3
      destinationOffset += 4
    }
  }

  static func premultiplyStraightAlpha(_ straightRGBA: Data) -> Data {
    var output = straightRGBA
    output.withUnsafeMutableBytes { raw in
      let bytes = raw.bindMemory(to: UInt8.self)
      var offset = 0
      while offset + 3 < bytes.count {
        let alpha = UInt16(bytes[offset + 3])
        if alpha == 0 {
          bytes[offset] = 0
          bytes[offset + 1] = 0
          bytes[offset + 2] = 0
        } else if alpha != 255 {
          bytes[offset] = UInt8((UInt16(bytes[offset]) * alpha + 127) / 255)
          bytes[offset + 1] = UInt8((UInt16(bytes[offset + 1]) * alpha + 127) / 255)
          bytes[offset + 2] = UInt8((UInt16(bytes[offset + 2]) * alpha + 127) / 255)
        }
        offset += 4
      }
    }
    return output
  }

  @inline(__always)
  private static func writePremultipliedRow(
    _ straight: UnsafePointer<UInt8>,
    to destination: UnsafeMutableBufferPointer<UInt8>,
    outputRowStart: Int,
    rowBytes: Int
  ) {
    var column = 0
    while column < rowBytes {
      let alpha = UInt16(straight[column + 3])
      if alpha == 0 {
        destination[outputRowStart + column] = 0
        destination[outputRowStart + column + 1] = 0
        destination[outputRowStart + column + 2] = 0
      } else if alpha == 255 {
        destination[outputRowStart + column] = straight[column]
        destination[outputRowStart + column + 1] = straight[column + 1]
        destination[outputRowStart + column + 2] = straight[column + 2]
      } else {
        destination[outputRowStart + column] =
          UInt8((UInt16(straight[column]) * alpha + 127) / 255)
        destination[outputRowStart + column + 1] =
          UInt8((UInt16(straight[column + 1]) * alpha + 127) / 255)
        destination[outputRowStart + column + 2] =
          UInt8((UInt16(straight[column + 2]) * alpha + 127) / 255)
      }
      destination[outputRowStart + column + 3] = straight[column + 3]
      column += 4
    }
  }

  @inline(__always)
  private static func writePremultipliedRow(
    _ straight: [UInt8],
    to destination: UnsafeMutableBufferPointer<UInt8>,
    outputRowStart: Int,
    rowBytes: Int
  ) {
    var column = 0
    while column < rowBytes {
      let alpha = UInt16(straight[column + 3])
      if alpha == 0 {
        destination[outputRowStart + column] = 0
        destination[outputRowStart + column + 1] = 0
        destination[outputRowStart + column + 2] = 0
      } else if alpha == 255 {
        destination[outputRowStart + column] = straight[column]
        destination[outputRowStart + column + 1] = straight[column + 1]
        destination[outputRowStart + column + 2] = straight[column + 2]
      } else {
        destination[outputRowStart + column] =
          UInt8((UInt16(straight[column]) * alpha + 127) / 255)
        destination[outputRowStart + column + 1] =
          UInt8((UInt16(straight[column + 1]) * alpha + 127) / 255)
        destination[outputRowStart + column + 2] =
          UInt8((UInt16(straight[column + 2]) * alpha + 127) / 255)
      }
      destination[outputRowStart + column + 3] = straight[column + 3]
      column += 4
    }
  }

  @inline(__always)
  private static func unfilterSub(
    input: UnsafeBufferPointer<UInt8>,
    inputOffset: Int,
    decoded: UnsafeMutableBufferPointer<UInt8>,
    rowStart: Int,
    rowBytes: Int
  ) {
    for channel in 0..<4 {
      var left = UInt8(0)
      var column = channel
      while column < rowBytes {
        let value = input[inputOffset + column] &+ left
        decoded[rowStart + column] = value
        left = value
        column += 4
      }
    }
  }

  @inline(__always)
  private static func unfilterAverage(
    input: UnsafeBufferPointer<UInt8>,
    inputOffset: Int,
    decoded: UnsafeMutableBufferPointer<UInt8>,
    rowStart: Int,
    previousStart: Int?,
    rowBytes: Int
  ) {
    var left = [UInt8](repeating: 0, count: 4)
    var column = 0
    while column < rowBytes {
      for channel in 0..<4 {
        let above = previousStart.map { decoded[$0 + column + channel] } ?? 0
        let value = input[inputOffset + column + channel]
          &+ UInt8((UInt16(left[channel]) + UInt16(above)) >> 1)
        decoded[rowStart + column + channel] = value
        left[channel] = value
      }
      column += 4
    }
  }

  @inline(__always)
  private static func unfilterPaeth(
    input: UnsafeBufferPointer<UInt8>,
    inputOffset: Int,
    decoded: UnsafeMutableBufferPointer<UInt8>,
    rowStart: Int,
    previousStart: Int?,
    rowBytes: Int
  ) {
    var left = [UInt8](repeating: 0, count: 4)
    var upperLeft = [UInt8](repeating: 0, count: 4)
    var column = 0
    while column < rowBytes {
      for channel in 0..<4 {
        let above = previousStart.map { decoded[$0 + column + channel] } ?? 0
        let value = input[inputOffset + column + channel]
          &+ paeth(left: left[channel], above: above, upperLeft: upperLeft[channel])
        decoded[rowStart + column + channel] = value
        left[channel] = value
        upperLeft[channel] = above
      }
      column += 4
    }
  }

  @inline(__always)
  private static func paeth(left: UInt8, above: UInt8, upperLeft: UInt8) -> UInt8 {
    // Algebraically identical to distances from p = left + above - upperLeft, but keeps every
    // intermediate in the narrow [-510, 510] domain and avoids generic `abs` in the hot loop.
    var leftDistance = Int(above) - Int(upperLeft)
    var aboveDistance = Int(left) - Int(upperLeft)
    var upperLeftDistance = leftDistance + aboveDistance
    if leftDistance < 0 { leftDistance = -leftDistance }
    if aboveDistance < 0 { aboveDistance = -aboveDistance }
    if upperLeftDistance < 0 { upperLeftDistance = -upperLeftDistance }
    if leftDistance <= aboveDistance, leftDistance <= upperLeftDistance { return left }
    return aboveDistance <= upperLeftDistance ? above : upperLeft
  }
}
