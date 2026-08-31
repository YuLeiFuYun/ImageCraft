import Foundation
import XCTest

@testable import ImageCraftImageIO

final class JPEGIndependentBaselineGrayscaleDecoderTests: XCTestCase {
  func testRetainedGrayscaleUsesFixedScratchAndExactOutputAdmission() throws {
    let data = try fixture(named: "jpeg-grayscale.jpg")
    let expectedOutputBytes = 19 * 11
    let exactCharge = expectedOutputBytes
      + JPEGIndependentBaselineGrayscaleDecoder.fixedScratchByteCount

    XCTAssertThrowsError(
      try JPEGIndependentBaselineGrayscaleDecoder(
        maximumOperationByteCharge: exactCharge - 1
      ).decode(data)
    ) { error in
      XCTAssertEqual(
        error as? JPEGIndependentBaselineGrayscaleError,
        .operationBudgetExceeded(
          requiredBytes: exactCharge,
          maximumBytes: exactCharge - 1
        )
      )
    }

    let decoded = try JPEGIndependentBaselineGrayscaleDecoder(
      maximumOperationByteCharge: exactCharge
    ).decode(data)
    XCTAssertEqual(decoded.width, 19)
    XCTAssertEqual(decoded.height, 11)
    XCTAssertEqual(decoded.pixels.count, expectedOutputBytes)
    XCTAssertEqual(
      decoded.fixedScratchByteCount,
      JPEGIndependentBaselineGrayscaleDecoder.fixedScratchByteCount
    )
    XCTAssertEqual(decoded.operationByteCharge, exactCharge)
    XCTAssertEqual(decoded.decodedMCUCount, 6)
  }

  func testEmbeddedICCFailsClosedWithoutWideningPixelAndScratchCharge() throws {
    let profile = Data(repeating: 0x7C, count: 128)
    let data = insertingICCProfile(profile, into: try fixture(named: "jpeg-grayscale.jpg"))
    let exactCharge = 19 * 11 + JPEGIndependentBaselineGrayscaleDecoder.fixedScratchByteCount

    XCTAssertThrowsError(
      try JPEGIndependentBaselineGrayscaleDecoder(
        maximumOperationByteCharge: exactCharge,
        maximumMetadataBytes: 512
      ).decode(data)
    ) { error in
      XCTAssertEqual(
        error as? JPEGIndependentBaselineGrayscaleError,
        .unsupportedSourceSemantics
      )
    }
  }

  func testColorAndProgressiveSourcesFailClosed() throws {
    let generousBudget = 1024 * 1024
    let decoder = JPEGIndependentBaselineGrayscaleDecoder(
      maximumOperationByteCharge: generousBudget
    )
    for name in ["jpeg-baseline-420.jpg", "jpeg-progressive-420.jpg"] {
      XCTAssertThrowsError(try decoder.decode(try fixture(named: name)))
    }
  }

  private func insertingICCProfile(_ profile: Data, into jpeg: Data) -> Data {
    let signature = Data("ICC_PROFILE\u{0}".utf8)
    let segmentLength = signature.count + 2 + profile.count + 2
    precondition(segmentLength <= Int(UInt16.max))
    var result = Data(jpeg.prefix(2))
    result.append(0xFF)
    result.append(0xE2)
    result.append(UInt8((segmentLength >> 8) & 0xFF))
    result.append(UInt8(segmentLength & 0xFF))
    result.append(signature)
    result.append(1)
    result.append(1)
    result.append(profile)
    result.append(jpeg.dropFirst(2))
    return result
  }

  private func fixture(named name: String) throws -> Data {
    let url = try XCTUnwrap(
      Bundle.module.url(
        forResource: name,
        withExtension: nil,
        subdirectory: "Corpus/v1"
      )
    )
    return try Data(contentsOf: url)
  }
}
