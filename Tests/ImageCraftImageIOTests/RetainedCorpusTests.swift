import CryptoKit
import Foundation
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class RetainedCorpusTests: XCTestCase {
  func testManifestHashesAndByteCounts_CORPUS_V1_001() throws {
    let manifest = try loadManifest()
    XCTAssertEqual(manifest.schemaVersion, 1)
    XCTAssertEqual(manifest.corpusVersion, "v1")
    XCTAssertEqual(manifest.generator, "imagecraft-retained-corpus-v1")
    XCTAssertEqual(manifest.cases.count, 14)
    XCTAssertEqual(Set(manifest.cases.map(\.id)).count, manifest.cases.count)

    for fixture in manifest.cases {
      let data = try loadData(for: fixture)
      XCTAssertEqual(data.count, fixture.byteCount, fixture.id)
      XCTAssertEqual(sha256(data), fixture.sha256, fixture.id)
    }
  }

  func testValidFixturesProbeAndDecode_CORPUS_V1_002() throws {
    let decoder = ImageIOImageDecoder()
    for fixture in try loadManifest().cases where fixture.kind == .valid {
      let data = try loadData(for: fixture)
      let probe = try decoder.probe(data: data, limits: .coreV1)
      try assertProbe(probe, matches: fixture)

      let decoded = try decoder.decode(
        data: data,
        target: try TargetPixels(
          width: try XCTUnwrap(fixture.width),
          height: try XCTUnwrap(fixture.height)
        ),
        limits: .coreV1
      )
      XCTAssertEqual(decoded.pixelWidth, try XCTUnwrap(fixture.width), fixture.id)
      XCTAssertEqual(decoded.pixelHeight, try XCTUnwrap(fixture.height), fixture.id)
      XCTAssertEqual(decoded.cgImage.colorSpace?.model, .rgb, fixture.id)

      switch fixture.alpha {
      case "present":
        XCTAssertNotEqual(decoded.alphaMode, .none, fixture.id)
      case "none":
        XCTAssertEqual(decoded.alphaMode, .none, fixture.id)
      case nil:
        break
      default:
        XCTFail("Unknown alpha expectation for \(fixture.id)")
      }
    }
  }

  func testFailureFixturesFailClosed_CORPUS_V1_003() throws {
    let decoder = ImageIOImageDecoder()
    for fixture in try loadManifest().cases where fixture.kind == .failure {
      XCTAssertThrowsError(
        try decoder.probe(data: loadData(for: fixture), limits: .coreV1),
        fixture.id
      ) { error in
        XCTAssertEqual(
          error as? ImageCraftError,
          try? expectedError(named: fixture.expectedError),
          fixture.id
        )
      }
    }
  }

  func testMetadataFixturesHonorExactObservedBoundary_CORPUS_V1_004() throws {
    let decoder = ImageIOImageDecoder()
    for fixture in try loadManifest().cases where fixture.kind == .metadataBoundary {
      let data = try loadData(for: fixture)
      let generousProbe = try decoder.probe(data: data, limits: .coreV1)
      try assertProbe(generousProbe, matches: fixture)
      XCTAssertGreaterThanOrEqual(
        generousProbe.metadataByteCount,
        try XCTUnwrap(fixture.containerMetadataBytes),
        fixture.id
      )

      let exactLimits = limits(maximumMetadataBytes: generousProbe.metadataByteCount)
      let exactProbe = try decoder.probe(data: data, limits: exactLimits)
      XCTAssertEqual(exactProbe, generousProbe, fixture.id)

      let rejectingLimits = limits(maximumMetadataBytes: generousProbe.metadataByteCount - 1)
      XCTAssertThrowsError(
        try decoder.probe(data: data, limits: rejectingLimits),
        fixture.id
      ) { error in
        XCTAssertEqual(error as? ImageCraftError, .metadataLimitExceeded, fixture.id)
      }
    }
  }

  func testAnimatedGIFFailsCorePolicyButProbesWithTwoFrameBudget_CORPUS_V1_005() throws {
    let fixture = try XCTUnwrap(
      loadManifest().cases.first { $0.kind == .frameBoundary }
    )
    let data = try loadData(for: fixture)
    let decoder = ImageIOImageDecoder()

    XCTAssertThrowsError(try decoder.probe(data: data, limits: .coreV1)) { error in
      XCTAssertEqual(
        error as? ImageCraftError,
        try? expectedError(named: fixture.expectedCoreError)
      )
    }

    let relaxed = limits(maximumFrameCount: 2)
    let probe = try decoder.probe(data: data, limits: relaxed)
    try assertProbe(probe, matches: fixture)
    let decoded = try decoder.decode(
      data: data,
      target: try TargetPixels(width: 1, height: 1),
      limits: relaxed
    )
    XCTAssertEqual(decoded.pixelWidth, 1)
    XCTAssertEqual(decoded.pixelHeight, 1)
  }

  func testRetainedJPEGStructuresMatchManifest_CORPUS_V1_006() throws {
    for fixture in try loadManifest().cases where fixture.jpegFrame != nil {
      let structure = try inspectJPEG(loadData(for: fixture))
      XCTAssertEqual(structure.frame, fixture.jpegFrame, fixture.id)
      XCTAssertEqual(structure.components, fixture.components, fixture.id)
    }
  }

  private func limits(
    maximumFrameCount: Int = 1,
    maximumMetadataBytes: Int = 4 * 1024 * 1024
  ) -> DecodeLimits {
    DecodeLimits(
      maximumEncodedBytes: 64 * 1024 * 1024,
      maximumDimension: 16_384,
      maximumPixelCount: 100_000_000,
      maximumFrameCount: maximumFrameCount,
      maximumMetadataBytes: maximumMetadataBytes,
      maximumAuxiliaryAttachments: 0,
      allowedFormats: Set(EncodedImageFormat.allCases)
    )
  }

  private func assertProbe(_ probe: ImageProbe, matches fixture: CorpusCase) throws {
    XCTAssertEqual(probe.pixelWidth, try XCTUnwrap(fixture.width), fixture.id)
    XCTAssertEqual(probe.pixelHeight, try XCTUnwrap(fixture.height), fixture.id)
    XCTAssertEqual(probe.frameCount, try XCTUnwrap(fixture.frames), fixture.id)
    XCTAssertEqual(probe.orientation, try XCTUnwrap(fixture.orientation), fixture.id)
    XCTAssertEqual(probe.format.rawValue, try XCTUnwrap(fixture.format), fixture.id)
    XCTAssertEqual(
      probe.sourceColorProfile.rawValue,
      try XCTUnwrap(fixture.sourceColorProfile),
      fixture.id
    )
  }

  private func expectedError(named name: String?) throws -> ImageCraftError {
    switch try XCTUnwrap(name) {
    case "unsupportedOrCorruptImage":
      return .unsupportedOrCorruptImage
    case "frameLimitExceeded":
      return .frameLimitExceeded
    default:
      throw CorpusError.unknownExpectedError
    }
  }

  private func loadManifest() throws -> CorpusManifest {
    let url = try XCTUnwrap(
      Bundle.module.url(
        forResource: "manifest",
        withExtension: "json",
        subdirectory: "Corpus/v1"
      )
    )
    return try JSONDecoder().decode(CorpusManifest.self, from: Data(contentsOf: url))
  }

  private func loadData(for fixture: CorpusCase) throws -> Data {
    let url = try XCTUnwrap(
      Bundle.module.url(
        forResource: fixture.file,
        withExtension: nil,
        subdirectory: "Corpus/v1"
      ),
      fixture.id
    )
    return try Data(contentsOf: url)
  }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func inspectJPEG(_ data: Data) throws -> JPEGFrameStructure {
    guard data.starts(with: [0xFF, 0xD8]) else { throw CorpusError.malformedJPEG }
    var offset = 2
    while offset + 3 < data.count {
      guard data[offset] == 0xFF else { throw CorpusError.malformedJPEG }
      while offset < data.count, data[offset] == 0xFF { offset += 1 }
      guard offset < data.count else { throw CorpusError.malformedJPEG }
      let marker = data[offset]
      offset += 1
      if marker == 0xD9 { break }
      if marker == 0x01 || (0xD0...0xD7).contains(marker) { continue }
      guard offset + 2 <= data.count else { throw CorpusError.malformedJPEG }
      let length = Int(data[offset]) << 8 | Int(data[offset + 1])
      guard length >= 2, offset + length <= data.count else {
        throw CorpusError.malformedJPEG
      }
      if marker == 0xC0 || marker == 0xC2 {
        guard length >= 8 else { throw CorpusError.malformedJPEG }
        return JPEGFrameStructure(
          frame: marker == 0xC0 ? "baseline" : "progressive",
          components: Int(data[offset + 7])
        )
      }
      if marker == 0xDA { break }
      offset += length
    }
    throw CorpusError.malformedJPEG
  }
}

private struct CorpusManifest: Decodable {
  let schemaVersion: Int
  let corpusVersion: String
  let generator: String
  let cases: [CorpusCase]
}

private struct CorpusCase: Decodable {
  enum Kind: String, Decodable {
    case valid
    case failure
    case metadataBoundary
    case frameBoundary
  }

  let id: String
  let file: String
  let kind: Kind
  let byteCount: Int
  let sha256: String
  let format: String?
  let width: Int?
  let height: Int?
  let frames: Int?
  let orientation: UInt32?
  let sourceColorProfile: String?
  let alpha: String?
  let containerMetadataBytes: Int?
  let jpegFrame: String?
  let components: Int?
  let expectedError: String?
  let expectedCoreError: String?
}

private struct JPEGFrameStructure {
  let frame: String
  let components: Int
}

private enum CorpusError: Error {
  case malformedJPEG
  case unknownExpectedError
}
