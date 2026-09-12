import Foundation
import XCTest
import ImageCraftImageIO

final class MJPEGMultipartFramerPublicTests: XCTestCase {
  func testExternalHostFramesArbitraryChunksAndRetainsTransferredFrames() throws {
    let boundary = "consumer-mjpeg-boundary"
    let frameA = Data([0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9])
    var frameB = Data([0xFF, 0xD8, 0x10])
    frameB.append(Data("\r\n--\(boundary)Z".utf8))
    frameB.append(contentsOf: [0x20, 0xFF, 0xD9])

    var body = Data(
      ("--\(boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(frameA.count)\r\n\r\n").utf8
    )
    body.append(frameA)
    body.append(Data("\r\n--\(boundary)\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
    body.append(frameB)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))

    var framer = try MJPEGMultipartFramer(
      contentType: "multipart/x-mixed-replace; boundary=\(boundary)",
      maximumHeaderBytes: 256,
      maximumFrameBytes: 128,
      maximumFrameCount: 2
    )
    XCTAssertEqual(
      framer.maximumLogicalMutablePayloadRetainedByteBound,
      max(256, 128 + Data("\r\n--\(boundary)".utf8).count + 1)
    )

    var frames: [Data] = []
    for byte in body {
      try framer.append(Data([byte])) { frames.append($0) }
      XCTAssertLessThanOrEqual(
        framer.state.currentLogicalRetainedBytes,
        framer.maximumLogicalMutablePayloadRetainedByteBound
      )
    }
    XCTAssertEqual(frames, [frameA, frameB])
    XCTAssertEqual(framer.state.emittedFrameCount, 2)
    XCTAssertTrue(framer.state.isClosed)
    XCTAssertFalse(framer.state.isTerminal)
    XCTAssertEqual(framer.state.currentLogicalRetainedBytes, 0)

    try framer.finish()
    XCTAssertTrue(framer.state.isTerminal)
    XCTAssertEqual(frames, [frameA, frameB])
  }

  func testExternalHostGetsStableFailureAndTerminalReclaim() throws {
    let boundary = "consumer-mjpeg-limit"
    var framer = try MJPEGMultipartFramer(
      contentType: "multipart/x-mixed-replace; boundary=\(boundary)",
      maximumHeaderBytes: 128,
      maximumFrameBytes: 8,
      maximumFrameCount: 1
    )
    let oversized = Data(
      ("--\(boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: 9\r\n\r\n").utf8
    )
    XCTAssertThrowsError(try framer.append(oversized) { _ in }) { error in
      XCTAssertEqual(error as? MJPEGMultipartFramingError, .frameByteLimitExceeded)
    }
    XCTAssertTrue(framer.state.isTerminal)
    XCTAssertEqual(framer.state.currentLogicalRetainedBytes, 0)
    XCTAssertThrowsError(try framer.append(Data([0x00])) { _ in }) { error in
      XCTAssertEqual(error as? MJPEGMultipartFramingError, .sessionFailed)
    }
  }
}
