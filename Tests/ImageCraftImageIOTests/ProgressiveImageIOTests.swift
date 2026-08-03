import Foundation
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class ProgressiveImageIOTests: XCTestCase {
  func testProgressiveJPEGProducesStrictlyIncreasingPartialGenerations() throws {
    let decoder = ImageIOImageDecoder()
    let data = try fixture(named: "jpeg-progressive-420.jpg")
    let session = try decoder.makeProgressiveSession(
      format: .jpeg,
      request: ImageDecodeRequest(target: try TargetPixels(width: 32, height: 32)),
      limits: .coreV1
    )

    var generations: [ImageProgressiveDecodeGeneration] = []
    for chunk in chunks(data, maximumSize: 32) {
      if let generation = try session.append(chunk) {
        generations.append(generation)
      }
    }

    XCTAssertGreaterThanOrEqual(generations.count, 2)
    XCTAssertLessThanOrEqual(generations.count, 4)
    XCTAssertEqual(generations.map(\.generation), Array(1...UInt32(generations.count)))
    XCTAssertEqual(
      generations.map(\.sourceByteCount),
      generations.map(\.sourceByteCount).sorted()
    )
    XCTAssertEqual(Set(generations.map(\.sourceByteCount)).count, generations.count)
    XCTAssertTrue(
      generations.allSatisfy { generation in
        generation.image.pixelWidth <= 32 && generation.image.pixelHeight <= 32
      })
    XCTAssertLessThan(try XCTUnwrap(generations.last?.sourceByteCount), data.count)
    XCTAssertEqual(session.receivedByteCount, data.count)
    try session.finish()
    XCTAssertThrowsError(try session.finish()) { error in
      XCTAssertEqual(error as? ImageCraftError, .progressiveSessionFinished)
    }
  }

  func testSingleByteChunksPreserveProgressiveLifecycle() throws {
    let decoder = ImageIOImageDecoder()
    let data = try fixture(named: "jpeg-progressive-420.jpg")
    let session = try decoder.makeProgressiveSession(
      format: .jpeg,
      request: ImageDecodeRequest(target: try TargetPixels(width: 32, height: 32)),
      limits: .coreV1
    )

    var generations: [ImageProgressiveDecodeGeneration] = []
    for chunk in chunks(data, maximumSize: 1) {
      if let generation = try session.append(chunk) {
        generations.append(generation)
      }
    }

    XCTAssertGreaterThanOrEqual(generations.count, 2)
    XCTAssertLessThanOrEqual(generations.count, 4)
    XCTAssertEqual(generations.map(\.generation), Array(1...UInt32(generations.count)))
    XCTAssertEqual(session.receivedByteCount, data.count)
    try session.finish()
  }

  func testBaselineJPEGFailsClosedWithoutPretendingToBeProgressive() throws {
    let decoder = ImageIOImageDecoder()
    let session = try decoder.makeProgressiveSession(
      format: .jpeg,
      request: ImageDecodeRequest(target: try TargetPixels(width: 32, height: 32)),
      limits: .coreV1
    )
    let data = try fixture(named: "jpeg-baseline-420.jpg")

    var observedFailure: ImageCraftError?
    for chunk in chunks(data, maximumSize: 32) {
      do {
        _ = try session.append(chunk)
      } catch let error as ImageCraftError {
        observedFailure = error
        break
      }
    }
    XCTAssertEqual(observedFailure, .progressiveDecodingUnsupported)
  }

  func testUnsupportedFormatColorPolicyAndEncodedByteLimitFailClosed() throws {
    let decoder = ImageIOImageDecoder()
    let target = try TargetPixels(width: 32, height: 32)
    XCTAssertThrowsError(
      try decoder.makeProgressiveSession(
        format: .png,
        request: ImageDecodeRequest(target: target),
        limits: .coreV1
      )
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .progressiveDecodingUnsupported)
    }
    XCTAssertThrowsError(
      try decoder.makeProgressiveSession(
        format: .jpeg,
        request: ImageDecodeRequest(target: target, colorPolicy: .convertToSRGB),
        limits: .coreV1
      )
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .progressiveDecodingUnsupported)
    }

    let session = try decoder.makeProgressiveSession(
      format: .jpeg,
      request: ImageDecodeRequest(target: target),
      limits: DecodeLimits(maximumEncodedBytes: 8)
    )
    XCTAssertNoThrow(try session.append(Data(repeating: 0, count: 0)))
    XCTAssertThrowsError(try session.append(Data(repeating: 0, count: 9))) { error in
      XCTAssertEqual(error as? ImageCraftError, .encodedBytesExceeded)
    }
  }

  func testCancellationIsIdempotentAndFencesFutureCalls() throws {
    let decoder = ImageIOImageDecoder()
    let session = try decoder.makeProgressiveSession(
      format: .jpeg,
      request: ImageDecodeRequest(target: try TargetPixels(width: 32, height: 32)),
      limits: .coreV1
    )
    _ = try session.append(Data([0xFF, 0xD8]))
    session.cancel()
    session.cancel()
    XCTAssertThrowsError(try session.append(Data([0xFF, 0xD9]))) { error in
      XCTAssertEqual(error as? ImageCraftError, .progressiveSessionCancelled)
    }
    XCTAssertThrowsError(try session.finish()) { error in
      XCTAssertEqual(error as? ImageCraftError, .progressiveSessionCancelled)
    }
  }

  private func fixture(named name: String) throws -> Data {
    let url = try XCTUnwrap(
      Bundle.module.url(
        forResource: name,
        withExtension: nil,
        subdirectory: "Corpus/v1"
      )
    )
    return try Data(contentsOf: url)
  }

  private func chunks(_ data: Data, maximumSize: Int) -> [Data] {
    stride(from: 0, to: data.count, by: maximumSize).map { offset in
      data.subdata(in: offset..<min(data.count, offset + maximumSize))
    }
  }
}
