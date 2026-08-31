import Foundation

/// Package-internal research prototype for bounded APNG pre-frame state retention.
///
/// The blob stores a complete straight-alpha RGBA canvas. It is intentionally not
/// wired into `ImageIOAnimatedImageDecoder`; production integration requires an owned
/// APNG subrect decoder and device evidence.
struct APNGCompressedCheckpointPolicy: Equatable, Sendable {
  static let bounded1024 = APNGCompressedCheckpointPolicy(
    maximumCanvasDimension: 1_024,
    maximumRetainedBytes: 32 * 1_024 * 1_024,
    maximumReplayFrames: 8,
    maximumCheckpointBlobRatioPPM: 100_000
  )

  let maximumCanvasDimension: Int
  let maximumRetainedBytes: Int
  let maximumReplayFrames: Int
  let maximumCheckpointBlobRatioPPM: Int

  func validate() throws {
    guard maximumCanvasDimension > 0,
      maximumCanvasDimension <= 1_024,
      maximumRetainedBytes >= 0,
      maximumRetainedBytes <= 32 * 1_024 * 1_024,
      maximumReplayFrames > 0,
      maximumReplayFrames <= 8,
      maximumCheckpointBlobRatioPPM > 0,
      maximumCheckpointBlobRatioPPM <= 1_000_000
    else { throw APNGCompressedCheckpointError.invalidPolicy }
  }
}

enum APNGCompressedCheckpointError: Error, Equatable, Sendable {
  case invalidPolicy
  case invalidCanvas
  case rawByteCountMismatch
  case invalidBlobHeader
  case payloadByteCountMismatch
  case compressionFailed
  case decompressionFailed
  case checksumMismatch
  case checkpointRatioExceeded
  case retainedBudgetExceeded
  case invalidFrameIndex
  case frameIndicesNotIncreasing
  case replayLimitExceeded
}

struct APNGCompressedCheckpointMetadata: Equatable, Sendable {
  let width: Int
  let height: Int
  let rawByteCount: Int
  let checksum: UInt32
  let payloadByteCount: Int

  var totalBlobByteCount: Int {
    APNGCompressedCheckpointCodec.headerByteCount + payloadByteCount
  }
}

enum APNGCompressedCheckpointCodec {
  static let compressionModel = "straight-alpha-zlib-level-9-checksummed-v1"
  static let headerByteCount = 28
  static let minimumBlobByteCount = 36
  static let smallCanvasBlobAllowanceByteCount = 4 * 1_024

  private static let magic = Data("FOVAPNG1".utf8)
  static func encode(
    straightAlphaRGBA: Data,
    width: Int,
    height: Int,
    policy: APNGCompressedCheckpointPolicy = .bounded1024
  ) throws -> Data {
    try policy.validate()
    let rawByteCount = try validatedRawByteCount(
      width: width,
      height: height,
      policy: policy
    )
    guard straightAlphaRGBA.count == rawByteCount else {
      throw APNGCompressedCheckpointError.rawByteCountMismatch
    }
    let payload = try compress(straightAlphaRGBA)
    let total = headerByteCount.addingReportingOverflow(payload.count)
    guard !total.overflow else {
      throw APNGCompressedCheckpointError.compressionFailed
    }
    try validateBlobAdmission(
      blobByteCount: total.partialValue,
      rawByteCount: rawByteCount,
      policy: policy
    )
    guard let width32 = UInt32(exactly: width),
      let height32 = UInt32(exactly: height),
      let rawCount32 = UInt32(exactly: rawByteCount),
      let payloadCount32 = UInt32(exactly: payload.count)
    else { throw APNGCompressedCheckpointError.invalidCanvas }

    var result = Data()
    result.reserveCapacity(total.partialValue)
    result.append(magic)
    appendUInt32BE(width32, to: &result)
    appendUInt32BE(height32, to: &result)
    appendUInt32BE(rawCount32, to: &result)
    appendUInt32BE(ImageCraftCRC32.checksum(straightAlphaRGBA), to: &result)
    appendUInt32BE(payloadCount32, to: &result)
    result.append(payload)
    return result
  }

  static func decode(
    _ blob: Data,
    policy: APNGCompressedCheckpointPolicy = .bounded1024
  ) throws -> (metadata: APNGCompressedCheckpointMetadata, straightAlphaRGBA: Data) {
    try policy.validate()
    let metadata = try inspect(blob, policy: policy)
    let payload = blob[headerByteCount...]
    let decoded = try decompress(
      Data(payload),
      expectedByteCount: metadata.rawByteCount
    )
    guard ImageCraftCRC32.checksum(decoded) == metadata.checksum else {
      throw APNGCompressedCheckpointError.checksumMismatch
    }
    return (metadata, decoded)
  }

  static func inspect(
    _ blob: Data,
    policy: APNGCompressedCheckpointPolicy = .bounded1024
  ) throws -> APNGCompressedCheckpointMetadata {
    try policy.validate()
    guard blob.count >= headerByteCount,
      blob.prefix(magic.count) == magic,
      let widthValue = readUInt32BE(blob, at: 8),
      let heightValue = readUInt32BE(blob, at: 12),
      let rawByteCountValue = readUInt32BE(blob, at: 16),
      let checksum = readUInt32BE(blob, at: 20),
      let payloadByteCountValue = readUInt32BE(blob, at: 24),
      let width = Int(exactly: widthValue),
      let height = Int(exactly: heightValue),
      let rawByteCount = Int(exactly: rawByteCountValue),
      let payloadByteCount = Int(exactly: payloadByteCountValue)
    else { throw APNGCompressedCheckpointError.invalidBlobHeader }

    let expectedRawByteCount = try validatedRawByteCount(
      width: width,
      height: height,
      policy: policy
    )
    guard rawByteCount == expectedRawByteCount else {
      throw APNGCompressedCheckpointError.invalidBlobHeader
    }
    let total = headerByteCount.addingReportingOverflow(payloadByteCount)
    guard !total.overflow, total.partialValue == blob.count else {
      throw APNGCompressedCheckpointError.payloadByteCountMismatch
    }
    try validateBlobAdmission(
      blobByteCount: blob.count,
      rawByteCount: rawByteCount,
      policy: policy
    )
    return APNGCompressedCheckpointMetadata(
      width: width,
      height: height,
      rawByteCount: rawByteCount,
      checksum: checksum,
      payloadByteCount: payloadByteCount
    )
  }

  private static func validateBlobAdmission(
    blobByteCount: Int,
    rawByteCount: Int,
    policy: APNGCompressedCheckpointPolicy
  ) throws {
    guard blobByteCount > 0, rawByteCount > 0 else {
      throw APNGCompressedCheckpointError.rawByteCountMismatch
    }
    let scaled = rawByteCount.multipliedReportingOverflow(
      by: policy.maximumCheckpointBlobRatioPPM
    )
    guard !scaled.overflow else {
      throw APNGCompressedCheckpointError.checkpointRatioExceeded
    }
    let adjusted = scaled.partialValue.addingReportingOverflow(999_999)
    guard !adjusted.overflow else {
      throw APNGCompressedCheckpointError.checkpointRatioExceeded
    }
    let proportionalLimit = adjusted.partialValue / 1_000_000
    let allowed = max(smallCanvasBlobAllowanceByteCount, proportionalLimit)
    guard blobByteCount <= allowed else {
      throw APNGCompressedCheckpointError.checkpointRatioExceeded
    }
  }

  static func checkpointRatioPPM(
    blobByteCount: Int,
    rawByteCount: Int
  ) throws -> Int {
    guard blobByteCount > 0, rawByteCount > 0 else {
      throw APNGCompressedCheckpointError.rawByteCountMismatch
    }
    let scaled = blobByteCount.multipliedReportingOverflow(by: 1_000_000)
    guard !scaled.overflow else {
      throw APNGCompressedCheckpointError.checkpointRatioExceeded
    }
    let adjusted = scaled.partialValue.addingReportingOverflow(rawByteCount - 1)
    guard !adjusted.overflow else {
      throw APNGCompressedCheckpointError.checkpointRatioExceeded
    }
    return adjusted.partialValue / rawByteCount
  }

  private static func validatedRawByteCount(
    width: Int,
    height: Int,
    policy: APNGCompressedCheckpointPolicy
  ) throws -> Int {
    guard width > 0, height > 0,
      width <= policy.maximumCanvasDimension,
      height <= policy.maximumCanvasDimension
    else { throw APNGCompressedCheckpointError.invalidCanvas }
    let pixels = width.multipliedReportingOverflow(by: height)
    guard !pixels.overflow else { throw APNGCompressedCheckpointError.invalidCanvas }
    let bytes = pixels.partialValue.multipliedReportingOverflow(by: 4)
    guard !bytes.overflow else { throw APNGCompressedCheckpointError.invalidCanvas }
    return bytes.partialValue
  }

  private static func compress(_ source: Data) throws -> Data {
    do {
      return try RFC1950Zlib.deflate(source)
    } catch {
      throw APNGCompressedCheckpointError.compressionFailed
    }
  }

  private static func decompress(
    _ source: Data,
    expectedByteCount: Int
  ) throws -> Data {
    do {
      return try RFC1950BoundedInflate.inflate(
        source,
        expectedByteCount: expectedByteCount
      )
    } catch {
      throw APNGCompressedCheckpointError.decompressionFailed
    }
  }

  private static func appendUInt32BE(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
  }

  private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= data.count else { return nil }
    return UInt32(data[offset]) << 24
      | UInt32(data[offset + 1]) << 16
      | UInt32(data[offset + 2]) << 8
      | UInt32(data[offset + 3])
  }

}

struct APNGCompressedCheckpointResolution: Equatable, Sendable {
  let checkpointFrameIndex: Int
  let replayFrameCount: Int
  let compressedBlob: Data?
}

struct APNGCompressedCheckpointStore: Sendable {
  private struct Entry: Sendable {
    let frameIndex: Int
    let blob: Data
  }

  let frameCount: Int
  let width: Int
  let height: Int
  let policy: APNGCompressedCheckpointPolicy

  private(set) var retainedBytes = 0
  private var entries: [Entry] = []

  init(
    frameCount: Int,
    width: Int,
    height: Int,
    policy: APNGCompressedCheckpointPolicy = .bounded1024
  ) throws {
    try policy.validate()
    guard frameCount > 0 else {
      throw APNGCompressedCheckpointError.invalidFrameIndex
    }
    guard width > 0, height > 0,
      width <= policy.maximumCanvasDimension,
      height <= policy.maximumCanvasDimension
    else { throw APNGCompressedCheckpointError.invalidCanvas }
    let pixels = width.multipliedReportingOverflow(by: height)
    guard !pixels.overflow else {
      throw APNGCompressedCheckpointError.invalidCanvas
    }
    let bytes = pixels.partialValue.multipliedReportingOverflow(by: 4)
    guard !bytes.overflow else {
      throw APNGCompressedCheckpointError.invalidCanvas
    }
    self.frameCount = frameCount
    self.width = width
    self.height = height
    self.policy = policy
  }

  var retainedCheckpointCount: Int { entries.count }

  mutating func insert(
    preFrameStraightAlphaRGBA: Data,
    at frameIndex: Int
  ) throws {
    guard frameIndex > 0, frameIndex < frameCount else {
      throw APNGCompressedCheckpointError.invalidFrameIndex
    }
    if let last = entries.last, frameIndex <= last.frameIndex {
      throw APNGCompressedCheckpointError.frameIndicesNotIncreasing
    }
    let blob = try APNGCompressedCheckpointCodec.encode(
      straightAlphaRGBA: preFrameStraightAlphaRGBA,
      width: width,
      height: height,
      policy: policy
    )
    let next = retainedBytes.addingReportingOverflow(blob.count)
    guard !next.overflow, next.partialValue <= policy.maximumRetainedBytes else {
      throw APNGCompressedCheckpointError.retainedBudgetExceeded
    }
    entries.append(Entry(frameIndex: frameIndex, blob: blob))
    retainedBytes = next.partialValue
  }

  func resolve(
    targetFrameIndex: Int,
    semanticReplayStart: Int = 0
  ) throws -> APNGCompressedCheckpointResolution {
    guard targetFrameIndex >= 0, targetFrameIndex < frameCount,
      semanticReplayStart >= 0, semanticReplayStart <= targetFrameIndex
    else {
      throw APNGCompressedCheckpointError.invalidFrameIndex
    }
    let entry = entries.last { $0.frameIndex <= targetFrameIndex }
    let checkpointFrameIndex = entry?.frameIndex ?? 0
    let useSemanticStart = semanticReplayStart > checkpointFrameIndex
    let replayStartFrameIndex = useSemanticStart ? semanticReplayStart : checkpointFrameIndex
    let replayFrameCount = targetFrameIndex - replayStartFrameIndex + 1
    guard replayFrameCount <= policy.maximumReplayFrames else {
      throw APNGCompressedCheckpointError.replayLimitExceeded
    }
    return APNGCompressedCheckpointResolution(
      checkpointFrameIndex: replayStartFrameIndex,
      replayFrameCount: replayFrameCount,
      compressedBlob: useSemanticStart ? nil : entry?.blob
    )
  }

  func decode(_ resolution: APNGCompressedCheckpointResolution) throws -> Data? {
    guard let blob = resolution.compressedBlob else { return nil }
    let decoded = try APNGCompressedCheckpointCodec.decode(blob, policy: policy)
    guard decoded.metadata.width == width, decoded.metadata.height == height else {
      throw APNGCompressedCheckpointError.invalidBlobHeader
    }
    return decoded.straightAlphaRGBA
  }
}

package struct APNGCompressedCheckpointInteropResult: Sendable {
  package let width: Int
  package let height: Int
  package let straightAlphaRGBA: Data

}

/// Package-only compatibility seam used by the evidence executable.
package enum APNGCompressedCheckpointInterop {
  package static func encode(
    straightAlphaRGBA: Data,
    width: Int,
    height: Int
  ) throws -> Data {
    try APNGCompressedCheckpointCodec.encode(
      straightAlphaRGBA: straightAlphaRGBA,
      width: width,
      height: height,
      policy: interoperabilityPolicy
    )
  }

  package static func decode(_ blob: Data) throws -> APNGCompressedCheckpointInteropResult {
    let value = try APNGCompressedCheckpointCodec.decode(
      blob,
      policy: interoperabilityPolicy
    )
    return APNGCompressedCheckpointInteropResult(
      width: value.metadata.width,
      height: value.metadata.height,
      straightAlphaRGBA: value.straightAlphaRGBA
    )
  }

  private static let interoperabilityPolicy = APNGCompressedCheckpointPolicy(
    maximumCanvasDimension: 1_024,
    maximumRetainedBytes: 32 * 1_024 * 1_024,
    maximumReplayFrames: 8,
    maximumCheckpointBlobRatioPPM: 1_000_000
  )
}
