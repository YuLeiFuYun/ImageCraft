import XCTest

@testable import ImageCraftImageIO

final class JPEGISlowIDCTTests: XCTestCase {
  func testZeroBlockProducesLevelShiftedNeutralSamples() throws {
    try assertBlock(
      coefficients: [Int16](repeating: 0, count: 64),
      quantization: [UInt16](repeating: 1, count: 64),
      expected: [UInt8](repeating: 128, count: 64)
    )
  }

  func testDCOnlyBlockUsesExactDescaleAndLevelShift() throws {
    var coefficients = [Int16](repeating: 0, count: 64)
    coefficients[0] = 80
    try assertBlock(
      coefficients: coefficients,
      quantization: [UInt16](repeating: 1, count: 64),
      expected: [UInt8](repeating: 138, count: 64)
    )
  }

  func testDequantizedDomainFailsClosedBeforeWorkspaceMutation() throws {
    var coefficients = [Int16](repeating: 0, count: 64)
    coefficients[0] = 1_000
    var quantization = [UInt16](repeating: 1, count: 64)
    quantization[0] = 255
    var workspace = [Int32](repeating: 0x1234, count: 64)
    var output = [UInt8](repeating: 0x5A, count: 64)

    XCTAssertThrowsError(
      try coefficients.withUnsafeBufferPointer { coefficientBuffer in
        try quantization.withUnsafeBufferPointer { quantizationBuffer in
          try workspace.withUnsafeMutableBufferPointer { workspaceBuffer in
            try output.withUnsafeMutableBufferPointer { outputBuffer in
              try JPEGISlowIDCT.writeBlock(
                coefficients: coefficientBuffer,
                quantization: quantizationBuffer,
                workspace: workspaceBuffer,
                destination: outputBuffer
              )
            }
          }
        }
      }
    )
    XCTAssertEqual(workspace, [Int32](repeating: 0x1234, count: 64))
    XCTAssertEqual(output, [UInt8](repeating: 0x5A, count: 64))
  }

  func testClippedStridedDestinationMatchesFullBlockAndPreservesOutsideRegion() throws {
    var coefficients = [Int16](repeating: 0, count: 64)
    coefficients[0] = 31
    coefficients[1] = -7
    coefficients[8] = 5
    coefficients[9] = 3
    let quantization = [UInt16](repeating: 4, count: 64)
    var fullWorkspace = [Int32](repeating: 0, count: 64)
    var fullOutput = [UInt8](repeating: 0, count: 64)
    try coefficients.withUnsafeBufferPointer { coefficientBuffer in
      try quantization.withUnsafeBufferPointer { quantizationBuffer in
        try fullWorkspace.withUnsafeMutableBufferPointer { workspaceBuffer in
          try fullOutput.withUnsafeMutableBufferPointer { outputBuffer in
            try JPEGISlowIDCT.writeBlock(
              coefficients: coefficientBuffer,
              quantization: quantizationBuffer,
              workspace: workspaceBuffer,
              destination: outputBuffer
            )
          }
        }
      }
    }

    var clippedWorkspace = [Int32](repeating: 0, count: 64)
    var stridedOutput = [UInt8](repeating: 0xA5, count: 11 * 7)
    try coefficients.withUnsafeBufferPointer { coefficientBuffer in
      try quantization.withUnsafeBufferPointer { quantizationBuffer in
        try clippedWorkspace.withUnsafeMutableBufferPointer { workspaceBuffer in
          try stridedOutput.withUnsafeMutableBufferPointer { outputBuffer in
            try JPEGISlowIDCT.writeBlockClipped(
              coefficients: coefficientBuffer,
              quantization: quantizationBuffer,
              workspace: workspaceBuffer,
              destination: outputBuffer,
              destinationRowStride: 11,
              writeWidth: 5,
              writeHeight: 6
            )
          }
        }
      }
    }
    for row in 0..<7 {
      for column in 0..<11 {
        let actual = stridedOutput[row * 11 + column]
        if row < 6, column < 5 {
          XCTAssertEqual(actual, fullOutput[row * 8 + column])
        } else {
          XCTAssertEqual(actual, 0xA5)
        }
      }
    }
  }

  private func assertBlock(
    coefficients: [Int16],
    quantization: [UInt16],
    expected: [UInt8]
  ) throws {
    let coefficients = coefficients
    let quantization = quantization
    var workspace = [Int32](repeating: 0, count: 64)
    var output = [UInt8](repeating: 0, count: 64)
    try coefficients.withUnsafeBufferPointer { coefficientBuffer in
      try quantization.withUnsafeBufferPointer { quantizationBuffer in
        try workspace.withUnsafeMutableBufferPointer { workspaceBuffer in
          try output.withUnsafeMutableBufferPointer { outputBuffer in
            try JPEGISlowIDCT.writeBlock(
              coefficients: coefficientBuffer,
              quantization: quantizationBuffer,
              workspace: workspaceBuffer,
              destination: outputBuffer
            )
          }
        }
      }
    }
    XCTAssertEqual(output, expected)
  }
}
