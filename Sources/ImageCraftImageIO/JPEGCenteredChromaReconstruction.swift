import Foundation
import ImageCraftCore

/// Package-owned 8-bit centered chroma reconstruction primitives for the narrow independent-JPEG
/// research seam.
///
/// The destination is caller-owned so output bytes can be admitted before reconstruction. Internal
/// iMCU boundaries have no semantic role here: adjacent source rows are clamped only at the actual
/// top/bottom image edge. Integer biases match the pinned reference triangle-filter arithmetic so
/// rounding behavior is independently testable instead of hidden behind a tolerance.
package enum JPEGCenteredChromaReconstruction {
  /// Reconstruct one horizontally and vertically 2x-subsampled chroma row using the same
  /// centered triangle arithmetic as libjpeg's fancy h2v2 path. `current` is the nearest
  /// low-resolution row for the output row and `adjacent` is the next-nearest row (above for
  /// even output rows, below for odd output rows). The vertical phase is therefore represented by
  /// row selection rather than another parameter.
  package static func writeH2V2Row(
    current: UnsafeBufferPointer<UInt8>,
    adjacent: UnsafeBufferPointer<UInt8>,
    destination: UnsafeMutableBufferPointer<UInt8>,
    outputWidth: Int
  ) throws {
    let sourceWidth = current.count
    let maximumOutputWidth = try product(sourceWidth, 2)
    guard sourceWidth > 2,
      adjacent.count == sourceWidth,
      outputWidth > 0,
      outputWidth <= maximumOutputWidth,
      destination.count >= outputWidth
    else { throw ImageCraftError.unsupportedOrCorruptImage }

    @inline(__always)
    func verticalSum(_ column: Int) -> Int {
      Int(current[column]) * 3 + Int(adjacent[column])
    }

    @inline(__always)
    func write(_ column: Int, _ value: UInt8) {
      if column < outputWidth { destination[column] = value }
    }

    var lastSum = verticalSum(0)
    var currentSum = lastSum
    var nextSum = verticalSum(1)
    write(0, UInt8((currentSum * 4 + 8) >> 4))
    write(1, UInt8((currentSum * 3 + nextSum + 7) >> 4))
    lastSum = currentSum
    currentSum = nextSum

    for column in 1..<(sourceWidth - 1) {
      nextSum = verticalSum(column + 1)
      write(column * 2, UInt8((currentSum * 3 + lastSum + 8) >> 4))
      write(column * 2 + 1, UInt8((currentSum * 3 + nextSum + 7) >> 4))
      lastSum = currentSum
      currentSum = nextSum
    }
    write((sourceWidth - 1) * 2, UInt8((currentSum * 3 + lastSum + 8) >> 4))
    write((sourceWidth - 1) * 2 + 1, UInt8((currentSum * 4 + 7) >> 4))
  }

  /// Narrow h2v2 sources (`downsampled_width <= 2`) deliberately do not enter libjpeg's fancy
  /// path. They use the box filter instead, duplicating each source sample horizontally and the
  /// same source row vertically. Keeping that branch explicit prevents a small-image edge case
  /// from being silently forced through the context-row model.
  package static func writeH2V2BoxRow(
    source: UnsafeBufferPointer<UInt8>,
    destination: UnsafeMutableBufferPointer<UInt8>,
    outputWidth: Int
  ) throws {
    let maximumOutputWidth = try product(source.count, 2)
    guard !source.isEmpty,
      outputWidth > 0,
      outputWidth <= maximumOutputWidth,
      destination.count >= outputWidth
    else { throw ImageCraftError.unsupportedOrCorruptImage }
    for column in 0..<source.count {
      let outputColumn = column * 2
      if outputColumn < outputWidth { destination[outputColumn] = source[column] }
      if outputColumn + 1 < outputWidth { destination[outputColumn + 1] = source[column] }
    }
  }

  package static func writeH1V2(
    source: UnsafeBufferPointer<UInt8>,
    sourceWidth: Int,
    sourceHeight: Int,
    destination: UnsafeMutableBufferPointer<UInt8>,
    outputHeight: Int
  ) throws {
    let sourceCount = try product(sourceWidth, sourceHeight)
    let maximumOutputHeight = try product(sourceHeight, 2)
    let destinationCount = try product(sourceWidth, outputHeight)
    guard sourceWidth > 0, sourceHeight > 0, outputHeight > 0,
      source.count == sourceCount,
      outputHeight <= maximumOutputHeight,
      destination.count == destinationCount
    else { throw ImageCraftError.unsupportedOrCorruptImage }

    for outputRow in 0..<outputHeight {
      let sourceRow = outputRow / 2
      guard sourceRow < sourceHeight else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      let adjacentRow: Int
      let bias: Int
      if outputRow & 1 == 0 {
        adjacentRow = max(0, sourceRow - 1)
        bias = 1
      } else {
        adjacentRow = min(sourceHeight - 1, sourceRow + 1)
        bias = 2
      }
      let sourceOffset = sourceRow * sourceWidth
      let adjacentOffset = adjacentRow * sourceWidth
      let outputOffset = outputRow * sourceWidth
      for column in 0..<sourceWidth {
        let value = Int(source[sourceOffset + column]) * 3
          + Int(source[adjacentOffset + column])
        destination[outputOffset + column] = UInt8((value + bias) >> 2)
      }
    }
  }

  package static func writeH2V1(
    source: UnsafeBufferPointer<UInt8>,
    sourceWidth: Int,
    sourceHeight: Int,
    destination: UnsafeMutableBufferPointer<UInt8>,
    outputWidth: Int
  ) throws {
    let maximumOutputWidth = try product(sourceWidth, 2)
    let sourceCount = try product(sourceWidth, sourceHeight)
    let destinationCount = try product(outputWidth, sourceHeight)
    guard sourceWidth > 1, sourceHeight > 0, outputWidth > 0,
      outputWidth <= maximumOutputWidth,
      source.count == sourceCount,
      destination.count == destinationCount
    else { throw ImageCraftError.unsupportedOrCorruptImage }

    for row in 0..<sourceHeight {
      let sourceOffset = row * sourceWidth
      let outputOffset = row * outputWidth

      @inline(__always)
      func write(_ column: Int, _ value: UInt8) {
        if column < outputWidth {
          destination[outputOffset + column] = value
        }
      }

      let first = Int(source[sourceOffset])
      write(0, UInt8(first))
      write(1, UInt8((first * 3 + Int(source[sourceOffset + 1]) + 2) >> 2))
      if sourceWidth > 2 {
        for column in 1..<(sourceWidth - 1) {
          let current = Int(source[sourceOffset + column]) * 3
          write(column * 2, UInt8(
            (current + Int(source[sourceOffset + column - 1]) + 1) >> 2
          ))
          write(column * 2 + 1, UInt8(
            (current + Int(source[sourceOffset + column + 1]) + 2) >> 2
          ))
        }
      }
      let last = Int(source[sourceOffset + sourceWidth - 1])
      write((sourceWidth - 1) * 2, UInt8(
        (last * 3 + Int(source[sourceOffset + sourceWidth - 2]) + 1) >> 2
      ))
      write((sourceWidth - 1) * 2 + 1, UInt8(last))
    }
  }

  package static func writeH2V2(
    source: UnsafeBufferPointer<UInt8>,
    sourceWidth: Int,
    sourceHeight: Int,
    destination: UnsafeMutableBufferPointer<UInt8>,
    outputWidth: Int,
    outputHeight: Int
  ) throws {
    let maximumOutputWidth = try product(sourceWidth, 2)
    let maximumOutputHeight = try product(sourceHeight, 2)
    let sourceCount = try product(sourceWidth, sourceHeight)
    let destinationCount = try product(outputWidth, outputHeight)
    guard sourceWidth > 2, sourceHeight > 0, outputWidth > 0, outputHeight > 0,
      outputWidth <= maximumOutputWidth,
      outputHeight <= maximumOutputHeight,
      source.count == sourceCount,
      destination.count == destinationCount
    else { throw ImageCraftError.unsupportedOrCorruptImage }

    for outputRow in 0..<outputHeight {
      let sourceRow = outputRow / 2
      guard sourceRow < sourceHeight else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      let adjacentRow = outputRow & 1 == 0
        ? max(0, sourceRow - 1)
        : min(sourceHeight - 1, sourceRow + 1)
      let sourceOffset = sourceRow * sourceWidth
      let adjacentOffset = adjacentRow * sourceWidth

      func verticalSum(_ column: Int) -> Int {
        Int(source[sourceOffset + column]) * 3 + Int(source[adjacentOffset + column])
      }

      let outputOffset = outputRow * outputWidth
      @inline(__always)
      func write(_ column: Int, _ value: UInt8) {
        if column < outputWidth {
          destination[outputOffset + column] = value
        }
      }

      var lastSum = verticalSum(0)
      var currentSum = lastSum
      var nextSum = verticalSum(1)
      write(0, UInt8((currentSum * 4 + 8) >> 4))
      write(1, UInt8((currentSum * 3 + nextSum + 7) >> 4))
      lastSum = currentSum
      currentSum = nextSum

      if sourceWidth > 2 {
        for column in 1..<(sourceWidth - 1) {
          nextSum = verticalSum(column + 1)
          write(column * 2, UInt8((currentSum * 3 + lastSum + 8) >> 4))
          write(column * 2 + 1, UInt8((currentSum * 3 + nextSum + 7) >> 4))
          lastSum = currentSum
          currentSum = nextSum
        }
      }
      write(
        (sourceWidth - 1) * 2,
        UInt8((currentSum * 3 + lastSum + 8) >> 4)
      )
      write((sourceWidth - 1) * 2 + 1, UInt8((currentSum * 4 + 7) >> 4))
    }
  }

  private static func product(_ lhs: Int, _ rhs: Int) throws -> Int {
    guard lhs >= 0, rhs >= 0 else { throw ImageCraftError.unsupportedOrCorruptImage }
    let result = lhs.multipliedReportingOverflow(by: rhs)
    guard !result.overflow else { throw ImageCraftError.unsupportedOrCorruptImage }
    return result.partialValue
  }
}
