import Foundation
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class BoundedBaselineJPEGPublicTests: XCTestCase {
  func testExternalHostUsesPublicRGB8ProtocolWithExactLedgerAndPixels() throws {
    let source = try fixture()
    XCTAssertEqual(source.count, 856)
    let decoder: any ImagePackedRGB8Decoding = try BoundedBaselineJPEGDecoder(
      maximumOperationByteCharge: 3_777
    )
    let request = ImageDecodeRequest(
      target: try TargetPixels(width: 23, height: 13),
      colorPolicy: .convertToSRGB
    )

    let probe = try decoder.probe(data: source, limits: .coreV1)
    XCTAssertEqual(probe.pixelWidth, 23)
    XCTAssertEqual(probe.pixelHeight, 13)
    XCTAssertEqual(probe.format, .jpeg)
    XCTAssertEqual(probe.sourceColorProfile, .absent)
    XCTAssertEqual(probe.sourceBitsPerComponent, 8)

    let ledger = try decoder.packedRGB8ResourceLedger(
      data: source,
      request: request,
      limits: .coreV1
    )
    XCTAssertEqual(ledger.operationPeak, .bounded(3_777))
    XCTAssertEqual(ledger.transferredOutput, .bounded(897))
    XCTAssertEqual(ledger.outputLayoutAuthority, .codecOwnedRGB8)
    XCTAssertEqual(
      ledger.coexistenceBound(for: .operationPeak, callerRetainedBytes: source.count),
      .bounded(3_777 + source.count)
    )

    let image = try decoder.decodePackedRGB8(
      data: source,
      request: request,
      limits: .coreV1
    )
    XCTAssertEqual(image.pixelWidth, 23)
    XCTAssertEqual(image.pixelHeight, 13)
    XCTAssertEqual(image.bytesPerRow, 69)
    XCTAssertEqual(image.data.count, 897)
    XCTAssertEqual(image.pixelByteCharge, 897)
    XCTAssertEqual(image.transferredByteCharge, 897)
    XCTAssertEqual(image.colorEncoding, .sRGB)
    XCTAssertEqual(image.sourceColorProfile, .absent)
  }

  func testExternalHostSeesStableRequestAndBudgetFailures() throws {
    let source = try fixture()
    let request = ImageDecodeRequest(
      target: try TargetPixels(width: 23, height: 13),
      colorPolicy: .convertToSRGB
    )
    let underBudget = try BoundedBaselineJPEGDecoder(
      maximumOperationByteCharge: 3_776
    )
    XCTAssertThrowsError(
      try underBudget.packedRGB8ResourceLedger(
        data: source,
        request: request,
        limits: .coreV1
      )
    ) { error in
      XCTAssertEqual(
        error as? BoundedBaselineJPEGDecodeError,
        .operationBudgetExceeded(requiredBytes: 3_777, maximumBytes: 3_776)
      )
    }

    let decoder = try BoundedBaselineJPEGDecoder(
      maximumOperationByteCharge: 3_777
    )
    let preserve = ImageDecodeRequest(
      target: try TargetPixels(width: 23, height: 13),
      colorPolicy: .preserveSource
    )
    XCTAssertThrowsError(
      try decoder.decodePackedRGB8(data: source, request: preserve, limits: .coreV1)
    ) { error in
      XCTAssertEqual(error as? BoundedBaselineJPEGDecodeError, .unsupportedRequest)
    }
  }

  func testExternalHostCanDecodeExactFirstJFIFGrayscaleAsBoundedRGB8() throws {
    let source = try fixture(named: "jpeg-grayscale", extension: "jpg")
    let expected = try fixture(named: "jpeg-grayscale-19x11", extension: "rgb")
    XCTAssertEqual(source.count, 543)
    XCTAssertEqual(expected.count, 627)

    let decoder: any ImagePackedRGB8Decoding = try BoundedBaselineJPEGDecoder(
      maximumOperationByteCharge: 836
    )
    let request = ImageDecodeRequest(
      target: try TargetPixels(width: 19, height: 11),
      colorPolicy: .convertToSRGB
    )
    let ledger = try decoder.packedRGB8ResourceLedger(
      data: source,
      request: request,
      limits: .coreV1
    )
    XCTAssertEqual(ledger.operationPeak, .bounded(836))
    XCTAssertEqual(ledger.transferredOutput, .bounded(627))
    XCTAssertEqual(
      ledger.coexistenceBound(for: .operationPeak, callerRetainedBytes: source.count),
      .bounded(836 + 543)
    )
    let image = try decoder.decodePackedRGB8(
      data: source,
      request: request,
      limits: .coreV1
    )
    XCTAssertEqual(image.pixelWidth, 19)
    XCTAssertEqual(image.pixelHeight, 11)
    XCTAssertEqual(image.bytesPerRow, 57)
    XCTAssertEqual(image.data, expected)
    XCTAssertEqual(image.colorEncoding, .sRGB)
    XCTAssertEqual(image.sourceColorProfile, .absent)
  }

  private func fixture() throws -> Data {
    try fixture(named: "jpeg-baseline-420", extension: "jpg")
  }

  private func fixture(named name: String, extension ext: String) throws -> Data {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: name, withExtension: ext)
    )
    return try Data(contentsOf: url)
  }
}
