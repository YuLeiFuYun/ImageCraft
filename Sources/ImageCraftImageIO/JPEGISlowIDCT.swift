import Foundation
import ImageCraftCore

/// ImageCraft-owned 8x8 integer inverse-DCT primitive for the narrow 8-bit JPEG research seam.
///
/// Arithmetic follows the IJG "slow/accurate" Loeffler fixed-point path with CONST_BITS=13 and
/// PASS1_BITS=2. The 64-entry Int32 workspace and destination storage are caller-owned, so the
/// operation has no hidden cardinality-dependent allocation. The current qualification domain
/// requires every dequantized coefficient to fit Int16, matching the pinned reference's 8-bit
/// multiply assumptions; inputs outside that domain fail closed instead of relying on signed
/// overflow behavior.
package enum JPEGISlowIDCT {
  private static let constBits = 13
  private static let pass1Bits = 2

  private static let fix0298631336: Int64 = 2_446
  private static let fix0390180644: Int64 = 3_196
  private static let fix0541196100: Int64 = 4_433
  private static let fix0765366865: Int64 = 6_270
  private static let fix0899976223: Int64 = 7_373
  private static let fix1175875602: Int64 = 9_633
  private static let fix1501321110: Int64 = 12_299
  private static let fix1847759065: Int64 = 15_137
  private static let fix1961570560: Int64 = 16_069
  private static let fix2053119869: Int64 = 16_819
  private static let fix2562915447: Int64 = 20_995
  private static let fix3072711026: Int64 = 25_172

  package static func writeBlock(
    coefficients: UnsafeBufferPointer<Int16>,
    quantization: UnsafeBufferPointer<UInt16>,
    workspace: UnsafeMutableBufferPointer<Int32>,
    destination: UnsafeMutableBufferPointer<UInt8>
  ) throws {
    guard destination.count == 64 else { throw ImageCraftError.unsupportedOrCorruptImage }
    try writeBlockClipped(
      coefficients: coefficients,
      quantization: quantization,
      workspace: workspace,
      destination: destination,
      destinationRowStride: 8,
      writeWidth: 8,
      writeHeight: 8
    )
  }

  package static func writeBlockClipped(
    coefficients: UnsafeBufferPointer<Int16>,
    quantization: UnsafeBufferPointer<UInt16>,
    workspace: UnsafeMutableBufferPointer<Int32>,
    destination: UnsafeMutableBufferPointer<UInt8>,
    destinationRowStride: Int,
    writeWidth: Int,
    writeHeight: Int
  ) throws {
    guard coefficients.count == 64, quantization.count == 64, workspace.count == 64,
      (1...8).contains(writeWidth), (1...8).contains(writeHeight),
      destinationRowStride >= writeWidth
    else { throw ImageCraftError.unsupportedOrCorruptImage }
    let required = (writeHeight - 1).multipliedReportingOverflow(by: destinationRowStride)
    guard !required.overflow else { throw ImageCraftError.unsupportedOrCorruptImage }
    let requiredCount = required.partialValue.addingReportingOverflow(writeWidth)
    guard !requiredCount.overflow, requiredCount.partialValue <= destination.count else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }

    @inline(__always)
    func store(row: Int, column: Int, value: UInt8) {
      if row < writeHeight, column < writeWidth {
        destination[row * destinationRowStride + column] = value
      }
    }

    for index in 0..<64 {
      let quant = Int64(quantization[index])
      guard (1...255).contains(quant) else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      let value = Int64(coefficients[index]) * quant
      guard value >= Int64(Int16.min), value <= Int64(Int16.max) else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
    }

    @inline(__always)
    func dequantized(_ index: Int) -> Int64 {
      Int64(coefficients[index]) * Int64(quantization[index])
    }

    // Pass 1: columns.
    for column in 0..<8 {
      if (1..<8).allSatisfy({ coefficients[$0 * 8 + column] == 0 }) {
        let dc = dequantized(column) << pass1Bits
        let stored = try int32(dc)
        for row in 0..<8 {
          workspace[row * 8 + column] = stored
        }
        continue
      }

      var z2 = dequantized(2 * 8 + column)
      var z3 = dequantized(6 * 8 + column)
      var z1 = multiply(z2 + z3, fix0541196100)
      var tmp2 = z1 + multiply(z3, -fix1847759065)
      var tmp3 = z1 + multiply(z2, fix0765366865)

      z2 = dequantized(column)
      z3 = dequantized(4 * 8 + column)
      var tmp0 = (z2 + z3) << constBits
      var tmp1 = (z2 - z3) << constBits

      let tmp10 = tmp0 + tmp3
      let tmp13 = tmp0 - tmp3
      let tmp11 = tmp1 + tmp2
      let tmp12 = tmp1 - tmp2

      tmp0 = dequantized(7 * 8 + column)
      tmp1 = dequantized(5 * 8 + column)
      tmp2 = dequantized(3 * 8 + column)
      tmp3 = dequantized(1 * 8 + column)

      z1 = tmp0 + tmp3
      z2 = tmp1 + tmp2
      z3 = tmp0 + tmp2
      var z4 = tmp1 + tmp3
      let z5 = multiply(z3 + z4, fix1175875602)

      tmp0 = multiply(tmp0, fix0298631336)
      tmp1 = multiply(tmp1, fix2053119869)
      tmp2 = multiply(tmp2, fix3072711026)
      tmp3 = multiply(tmp3, fix1501321110)
      z1 = multiply(z1, -fix0899976223)
      z2 = multiply(z2, -fix2562915447)
      z3 = multiply(z3, -fix1961570560) + z5
      z4 = multiply(z4, -fix0390180644) + z5

      tmp0 += z1 + z3
      tmp1 += z2 + z4
      tmp2 += z2 + z3
      tmp3 += z1 + z4

      workspace[0 * 8 + column] = try int32(descale(tmp10 + tmp3, constBits - pass1Bits))
      workspace[7 * 8 + column] = try int32(descale(tmp10 - tmp3, constBits - pass1Bits))
      workspace[1 * 8 + column] = try int32(descale(tmp11 + tmp2, constBits - pass1Bits))
      workspace[6 * 8 + column] = try int32(descale(tmp11 - tmp2, constBits - pass1Bits))
      workspace[2 * 8 + column] = try int32(descale(tmp12 + tmp1, constBits - pass1Bits))
      workspace[5 * 8 + column] = try int32(descale(tmp12 - tmp1, constBits - pass1Bits))
      workspace[3 * 8 + column] = try int32(descale(tmp13 + tmp0, constBits - pass1Bits))
      workspace[4 * 8 + column] = try int32(descale(tmp13 - tmp0, constBits - pass1Bits))
    }

    // Pass 2: rows.
    for row in 0..<8 {
      let base = row * 8
      if (1..<8).allSatisfy({ workspace[base + $0] == 0 }) {
        let sample = rangeLimit(descale(Int64(workspace[base]), pass1Bits + 3))
        if row < writeHeight {
          for column in 0..<writeWidth {
            store(row: row, column: column, value: sample)
          }
        }
        continue
      }

      var z2 = Int64(workspace[base + 2])
      var z3 = Int64(workspace[base + 6])
      var z1 = multiply(z2 + z3, fix0541196100)
      var tmp2 = z1 + multiply(z3, -fix1847759065)
      var tmp3 = z1 + multiply(z2, fix0765366865)

      var tmp0 = (Int64(workspace[base]) + Int64(workspace[base + 4])) << constBits
      var tmp1 = (Int64(workspace[base]) - Int64(workspace[base + 4])) << constBits

      let tmp10 = tmp0 + tmp3
      let tmp13 = tmp0 - tmp3
      let tmp11 = tmp1 + tmp2
      let tmp12 = tmp1 - tmp2

      tmp0 = Int64(workspace[base + 7])
      tmp1 = Int64(workspace[base + 5])
      tmp2 = Int64(workspace[base + 3])
      tmp3 = Int64(workspace[base + 1])

      z1 = tmp0 + tmp3
      z2 = tmp1 + tmp2
      z3 = tmp0 + tmp2
      var z4 = tmp1 + tmp3
      let z5 = multiply(z3 + z4, fix1175875602)

      tmp0 = multiply(tmp0, fix0298631336)
      tmp1 = multiply(tmp1, fix2053119869)
      tmp2 = multiply(tmp2, fix3072711026)
      tmp3 = multiply(tmp3, fix1501321110)
      z1 = multiply(z1, -fix0899976223)
      z2 = multiply(z2, -fix2562915447)
      z3 = multiply(z3, -fix1961570560) + z5
      z4 = multiply(z4, -fix0390180644) + z5

      tmp0 += z1 + z3
      tmp1 += z2 + z4
      tmp2 += z2 + z3
      tmp3 += z1 + z4

      let shift = constBits + pass1Bits + 3
      store(row: row, column: 0, value: rangeLimit(descale(tmp10 + tmp3, shift)))
      store(row: row, column: 7, value: rangeLimit(descale(tmp10 - tmp3, shift)))
      store(row: row, column: 1, value: rangeLimit(descale(tmp11 + tmp2, shift)))
      store(row: row, column: 6, value: rangeLimit(descale(tmp11 - tmp2, shift)))
      store(row: row, column: 2, value: rangeLimit(descale(tmp12 + tmp1, shift)))
      store(row: row, column: 5, value: rangeLimit(descale(tmp12 - tmp1, shift)))
      store(row: row, column: 3, value: rangeLimit(descale(tmp13 + tmp0, shift)))
      store(row: row, column: 4, value: rangeLimit(descale(tmp13 - tmp0, shift)))
    }
  }

  @inline(__always)
  private static func multiply(_ value: Int64, _ constant: Int64) -> Int64 {
    value * constant
  }

  @inline(__always)
  private static func descale(_ value: Int64, _ bits: Int) -> Int64 {
    (value + (Int64(1) << (bits - 1))) >> bits
  }

  @inline(__always)
  private static func rangeLimit(_ value: Int64) -> UInt8 {
    let masked = Int(value & 1_023)
    if masked < 128 { return UInt8(masked + 128) }
    if masked < 512 { return 255 }
    if masked < 896 { return 0 }
    return UInt8(masked - 896)
  }

  @inline(__always)
  private static func int32(_ value: Int64) throws -> Int32 {
    guard value >= Int64(Int32.min), value <= Int64(Int32.max) else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    return Int32(value)
  }
}
