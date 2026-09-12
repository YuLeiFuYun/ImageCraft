import Foundation
import ImageCraftCore
import XCTest

@testable import ImageCraftImageIO

final class JPEGIndependentBaseline422DecoderTests: XCTestCase {
  private let exactStateBytes = 2_176
  private let exactTransferBytes = 897
  private let exactOperationBytes = 3_073

  func testStatePlanAndPixelsMatchIndependentLibjpegOracle() throws {
    let source = try fixture("baseline422-q75-23x13.jpg")
    let expected = try fixture("baseline422-q75-23x13-libjpeg.rgb")
    XCTAssertEqual(source.count, 921)
    XCTAssertEqual(expected.count, exactTransferBytes)

    let statePlan = try JPEGIndependentBaseline422StatePlan.inspect(source)
    XCTAssertEqual(statePlan.width, 23)
    XCTAssertEqual(statePlan.height, 13)
    XCTAssertEqual(statePlan.chromaWidth, 12)
    XCTAssertEqual(statePlan.yRowStrideBytes, 64)
    XCTAssertEqual(statePlan.chromaRowStrideBytes, 64)
    XCTAssertEqual(statePlan.yStripBytes, 512)
    XCTAssertEqual(statePlan.chromaStripBytesPerComponent, 512)
    XCTAssertEqual(statePlan.reconstructedChromaRowBytesPerComponent, 64)
    XCTAssertEqual(statePlan.totalStateBytes, exactStateBytes)

    let decoded = try JPEGIndependentBaseline422Decoder(
      maximumOperationByteCharge: exactOperationBytes
    ).decode(source)
    XCTAssertEqual(decoded.width, 23)
    XCTAssertEqual(decoded.height, 13)
    XCTAssertEqual(decoded.rgb, expected)
    XCTAssertEqual(decoded.statePlan, statePlan)
    XCTAssertEqual(decoded.operationByteCharge, exactOperationBytes)
    XCTAssertEqual(decoded.decodedMCUCount, 4)
    XCTAssertEqual(decoded.restartIntervalMCUs, 0)
  }

  func testOperationBudgetFailsExactlyOneByteBelowPeak() throws {
    let source = try fixture("baseline422-q75-23x13.jpg")
    XCTAssertThrowsError(
      try JPEGIndependentBaseline422Decoder(
        maximumOperationByteCharge: exactOperationBytes - 1
      ).decode(source)
    ) { error in
      XCTAssertEqual(
        error as? JPEGIndependentBaseline422Error,
        .operationBudgetExceeded(
          requiredBytes: self.exactOperationBytes,
          maximumBytes: self.exactOperationBytes - 1
        )
      )
    }
  }

  func testRestartIntervalOneMatchesSameIndependentRGBOracle() throws {
    let source = try fixture("baseline422-q75-23x13-rst1b.jpg")
    let expected = try fixture("baseline422-q75-23x13-rst1b-libjpeg.rgb")
    XCTAssertEqual(source.count, 934)
    XCTAssertEqual(expected.count, exactTransferBytes)

    let decoded = try JPEGIndependentBaseline422Decoder(
      maximumOperationByteCharge: exactOperationBytes
    ).decode(source)
    XCTAssertEqual(decoded.rgb, expected)
    XCTAssertEqual(decoded.operationByteCharge, exactOperationBytes)
    XCTAssertEqual(decoded.decodedMCUCount, 4)
    XCTAssertEqual(decoded.restartIntervalMCUs, 1)
  }

  func testCOMIsOpaqueMetadataAndRemainsBudgeted() throws {
    let original = try fixture("baseline422-q75-23x13.jpg")
    let reference = try JPEGIndependentBaseline422Decoder(
      maximumOperationByteCharge: exactOperationBytes
    ).decode(original)
    let payload = Data(repeating: 0x43, count: 48)
    let withCOM = try insertingSegment(marker: 0xFE, payload: payload, into: original)

    let inspection = try EncodedImageSecurityInspector.inspect(
      withCOM,
      maximumMetadataBytes: DecodeLimits.coreV1.maximumMetadataBytes,
      materializePNGICCProfile: false,
      materializeJPEGICCProfile: false
    )
    let decoded = try JPEGIndependentBaseline422Decoder(
      maximumOperationByteCharge: exactOperationBytes,
      maximumMetadataBytes: inspection.metadataByteCount
    ).decode(withCOM)
    XCTAssertEqual(decoded.rgb, reference.rgb)
    XCTAssertEqual(decoded.operationByteCharge, exactOperationBytes)

    XCTAssertThrowsError(
      try JPEGIndependentBaseline422Decoder(
        maximumOperationByteCharge: exactOperationBytes,
        maximumMetadataBytes: inspection.metadataByteCount - 1
      ).decode(withCOM)
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .metadataLimitExceeded)
    }
  }

  func testQualifiedAdobeYCbCrMarkerDoesNotChangePixels() throws {
    let original = try fixture("baseline422-q75-23x13.jpg")
    let reference = try JPEGIndependentBaseline422Decoder(
      maximumOperationByteCharge: exactOperationBytes
    ).decode(original)
    var adobe = Data("Adobe".utf8)
    adobe.append(contentsOf: [0x00, 0x64, 0x00, 0x00, 0x00, 0x00, 0x01])
    let withAdobe = try insertingSegment(marker: 0xEE, payload: adobe, into: original)
    let decoded = try JPEGIndependentBaseline422Decoder(
      maximumOperationByteCharge: exactOperationBytes
    ).decode(withAdobe)
    XCTAssertEqual(decoded.rgb, reference.rgb)
  }

  func testOtherSamplingProgressiveAndSemanticAPPMarkersFailClosed() throws {
    let decoder = JPEGIndependentBaseline422Decoder(maximumOperationByteCharge: 1_000_000)
    for name in ["jpeg-baseline-420.jpg", "jpeg-grayscale.jpg", "jpeg-progressive-420.jpg"] {
      XCTAssertThrowsError(try decoder.decode(try corpusV1Fixture(name))) { error in
        XCTAssertEqual(
          error as? JPEGIndependentBaseline422Error,
          .unsupportedSourceSemantics,
          "unexpected error for \(name): \(error)"
        )
      }
    }

    let original = try fixture("baseline422-q75-23x13.jpg")
    let app3 = try insertingSegment(
      marker: 0xE3,
      payload: Data(repeating: 0x4D, count: 16),
      into: original
    )
    XCTAssertThrowsError(try decoder.decode(app3)) { error in
      XCTAssertEqual(error as? JPEGIndependentBaseline422Error, .unsupportedSourceSemantics)
    }

    var exif = Data("Exif\u{0}\u{0}".utf8)
    exif.append(contentsOf: [
      0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00,
      0x01, 0x00, 0x12, 0x01, 0x03, 0x00, 0x01, 0x00,
      0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00,
    ])
    let orientation6 = try insertingSegment(marker: 0xE1, payload: exif, into: original)
    XCTAssertThrowsError(try decoder.decode(orientation6)) { error in
      XCTAssertEqual(error as? JPEGIndependentBaseline422Error, .unsupportedSourceSemantics)
    }
  }

  private func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(
      Bundle.module.url(
        forResource: name,
        withExtension: nil,
        subdirectory: "Corpus/SessionStress"
      )
    )
    return try Data(contentsOf: url)
  }

  private func corpusV1Fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(
      Bundle.module.url(
        forResource: name,
        withExtension: nil,
        subdirectory: "Corpus/v1"
      )
    )
    return try Data(contentsOf: url)
  }

  private func insertingSegment(marker: UInt8, payload: Data, into source: Data) throws -> Data {
    guard source.count >= 6,
      source[0] == 0xFF,
      source[1] == 0xD8,
      source[2] == 0xFF,
      source[3] == 0xE0
    else { throw ImageCraftError.unsupportedOrCorruptImage }
    let app0Length = Int(source[4]) << 8 | Int(source[5])
    let insertionOffset = 2 + 2 + app0Length
    guard insertionOffset <= source.count, payload.count <= Int(UInt16.max) - 2 else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    let length = payload.count + 2
    var segment = Data([0xFF, marker, UInt8(length >> 8), UInt8(length & 0xFF)])
    segment.append(payload)
    var result = Data()
    result.reserveCapacity(source.count + segment.count)
    result.append(source.prefix(insertionOffset))
    result.append(segment)
    result.append(source.dropFirst(insertionOffset))
    return result
  }
}
