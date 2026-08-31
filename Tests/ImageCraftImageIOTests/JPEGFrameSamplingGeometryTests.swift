import Foundation
import XCTest

@testable import ImageCraftCore
@testable import ImageCraftImageIO

final class JPEGFrameSamplingGeometryTests: XCTestCase {
  func testBaselineAndProgressive420ShareFrameSamplingGeometry() throws {
    for marker: UInt8 in [0xC0, 0xC2] {
      let geometry = try JPEGFrameSamplingGeometry.inspect(
        syntheticSOF(
          marker: marker,
          width: 1_920,
          height: 1_285,
          componentIDs: [7, 9, 13],
          sampling: [0x22, 0x11, 0x11]
        )
      )
      XCTAssertEqual(
        geometry.codingMode,
        marker == 0xC0 ? .baselineDCT : .progressiveDCT
      )
      XCTAssertEqual(geometry.samplingMode, .threeComponent420)
      XCTAssertEqual(geometry.maximumHorizontalSamplingFactor, 2)
      XCTAssertEqual(geometry.maximumVerticalSamplingFactor, 2)
      XCTAssertEqual(geometry.outputIMCURowHeight, 16)
      XCTAssertEqual(geometry.totalIMCURowCount, 81)
      XCTAssertEqual(geometry.internalIMCUBoundaryCount, 80)
      XCTAssertTrue(geometry.verticalChromaSubsamplingPresent)
      XCTAssertEqual(geometry.verticalChromaBoundaryAdjacentOutputRowCount, 160)
      XCTAssertEqual(geometry.components.map(\.componentID), [7, 9, 13])
    }
  }

  func testVerticalOnly440HasSameIMCURowHeightWithoutInferringColorModel() throws {
    let geometry = try JPEGFrameSamplingGeometry.inspect(
      syntheticSOF(
        marker: 0xC2,
        width: 1_920,
        height: 1_285,
        componentIDs: [3, 8, 21],
        sampling: [0x12, 0x11, 0x11]
      )
    )
    XCTAssertEqual(geometry.samplingMode, .threeComponent440)
    XCTAssertEqual(geometry.outputIMCURowHeight, 16)
    XCTAssertEqual(geometry.internalIMCUBoundaryCount, 80)
    XCTAssertEqual(geometry.verticalChromaBoundaryAdjacentOutputRowCount, 160)
  }

  func test422HasNoVerticalChromaBoundaryAdjacentRows() throws {
    let geometry = try JPEGFrameSamplingGeometry.inspect(
      syntheticSOF(
        marker: 0xC0,
        width: 1_920,
        height: 1_285,
        componentIDs: [1, 2, 3],
        sampling: [0x21, 0x11, 0x11]
      )
    )
    XCTAssertEqual(geometry.samplingMode, .threeComponent422)
    XCTAssertEqual(geometry.outputIMCURowHeight, 8)
    XCTAssertEqual(geometry.totalIMCURowCount, 161)
    XCTAssertEqual(geometry.internalIMCUBoundaryCount, 160)
    XCTAssertFalse(geometry.verticalChromaSubsamplingPresent)
    XCTAssertEqual(geometry.verticalChromaBoundaryAdjacentOutputRowCount, 0)
  }

  func testUnsupportedFrameCodingAndSamplingFailClosed() throws {
    XCTAssertThrowsError(
      try JPEGFrameSamplingGeometry.inspect(
        syntheticSOF(
          marker: 0xC1,
          width: 64,
          height: 64,
          componentIDs: [1, 2, 3],
          sampling: [0x22, 0x11, 0x11]
        )
      )
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .unsupportedOrCorruptImage)
    }

    XCTAssertThrowsError(
      try JPEGFrameSamplingGeometry.inspect(
        syntheticSOF(
          marker: 0xC2,
          width: 64,
          height: 64,
          componentIDs: [1, 2, 3],
          sampling: [0x31, 0x11, 0x11]
        )
      )
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .unsupportedOrCorruptImage)
    }
  }

  private func syntheticSOF(
    marker: UInt8,
    width: Int,
    height: Int,
    componentIDs: [UInt8],
    sampling: [UInt8]
  ) -> Data {
    precondition(componentIDs.count == sampling.count)
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
    for (componentID, factors) in zip(componentIDs, sampling) {
      bytes.append(componentID)
      bytes.append(factors)
      bytes.append(0)
    }
    return bytes
  }
}
