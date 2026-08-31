import Foundation
import ImageCraftCore

/// Caller-owned 8-bit JFIF/BT.601-style YCbCr -> RGB conversion matching the pinned IJG/libjpeg
/// integer table arithmetic.  The input is full-resolution interleaved Y,Cb,Cr; chroma upsampling is
/// deliberately outside this primitive.  No payload-sized allocation is performed.
package enum JPEGYCbCrToRGB {
  private static let scaleBits = 16
  private static let oneHalf: Int64 = 1 << (scaleBits - 1)
  private static let crToR: Int64 = 91_881   // FIX(1.40200)
  private static let cbToB: Int64 = 116_130  // FIX(1.77200)
  private static let crToG: Int64 = 46_802   // FIX(0.71414)
  private static let cbToG: Int64 = 22_554   // FIX(0.34414)

  package static func writeInterleavedRGB(
    yCbCr: UnsafeBufferPointer<UInt8>,
    destination: UnsafeMutableBufferPointer<UInt8>
  ) throws {
    guard yCbCr.count % 3 == 0, destination.count == yCbCr.count else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    let pixelCount = yCbCr.count / 3
    for pixel in 0..<pixelCount {
      let input = pixel * 3
      let y = Int64(yCbCr[input])
      let cb = Int64(yCbCr[input + 1]) - 128
      let cr = Int64(yCbCr[input + 2]) - 128
      let rgb = convert(y: y, cb: cb, cr: cr)
      destination[input] = rgb.0
      destination[input + 1] = rgb.1
      destination[input + 2] = rgb.2
    }
  }

  package static func writePlanarRGB(
    y: UnsafeBufferPointer<UInt8>,
    cb: UnsafeBufferPointer<UInt8>,
    cr: UnsafeBufferPointer<UInt8>,
    destination: UnsafeMutableBufferPointer<UInt8>,
    destinationPixelStride: Int = 3,
    destinationRowStride: Int,
    writeWidth: Int,
    writeHeight: Int,
    sourceRowStride: Int = 8
  ) throws {
    guard (1...8).contains(writeWidth), (1...8).contains(writeHeight),
      sourceRowStride >= writeWidth,
      destinationPixelStride >= 3,
      destinationRowStride >= writeWidth * destinationPixelStride
    else { throw ImageCraftError.unsupportedOrCorruptImage }
    let sourceRequired = (writeHeight - 1).multipliedReportingOverflow(by: sourceRowStride)
    guard !sourceRequired.overflow else { throw ImageCraftError.unsupportedOrCorruptImage }
    let sourceCount = sourceRequired.partialValue.addingReportingOverflow(writeWidth)
    guard !sourceCount.overflow,
      sourceCount.partialValue <= y.count,
      sourceCount.partialValue <= cb.count,
      sourceCount.partialValue <= cr.count
    else { throw ImageCraftError.unsupportedOrCorruptImage }
    let destinationRequired = (writeHeight - 1).multipliedReportingOverflow(
      by: destinationRowStride
    )
    guard !destinationRequired.overflow else { throw ImageCraftError.unsupportedOrCorruptImage }
    let lastRowBytes = writeWidth.multipliedReportingOverflow(by: destinationPixelStride)
    guard !lastRowBytes.overflow else { throw ImageCraftError.unsupportedOrCorruptImage }
    let destinationCount = destinationRequired.partialValue.addingReportingOverflow(
      lastRowBytes.partialValue
    )
    guard !destinationCount.overflow, destinationCount.partialValue <= destination.count else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }

    for row in 0..<writeHeight {
      let sourceBase = row * sourceRowStride
      let destinationBase = row * destinationRowStride
      for column in 0..<writeWidth {
        let sourceIndex = sourceBase + column
        let destinationIndex = destinationBase + column * destinationPixelStride
        let yy = Int64(y[sourceIndex])
        let cbb = Int64(cb[sourceIndex]) - 128
        let crr = Int64(cr[sourceIndex]) - 128
        let rgb = convert(y: yy, cb: cbb, cr: crr)
        destination[destinationIndex] = rgb.0
        destination[destinationIndex + 1] = rgb.1
        destination[destinationIndex + 2] = rgb.2
      }
    }
  }

  /// Arbitrary-width single-row variant used by strip-based independent JPEG decoders. All input
  /// and destination storage is caller-owned; no temporary payload allocation is performed.
  package static func writePlanarRGBRow(
    y: UnsafeBufferPointer<UInt8>,
    cb: UnsafeBufferPointer<UInt8>,
    cr: UnsafeBufferPointer<UInt8>,
    destination: UnsafeMutableBufferPointer<UInt8>,
    writeWidth: Int
  ) throws {
    guard writeWidth > 0,
      writeWidth <= y.count,
      writeWidth <= cb.count,
      writeWidth <= cr.count
    else { throw ImageCraftError.unsupportedOrCorruptImage }
    let required = writeWidth.multipliedReportingOverflow(by: 3)
    guard !required.overflow, required.partialValue <= destination.count else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    for column in 0..<writeWidth {
      let yy = Int64(y[column])
      let cbb = Int64(cb[column]) - 128
      let crr = Int64(cr[column]) - 128
      let rgb = convert(y: yy, cb: cbb, cr: crr)
      let output = column * 3
      destination[output] = rgb.0
      destination[output + 1] = rgb.1
      destination[output + 2] = rgb.2
    }
  }

  /// Fused centered H2V2 chroma reconstruction + YCbCr conversion for strip-based JPEG renderers.
  /// Full-resolution Cb/Cr rows are consumed at the same output column instead of materialized.
  package static func writeCenteredH2V2RGBRow(
    y: UnsafeBufferPointer<UInt8>,
    currentCb: UnsafeBufferPointer<UInt8>,
    adjacentCb: UnsafeBufferPointer<UInt8>,
    currentCr: UnsafeBufferPointer<UInt8>,
    adjacentCr: UnsafeBufferPointer<UInt8>,
    destination: UnsafeMutableBufferPointer<UInt8>,
    writeWidth: Int,
    usesFancyGlobalContext: Bool
  ) throws {
    let sourceWidth = currentCb.count
    let maximumOutputWidth = sourceWidth.multipliedReportingOverflow(by: 2)
    let required = writeWidth.multipliedReportingOverflow(by: 3)
    guard sourceWidth > 0,
      !maximumOutputWidth.overflow,
      writeWidth > 0,
      writeWidth <= maximumOutputWidth.partialValue,
      writeWidth <= y.count,
      currentCr.count == sourceWidth,
      adjacentCb.count == sourceWidth,
      adjacentCr.count == sourceWidth,
      !required.overflow,
      required.partialValue <= destination.count
    else { throw ImageCraftError.unsupportedOrCorruptImage }

    @inline(__always)
    func write(_ column: Int, cb: UInt8, cr: UInt8) {
      guard column < writeWidth else { return }
      let rgb = convert(
        y: Int64(y[column]),
        cb: Int64(cb) - 128,
        cr: Int64(cr) - 128
      )
      let output = column * 3
      destination[output] = rgb.0
      destination[output + 1] = rgb.1
      destination[output + 2] = rgb.2
    }

    if !usesFancyGlobalContext {
      for column in 0..<writeWidth {
        let sourceColumn = column / 2
        write(column, cb: currentCb[sourceColumn], cr: currentCr[sourceColumn])
      }
      return
    }

    guard sourceWidth > 2 else { throw ImageCraftError.unsupportedOrCorruptImage }

    @inline(__always)
    func cbVerticalSum(_ column: Int) -> Int {
      Int(currentCb[column]) * 3 + Int(adjacentCb[column])
    }

    @inline(__always)
    func crVerticalSum(_ column: Int) -> Int {
      Int(currentCr[column]) * 3 + Int(adjacentCr[column])
    }

    var cbLast = cbVerticalSum(0)
    var cbCurrent = cbLast
    var cbNext = cbVerticalSum(1)
    var crLast = crVerticalSum(0)
    var crCurrent = crLast
    var crNext = crVerticalSum(1)
    write(
      0,
      cb: UInt8((cbCurrent * 4 + 8) >> 4),
      cr: UInt8((crCurrent * 4 + 8) >> 4)
    )
    write(
      1,
      cb: UInt8((cbCurrent * 3 + cbNext + 7) >> 4),
      cr: UInt8((crCurrent * 3 + crNext + 7) >> 4)
    )
    cbLast = cbCurrent
    cbCurrent = cbNext
    crLast = crCurrent
    crCurrent = crNext

    for column in 1..<(sourceWidth - 1) {
      cbNext = cbVerticalSum(column + 1)
      crNext = crVerticalSum(column + 1)
      write(
        column * 2,
        cb: UInt8((cbCurrent * 3 + cbLast + 8) >> 4),
        cr: UInt8((crCurrent * 3 + crLast + 8) >> 4)
      )
      write(
        column * 2 + 1,
        cb: UInt8((cbCurrent * 3 + cbNext + 7) >> 4),
        cr: UInt8((crCurrent * 3 + crNext + 7) >> 4)
      )
      cbLast = cbCurrent
      cbCurrent = cbNext
      crLast = crCurrent
      crCurrent = crNext
    }
    write(
      (sourceWidth - 1) * 2,
      cb: UInt8((cbCurrent * 3 + cbLast + 8) >> 4),
      cr: UInt8((crCurrent * 3 + crLast + 8) >> 4)
    )
    write(
      (sourceWidth - 1) * 2 + 1,
      cb: UInt8((cbCurrent * 4 + 7) >> 4),
      cr: UInt8((crCurrent * 4 + 7) >> 4)
    )
  }

  @inline(__always)
  private static func convert(y: Int64, cb: Int64, cr: Int64) -> (UInt8, UInt8, UInt8) {
    let redOffset = (Self.crToR * cr + Self.oneHalf) >> Self.scaleBits
    let blueOffset = (Self.cbToB * cb + Self.oneHalf) >> Self.scaleBits
    let greenOffset =
      ((-Self.cbToG * cb + Self.oneHalf) + (-Self.crToG * cr)) >> Self.scaleBits
    return (
      clamp8(y + redOffset),
      clamp8(y + greenOffset),
      clamp8(y + blueOffset)
    )
  }

  @inline(__always)
  private static func clamp8(_ value: Int64) -> UInt8 {
    if value <= 0 { return 0 }
    if value >= 255 { return 255 }
    return UInt8(value)
  }
}
