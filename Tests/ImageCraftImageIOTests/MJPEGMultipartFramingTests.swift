import Foundation
import XCTest
@testable import ImageCraftImageIO

final class MJPEGMultipartFramingTests: XCTestCase {
  private let boundary = "imagecraft-boundary_42"
  private let frameA = Data([0xFF, 0xD8, 0x01, 0x02, 0x03, 0xFF, 0xD9])
  private let frameB = Data([0xFF, 0xD8, 0x10, 0x0D, 0x0A, 0x20, 0x30, 0xFF, 0xD9])

  func testContentTypeBoundaryParserIsStrictAndDeterministic_MJPEG_PT_001() throws {
    XCTAssertEqual(
      try MJPEGMultipartContentType.boundary(
        from: "multipart/x-mixed-replace; boundary=imagecraft-boundary_42"
      ),
      boundary
    )
    XCTAssertEqual(
      try MJPEGMultipartContentType.boundary(
        from: "Multipart/X-Mixed-Replace; charset=ignored; boundary=\"imagecraft-boundary_42\""
      ),
      boundary
    )
    for invalid in [
      "image/jpeg; boundary=imagecraft-boundary_42",
      "multipart/x-mixed-replace",
      "multipart/x-mixed-replace; boundary=a; boundary=b",
      "multipart/x-mixed-replace; boundary=has space",
      "multipart/x-mixed-replace; boundary=\"unterminated",
    ] {
      XCTAssertThrowsError(try MJPEGMultipartContentType.boundary(from: invalid))
    }
  }

  func testArbitraryChunkingFramesContentLengthAndBoundaryDelimitedParts_MJPEG_PT_002() throws {
    let body = multipartBody()
    let whole = try parse(body, chunkSizes: [body.count])
    let bytewise = try parse(body, chunkSizes: Array(repeating: 1, count: body.count))
    let uneven = try parse(body, chunkSizes: [2, 7, 1, 31, 3, 5, 11])
    XCTAssertEqual(whole, [frameA, frameB])
    XCTAssertEqual(bytewise, whole)
    XCTAssertEqual(uneven, whole)
  }

  func testFramePublicationWaitsForValidatedFollowingDelimiter_MJPEG_PT_003() throws {
    var parser = try MJPEGMultipartFramingParser(
      boundary: boundary,
      maximumHeaderBytes: 1_024,
      maximumFrameBytes: 1_024,
      maximumFrameCount: 2
    )
    let prefix = Data(("--\(boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(frameA.count)\r\n\r\n").utf8)
      + frameA
    var frames: [Data] = []
    try parser.append(prefix) { frames.append($0) }
    XCTAssertEqual(frames, [])
    XCTAssertEqual(parser.snapshot.retainedFrameBytes, frameA.count)
    try parser.append(Data("\r\n--\(boundary)".utf8)) { frames.append($0) }
    XCTAssertEqual(frames, [])
    XCTAssertEqual(parser.snapshot.retainedFrameBytes, frameA.count)
    try parser.append(Data("\r\n".utf8)) { frames.append($0) }
    XCTAssertEqual(frames, [frameA])
    XCTAssertEqual(parser.snapshot.retainedFrameBytes, 0)
  }

  func testLogicalRetentionStaysWithinFrameOrHeaderAndDelimiterBounds_MJPEG_PT_004() throws {
    let body = multipartBody()
    var parser = try MJPEGMultipartFramingParser(
      boundary: boundary,
      maximumHeaderBytes: 256,
      maximumFrameBytes: 64,
      maximumFrameCount: 2
    )
    var frames: [Data] = []
    for byte in body {
      try parser.append(Data([byte])) { frames.append($0) }
      let snapshot = parser.snapshot
      XCTAssertLessThanOrEqual(snapshot.retainedHeaderBytes, 256)
      XCTAssertLessThanOrEqual(snapshot.retainedFrameBytes, 64)
      XCTAssertLessThanOrEqual(
        snapshot.retainedDelimiterCandidateBytes,
        Data("\r\n--\(boundary)".utf8).count + 1
      )
      XCTAssertLessThanOrEqual(
        snapshot.logicalRetainedBytes,
        max(256, 64 + Data("\r\n--\(boundary)".utf8).count + 1)
      )
    }
    try parser.finish()
    XCTAssertEqual(frames, [frameA, frameB])
    XCTAssertEqual(parser.snapshot.logicalRetainedBytes, 0)
    XCTAssertTrue(parser.snapshot.isTerminal)
  }

  func testLimitsAndUnsupportedTransferSemanticsFailClosedAndFenceSession_MJPEG_PT_005() throws {
    let oversized = Data(
      ("--\(boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: 999\r\n\r\n").utf8
    )
    var parser = try MJPEGMultipartFramingParser(
      boundary: boundary,
      maximumHeaderBytes: 128,
      maximumFrameBytes: 16,
      maximumFrameCount: 1
    )
    XCTAssertThrowsError(try parser.append(oversized) { _ in }) { error in
      XCTAssertEqual(error as? MJPEGMultipartFramingError, .frameByteLimitExceeded)
    }
    XCTAssertEqual(parser.snapshot.logicalRetainedBytes, 0)
    XCTAssertThrowsError(try parser.append(Data([0x00])) { _ in }) { error in
      XCTAssertEqual(error as? MJPEGMultipartFramingError, .sessionFailed)
    }

    let encoded = Data(
      ("--\(boundary)\r\nContent-Type: image/jpeg\r\nContent-Transfer-Encoding: base64\r\n\r\n").utf8
    )
    var unsupported = try MJPEGMultipartFramingParser(
      boundary: boundary,
      maximumHeaderBytes: 256,
      maximumFrameBytes: 64,
      maximumFrameCount: 1
    )
    XCTAssertThrowsError(try unsupported.append(encoded) { _ in }) { error in
      XCTAssertEqual(error as? MJPEGMultipartFramingError, .unsupportedPartSemantics)
    }
  }

  func testLengthMismatchMalformedClosingAndNonJPEGBodyNeverPublish_MJPEG_PT_006() throws {
    var shortLength = Data(
      ("--\(boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: 3\r\n\r\n").utf8
    )
    shortLength.append(frameA)
    shortLength.append(Data("\r\n--\(boundary)--\r\n".utf8))
    var parser = try MJPEGMultipartFramingParser(
      boundary: boundary,
      maximumFrameBytes: 64,
      maximumFrameCount: 2
    )
    XCTAssertThrowsError(try parser.append(shortLength) { _ in }) { error in
      XCTAssertEqual(error as? MJPEGMultipartFramingError, .malformedMultipart)
    }

    let notJPEG = Data(
      ("--\(boundary)\r\nContent-Type: image/jpeg\r\n\r\nnot-a-jpeg\r\n--\(boundary)--\r\n").utf8
    )
    var nonJPEGParser = try MJPEGMultipartFramingParser(
      boundary: boundary,
      maximumFrameBytes: 64,
      maximumFrameCount: 1
    )
    XCTAssertThrowsError(try nonJPEGParser.append(notJPEG) { _ in }) { error in
      XCTAssertEqual(error as? MJPEGMultipartFramingError, .unsupportedPartSemantics)
    }
  }

  func testRealBaselineAndProgressiveJPEGFramesRemainByteExactAndDecodable_MJPEG_PT_007() throws {
    let baseline = try retainedJPEG(named: "jpeg-baseline-420.jpg")
    let progressive = try retainedJPEG(named: "jpeg-progressive-420.jpg")
    var body = Data(
      ("--\(boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(baseline.count)\r\n\r\n").utf8
    )
    body.append(baseline)
    body.append(Data("\r\n--\(boundary)\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
    body.append(progressive)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))

    let frames = try parse(
      body,
      chunkSizes: [1, 2, 3, 5, 8, 13, 21, 34],
      maximumFrameBytes: max(baseline.count, progressive.count)
    )
    XCTAssertEqual(frames, [baseline, progressive])

    let baselinePlan = try JPEGIndependentBaseline420StatePlan.inspect(baseline)
    let baselineCharge = baselinePlan.totalStateBytes + baselinePlan.width * baselinePlan.height * 3
    let directBaseline = try JPEGIndependentBaseline420Decoder(
      maximumOperationByteCharge: baselineCharge
    ).decode(baseline)
    let framedBaseline = try JPEGIndependentBaseline420Decoder(
      maximumOperationByteCharge: baselineCharge
    ).decode(frames[0])
    XCTAssertEqual(framedBaseline.rgb, directBaseline.rgb)

    let progressivePlan = try JPEGIndependentProgressive420StatePlan.inspect(progressive)
    let progressiveCharge = progressivePlan.totalStateBytes
      + progressivePlan.width * progressivePlan.height * 3
    let directProgressive = try JPEGIndependentProgressive420Decoder(
      maximumOperationByteCharge: progressiveCharge
    ).decode(progressive)
    let framedProgressive = try JPEGIndependentProgressive420Decoder(
      maximumOperationByteCharge: progressiveCharge
    ).decode(frames[1])
    XCTAssertEqual(framedProgressive.rgb, directProgressive.rgb)
  }

  func testBoundaryPrefixNearMissIsPreservedInsideBoundaryDelimitedJPEG_MJPEG_PT_008() throws {
    var frame = Data([0xFF, 0xD8, 0x44, 0x55])
    frame.append(Data("\r\n--imagecraft-boundary_4X-not-a-delimiter\r\n".utf8))
    frame.append(contentsOf: [0x66, 0x77, 0xFF, 0xD9])
    var body = Data(
      ("--\(boundary)\r\nContent-Type: image/jpeg\r\n\r\n").utf8
    )
    body.append(frame)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))

    let frames = try parse(body, chunkSizes: Array(repeating: 1, count: body.count))
    XCTAssertEqual(frames, [frame])
  }

  func testExactBoundaryTokenWithInvalidSuffixIsPreservedAsPayload_MJPEG_PT_011() throws {
    var frame = Data([0xFF, 0xD8, 0x44, 0x55])
    // The first exact token has an invalid second suffix byte. That second CR is also the start of
    // another boundary-like sequence, exercising overlap recovery instead of one-shot flushing.
    frame.append(Data("\r\n--\(boundary)\r\r\n--\(boundary)Z".utf8))
    frame.append(contentsOf: [0x66, 0x77, 0xFF, 0xD9])
    var body = Data(
      ("--\(boundary)\r\nContent-Type: image/jpeg\r\n\r\n").utf8
    )
    body.append(frame)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))

    let frames = try parse(body, chunkSizes: Array(repeating: 1, count: body.count))
    XCTAssertEqual(frames, [frame])
  }

  func testSingleLargeCallerChunkDoesNotAccumulateCompletedFramesInParser_MJPEG_PT_009() throws {
    let frameCount = 64
    var body = Data()
    for index in 0..<frameCount {
      body.append(
        Data(
          ("--\(boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(frameA.count)\r\nX-Sequence: \(index)\r\n\r\n").utf8
        )
      )
      body.append(frameA)
      body.append(
        Data(
          index + 1 == frameCount
            ? "\r\n--\(boundary)--\r\n".utf8
            : "\r\n".utf8
        )
      )
    }
    var parser = try MJPEGMultipartFramingParser(
      boundary: boundary,
      maximumHeaderBytes: 256,
      maximumFrameBytes: 64,
      maximumFrameCount: frameCount
    )
    var callbackCount = 0
    try parser.append(body) { frame in
      XCTAssertEqual(frame, frameA)
      callbackCount += 1
    }
    XCTAssertEqual(callbackCount, frameCount)
    XCTAssertEqual(parser.snapshot.emittedFrameCount, frameCount)
    XCTAssertLessThanOrEqual(
      parser.snapshot.maximumObservedLogicalRetainedBytes,
      parser.maximumMutablePayloadRetainedByteBound
    )
    XCTAssertEqual(parser.snapshot.retainedFrameBytes, 0)
    try parser.finish()
  }

  func testFrameCountAndIncompleteFinishTerminalizeAndReleasePayload_MJPEG_PT_010() throws {
    var tooMany = Data(
      ("--\(boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(frameA.count)\r\n\r\n").utf8
    )
    tooMany.append(frameA)
    tooMany.append(
      Data(
        "\r\n--\(boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(frameA.count)\r\n\r\n".utf8
      )
    )
    var limited = try MJPEGMultipartFramingParser(
      boundary: boundary,
      maximumHeaderBytes: 256,
      maximumFrameBytes: 64,
      maximumFrameCount: 1
    )
    var emitted: [Data] = []
    XCTAssertThrowsError(try limited.append(tooMany) { emitted.append($0) }) { error in
      XCTAssertEqual(error as? MJPEGMultipartFramingError, .frameCountExceeded)
    }
    XCTAssertEqual(emitted, [frameA])
    XCTAssertTrue(limited.snapshot.isTerminal)
    XCTAssertEqual(limited.snapshot.logicalRetainedBytes, 0)

    let partial = Data(
      ("--\(boundary)\r\nContent-Type: image/jpeg\r\n\r\n").utf8
    ) + frameA.prefix(4)
    var incomplete = try MJPEGMultipartFramingParser(
      boundary: boundary,
      maximumHeaderBytes: 256,
      maximumFrameBytes: 64,
      maximumFrameCount: 1
    )
    try incomplete.append(partial) { _ in XCTFail("incomplete frame must not publish") }
    XCTAssertThrowsError(try incomplete.finish()) { error in
      XCTAssertEqual(error as? MJPEGMultipartFramingError, .malformedMultipart)
    }
    XCTAssertTrue(incomplete.snapshot.isTerminal)
    XCTAssertEqual(incomplete.snapshot.logicalRetainedBytes, 0)
  }

  private func multipartBody() -> Data {
    var result = Data(
      ("--\(boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(frameA.count)\r\nX-Sequence: 1\r\n\r\n").utf8
    )
    result.append(frameA)
    result.append(Data("\r\n--\(boundary)\r\nContent-Type: image/jpeg\r\nX-Sequence: 2\r\n\r\n".utf8))
    result.append(frameB)
    result.append(Data("\r\n--\(boundary)--\r\n".utf8))
    return result
  }

  private func parse(
    _ body: Data,
    chunkSizes: [Int],
    maximumFrameBytes: Int = 1_024
  ) throws -> [Data] {
    var parser = try MJPEGMultipartFramingParser(
      boundary: boundary,
      maximumHeaderBytes: 1_024,
      maximumFrameBytes: maximumFrameBytes,
      maximumFrameCount: 2
    )
    var frames: [Data] = []
    var offset = 0
    var chunkIndex = 0
    while offset < body.count {
      let proposed = chunkSizes[chunkIndex % chunkSizes.count]
      let end = min(body.count, offset + max(1, proposed))
      try parser.append(body.subdata(in: offset..<end)) { frames.append($0) }
      offset = end
      chunkIndex += 1
    }
    XCTAssertTrue(parser.snapshot.isClosed)
    try parser.finish()
    return frames
  }

  private func retainedJPEG(named name: String) throws -> Data {
    let url = try XCTUnwrap(
      Bundle.module.url(
        forResource: name,
        withExtension: nil,
        subdirectory: "Corpus/v1"
      )
    )
    return try Data(contentsOf: url)
  }
}
