import XCTest

@testable import ImageCraftImageIO

final class JPEGAdaptiveChromaReconstructionTests: XCTestCase {
  func testPinnedV3PostIDCTRowsMatchPythonAdaptivePolicyExactly() throws {
    let cases: [(String, [UInt8], [UInt8])] = [
      (
        "quadratic",
        [80, 80, 80, 81, 81, 82, 83, 84, 85, 87, 88, 90, 92, 94, 96, 98, 101, 104, 107, 110, 113, 116, 120, 124, 127, 131, 136, 140, 144, 149, 154, 158],
        [80, 80, 80, 80, 80, 80, 81, 81, 81, 81, 82, 82, 83, 83, 84, 84, 85, 86, 86, 87, 88, 89, 89, 91, 91, 93, 93, 95, 95, 97, 97, 99, 100, 102, 103, 105, 106, 108, 109, 111, 112, 114, 115, 117, 119, 121, 123, 125, 126, 128, 130, 132, 135, 137, 139, 141, 143, 145, 148, 150, 153, 155, 157, 158]
      ),
      (
        "kink",
        [64, 66, 68, 70, 72, 74, 76, 78, 80, 82, 84, 86, 88, 90, 92, 94, 97, 103, 109, 115, 121, 127, 133, 139, 145, 151, 157, 163, 169, 175, 181, 187],
        [64, 65, 65, 67, 67, 69, 69, 71, 71, 73, 73, 75, 75, 77, 77, 79, 79, 81, 81, 83, 83, 85, 85, 87, 87, 89, 89, 91, 91, 93, 93, 95, 96, 99, 101, 105, 107, 111, 113, 117, 119, 123, 125, 129, 131, 135, 137, 141, 143, 147, 149, 153, 155, 159, 161, 165, 167, 171, 173, 177, 179, 183, 185, 187]
      ),
      (
        "step-off24",
        [80, 80, 80, 80, 80, 80, 80, 80, 80, 80, 80, 80, 176, 176, 176, 176, 176, 176, 176, 176, 176, 176, 176, 176, 176, 176, 176, 176, 176, 176, 176, 176],
        Array(repeating: 80, count: 24) + Array(repeating: 176, count: 40)
      ),
      (
        "step-small",
        Array(repeating: 112, count: 16) + Array(repeating: 120, count: 16),
        Array(repeating: 112, count: 32) + Array(repeating: 120, count: 32)
      ),
      (
        "ramp-step",
        [65, 69, 73, 77, 81, 85, 89, 93, 97, 101, 105, 109, 113, 117, 121, 125, 153, 157, 161, 165, 169, 173, 177, 181, 185, 189, 193, 197, 201, 205, 209, 213],
        [65, 66, 68, 70, 72, 74, 76, 78, 80, 82, 84, 86, 88, 90, 92, 94, 96, 98, 100, 102, 104, 106, 108, 110, 112, 114, 116, 118, 120, 122, 124, 125, 153, 154, 156, 158, 160, 162, 164, 166, 168, 170, 172, 174, 176, 178, 180, 182, 184, 186, 188, 190, 192, 194, 196, 198, 200, 202, 204, 206, 208, 210, 212, 213]
      ),
      (
        "impulse31",
        Array(repeating: 128, count: 15) + [144] + Array(repeating: 128, count: 16),
        Array(repeating: 128, count: 29) + [132, 140, 140, 132] + Array(repeating: 128, count: 31)
      ),
    ]

    for (name, source, expected) in cases {
      var actual = [UInt8](repeating: 0, count: expected.count)
      try source.withUnsafeBufferPointer { input in
        try actual.withUnsafeMutableBufferPointer { output in
          try JPEGAdaptiveChromaReconstruction.writeH1V2(
            source: input,
            sourceWidth: 1,
            sourceHeight: source.count,
            destination: output,
            outputHeight: expected.count
          )
        }
      }
      XCTAssertEqual(actual, expected, name)
    }
  }

  func testColumnsAreIndependentAndCenteredRoundingIsPreserved() throws {
    // Column 0 contains a hard edge; column 1 is a constant-gradient control. The adaptive rule
    // must stop cross-edge mixing only in column 0 while retaining the existing centered integer
    // biases for column 1.
    let source: [UInt8] = [
      80, 10,
      80, 20,
      176, 30,
      176, 40,
    ]
    let expected: [UInt8] = [
      80, 10,
      80, 13,
      80, 17,
      80, 23,
      176, 27,
      176, 33,
      176, 37,
      176, 40,
    ]
    var actual = [UInt8](repeating: 0, count: expected.count)
    try source.withUnsafeBufferPointer { input in
      try actual.withUnsafeMutableBufferPointer { output in
        try JPEGAdaptiveChromaReconstruction.writeH1V2(
          source: input,
          sourceWidth: 2,
          sourceHeight: 4,
          destination: output,
          outputHeight: 8
        )
      }
    }
    XCTAssertEqual(actual, expected)
  }

  func testPhaseShiftedTwoRowStripeFalsifiesV3Rule() throws {
    // Full-resolution source truth is 80 except for rows 17...18, which are 176. Exact 2:1 box
    // subsampling therefore yields two adjacent mixed 128 samples. V3 sees each 80<->128 flank as
    // a strong local outlier and snaps to nearest/current; that sharpens the wrong low-resolution
    // plateau and raises source-truth RMSE versus centered reconstruction.
    var truth = [UInt8](repeating: 80, count: 32)
    truth[17] = 176
    truth[18] = 176
    let subsampled: [UInt8] = stride(from: 0, to: truth.count, by: 2).map {
      UInt8((Int(truth[$0]) + Int(truth[$0 + 1])) / 2)
    }
    XCTAssertEqual(subsampled[7...10], [80, 128, 128, 80])

    var centered = [UInt8](repeating: 0, count: truth.count)
    var adaptive = [UInt8](repeating: 0, count: truth.count)
    try subsampled.withUnsafeBufferPointer { input in
      try centered.withUnsafeMutableBufferPointer { output in
        try JPEGCenteredChromaReconstruction.writeH1V2(
          source: input,
          sourceWidth: 1,
          sourceHeight: subsampled.count,
          destination: output,
          outputHeight: truth.count
        )
      }
      try adaptive.withUnsafeMutableBufferPointer { output in
        try JPEGAdaptiveChromaReconstruction.writeH1V2(
          source: input,
          sourceWidth: 1,
          sourceHeight: subsampled.count,
          destination: output,
          outputHeight: truth.count
        )
      }
    }

    func squaredError(_ values: [UInt8]) -> Int {
      zip(truth, values).reduce(into: 0) { total, pair in
        let delta = Int(pair.0) - Int(pair.1)
        total += delta * delta
      }
    }

    XCTAssertGreaterThan(squaredError(adaptive), squaredError(centered))
    XCTAssertEqual(Array(centered[15...20]), [92, 116, 128, 128, 116, 92])
    XCTAssertEqual(Array(adaptive[15...20]), [80, 128, 128, 128, 128, 80])
  }

  func testInvalidGeometryFailsClosedWithoutWriting() throws {
    let source: [UInt8] = [1, 2, 3, 4]
    var output = [UInt8](repeating: 0xA5, count: 7)
    XCTAssertThrowsError(
      try source.withUnsafeBufferPointer { input in
        try output.withUnsafeMutableBufferPointer { destination in
          try JPEGAdaptiveChromaReconstruction.writeH1V2(
            source: input,
            sourceWidth: 1,
            sourceHeight: 4,
            destination: destination,
            outputHeight: 8
          )
        }
      }
    )
    XCTAssertEqual(output, [UInt8](repeating: 0xA5, count: 7))
  }
}
