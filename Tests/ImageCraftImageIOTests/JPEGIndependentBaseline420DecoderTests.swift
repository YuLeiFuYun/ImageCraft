import Foundation
import XCTest

@testable import ImageCraftImageIO

final class JPEGIndependentBaseline420DecoderTests: XCTestCase {
  func testRetained420UsesWidthBoundedOwnedStripStateAndExactAdmission() throws {
    let data = try fixture(named: "jpeg-baseline-420.jpg")
    let statePlan = try JPEGIndependentBaseline420StatePlan.inspect(data)
    XCTAssertEqual(statePlan.width, 23)
    XCTAssertEqual(statePlan.height, 13)
    XCTAssertEqual(statePlan.chromaWidth, 12)
    XCTAssertEqual(statePlan.yRowStrideBytes, 64)
    XCTAssertEqual(statePlan.chromaRowStrideBytes, 64)
    XCTAssertEqual(statePlan.yStripBytes, 1_024)
    XCTAssertEqual(statePlan.chromaStripBytesPerComponent, 512)
    XCTAssertEqual(statePlan.totalStateBytes, 2_880)
    XCTAssertTrue(statePlan.usesFancyGlobalContext)

    let exactCharge = 23 * 13 * 3 + statePlan.totalStateBytes
    XCTAssertEqual(exactCharge, 3_777)
    XCTAssertThrowsError(
      try JPEGIndependentBaseline420Decoder(
        maximumOperationByteCharge: exactCharge - 1
      ).decode(data)
    ) { error in
      XCTAssertEqual(
        error as? JPEGIndependentBaseline420Error,
        .operationBudgetExceeded(
          requiredBytes: exactCharge,
          maximumBytes: exactCharge - 1
        )
      )
    }

    let decoded = try JPEGIndependentBaseline420Decoder(
      maximumOperationByteCharge: exactCharge
    ).decode(data)
    XCTAssertEqual(decoded.width, 23)
    XCTAssertEqual(decoded.height, 13)
    XCTAssertEqual(decoded.rgb.count, 23 * 13 * 3)
    XCTAssertEqual(decoded.decodedMCUCount, 2)
    XCTAssertEqual(decoded.statePlan, statePlan)
    XCTAssertEqual(decoded.operationByteCharge, exactCharge)
  }

  func testProgressiveAndGrayscaleSourcesFailClosed() throws {
    let decoder = JPEGIndependentBaseline420Decoder(maximumOperationByteCharge: 1_000_000)
    for name in ["jpeg-progressive-420.jpg", "jpeg-grayscale.jpg"] {
      XCTAssertThrowsError(try decoder.decode(try fixture(named: name)))
    }
  }

  func testAdobeAPP14MustAgreeWithJFIFYCbCr() throws {
    let original = try fixture(named: "jpeg-baseline-420.jpg")
    let plan = try JPEGIndependentBaseline420StatePlan.inspect(original)
    let operationCharge = plan.totalStateBytes + plan.width * plan.height * 3
    let reference = try JPEGIndependentBaseline420Decoder(
      maximumOperationByteCharge: operationCharge
    ).decode(original)
    let jfifLength = Int(original[4]) << 8 | Int(original[5])
    let adobeInsertionOffset = 4 + jfifLength

    func sourceWithAdobeTransform(_ transform: UInt8) -> Data {
      var app14 = Data([0xFF, 0xEE, 0x00, 0x0E])
      app14.append(Data("Adobe".utf8))
      app14.append(contentsOf: [0x00, 0x64, 0x00, 0x00, 0x00, 0x00, transform])
      var result = Data()
      result.reserveCapacity(original.count + app14.count)
      result.append(original.prefix(adobeInsertionOffset))
      result.append(app14)
      result.append(original.dropFirst(adobeInsertionOffset))
      return result
    }

    let accepted = try JPEGIndependentBaseline420Decoder(
      maximumOperationByteCharge: operationCharge
    ).decode(sourceWithAdobeTransform(1))
    XCTAssertEqual(accepted.rgb, reference.rgb)

    for conflictingTransform in [UInt8(0), UInt8(2)] {
      XCTAssertThrowsError(
        try JPEGIndependentBaseline420Decoder(
          maximumOperationByteCharge: operationCharge
        ).decode(sourceWithAdobeTransform(conflictingTransform))
      ) { error in
        XCTAssertEqual(
          error as? JPEGIndependentBaseline420Error,
          .unsupportedSourceSemantics
        )
      }
    }
  }

  func testJFIFAuthorityRequiresCompleteFirstAPP0() throws {
    let original = try fixture(named: "jpeg-baseline-420.jpg")
    XCTAssertGreaterThanOrEqual(original.count, 24)
    XCTAssertEqual(Array(original[0..<4]), [0xFF, 0xD8, 0xFF, 0xE0])
    let app0Length = Int(original[4]) << 8 | Int(original[5])
    let app0End = 4 + app0Length
    XCTAssertGreaterThanOrEqual(app0Length, 16)
    XCTAssertLessThan(app0End + 4, original.count)
    XCTAssertEqual(original[app0End], 0xFF)
    XCTAssertEqual(original[app0End + 1], 0xDB)
    let dqtLength = Int(original[app0End + 2]) << 8 | Int(original[app0End + 3])
    let dqtEnd = app0End + 2 + dqtLength

    let plan = try JPEGIndependentBaseline420StatePlan.inspect(original)
    let operationCharge = plan.totalStateBytes + plan.width * plan.height * 3
    let decoder = JPEGIndependentBaseline420Decoder(
      maximumOperationByteCharge: operationCharge
    )

    var truncated = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x07])
    truncated.append(Data("JFIF\u{0}".utf8))
    truncated.append(original.dropFirst(app0End))
    XCTAssertThrowsError(try decoder.decode(truncated)) { error in
      XCTAssertEqual(
        error as? JPEGIndependentBaseline420Error,
        .unsupportedSourceSemantics
      )
    }

    var reordered = Data([0xFF, 0xD8])
    reordered.append(original[app0End..<dqtEnd])
    reordered.append(original[2..<app0End])
    reordered.append(original.dropFirst(dqtEnd))
    XCTAssertThrowsError(try decoder.decode(reordered)) { error in
      XCTAssertEqual(
        error as? JPEGIndependentBaseline420Error,
        .unsupportedSourceSemantics
      )
    }
  }

  func testWidthFourUsesBoxBranchAndWidthFiveUsesFancyContextBranch() throws {
    let widthFour = try JPEGIndependentBaseline420StatePlan.make(width: 4, height: 17)
    let widthFive = try JPEGIndependentBaseline420StatePlan.make(width: 5, height: 17)
    XCTAssertEqual(widthFour.chromaWidth, 2)
    XCTAssertFalse(widthFour.usesFancyGlobalContext)
    XCTAssertEqual(widthFive.chromaWidth, 3)
    XCTAssertTrue(widthFive.usesFancyGlobalContext)
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
