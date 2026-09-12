import Foundation
import XCTest
import ImageCraftCore
import ImageCraftImageIO

final class BoundedPNG16DecoderPublicTests: XCTestCase {
  private let fixtureBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABEAYAAACksqPJAAAAAXNSR0IArs4c6QAAABlJREFUeNpjEDIJq5i1596H//8ZGBsYhEwAQL8G/rgiw0oAAAAASUVORK5CYII="

  func testExternalHostCanPreflightAndDecodeStraightRGBA16LE() throws {
    let encoded = try XCTUnwrap(Data(base64Encoded: fixtureBase64))
    let expected = Data([
      0x34, 0x12, 0x78, 0x56, 0xbc, 0x9a, 0xf0, 0xde,
      0xff, 0xff, 0x01, 0x00, 0x00, 0x80, 0x34, 0x12,
    ])
    let limits = DecodeLimits(
      maximumEncodedBytes: 1 << 20,
      maximumDimension: 64,
      maximumPixelCount: 4_096,
      maximumFrameCount: 1,
      maximumMetadataBytes: 64 * 1_024,
      maximumAuxiliaryAttachments: 0,
      allowedFormats: [.png]
    )
    let decoder: any ImagePackedRGBA16Decoding = try BoundedPNG16Decoder(
      maximumOperationByteCharge: 1 << 20
    )
    let probe = try decoder.probe(data: encoded, limits: limits)
    XCTAssertEqual(probe.pixelWidth, 2)
    XCTAssertEqual(probe.pixelHeight, 1)
    XCTAssertEqual(probe.frameCount, 1)
    XCTAssertEqual(probe.orientation, 1)
    XCTAssertEqual(probe.format, .png)
    XCTAssertEqual(probe.sourceColorProfile, .standardSRGB)
    XCTAssertEqual(probe.sourceBitsPerComponent, 16)

    let request = ImageDecodeRequest(
      target: try TargetPixels(width: 2, height: 1),
      colorPolicy: .preserveSource
    )
    let ledger = try decoder.packedRGBA16ResourceLedger(
      data: encoded,
      request: request,
      limits: limits
    )
    guard case .bounded = ledger.operationPeak else {
      return XCTFail("bounded PNG16 producer must publish a bounded operation peak")
    }
    XCTAssertEqual(ledger.outputLayoutAuthority, .codecOwnedStraightRGBA16LE)
    XCTAssertEqual(ledger.transferredOutput, .bounded(16))

    let packed = try decoder.decodePackedRGBA16(
      data: encoded,
      request: request,
      limits: limits
    )
    XCTAssertEqual(packed.data, expected)
    XCTAssertEqual(packed.pixelWidth, 2)
    XCTAssertEqual(packed.pixelHeight, 1)
    XCTAssertEqual(packed.bytesPerRow, 16)
    XCTAssertEqual(packed.colorEncoding, .sRGB)
    XCTAssertEqual(packed.sourceColorProfile, .standardSRGB)
    XCTAssertEqual(packed.pixelByteCharge, 16)
    XCTAssertEqual(packed.transferredByteCharge, 16)
  }

  func testExternalHostCanConstructThePublicStraightRGBA16Value() throws {
    let data = Data(repeating: 0, count: 16)
    let value = try XCTUnwrap(
      ImagePackedRGBA16Straight(
        data: data,
        pixelWidth: 2,
        pixelHeight: 1,
        colorEncoding: .sRGB,
        sourceColorProfile: .standardSRGB
      )
    )
    XCTAssertEqual(value.bytesPerRow, 16)
    XCTAssertEqual(value.data, data)
    XCTAssertNil(
      ImagePackedRGBA16Straight(
        data: Data(repeating: 0, count: 15),
        pixelWidth: 2,
        pixelHeight: 1,
        colorEncoding: .sRGB,
        sourceColorProfile: .standardSRGB
      )
    )
  }

  func testPublicPNG16WrapperRejectsColorConversionHighDynamicRangeAndTinyBudget() throws {
    let encoded = try XCTUnwrap(Data(base64Encoded: fixtureBase64))
    let target = try TargetPixels(width: 2, height: 1)
    let decoder = try BoundedPNG16Decoder(maximumOperationByteCharge: 1 << 20)
    let convert = ImageDecodeRequest(target: target, colorPolicy: .convertToSRGB)
    XCTAssertThrowsError(
      try decoder.packedRGBA16ResourceLedger(data: encoded, request: convert, limits: .coreV1)
    ) { XCTAssertEqual($0 as? BoundedPNG16DecodeError, .unsupportedRequest) }

    let high = ImageDecodeRequest(
      target: target,
      colorPolicy: .preserveSource,
      dynamicRange: .high
    )
    XCTAssertThrowsError(
      try decoder.decodePackedRGBA16(data: encoded, request: high, limits: .coreV1)
    ) { XCTAssertEqual($0 as? BoundedPNG16DecodeError, .unsupportedRequest) }

    let tiny = try BoundedPNG16Decoder(maximumOperationByteCharge: 1)
    XCTAssertThrowsError(try tiny.probe(data: encoded, limits: .coreV1)) {
      XCTAssertEqual($0 as? BoundedPNG16DecodeError, .operationBudgetExceeded)
    }
  }
}
