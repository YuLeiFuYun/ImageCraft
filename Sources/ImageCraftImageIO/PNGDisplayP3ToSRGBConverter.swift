import Foundation

package enum PNG16OutputColorTransform: Sendable, Equatable {
  case preserve
  case displayP3ToSRGBInGamut
  case iccMatrixTRCToSRGBInGamut(PNGICCMatrixTRCToSRGBTransform)

  func convert(
    red: UInt16,
    green: UInt16,
    blue: UInt16
  ) throws -> (red: UInt16, green: UInt16, blue: UInt16) {
    switch self {
    case .preserve:
      return (red, green, blue)
    case .displayP3ToSRGBInGamut:
      return try PNGDisplayP3ToSRGBConverter.convert(red: red, green: green, blue: blue)
    case .iccMatrixTRCToSRGBInGamut(let transform):
      return try transform.convert(red: red, green: green, blue: blue)
    }
  }
}

package enum PNGDisplayP3ToSRGBConversionError: Error, Equatable, Sendable {
  case targetColorGamutExceeded
}

/// Exact-policy Display-P3 -> sRGB conversion for the first bounded high-depth conversion slice.
///
/// Both spaces use the same sRGB transfer curve and D65 white. The linear-light transform is the
/// exact-rational CSS Color 4 Display-P3->XYZ and XYZ->linear-sRGB matrix product. Rewriting uses the
/// algebraically equivalent difference form so neutral values stay neutral by construction.
///
/// This helper deliberately performs no gamut mapping. If any converted linear-sRGB component lies
/// outside [0, 1], the pixel is outside the qualified slice and conversion fails closed. Alpha is not
/// accepted here and therefore cannot be modified accidentally by the color transform.
package enum PNGDisplayP3ToSRGBConverter {
  private static let redFromRedDelta = Double(3_685_649) / Double(3_008_840)
  private static let greenFromRedDelta = -Double(5_617_931) / Double(133_579_120)
  private static let blueFromRedDelta = -Double(1_323_971) / Double(67_420_360)
  private static let blueFromGreenDelta = -Double(1_514_763) / Double(19_262_960)

  package static func convert(
    red: UInt16,
    green: UInt16,
    blue: UInt16
  ) throws -> (red: UInt16, green: UInt16, blue: UInt16) {
    let linearRed = decodeTransfer(red)
    let linearGreen = decodeTransfer(green)
    let linearBlue = decodeTransfer(blue)

    let targetRed = linearGreen + redFromRedDelta * (linearRed - linearGreen)
    let targetGreen = linearGreen + greenFromRedDelta * (linearRed - linearGreen)
    let targetBlue = linearBlue
      + blueFromRedDelta * (linearRed - linearBlue)
      + blueFromGreenDelta * (linearGreen - linearBlue)

    guard isInUnitInterval(targetRed),
      isInUnitInterval(targetGreen),
      isInUnitInterval(targetBlue)
    else { throw PNGDisplayP3ToSRGBConversionError.targetColorGamutExceeded }

    return (
      encodeTransfer(targetRed),
      encodeTransfer(targetGreen),
      encodeTransfer(targetBlue)
    )
  }

  private static func decodeTransfer(_ sample: UInt16) -> Double {
    let encoded = Double(sample) / 65_535.0
    if encoded <= 0.04045 {
      return encoded / 12.92
    }
    return pow((encoded + 0.055) / 1.055, 2.4)
  }

  private static func encodeTransfer(_ linear: Double) -> UInt16 {
    let encoded: Double
    if linear <= 0.0031308 {
      encoded = 12.92 * linear
    } else {
      encoded = 1.055 * pow(linear, 1.0 / 2.4) - 0.055
    }
    // All qualified values are non-negative, so floor(x + 0.5) is an explicit nearest-code rule.
    let quantized = Int(floor(encoded * 65_535.0 + 0.5))
    return UInt16(quantized)
  }

  private static func isInUnitInterval(_ value: Double) -> Bool {
    value >= 0.0 && value <= 1.0 && value.isFinite
  }
}
