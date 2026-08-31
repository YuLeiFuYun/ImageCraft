import Foundation
import XCTest
@testable import ImageCraftImageIO

final class RFC1950ResumableSessionTests: XCTestCase {
  func testStoredFixedAndDynamicStreamsSuspendAtEveryByteAndDecodeExactly() throws {
    let storedPayload = Data(String(repeating: "ImageCraft-stored-block-", count: 3).utf8)
    let stored = try resumableHexData(
      "7801014800b7ff496d61676543726166742d73746f7265642d626c6f636b2d496d61676543726166742d73746f7265642d626c6f636b2d496d61676543726166742d73746f7265642d626c6f636b2dd8ed1ae3"
    )

    var fixedPayload = Data()
    for _ in 0..<40 { fixedPayload.append(Data("ABRACADABRA-".utf8)) }
    fixedPayload.append(contentsOf: 0..<32)
    let fixed = try resumableHexData(
      "780173740a72747674710452ba8ea3ec61c76660646266616563e7e0e4e2e6e1e5e317101412161115139790949296919593070069eb7f19"
    )

    var dynamicPayload = Data()
    for _ in 0..<4_096 { dynamicPayload.append(Data("0123456789abcdef".utf8)) }
    let dynamic = try resumableHexData(
      "789cedc7c901c0100000b09594bac641d97f840e22f9253c31bdb9d4d6c75cdf3ec1ddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddaffc0fbb5d241b"
    )

    for (name, stream, expected) in [
      ("stored", stored, storedPayload),
      ("fixed", fixed, fixedPayload),
      ("dynamic", dynamic, dynamicPayload),
    ] {
      let schedules = name == "dynamic" ? [stream.count, 64, 7, 2, 1] : [1]
      for chunkSize in schedules {
        let result: ResumableDecodeResult
        do {
          result = try decodeResumably(
            stream,
            expectedByteCount: expected.count,
            chunkSize: chunkSize
          )
        } catch {
          XCTFail("\(name) chunk=\(chunkSize) failed: \(error)")
          continue
        }
        XCTAssertEqual(result.output, expected, "\(name) chunk=\(chunkSize)")
        XCTAssertEqual(result.acceptedInputBytes, stream.count, name)
        XCTAssertEqual(result.retainedInputBytes, 0, name)
        XCTAssertEqual(result.reclaimedInputBytes, stream.count, name)
        XCTAssertLessThanOrEqual(
          result.maximumRetainedInputBytes,
          RFC1950BoundedInflate.resumableInputRollbackByteCount,
          name
        )
      }
    }
  }

  func testHighEntropyStreamReclaimsCallerPrefixAcrossArbitrarySchedules() throws {
    var payload = Data(capacity: 8 * 1024)
    var state: UInt32 = 0xA17E_5EED
    for index in 0..<(8 * 1024) {
      state = state &* 1_664_525 &+ 1_013_904_223
      payload.append(UInt8(truncatingIfNeeded: state >> 24) ^ UInt8(truncatingIfNeeded: index * 17))
    }
    let encoded = try RFC1950Zlib.deflate(payload)
    XCTAssertGreaterThan(encoded.count, RFC1950BoundedInflate.resumableInputRollbackByteCount * 4)

    var referenceHash: UInt64?
    for chunkSize in [1, 7, 64, encoded.count] {
      let result = try decodeResumably(
        encoded,
        expectedByteCount: payload.count,
        chunkSize: chunkSize
      )
      XCTAssertEqual(result.output, payload, "chunk=\(chunkSize)")
      XCTAssertEqual(result.acceptedInputBytes, encoded.count, "chunk=\(chunkSize)")
      XCTAssertEqual(result.reclaimedInputBytes, encoded.count, "chunk=\(chunkSize)")
      XCTAssertEqual(result.retainedInputBytes, 0, "chunk=\(chunkSize)")
      XCTAssertLessThanOrEqual(
        result.maximumRetainedInputBytes,
        RFC1950BoundedInflate.resumableInputRollbackByteCount,
        "chunk=\(chunkSize)"
      )
      XCTAssertLessThan(result.maximumRetainedInputBytes, encoded.count, "chunk=\(chunkSize)")
      let hash = fnv1a64(result.output)
      if let referenceHash {
        XCTAssertEqual(hash, referenceHash, "chunk=\(chunkSize)")
      } else {
        referenceHash = hash
      }
    }
  }

  func testRollbackAuthorityDominatesDynamicHeaderFormatBound() {
    let maximumDynamicHeaderBits = 14 + 19 * 3 + (286 + 32) * 7
    let maximumDynamicHeaderBytes = (maximumDynamicHeaderBits + 7) / 8
    XCTAssertEqual(maximumDynamicHeaderBits, 2_297)
    XCTAssertEqual(maximumDynamicHeaderBytes, 288)
    XCTAssertGreaterThan(
      RFC1950BoundedInflate.resumableInputRollbackByteCount,
      maximumDynamicHeaderBytes
    )
    XCTAssertEqual(RFC1950BoundedInflate.resumableInputRollbackByteCount, 512)
  }

  func testTruncationBadAdlerAndTrailingBytesRemainTerminal() throws {
    let payload = Data(String(repeating: "resumable-terminal-", count: 97).utf8)
    let encoded = try RFC1950Zlib.deflate(payload)

    do {
      var output = Data()
      let session = try RFC1950BoundedInflate.ResumableSession(
        expectedByteCount: payload.count
      ) { output.append(contentsOf: $0) }
      try feed(encoded.dropLast(), to: session, chunkSize: 3)
      XCTAssertThrowsError(try session.finishInput()) {
        XCTAssertEqual($0 as? RFC1950BoundedInflateError, .truncatedInput)
      }
      _ = output
    }

    do {
      var badAdler = encoded
      badAdler[badAdler.count - 1] ^= 1
      var output = Data()
      let session = try RFC1950BoundedInflate.ResumableSession(
        expectedByteCount: payload.count
      ) { output.append(contentsOf: $0) }
      XCTAssertThrowsError(try feed(badAdler, to: session, chunkSize: 5)) {
        XCTAssertEqual($0 as? RFC1950BoundedInflateError, .adler32Mismatch)
      }
      _ = output
    }

    do {
      var trailing = encoded
      trailing.append(0x00)
      var output = Data()
      let session = try RFC1950BoundedInflate.ResumableSession(
        expectedByteCount: payload.count
      ) { output.append(contentsOf: $0) }
      XCTAssertThrowsError(try feed(trailing, to: session, chunkSize: trailing.count)) {
        XCTAssertEqual($0 as? RFC1950BoundedInflateError, .truncatedInput)
      }
      _ = output
    }
  }
}

private struct ResumableDecodeResult {
  let output: Data
  let acceptedInputBytes: Int
  let retainedInputBytes: Int
  let reclaimedInputBytes: Int
  let maximumRetainedInputBytes: Int
}

private func decodeResumably(
  _ encoded: Data,
  expectedByteCount: Int,
  chunkSize: Int
) throws -> ResumableDecodeResult {
  var output = Data(capacity: expectedByteCount)
  let session = try RFC1950BoundedInflate.ResumableSession(
    expectedByteCount: expectedByteCount
  ) { bytes in
    output.append(contentsOf: bytes)
  }
  do {
    try feed(encoded, to: session, chunkSize: chunkSize)
    try session.finishInput()
  } catch {
    print(
      "resumable failure chunk=\(chunkSize) accepted=\(session.acceptedInputByteCount) "
        + "decoded=\(session.decodedByteCount) retained=\(session.retainedInputByteCount) "
        + "maxRetained=\(session.maximumObservedRetainedInputByteCount) error=\(error)"
    )
    throw error
  }
  XCTAssertTrue(session.isComplete)
  return ResumableDecodeResult(
    output: output,
    acceptedInputBytes: session.acceptedInputByteCount,
    retainedInputBytes: session.retainedInputByteCount,
    reclaimedInputBytes: session.reclaimedInputByteCount,
    maximumRetainedInputBytes: session.maximumObservedRetainedInputByteCount
  )
}

private func feed(
  _ encoded: Data,
  to session: RFC1950BoundedInflate.ResumableSession,
  chunkSize: Int
) throws {
  precondition(chunkSize > 0)
  var offset = 0
  while offset < encoded.count {
    let end = min(encoded.count, offset + chunkSize)
    var callerChunk = Array(encoded[offset..<end])
    try callerChunk.withUnsafeBufferPointer { bytes in
      try session.append(bytes)
    }
    // Any input that must survive suspension has to be copied into the session's fixed rollback
    // authority; the caller is free to destroy its chunk immediately after append returns.
    callerChunk = [UInt8](repeating: 0xA5, count: callerChunk.count)
    XCTAssertTrue(callerChunk.allSatisfy { $0 == 0xA5 })
    XCTAssertLessThanOrEqual(
      session.retainedInputByteCount,
      RFC1950BoundedInflate.resumableInputRollbackByteCount
    )
    offset = end
  }
}

private func resumableHexData(_ string: String) throws -> Data {
  guard string.count.isMultiple(of: 2) else { throw RFC1950BoundedInflateError.invalidHeader }
  var data = Data(capacity: string.count / 2)
  var index = string.startIndex
  while index < string.endIndex {
    let end = string.index(index, offsetBy: 2)
    guard let byte = UInt8(string[index..<end], radix: 16) else {
      throw RFC1950BoundedInflateError.invalidHeader
    }
    data.append(byte)
    index = end
  }
  return data
}

private func fnv1a64(_ data: Data) -> UInt64 {
  var hash = UInt64(1_469_598_103_934_665_603)
  for byte in data {
    hash ^= UInt64(byte)
    hash &*= 1_099_511_628_211
  }
  return hash
}
