import Foundation
import ImageCraftCore

/// Package-only vertical chroma reconstruction experiment.
///
/// This is deliberately not wired into any production JPEG decoder. It encodes the fixed
/// source-truth policy qualified by `JPEGChromaAdaptivePolicy/v3`: preserve the existing centered
/// 3/4-current + 1/4-adjacent interpolation unless the crossed low-resolution interval is a strong
/// local gradient outlier. An interval is considered an edge only when its absolute gradient is
/// strictly greater than twice the larger same-side neighboring gradient.
///
/// The policy is retained as an experimental witness, not a production candidate. A phase-shifted
/// two-row stripe is a known falsifier: two mixed low-resolution plateau samples make the local
/// gradient test look like a persistent edge even though centered interpolation has lower
/// source-truth RMSE. Any production successor must add at least a wider normal-direction
/// persistence condition; see `testPhaseShiftedTwoRowStripeFalsifiesV3Rule`.
package enum JPEGAdaptiveChromaReconstruction {
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
    guard sourceWidth > 0,
      sourceHeight > 0,
      outputHeight > 0,
      source.count == sourceCount,
      outputHeight <= maximumOutputHeight,
      destination.count == destinationCount
    else { throw ImageCraftError.unsupportedOrCorruptImage }

    @inline(__always)
    func sample(row: Int, column: Int) -> Int {
      Int(source[row * sourceWidth + column])
    }

    @inline(__always)
    func isGradientOutlier(
      firstRow: Int,
      secondRow: Int,
      column: Int
    ) -> Bool {
      let low = min(firstRow, secondRow)
      let high = max(firstRow, secondRow)
      let cross = abs(sample(row: high, column: column) - sample(row: low, column: column))
      let left = low > 0
        ? abs(sample(row: low, column: column) - sample(row: low - 1, column: column))
        : cross
      let right = high + 1 < sourceHeight
        ? abs(sample(row: high + 1, column: column) - sample(row: high, column: column))
        : cross
      return cross > 2 * max(left, right)
    }

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
      let outputOffset = outputRow * sourceWidth
      for column in 0..<sourceWidth {
        let current = sample(row: sourceRow, column: column)
        if adjacentRow != sourceRow,
          isGradientOutlier(firstRow: sourceRow, secondRow: adjacentRow, column: column)
        {
          destination[outputOffset + column] = UInt8(current)
        } else {
          let adjacent = sample(row: adjacentRow, column: column)
          destination[outputOffset + column] = UInt8((current * 3 + adjacent + bias) >> 2)
        }
      }
    }
  }

  private static func product(_ lhs: Int, _ rhs: Int) throws -> Int {
    guard lhs >= 0, rhs >= 0 else { throw ImageCraftError.unsupportedOrCorruptImage }
    let result = lhs.multipliedReportingOverflow(by: rhs)
    guard !result.overflow else { throw ImageCraftError.unsupportedOrCorruptImage }
    return result.partialValue
  }
}
