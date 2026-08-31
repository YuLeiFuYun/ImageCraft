import Foundation

enum PNGICCMatrixTRCToSRGBConversionError: Error, Equatable, Sendable {
  case targetColorGamutExceeded
}

/// Deterministic RGB matrix/TRC ICC -> standard sRGB conversion for the first qualified ICC-CMS slice.
///
/// The source matrix and qualified parametric TRC are parsed from the embedded profile itself. The target
/// is the ICC reference sRGB D50 Matrix/TRC space, represented here by the inverse of its published
/// D50-adapted RGB->XYZ matrix. No gamut mapping is performed: any target-linear component outside
/// [0, 1] fails the operation closed. Alpha never enters this transform.
package struct PNGICCMatrixTRCToSRGBTransform: Equatable, Sendable {
  struct Matrix3x3: Equatable, Sendable {
    let m00: Double
    let m01: Double
    let m02: Double
    let m10: Double
    let m11: Double
    let m12: Double
    let m20: Double
    let m21: Double
    let m22: Double
  }

  enum SourceTransferCurve: Equatable, Sendable {
    case curveIdentity
    case curveGamma(gamma: Double)
    case curveSampled(SampledCurve)
    case type0(gamma: Double)
    case type1(ParametricCurveType1)
    case type2(ParametricCurveType2)
    case type3(ParametricCurveType3)
    case type4(ParametricCurveType4)

    func decode(_ encoded: Double) -> Double {
      switch self {
      case .curveIdentity:
        return encoded
      case .curveGamma(let gamma):
        return pow(encoded, gamma)
      case .curveSampled(let curve):
        return curve.decode(encoded)
      case .type0(let gamma):
        return pow(encoded, gamma)
      case .type1(let curve):
        return curve.decode(encoded)
      case .type2(let curve):
        return curve.decode(encoded)
      case .type3(let curve):
        return curve.decode(encoded)
      case .type4(let curve):
        return curve.decode(encoded)
      }
    }
  }

  enum SourceTransferCurves: Equatable, Sendable {
    case shared(SourceTransferCurve)
    case perChannel(
      red: SourceTransferCurve,
      green: SourceTransferCurve,
      blue: SourceTransferCurve
    )

    func decode(
      red: Double,
      green: Double,
      blue: Double
    ) -> (red: Double, green: Double, blue: Double) {
      switch self {
      case .shared(let curve):
        return (
          curve.decode(red),
          curve.decode(green),
          curve.decode(blue)
        )
      case .perChannel(let redCurve, let greenCurve, let blueCurve):
        return (
          redCurve.decode(red),
          greenCurve.decode(green),
          blueCurve.decode(blue)
        )
      }
    }
  }

  struct SampledCurve: Equatable, Sendable {
    let profile: Data
    let samplesOffset: Int
    let count: Int

    func decode(_ encoded: Double) -> Double {
      if encoded <= 0 {
        return Double(sample(at: 0)) / 65_535.0
      }
      if encoded >= 1 {
        return Double(sample(at: count - 1)) / 65_535.0
      }
      let position = encoded * Double(count - 1)
      let lowerIndex = min(count - 2, Int(floor(position)))
      let fraction = position - Double(lowerIndex)
      let lower = Double(sample(at: lowerIndex))
      let upper = Double(sample(at: lowerIndex + 1))
      return (lower + (upper - lower) * fraction) / 65_535.0
    }

    private func sample(at index: Int) -> UInt16 {
      let offset = samplesOffset + index * 2
      return UInt16(profile[offset]) << 8 | UInt16(profile[offset + 1])
    }
  }

  struct ParametricCurveType1: Equatable, Sendable {
    let gamma: Double
    let a: Double
    let b: Double
    let threshold: Double

    func decode(_ encoded: Double) -> Double {
      if encoded >= threshold {
        return pow(a * encoded + b, gamma)
      }
      return 0
    }
  }

  struct ParametricCurveType2: Equatable, Sendable {
    let gamma: Double
    let a: Double
    let b: Double
    let c: Double
    let threshold: Double

    func decode(_ encoded: Double) -> Double {
      if encoded >= threshold {
        return pow(a * encoded + b, gamma) + c
      }
      return c
    }
  }

  struct ParametricCurveType3: Equatable, Sendable {
    let gamma: Double
    let a: Double
    let b: Double
    let c: Double
    let d: Double

    func decode(_ encoded: Double) -> Double {
      if encoded >= d {
        return pow(a * encoded + b, gamma)
      }
      return c * encoded
    }
  }

  struct ParametricCurveType4: Equatable, Sendable {
    let gamma: Double
    let a: Double
    let b: Double
    let c: Double
    let d: Double
    let e: Double
    let f: Double

    func decode(_ encoded: Double) -> Double {
      if encoded >= d {
        return pow(a * encoded + b, gamma) + e
      }
      return c * encoded + f
    }
  }

  let sourceRGBToD50XYZ: Matrix3x3
  let sourceTRCs: SourceTransferCurves

  private static let d50XYZToLinearSRGB = Matrix3x3(
    m00: 3.1339236463378164,
    m01: -1.6169229392738516,
    m02: -0.490733723087733,
    m10: -0.9784210516720576,
    m11: 1.915842665313229,
    m12: 0.03339912699596239,
    m20: 0.07203553396859233,
    m21: -0.22903203517027076,
    m22: 1.4057161576769963
  )

  func convert(
    red: UInt16,
    green: UInt16,
    blue: UInt16
  ) throws -> (red: UInt16, green: UInt16, blue: UInt16) {
    let source = sourceTRCs.decode(
      red: Double(red) / 65_535.0,
      green: Double(green) / 65_535.0,
      blue: Double(blue) / 65_535.0
    )

    let x = sourceRGBToD50XYZ.m00 * source.red
      + sourceRGBToD50XYZ.m01 * source.green
      + sourceRGBToD50XYZ.m02 * source.blue
    let y = sourceRGBToD50XYZ.m10 * source.red
      + sourceRGBToD50XYZ.m11 * source.green
      + sourceRGBToD50XYZ.m12 * source.blue
    let z = sourceRGBToD50XYZ.m20 * source.red
      + sourceRGBToD50XYZ.m21 * source.green
      + sourceRGBToD50XYZ.m22 * source.blue

    let target = Self.d50XYZToLinearSRGB
    let targetRed = target.m00 * x + target.m01 * y + target.m02 * z
    let targetGreen = target.m10 * x + target.m11 * y + target.m12 * z
    let targetBlue = target.m20 * x + target.m21 * y + target.m22 * z
    guard Self.isWithinQuantizedUnitBoundary(targetRed),
      Self.isWithinQuantizedUnitBoundary(targetGreen),
      Self.isWithinQuantizedUnitBoundary(targetBlue)
    else { throw PNGICCMatrixTRCToSRGBConversionError.targetColorGamutExceeded }

    return (
      Self.encodeSRGB(Self.clampUnitBoundary(targetRed)),
      Self.encodeSRGB(Self.clampUnitBoundary(targetGreen)),
      Self.encodeSRGB(Self.clampUnitBoundary(targetBlue))
    )
  }

  private static func encodeSRGB(_ linear: Double) -> UInt16 {
    let encoded: Double
    if linear <= 0.0031308 {
      encoded = 12.92 * linear
    } else {
      encoded = 1.055 * pow(linear, 1.0 / 2.4) - 0.055
    }
    return UInt16(Int(floor(encoded * 65_535.0 + 0.5)))
  }

  // The source colorants are s15Fixed16 values. Propagating at most half an LSB of quantization
  // through three matrix terms and the largest target-inverse row stays below eight fixed-point LSBs.
  // This tolerance exists only to keep encoded endpoints such as white from failing because of ICC
  // matrix quantization; it is orders of magnitude smaller than a real P3->sRGB gamut excursion.
  private static let matrixFixedPointBoundaryTolerance = 8.0 / 65_536.0

  private static func isWithinQuantizedUnitBoundary(_ value: Double) -> Bool {
    value.isFinite
      && value >= -matrixFixedPointBoundaryTolerance
      && value <= 1.0 + matrixFixedPointBoundaryTolerance
  }

  private static func clampUnitBoundary(_ value: Double) -> Double {
    min(1.0, max(0.0, value))
  }
}

extension PNGICCProfileSemantics {
  /// Recognizes the narrow input/display RGB/XYZ matrix/TRC ICC subset qualified for deterministic 16-bit
  /// conversion. The full qualified curve domain remains available when R/G/B share one raw TRC;
  /// profiles with different channel curves qualify when all three are individually-qualified parametric
  /// type-0...type-4 curves; per-channel curves may mix qualified curveType and parametric encodings.
  ///
  /// Source colorants and TRC parameters are taken from the profile rather than matched by profile
  /// name or hash. Profiles carrying a LUT/MPE transform are rejected so a matrix fallback cannot
  /// silently override the profile's authored transform. Display-class profiles retain the stricter
  /// D50-media-white + matrix-reconstructs-white qualification because their admitted encoding is
  /// normalized around display white. Input-class profiles use the authored matrix/TRC directly as the
  /// device-to-XYZ-PCS relative-colorimetric transform: their media white describes the captured medium
  /// and need not equal D50 or device code [1,1,1]. Input media white must still have positive Y, and
  /// every admitted profile keeps a nondegenerate matrix. Every admitted
  /// parametric function 0...4 is finite, weakly nondecreasing, normalized to the
  /// source [0, 1] domain, and needs no source-value clipping. Function 0 requires positive gamma;
  /// functions 1/2 add positive affine scale, an in-domain threshold and normalized high endpoint;
  /// functions 3/4 add a valid breakpoint/power base and near-continuity across the two pieces. curveType
  /// admits count=0 identity, count=1 positive u8Fixed8 forward gamma, and count>1 normalized weakly
  /// nondecreasing UInt16 samples with ICC-defined uniform-domain linear interpolation. Sampled values are
  /// read directly from the retained profile bytes; no second table payload is allocated.
  static func matrixTRCToSRGBTransform(
    _ profile: Data
  ) -> PNGICCMatrixTRCToSRGBTransform? {
    guard profile.count >= 132,
      let profileClass = qualifiedForwardDeviceProfileClass(profile),
      bytesEqual(profile, at: 16, ascii: "RGB "),
      bytesEqual(profile, at: 20, ascii: "XYZ "),
      bytesEqual(profile, at: 36, ascii: "acsp"),
      let tagCount = readUInt32BE(profile, at: 128).flatMap(Int.init(exactly:)),
      tagCount >= 6
    else { return nil }

    let tableBytes = tagCount.multipliedReportingOverflow(by: 12)
    guard !tableBytes.overflow else { return nil }
    let tableEnd = 132.addingReportingOverflow(tableBytes.partialValue)
    guard !tableEnd.overflow, tableEnd.partialValue <= profile.count else { return nil }

    var tags: [String: Range<Int>] = [:]
    for index in 0..<tagCount {
      let entry = 132 + index * 12
      guard let signature = ascii4(profile, at: entry),
        let rawOffset = readUInt32BE(profile, at: entry + 4),
        let rawSize = readUInt32BE(profile, at: entry + 8),
        let offset = Int(exactly: rawOffset),
        let size = Int(exactly: rawSize),
        size > 0
      else { return nil }
      let end = offset.addingReportingOverflow(size)
      guard offset >= tableEnd.partialValue,
        offset % 4 == 0,
        !end.overflow,
        end.partialValue <= profile.count,
        tags[signature] == nil
      else { return nil }
      if isLUTTransformSignature(signature) { return nil }
      tags[signature] = offset..<end.partialValue
    }

    guard let whiteXYZ = parseXYZ(profile, range: tags["wtpt"]),
      let redXYZ = parseXYZ(profile, range: tags["rXYZ"]),
      let greenXYZ = parseXYZ(profile, range: tags["gXYZ"]),
      let blueXYZ = parseXYZ(profile, range: tags["bXYZ"]),
      let redTRC = parseQualifiedTRC(profile, range: tags["rTRC"]),
      let greenTRC = parseQualifiedTRC(profile, range: tags["gTRC"]),
      let blueTRC = parseQualifiedTRC(profile, range: tags["bTRC"])
    else { return nil }

    let sourceTRCs: PNGICCMatrixTRCToSRGBTransform.SourceTransferCurves
    if trcFixedMatches(profile, greenTRC.fixed, redTRC.fixed),
      trcFixedMatches(profile, blueTRC.fixed, redTRC.fixed)
    {
      sourceTRCs = .shared(redTRC.curve)
    } else {
      sourceTRCs = .perChannel(
        red: redTRC.curve,
        green: greenTRC.curve,
        blue: blueTRC.curve
      )
    }

    let whiteSemanticsQualified: Bool
    switch profileClass {
    case .display:
      whiteSemanticsQualified = fixedXYZ(
        whiteXYZ.fixed,
        isWithin: matrixWhiteFixedTolerance,
        of: Self.iccD50Fixed
      ) && matrixReconstructsWhite(
        red: redXYZ.fixed,
        green: greenXYZ.fixed,
        blue: blueXYZ.fixed,
        white: whiteXYZ.fixed
      )
    case .input:
      whiteSemanticsQualified = inputMediaWhiteIsPlausible(whiteXYZ.fixed)
    }

    guard whiteSemanticsQualified,
      matrixIsNondegenerate(red: redXYZ.value, green: greenXYZ.value, blue: blueXYZ.value)
    else { return nil }

    return PNGICCMatrixTRCToSRGBTransform(
      sourceRGBToD50XYZ: .init(
        m00: redXYZ.value.0,
        m01: greenXYZ.value.0,
        m02: blueXYZ.value.0,
        m10: redXYZ.value.1,
        m11: greenXYZ.value.1,
        m12: blueXYZ.value.1,
        m20: redXYZ.value.2,
        m21: greenXYZ.value.2,
        m22: blueXYZ.value.2
      ),
      sourceTRCs: sourceTRCs
    )
  }

  private enum QualifiedForwardDeviceProfileClass {
    case display
    case input
  }

  private static func qualifiedForwardDeviceProfileClass(
    _ profile: Data
  ) -> QualifiedForwardDeviceProfileClass? {
    if bytesEqual(profile, at: 12, ascii: "mntr") { return .display }
    if bytesEqual(profile, at: 12, ascii: "scnr") { return .input }
    return nil
  }

  private static let iccD50Fixed: (Int32, Int32, Int32) = (63_190, 65_536, 54_061)
  private static let matrixWhiteFixedTolerance: Int64 = 2
  private static let curveBoundaryTolerance = 8.0 / 65_536.0

  private static func fixedXYZ(
    _ value: (Int32, Int32, Int32),
    isWithin tolerance: Int64,
    of expected: (Int32, Int32, Int32)
  ) -> Bool {
    abs(Int64(value.0) - Int64(expected.0)) <= tolerance
      && abs(Int64(value.1) - Int64(expected.1)) <= tolerance
      && abs(Int64(value.2) - Int64(expected.2)) <= tolerance
  }

  private static func inputMediaWhiteIsPlausible(
    _ value: (Int32, Int32, Int32)
  ) -> Bool {
    value.0 >= 0 && value.1 > 0 && value.2 >= 0
  }

  private static func matrixReconstructsWhite(
    red: (Int32, Int32, Int32),
    green: (Int32, Int32, Int32),
    blue: (Int32, Int32, Int32),
    white: (Int32, Int32, Int32)
  ) -> Bool {
    let channels = [
      (red.0, green.0, blue.0, white.0),
      (red.1, green.1, blue.1, white.1),
      (red.2, green.2, blue.2, white.2),
    ]
    return channels.allSatisfy { red, green, blue, white in
      let reconstructed = Int64(red) + Int64(green) + Int64(blue)
      return abs(reconstructed - Int64(white)) <= matrixWhiteFixedTolerance
    }
  }

  private static func matrixIsNondegenerate(
    red: (Double, Double, Double),
    green: (Double, Double, Double),
    blue: (Double, Double, Double)
  ) -> Bool {
    let m00 = red.0
    let m01 = green.0
    let m02 = blue.0
    let m10 = red.1
    let m11 = green.1
    let m12 = blue.1
    let m20 = red.2
    let m21 = green.2
    let m22 = blue.2
    let determinant = m00 * (m11 * m22 - m12 * m21)
      - m01 * (m10 * m22 - m12 * m20)
      + m02 * (m10 * m21 - m11 * m20)
    return determinant.isFinite && abs(determinant) > 1e-8
  }

  private static func type1CurveIsQualified(
    _ curve: (Double, Double, Double)
  ) -> Bool {
    let (gamma, a, b) = curve
    guard gamma.isFinite, a.isFinite, b.isFinite,
      gamma > 0,
      a > 0
    else { return false }

    let threshold = -b / a
    let baseAtOne = a + b
    guard threshold.isFinite,
      threshold >= 0,
      threshold <= 1,
      baseAtOne >= 0
    else { return false }
    let end = pow(baseAtOne, gamma)
    return end.isFinite && abs(end - 1) <= curveBoundaryTolerance
  }

  private static func type2CurveIsQualified(
    _ curve: (Double, Double, Double, Double)
  ) -> Bool {
    let (gamma, a, b, c) = curve
    guard gamma.isFinite, a.isFinite, b.isFinite, c.isFinite,
      gamma > 0,
      a > 0,
      c >= 0,
      c <= 1
    else { return false }

    let threshold = -b / a
    let baseAtOne = a + b
    guard threshold.isFinite,
      threshold >= 0,
      threshold <= 1,
      baseAtOne >= 0
    else { return false }
    let end = pow(baseAtOne, gamma) + c
    return end.isFinite && abs(end - 1) <= curveBoundaryTolerance
  }

  private static func type3CurveIsQualified(
    _ curve: (Double, Double, Double, Double, Double)
  ) -> Bool {
    let (gamma, a, b, c, d) = curve
    guard gamma.isFinite, a.isFinite, b.isFinite, c.isFinite, d.isFinite,
      gamma > 0,
      a > 0,
      c >= 0,
      d >= 0,
      d <= 1
    else { return false }

    let baseAtBoundary = a * d + b
    let baseAtOne = a + b
    guard baseAtBoundary >= 0, baseAtOne >= 0 else { return false }
    let lowerAtBoundary = c * d
    let upperAtBoundary = pow(baseAtBoundary, gamma)
    let start = d == 0 ? pow(b, gamma) : 0
    let end = pow(baseAtOne, gamma)
    return lowerAtBoundary.isFinite
      && upperAtBoundary.isFinite
      && start.isFinite
      && end.isFinite
      && abs(lowerAtBoundary - upperAtBoundary) <= curveBoundaryTolerance
      && abs(start) <= curveBoundaryTolerance
      && abs(end - 1) <= curveBoundaryTolerance
  }

  private static func type4CurveIsQualified(
    _ curve: (Double, Double, Double, Double, Double, Double, Double)
  ) -> Bool {
    let (gamma, a, b, c, d, e, f) = curve
    guard gamma.isFinite, a.isFinite, b.isFinite, c.isFinite, d.isFinite,
      e.isFinite, f.isFinite,
      gamma > 0,
      a > 0,
      c >= 0,
      d >= 0,
      d <= 1
    else { return false }

    let baseAtBoundary = a * d + b
    let baseAtOne = a + b
    guard baseAtBoundary >= 0, baseAtOne >= 0 else { return false }
    let lowerAtBoundary = c * d + f
    let upperAtBoundary = pow(baseAtBoundary, gamma) + e
    let start = d == 0 ? pow(b, gamma) + e : f
    let end = pow(baseAtOne, gamma) + e
    return lowerAtBoundary.isFinite
      && upperAtBoundary.isFinite
      && start.isFinite
      && end.isFinite
      && abs(lowerAtBoundary - upperAtBoundary) <= curveBoundaryTolerance
      && abs(start) <= curveBoundaryTolerance
      && abs(end - 1) <= curveBoundaryTolerance
  }

  private static func parseXYZ(
    _ profile: Data,
    range: Range<Int>?
  ) -> (fixed: (Int32, Int32, Int32), value: (Double, Double, Double))? {
    guard let range, range.count == 20,
      bytesEqual(profile, at: range.lowerBound, ascii: "XYZ "),
      bytesAreZero(profile, range: (range.lowerBound + 4)..<(range.lowerBound + 8)),
      let x = readInt32BE(profile, at: range.lowerBound + 8),
      let y = readInt32BE(profile, at: range.lowerBound + 12),
      let z = readInt32BE(profile, at: range.lowerBound + 16)
    else { return nil }
    return ((x, y, z), (fixed16(x), fixed16(y), fixed16(z)))
  }

  private enum ParsedTRCFixed: Equatable {
    case curveIdentity
    case curveGamma(raw: UInt16)
    case curveSampled(samplesRange: Range<Int>, count: Int)
    case type0(gamma: Int32)
    case type1(gamma: Int32, a: Int32, b: Int32)
    case type2(gamma: Int32, a: Int32, b: Int32, c: Int32)
    case type3(gamma: Int32, a: Int32, b: Int32, c: Int32, d: Int32)
    case type4(gamma: Int32, a: Int32, b: Int32, c: Int32, d: Int32, e: Int32, f: Int32)
  }

  private struct ParsedTRC {
    let fixed: ParsedTRCFixed
    let curve: PNGICCMatrixTRCToSRGBTransform.SourceTransferCurve
  }

  private static func trcFixedMatches(
    _ profile: Data,
    _ lhs: ParsedTRCFixed,
    _ rhs: ParsedTRCFixed
  ) -> Bool {
    switch (lhs, rhs) {
    case let (.curveSampled(lhsRange, lhsCount), .curveSampled(rhsRange, rhsCount)):
      guard lhsCount == rhsCount, lhsRange.count == rhsRange.count else { return false }
      for offset in 0..<lhsRange.count {
        if profile[lhsRange.lowerBound + offset] != profile[rhsRange.lowerBound + offset] {
          return false
        }
      }
      return true
    default:
      return lhs == rhs
    }
  }

  private static func parseQualifiedTRC(
    _ profile: Data,
    range: Range<Int>?
  ) -> ParsedTRC? {
    guard let range, range.count >= 12,
      bytesAreZero(profile, range: (range.lowerBound + 4)..<(range.lowerBound + 8))
    else { return nil }

    if bytesEqual(profile, at: range.lowerBound, ascii: "curv") {
      guard let rawCount = readUInt32BE(profile, at: range.lowerBound + 8) else { return nil }
      if rawCount == 0 {
        guard range.count == 12 else { return nil }
        return ParsedTRC(fixed: .curveIdentity, curve: .curveIdentity)
      }
      if rawCount == 1 {
        guard range.count == 14,
          let gammaRaw = readUInt16BE(profile, at: range.lowerBound + 12),
          gammaRaw > 0
        else { return nil }
        return ParsedTRC(
          fixed: .curveGamma(raw: gammaRaw),
          curve: .curveGamma(gamma: Double(gammaRaw) / 256.0)
        )
      }

      guard let count = Int(exactly: rawCount), count > 1 else { return nil }
      let sampleBytes = count.multipliedReportingOverflow(by: 2)
      guard !sampleBytes.overflow else { return nil }
      let expectedByteCount = 12.addingReportingOverflow(sampleBytes.partialValue)
      guard !expectedByteCount.overflow, range.count == expectedByteCount.partialValue else { return nil }
      let samplesOffset = range.lowerBound + 12
      guard readUInt16BE(profile, at: samplesOffset) == 0,
        readUInt16BE(profile, at: samplesOffset + (count - 1) * 2) == UInt16.max
      else { return nil }
      var previous = UInt16.zero
      for index in 0..<count {
        guard let sample = readUInt16BE(profile, at: samplesOffset + index * 2),
          sample >= previous
        else { return nil }
        previous = sample
      }
      let samplesRange = samplesOffset..<(samplesOffset + sampleBytes.partialValue)
      return ParsedTRC(
        fixed: .curveSampled(samplesRange: samplesRange, count: count),
        curve: .curveSampled(
          .init(profile: profile, samplesOffset: samplesOffset, count: count)
        )
      )
    }

    guard range.count >= 16,
      bytesEqual(profile, at: range.lowerBound, ascii: "para"),
      profile[range.lowerBound + 8] == 0,
      profile[range.lowerBound + 10] == 0,
      profile[range.lowerBound + 11] == 0
    else { return nil }

    switch profile[range.lowerBound + 9] {
    case 0:
      guard range.count == 16,
        let gamma = readInt32BE(profile, at: range.lowerBound + 12),
        gamma > 0
      else { return nil }
      return ParsedTRC(
        fixed: .type0(gamma: gamma),
        curve: .type0(gamma: fixed16(gamma))
      )
    case 1:
      guard range.count == 24,
        let gamma = readInt32BE(profile, at: range.lowerBound + 12),
        let a = readInt32BE(profile, at: range.lowerBound + 16),
        let b = readInt32BE(profile, at: range.lowerBound + 20)
      else { return nil }
      let value = (fixed16(gamma), fixed16(a), fixed16(b))
      guard type1CurveIsQualified(value) else { return nil }
      return ParsedTRC(
        fixed: .type1(gamma: gamma, a: a, b: b),
        curve: .type1(
          .init(
            gamma: value.0,
            a: value.1,
            b: value.2,
            threshold: -value.2 / value.1
          )
        )
      )
    case 2:
      guard range.count == 28,
        let gamma = readInt32BE(profile, at: range.lowerBound + 12),
        let a = readInt32BE(profile, at: range.lowerBound + 16),
        let b = readInt32BE(profile, at: range.lowerBound + 20),
        let c = readInt32BE(profile, at: range.lowerBound + 24)
      else { return nil }
      let value = (fixed16(gamma), fixed16(a), fixed16(b), fixed16(c))
      guard type2CurveIsQualified(value) else { return nil }
      return ParsedTRC(
        fixed: .type2(gamma: gamma, a: a, b: b, c: c),
        curve: .type2(
          .init(
            gamma: value.0,
            a: value.1,
            b: value.2,
            c: value.3,
            threshold: -value.2 / value.1
          )
        )
      )
    case 3:
      guard range.count == 32,
        let gamma = readInt32BE(profile, at: range.lowerBound + 12),
        let a = readInt32BE(profile, at: range.lowerBound + 16),
        let b = readInt32BE(profile, at: range.lowerBound + 20),
        let c = readInt32BE(profile, at: range.lowerBound + 24),
        let d = readInt32BE(profile, at: range.lowerBound + 28)
      else { return nil }
      let value = (fixed16(gamma), fixed16(a), fixed16(b), fixed16(c), fixed16(d))
      guard type3CurveIsQualified(value) else { return nil }
      return ParsedTRC(
        fixed: .type3(gamma: gamma, a: a, b: b, c: c, d: d),
        curve: .type3(
          .init(
            gamma: value.0,
            a: value.1,
            b: value.2,
            c: value.3,
            d: value.4
          )
        )
      )
    case 4:
      guard range.count == 40,
        let gamma = readInt32BE(profile, at: range.lowerBound + 12),
        let a = readInt32BE(profile, at: range.lowerBound + 16),
        let b = readInt32BE(profile, at: range.lowerBound + 20),
        let c = readInt32BE(profile, at: range.lowerBound + 24),
        let d = readInt32BE(profile, at: range.lowerBound + 28),
        let e = readInt32BE(profile, at: range.lowerBound + 32),
        let f = readInt32BE(profile, at: range.lowerBound + 36)
      else { return nil }
      let value = (
        fixed16(gamma), fixed16(a), fixed16(b), fixed16(c),
        fixed16(d), fixed16(e), fixed16(f)
      )
      guard type4CurveIsQualified(value) else { return nil }
      return ParsedTRC(
        fixed: .type4(gamma: gamma, a: a, b: b, c: c, d: d, e: e, f: f),
        curve: .type4(
          .init(
            gamma: value.0,
            a: value.1,
            b: value.2,
            c: value.3,
            d: value.4,
            e: value.5,
            f: value.6
          )
        )
      )
    default:
      return nil
    }
  }

  private static func fixed16(_ value: Int32) -> Double {
    Double(value) / 65_536.0
  }

  private static func readUInt16BE(_ data: Data, at offset: Int) -> UInt16? {
    guard offset >= 0, offset + 2 <= data.count else { return nil }
    return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
  }

  private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= data.count else { return nil }
    return UInt32(data[offset]) << 24
      | UInt32(data[offset + 1]) << 16
      | UInt32(data[offset + 2]) << 8
      | UInt32(data[offset + 3])
  }

  private static func readInt32BE(_ data: Data, at offset: Int) -> Int32? {
    readUInt32BE(data, at: offset).map(Int32.init(bitPattern:))
  }

  private static func ascii4(_ data: Data, at offset: Int) -> String? {
    guard offset >= 0, offset + 4 <= data.count else { return nil }
    return String(bytes: data[offset..<(offset + 4)], encoding: .ascii)
  }

  private static func bytesEqual(_ data: Data, at offset: Int, ascii: String) -> Bool {
    let bytes = Array(ascii.utf8)
    guard offset >= 0, offset + bytes.count <= data.count else { return false }
    for (index, byte) in bytes.enumerated() where data[offset + index] != byte {
      return false
    }
    return true
  }

  private static func bytesAreZero(_ data: Data, range: Range<Int>) -> Bool {
    guard range.lowerBound >= 0, range.upperBound <= data.count else { return false }
    return data[range].allSatisfy { $0 == 0 }
  }

  private static func isLUTTransformSignature(_ signature: String) -> Bool {
    signature.hasPrefix("A2B")
      || signature.hasPrefix("B2A")
      || signature.hasPrefix("D2B")
      || signature.hasPrefix("B2D")
  }
}
