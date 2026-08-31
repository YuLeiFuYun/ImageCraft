import XCTest

@testable import ImageCraftImageIO

final class JPEGYCbCrToRGBTests: XCTestCase {
  func testArbitraryWidthPlanarRowMatchesInterleavedKernel() throws {
    let width = 13
    let y = (0..<width).map { UInt8(20 + $0 * 11) }
    let cb = (0..<width).map { UInt8(70 + $0 * 5) }
    let cr = (0..<width).map { UInt8(190 - $0 * 4) }
    var interleaved: [UInt8] = []
    interleaved.reserveCapacity(width * 3)
    for column in 0..<width {
      interleaved.append(y[column])
      interleaved.append(cb[column])
      interleaved.append(cr[column])
    }
    var reference = [UInt8](repeating: 0, count: width * 3)
    try interleaved.withUnsafeBufferPointer { source in
      try reference.withUnsafeMutableBufferPointer { destination in
        try JPEGYCbCrToRGB.writeInterleavedRGB(yCbCr: source, destination: destination)
      }
    }

    var row = [UInt8](repeating: 0, count: width * 3)
    try y.withUnsafeBufferPointer { yBuffer in
      try cb.withUnsafeBufferPointer { cbBuffer in
        try cr.withUnsafeBufferPointer { crBuffer in
          try row.withUnsafeMutableBufferPointer { destination in
            try JPEGYCbCrToRGB.writePlanarRGBRow(
              y: yBuffer,
              cb: cbBuffer,
              cr: crBuffer,
              destination: destination,
              writeWidth: width
            )
          }
        }
      }
    }
    XCTAssertEqual(row, reference)
  }

  func testNeutralChromaPreservesLumaExactly() throws {
    let input: [UInt8] = [0, 128, 128, 1, 128, 128, 127, 128, 128, 255, 128, 128]
    var output = [UInt8](repeating: 0, count: input.count)
    try input.withUnsafeBufferPointer { source in
      try output.withUnsafeMutableBufferPointer { destination in
        try JPEGYCbCrToRGB.writeInterleavedRGB(yCbCr: source, destination: destination)
      }
    }
    XCTAssertEqual(output, [0, 0, 0, 1, 1, 1, 127, 127, 127, 255, 255, 255])
  }

  func testFusedH2V2RowMatchesStagedReconstructionExactly() throws {
    let width = 7
    let y: [UInt8] = [19, 47, 81, 103, 144, 201, 250]
    let currentCb: [UInt8] = [33, 91, 149, 211]
    let adjacentCb: [UInt8] = [71, 52, 181, 224]
    let currentCr: [UInt8] = [218, 170, 117, 64]
    let adjacentCr: [UInt8] = [196, 143, 99, 41]
    var reconstructedCb = [UInt8](repeating: 0, count: width)
    var reconstructedCr = [UInt8](repeating: 0, count: width)
    try currentCb.withUnsafeBufferPointer { current in
      try adjacentCb.withUnsafeBufferPointer { adjacent in
        try reconstructedCb.withUnsafeMutableBufferPointer { destination in
          try JPEGCenteredChromaReconstruction.writeH2V2Row(
            current: current,
            adjacent: adjacent,
            destination: destination,
            outputWidth: width
          )
        }
      }
    }
    try currentCr.withUnsafeBufferPointer { current in
      try adjacentCr.withUnsafeBufferPointer { adjacent in
        try reconstructedCr.withUnsafeMutableBufferPointer { destination in
          try JPEGCenteredChromaReconstruction.writeH2V2Row(
            current: current,
            adjacent: adjacent,
            destination: destination,
            outputWidth: width
          )
        }
      }
    }

    var staged = [UInt8](repeating: 0, count: width * 3)
    try y.withUnsafeBufferPointer { yy in
      try reconstructedCb.withUnsafeBufferPointer { cb in
        try reconstructedCr.withUnsafeBufferPointer { cr in
          try staged.withUnsafeMutableBufferPointer { destination in
            try JPEGYCbCrToRGB.writePlanarRGBRow(
              y: yy,
              cb: cb,
              cr: cr,
              destination: destination,
              writeWidth: width
            )
          }
        }
      }
    }

    var fused = [UInt8](repeating: 0, count: width * 3)
    try y.withUnsafeBufferPointer { yy in
      try currentCb.withUnsafeBufferPointer { cb in
        try adjacentCb.withUnsafeBufferPointer { adjacentCB in
          try currentCr.withUnsafeBufferPointer { cr in
            try adjacentCr.withUnsafeBufferPointer { adjacentCR in
              try fused.withUnsafeMutableBufferPointer { destination in
                try JPEGYCbCrToRGB.writeCenteredH2V2RGBRow(
                  y: yy,
                  currentCb: cb,
                  adjacentCb: adjacentCB,
                  currentCr: cr,
                  adjacentCr: adjacentCR,
                  destination: destination,
                  writeWidth: width,
                  usesFancyGlobalContext: true
                )
              }
            }
          }
        }
      }
    }
    XCTAssertEqual(fused, staged)

    let boxY: [UInt8] = [20, 80, 140]
    let boxCb: [UInt8] = [64, 192]
    let boxCr: [UInt8] = [200, 40]
    var boxReconstructedCb = [UInt8](repeating: 0, count: 3)
    var boxReconstructedCr = [UInt8](repeating: 0, count: 3)
    try boxCb.withUnsafeBufferPointer { source in
      try boxReconstructedCb.withUnsafeMutableBufferPointer { destination in
        try JPEGCenteredChromaReconstruction.writeH2V2BoxRow(
          source: source,
          destination: destination,
          outputWidth: 3
        )
      }
    }
    try boxCr.withUnsafeBufferPointer { source in
      try boxReconstructedCr.withUnsafeMutableBufferPointer { destination in
        try JPEGCenteredChromaReconstruction.writeH2V2BoxRow(
          source: source,
          destination: destination,
          outputWidth: 3
        )
      }
    }
    var boxReference = [UInt8](repeating: 0, count: 9)
    try boxY.withUnsafeBufferPointer { yy in
      try boxReconstructedCb.withUnsafeBufferPointer { cb in
        try boxReconstructedCr.withUnsafeBufferPointer { cr in
          try boxReference.withUnsafeMutableBufferPointer { destination in
            try JPEGYCbCrToRGB.writePlanarRGBRow(
              y: yy,
              cb: cb,
              cr: cr,
              destination: destination,
              writeWidth: 3
            )
          }
        }
      }
    }
    var boxFused = [UInt8](repeating: 0, count: 9)
    try boxY.withUnsafeBufferPointer { yy in
      try boxCb.withUnsafeBufferPointer { cb in
        try boxCr.withUnsafeBufferPointer { cr in
          try boxFused.withUnsafeMutableBufferPointer { destination in
            try JPEGYCbCrToRGB.writeCenteredH2V2RGBRow(
              y: yy,
              currentCb: cb,
              adjacentCb: cb,
              currentCr: cr,
              adjacentCr: cr,
              destination: destination,
              writeWidth: 3,
              usesFancyGlobalContext: false
            )
          }
        }
      }
    }
    XCTAssertEqual(boxFused, boxReference)
  }

  func testKnownIntegerRoundingAndSaturation() throws {
    let input: [UInt8] = [
      100, 129, 127,
      100, 127, 129,
      16, 0, 0,
      240, 255, 255,
    ]
    var output = [UInt8](repeating: 0, count: input.count)
    try input.withUnsafeBufferPointer { source in
      try output.withUnsafeMutableBufferPointer { destination in
        try JPEGYCbCrToRGB.writeInterleavedRGB(yCbCr: source, destination: destination)
      }
    }
    // Matches pinned libjpeg's Cb_g/Cr_g table arithmetic: ONE_HALF is carried only by the Cb
    // contribution before the signed SCALEBITS shift.
    XCTAssertEqual(output, [99, 100, 102, 101, 100, 98, 0, 151, 0, 255, 106, 255])
  }

  func testShapeMismatchFailsClosedWithoutWriting() throws {
    let input: [UInt8] = [1, 2, 3, 4]
    var output = [UInt8](repeating: 0xA5, count: 4)
    XCTAssertThrowsError(
      try input.withUnsafeBufferPointer { source in
        try output.withUnsafeMutableBufferPointer { destination in
          try JPEGYCbCrToRGB.writeInterleavedRGB(yCbCr: source, destination: destination)
        }
      }
    )
    XCTAssertEqual(output, [UInt8](repeating: 0xA5, count: 4))
  }
}
