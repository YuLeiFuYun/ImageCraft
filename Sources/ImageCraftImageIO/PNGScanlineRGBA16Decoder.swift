import Foundation

/// Streaming row decoder for exact high-depth PNG values normalized to straight RGBA16LE.
///
/// PNG filtering is applied to source bytes before endian conversion. Source samples are big-endian
/// per PNG; the published qualification value is straight RGBA16 little-endian. RGB16 sources may
/// carry one exact tRNS key; comparison happens in the full 16-bit source-sample domain before alpha
/// is injected.
enum PNGScanlineRGBA16Decoder {
  struct TransparentRGB16: Equatable, Sendable {
    let red: UInt16
    let green: UInt16
    let blue: UInt16
  }

  enum SourceLayout: Equatable, Sendable {
    case grayscale(transparent: UInt16?)
    case grayscaleAlpha
    case rgb(transparent: TransparentRGB16?)
    case rgba

    var bytesPerPixel: Int {
      switch self {
      case .grayscale: 2
      case .grayscaleAlpha: 4
      case .rgb: 6
      case .rgba: 8
      }
    }
  }

  static func inflateAndDecodeStraightRGBA16LittleEndian<Cursor: RFC1950StreamingByteCursor>(
    cursor: Cursor,
    width: Int,
    height: Int,
    sourceLayout: SourceLayout = .rgba,
    outputColorTransform: PNG16OutputColorTransform = .preserve
  ) throws -> Data {
    guard width > 0, height > 0 else {
      throw PNGScanlineRGBA8Error.decodedByteCountMismatch
    }
    switch outputColorTransform {
    case .preserve:
      break
    case .displayP3ToSRGBInGamut, .iccMatrixTRCToSRGBInGamut:
      switch sourceLayout {
      case .rgb, .rgba: break
      case .grayscale, .grayscaleAlpha:
        throw PNGScanlineRGBA8Error.decodedByteCountMismatch
      }
    }
    let sourceRowBytes = width.multipliedReportingOverflow(by: sourceLayout.bytesPerPixel)
    let outputRowBytes = width.multipliedReportingOverflow(by: 8)
    guard !sourceRowBytes.overflow, !outputRowBytes.overflow else {
      throw PNGScanlineRGBA8Error.decodedByteCountMismatch
    }
    let filteredRowBytes = sourceRowBytes.partialValue.addingReportingOverflow(1)
    guard !filteredRowBytes.overflow else {
      throw PNGScanlineRGBA8Error.decodedByteCountMismatch
    }
    let expectedInflated = filteredRowBytes.partialValue.multipliedReportingOverflow(by: height)
    let outputByteCount = outputRowBytes.partialValue.multipliedReportingOverflow(by: height)
    let rowStorageByteCount = sourceRowBytes.partialValue.multipliedReportingOverflow(by: 2)
    guard !expectedInflated.overflow,
      !outputByteCount.overflow,
      !rowStorageByteCount.overflow
    else { throw PNGScanlineRGBA8Error.decodedByteCountMismatch }

    let rowStorage = UnsafeMutablePointer<UInt8>.allocate(capacity: rowStorageByteCount.partialValue)
    defer { rowStorage.deallocate() }
    memset(rowStorage, 0, rowStorageByteCount.partialValue)
    var previous = rowStorage
    var current = rowStorage.advanced(by: sourceRowBytes.partialValue)
    var output = Data(count: outputByteCount.partialValue)
    var row = 0
    var positionInFilteredRow = 0
    var filter = UInt8(0)

    try output.withUnsafeMutableBytes { outputRaw in
      let destination = outputRaw.bindMemory(to: UInt8.self)
      try RFC1950BoundedInflate.inflateStreaming(
        cursor: cursor,
        expectedByteCount: expectedInflated.partialValue
      ) { bytes in
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
          guard column < sourceRowBytes.partialValue else {
            throw PNGScanlineRGBA8Error.decodedByteCountMismatch
          }
          let copyCount = min(
            sourceRowBytes.partialValue - column,
            bytes.count - inputOffset
          )
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

          if positionInFilteredRow == sourceRowBytes.partialValue + 1 {
            try PNGScanlineRGBA8Decoder.unfilterCurrentRowInPlace(
              current,
              previous: UnsafePointer(previous),
              count: sourceRowBytes.partialValue,
              filter: filter,
              bytesPerPixel: sourceLayout.bytesPerPixel
            )
            let outputRowStart = row * outputRowBytes.partialValue
            switch sourceLayout {
            case .grayscale(let transparent):
              var sourceOffset = 0
              var outputOffset = outputRowStart
              while sourceOffset < sourceRowBytes.partialValue {
                let gray = readBigEndianSample(current, at: sourceOffset)
                writeLittleEndian(gray, to: destination, at: outputOffset)
                writeLittleEndian(gray, to: destination, at: outputOffset + 2)
                writeLittleEndian(gray, to: destination, at: outputOffset + 4)
                writeLittleEndian(gray == transparent ? 0 : UInt16.max, to: destination, at: outputOffset + 6)
                sourceOffset += 2
                outputOffset += 8
              }
            case .grayscaleAlpha:
              var sourceOffset = 0
              var outputOffset = outputRowStart
              while sourceOffset < sourceRowBytes.partialValue {
                let gray = readBigEndianSample(current, at: sourceOffset)
                let alpha = readBigEndianSample(current, at: sourceOffset + 2)
                writeLittleEndian(gray, to: destination, at: outputOffset)
                writeLittleEndian(gray, to: destination, at: outputOffset + 2)
                writeLittleEndian(gray, to: destination, at: outputOffset + 4)
                writeLittleEndian(alpha, to: destination, at: outputOffset + 6)
                sourceOffset += 4
                outputOffset += 8
              }
            case .rgba:
              if outputColorTransform == .preserve {
                var sourceOffset = 0
                while sourceOffset < sourceRowBytes.partialValue {
                  writeLittleEndianSample(
                    high: current[sourceOffset],
                    low: current[sourceOffset + 1],
                    to: destination,
                    at: outputRowStart + sourceOffset
                  )
                  sourceOffset += 2
                }
              } else {
                var sourceOffset = 0
                var outputOffset = outputRowStart
                while sourceOffset < sourceRowBytes.partialValue {
                  let converted = try outputColorTransform.convert(
                    red: readBigEndianSample(current, at: sourceOffset),
                    green: readBigEndianSample(current, at: sourceOffset + 2),
                    blue: readBigEndianSample(current, at: sourceOffset + 4)
                  )
                  let alpha = readBigEndianSample(current, at: sourceOffset + 6)
                  writeLittleEndian(converted.red, to: destination, at: outputOffset)
                  writeLittleEndian(converted.green, to: destination, at: outputOffset + 2)
                  writeLittleEndian(converted.blue, to: destination, at: outputOffset + 4)
                  writeLittleEndian(alpha, to: destination, at: outputOffset + 6)
                  sourceOffset += 8
                  outputOffset += 8
                }
              }
            case .rgb(let transparent):
              var sourceOffset = 0
              var outputOffset = outputRowStart
              while sourceOffset < sourceRowBytes.partialValue {
                let red = readBigEndianSample(current, at: sourceOffset)
                let green = readBigEndianSample(current, at: sourceOffset + 2)
                let blue = readBigEndianSample(current, at: sourceOffset + 4)
                let converted = try outputColorTransform.convert(
                  red: red,
                  green: green,
                  blue: blue
                )
                writeLittleEndian(converted.red, to: destination, at: outputOffset)
                writeLittleEndian(converted.green, to: destination, at: outputOffset + 2)
                writeLittleEndian(converted.blue, to: destination, at: outputOffset + 4)
                let isTransparent = transparent.map {
                  red == $0.red && green == $0.green && blue == $0.blue
                } ?? false
                writeLittleEndian(isTransparent ? 0 : UInt16.max, to: destination, at: outputOffset + 6)
                sourceOffset += 6
                outputOffset += 8
              }
            }
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

  static func inflateAndDecodeStraightRGBA16LittleEndianAdam7<Cursor: RFC1950StreamingByteCursor>(
    cursor: Cursor,
    width: Int,
    height: Int,
    sourceLayout: SourceLayout = .rgba,
    outputColorTransform: PNG16OutputColorTransform = .preserve
  ) throws -> Data {
    guard width > 0, height > 0,
      let passes = PNGAdam7Geometry.passes(width: width, height: height),
      let expectedInflatedByteCount = PNGAdam7Geometry.expectedInflatedByteCount(
        passes: passes,
        bytesPerPixel: sourceLayout.bytesPerPixel
      )
    else { throw PNGScanlineRGBA8Error.decodedByteCountMismatch }
    switch outputColorTransform {
    case .preserve:
      break
    case .displayP3ToSRGBInGamut, .iccMatrixTRCToSRGBInGamut:
      switch sourceLayout {
      case .rgb, .rgba: break
      case .grayscale, .grayscaleAlpha:
        throw PNGScanlineRGBA8Error.decodedByteCountMismatch
      }
    }

    let sourceFullRowBytes = width.multipliedReportingOverflow(by: sourceLayout.bytesPerPixel)
    let outputFullRowBytes = width.multipliedReportingOverflow(by: 8)
    guard !sourceFullRowBytes.overflow, !outputFullRowBytes.overflow else {
      throw PNGScanlineRGBA8Error.decodedByteCountMismatch
    }
    let outputByteCount = outputFullRowBytes.partialValue.multipliedReportingOverflow(by: height)
    let rowStorageByteCount = sourceFullRowBytes.partialValue.multipliedReportingOverflow(by: 2)
    guard !outputByteCount.overflow, !rowStorageByteCount.overflow else {
      throw PNGScanlineRGBA8Error.decodedByteCountMismatch
    }

    let rowStorage = UnsafeMutablePointer<UInt8>.allocate(capacity: rowStorageByteCount.partialValue)
    defer { rowStorage.deallocate() }
    memset(rowStorage, 0, rowStorageByteCount.partialValue)
    var previous = rowStorage
    var current = rowStorage.advanced(by: sourceFullRowBytes.partialValue)
    var output = Data(count: outputByteCount.partialValue)
    var passIndex = 0
    var passRow = 0
    var positionInFilteredRow = 0
    var filter = UInt8(0)

    try output.withUnsafeMutableBytes { outputRaw in
      let destination = outputRaw.bindMemory(to: UInt8.self)
      try RFC1950BoundedInflate.inflateStreaming(
        cursor: cursor,
        expectedByteCount: expectedInflatedByteCount
      ) { bytes in
        var inputOffset = 0
        while inputOffset < bytes.count {
          guard passIndex < passes.count else {
            throw PNGScanlineRGBA8Error.decodedByteCountMismatch
          }
          let pass = passes[passIndex]
          let passRowBytes = pass.width * sourceLayout.bytesPerPixel
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
            try PNGScanlineRGBA8Decoder.unfilterCurrentRowInPlace(
              current,
              previous: UnsafePointer(previous),
              count: passRowBytes,
              filter: filter,
              bytesPerPixel: sourceLayout.bytesPerPixel
            )
            try writeStraightAdam7RGBA16Row(
              UnsafePointer(current),
              to: destination,
              fullWidth: width,
              pass: pass,
              passRow: passRow,
              sourceLayout: sourceLayout,
              outputColorTransform: outputColorTransform
            )
            swap(&previous, &current)
            passRow += 1
            positionInFilteredRow = 0
            if passRow == pass.height {
              passIndex += 1
              passRow = 0
              if passIndex < passes.count {
                memset(previous, 0, sourceFullRowBytes.partialValue)
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

  private static func writeStraightAdam7RGBA16Row(
    _ source: UnsafePointer<UInt8>,
    to destination: UnsafeMutableBufferPointer<UInt8>,
    fullWidth: Int,
    pass: PNGAdam7Geometry.Pass,
    passRow: Int,
    sourceLayout: SourceLayout,
    outputColorTransform: PNG16OutputColorTransform
  ) throws {
    guard passRow >= 0, passRow < pass.height else {
      throw PNGScanlineRGBA8Error.decodedByteCountMismatch
    }
    let y = pass.yStart + passRow * pass.yStep
    for passColumn in 0..<pass.width {
      let x = pass.xStart + passColumn * pass.xStep
      let sourceOffset = passColumn * sourceLayout.bytesPerPixel
      let destinationOffset = (y * fullWidth + x) * 8
      guard destinationOffset >= 0, destinationOffset + 7 < destination.count else {
        throw PNGScanlineRGBA8Error.decodedByteCountMismatch
      }
      switch sourceLayout {
      case .grayscale(let transparent):
        let gray = readBigEndianSample(source, at: sourceOffset)
        writeLittleEndian(gray, to: destination, at: destinationOffset)
        writeLittleEndian(gray, to: destination, at: destinationOffset + 2)
        writeLittleEndian(gray, to: destination, at: destinationOffset + 4)
        writeLittleEndian(gray == transparent ? 0 : UInt16.max, to: destination, at: destinationOffset + 6)
      case .grayscaleAlpha:
        let gray = readBigEndianSample(source, at: sourceOffset)
        let alpha = readBigEndianSample(source, at: sourceOffset + 2)
        writeLittleEndian(gray, to: destination, at: destinationOffset)
        writeLittleEndian(gray, to: destination, at: destinationOffset + 2)
        writeLittleEndian(gray, to: destination, at: destinationOffset + 4)
        writeLittleEndian(alpha, to: destination, at: destinationOffset + 6)
      case .rgba:
        if outputColorTransform == .preserve {
          for sampleOffset in stride(from: 0, to: 8, by: 2) {
            destination[destinationOffset + sampleOffset] = source[sourceOffset + sampleOffset + 1]
            destination[destinationOffset + sampleOffset + 1] = source[sourceOffset + sampleOffset]
          }
        } else {
          let converted = try outputColorTransform.convert(
            red: readBigEndianSample(source, at: sourceOffset),
            green: readBigEndianSample(source, at: sourceOffset + 2),
            blue: readBigEndianSample(source, at: sourceOffset + 4)
          )
          let alpha = readBigEndianSample(source, at: sourceOffset + 6)
          writeLittleEndian(converted.red, to: destination, at: destinationOffset)
          writeLittleEndian(converted.green, to: destination, at: destinationOffset + 2)
          writeLittleEndian(converted.blue, to: destination, at: destinationOffset + 4)
          writeLittleEndian(alpha, to: destination, at: destinationOffset + 6)
        }
      case .rgb(let transparent):
        let red = readBigEndianSample(source, at: sourceOffset)
        let green = readBigEndianSample(source, at: sourceOffset + 2)
        let blue = readBigEndianSample(source, at: sourceOffset + 4)
        let converted = try outputColorTransform.convert(
          red: red,
          green: green,
          blue: blue
        )
        writeLittleEndian(converted.red, to: destination, at: destinationOffset)
        writeLittleEndian(converted.green, to: destination, at: destinationOffset + 2)
        writeLittleEndian(converted.blue, to: destination, at: destinationOffset + 4)
        let isTransparent = transparent.map {
          red == $0.red && green == $0.green && blue == $0.blue
        } ?? false
        writeLittleEndian(isTransparent ? 0 : UInt16.max, to: destination, at: destinationOffset + 6)
      }
    }
  }

  @inline(__always)
  private static func readBigEndianSample(
    _ bytes: UnsafePointer<UInt8>,
    at offset: Int
  ) -> UInt16 {
    UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
  }

  @inline(__always)
  private static func writeLittleEndianSample(
    high: UInt8,
    low: UInt8,
    to destination: UnsafeMutableBufferPointer<UInt8>,
    at offset: Int
  ) {
    destination[offset] = low
    destination[offset + 1] = high
  }

  @inline(__always)
  private static func writeLittleEndian(
    _ sample: UInt16,
    to destination: UnsafeMutableBufferPointer<UInt8>,
    at offset: Int
  ) {
    destination[offset] = UInt8(truncatingIfNeeded: sample)
    destination[offset + 1] = UInt8(truncatingIfNeeded: sample >> 8)
  }
}
