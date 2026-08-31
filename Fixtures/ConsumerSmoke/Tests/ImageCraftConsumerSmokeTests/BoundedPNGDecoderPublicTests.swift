import Foundation
import XCTest
import ImageCraftCore
import ImageCraftImageIO

final class BoundedPNGDecoderPublicTests: XCTestCase {
  func testExternalHostCanPreflightAndDecodeBoundedPackedRGBA8() throws {
    let pixels = Data([
      255, 0, 0, 255,
      0, 128, 255, 255,
    ])
    let encoded = try XCTUnwrap(Data(
      base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAAAXNSR0IArs4c6QAAABFJREFUeNpj+M/A8J+h4f9/ABF5BH1k603MAAAAAElFTkSuQmCC"
    ))

    let limits = DecodeLimits(
      maximumEncodedBytes: 1 << 20,
      maximumDimension: 64,
      maximumPixelCount: 4_096,
      maximumFrameCount: 1,
      maximumMetadataBytes: 64 * 1024,
      maximumAuxiliaryAttachments: 0,
      allowedFormats: [.png]
    )
    let decoder: any ImagePackedRGBA8Decoding = try BoundedPNGDecoder(
      maximumOperationByteCharge: 1 << 20
    )
    let probe = try decoder.probe(data: encoded, limits: limits)
    XCTAssertEqual(probe.pixelWidth, 2)
    XCTAssertEqual(probe.pixelHeight, 1)
    XCTAssertEqual(probe.frameCount, 1)
    XCTAssertEqual(probe.orientation, 1)
    XCTAssertEqual(probe.format, .png)

    let request = ImageDecodeRequest(
      target: try TargetPixels(width: probe.pixelWidth, height: probe.pixelHeight),
      colorPolicy: .preserveSource
    )
    let ledger = try decoder.packedRGBA8ResourceLedger(
      data: encoded,
      request: request,
      limits: limits
    )
    guard case .bounded = ledger.operationPeak else {
      return XCTFail("bounded PNG producer must publish a bounded operation peak")
    }
    XCTAssertEqual(ledger.outputLayoutAuthority, .codecOwnedRGBA8)

    let packed = try decoder.decodePackedRGBA8(
      data: encoded,
      request: request,
      limits: limits
    )
    XCTAssertEqual(packed.data, pixels)
    XCTAssertEqual(packed.bytesPerRow, 8)
    XCTAssertEqual(ledger.transferredOutput, .bounded(packed.transferredByteCharge))
  }

  func testPublicInitializerRejectsNonPositiveOperationBudget() throws {
    XCTAssertThrowsError(try BoundedPNGDecoder(maximumOperationByteCharge: 0))
    XCTAssertThrowsError(try BoundedPNGDecoder(maximumOperationByteCharge: -1))
  }

  func testExternalHostMustExplicitlyRequestSRGBFallbackForUntaggedPNG() throws {
    let encoded = try XCTUnwrap(Data(
      base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAAEUlEQVR42mP4z8Dwn6Hh/38AEXkEfWTrTcwAAAAASUVORK5CYII="
    ))
    let expected = Data([
      255, 0, 0, 255,
      0, 128, 255, 255,
    ])
    let limits = DecodeLimits(
      maximumEncodedBytes: 1 << 20,
      maximumDimension: 64,
      maximumPixelCount: 4_096,
      maximumFrameCount: 1,
      maximumMetadataBytes: 64 * 1024,
      maximumAuxiliaryAttachments: 0,
      allowedFormats: [.png]
    )
    let decoder: any ImagePackedRGBA8Decoding = try BoundedPNGDecoder(
      maximumOperationByteCharge: 1 << 20
    )
    let probe = try decoder.probe(data: encoded, limits: limits)
    XCTAssertEqual(probe.sourceColorProfile, .absent)

    let target = try TargetPixels(width: probe.pixelWidth, height: probe.pixelHeight)
    let preserve = ImageDecodeRequest(target: target, colorPolicy: .preserveSource)
    XCTAssertThrowsError(
      try decoder.decodePackedRGBA8(data: encoded, request: preserve, limits: limits)
    ) {
      XCTAssertEqual($0 as? BoundedPNGDecodeError, .unsupportedSourceSemantics)
    }

    let convert = ImageDecodeRequest(target: target, colorPolicy: .convertToSRGB)
    let ledger = try decoder.packedRGBA8ResourceLedger(
      data: encoded,
      request: convert,
      limits: limits
    )
    guard case .bounded = ledger.operationPeak else {
      return XCTFail("untagged fallback must remain a bounded codec operation")
    }
    let packed = try decoder.decodePackedRGBA8(data: encoded, request: convert, limits: limits)
    XCTAssertEqual(packed.data, expected)
    XCTAssertEqual(packed.colorEncoding, .sRGB)
    XCTAssertEqual(packed.sourceColorProfile, .absent)
    XCTAssertEqual(ledger.transferredOutput, .bounded(packed.transferredByteCharge))
  }

  func testExternalHostCanClassifyOperationBudgetFailure() throws {
    let encoded = try XCTUnwrap(Data(
      base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAAAXNSR0IArs4c6QAAABFJREFUeNpj+M/A8J+h4f9/ABF5BH1k603MAAAAAElFTkSuQmCC"
    ))
    let decoder = try BoundedPNGDecoder(maximumOperationByteCharge: 1)
    XCTAssertThrowsError(try decoder.probe(data: encoded, limits: .coreV1)) {
      XCTAssertEqual($0 as? BoundedPNGDecodeError, .operationBudgetExceeded)
    }
  }
}
