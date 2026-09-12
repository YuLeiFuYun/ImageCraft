import Foundation
import XCTest
import ImageCraftCore

@testable import ImageCraftImageIO

final class BoundedBaselineJPEGDecoderTests: XCTestCase {
  func testPublicDecoderRoutesQualified420422444WithExactLedgersAndPixels() throws {
    struct Case {
      let sampling: String
      let source: Data
      let expectedRGB: Data
      let width: Int
      let height: Int
      let exactOperationByteCharge: Int
    }

    let baseline420 = try fixture(named: "jpeg-baseline-420.jpg", subdirectory: "Corpus/v1")
    let reference420 = try JPEGIndependentBaseline420Decoder(
      maximumOperationByteCharge: 3_777
    ).decode(baseline420).rgb
    let cases = [
      Case(
        sampling: "grayscale",
        source: try fixture(named: "jpeg-grayscale.jpg", subdirectory: "Corpus/v1"),
        expectedRGB: try fixture(
          named: "jpeg-baseline-grayscale-19x11.rgb",
          subdirectory: "Corpus/BaselinePublicV1"
        ),
        width: 19,
        height: 11,
        exactOperationByteCharge: 836
      ),
      Case(
        sampling: "420",
        source: baseline420,
        expectedRGB: reference420,
        width: 23,
        height: 13,
        exactOperationByteCharge: 3_777
      ),
      Case(
        sampling: "422",
        source: try fixture(
          named: "jpeg-baseline-422-23x13.jpg",
          subdirectory: "Corpus/BaselinePublicV1"
        ),
        expectedRGB: try fixture(
          named: "jpeg-baseline-422-23x13.rgb",
          subdirectory: "Corpus/BaselinePublicV1"
        ),
        width: 23,
        height: 13,
        exactOperationByteCharge: 3_073
      ),
      Case(
        sampling: "444",
        source: try fixture(
          named: "jpeg-baseline-444-23x13.jpg",
          subdirectory: "Corpus/BaselinePublicV1"
        ),
        expectedRGB: try fixture(
          named: "jpeg-baseline-444-23x13.rgb",
          subdirectory: "Corpus/BaselinePublicV1"
        ),
        width: 23,
        height: 13,
        exactOperationByteCharge: 1_601
      ),
    ]

    for item in cases {
      let decoder: any ImagePackedRGB8Decoding = try BoundedBaselineJPEGDecoder(
        maximumOperationByteCharge: item.exactOperationByteCharge
      )
      let probe = try decoder.probe(data: item.source, limits: .coreV1)
      XCTAssertEqual(probe.format, .jpeg, item.sampling)
      XCTAssertEqual(probe.pixelWidth, item.width, item.sampling)
      XCTAssertEqual(probe.pixelHeight, item.height, item.sampling)
      XCTAssertEqual(probe.frameCount, 1, item.sampling)
      XCTAssertEqual(probe.orientation, 1, item.sampling)
      XCTAssertEqual(probe.sourceColorProfile, .absent, item.sampling)
      XCTAssertEqual(probe.sourceBitsPerComponent, 8, item.sampling)

      let request = try qualifiedRequest(width: item.width, height: item.height)
      let ledger = try decoder.packedRGB8ResourceLedger(
        data: item.source,
        request: request,
        limits: .coreV1
      )
      XCTAssertEqual(ledger.retainedKnownBytes, 0, item.sampling)
      XCTAssertEqual(ledger.retainedBetweenCalls, .bounded(0), item.sampling)
      XCTAssertEqual(
        ledger.operationPeak,
        .bounded(item.exactOperationByteCharge),
        item.sampling
      )
      let transferByteCount = item.width * item.height * 3
      XCTAssertEqual(ledger.transferredOutput, .bounded(transferByteCount), item.sampling)
      XCTAssertEqual(ledger.outputLayoutAuthority, .codecOwnedRGB8, item.sampling)
      XCTAssertEqual(
        ledger.coexistenceBound(
          for: .operationPeak,
          callerRetainedBytes: item.source.count
        ),
        .bounded(item.exactOperationByteCharge + item.source.count),
        item.sampling
      )

      let decoded = try decoder.decodePackedRGB8(
        data: item.source,
        request: request,
        limits: .coreV1
      )
      XCTAssertEqual(decoded.pixelWidth, item.width, item.sampling)
      XCTAssertEqual(decoded.pixelHeight, item.height, item.sampling)
      XCTAssertEqual(decoded.bytesPerRow, item.width * 3, item.sampling)
      XCTAssertEqual(decoded.data.count, transferByteCount, item.sampling)
      XCTAssertEqual(decoded.data, item.expectedRGB, item.sampling)
      XCTAssertEqual(decoded.colorEncoding, .sRGB, item.sampling)
      XCTAssertEqual(decoded.sourceColorProfile, .absent, item.sampling)
      XCTAssertEqual(decoded.transferredByteCharge, transferByteCount, item.sampling)
    }
  }

  func testPublicDecoderRejectsChargeMinusOneForEveryQualifiedSampling() throws {
    let cases: [(source: Data, width: Int, height: Int, required: Int)] = [
      (try fixture(named: "jpeg-grayscale.jpg", subdirectory: "Corpus/v1"), 19, 11, 836),
      (try fixture(named: "jpeg-baseline-420.jpg", subdirectory: "Corpus/v1"), 23, 13, 3_777),
      (
        try fixture(
          named: "jpeg-baseline-422-23x13.jpg",
          subdirectory: "Corpus/BaselinePublicV1"
        ),
        23,
        13,
        3_073
      ),
      (
        try fixture(
          named: "jpeg-baseline-444-23x13.jpg",
          subdirectory: "Corpus/BaselinePublicV1"
        ),
        23,
        13,
        1_601
      ),
    ]
    for item in cases {
      let request = try qualifiedRequest(width: item.width, height: item.height)
      let maximum = item.required - 1
      let decoder = try BoundedBaselineJPEGDecoder(maximumOperationByteCharge: maximum)
      for operation: () throws -> Void in [
        {
          _ = try decoder.packedRGB8ResourceLedger(
            data: item.source,
            request: request,
            limits: .coreV1
          )
        },
        {
          _ = try decoder.decodePackedRGB8(
            data: item.source,
            request: request,
            limits: .coreV1
          )
        },
      ] {
        XCTAssertThrowsError(try operation()) { error in
          XCTAssertEqual(
            error as? BoundedBaselineJPEGDecodeError,
            .operationBudgetExceeded(requiredBytes: item.required, maximumBytes: maximum)
          )
        }
      }
    }
  }

  func testPublicDecoderKeepsRequestAndSourceDomainNarrow() throws {
    let data = try fixture(named: "jpeg-baseline-420.jpg", subdirectory: "Corpus/v1")
    let decoder = try BoundedBaselineJPEGDecoder(maximumOperationByteCharge: 1 << 20)
    let requests = [
      ImageDecodeRequest(
        target: try TargetPixels(width: 23, height: 13),
        contentMode: .fit,
        colorPolicy: .preserveSource
      ),
      ImageDecodeRequest(
        target: try TargetPixels(width: 23, height: 13),
        contentMode: .fill,
        colorPolicy: .convertToSRGB
      ),
      ImageDecodeRequest(
        target: try TargetPixels(width: 22, height: 13),
        contentMode: .fit,
        colorPolicy: .convertToSRGB
      ),
      ImageDecodeRequest(
        target: try TargetPixels(width: 23, height: 13),
        contentMode: .fit,
        colorPolicy: .convertToSRGB,
        dynamicRange: .high
      ),
    ]
    for request in requests {
      XCTAssertThrowsError(
        try decoder.packedRGB8ResourceLedger(data: data, request: request, limits: .coreV1)
      ) { error in
        XCTAssertEqual(error as? BoundedBaselineJPEGDecodeError, .unsupportedRequest)
      }
    }

    XCTAssertThrowsError(
      try decoder.probe(
        data: try fixture(named: "jpeg-progressive-420.jpg", subdirectory: "Corpus/v1"),
        limits: .coreV1
      )
    ) { error in
      XCTAssertEqual(error as? BoundedBaselineJPEGDecodeError, .unsupportedSourceSemantics)
    }

    let grayscale = try fixture(named: "jpeg-grayscale.jpg", subdirectory: "Corpus/v1")
    XCTAssertThrowsError(
      try decoder.probe(data: try removingFirstJFIFAPP0(from: grayscale), limits: .coreV1)
    ) { error in
      XCTAssertEqual(error as? BoundedBaselineJPEGDecodeError, .unsupportedSourceSemantics)
    }
  }

  func testPublicDecoderRejectsDuplicateAdobeColorAuthorityAcrossQualifiedSamplingUnion() throws {
    let sources = [
      try fixture(named: "jpeg-baseline-420.jpg", subdirectory: "Corpus/v1"),
      try fixture(
        named: "jpeg-baseline-422-23x13.jpg",
        subdirectory: "Corpus/BaselinePublicV1"
      ),
      try fixture(
        named: "jpeg-baseline-444-23x13.jpg",
        subdirectory: "Corpus/BaselinePublicV1"
      ),
    ]
    let decoder = try BoundedBaselineJPEGDecoder(maximumOperationByteCharge: 1 << 20)
    for source in sources {
      let duplicateAdobe = try insertingDuplicateQualifiedAdobe(into: source)
      XCTAssertThrowsError(try decoder.probe(data: duplicateAdobe, limits: .coreV1)) { error in
        XCTAssertEqual(error as? BoundedBaselineJPEGDecodeError, .unsupportedSourceSemantics)
      }
    }
  }

  private func qualifiedRequest(width: Int, height: Int) throws -> ImageDecodeRequest {
    ImageDecodeRequest(
      target: try TargetPixels(width: width, height: height),
      contentMode: .fit,
      colorPolicy: .convertToSRGB
    )
  }

  private func fixture(named name: String, subdirectory: String) throws -> Data {
    let url = try XCTUnwrap(
      Bundle.module.url(
        forResource: name,
        withExtension: nil,
        subdirectory: subdirectory
      )
    )
    return try Data(contentsOf: url)
  }

  private func insertingDuplicateQualifiedAdobe(into source: Data) throws -> Data {
    guard source.count >= 6,
      Array(source[0..<4]) == [0xFF, 0xD8, 0xFF, 0xE0]
    else { throw ImageCraftError.unsupportedOrCorruptImage }
    let jfifLength = Int(source[4]) << 8 | Int(source[5])
    let insertionOffset = 4 + jfifLength
    guard insertionOffset <= source.count else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    var app14 = Data([0xFF, 0xEE, 0x00, 0x0E])
    app14.append(Data("Adobe".utf8))
    app14.append(contentsOf: [0x00, 0x64, 0x00, 0x00, 0x00, 0x00, 0x01])
    var result = Data()
    result.reserveCapacity(source.count + app14.count * 2)
    result.append(source.prefix(insertionOffset))
    result.append(app14)
    result.append(app14)
    result.append(source.dropFirst(insertionOffset))
    return result
  }

  private func removingFirstJFIFAPP0(from source: Data) throws -> Data {
    guard source.count >= 6,
      Array(source[0..<4]) == [0xFF, 0xD8, 0xFF, 0xE0]
    else { throw ImageCraftError.unsupportedOrCorruptImage }
    let jfifLength = Int(source[4]) << 8 | Int(source[5])
    let app0End = 4 + jfifLength
    guard app0End <= source.count else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    var result = Data(source.prefix(2))
    result.append(source.dropFirst(app0End))
    return result
  }
}
