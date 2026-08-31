import XCTest

@testable import ImageCraftImageIO

final class JPEGCenteredChromaReconstructionTests: XCTestCase {
  func testH2V2SingleRowMatchesFullPlaneKernelExactly() throws {
    let sourceWidth = 4
    let source: [UInt8] = [
      10, 20, 40, 80,
      30, 50, 70, 90,
      60, 80, 100, 120,
    ]
    var full = [UInt8](repeating: 0, count: 8 * 6)
    try source.withUnsafeBufferPointer { sourceBuffer in
      try full.withUnsafeMutableBufferPointer { destination in
        try JPEGCenteredChromaReconstruction.writeH2V2(
          source: sourceBuffer,
          sourceWidth: sourceWidth,
          sourceHeight: 3,
          destination: destination,
          outputWidth: 8,
          outputHeight: 6
        )
      }
    }

    var row = [UInt8](repeating: 0, count: 8)
    try source.withUnsafeBufferPointer { sourceBuffer in
      let current = UnsafeBufferPointer(start: sourceBuffer.baseAddress!.advanced(by: 4), count: 4)
      let adjacent = UnsafeBufferPointer(start: sourceBuffer.baseAddress!, count: 4)
      try row.withUnsafeMutableBufferPointer { destination in
        try JPEGCenteredChromaReconstruction.writeH2V2Row(
          current: current,
          adjacent: adjacent,
          destination: destination,
          outputWidth: 8
        )
      }
    }
    XCTAssertEqual(row, Array(full[16..<24]))
  }

  func testH2V2NarrowWidthUsesExplicitBoxBranch() throws {
    let source: [UInt8] = [10, 20]
    var output = [UInt8](repeating: 0, count: 3)
    try source.withUnsafeBufferPointer { sourceBuffer in
      try output.withUnsafeMutableBufferPointer { destination in
        try JPEGCenteredChromaReconstruction.writeH2V2BoxRow(
          source: sourceBuffer,
          destination: destination,
          outputWidth: 3
        )
      }
    }
    XCTAssertEqual(output, [10, 10, 20])
  }

  func testH1V2LinearTruthCrossesInternalIMCUBoundariesExactly() throws {
    let source = (0..<32).map { UInt8(66 + 4 * $0) }
    let truth = (0..<64).map { UInt8(65 + 2 * $0) }
    var output = [UInt8](repeating: 0, count: 64)
    try source.withUnsafeBufferPointer { sourceBuffer in
      try output.withUnsafeMutableBufferPointer { outputBuffer in
        try JPEGCenteredChromaReconstruction.writeH1V2(
          source: sourceBuffer,
          sourceWidth: 1,
          sourceHeight: 32,
          destination: outputBuffer,
          outputHeight: 64
        )
      }
    }
    // True outer image edges use edge extension. Every internal 16-row iMCU boundary remains
    // exact for the centered linear source field.
    XCTAssertEqual(Array(output[1..<63]), Array(truth[1..<63]))
    for row in [15, 16, 31, 32, 47, 48] {
      XCTAssertEqual(output[row], truth[row])
    }
  }

  func testH2V2ConstantHorizontalLinearVerticalTruthIsExactAwayFromImageEdges() throws {
    let sourceWidth = 4
    var source = [UInt8]()
    for row in 0..<32 {
      source.append(contentsOf: repeatElement(UInt8(66 + 4 * row), count: sourceWidth))
    }
    var output = [UInt8](repeating: 0, count: 8 * 64)
    try source.withUnsafeBufferPointer { sourceBuffer in
      try output.withUnsafeMutableBufferPointer { outputBuffer in
        try JPEGCenteredChromaReconstruction.writeH2V2(
          source: sourceBuffer,
          sourceWidth: sourceWidth,
          sourceHeight: 32,
          destination: outputBuffer,
          outputWidth: 8,
          outputHeight: 64
        )
      }
    }
    for row in 1..<63 {
      let expected = UInt8(65 + 2 * row)
      XCTAssertEqual(Array(output[(row * 8)..<(row * 8 + 8)]), [UInt8](repeating: expected, count: 8))
    }
  }

  func testH2V1MatchesReferenceIntegerBiasPattern() throws {
    let source: [UInt8] = [10, 20, 50, 90]
    var output = [UInt8](repeating: 0, count: 8)
    try source.withUnsafeBufferPointer { sourceBuffer in
      try output.withUnsafeMutableBufferPointer { outputBuffer in
        try JPEGCenteredChromaReconstruction.writeH2V1(
          source: sourceBuffer,
          sourceWidth: 4,
          sourceHeight: 1,
          destination: outputBuffer,
          outputWidth: 8
        )
      }
    }
    XCTAssertEqual(output, [10, 13, 17, 28, 42, 60, 80, 90])
  }
}
