import Foundation

/// Shared package-only source-color classification for independent JPEG slices that explicitly
/// qualify JFIF YCbCr rather than attempting generic JPEG color-model inference.
package enum JPEGIndependentJFIFColorAuthority {
  /// Returns `nil` for an APP0 payload that is not the JFIF authority marker, `true` for the
  /// structurally qualified JFIF 1.00...1.02 form, and `false` when the `JFIF\0` identifier is
  /// present but its fixed fields or thumbnail extent cannot prove that authority.
  package static func jfifAPP0IsStructurallyQualified(
    _ bytes: UnsafeBufferPointer<UInt8>,
    payload: Range<Int>
  ) -> Bool? {
    guard payload.lowerBound >= 0,
      payload.upperBound <= bytes.count,
      payload.count >= 5
    else { return nil }
    let start = payload.lowerBound
    let isJFIF = bytes[start] == 0x4A
      && bytes[start + 1] == 0x46
      && bytes[start + 2] == 0x49
      && bytes[start + 3] == 0x46
      && bytes[start + 4] == 0x00
    guard isJFIF else { return nil }
    guard payload.count >= 14 else { return false }

    return jfifHeaderIsStructurallyQualified(
      bytes,
      header: payload.lowerBound..<(payload.lowerBound + 14),
      declaredPayloadByteCount: payload.count
    )
  }

  /// Streaming form of the JFIF APP0 authority check. `header` must contain exactly the first
  /// fourteen payload bytes; thumbnail pixels need not be retained because their dimensions and
  /// the declared APP0 payload length prove their complete extent.
  package static func jfifHeaderIsStructurallyQualified(
    _ bytes: UnsafeBufferPointer<UInt8>,
    header: Range<Int>,
    declaredPayloadByteCount: Int
  ) -> Bool {
    guard header.lowerBound >= 0,
      header.upperBound <= bytes.count,
      header.count == 14,
      declaredPayloadByteCount >= 14
    else { return false }
    let start = header.lowerBound
    guard bytes[start] == 0x4A,
      bytes[start + 1] == 0x46,
      bytes[start + 2] == 0x49,
      bytes[start + 3] == 0x46,
      bytes[start + 4] == 0x00
    else { return false }

    let majorVersion = bytes[start + 5]
    let minorVersion = bytes[start + 6]
    let units = bytes[start + 7]
    let xDensity = Int(bytes[start + 8]) << 8 | Int(bytes[start + 9])
    let yDensity = Int(bytes[start + 10]) << 8 | Int(bytes[start + 11])
    let xThumbnail = Int(bytes[start + 12])
    let yThumbnail = Int(bytes[start + 13])
    guard majorVersion == 1,
      minorVersion <= 2,
      units <= 2,
      xDensity > 0,
      yDensity > 0
    else { return false }

    let thumbnailPixels = xThumbnail.multipliedReportingOverflow(by: yThumbnail)
    guard !thumbnailPixels.overflow else { return false }
    let thumbnailBytes = thumbnailPixels.partialValue.multipliedReportingOverflow(by: 3)
    guard !thumbnailBytes.overflow else { return false }
    let expectedPayloadBytes = 14.addingReportingOverflow(thumbnailBytes.partialValue)
    guard !expectedPayloadBytes.overflow else { return false }
    return declaredPayloadByteCount == expectedPayloadBytes.partialValue
  }

  /// Returns `nil` for an APP14 payload that is not Adobe color authority, `true` for the exact
  /// qualified Adobe YCbCr form, and `false` for an Adobe authority that conflicts with or falls
  /// outside the JFIF YCbCr slice.
  package static func adobeAPP14IsQualifiedYCbCr(
    _ bytes: UnsafeBufferPointer<UInt8>,
    payload: Range<Int>
  ) -> Bool? {
    guard payload.lowerBound >= 0,
      payload.upperBound <= bytes.count,
      payload.count >= 5
    else { return nil }
    let start = payload.lowerBound
    let isAdobe = bytes[start] == 0x41
      && bytes[start + 1] == 0x64
      && bytes[start + 2] == 0x6F
      && bytes[start + 3] == 0x62
      && bytes[start + 4] == 0x65
    guard isAdobe else { return nil }
    guard payload.count == 12 else { return false }
    return bytes[start + 11] == 1
  }
}
