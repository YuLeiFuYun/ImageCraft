import Foundation
import ImageCraftImageIO

private let rfc1950InflateComparisonEvidenceVersion = "imagecraft-rfc1950-inflate-comparison-v1"

private enum RFC1950InflatePayloadProfile: String, Codable {
  case repetitiveV1 = "repetitive-v1"
  case pngScanlineV1 = "png-scanline-v1"
  case incompressibleV1 = "incompressible-v1"
}

private struct InflateImplementationEvidence: Codable {
  let implementation: String
  let samplesNanoseconds: [UInt64]
  let duration: PerformanceDurationStatistics
}

private struct RFC1950InflateComparisonReport: Codable {
  let schemaVersion: UInt16
  let evidenceVersion: String
  let runtime: ImageIORuntimeFingerprint
  let environment: PerformanceEnvironment
  let warmupIterationsPerImplementation: Int
  let iterationsPerImplementation: Int
  let alternatingOrder: Bool
  let payloadProfile: String
  let payloadByteCount: Int
  let payloadSHA256: String
  let compressedByteCount: Int
  let compressedSHA256: String
  let firstDeflateBlockType: Int
  let pureAlgorithmicWorkspaceByteChargeUpperBound: Int
  let streamingExactOutputPreflight: Bool
  let pure: InflateImplementationEvidence
  let streamingPure: InflateImplementationEvidence
  let appleCompression: InflateImplementationEvidence
  let pureToAppleMedianRatio: Double
  let streamingToPureMedianRatio: Double
  let streamingToAppleMedianRatio: Double
}

func writeRFC1950InflateComparisonEvidence(
  profileID: String,
  payloadByteCount: Int,
  iterations: Int
) throws {
  guard let profile = RFC1950InflatePayloadProfile(rawValue: profileID),
    (1_024...(16 * 1_024 * 1_024)).contains(payloadByteCount),
    (1...50).contains(iterations)
  else { throw PerformanceBenchmarkError.invalidIterations }

  let payload = makeInflateComparisonPayload(profile: profile, byteCount: payloadByteCount)
  let compressed = try RFC1950Zlib.deflate(payload)
  guard compressed.count >= 3 else { throw PerformanceBenchmarkError.unexpectedOutput }
  let firstDeflateBlockType = Int((compressed[2] >> 1) & 0x03)

  var streamingReference = Data(capacity: payload.count)
  try RFC1950BoundedInflate.inflateStreaming(
    compressed,
    expectedByteCount: payload.count
  ) { bytes in
    streamingReference.append(contentsOf: bytes)
  }
  guard streamingReference == payload else { throw PerformanceBenchmarkError.unexpectedOutput }

  func runPure() throws {
    let decoded = try RFC1950BoundedInflate.inflate(
      compressed,
      expectedByteCount: payload.count
    )
    guard decoded == payload else { throw PerformanceBenchmarkError.unexpectedOutput }
  }

  func runApple() throws {
    let decoded = try RFC1950Zlib.inflate(
      compressed,
      expectedByteCount: payload.count
    )
    guard decoded == payload else { throw PerformanceBenchmarkError.unexpectedOutput }
  }

  func runStreaming() throws {
    var consumedByteCount = 0
    try RFC1950BoundedInflate.inflateStreaming(
      compressed,
      expectedByteCount: payload.count
    ) { bytes in
      consumedByteCount += bytes.count
    }
    guard consumedByteCount == payload.count else {
      throw PerformanceBenchmarkError.unexpectedOutput
    }
  }

  let warmups = 2
  for _ in 0..<warmups {
    try autoreleasepool(invoking: runPure)
    try autoreleasepool(invoking: runStreaming)
    try autoreleasepool(invoking: runApple)
  }

  var pureSamples: [UInt64] = []
  var streamingSamples: [UInt64] = []
  var appleSamples: [UInt64] = []
  pureSamples.reserveCapacity(iterations)
  streamingSamples.reserveCapacity(iterations)
  appleSamples.reserveCapacity(iterations)
  for iteration in 0..<iterations {
    let operations: [(String, () throws -> Void)]
    switch iteration % 3 {
    case 0:
      operations = [("pure", runPure), ("streaming", runStreaming), ("apple", runApple)]
    case 1:
      operations = [("streaming", runStreaming), ("apple", runApple), ("pure", runPure)]
    default:
      operations = [("apple", runApple), ("pure", runPure), ("streaming", runStreaming)]
    }
    for (name, operation) in operations {
      let started = DispatchTime.now().uptimeNanoseconds
      try autoreleasepool(invoking: operation)
      let elapsed = DispatchTime.now().uptimeNanoseconds &- started
      if name == "pure" {
        pureSamples.append(elapsed)
      } else if name == "streaming" {
        streamingSamples.append(elapsed)
      } else {
        appleSamples.append(elapsed)
      }
    }
  }

  let pureStats = durationStatistics(pureSamples)
  let streamingStats = durationStatistics(streamingSamples)
  let appleStats = durationStatistics(appleSamples)
  let report = RFC1950InflateComparisonReport(
    schemaVersion: 1,
    evidenceVersion: rfc1950InflateComparisonEvidenceVersion,
    runtime: .capture(),
    environment: capturePerformanceEnvironment(),
    warmupIterationsPerImplementation: warmups,
    iterationsPerImplementation: iterations,
    alternatingOrder: true,
    payloadProfile: profile.rawValue,
    payloadByteCount: payload.count,
    payloadSHA256: sha256(payload),
    compressedByteCount: compressed.count,
    compressedSHA256: sha256(compressed),
    firstDeflateBlockType: firstDeflateBlockType,
    pureAlgorithmicWorkspaceByteChargeUpperBound:
      RFC1950BoundedInflate.algorithmicWorkspaceByteChargeUpperBound,
    streamingExactOutputPreflight: true,
    pure: InflateImplementationEvidence(
      implementation: "ImageCraft.RFC1950BoundedInflate",
      samplesNanoseconds: pureSamples,
      duration: pureStats
    ),
    streamingPure: InflateImplementationEvidence(
      implementation: "ImageCraft.RFC1950BoundedInflate.streaming",
      samplesNanoseconds: streamingSamples,
      duration: streamingStats
    ),
    appleCompression: InflateImplementationEvidence(
      implementation: "Apple.Compression.COMPRESSION_ZLIB",
      samplesNanoseconds: appleSamples,
      duration: appleStats
    ),
    pureToAppleMedianRatio: Double(pureStats.medianNanoseconds)
      / Double(appleStats.medianNanoseconds),
    streamingToPureMedianRatio: Double(streamingStats.medianNanoseconds)
      / Double(pureStats.medianNanoseconds),
    streamingToAppleMedianRatio: Double(streamingStats.medianNanoseconds)
      / Double(appleStats.medianNanoseconds)
  )

  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  FileHandle.standardOutput.write(try encoder.encode(report))
  FileHandle.standardOutput.write(Data([0x0A]))
}

private func makeInflateComparisonPayload(
  profile: RFC1950InflatePayloadProfile,
  byteCount: Int
) -> Data {
  var payload = Data(capacity: byteCount)
  switch profile {
  case .repetitiveV1:
    for index in 0..<byteCount {
      let withinBlock = index & 4_095
      let block = index >> 12
      payload.append(
        UInt8(
          truncatingIfNeeded:
            withinBlock &* 31
              &+ (withinBlock >> 4) &* 17
              &+ (block % 13) &* 7
        )
      )
    }
  case .pngScanlineV1:
    let rowPayloadBytes = 256 * 4
    let rowSpan = rowPayloadBytes + 1
    for index in 0..<byteCount {
      let withinRow = index % rowSpan
      if withinRow == 0 {
        payload.append(0)
        continue
      }
      let componentOffset = withinRow - 1
      let x = (componentOffset / 4) % 256
      let channel = componentOffset & 3
      let y = index / rowSpan
      switch channel {
      case 0: payload.append(UInt8(truncatingIfNeeded: x &* 3 &+ y &* 5))
      case 1: payload.append(UInt8(truncatingIfNeeded: x &* 7 &+ y &* 11))
      case 2: payload.append(UInt8(truncatingIfNeeded: x &* 13 &+ y &* 17))
      default: payload.append(UInt8(truncatingIfNeeded: 255 - ((x &+ y) & 63)))
      }
    }
  case .incompressibleV1:
    var state: UInt32 = 0xC001_D00D
    for _ in 0..<byteCount {
      state = state &* 1_664_525 &+ 1_013_904_223
      payload.append(UInt8(truncatingIfNeeded: state >> 24))
    }
  }
  return payload
}
