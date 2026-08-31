import Foundation
import XCTest
@testable import ImageCraftImageIO

final class PNGScanlineRGBA8DecoderTests: XCTestCase {
  func testRowwisePremultiplyMatchesFullStraightPipelineAcrossEveryFilter() throws {
    let width = 7
    let height = 5
    var straight = Data(capacity: width * height * 4)
    for row in 0..<height {
      for column in 0..<width {
        straight.append(UInt8((row * 71 + column * 31 + 17) & 0xFF))
        straight.append(UInt8((row * 29 + column * 83 + 41) & 0xFF))
        straight.append(UInt8((row * 47 + column * 19 + 113) & 0xFF))
        straight.append(UInt8((row * 53 + column * 37 + 23) & 0xFF))
      }
    }
    let filtered = try makeFilteredRGBA8Scanlines(
      straight,
      width: width,
      height: height,
      filters: [0, 1, 2, 3, 4]
    )

    let decodedStraight = try PNGScanlineRGBA8Decoder.decode(
      filtered,
      width: width,
      height: height
    )
    XCTAssertEqual(decodedStraight, straight)
    XCTAssertEqual(
      try PNGScanlineRGBA8Decoder.decodePremultipliedRowwise(
        filtered,
        width: width,
        height: height
      ),
      PNGScanlineRGBA8Decoder.premultiplyStraightAlpha(straight)
    )
    XCTAssertEqual(
      try PNGScanlineRGBA8Decoder.inflateAndDecodePremultipliedRowwise(
        RFC1950Zlib.deflate(filtered),
        width: width,
        height: height
      ),
      PNGScanlineRGBA8Decoder.premultiplyStraightAlpha(straight)
    )
  }

  func testStreamingInflateCrossesStagingBoundaryInsideScanline() throws {
    let width = 1_025
    let height = 3
    var straight = Data(capacity: width * height * 4)
    for row in 0..<height {
      for column in 0..<width {
        straight.append(UInt8((row * 71 + column * 31 + 17) & 0xFF))
        straight.append(UInt8((row * 29 + column * 83 + 41) & 0xFF))
        straight.append(UInt8((row * 47 + column * 19 + 113) & 0xFF))
        straight.append(UInt8((row * 53 + column * 37 + 23) & 0xFF))
      }
    }
    let filtered = try makeFilteredRGBA8Scanlines(
      straight,
      width: width,
      height: height,
      filters: [1, 4, 3]
    )
    XCTAssertGreaterThan(width * 4 + 1, 4 * 1024)

    XCTAssertEqual(
      try PNGScanlineRGBA8Decoder.inflateAndDecodePremultipliedRowwise(
        RFC1950Zlib.deflate(filtered),
        width: width,
        height: height
      ),
      PNGScanlineRGBA8Decoder.premultiplyStraightAlpha(straight)
    )
  }

  func testStreamingPremultiplyMatchesReferenceForEveryComponentAlphaPair() throws {
    let width = 256 * 256
    let height = 1
    var straight = Data(capacity: width * 4)
    for alpha in 0...255 {
      for component in 0...255 {
        let value = UInt8(component)
        straight.append(contentsOf: [value, value, value, UInt8(alpha)])
      }
    }
    let filtered = try makeFilteredRGBA8Scanlines(
      straight,
      width: width,
      height: height,
      filters: [0]
    )
    let expected = PNGScanlineRGBA8Decoder.premultiplyStraightAlpha(straight)
    XCTAssertEqual(
      try PNGScanlineRGBA8Decoder.inflateAndDecodePremultipliedRowwise(
        RFC1950Zlib.deflate(filtered),
        width: width,
        height: height
      ),
      expected
    )
  }

  func testRowwisePremultiplyRejectsInvalidFilterAndByteCount() throws {
    let width = 2
    let height = 1
    XCTAssertThrowsError(
      try PNGScanlineRGBA8Decoder.decodePremultipliedRowwise(
        Data([5] + Array(repeating: 0, count: 8)),
        width: width,
        height: height
      )
    ) { XCTAssertEqual($0 as? PNGScanlineRGBA8Error, .invalidFilter) }
    XCTAssertThrowsError(
      try PNGScanlineRGBA8Decoder.decodePremultipliedRowwise(
        Data([0, 1, 2]),
        width: width,
        height: height
      )
    ) { XCTAssertEqual($0 as? PNGScanlineRGBA8Error, .decodedByteCountMismatch) }
  }
}

private func makeFilteredRGBA8Scanlines(
  _ straight: Data,
  width: Int,
  height: Int,
  filters: [UInt8]
) throws -> Data {
  let rowBytes = width * 4
  guard straight.count == rowBytes * height, filters.count == height else {
    throw PNGScanlineRGBA8Error.decodedByteCountMismatch
  }
  var output = Data(capacity: (rowBytes + 1) * height)
  for row in 0..<height {
    let filter = filters[row]
    output.append(filter)
    for column in 0..<rowBytes {
      let value = straight[row * rowBytes + column]
      let left = column >= 4 ? straight[row * rowBytes + column - 4] : 0
      let above = row > 0 ? straight[(row - 1) * rowBytes + column] : 0
      let upperLeft = row > 0 && column >= 4
        ? straight[(row - 1) * rowBytes + column - 4]
        : 0
      let predictor: UInt8
      switch filter {
      case 0: predictor = 0
      case 1: predictor = left
      case 2: predictor = above
      case 3: predictor = UInt8((UInt16(left) + UInt16(above)) >> 1)
      case 4: predictor = testPaeth(left: left, above: above, upperLeft: upperLeft)
      default: throw PNGScanlineRGBA8Error.invalidFilter
      }
      output.append(value &- predictor)
    }
  }
  return output
}

private func testPaeth(left: UInt8, above: UInt8, upperLeft: UInt8) -> UInt8 {
  let prediction = Int(left) + Int(above) - Int(upperLeft)
  let leftDistance = abs(prediction - Int(left))
  let aboveDistance = abs(prediction - Int(above))
  let upperLeftDistance = abs(prediction - Int(upperLeft))
  if leftDistance <= aboveDistance, leftDistance <= upperLeftDistance { return left }
  return aboveDistance <= upperLeftDistance ? above : upperLeft
}
