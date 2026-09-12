import Foundation
import ImageCraftCore

public enum MJPEGMultipartFramingError: Error, Equatable, Sendable {
  case invalidContentType
  case invalidBoundary
  case malformedMultipart
  case unsupportedPartSemantics
  case headerByteLimitExceeded
  case frameByteLimitExceeded
  case frameCountExceeded
  case sessionFinished
  case sessionFailed
}

/// Strict public parser for the outer HTTP `Content-Type` value used by the opt-in MJPEG framer.
///
/// The qualified boundary vocabulary deliberately excludes whitespace and escaped quoted-string
/// forms. Quoting an otherwise valid token is accepted, but the decoded boundary itself must fit
/// the same 1...70 ASCII token domain used by the incremental body parser.
public enum MJPEGMultipartContentType {
  public static func boundary(from rawValue: String) throws -> String {
    let fields = try splitParameters(rawValue)
    guard let mediaType = fields.first?.trimmingCharacters(in: .whitespacesAndNewlines),
      mediaType.lowercased() == "multipart/x-mixed-replace"
    else { throw MJPEGMultipartFramingError.invalidContentType }

    var boundary: String?
    for field in fields.dropFirst() {
      let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, let equals = trimmed.firstIndex(of: "=") else {
        throw MJPEGMultipartFramingError.invalidContentType
      }
      let name = trimmed[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
      var value = trimmed[trimmed.index(after: equals)...]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if value.first == "\"" || value.last == "\"" {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else {
          throw MJPEGMultipartFramingError.invalidContentType
        }
        value.removeFirst()
        value.removeLast()
        guard !value.contains("\\"), !value.contains("\"") else {
          throw MJPEGMultipartFramingError.invalidContentType
        }
      }
      if name.lowercased() == "boundary" {
        guard boundary == nil else { throw MJPEGMultipartFramingError.invalidContentType }
        boundary = String(value)
      }
    }
    guard let boundary else { throw MJPEGMultipartFramingError.invalidContentType }
    try MJPEGMultipartFramingParser.validateBoundary(boundary)
    return boundary
  }

  private static func splitParameters(_ rawValue: String) throws -> [String] {
    var result: [String] = []
    var current = ""
    var quoted = false
    for character in rawValue {
      if character == "\"" { quoted.toggle() }
      if character == ";", !quoted {
        result.append(current)
        current.removeAll(keepingCapacity: true)
      } else {
        current.append(character)
      }
    }
    guard !quoted else { throw MJPEGMultipartFramingError.invalidContentType }
    result.append(current)
    return result
  }
}

/// Public logical-retention state for the transport-agnostic MJPEG multipart framer.
///
/// Byte counts describe payload bytes logically retained by the framing algorithm. They are not
/// Swift allocator capacity, object-header cost, process RSS, JPEG decode memory, or HTTP buffering.
public struct MJPEGMultipartFramingState: Hashable, Sendable {
  public let emittedFrameCount: Int
  public let currentLogicalRetainedBytes: Int
  public let maximumObservedLogicalRetainedBytes: Int
  public let isClosed: Bool
  public let isTerminal: Bool

  fileprivate init(_ snapshot: MJPEGMultipartFramingSnapshot) {
    self.emittedFrameCount = snapshot.emittedFrameCount
    self.currentLogicalRetainedBytes = snapshot.logicalRetainedBytes
    self.maximumObservedLogicalRetainedBytes = snapshot.maximumObservedLogicalRetainedBytes
    self.isClosed = snapshot.isClosed
    self.isTerminal = snapshot.isTerminal
  }
}

/// Opt-in, transport-agnostic incremental framer for MJPEG `multipart/x-mixed-replace` bodies.
///
/// This type does not perform HTTP transfer decoding, networking, retry/reconnect, JPEG pixel
/// decoding, caching, or playback scheduling. Caller chunks remain caller-owned. Each complete JPEG
/// part is transferred synchronously to `onFrame`; callers may retain that `Data` after the callback
/// returns, while the framer releases its own reference before accepting the next part.
///
/// `maximumLogicalMutablePayloadRetainedByteBound` is a framing-payload bound only. It deliberately
/// does not claim a hard allocator/RSS bound for Foundation `Data`/`Array` storage.
public struct MJPEGMultipartFramer: Sendable {
  public let maximumLogicalMutablePayloadRetainedByteBound: Int
  private var parser: MJPEGMultipartFramingParser

  public init(
    contentType: String,
    maximumHeaderBytes: Int = 8 * 1_024,
    maximumFrameBytes: Int,
    maximumFrameCount: Int
  ) throws {
    let boundary = try MJPEGMultipartContentType.boundary(from: contentType)
    let parser = try MJPEGMultipartFramingParser(
      boundary: boundary,
      maximumHeaderBytes: maximumHeaderBytes,
      maximumFrameBytes: maximumFrameBytes,
      maximumFrameCount: maximumFrameCount
    )
    self.maximumLogicalMutablePayloadRetainedByteBound =
      parser.maximumMutablePayloadRetainedByteBound
    self.parser = parser
  }

  public var state: MJPEGMultipartFramingState {
    MJPEGMultipartFramingState(parser.snapshot)
  }

  public mutating func append(
    _ chunk: Data,
    onFrame: (Data) throws -> Void
  ) throws {
    try parser.append(chunk, onFrame: onFrame)
  }

  public mutating func finish() throws {
    try parser.finish()
  }
}

package struct MJPEGMultipartFramingSnapshot: Equatable, Sendable {
  package let emittedFrameCount: Int
  package let retainedFrameBytes: Int
  package let retainedHeaderBytes: Int
  package let retainedDelimiterCandidateBytes: Int
  package let logicalRetainedBytes: Int
  package let maximumObservedLogicalRetainedBytes: Int
  package let isClosed: Bool
  package let isTerminal: Bool
}

/// Incremental, bounded MJPEG multipart body framer.
///
/// This type owns framing bytes only. It neither performs HTTP transfer decoding nor decodes JPEG
/// pixels. A frame is published only after its following multipart delimiter and delimiter suffix
/// are validated, so malformed framing cannot publish a final body early. Current-frame bytes are
/// retained up to `maximumFrameBytes`; header bytes and delimiter lookbehind have independent hard
/// bounds. Caller-owned append chunks are consumed byte-wise and never copied wholesale into a
/// parser transport buffer.
package struct MJPEGMultipartFramingParser: Sendable {
  private enum Phase: Sendable {
    case initialBoundary(Int)
    case headers
    case body
    case fixedLengthDelimiter(Int)
    case boundarySuffixFirst
    case boundarySuffixSecond(UInt8)
    case closingCR
    case closingLF
    case closed
  }

  private let maximumHeaderBytes: Int
  private let maximumFrameBytes: Int
  private let maximumFrameCount: Int
  private let initialBoundary: [UInt8]
  private let bodyDelimiter: [UInt8]
  package let maximumMutablePayloadRetainedByteBound: Int

  private var phase: Phase = .initialBoundary(0)
  private var headerBytes: [UInt8] = []
  private var framePayload = Data()
  private var delimiterCandidate: [UInt8] = []
  private var expectedContentLength: Int?
  private var emittedFrameCount = 0
  private var maximumObservedLogicalRetainedBytes = 0
  private var failed = false
  private var finished = false

  package init(
    boundary: String,
    maximumHeaderBytes: Int = 8 * 1_024,
    maximumFrameBytes: Int,
    maximumFrameCount: Int
  ) throws {
    try Self.validateBoundary(boundary)
    guard maximumHeaderBytes > 0, maximumFrameBytes > 0, maximumFrameCount > 0 else {
      throw ImageCodecContractError.invalidResourceEstimate
    }
    self.maximumHeaderBytes = maximumHeaderBytes
    self.maximumFrameBytes = maximumFrameBytes
    self.maximumFrameCount = maximumFrameCount
    let token = Array(boundary.utf8)
    self.initialBoundary = Array("--".utf8) + token + [13, 10]
    self.bodyDelimiter = [13, 10] + Array("--".utf8) + token
    // Boundary-delimited bodies retain at most one complete delimiter candidate plus the first
    // suffix byte while deciding whether an exact token is really a delimiter or payload.
    let bodyBound = maximumFrameBytes.addingReportingOverflow(
      self.bodyDelimiter.count + 1
    )
    guard !bodyBound.overflow else {
      throw ImageCodecContractError.invalidResourceEstimate
    }
    self.maximumMutablePayloadRetainedByteBound = max(
      maximumHeaderBytes,
      bodyBound.partialValue
    )
    self.headerBytes.reserveCapacity(min(maximumHeaderBytes, 1_024))
    self.delimiterCandidate.reserveCapacity(self.bodyDelimiter.count)
    observeLogicalRetainedBytes()
  }

  package var snapshot: MJPEGMultipartFramingSnapshot {
    MJPEGMultipartFramingSnapshot(
      emittedFrameCount: emittedFrameCount,
      retainedFrameBytes: framePayload.count,
      retainedHeaderBytes: headerBytes.count,
      retainedDelimiterCandidateBytes: delimiterCandidate.count + retainedBoundarySuffixByteCount,
      logicalRetainedBytes: logicalRetainedByteCount,
      maximumObservedLogicalRetainedBytes: maximumObservedLogicalRetainedBytes,
      isClosed: {
        if case .closed = phase { return true }
        return false
      }(),
      isTerminal: failed || finished
    )
  }

  package mutating func append(
    _ chunk: Data,
    onFrame: (Data) throws -> Void
  ) throws {
    guard !finished else { throw MJPEGMultipartFramingError.sessionFinished }
    guard !failed else { throw MJPEGMultipartFramingError.sessionFailed }
    if chunk.isEmpty { return }
    do {
      for byte in chunk {
        try consume(byte, onFrame: onFrame)
        observeLogicalRetainedBytes()
      }
    } catch {
      terminalizeFailure()
      throw error
    }
  }

  package mutating func finish() throws {
    guard !finished else { throw MJPEGMultipartFramingError.sessionFinished }
    guard !failed else { throw MJPEGMultipartFramingError.sessionFailed }
    guard case .closed = phase else {
      terminalizeFailure()
      throw MJPEGMultipartFramingError.malformedMultipart
    }
    finished = true
    clearRetainedPayloads()
  }

  fileprivate static func validateBoundary(_ boundary: String) throws {
    let bytes = Array(boundary.utf8)
    guard (1...70).contains(bytes.count), bytes.count == boundary.unicodeScalars.count else {
      throw MJPEGMultipartFramingError.invalidBoundary
    }
    let punctuation = Set(Array("'()+_,-./:=?".utf8))
    guard bytes.allSatisfy({ byte in
      (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        || punctuation.contains(byte)
    }) else { throw MJPEGMultipartFramingError.invalidBoundary }
  }

  private var logicalRetainedByteCount: Int {
    headerBytes.count + framePayload.count + delimiterCandidate.count
      + retainedBoundarySuffixByteCount
  }

  private var retainedBoundarySuffixByteCount: Int {
    if case .boundarySuffixSecond = phase { return 1 }
    return 0
  }

  private mutating func observeLogicalRetainedBytes() {
    maximumObservedLogicalRetainedBytes = max(
      maximumObservedLogicalRetainedBytes,
      logicalRetainedByteCount
    )
  }

  private mutating func consume(
    _ byte: UInt8,
    onFrame: (Data) throws -> Void
  ) throws {
    switch phase {
    case .initialBoundary(let index):
      guard index < initialBoundary.count, byte == initialBoundary[index] else {
        throw MJPEGMultipartFramingError.malformedMultipart
      }
      phase = index + 1 == initialBoundary.count ? .headers : .initialBoundary(index + 1)

    case .headers:
      if emittedFrameCount >= maximumFrameCount {
        throw MJPEGMultipartFramingError.frameCountExceeded
      }
      headerBytes.append(byte)
      guard headerBytes.count <= maximumHeaderBytes else {
        throw MJPEGMultipartFramingError.headerByteLimitExceeded
      }
      if headerBytes.count >= 4,
        headerBytes.suffix(4).elementsEqual([13, 10, 13, 10])
      {
        try parseHeaders(Array(headerBytes.dropLast(4)))
        headerBytes.removeAll(keepingCapacity: true)
        phase = .body
      }

    case .body:
      if let expectedContentLength {
        guard framePayload.count < expectedContentLength else {
          throw MJPEGMultipartFramingError.malformedMultipart
        }
        try appendFrameByte(byte)
        if framePayload.count == expectedContentLength {
          phase = .fixedLengthDelimiter(0)
        }
      } else {
        try consumeBoundaryDelimitedBodyByte(byte)
      }

    case .fixedLengthDelimiter(let index):
      guard index < bodyDelimiter.count, byte == bodyDelimiter[index] else {
        throw MJPEGMultipartFramingError.malformedMultipart
      }
      phase = index + 1 == bodyDelimiter.count
        ? .boundarySuffixFirst
        : .fixedLengthDelimiter(index + 1)

    case .boundarySuffixFirst:
      guard byte == 13 || byte == 45 else {
        try recoverFalseBodyDelimiter(suffixBytes: [byte], onFrame: onFrame)
        return
      }
      phase = .boundarySuffixSecond(byte)

    case .boundarySuffixSecond(let first):
      if first == 13 {
        guard byte == 10 else {
          try recoverFalseBodyDelimiter(suffixBytes: [first, byte], onFrame: onFrame)
          return
        }
        delimiterCandidate.removeAll(keepingCapacity: true)
        try emitPendingFrame(onFrame: onFrame)
        phase = .headers
      } else {
        guard first == 45, byte == 45 else {
          try recoverFalseBodyDelimiter(suffixBytes: [first, byte], onFrame: onFrame)
          return
        }
        delimiterCandidate.removeAll(keepingCapacity: true)
        phase = .closingCR
      }

    case .closingCR:
      guard byte == 13 else { throw MJPEGMultipartFramingError.malformedMultipart }
      phase = .closingLF

    case .closingLF:
      guard byte == 10 else { throw MJPEGMultipartFramingError.malformedMultipart }
      try emitPendingFrame(onFrame: onFrame)
      phase = .closed

    case .closed:
      throw MJPEGMultipartFramingError.malformedMultipart
    }
  }

  private mutating func consumeBoundaryDelimitedBodyByte(_ byte: UInt8) throws {
    delimiterCandidate.append(byte)
    while !bodyDelimiter.starts(with: delimiterCandidate) {
      guard !delimiterCandidate.isEmpty else {
        throw MJPEGMultipartFramingError.malformedMultipart
      }
      let payloadByte = delimiterCandidate.removeFirst()
      try appendFrameByte(payloadByte)
    }
    if delimiterCandidate.count == bodyDelimiter.count {
      phase = .boundarySuffixFirst
    }
  }

  /// An exact boundary token is not a delimiter until its suffix is validated. When the suffix
  /// fails, commit one byte of the candidate to payload and replay the remaining bytes through the
  /// same matcher. Committing one byte guarantees progress while replay preserves overlapping
  /// `CRLF--boundary` prefixes that can begin inside the rejected candidate/suffix sequence.
  private mutating func recoverFalseBodyDelimiter(
    suffixBytes: [UInt8],
    onFrame: (Data) throws -> Void
  ) throws {
    guard delimiterCandidate == bodyDelimiter, let first = delimiterCandidate.first else {
      throw MJPEGMultipartFramingError.malformedMultipart
    }
    let replay = Array(delimiterCandidate.dropFirst()) + suffixBytes
    delimiterCandidate.removeAll(keepingCapacity: true)
    phase = .body
    try appendFrameByte(first)
    observeLogicalRetainedBytes()
    for byte in replay {
      try consume(byte, onFrame: onFrame)
      observeLogicalRetainedBytes()
    }
  }

  private mutating func appendFrameByte(_ byte: UInt8) throws {
    guard framePayload.count < maximumFrameBytes else {
      throw MJPEGMultipartFramingError.frameByteLimitExceeded
    }
    framePayload.append(byte)
  }

  private mutating func parseHeaders(_ bytes: [UInt8]) throws {
    var offset = 0
    while offset < bytes.count {
      let byte = bytes[offset]
      if byte == 13 {
        guard offset + 1 < bytes.count, bytes[offset + 1] == 10 else {
          throw MJPEGMultipartFramingError.malformedMultipart
        }
        offset += 2
        continue
      }
      guard byte != 10, byte == 9 || (32...126).contains(byte) else {
        throw MJPEGMultipartFramingError.malformedMultipart
      }
      offset += 1
    }
    guard let text = String(bytes: bytes, encoding: .ascii) else {
      throw MJPEGMultipartFramingError.malformedMultipart
    }
    var contentType: String?
    var contentLength: Int?
    for line in text.components(separatedBy: "\r\n") {
      guard !line.isEmpty, let colon = line.firstIndex(of: ":") else {
        throw MJPEGMultipartFramingError.malformedMultipart
      }
      let name = String(line[..<colon])
      guard Self.isHeaderName(name) else {
        throw MJPEGMultipartFramingError.malformedMultipart
      }
      let value = line[line.index(after: colon)...]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      switch name.lowercased() {
      case "content-type":
        guard contentType == nil, value.lowercased() == "image/jpeg" else {
          throw MJPEGMultipartFramingError.unsupportedPartSemantics
        }
        contentType = value
      case "content-length":
        guard contentLength == nil, !value.isEmpty,
          value.allSatisfy({ $0.isASCII && $0.isNumber }),
          let parsed = Int(value), parsed > 0
        else { throw MJPEGMultipartFramingError.malformedMultipart }
        guard parsed <= maximumFrameBytes else {
          throw MJPEGMultipartFramingError.frameByteLimitExceeded
        }
        contentLength = parsed
      case let header where header.hasPrefix("x-"):
        continue
      default:
        throw MJPEGMultipartFramingError.unsupportedPartSemantics
      }
    }
    guard contentType != nil else {
      throw MJPEGMultipartFramingError.unsupportedPartSemantics
    }
    expectedContentLength = contentLength
    framePayload.removeAll(keepingCapacity: true)
    delimiterCandidate.removeAll(keepingCapacity: true)
  }

  private static func isHeaderName(_ value: String) -> Bool {
    guard !value.isEmpty else { return false }
    let punctuation = Set(Array("!#$%&'*+-.^_`|~".utf8))
    return value.utf8.allSatisfy { byte in
      (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        || punctuation.contains(byte)
    }
  }

  private mutating func emitPendingFrame(onFrame: (Data) throws -> Void) throws {
    guard emittedFrameCount < maximumFrameCount else {
      throw MJPEGMultipartFramingError.frameCountExceeded
    }
    guard framePayload.count >= 4,
      framePayload[framePayload.startIndex] == 0xFF,
      framePayload[framePayload.startIndex + 1] == 0xD8,
      framePayload[framePayload.endIndex - 2] == 0xFF,
      framePayload[framePayload.endIndex - 1] == 0xD9
    else { throw MJPEGMultipartFramingError.unsupportedPartSemantics }
    if let expectedContentLength, expectedContentLength != framePayload.count {
      throw MJPEGMultipartFramingError.malformedMultipart
    }
    try onFrame(framePayload)
    emittedFrameCount += 1
    framePayload = Data()
    expectedContentLength = nil
    delimiterCandidate.removeAll(keepingCapacity: true)
  }

  private mutating func terminalizeFailure() {
    failed = true
    clearRetainedPayloads()
  }

  private mutating func clearRetainedPayloads() {
    headerBytes.removeAll(keepingCapacity: false)
    framePayload = Data()
    delimiterCandidate.removeAll(keepingCapacity: false)
    expectedContentLength = nil
  }
}
