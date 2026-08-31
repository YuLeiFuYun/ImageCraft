import Darwin
import Foundation

package enum RFC1950BoundedInflateError: Error, Equatable, Sendable {
  case invalidHeader
  case presetDictionaryUnsupported
  case invalidBlockType
  case invalidStoredBlock
  case invalidHuffmanTree
  case invalidHuffmanCode
  case invalidLengthSymbol
  case invalidDistanceSymbol
  case invalidBackReference
  case truncatedInput
  case outputLimitExceeded
  case outputLengthMismatch
  case adler32Mismatch
  case rollbackWindowExceeded
}

protocol RFC1950StreamingByteCursor {
  var remainingByteCount: Int { get }
  mutating func readByte() -> UInt8?
  mutating func read(into destination: UnsafeMutableBufferPointer<UInt8>) -> Int
}

extension RFC1950StreamingByteCursor {
  mutating func read(into destination: UnsafeMutableBufferPointer<UInt8>) -> Int {
    var written = 0
    while written < destination.count, let byte = readByte() {
      destination[written] = byte
      written += 1
    }
    return written
  }
}

/// Pure-Swift RFC 1950 / RFC 1951 decoder for a caller-known exact output size.
///
/// This decoder exists to make the independent PNG path independent from Apple Compression's
/// private workspace. It supports all three DEFLATE block kinds (stored, fixed Huffman and dynamic
/// Huffman), rejects preset dictionaries, enforces the 32 KiB distance window and validates the
/// zlib Adler-32 trailer. The output is allocated once at exactly `expectedByteCount`; an attempted
/// literal or match past that boundary fails before publication.
///
/// `algorithmicWorkspaceByteChargeUpperBound` is an admission-accounting charge, not RSS. It
/// intentionally overcharges the bounded canonical-Huffman vectors/tables used by this
/// implementation; allocator headers and VM page rounding remain outside ImageCraft's byte-charge
/// vocabulary.
package enum RFC1950BoundedInflate {
  private static let streamingHistoryByteCount = 32 * 1024
  private static let streamingStagingByteCount = 4 * 1024
  private static let streamingWindowByteCount =
    streamingHistoryByteCount + streamingStagingByteCount
  private static let adlerModulus = UInt64(65_521)
  // RFC 1950 Adler-32 NMAX. Reduce every 5_552 bytes to keep the hot-loop state bounded while
  // retaining UInt64 accumulators; the earlier UInt32 narrowing did not improve actual PNG IDAT A/B.
  private static let adlerNMAX = 5_552

  // Payload-model derivation (allocator metadata/page rounding intentionally excluded):
  // - at most three simultaneously live canonical tables (literal/length, distance, code-length);
  // - each table has a 512-entry UInt16 9-bit fast prefix table plus three 16-entry Int vectors;
  // - at most the dynamic literal/length table additionally owns one 1,024-entry UInt16 10-bit
  //   secondary table; distance and code-length tables remain 9-bit-only;
  // - symbol payloads are bounded by 288 + 32 + 19 UInt16 values;
  // - dynamic code-length storage is bounded by 286 + 32 UInt8 values;
  // - fixed-length vectors, base/extra-bit vectors and scalar reader state fit well inside the
  //   remaining headroom. The explicit 24 KiB charge is >3x the directly enumerated vector/table
  //   payload and is intentionally stable rather than allocator-layout dependent.
  package static let algorithmicWorkspaceByteChargeUpperBound = 24 * 1024

  /// Additional codec-owned payload used by streaming exact-output mode. One 36 KiB circular
  /// logical-output window simultaneously retains the RFC1951 32 KiB lookback and one 4 KiB pending
  /// sink span; there is no second history/staging payload.
  package static let streamingOutputWorkspaceByteChargeUpperBound = streamingWindowByteCount

  /// Fixed retained-input authority for resumable RFC1950 decoding. A dynamic-Huffman header is
  /// the largest semantic transaction that may need replay: 14 header bits + at most 57 code-
  /// length-alphabet bits + 318 code lengths at at most seven Huffman bits each = 2,297 bits
  /// (< 288 bytes). The 512-byte ring leaves ample refill/lookahead headroom without retaining a
  /// whole DEFLATE block or caller chunk.
  package static let resumableInputRollbackByteCount = 512

  /// Conservative payload charge while maximum-output mode is publishing an exact returned value:
  /// the ceiling-sized temporary output and an exact-sized copy may coexist with Huffman workspace.
  package static func maximumModeByteChargeUpperBound(
    maximumOutputByteCount: Int
  ) -> Int {
    guard maximumOutputByteCount >= 0 else { return Int.max }
    let doubled = maximumOutputByteCount.multipliedReportingOverflow(by: 2)
    guard !doubled.overflow else { return Int.max }
    let total = doubled.partialValue.addingReportingOverflow(
      algorithmicWorkspaceByteChargeUpperBound
    )
    return total.overflow ? Int.max : total.partialValue
  }

  package static func inflate(
    _ source: Data,
    expectedByteCount: Int
  ) throws -> Data {
    guard expectedByteCount >= 0, source.count >= 6 else {
      throw RFC1950BoundedInflateError.invalidHeader
    }
    var output = Data(repeating: 0, count: expectedByteCount)
    try source.withUnsafeBytes { rawInput in
      let input = rawInput.bindMemory(to: UInt8.self)
      try output.withUnsafeMutableBytes { rawOutput in
        let destination = rawOutput.bindMemory(to: UInt8.self)
        var decoder = Decoder(input: input, output: destination, allowsShortOutput: false)
        _ = try decoder.decode()
      }
    }
    return output
  }

  /// Decodes a stream with an unknown exact length under a hard output ceiling. The ceiling-sized
  /// temporary buffer is not transferred: after Adler/trailer validation only the decoded prefix is
  /// copied into the returned value.
  package static func inflate(
    _ source: Data,
    maximumByteCount: Int
  ) throws -> Data {
    guard maximumByteCount >= 0, source.count >= 6 else {
      throw RFC1950BoundedInflateError.invalidHeader
    }
    return try source.withUnsafeBytes { rawInput in
      try inflate(
        rawInput.bindMemory(to: UInt8.self),
        maximumByteCount: maximumByteCount
      )
    }
  }

  /// Synchronous maximum-output decode over caller-owned bytes. The source buffer is borrowed for
  /// the duration of the call and is never copied or retained; returned bytes own only the validated
  /// decoded prefix.
  static func inflate(
    _ source: UnsafeBufferPointer<UInt8>,
    maximumByteCount: Int
  ) throws -> Data {
    guard maximumByteCount >= 0, source.count >= 6 else {
      throw RFC1950BoundedInflateError.invalidHeader
    }
    var decodedCount = 0
    let storage: UnsafeMutablePointer<UInt8>? = maximumByteCount > 0
      ? .allocate(capacity: maximumByteCount)
      : nil
    defer { storage?.deallocate() }
    let destination = UnsafeMutableBufferPointer(
      start: storage,
      count: maximumByteCount
    )
    var decoder = Decoder(input: source, output: destination, allowsShortOutput: true)
    decodedCount = try decoder.decode()
    guard decodedCount > 0, let storage else { return Data() }
    return Data(bytes: storage, count: decodedCount)
  }

  /// Exact-size streaming decode for callers that can consume decompressed bytes incrementally.
  /// The sink receives bounded staging slices in stream order. The decoder retains only the RFC
  /// 1951 32 KiB history window plus the staging buffer; it never allocates `expectedByteCount`.
  ///
  /// Sink effects are provisional until this function returns: a late checksum/trailer failure can
  /// occur after earlier slices were delivered, so callers must not externally publish those bytes
  /// before successful return.
  package static func inflateStreaming(
    _ source: Data,
    expectedByteCount: Int,
    consume: (UnsafeBufferPointer<UInt8>) throws -> Void
  ) throws {
    guard expectedByteCount >= 0, source.count >= 6 else {
      throw RFC1950BoundedInflateError.invalidHeader
    }
    try withoutActuallyEscaping(consume) { escapableConsume in
      try source.withUnsafeBytes { rawInput in
        let input = rawInput.bindMemory(to: UInt8.self)
        guard let base = input.baseAddress else {
          throw RFC1950BoundedInflateError.invalidHeader
        }
        let cursor = ContiguousStreamingByteCursor(base: base, count: input.count)
        var decoder = try StreamingDecoder(
          cursor: cursor,
          expectedByteCount: expectedByteCount,
          consume: escapableConsume
        )
        try decoder.decode()
      }
    }
  }

  static func inflateStreaming<Cursor: RFC1950StreamingByteCursor>(
    cursor: Cursor,
    expectedByteCount: Int,
    consume: (UnsafeBufferPointer<UInt8>) throws -> Void
  ) throws {
    guard expectedByteCount >= 0, cursor.remainingByteCount >= 6 else {
      throw RFC1950BoundedInflateError.invalidHeader
    }
    try withoutActuallyEscaping(consume) { escapableConsume in
      var decoder = try StreamingDecoder(
        cursor: cursor,
        expectedByteCount: expectedByteCount,
        consume: escapableConsume
      )
      try decoder.decode()
    }
  }

  private struct ContiguousStreamingByteCursor: RFC1950StreamingByteCursor {
    let base: UnsafePointer<UInt8>
    let count: Int
    var index = 0

    var remainingByteCount: Int { count - index }

    mutating func readByte() -> UInt8? {
      guard index < count else { return nil }
      let byte = base[index]
      index += 1
      return byte
    }

    mutating func read(into destination: UnsafeMutableBufferPointer<UInt8>) -> Int {
      let copied = min(destination.count, remainingByteCount)
      guard copied > 0, let destinationBase = destination.baseAddress else { return 0 }
      memcpy(destinationBase, base.advanced(by: index), copied)
      index += copied
      return copied
    }
  }

  private struct HuffmanTable {
    private static let fastBitCount = 9
    private let counts: [Int]
    private let firstCodes: [Int]
    private let firstSymbols: [Int]
    private let symbols: [UInt16]
    private let fastLookup: [UInt16]
    private let fastTenLookup: [UInt16]?
    private let fastLiteralPrefixCount: Int

    var prefersFastLiteralRuns: Bool {
      fastLiteralPrefixCount >= (1 << (Self.fastBitCount - 1))
    }

    init<S: Collection>(
      lengths: S,
      allowsSingleOneBitIncomplete: Bool = false,
      enablesTenBitSecondary: Bool = false
    ) throws where S.Element == UInt8 {
      var counts = [Int](repeating: 0, count: 16)
      var symbolCount = 0
      for length in lengths {
        guard length <= 15 else { throw RFC1950BoundedInflateError.invalidHuffmanTree }
        if length != 0 {
          counts[Int(length)] += 1
          symbolCount += 1
        }
      }
      guard symbolCount > 0 else { throw RFC1950BoundedInflateError.invalidHuffmanTree }

      // RFC 1951 canonical-code oversubscription check. Incomplete trees are accepted because
      // DEFLATE permits degenerate one-symbol trees; an absent code still fails during decode.
      var remaining = 1
      for bits in 1...15 {
        remaining <<= 1
        remaining -= counts[bits]
        guard remaining >= 0 else { throw RFC1950BoundedInflateError.invalidHuffmanTree }
      }
      if remaining > 0 {
        guard allowsSingleOneBitIncomplete,
          symbolCount == 1,
          counts[1] == 1
        else { throw RFC1950BoundedInflateError.invalidHuffmanTree }
      }

      var firstCodes = [Int](repeating: 0, count: 16)
      var firstSymbols = [Int](repeating: 0, count: 16)
      var code = 0
      var firstSymbol = 0
      for bits in 1...15 {
        code = (code + counts[bits - 1]) << 1
        firstCodes[bits] = code
        firstSymbols[bits] = firstSymbol
        firstSymbol += counts[bits]
      }

      var offsets = firstSymbols
      var symbols = [UInt16](repeating: 0, count: symbolCount)
      var fastLookup = [UInt16](repeating: 0, count: 1 << Self.fastBitCount)
      var fastTenLookup: [UInt16]? = enablesTenBitSecondary && counts[10] > 0
        ? [UInt16](repeating: 0, count: 1 << 10)
        : nil
      var fastLiteralPrefixCount = 0
      var nextCodes = firstCodes
      for (rawSymbol, length) in lengths.enumerated() where length != 0 {
        guard let symbol = UInt16(exactly: rawSymbol) else {
          throw RFC1950BoundedInflateError.invalidHuffmanTree
        }
        let bits = Int(length)
        let canonicalCode = nextCodes[bits]
        nextCodes[bits] += 1
        let index = offsets[bits]
        guard index >= 0, index < symbols.count else {
          throw RFC1950BoundedInflateError.invalidHuffmanTree
        }
        symbols[index] = symbol
        offsets[bits] += 1

        if bits <= Self.fastBitCount {
          let streamPrefix = Self.reversedBits(canonicalCode, count: bits)
          let packed = UInt16(bits << 9) | symbol
          let suffixCount = 1 << (Self.fastBitCount - bits)
          if rawSymbol < 256 { fastLiteralPrefixCount += suffixCount }
          for suffix in 0..<suffixCount {
            fastLookup[streamPrefix | (suffix << bits)] = packed
          }
        } else if bits == 10, fastTenLookup != nil {
          let streamPrefix = Self.reversedBits(canonicalCode, count: bits)
          fastTenLookup![streamPrefix] = UInt16(bits << 9) | symbol
        }
      }

      self.counts = counts
      self.firstCodes = firstCodes
      self.firstSymbols = firstSymbols
      self.symbols = symbols
      self.fastLookup = fastLookup
      self.fastTenLookup = fastTenLookup
      self.fastLiteralPrefixCount = fastLiteralPrefixCount
    }

    func decodeSymbol<Reader: RFC1950BitReading>(reader: inout Reader) throws -> Int {
      try fastLookup.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else {
          throw RFC1950BoundedInflateError.invalidHuffmanTree
        }
        return try decodeSymbol(reader: &reader, fastLookupBase: base)
      }
    }

    func withFastLookup<R>(
      _ body: (UnsafePointer<UInt16>) throws -> R
    ) rethrows -> R {
      try fastLookup.withUnsafeBufferPointer { buffer in
        try body(buffer.baseAddress!)
      }
    }

    func decodeSymbol<Reader: RFC1950BitReading>(
      reader: inout Reader,
      fastLookupBase: UnsafePointer<UInt16>
    ) throws -> Int {
      let prefix = reader.peekNineBitsIfAvailable()
      if prefix >= 0 {
        let packed = fastLookupBase[prefix]
        let length = Int(packed >> 9)
        if length > 0 {
          reader.dropBits(length)
          return Int(packed & 0x01FF)
        }
      }
      if let fastTenLookup {
        let tenBitPrefix = reader.peekTenBitsIfAvailable()
        if tenBitPrefix >= 0 {
          let packed = fastTenLookup[tenBitPrefix]
          if packed != 0 {
            reader.dropBits(10)
            return Int(packed & 0x01FF)
          }
        }
      }
      var code = 0
      for bits in 1...15 {
        code = (code << 1) | Int(try reader.readBit())
        let count = counts[bits]
        guard count > 0 else { continue }
        let delta = code - firstCodes[bits]
        if delta >= 0, delta < count {
          let index = firstSymbols[bits] + delta
          guard index >= 0, index < symbols.count else {
            throw RFC1950BoundedInflateError.invalidHuffmanCode
          }
          return Int(symbols[index])
        }
      }
      throw RFC1950BoundedInflateError.invalidHuffmanCode
    }

    private static func reversedBits(_ value: Int, count: Int) -> Int {
      var source = value
      var result = 0
      for _ in 0..<count {
        result = (result << 1) | (source & 1)
        source >>= 1
      }
      return result
    }
  }

  private protocol RFC1950BitReading {
    mutating func readBit() throws -> UInt8
    mutating func readBits(_ count: Int) throws -> UInt32
    mutating func peekNineBitsIfAvailable() -> Int
    mutating func peekTenBitsIfAvailable() -> Int
    mutating func dropBits(_ count: Int)
  }

  private struct BitReader: RFC1950BitReading {
    let input: UnsafeBufferPointer<UInt8>
    let inputBase: UnsafePointer<UInt8>
    let byteLimit: Int
    var byteIndex: Int
    private var bitBuffer: UInt64 = 0
    private var bitCount: Int = 0

    init(input: UnsafeBufferPointer<UInt8>, byteIndex: Int, byteLimit: Int) {
      precondition(input.count > 0 && input.baseAddress != nil)
      self.input = input
      self.inputBase = input.baseAddress!
      self.byteIndex = byteIndex
      self.byteLimit = byteLimit
    }

    mutating func readBit() throws -> UInt8 {
      if bitCount == 0 {
        guard byteIndex < byteLimit else { throw RFC1950BoundedInflateError.truncatedInput }
        bitBuffer = UInt64(inputBase[byteIndex])
        byteIndex += 1
        bitCount = 8
      }
      let result = UInt8(bitBuffer & 1)
      bitBuffer >>= 1
      bitCount -= 1
      return result
    }

    mutating func readBits(_ count: Int) throws -> UInt32 {
      guard count >= 0, count <= 24 else {
        throw RFC1950BoundedInflateError.truncatedInput
      }
      if count == 0 { return 0 }
      return try readBitsUnchecked(count)
    }

    @inline(__always)
    mutating func readBitsUnchecked(_ count: Int) throws -> UInt32 {
      precondition(count > 0 && count <= 24)
      while bitCount < count {
        guard byteIndex < byteLimit else { throw RFC1950BoundedInflateError.truncatedInput }
        bitBuffer |= UInt64(inputBase[byteIndex]) << UInt64(bitCount)
        byteIndex += 1
        bitCount += 8
      }
      let mask = (UInt64(1) << UInt64(count)) - 1
      let result = UInt32(bitBuffer & mask)
      bitBuffer >>= UInt64(count)
      bitCount -= count
      return result
    }

    @inline(__always)
    mutating func peekNineBitsIfAvailable() -> Int {
      while bitCount < 9, byteIndex < byteLimit {
        bitBuffer |= UInt64(inputBase[byteIndex]) << UInt64(bitCount)
        byteIndex += 1
        bitCount += 8
      }
      guard bitCount >= 9 else { return -1 }
      return Int(bitBuffer & 0x01FF)
    }

    @inline(__always)
    mutating func peekTenBitsIfAvailable() -> Int {
      while bitCount < 10, byteIndex < byteLimit {
        bitBuffer |= UInt64(inputBase[byteIndex]) << UInt64(bitCount)
        byteIndex += 1
        bitCount += 8
      }
      guard bitCount >= 10 else { return -1 }
      return Int(bitBuffer & 0x03FF)
    }

    @inline(__always)
    mutating func dropBits(_ count: Int) {
      precondition(count >= 0 && count <= bitCount)
      bitBuffer >>= UInt64(count)
      bitCount -= count
    }

    /// Consumes only consecutive <=9-bit literal symbols. The reader state stays positioned at the
    /// first non-literal/slow symbol, so the canonical decoder remains the semantic authority for
    /// length/end symbols and long codes. Local reader state amortizes refill and stored-property
    /// traffic across the literal run without changing the Huffman table or workspace model.
    @inline(__always)
    mutating func copyFastLiteralRun(
      fastLookupBase: UnsafePointer<UInt16>,
      outputBase: UnsafeMutablePointer<UInt8>,
      outputIndex: inout Int,
      outputLimit: Int
    ) -> Int {
      var localBits = bitBuffer
      var localBitCount = bitCount
      var localByteIndex = byteIndex
      var localOutputIndex = outputIndex
      let initialOutputIndex = outputIndex

      literalRun: while localOutputIndex < outputLimit {
        if localBitCount < 27 {
          while localBitCount < 56, localByteIndex < byteLimit {
            localBits |= UInt64(inputBase[localByteIndex]) << UInt64(localBitCount)
            localByteIndex += 1
            localBitCount += 8
          }
          guard localBitCount >= 9 else { break }
        }

        var packed = fastLookupBase[Int(localBits & 0x01FF)]
        var length = Int(packed >> 9)
        guard length > 0, (packed & 0x01FF) < 256 else { break }
        outputBase[localOutputIndex] = UInt8(truncatingIfNeeded: packed)
        localOutputIndex += 1
        localBits >>= UInt64(length)
        localBitCount -= length

        guard localOutputIndex < outputLimit, localBitCount >= 9 else { continue }
        packed = fastLookupBase[Int(localBits & 0x01FF)]
        length = Int(packed >> 9)
        guard length > 0, (packed & 0x01FF) < 256 else { break literalRun }
        outputBase[localOutputIndex] = UInt8(truncatingIfNeeded: packed)
        localOutputIndex += 1
        localBits >>= UInt64(length)
        localBitCount -= length

        guard localOutputIndex < outputLimit, localBitCount >= 9 else { continue }
        packed = fastLookupBase[Int(localBits & 0x01FF)]
        length = Int(packed >> 9)
        guard length > 0, (packed & 0x01FF) < 256 else { break literalRun }
        outputBase[localOutputIndex] = UInt8(truncatingIfNeeded: packed)
        localOutputIndex += 1
        localBits >>= UInt64(length)
        localBitCount -= length
      }

      bitBuffer = localBits
      bitCount = localBitCount
      byteIndex = localByteIndex
      outputIndex = localOutputIndex
      return localOutputIndex - initialOutputIndex
    }

    mutating func alignToByte() {
      let discarded = bitCount & 7
      if discarded > 0 {
        bitBuffer >>= UInt64(discarded)
        bitCount -= discarded
      }
    }

    var bufferedBitCount: Int { bitCount }

    mutating func readAlignedUInt16LE() throws -> UInt16 {
      guard bitCount.isMultiple(of: 8) else {
        throw RFC1950BoundedInflateError.truncatedInput
      }
      return UInt16(try readBits(16))
    }

    mutating func copyAlignedBytes(
      count: Int,
      to output: UnsafeMutableBufferPointer<UInt8>,
      outputIndex: inout Int,
      outputOverflowError: RFC1950BoundedInflateError
    ) throws {
      guard bitCount.isMultiple(of: 8), count >= 0,
        outputIndex + count <= output.count
      else {
        if outputIndex + max(0, count) > output.count {
          throw outputOverflowError
        }
        throw RFC1950BoundedInflateError.truncatedInput
      }
      var remaining = count
      while remaining > 0, bitCount >= 8 {
        output[outputIndex] = UInt8(bitBuffer & 0xFF)
        bitBuffer >>= 8
        bitCount -= 8
        outputIndex += 1
        remaining -= 1
      }
      guard byteIndex + remaining <= byteLimit else {
        throw RFC1950BoundedInflateError.truncatedInput
      }
      if remaining > 0 {
        guard let destination = output.baseAddress,
          outputIndex + remaining <= output.count
        else { throw RFC1950BoundedInflateError.outputLengthMismatch }
        memcpy(
          destination.advanced(by: outputIndex),
          inputBase.advanced(by: byteIndex),
          remaining
        )
      }
      byteIndex += remaining
      outputIndex += remaining
    }

  }

  private struct StreamingBitReader<Cursor: RFC1950StreamingByteCursor>: RFC1950BitReading {
    var cursor: Cursor
    let byteLimit: Int
    var byteIndex = 0
    private var bitBuffer: UInt64 = 0
    private var bitCount: Int = 0

    init(cursor: Cursor, byteLimit: Int) {
      precondition(byteLimit >= 0)
      self.cursor = cursor
      self.byteLimit = byteLimit
    }

    mutating func readBit() throws -> UInt8 {
      if bitCount == 0 {
        guard byteIndex < byteLimit, let byte = cursor.readByte() else {
          throw RFC1950BoundedInflateError.truncatedInput
        }
        bitBuffer = UInt64(byte)
        byteIndex += 1
        bitCount = 8
      }
      let result = UInt8(bitBuffer & 1)
      bitBuffer >>= 1
      bitCount -= 1
      return result
    }

    mutating func readBits(_ count: Int) throws -> UInt32 {
      guard count >= 0, count <= 24 else {
        throw RFC1950BoundedInflateError.truncatedInput
      }
      if count == 0 { return 0 }
      return try readBitsUnchecked(count)
    }

    @inline(__always)
    mutating func readBitsUnchecked(_ count: Int) throws -> UInt32 {
      precondition(count > 0 && count <= 24)
      while bitCount < count {
        guard byteIndex < byteLimit, let byte = cursor.readByte() else {
          throw RFC1950BoundedInflateError.truncatedInput
        }
        bitBuffer |= UInt64(byte) << UInt64(bitCount)
        byteIndex += 1
        bitCount += 8
      }
      let mask = (UInt64(1) << UInt64(count)) - 1
      let result = UInt32(bitBuffer & mask)
      bitBuffer >>= UInt64(count)
      bitCount -= count
      return result
    }

    @inline(__always)
    mutating func peekNineBitsIfAvailable() -> Int {
      while bitCount < 9, byteIndex < byteLimit {
        guard let byte = cursor.readByte() else { return -1 }
        bitBuffer |= UInt64(byte) << UInt64(bitCount)
        byteIndex += 1
        bitCount += 8
      }
      guard bitCount >= 9 else { return -1 }
      return Int(bitBuffer & 0x01FF)
    }

    @inline(__always)
    mutating func peekTenBitsIfAvailable() -> Int {
      while bitCount < 10, byteIndex < byteLimit {
        guard let byte = cursor.readByte() else { return -1 }
        bitBuffer |= UInt64(byte) << UInt64(bitCount)
        byteIndex += 1
        bitCount += 8
      }
      guard bitCount >= 10 else { return -1 }
      return Int(bitBuffer & 0x03FF)
    }

    @inline(__always)
    mutating func decodeFastMatch(
      lengthSymbol: Int,
      distanceFastLookupBase: UnsafePointer<UInt16>
    ) throws -> (length: Int, distance: Int?) {
      let lengthValue = try RFC1950BoundedInflate.sharedLengthBaseAndExtraBits(
        index: lengthSymbol - 257
      )
      let length = lengthValue.base
        + (lengthValue.extra == 0 ? 0 : Int(try readBitsUnchecked(lengthValue.extra)))

      let prefix = peekNineBitsIfAvailable()
      guard prefix >= 0 else { return (length, nil) }
      let packed = distanceFastLookupBase[prefix]
      let codeLength = Int(packed >> 9)
      guard codeLength > 0 else { return (length, nil) }
      let distanceSymbol = Int(packed & 0x01FF)
      guard distanceSymbol <= 29 else {
        throw RFC1950BoundedInflateError.invalidDistanceSymbol
      }
      dropBits(codeLength)
      let distanceValue = try RFC1950BoundedInflate.sharedDistanceBaseAndExtraBits(
        symbol: distanceSymbol
      )
      let distance = distanceValue.base
        + (distanceValue.extra == 0 ? 0 : Int(try readBitsUnchecked(distanceValue.extra)))
      return (length, distance)
    }

    @inline(__always)
    mutating func dropBits(_ count: Int) {
      precondition(count >= 0 && count <= bitCount)
      bitBuffer >>= UInt64(count)
      bitCount -= count
    }

    /// Consumes only consecutive <=9-bit literal symbols into a caller-provided contiguous span.
    /// Input is refilled toward a 56-bit reservoir so many literals share cursor/property traffic.
    /// The first non-literal/slow symbol remains unconsumed for the canonical decoder.
    @inline(__always)
    mutating func copyFastLiteralRun(
      fastLookupBase: UnsafePointer<UInt16>,
      outputBase: UnsafeMutablePointer<UInt8>,
      outputLimit: Int
    ) throws -> (written: Int, followingFastSymbol: UInt16?) {
      guard outputLimit > 0 else { return (0, nil) }
      var localBits = bitBuffer
      var localBitCount = bitCount
      var localByteIndex = byteIndex
      var localOutputIndex = 0
      var followingFastSymbol: UInt16?

      literalRun: while localOutputIndex < outputLimit {
        if localBitCount < 27 {
          while localBitCount < 56, localByteIndex < byteLimit {
            guard let byte = cursor.readByte() else {
              throw RFC1950BoundedInflateError.truncatedInput
            }
            localBits |= UInt64(byte) << UInt64(localBitCount)
            localByteIndex += 1
            localBitCount += 8
          }
          guard localBitCount >= 9 else { break }
        }

        var packed = fastLookupBase[Int(localBits & 0x01FF)]
        var length = Int(packed >> 9)
        guard length > 0 else { break }
        if (packed & 0x01FF) >= 256 {
          followingFastSymbol = packed
          break
        }
        outputBase[localOutputIndex] = UInt8(truncatingIfNeeded: packed)
        localOutputIndex += 1
        localBits >>= UInt64(length)
        localBitCount -= length

        guard localOutputIndex < outputLimit, localBitCount >= 9 else { continue }
        packed = fastLookupBase[Int(localBits & 0x01FF)]
        length = Int(packed >> 9)
        guard length > 0 else { break literalRun }
        if (packed & 0x01FF) >= 256 {
          followingFastSymbol = packed
          break literalRun
        }
        outputBase[localOutputIndex] = UInt8(truncatingIfNeeded: packed)
        localOutputIndex += 1
        localBits >>= UInt64(length)
        localBitCount -= length

        guard localOutputIndex < outputLimit, localBitCount >= 9 else { continue }
        packed = fastLookupBase[Int(localBits & 0x01FF)]
        length = Int(packed >> 9)
        guard length > 0 else { break literalRun }
        if (packed & 0x01FF) >= 256 {
          followingFastSymbol = packed
          break literalRun
        }
        outputBase[localOutputIndex] = UInt8(truncatingIfNeeded: packed)
        localOutputIndex += 1
        localBits >>= UInt64(length)
        localBitCount -= length
      }

      bitBuffer = localBits
      bitCount = localBitCount
      byteIndex = localByteIndex
      return (localOutputIndex, followingFastSymbol)
    }

    mutating func alignToByte() {
      let discarded = bitCount & 7
      if discarded > 0 {
        bitBuffer >>= UInt64(discarded)
        bitCount -= discarded
      }
    }

    var bufferedBitCount: Int { bitCount }

    mutating func readAlignedUInt16LE() throws -> UInt16 {
      guard bitCount.isMultiple(of: 8) else {
        throw RFC1950BoundedInflateError.truncatedInput
      }
      return UInt16(try readBits(16))
    }

    mutating func copyAlignedBytes(
      count: Int,
      to output: inout StreamingOutput
    ) throws {
      guard bitCount.isMultiple(of: 8), count >= 0 else {
        throw RFC1950BoundedInflateError.truncatedInput
      }
      var remaining = count
      while remaining > 0, bitCount >= 8 {
        try output.append(UInt8(bitBuffer & 0xFF))
        bitBuffer >>= 8
        bitCount -= 8
        remaining -= 1
      }
      let end = byteIndex.addingReportingOverflow(remaining)
      guard !end.overflow, end.partialValue <= byteLimit else {
        throw RFC1950BoundedInflateError.truncatedInput
      }
      if remaining > 0 {
        try output.append(from: &cursor, count: remaining)
        byteIndex += remaining
      }
    }

    mutating func readTrailerByte() throws -> UInt8 {
      guard bitCount == 0,
        byteIndex == byteLimit,
        let byte = cursor.readByte()
      else { throw RFC1950BoundedInflateError.truncatedInput }
      return byte
    }

    var remainingUnderlyingByteCount: Int { cursor.remainingByteCount }
  }

  private static func sharedDynamicTables<Reader: RFC1950BitReading>(
    reader: inout Reader
  ) throws -> (literalLength: HuffmanTable, distance: HuffmanTable) {
    let literalCount = Int(try reader.readBits(5)) + 257
    let distanceCount = Int(try reader.readBits(5)) + 1
    let codeLengthCount = Int(try reader.readBits(4)) + 4
    guard literalCount <= 286, distanceCount <= 32, codeLengthCount <= 19 else {
      throw RFC1950BoundedInflateError.invalidHuffmanTree
    }

    let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
    var codeLengthLengths = [UInt8](repeating: 0, count: 19)
    for index in 0..<codeLengthCount {
      codeLengthLengths[order[index]] = UInt8(try reader.readBits(3))
    }
    let codeLengthTable = try HuffmanTable(lengths: codeLengthLengths)

    let totalCount = literalCount + distanceCount
    var lengths = [UInt8](repeating: 0, count: totalCount)
    var index = 0
    while index < totalCount {
      let symbol = try codeLengthTable.decodeSymbol(reader: &reader)
      switch symbol {
      case 0...15:
        lengths[index] = UInt8(symbol)
        index += 1
      case 16:
        guard index > 0 else { throw RFC1950BoundedInflateError.invalidHuffmanTree }
        let repeatCount = Int(try reader.readBits(2)) + 3
        guard index + repeatCount <= totalCount else {
          throw RFC1950BoundedInflateError.invalidHuffmanTree
        }
        let previous = lengths[index - 1]
        for repeated in index..<(index + repeatCount) { lengths[repeated] = previous }
        index += repeatCount
      case 17:
        let repeatCount = Int(try reader.readBits(3)) + 3
        guard index + repeatCount <= totalCount else {
          throw RFC1950BoundedInflateError.invalidHuffmanTree
        }
        index += repeatCount
      case 18:
        let repeatCount = Int(try reader.readBits(7)) + 11
        guard index + repeatCount <= totalCount else {
          throw RFC1950BoundedInflateError.invalidHuffmanTree
        }
        index += repeatCount
      default:
        throw RFC1950BoundedInflateError.invalidHuffmanTree
      }
    }
    guard lengths.count > 256, lengths[256] != 0 else {
      throw RFC1950BoundedInflateError.invalidHuffmanTree
    }
    let literalLength = try HuffmanTable(
      lengths: lengths[0..<literalCount],
      allowsSingleOneBitIncomplete: true,
      enablesTenBitSecondary: true
    )
    let distanceLengths = lengths[literalCount..<totalCount]
    let distance: HuffmanTable
    if distanceLengths.contains(where: { $0 != 0 }) {
      distance = try HuffmanTable(
        lengths: distanceLengths,
        allowsSingleOneBitIncomplete: true
      )
    } else {
      var invalidDistanceLengths = [UInt8](repeating: 0, count: 31)
      invalidDistanceLengths[30] = 1
      distance = try HuffmanTable(
        lengths: invalidDistanceLengths,
        allowsSingleOneBitIncomplete: true
      )
    }
    return (literalLength, distance)
  }

  private static func sharedFixedTables() throws -> (
    literalLength: HuffmanTable,
    distance: HuffmanTable
  ) {
    var literalLengths = [UInt8](repeating: 0, count: 288)
    for symbol in 0...143 { literalLengths[symbol] = 8 }
    for symbol in 144...255 { literalLengths[symbol] = 9 }
    for symbol in 256...279 { literalLengths[symbol] = 7 }
    for symbol in 280...287 { literalLengths[symbol] = 8 }
    let distanceLengths = [UInt8](repeating: 5, count: 32)
    return (
      try HuffmanTable(lengths: literalLengths),
      try HuffmanTable(lengths: distanceLengths)
    )
  }

  @inline(__always)
  private static func sharedLengthBaseAndExtraBits(index: Int) throws -> (base: Int, extra: Int) {
    guard index >= 0, index <= 28 else {
      throw RFC1950BoundedInflateError.invalidLengthSymbol
    }
    if index < 8 { return (index + 3, 0) }
    if index == 28 { return (258, 0) }
    let groupIndex = index - 8
    let extraBitCount = (groupIndex >> 2) + 1
    let positionInGroup = groupIndex & 3
    let base = (1 << (extraBitCount + 2)) + 3 + (positionInGroup << extraBitCount)
    return (base, extraBitCount)
  }

  @inline(__always)
  private static func sharedDistanceBaseAndExtraBits(symbol: Int) throws -> (base: Int, extra: Int) {
    guard symbol >= 0, symbol <= 29 else {
      throw RFC1950BoundedInflateError.invalidDistanceSymbol
    }
    if symbol < 4 { return (symbol + 1, 0) }
    let extraBitCount = (symbol >> 1) - 1
    let base = (1 << (extraBitCount + 1)) + 1 + ((symbol & 1) << extraBitCount)
    return (base, extraBitCount)
  }

  private static func sharedLengthValue(
    index: Int,
    reader: inout BitReader
  ) throws -> Int {
    let value = try sharedLengthBaseAndExtraBits(index: index)
    if value.extra == 0 { return value.base }
    return value.base + Int(try reader.readBitsUnchecked(value.extra))
  }

  private static func sharedLengthValue<Cursor: RFC1950StreamingByteCursor>(
    index: Int,
    reader: inout StreamingBitReader<Cursor>
  ) throws -> Int {
    let value = try sharedLengthBaseAndExtraBits(index: index)
    if value.extra == 0 { return value.base }
    return value.base + Int(try reader.readBitsUnchecked(value.extra))
  }

  private static func sharedDistanceValue(
    symbol: Int,
    reader: inout BitReader
  ) throws -> Int {
    let value = try sharedDistanceBaseAndExtraBits(symbol: symbol)
    if value.extra == 0 { return value.base }
    return value.base + Int(try reader.readBitsUnchecked(value.extra))
  }

  private static func sharedDistanceValue<Cursor: RFC1950StreamingByteCursor>(
    symbol: Int,
    reader: inout StreamingBitReader<Cursor>
  ) throws -> Int {
    let value = try sharedDistanceBaseAndExtraBits(symbol: symbol)
    if value.extra == 0 { return value.base }
    return value.base + Int(try reader.readBitsUnchecked(value.extra))
  }

  @inline(__always)
  private static func accumulateAdlerUnreduced(
    _ bytes: UnsafeBufferPointer<UInt8>,
    offset: inout Int,
    end: Int,
    a: inout UInt64,
    b: inout UInt64
  ) {
    guard let base = bytes.baseAddress else { return }
    while offset + 16 <= end {
      let a0 = a
      let x0 = UInt64(base[offset])
      let x1 = UInt64(base[offset + 1])
      let x2 = UInt64(base[offset + 2])
      let x3 = UInt64(base[offset + 3])
      let x4 = UInt64(base[offset + 4])
      let x5 = UInt64(base[offset + 5])
      let x6 = UInt64(base[offset + 6])
      let x7 = UInt64(base[offset + 7])
      let x8 = UInt64(base[offset + 8])
      let x9 = UInt64(base[offset + 9])
      let x10 = UInt64(base[offset + 10])
      let x11 = UInt64(base[offset + 11])
      let x12 = UInt64(base[offset + 12])
      let x13 = UInt64(base[offset + 13])
      let x14 = UInt64(base[offset + 14])
      let x15 = UInt64(base[offset + 15])
      let sum0 = x0 + x1 + x2 + x3
      let sum1 = x4 + x5 + x6 + x7
      let sum2 = x8 + x9 + x10 + x11
      let sum3 = x12 + x13 + x14 + x15
      let weighted0 = 16 * x0 + 15 * x1 + 14 * x2 + 13 * x3
      let weighted1 = 12 * x4 + 11 * x5 + 10 * x6 + 9 * x7
      let weighted2 = 8 * x8 + 7 * x9 + 6 * x10 + 5 * x11
      let weighted3 = 4 * x12 + 3 * x13 + 2 * x14 + x15
      a = a0 + sum0 + sum1 + sum2 + sum3
      b += 16 * a0 + weighted0 + weighted1 + weighted2 + weighted3
      offset += 16
    }
    while offset < end {
      a += UInt64(base[offset])
      b += a
      offset += 1
    }
  }

  private final class StreamingWindowStorage {
    let baseAddress: UnsafeMutablePointer<UInt8>

    init() {
      baseAddress = UnsafeMutablePointer<UInt8>.allocate(
        capacity: RFC1950BoundedInflate.streamingWindowByteCount
      )
      baseAddress.initialize(
        repeating: 0,
        count: RFC1950BoundedInflate.streamingWindowByteCount
      )
    }

    deinit {
      baseAddress.deinitialize(count: RFC1950BoundedInflate.streamingWindowByteCount)
      baseAddress.deallocate()
    }
  }

  private struct StreamingOutput {
    private let expectedByteCount: Int
    private let consume: (UnsafeBufferPointer<UInt8>) throws -> Void
    private let window = StreamingWindowStorage()
    // The 36 KiB window is nine 4 KiB slots. Eight slots retain the full 32 KiB DEFLATE
    // lookback; one slot is the current pending sink span. Full flushes advance by exactly one
    // slot, so pending bytes are always contiguous and never straddle the physical window end.
    private var stagingStartIndex = 0
    private var stagingCount = 0
    private var adlerA = UInt64(1)
    private var adlerB = UInt64(0)
    private var bytesSinceAdlerReduction = 0
    private(set) var count = 0
    var remainingByteCount: Int { expectedByteCount - count }

    init(
      expectedByteCount: Int,
      consume: @escaping (UnsafeBufferPointer<UInt8>) throws -> Void
    ) {
      self.expectedByteCount = expectedByteCount
      self.consume = consume
    }

    @inline(__always)
    mutating func append(_ byte: UInt8) throws {
      guard count < expectedByteCount else {
        throw RFC1950BoundedInflateError.outputLengthMismatch
      }
      window.baseAddress[stagingStartIndex + stagingCount] = byte
      stagingCount += 1
      count += 1
      if stagingCount == RFC1950BoundedInflate.streamingStagingByteCount {
        try flush()
      }
    }

    @inline(__always)
    mutating func appendFastLiteralRun<Cursor: RFC1950StreamingByteCursor>(
      reader: inout StreamingBitReader<Cursor>,
      fastLookupBase: UnsafePointer<UInt16>
    ) throws -> (written: Int, followingFastSymbol: UInt16?) {
      if stagingCount == RFC1950BoundedInflate.streamingStagingByteCount { try flush() }
      let writableCount = min(
        RFC1950BoundedInflate.streamingStagingByteCount - stagingCount,
        remainingByteCount
      )
      guard writableCount > 0 else { return (0, nil) }
      let destination = window.baseAddress.advanced(by: stagingStartIndex + stagingCount)
      let result = try reader.copyFastLiteralRun(
        fastLookupBase: fastLookupBase,
        outputBase: destination,
        outputLimit: writableCount
      )
      stagingCount += result.written
      count += result.written
      if stagingCount == RFC1950BoundedInflate.streamingStagingByteCount { try flush() }
      return result
    }

    mutating func append(contentsOf bytes: UnsafeBufferPointer<UInt8>) throws {
      let outputEnd = count.addingReportingOverflow(bytes.count)
      guard !outputEnd.overflow, outputEnd.partialValue <= expectedByteCount else {
        throw RFC1950BoundedInflateError.outputLengthMismatch
      }
      var sourceOffset = 0
      while sourceOffset < bytes.count {
        if stagingCount == RFC1950BoundedInflate.streamingStagingByteCount { try flush() }
        let chunkCount = min(
          bytes.count - sourceOffset,
          RFC1950BoundedInflate.streamingStagingByteCount - stagingCount
        )
        let stagingStart = stagingCount
        guard chunkCount > 0, let sourceBase = bytes.baseAddress else {
          throw RFC1950BoundedInflateError.outputLengthMismatch
        }
        memcpy(
          window.baseAddress.advanced(by: stagingStartIndex + stagingStart),
          sourceBase.advanced(by: sourceOffset),
          chunkCount
        )
        stagingCount += chunkCount
        count += chunkCount
        if stagingCount == RFC1950BoundedInflate.streamingStagingByteCount { try flush() }
        sourceOffset += chunkCount
      }
    }

    mutating func append<Cursor: RFC1950StreamingByteCursor>(
      from cursor: inout Cursor,
      count requestedCount: Int
    ) throws {
      let outputEnd = count.addingReportingOverflow(requestedCount)
      guard requestedCount >= 0,
        !outputEnd.overflow,
        outputEnd.partialValue <= expectedByteCount
      else { throw RFC1950BoundedInflateError.outputLengthMismatch }
      var remaining = requestedCount
      while remaining > 0 {
        if stagingCount == RFC1950BoundedInflate.streamingStagingByteCount { try flush() }
        let chunkCount = min(
          remaining,
          RFC1950BoundedInflate.streamingStagingByteCount - stagingCount
        )
        let stagingStart = stagingCount
        let destination = UnsafeMutableBufferPointer(
          start: window.baseAddress.advanced(by: stagingStartIndex + stagingStart),
          count: chunkCount
        )
        let copied = cursor.read(into: destination)
        guard copied == chunkCount else {
          throw RFC1950BoundedInflateError.truncatedInput
        }
        stagingCount += chunkCount
        count += chunkCount
        if stagingCount == RFC1950BoundedInflate.streamingStagingByteCount { try flush() }
        remaining -= chunkCount
      }
    }

    @inline(__always)
    private static func copyShortNonoverlapping(
      destination: UnsafeMutablePointer<UInt8>,
      source: UnsafePointer<UInt8>,
      length: Int
    ) {
      switch length {
      case 3: memcpy(destination, source, 3)
      case 4: memcpy(destination, source, 4)
      case 5: memcpy(destination, source, 5)
      case 6: memcpy(destination, source, 6)
      case 7: memcpy(destination, source, 7)
      case 8: memcpy(destination, source, 8)
      case 9: memcpy(destination, source, 9)
      case 10: memcpy(destination, source, 10)
      case 11: memcpy(destination, source, 11)
      case 12: memcpy(destination, source, 12)
      case 13: memcpy(destination, source, 13)
      case 14: memcpy(destination, source, 14)
      case 15: memcpy(destination, source, 15)
      case 16: memcpy(destination, source, 16)
      case 17...32:
        memcpy(destination, source, 16)
        let tailOffset = length - 16
        memcpy(
          destination.advanced(by: tailOffset),
          source.advanced(by: tailOffset),
          16
        )
      default: memcpy(destination, source, length)
      }
    }

    mutating func copyMatch(length: Int, distance: Int) throws {
      let outputEnd = count.addingReportingOverflow(length)
      guard length > 0,
        distance > 0,
        distance <= RFC1950BoundedInflate.streamingHistoryByteCount,
        distance <= count,
        !outputEnd.overflow,
        outputEnd.partialValue <= expectedByteCount
      else {
        let attemptedEnd = count.addingReportingOverflow(max(0, length))
        if attemptedEnd.overflow || attemptedEnd.partialValue > expectedByteCount {
          throw RFC1950BoundedInflateError.outputLengthMismatch
        }
        throw RFC1950BoundedInflateError.invalidBackReference
      }

      if stagingCount == RFC1950BoundedInflate.streamingStagingByteCount { try flush() }
      let stagingAvailable = RFC1950BoundedInflate.streamingStagingByteCount - stagingCount
      if length <= stagingAvailable, distance >= length {
        let destinationIndex = stagingStartIndex + stagingCount
        var sourceIndex = destinationIndex - distance
        if sourceIndex < 0 { sourceIndex += RFC1950BoundedInflate.streamingWindowByteCount }
        let base = window.baseAddress
        let destination = base.advanced(by: destinationIndex)
        let firstCount = min(
          length,
          RFC1950BoundedInflate.streamingWindowByteCount - sourceIndex
        )
        if length <= 16,
          stagingAvailable >= 16,
          distance >= 16,
          sourceIndex + 16 <= RFC1950BoundedInflate.streamingWindowByteCount
        {
          // The 16-byte source and destination spans are non-overlapping when distance >= 16.
          // Only `length` bytes become logical output; the harmless staging over-write is outside
          // stagingCount and will be replaced before those future positions are ever committed.
          memcpy(destination, base.advanced(by: sourceIndex), 16)
        } else if length <= 32, firstCount == length {
          Self.copyShortNonoverlapping(
            destination: destination,
            source: UnsafePointer(base.advanced(by: sourceIndex)),
            length: length
          )
        } else {
          memcpy(destination, base.advanced(by: sourceIndex), firstCount)
        }
        let secondCount = length - firstCount
        if secondCount > 0 {
          memcpy(destination.advanced(by: firstCount), base, secondCount)
        }
        stagingCount += length
        count += length
        if stagingCount == RFC1950BoundedInflate.streamingStagingByteCount { try flush() }
        return
      }

      var remaining = length
      while remaining > 0 {
        if stagingCount == RFC1950BoundedInflate.streamingStagingByteCount { try flush() }
        let chunkCount = min(
          remaining,
          RFC1950BoundedInflate.streamingStagingByteCount - stagingCount
        )
        let destinationIndex = stagingStartIndex + stagingCount
        let seedCount = min(distance, chunkCount)
        var sourceIndex = destinationIndex - distance
        if sourceIndex < 0 { sourceIndex += RFC1950BoundedInflate.streamingWindowByteCount }
        let base = window.baseAddress
        let destination = base.advanced(by: destinationIndex)
        let firstSeedCount = min(
          seedCount,
          RFC1950BoundedInflate.streamingWindowByteCount - sourceIndex
        )
        memcpy(destination, base.advanced(by: sourceIndex), firstSeedCount)
        let secondSeedCount = seedCount - firstSeedCount
        if secondSeedCount > 0 {
          memcpy(destination.advanced(by: firstSeedCount), base, secondSeedCount)
        }
        var generated = seedCount
        while generated < chunkCount {
          let copied = min(generated, chunkCount - generated)
          memcpy(
            destination.advanced(by: generated),
            destination,
            copied
          )
          generated += copied
        }
        stagingCount += chunkCount
        count += chunkCount
        if stagingCount == RFC1950BoundedInflate.streamingStagingByteCount { try flush() }
        remaining -= chunkCount
      }
    }

    mutating func finish(storedAdler: UInt32) throws {
      guard count == expectedByteCount else {
        throw RFC1950BoundedInflateError.outputLengthMismatch
      }
      commitPendingStaging()
      reduceAdler()
      let actual = UInt32((adlerB << 16) | adlerA)
      guard actual == storedAdler else {
        throw RFC1950BoundedInflateError.adler32Mismatch
      }
      try deliverStaging()
    }

    private mutating func reduceAdler() {
      adlerA %= adlerModulus
      adlerB %= adlerModulus
      bytesSinceAdlerReduction = 0
    }

    private mutating func commitPendingStaging() {
      guard stagingCount > 0 else { return }
      var nextAdlerA = adlerA
      var nextAdlerB = adlerB
      var nextBytesSinceReduction = bytesSinceAdlerReduction
      let source = UnsafeBufferPointer(
        start: UnsafePointer(window.baseAddress.advanced(by: stagingStartIndex)),
        count: stagingCount
      )
      Self.accumulateAdler(
        source,
        a: &nextAdlerA,
        b: &nextAdlerB,
        bytesSinceReduction: &nextBytesSinceReduction
      )
      adlerA = nextAdlerA
      adlerB = nextAdlerB
      bytesSinceAdlerReduction = nextBytesSinceReduction
    }

    private static func accumulateAdler(
      _ bytes: UnsafeBufferPointer<UInt8>,
      a: inout UInt64,
      b: inout UInt64,
      bytesSinceReduction: inout Int
    ) {
      var offset = 0
      while offset < bytes.count {
        let room = RFC1950BoundedInflate.adlerNMAX - bytesSinceReduction
        let end = min(bytes.count, offset + room)
        let start = offset
        RFC1950BoundedInflate.accumulateAdlerUnreduced(
          bytes,
          offset: &offset,
          end: end,
          a: &a,
          b: &b
        )
        bytesSinceReduction += end - start
        if bytesSinceReduction >= RFC1950BoundedInflate.adlerNMAX {
          a %= RFC1950BoundedInflate.adlerModulus
          b %= RFC1950BoundedInflate.adlerModulus
          bytesSinceReduction = 0
        }
      }
    }

    private mutating func flush() throws {
      guard stagingCount > 0 else { return }
      commitPendingStaging()
      try deliverStaging()
    }

    private mutating func deliverStaging() throws {
      guard stagingCount > 0 else { return }
      try consume(
        UnsafeBufferPointer(
          start: UnsafePointer(window.baseAddress.advanced(by: stagingStartIndex)),
          count: stagingCount
        )
      )
      stagingCount = 0
      stagingStartIndex += RFC1950BoundedInflate.streamingStagingByteCount
      if stagingStartIndex == RFC1950BoundedInflate.streamingWindowByteCount {
        stagingStartIndex = 0
      }
    }
  }

  private struct StreamingDecoder<Cursor: RFC1950StreamingByteCursor> {
    var reader: StreamingBitReader<Cursor>
    var output: StreamingOutput

    init(
      cursor: Cursor,
      expectedByteCount: Int,
      consume: @escaping (UnsafeBufferPointer<UInt8>) throws -> Void
    ) throws {
      var cursor = cursor
      guard cursor.remainingByteCount >= 6,
        let cmf = cursor.readByte(),
        let flg = cursor.readByte()
      else { throw RFC1950BoundedInflateError.invalidHeader }
      guard cmf & 0x0F == 8,
        cmf >> 4 <= 7,
        (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0
      else { throw RFC1950BoundedInflateError.invalidHeader }
      guard flg & 0x20 == 0 else {
        throw RFC1950BoundedInflateError.presetDictionaryUnsupported
      }
      guard cursor.remainingByteCount >= 4 else {
        throw RFC1950BoundedInflateError.truncatedInput
      }
      self.reader = StreamingBitReader(
        cursor: cursor,
        byteLimit: cursor.remainingByteCount - 4
      )
      self.output = StreamingOutput(
        expectedByteCount: expectedByteCount,
        consume: consume
      )
    }

    mutating func decode() throws {
      var isFinal = false
      while !isFinal {
        isFinal = try reader.readBits(1) == 1
        switch try reader.readBits(2) {
        case 0:
          try decodeStoredBlock()
        case 1:
          let tables = try RFC1950BoundedInflate.sharedFixedTables()
          try decodeCompressedBlock(literalLength: tables.literalLength, distance: tables.distance)
        case 2:
          let tables = try RFC1950BoundedInflate.sharedDynamicTables(reader: &reader)
          try decodeCompressedBlock(literalLength: tables.literalLength, distance: tables.distance)
        default:
          throw RFC1950BoundedInflateError.invalidBlockType
        }
      }

      reader.alignToByte()
      guard reader.bufferedBitCount == 0,
        reader.byteIndex == reader.byteLimit
      else { throw RFC1950BoundedInflateError.truncatedInput }
      let storedAdler = UInt32(try reader.readTrailerByte()) << 24
        | UInt32(try reader.readTrailerByte()) << 16
        | UInt32(try reader.readTrailerByte()) << 8
        | UInt32(try reader.readTrailerByte())
      guard reader.remainingUnderlyingByteCount == 0 else {
        throw RFC1950BoundedInflateError.truncatedInput
      }
      try output.finish(storedAdler: storedAdler)
    }

    private mutating func decodeStoredBlock() throws {
      reader.alignToByte()
      let length = try reader.readAlignedUInt16LE()
      let complement = try reader.readAlignedUInt16LE()
      guard length ^ complement == UInt16.max else {
        throw RFC1950BoundedInflateError.invalidStoredBlock
      }
      try reader.copyAlignedBytes(count: Int(length), to: &output)
    }

    private mutating func decodeCompressedBlock(
      literalLength: HuffmanTable,
      distance: HuffmanTable
    ) throws {
      try literalLength.withFastLookup { literalFast in
        try distance.withFastLookup { distanceFast in
          while true {
            var followingFastSymbol: UInt16?
            if literalLength.prefersFastLiteralRuns {
              let fastRun = try output.appendFastLiteralRun(
                reader: &reader,
                fastLookupBase: literalFast
              )
              followingFastSymbol = fastRun.followingFastSymbol
              if fastRun.written > 0, followingFastSymbol == nil {
                continue
              }
            }
            let symbol: Int
            if let packed = followingFastSymbol {
              reader.dropBits(Int(packed >> 9))
              symbol = Int(packed & 0x01FF)
            } else {
              symbol = try literalLength.decodeSymbol(
                reader: &reader,
                fastLookupBase: literalFast
              )
            }
            switch symbol {
            case 0...255:
              try output.append(UInt8(symbol))
            case 256:
              return
            case 257...285:
              let fastMatch = try reader.decodeFastMatch(
                lengthSymbol: symbol,
                distanceFastLookupBase: distanceFast
              )
              let backDistance: Int
              if let fastDistance = fastMatch.distance {
                backDistance = fastDistance
              } else {
                let distanceSymbol = try distance.decodeSymbol(
                  reader: &reader,
                  fastLookupBase: distanceFast
                )
                guard distanceSymbol <= 29 else {
                  throw RFC1950BoundedInflateError.invalidDistanceSymbol
                }
                backDistance = try RFC1950BoundedInflate.sharedDistanceValue(
                  symbol: distanceSymbol,
                  reader: &reader
                )
              }
              try output.copyMatch(length: fastMatch.length, distance: backDistance)
            default:
              throw RFC1950BoundedInflateError.invalidLengthSymbol
            }
          }
        }
      }
    }
  }

  /// Package-only input-suspendable RFC1950 decoder. Unlike `inflateStreaming`, which streams only
  /// decompressed output while borrowing one complete compressed input, this session accepts
  /// arbitrary compressed chunks and releases committed input prefixes between calls.
  ///
  /// Suspension is transactional rather than whole-block replay. Zlib/block headers, dynamic
  /// Huffman construction and one compressed symbol/match are retried from a reader checkpoint
  /// when a chunk ends; stored-block payload tracks an explicit remaining byte count. The fixed
  /// 512-byte rollback ring therefore bounds retained compressed input independently of caller
  /// chunk size. Sink effects remain provisional until `finishInput()` succeeds, matching the
  /// existing streaming decoder's late-Adler-failure contract.
  package final class ResumableSession {
    package private(set) var acceptedInputByteCount = 0
    package private(set) var maximumObservedRetainedInputByteCount = 0

    package var retainedInputByteCount: Int { reader.retainedByteCount }
    package var reclaimedInputByteCount: Int { acceptedInputByteCount - retainedInputByteCount }
    package var decodedByteCount: Int { output.count }
    package var isComplete: Bool {
      if case .complete = phase { return true }
      return false
    }

    private enum Phase {
      case zlibHeader
      case blockHeader
      case dynamicTables(isFinal: Bool)
      case storedHeader(isFinal: Bool)
      case storedData(isFinal: Bool, remaining: Int)
      case compressed(isFinal: Bool, literalLength: HuffmanTable, distance: HuffmanTable)
      case trailer(index: Int, value: UInt32)
      case complete
      case failed
    }

    private enum CompressedToken {
      case literal(UInt8)
      case end
      case match(length: Int, distance: Int)
    }

    private var reader = ResumableBitReader()
    private var output: StreamingOutput
    private var phase: Phase = .zlibHeader

    package init(
      expectedByteCount: Int,
      consume: @escaping (UnsafeBufferPointer<UInt8>) throws -> Void
    ) throws {
      guard expectedByteCount >= 0 else {
        throw RFC1950BoundedInflateError.outputLengthMismatch
      }
      output = StreamingOutput(expectedByteCount: expectedByteCount, consume: consume)
    }

    package func append(_ data: Data) throws {
      try data.withUnsafeBytes { rawBytes in
        try append(rawBytes.bindMemory(to: UInt8.self))
      }
    }

    package func append(_ source: UnsafeBufferPointer<UInt8>) throws {
      guard !source.isEmpty else { return }
      guard !isComplete else { throw RFC1950BoundedInflateError.truncatedInput }
      guard case .failed = phase else {
        do {
          var sourceOffset = 0
          while sourceOffset < source.count {
            if reader.availableByteCapacity == 0 {
              try processAvailableInput()
              guard reader.availableByteCapacity > 0 else {
                throw RFC1950BoundedInflateError.rollbackWindowExceeded
              }
            }

            let copied = reader.append(
              source,
              offset: sourceOffset,
              maximumCount: reader.availableByteCapacity
            )
            guard copied > 0 else {
              throw RFC1950BoundedInflateError.rollbackWindowExceeded
            }
            sourceOffset += copied
            acceptedInputByteCount += copied
            maximumObservedRetainedInputByteCount = max(
              maximumObservedRetainedInputByteCount,
              reader.retainedByteCount
            )

            try processAvailableInput()
            if isComplete, sourceOffset < source.count {
              throw RFC1950BoundedInflateError.truncatedInput
            }
          }
          return
        } catch {
          phase = .failed
          throw error
        }
      }
      throw RFC1950BoundedInflateError.truncatedInput
    }

    /// Declares that no further RFC1950 bytes will arrive. Successful return is the publication
    /// boundary for all sink slices previously delivered by the session.
    package func finishInput() throws {
      guard case .failed = phase else {
        do {
          try processAvailableInput()
          guard isComplete,
            reader.retainedByteCount == 0,
            reader.bufferedBitCount == 0
          else { throw RFC1950BoundedInflateError.truncatedInput }
          return
        } catch {
          phase = .failed
          throw error
        }
      }
      throw RFC1950BoundedInflateError.truncatedInput
    }

    private func processAvailableInput() throws {
      processing: while true {
        switch phase {
        case .zlibHeader:
          guard let header = try transaction({ reader in
            (UInt8(try reader.readBits(8)), UInt8(try reader.readBits(8)))
          }) else { return }
          let cmf = header.0
          let flg = header.1
          guard cmf & 0x0F == 8,
            cmf >> 4 <= 7,
            (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0
          else { throw RFC1950BoundedInflateError.invalidHeader }
          guard flg & 0x20 == 0 else {
            throw RFC1950BoundedInflateError.presetDictionaryUnsupported
          }
          phase = .blockHeader

        case .blockHeader:
          guard let header = try transaction({ reader in
            (try reader.readBits(1) == 1, try reader.readBits(2))
          }) else { return }
          switch header.1 {
          case 0:
            phase = .storedHeader(isFinal: header.0)
          case 1:
            let tables = try RFC1950BoundedInflate.sharedFixedTables()
            phase = .compressed(
              isFinal: header.0,
              literalLength: tables.literalLength,
              distance: tables.distance
            )
          case 2:
            phase = .dynamicTables(isFinal: header.0)
          default:
            throw RFC1950BoundedInflateError.invalidBlockType
          }

        case .dynamicTables(let isFinal):
          guard let tables = try transaction({ reader in
            try RFC1950BoundedInflate.sharedDynamicTables(reader: &reader)
          }) else { return }
          phase = .compressed(
            isFinal: isFinal,
            literalLength: tables.literalLength,
            distance: tables.distance
          )

        case .storedHeader(let isFinal):
          guard let lengths = try transaction({ reader in
            reader.alignToByte()
            return (
              try reader.readAlignedUInt16LE(),
              try reader.readAlignedUInt16LE()
            )
          }) else { return }
          guard lengths.0 ^ lengths.1 == UInt16.max else {
            throw RFC1950BoundedInflateError.invalidStoredBlock
          }
          phase = .storedData(isFinal: isFinal, remaining: Int(lengths.0))

        case .storedData(let isFinal, var remaining):
          while remaining > 0 {
            guard let byte = try transaction({ reader in
              UInt8(try reader.readBits(8))
            }) else {
              phase = .storedData(isFinal: isFinal, remaining: remaining)
              return
            }
            try output.append(byte)
            remaining -= 1
          }
          transitionAfterBlock(isFinal: isFinal)

        case .compressed(let isFinal, let literalLength, let distance):
          while true {
            guard let token = try transaction({ reader in
              let symbol = try literalLength.decodeSymbol(reader: &reader)
              switch symbol {
              case 0...255:
                return CompressedToken.literal(UInt8(symbol))
              case 256:
                return CompressedToken.end
              case 257...285:
                let lengthSpec = try RFC1950BoundedInflate.sharedLengthBaseAndExtraBits(
                  index: symbol - 257
                )
                let lengthExtra = lengthSpec.extra == 0
                  ? 0
                  : Int(try reader.readBits(lengthSpec.extra))
                let length = lengthSpec.base + lengthExtra
                let distanceSymbol = try distance.decodeSymbol(reader: &reader)
                guard distanceSymbol <= 29 else {
                  throw RFC1950BoundedInflateError.invalidDistanceSymbol
                }
                let distanceSpec = try RFC1950BoundedInflate.sharedDistanceBaseAndExtraBits(
                  symbol: distanceSymbol
                )
                let distanceExtra = distanceSpec.extra == 0
                  ? 0
                  : Int(try reader.readBits(distanceSpec.extra))
                let backDistance = distanceSpec.base + distanceExtra
                return CompressedToken.match(length: length, distance: backDistance)
              default:
                throw RFC1950BoundedInflateError.invalidLengthSymbol
              }
            }) else {
              phase = .compressed(
                isFinal: isFinal,
                literalLength: literalLength,
                distance: distance
              )
              return
            }

            switch token {
            case .literal(let byte):
              try output.append(byte)
            case .match(let length, let distance):
              try output.copyMatch(length: length, distance: distance)
            case .end:
              transitionAfterBlock(isFinal: isFinal)
              continue processing
            }
          }

        case .trailer(let index, let value):
          guard let byte = try transaction({ reader in
            UInt8(try reader.readBits(8))
          }) else { return }
          let updated: UInt32
          switch index {
          case 0: updated = UInt32(byte) << 24
          case 1: updated = value | UInt32(byte) << 16
          case 2: updated = value | UInt32(byte) << 8
          case 3: updated = value | UInt32(byte)
          default: throw RFC1950BoundedInflateError.truncatedInput
          }
          if index == 3 {
            try output.finish(storedAdler: updated)
            phase = .complete
            guard reader.retainedByteCount == 0, reader.bufferedBitCount == 0 else {
              throw RFC1950BoundedInflateError.truncatedInput
            }
            return
          }
          phase = .trailer(index: index + 1, value: updated)

        case .complete:
          return

        case .failed:
          throw RFC1950BoundedInflateError.truncatedInput
        }
      }
    }

    private func transitionAfterBlock(isFinal: Bool) {
      if isFinal {
        reader.alignToByte()
        phase = .trailer(index: 0, value: 0)
      } else {
        phase = .blockHeader
      }
    }

    private func transaction<T>(
      _ body: (inout ResumableBitReader) throws -> T
    ) throws -> T? {
      let checkpoint = reader.checkpoint()
      do {
        let result = try body(&reader)
        reader.commitConsumedBytes()
        return result
      } catch RFC1950BoundedInflateError.truncatedInput {
        reader.restore(checkpoint)
        return nil
      }
    }
  }

  private struct ResumableBitReader: RFC1950BitReading {
    struct Checkpoint {
      let readOffset: Int
      let bitBuffer: UInt64
      let bitCount: Int
    }

    private var storage = [UInt8](
      repeating: 0,
      count: RFC1950BoundedInflate.resumableInputRollbackByteCount
    )
    private var head = 0
    private var storedCount = 0
    private var readOffset = 0
    private var bitBuffer: UInt64 = 0
    private var bitCount = 0

    var retainedByteCount: Int { storedCount }
    var availableByteCapacity: Int { storage.count - storedCount }
    var bufferedBitCount: Int { bitCount }

    mutating func append(
      _ source: UnsafeBufferPointer<UInt8>,
      offset: Int,
      maximumCount: Int
    ) -> Int {
      guard offset >= 0, offset < source.count, maximumCount > 0 else { return 0 }
      let copied = min(source.count - offset, min(maximumCount, availableByteCapacity))
      guard copied > 0 else { return 0 }
      for index in 0..<copied {
        storage[(head + storedCount + index) % storage.count] = source[offset + index]
      }
      storedCount += copied
      return copied
    }

    func checkpoint() -> Checkpoint {
      Checkpoint(readOffset: readOffset, bitBuffer: bitBuffer, bitCount: bitCount)
    }

    mutating func restore(_ checkpoint: Checkpoint) {
      readOffset = checkpoint.readOffset
      bitBuffer = checkpoint.bitBuffer
      bitCount = checkpoint.bitCount
    }

    mutating func commitConsumedBytes() {
      guard readOffset > 0 else { return }
      head = (head + readOffset) % storage.count
      storedCount -= readOffset
      readOffset = 0
    }

    mutating func readBit() throws -> UInt8 {
      if bitCount == 0 {
        bitBuffer = UInt64(try readByte())
        bitCount = 8
      }
      let result = UInt8(bitBuffer & 1)
      bitBuffer >>= 1
      bitCount -= 1
      return result
    }

    mutating func readBits(_ count: Int) throws -> UInt32 {
      guard count >= 0, count <= 24 else {
        throw RFC1950BoundedInflateError.truncatedInput
      }
      if count == 0 { return 0 }
      while bitCount < count {
        bitBuffer |= UInt64(try readByte()) << UInt64(bitCount)
        bitCount += 8
      }
      let mask = (UInt64(1) << UInt64(count)) - 1
      let result = UInt32(bitBuffer & mask)
      bitBuffer >>= UInt64(count)
      bitCount -= count
      return result
    }

    mutating func peekNineBitsIfAvailable() -> Int {
      while bitCount < 9, readOffset < storedCount {
        bitBuffer |= UInt64(readAvailableByte()) << UInt64(bitCount)
        bitCount += 8
      }
      guard bitCount >= 9 else { return -1 }
      return Int(bitBuffer & 0x01FF)
    }

    mutating func peekTenBitsIfAvailable() -> Int {
      while bitCount < 10, readOffset < storedCount {
        bitBuffer |= UInt64(readAvailableByte()) << UInt64(bitCount)
        bitCount += 8
      }
      guard bitCount >= 10 else { return -1 }
      return Int(bitBuffer & 0x03FF)
    }

    mutating func dropBits(_ count: Int) {
      precondition(count >= 0 && count <= bitCount)
      bitBuffer >>= UInt64(count)
      bitCount -= count
    }

    mutating func alignToByte() {
      let discarded = bitCount & 7
      if discarded > 0 {
        bitBuffer >>= UInt64(discarded)
        bitCount -= discarded
      }
    }

    mutating func readAlignedUInt16LE() throws -> UInt16 {
      guard bitCount.isMultiple(of: 8) else {
        throw RFC1950BoundedInflateError.truncatedInput
      }
      return UInt16(try readBits(16))
    }

    private mutating func readByte() throws -> UInt8 {
      guard readOffset < storedCount else {
        throw RFC1950BoundedInflateError.truncatedInput
      }
      return readAvailableByte()
    }

    private mutating func readAvailableByte() -> UInt8 {
      let byte = storage[(head + readOffset) % storage.count]
      readOffset += 1
      return byte
    }
  }

  private struct Decoder {
    let input: UnsafeBufferPointer<UInt8>
    let output: UnsafeMutableBufferPointer<UInt8>
    var reader: BitReader
    var outputIndex = 0
    let allowsShortOutput: Bool

    init(
      input: UnsafeBufferPointer<UInt8>,
      output: UnsafeMutableBufferPointer<UInt8>,
      allowsShortOutput: Bool
    ) {
      self.input = input
      self.output = output
      self.reader = BitReader(input: input, byteIndex: 2, byteLimit: input.count - 4)
      self.allowsShortOutput = allowsShortOutput
    }

    mutating func decode() throws -> Int {
      try validateZlibHeader()

      var isFinal = false
      while !isFinal {
        isFinal = try reader.readBits(1) == 1
        switch try reader.readBits(2) {
        case 0:
          try decodeStoredBlock()
        case 1:
          let tables = try RFC1950BoundedInflate.sharedFixedTables()
          try decodeCompressedBlock(literalLength: tables.literalLength, distance: tables.distance)
        case 2:
          let tables = try RFC1950BoundedInflate.sharedDynamicTables(reader: &reader)
          try decodeCompressedBlock(literalLength: tables.literalLength, distance: tables.distance)
        default:
          throw RFC1950BoundedInflateError.invalidBlockType
        }
      }

      reader.alignToByte()
      guard reader.bufferedBitCount == 0,
        reader.byteIndex == reader.byteLimit
      else { throw RFC1950BoundedInflateError.truncatedInput }
      guard allowsShortOutput || outputIndex == output.count else {
        throw RFC1950BoundedInflateError.outputLengthMismatch
      }
      let trailer = reader.byteLimit
      let storedAdler = UInt32(input[trailer]) << 24
        | UInt32(input[trailer + 1]) << 16
        | UInt32(input[trailer + 2]) << 8
        | UInt32(input[trailer + 3])
      guard Self.adler32(output, count: outputIndex) == storedAdler else {
        throw RFC1950BoundedInflateError.adler32Mismatch
      }
      return outputIndex
    }

    private mutating func validateZlibHeader() throws {
      guard input.count >= 6 else { throw RFC1950BoundedInflateError.invalidHeader }
      let cmf = input[0]
      let flg = input[1]
      guard cmf & 0x0F == 8,
        cmf >> 4 <= 7,
        (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0
      else { throw RFC1950BoundedInflateError.invalidHeader }
      guard flg & 0x20 == 0 else {
        throw RFC1950BoundedInflateError.presetDictionaryUnsupported
      }
    }

    private mutating func decodeStoredBlock() throws {
      reader.alignToByte()
      let length = try reader.readAlignedUInt16LE()
      let complement = try reader.readAlignedUInt16LE()
      guard length ^ complement == UInt16.max else {
        throw RFC1950BoundedInflateError.invalidStoredBlock
      }
      try reader.copyAlignedBytes(
        count: Int(length),
        to: output,
        outputIndex: &outputIndex,
        outputOverflowError: outputOverflowError
      )
    }

    private mutating func decodeCompressedBlock(
      literalLength: HuffmanTable,
      distance: HuffmanTable
    ) throws {
      let outputBase = output.baseAddress
      try literalLength.withFastLookup { literalFast in
        try distance.withFastLookup { distanceFast in
          while true {
            if literalLength.prefersFastLiteralRuns,
              let outputBase,
              reader.copyFastLiteralRun(
                fastLookupBase: literalFast,
                outputBase: outputBase,
                outputIndex: &outputIndex,
                outputLimit: output.count
              ) > 0
            {
              continue
            }
            let symbol = try literalLength.decodeSymbol(
              reader: &reader,
              fastLookupBase: literalFast
            )
            switch symbol {
            case 0...255:
              guard outputIndex < output.count, let outputBase else {
                throw outputOverflowError
              }
              outputBase[outputIndex] = UInt8(symbol)
              outputIndex += 1
            case 256:
              return
            case 257...285:
              let lengthIndex = symbol - 257
              let length = try RFC1950BoundedInflate.sharedLengthValue(
                index: lengthIndex,
                reader: &reader
              )
              let distanceSymbol = try distance.decodeSymbol(
                reader: &reader,
                fastLookupBase: distanceFast
              )
              guard distanceSymbol <= 29 else {
                throw RFC1950BoundedInflateError.invalidDistanceSymbol
              }
              let backDistance = try RFC1950BoundedInflate.sharedDistanceValue(
                symbol: distanceSymbol,
                reader: &reader
              )
              try copyMatch(length: length, distance: backDistance)
            default:
              throw RFC1950BoundedInflateError.invalidLengthSymbol
            }
          }
        }
      }
    }

    private mutating func copyMatch(length: Int, distance: Int) throws {
      guard length > 0, distance > 0, distance <= 32_768,
        distance <= outputIndex,
        outputIndex + length <= output.count
      else {
        if outputIndex + max(0, length) > output.count {
          throw outputOverflowError
        }
        throw RFC1950BoundedInflateError.invalidBackReference
      }
      guard let base = output.baseAddress else {
        throw RFC1950BoundedInflateError.outputLengthMismatch
      }
      let destination = base.advanced(by: outputIndex)
      let source = destination.advanced(by: -distance)
      if length <= 16 {
        // Short matches dominate PNG-like streams. Scalar LZ77 recurrence avoids the fixed cost of
        // many tiny libc copies and is intrinsically overlap-safe because later source bytes may be
        // bytes generated earlier in this same match.
        var offset = 0
        while offset < length {
          destination[offset] = source[offset]
          offset += 1
        }
      } else if distance >= length {
        memcpy(destination, source, length)
      } else {
        // Seed one complete LZ77 period, then repeatedly copy the already-generated prefix. This is
        // overlap-safe and preserves the byte-for-byte semantics of the scalar recurrence while
        // avoiding a Swift loop for long repeated matches.
        memcpy(destination, source, distance)
        var copied = distance
        while copied < length {
          let chunk = min(copied, length - copied)
          memcpy(destination.advanced(by: copied), destination, chunk)
          copied += chunk
        }
      }
      outputIndex += length
    }

    private var outputOverflowError: RFC1950BoundedInflateError {
      allowsShortOutput ? .outputLimitExceeded : .outputLengthMismatch
    }

    private static func adler32(
      _ bytes: UnsafeMutableBufferPointer<UInt8>,
      count: Int
    ) -> UInt32 {
      precondition(count >= 0 && count <= bytes.count)
      let maximumUnreducedBytes = RFC1950BoundedInflate.adlerNMAX
      var a = UInt64(1)
      var b = UInt64(0)
      var offset = 0
      while offset < count {
        let end = min(count, offset + maximumUnreducedBytes)
        RFC1950BoundedInflate.accumulateAdlerUnreduced(
          UnsafeBufferPointer(start: bytes.baseAddress, count: bytes.count),
          offset: &offset,
          end: end,
          a: &a,
          b: &b
        )
        a %= RFC1950BoundedInflate.adlerModulus
        b %= RFC1950BoundedInflate.adlerModulus
      }
      return UInt32((b << 16) | a)
    }
  }
}
