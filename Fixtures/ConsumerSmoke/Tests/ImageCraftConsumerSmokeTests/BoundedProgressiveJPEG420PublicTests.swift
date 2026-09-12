import Foundation
import XCTest
import ImageCraftCore
import ImageCraftImageIO

final class BoundedProgressiveJPEG420PublicTests: XCTestCase {
  func testExternalHostPreflightsAndFinalizesExactPackedRGB8() throws {
    let source = try fixture()
    XCTAssertEqual(source.count, 787)

    let session: any ProgressiveImagePackedRGB8FinalizingSession =
      try BoundedProgressiveJPEG420Session(maximumCodecOwnedByteCharge: 1 << 20)
    XCTAssertNil(try session.packedRGB8FinalizationResourceLedger())

    var offset = 0
    while offset < source.count {
      let end = min(source.count, offset + 17)
      XCTAssertNil(try session.append(source.subdata(in: offset..<end)))
      offset = end
    }
    XCTAssertEqual(session.receivedByteCount, source.count)

    let ledger = try XCTUnwrap(session.packedRGB8FinalizationResourceLedger())
    XCTAssertEqual(ledger.outputLayoutAuthority, .codecOwnedRGB8)
    let operationPeak = try XCTUnwrap(ledger.bytesUpperBound(for: .operationPeak))
    XCTAssertGreaterThan(operationPeak, 0)
    XCTAssertEqual(ledger.bytesUpperBound(for: .transferredOutput), 23 * 13 * 3)
    XCTAssertEqual(
      ledger.coexistenceBound(for: .operationPeak, callerRetainedBytes: source.count),
      .bounded(operationPeak + source.count)
    )

    let finalization = try session.finishWithPackedRGB8()
    XCTAssertEqual(finalization.sourceByteCount, source.count)
    XCTAssertEqual(finalization.image.pixelWidth, 23)
    XCTAssertEqual(finalization.image.pixelHeight, 13)
    XCTAssertEqual(finalization.image.bytesPerRow, 23 * 3)
    XCTAssertEqual(finalization.image.data.count, 23 * 13 * 3)
    XCTAssertEqual(finalization.image.colorEncoding, .sRGB)
    XCTAssertEqual(finalization.image.sourceColorProfile, .absent)
    XCTAssertEqual(finalization.image.pixelByteCharge, 23 * 13 * 3)
    XCTAssertEqual(finalization.image.transferredByteCharge, 23 * 13 * 3)
    XCTAssertEqual(
      ledger.transferredOutput,
      .bounded(finalization.image.transferredByteCharge)
    )

    XCTAssertThrowsError(try session.append(Data([0x00]))) { error in
      XCTAssertEqual(error as? ImageCraftError, .progressiveSessionFinished)
    }
  }

  func testExternalHostGetsChunkPartitionInvariantPackedFinalization() throws {
    let source = try fixture()
    let whole = try decode(source: source, chunkSize: source.count)
    let bytewise = try decode(source: source, chunkSize: 1)
    let uneven = try decode(source: source, chunkSize: 29)
    XCTAssertEqual(whole.sourceByteCount, source.count)
    XCTAssertEqual(whole.image, bytewise.image)
    XCTAssertEqual(whole.image, uneven.image)
  }

  func testPublicSessionCancellationAndHardBudgetFailClosed() throws {
    let source = try fixture()
    let cancelled = try BoundedProgressiveJPEG420Session(
      maximumCodecOwnedByteCharge: 1 << 20
    )
    XCTAssertNil(try cancelled.append(source.prefix(source.count / 2)))
    cancelled.cancel()
    cancelled.cancel()
    XCTAssertThrowsError(try cancelled.append(source.suffix(1))) { error in
      XCTAssertEqual(error as? ImageCraftError, .progressiveSessionCancelled)
    }
    XCTAssertThrowsError(try cancelled.finishWithPackedRGB8()) { error in
      XCTAssertEqual(error as? ImageCraftError, .progressiveSessionCancelled)
    }

    XCTAssertThrowsError(
      try BoundedProgressiveJPEG420Session(maximumCodecOwnedByteCharge: 1)
    ) { error in
      guard case .operationBudgetExceeded(let required, let maximum) =
        error as? BoundedProgressiveJPEG420Error
      else { return XCTFail("unexpected error: \(error)") }
      XCTAssertGreaterThan(required, maximum)
      XCTAssertEqual(maximum, 1)
    }

    XCTAssertThrowsError(
      try BoundedProgressiveJPEG420Session(maximumCodecOwnedByteCharge: 0)
    ) { error in
      XCTAssertEqual(error as? ImageCodecContractError, .invalidResourceEstimate)
    }
  }

  private func decode(
    source: Data,
    chunkSize: Int
  ) throws -> ImageProgressivePackedRGB8Finalization {
    let session = try BoundedProgressiveJPEG420Session(
      maximumCodecOwnedByteCharge: 1 << 20
    )
    var offset = 0
    while offset < source.count {
      let end = min(source.count, offset + chunkSize)
      XCTAssertNil(try session.append(source.subdata(in: offset..<end)))
      offset = end
    }
    _ = try XCTUnwrap(session.packedRGB8FinalizationResourceLedger())
    return try session.finishWithPackedRGB8()
  }

  private func fixture() throws -> Data {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: "jpeg-progressive-420", withExtension: "jpg")
    )
    return try Data(contentsOf: url)
  }
}
