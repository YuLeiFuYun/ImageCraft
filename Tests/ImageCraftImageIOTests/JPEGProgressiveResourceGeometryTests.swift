import Foundation
import XCTest

@testable import ImageCraftCore
@testable import ImageCraftImageIO

final class JPEGProgressiveResourceGeometryTests: XCTestCase {
  func testRetainedProgressive420FixtureMatchesIndependentGeometryModel() throws {
    let geometry = try JPEGProgressiveResourceGeometry.inspect(
      fixture(named: "jpeg-progressive-420.jpg")
    )

    XCTAssertEqual(geometry.width, 23)
    XCTAssertEqual(geometry.height, 13)
    XCTAssertEqual(geometry.precision, 8)
    XCTAssertEqual(geometry.samplingMode, .threeComponent420)
    XCTAssertTrue(geometry.fancyVerticalContextRowsRequired)
    XCTAssertEqual(geometry.coefficientArrayPayloadBytes, 1_536)
    XCTAssertEqual(geometry.fullScaleFancyRowWorkspaceBytes, 896)
    XCTAssertEqual(
      geometry.components,
      [
        JPEGProgressiveComponentGeometry(
          componentID: 1,
          horizontalSamplingFactor: 2,
          verticalSamplingFactor: 2,
          widthInBlocks: 3,
          heightInBlocks: 2,
          paddedWidthInBlocks: 4,
          paddedHeightInBlocks: 2,
          coefficientPayloadBytes: 1_024
        ),
        JPEGProgressiveComponentGeometry(
          componentID: 2,
          horizontalSamplingFactor: 1,
          verticalSamplingFactor: 1,
          widthInBlocks: 2,
          heightInBlocks: 1,
          paddedWidthInBlocks: 2,
          paddedHeightInBlocks: 1,
          coefficientPayloadBytes: 256
        ),
        JPEGProgressiveComponentGeometry(
          componentID: 3,
          horizontalSamplingFactor: 1,
          verticalSamplingFactor: 1,
          widthInBlocks: 2,
          heightInBlocks: 1,
          paddedWidthInBlocks: 2,
          paddedHeightInBlocks: 1,
          coefficientPayloadBytes: 256
        ),
      ]
    )
  }

  func testQualifiedSamplingModesDeriveExpectedFullScaleFancyRowWorkspace() throws {
    let cases: [(JPEGProgressiveSamplingMode, [UInt8], Int, Int, Bool)] = [
      (.singleComponent, [0x11], 15_360, 4_945_920, false),
      (.threeComponent444, [0x11, 0x11, 0x11], 46_080, 14_837_760, false),
      (.threeComponent422, [0x21, 0x11, 0x11], 34_560, 9_891_840, false),
      (.threeComponent440, [0x12, 0x11, 0x11], 84_480, 9_953_280, true),
      (.threeComponent420, [0x22, 0x11, 0x11], 65_280, 7_464_960, true),
    ]

    for (mode, sampling, expectedWorkspace, expectedCoefficientBytes, expectedContext) in cases {
      let geometry = try JPEGProgressiveResourceGeometry.inspect(
        syntheticSOF(marker: 0xC2, width: 1_920, height: 1_285, sampling: sampling)
      )
      XCTAssertEqual(geometry.samplingMode, mode)
      XCTAssertEqual(geometry.fullScaleFancyRowWorkspaceBytes, expectedWorkspace)
      XCTAssertEqual(geometry.coefficientArrayPayloadBytes, expectedCoefficientBytes)
      XCTAssertEqual(geometry.fancyVerticalContextRowsRequired, expectedContext)
    }
  }

  func test420FancyContextBoundaryActivatesAtWidthFive() throws {
    let widthFour = try JPEGProgressiveResourceGeometry.inspect(
      syntheticSOF(marker: 0xC2, width: 4, height: 129, sampling: [0x22, 0x11, 0x11])
    )
    let widthFive = try JPEGProgressiveResourceGeometry.inspect(
      syntheticSOF(marker: 0xC2, width: 5, height: 129, sampling: [0x22, 0x11, 0x11])
    )

    XCTAssertFalse(widthFour.fancyVerticalContextRowsRequired)
    XCTAssertTrue(widthFive.fancyVerticalContextRowsRequired)
    XCTAssertEqual(widthFour.fullScaleFancyRowWorkspaceBytes, 272)
    XCTAssertEqual(widthFive.fullScaleFancyRowWorkspaceBytes, 344)
  }

  func testBaselineAndUnqualifiedSamplingFailClosed() throws {
    XCTAssertThrowsError(
      try JPEGProgressiveResourceGeometry.inspect(
        syntheticSOF(marker: 0xC0, width: 32, height: 32, sampling: [0x22, 0x11, 0x11])
      )
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .progressiveDecodingUnsupported)
    }

    XCTAssertThrowsError(
      try JPEGProgressiveResourceGeometry.inspect(
        syntheticSOF(marker: 0xC2, width: 32, height: 32, sampling: [0x41, 0x11, 0x11])
      )
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .unsupportedOrCorruptImage)
    }
  }

  func testDuplicateComponentIDAndMalformedSegmentFailClosed() throws {
    var duplicate = syntheticSOF(
      marker: 0xC2,
      width: 32,
      height: 32,
      sampling: [0x22, 0x11, 0x11]
    )
    // SOI(2) + marker(2) + length(2) + precision/height/width/count(6) = 12.
    // Component IDs are at offsets 12, 15 and 18.
    duplicate[15] = duplicate[12]
    XCTAssertThrowsError(try JPEGProgressiveResourceGeometry.inspect(duplicate)) { error in
      XCTAssertEqual(error as? ImageCraftError, .unsupportedOrCorruptImage)
    }

    var malformed = syntheticSOF(
      marker: 0xC2,
      width: 32,
      height: 32,
      sampling: [0x22, 0x11, 0x11]
    )
    malformed[5] &-= 1
    XCTAssertThrowsError(try JPEGProgressiveResourceGeometry.inspect(malformed)) { error in
      XCTAssertEqual(error as? ImageCraftError, .unsupportedOrCorruptImage)
    }
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

  private func syntheticSOF(
    marker: UInt8,
    width: Int,
    height: Int,
    sampling: [UInt8]
  ) -> Data {
    precondition((1...65_535).contains(width))
    precondition((1...65_535).contains(height))
    precondition(sampling.count == 1 || sampling.count == 3)
    let segmentLength = 8 + 3 * sampling.count
    var bytes = Data([
      0xFF, 0xD8,
      0xFF, marker,
      UInt8((segmentLength >> 8) & 0xFF), UInt8(segmentLength & 0xFF),
      8,
      UInt8((height >> 8) & 0xFF), UInt8(height & 0xFF),
      UInt8((width >> 8) & 0xFF), UInt8(width & 0xFF),
      UInt8(sampling.count),
    ])
    for (index, factors) in sampling.enumerated() {
      bytes.append(UInt8(index + 1))
      bytes.append(factors)
      bytes.append(0)
    }
    return bytes
  }
}
