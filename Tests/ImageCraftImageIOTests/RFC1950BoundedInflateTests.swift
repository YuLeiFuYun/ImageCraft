import Foundation
import XCTest
@testable import ImageCraftImageIO

final class RFC1950BoundedInflateTests: XCTestCase {
  func testStoredFixedAndDynamicStreamsDecodeExactly() throws {
    let storedPayload = Data(String(repeating: "ImageCraft-stored-block-", count: 3).utf8)
    let stored = try hexData(
      "7801014800b7ff496d61676543726166742d73746f7265642d626c6f636b2d496d61676543726166742d73746f7265642d626c6f636b2d496d61676543726166742d73746f7265642d626c6f636b2dd8ed1ae3"
    )

    var fixedPayload = Data()
    for _ in 0..<40 { fixedPayload.append(Data("ABRACADABRA-".utf8)) }
    fixedPayload.append(contentsOf: 0..<32)
    let fixed = try hexData(
      "780173740a72747674710452ba8ea3ec61c76660646266616563e7e0e4e2e6e1e5e317101412161115139790949296919593070069eb7f19"
    )

    var dynamicPayload = Data()
    for _ in 0..<4_096 { dynamicPayload.append(Data("0123456789abcdef".utf8)) }
    let dynamic = try hexData(
      "789cedc7c901c0100000b09594bac641d97f840e22f9253c31bdb9d4d6c75cdf3ec1ddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddaffc0fbb5d241b"
    )

    for (stream, expected) in [
      (stored, storedPayload),
      (fixed, fixedPayload),
      (dynamic, dynamicPayload),
    ] {
      let decoded = try RFC1950BoundedInflate.inflate(
        stream,
        expectedByteCount: expected.count
      )
      XCTAssertEqual(decoded, expected)
      XCTAssertEqual(
        decoded,
        try RFC1950Zlib.inflate(stream, expectedByteCount: expected.count)
      )
      var streamed = Data()
      try RFC1950BoundedInflate.inflateStreaming(
        stream,
        expectedByteCount: expected.count
      ) { bytes in
        streamed.append(contentsOf: bytes)
      }
      XCTAssertEqual(streamed, expected)
    }
  }

  func testFullFlushMultiBlockStreamPreservesPrefetchedByteAlignment() throws {
    var expected = Data()
    for _ in 0..<17 { expected.append(Data("ABRACADABRA-".utf8)) }
    for _ in 0..<3 { expected.append(contentsOf: 0..<64) }
    for _ in 0..<23 { expected.append(Data("XYZXYZXYZXYZ".utf8)) }
    let stream = try hexData(
      "78da72740a72747674710452ba8e439c0d000000ffff6260646266616563e7e0e4e2e6e1e5e3171014121611151397909492969195935750545256515553d7d0d4d2d6d1d5d33730343236313533b7b0b4b2b6b1b5b3671860fd00000000ffff8b888c1a45680800e8ebacc6"
    )

    XCTAssertEqual(expected.count, 672)
    XCTAssertEqual(
      try RFC1950BoundedInflate.inflate(stream, expectedByteCount: expected.count),
      expected
    )
    XCTAssertEqual(
      try RFC1950BoundedInflate.inflate(stream, maximumByteCount: expected.count + 128),
      expected
    )
    var streamed = Data()
    try RFC1950BoundedInflate.inflateStreaming(
      stream,
      expectedByteCount: expected.count
    ) { bytes in
      streamed.append(contentsOf: bytes)
    }
    XCTAssertEqual(streamed, expected)
  }

  func testAlgorithmicWorkspaceChargeDominatesExplicitTablePayloadModel() {
    let fastTablePayload = (3 * 512 + 1_024) * MemoryLayout<UInt16>.size
    let canonicalVectors = 3 * 3 * 16 * MemoryLayout<Int>.size
    let symbols = (288 + 32 + 19) * MemoryLayout<UInt16>.size
    let dynamicLengths = (286 + 32) * MemoryLayout<UInt8>.size
    let fixedLengths = (288 + 32) * MemoryLayout<UInt8>.size
    let directlyEnumeratedPayload =
      fastTablePayload + canonicalVectors + symbols + dynamicLengths + fixedLengths

    XCTAssertGreaterThanOrEqual(
      RFC1950BoundedInflate.algorithmicWorkspaceByteChargeUpperBound,
      directlyEnumeratedPayload * 3
    )
    XCTAssertEqual(
      RFC1950BoundedInflate.streamingOutputWorkspaceByteChargeUpperBound,
      36 * 1024
    )
  }

  func testAdlerNMAXWorstCaseBoundaryMatchesReferenceExactly() throws {
    for count in [5_552, 5_553] {
      let payload = Data(repeating: 0xFF, count: count)
      let encoded = try RFC1950Zlib.deflate(payload)
      XCTAssertEqual(
        try RFC1950BoundedInflate.inflate(encoded, expectedByteCount: count),
        payload
      )
      XCTAssertEqual(
        try RFC1950Zlib.inflate(encoded, expectedByteCount: count),
        payload
      )
      var streamed = Data(capacity: count)
      try RFC1950BoundedInflate.inflateStreaming(
        encoded,
        expectedByteCount: count
      ) { bytes in
        streamed.append(contentsOf: bytes)
      }
      XCTAssertEqual(streamed, payload)
    }
  }

  func testLiteralOnlyDynamicBlockMayOmitUsableDistanceCodes() throws {
    let stream = makeLiteralOnlyDynamicStream()
    XCTAssertEqual(
      try RFC1950BoundedInflate.inflate(stream, expectedByteCount: 1),
      Data([65])
    )
    var streamed = Data()
    try RFC1950BoundedInflate.inflateStreaming(stream, expectedByteCount: 1) { bytes in
      streamed.append(contentsOf: bytes)
    }
    XCTAssertEqual(streamed, Data([65]))
  }

  func testIncompleteCodeLengthAlphabetIsRejectedBeforePayloadDecode() {
    let stream = makeIncompleteCodeLengthAlphabetStream()
    XCTAssertThrowsError(
      try RFC1950BoundedInflate.inflate(stream, expectedByteCount: 0)
    ) { XCTAssertEqual($0 as? RFC1950BoundedInflateError, .invalidHuffmanTree) }
  }

  func testCompressionProducedCorpusMatchesExistingInflater() throws {
    for seed in 0..<32 {
      let count = 1 + seed * 137
      var payload = Data(capacity: count)
      var state = UInt32(seed + 1) &* 0x9E37_79B9
      for index in 0..<count {
        state = state &* 1_664_525 &+ 1_013_904_223
        let patterned = UInt8(truncatingIfNeeded: (index / 17) &* (seed + 3))
        payload.append(UInt8(truncatingIfNeeded: state >> 24) ^ patterned)
      }
      let encoded = try RFC1950Zlib.deflate(payload)
      let pure = try RFC1950BoundedInflate.inflate(
        encoded,
        expectedByteCount: payload.count
      )
      let framework = try RFC1950Zlib.inflate(
        encoded,
        expectedByteCount: payload.count
      )
      XCTAssertEqual(pure, payload, "seed=\(seed)")
      XCTAssertEqual(pure, framework, "seed=\(seed)")
    }
  }

  func testStreamingBulkOutputCrossesMultipleHistoryWraps() throws {
    var repetitive = Data(capacity: 128 * 1024)
    for index in 0..<(128 * 1024) {
      repetitive.append(
        UInt8(truncatingIfNeeded: (index & 4_095) &* 31 &+ ((index >> 12) % 11) &* 7)
      )
    }

    var incompressible = Data(capacity: 96 * 1024)
    var state: UInt32 = 0xC001_D00D
    for _ in 0..<(96 * 1024) {
      state = state &* 1_664_525 &+ 1_013_904_223
      incompressible.append(UInt8(truncatingIfNeeded: state >> 24))
    }

    for payload in [repetitive, incompressible] {
      let encoded = try RFC1950Zlib.deflate(payload)
      var streamed = Data(capacity: payload.count)
      try RFC1950BoundedInflate.inflateStreaming(
        encoded,
        expectedByteCount: payload.count
      ) { bytes in
        streamed.append(contentsOf: bytes)
      }
      XCTAssertEqual(streamed, payload)
      XCTAssertEqual(
        try RFC1950BoundedInflate.inflate(encoded, expectedByteCount: payload.count),
        payload
      )
      XCTAssertEqual(
        try RFC1950Zlib.inflate(encoded, expectedByteCount: payload.count),
        payload
      )
    }
  }

  func testStreamingWindowPreservesFullLookbackAcrossPhysicalWraps() throws {
    var prefix = Data(capacity: 32 * 1024)
    var state: UInt32 = 0x51A7_C0DE
    for _ in 0..<(32 * 1024) {
      state = state &* 1_664_525 &+ 1_013_904_223
      prefix.append(UInt8(truncatingIfNeeded: state >> 24))
    }
    var payload = Data(capacity: 3 * prefix.count)
    payload.append(prefix)
    payload.append(prefix)
    payload.append(prefix)

    let encoded = try RFC1950Zlib.deflate(payload)
    var streamed = Data(capacity: payload.count)
    try RFC1950BoundedInflate.inflateStreaming(
      encoded,
      expectedByteCount: payload.count
    ) { bytes in
      streamed.append(contentsOf: bytes)
    }
    XCTAssertEqual(streamed, payload)
    XCTAssertEqual(
      try RFC1950BoundedInflate.inflate(encoded, expectedByteCount: payload.count),
      payload
    )
    XCTAssertEqual(
      try RFC1950Zlib.inflate(encoded, expectedByteCount: payload.count),
      payload
    )
  }

  func testMaximumByteModeReturnsExactValueAndDistinguishesLimitFailure() throws {
    let payload = Data(String(repeating: "bounded-metadata-value-", count: 19).utf8)
    let encoded = try RFC1950Zlib.deflate(payload)

    XCTAssertEqual(
      try RFC1950BoundedInflate.inflate(
        encoded,
        maximumByteCount: payload.count
      ),
      payload
    )
    XCTAssertEqual(
      try RFC1950BoundedInflate.inflate(
        encoded,
        maximumByteCount: payload.count + 4_096
      ),
      payload
    )
    let borrowed = try encoded.withUnsafeBytes { rawInput in
      try RFC1950BoundedInflate.inflate(
        rawInput.bindMemory(to: UInt8.self),
        maximumByteCount: payload.count + 4_096
      )
    }
    XCTAssertEqual(borrowed, payload)
    XCTAssertThrowsError(
      try RFC1950BoundedInflate.inflate(
        encoded,
        maximumByteCount: payload.count - 1
      )
    ) { XCTAssertEqual($0 as? RFC1950BoundedInflateError, .outputLimitExceeded) }
  }

  func testSingleBitMutationsCannotPublishCorruptedFixedOrDynamicOutput() throws {
    var fixedPayload = Data()
    for _ in 0..<40 { fixedPayload.append(Data("ABRACADABRA-".utf8)) }
    fixedPayload.append(contentsOf: 0..<32)
    let fixed = try hexData(
      "780173740a72747674710452ba8ea3ec61c76660646266616563e7e0e4e2e6e1e5e317101412161115139790949296919593070069eb7f19"
    )

    var dynamicPayload = Data()
    for _ in 0..<4_096 { dynamicPayload.append(Data("0123456789abcdef".utf8)) }
    let dynamic = try hexData(
      "789cedc7c901c0100000b09594bac641d97f840e22f9253c31bdb9d4d6c75cdf3ec1ddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddaffc0fbb5d241b"
    )

    for (name, stream, expected) in [
      ("fixed", fixed, fixedPayload),
      ("dynamic", dynamic, dynamicPayload),
    ] {
      for byteIndex in stream.indices {
        for bit: UInt8 in [1, 2, 4, 8, 16, 32, 64, 128] {
          var mutated = stream
          mutated[byteIndex] ^= bit
          do {
            let decoded = try RFC1950BoundedInflate.inflate(
              mutated,
              maximumByteCount: expected.count
            )
            XCTAssertEqual(decoded, expected, "accepted corrupted \(name) byte=\(byteIndex) bit=\(bit)")
          } catch {
            // Rejection is the expected outcome for almost every mutation. The property under test
            // is that no mutated stream can publish a different value through a valid Adler/trailer.
          }
        }
      }
    }
  }

  func testHeaderBlockStoredLengthOutputAndAdlerFailuresAreTerminal() throws {
    let valid = try hexData(
      "7801014800b7ff496d61676543726166742d73746f7265642d626c6f636b2d496d61676543726166742d73746f7265642d626c6f636b2d496d61676543726166742d73746f7265642d626c6f636b2dd8ed1ae3"
    )
    let expectedCount = 72

    var invalidCM = valid
    invalidCM[0] = 0x79
    XCTAssertThrowsError(
      try RFC1950BoundedInflate.inflate(invalidCM, expectedByteCount: expectedCount)
    ) { XCTAssertEqual($0 as? RFC1950BoundedInflateError, .invalidHeader) }

    var presetDictionary = valid
    presetDictionary[1] = 0x20
    XCTAssertThrowsError(
      try RFC1950BoundedInflate.inflate(presetDictionary, expectedByteCount: expectedCount)
    ) { XCTAssertEqual($0 as? RFC1950BoundedInflateError, .presetDictionaryUnsupported) }

    var badStoredLength = valid
    badStoredLength[5] ^= 0x01
    XCTAssertThrowsError(
      try RFC1950BoundedInflate.inflate(badStoredLength, expectedByteCount: expectedCount)
    ) { XCTAssertEqual($0 as? RFC1950BoundedInflateError, .invalidStoredBlock) }

    let invalidBlock = Data([0x78, 0x01, 0x07, 0x00, 0x00, 0x00, 0x01])
    XCTAssertThrowsError(
      try RFC1950BoundedInflate.inflate(invalidBlock, expectedByteCount: 0)
    ) { XCTAssertEqual($0 as? RFC1950BoundedInflateError, .invalidBlockType) }

    XCTAssertThrowsError(
      try RFC1950BoundedInflate.inflate(valid, expectedByteCount: expectedCount - 1)
    ) { XCTAssertEqual($0 as? RFC1950BoundedInflateError, .outputLengthMismatch) }
    XCTAssertThrowsError(
      try RFC1950BoundedInflate.inflate(valid, expectedByteCount: expectedCount + 1)
    ) { XCTAssertEqual($0 as? RFC1950BoundedInflateError, .outputLengthMismatch) }

    var badAdler = valid
    badAdler[badAdler.count - 1] ^= 1
    XCTAssertThrowsError(
      try RFC1950BoundedInflate.inflate(badAdler, expectedByteCount: expectedCount)
    ) { XCTAssertEqual($0 as? RFC1950BoundedInflateError, .adler32Mismatch) }
    XCTAssertThrowsError(
      try RFC1950BoundedInflate.inflateStreaming(
        badAdler,
        expectedByteCount: expectedCount
      ) { _ in }
    ) { XCTAssertEqual($0 as? RFC1950BoundedInflateError, .adler32Mismatch) }

    XCTAssertThrowsError(
      try RFC1950BoundedInflate.inflateStreaming(
        valid,
        expectedByteCount: expectedCount - 1
      ) { _ in }
    ) { XCTAssertEqual($0 as? RFC1950BoundedInflateError, .outputLengthMismatch) }

    XCTAssertThrowsError(
      try RFC1950BoundedInflate.inflate(valid.dropLast(), expectedByteCount: expectedCount)
    )
  }
}

private enum HexFixtureError: Error {
  case invalidHex
}

private func hexData(_ string: String) throws -> Data {
  guard string.count.isMultiple(of: 2) else { throw HexFixtureError.invalidHex }
  var data = Data(capacity: string.count / 2)
  var index = string.startIndex
  while index < string.endIndex {
    let end = string.index(index, offsetBy: 2)
    guard let byte = UInt8(string[index..<end], radix: 16) else {
      throw HexFixtureError.invalidHex
    }
    data.append(byte)
    index = end
  }
  return data
}

private struct DeflateTestBitWriter {
  private var bytes: [UInt8] = []
  private var current: UInt8 = 0
  private var bitOffset = 0

  mutating func writeLSB(_ value: Int, count: Int) {
    for bit in 0..<count {
      writeBit((value >> bit) & 1)
    }
  }

  mutating func writeHuffmanMSB(_ canonicalCode: Int, count: Int) {
    guard count > 0 else { return }
    for bit in stride(from: count - 1, through: 0, by: -1) {
      writeBit((canonicalCode >> bit) & 1)
    }
  }

  mutating func finish() -> Data {
    if bitOffset != 0 {
      bytes.append(current)
      current = 0
      bitOffset = 0
    }
    return Data(bytes)
  }

  private mutating func writeBit(_ bit: Int) {
    if bit != 0 { current |= UInt8(1 << bitOffset) }
    bitOffset += 1
    if bitOffset == 8 {
      bytes.append(current)
      current = 0
      bitOffset = 0
    }
  }
}

private func makeLiteralOnlyDynamicStream() -> Data {
  var bits = DeflateTestBitWriter()
  bits.writeLSB(1, count: 1)  // BFINAL
  bits.writeLSB(2, count: 2)  // dynamic Huffman
  bits.writeLSB(0, count: 5)  // HLIT = 257
  bits.writeLSB(0, count: 5)  // HDIST = 1
  bits.writeLSB(14, count: 4)  // HCLEN = 18

  // Code-length alphabet in RFC1951 order. Symbol 18 gets code length 1; symbols 0 and 1 get
  // length 2. The resulting complete canonical codes are 18=0, 0=10, 1=11.
  let codeLengthCodeLengths = [0, 0, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2]
  for length in codeLengthCodeLengths { bits.writeLSB(length, count: 3) }

  // Literal/length lengths: symbol 65='A' => 1, symbol 256=EOB => 1, everything else zero.
  bits.writeHuffmanMSB(0, count: 1)  // symbol 18
  bits.writeLSB(65 - 11, count: 7)
  bits.writeHuffmanMSB(3, count: 2)  // symbol 1
  bits.writeHuffmanMSB(0, count: 1)  // symbol 18: 138 zeros
  bits.writeLSB(127, count: 7)
  bits.writeHuffmanMSB(0, count: 1)  // symbol 18: remaining 52 zeros
  bits.writeLSB(52 - 11, count: 7)
  bits.writeHuffmanMSB(3, count: 2)  // EOB length 1
  bits.writeHuffmanMSB(2, count: 2)  // single distance code length 0 via symbol 0

  // Two-symbol literal/length tree: 'A'=0, EOB=1.
  bits.writeHuffmanMSB(0, count: 1)
  bits.writeHuffmanMSB(1, count: 1)

  var stream = Data([0x78, 0x01])
  stream.append(bits.finish())
  stream.append(contentsOf: [0x00, 0x42, 0x00, 0x42])  // Adler-32("A")
  return stream
}

private func makeIncompleteCodeLengthAlphabetStream() -> Data {
  var bits = DeflateTestBitWriter()
  bits.writeLSB(1, count: 1)
  bits.writeLSB(2, count: 2)
  bits.writeLSB(0, count: 5)
  bits.writeLSB(0, count: 5)
  bits.writeLSB(0, count: 4)  // HCLEN = 4
  bits.writeLSB(0, count: 3)  // symbol 16
  bits.writeLSB(0, count: 3)  // symbol 17
  bits.writeLSB(1, count: 3)  // symbol 18 only => forbidden incomplete CODES tree
  bits.writeLSB(0, count: 3)  // symbol 0

  var stream = Data([0x78, 0x01])
  stream.append(bits.finish())
  stream.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
  return stream
}
