import Foundation
import ImageCraftImageIO

private let rfc1950FileComparisonEvidenceVersion =
  "imagecraft-rfc1950-file-comparison-v1"

private struct RFC1950FileTimingEvidence: Codable {
  let implementation: String
  let samplesNanoseconds: [UInt64]
  let duration: PerformanceDurationStatistics
}

private struct RFC1950FileComparisonReport: Codable {
  let schemaVersion: UInt16
  let evidenceVersion: String
  let runtime: ImageIORuntimeFingerprint
  let environment: PerformanceEnvironment
  let warmupIterationsPerImplementation: Int
  let iterationsPerImplementation: Int
  let rotatingOrder: Bool
  let compressedByteCount: Int
  let compressedSHA256: String
  let outputByteCount: Int
  let outputSHA256: String
  let exactOutputMatch: Bool
  let pure: RFC1950FileTimingEvidence
  let streamingPure: RFC1950FileTimingEvidence
  let appleCompression: RFC1950FileTimingEvidence
  let streamingToPureMedianRatio: Double
  let streamingToAppleMedianRatio: Double
}

func writeRFC1950FileComparisonEvidence(
  input: URL,
  expectedByteCount: Int,
  iterations: Int
) throws {
  guard expectedByteCount >= 0, (1...50).contains(iterations) else {
    throw PerformanceBenchmarkError.invalidIterations
  }
  let compressed = try Data(contentsOf: input)
  let reference = try RFC1950BoundedInflate.inflate(
    compressed,
    expectedByteCount: expectedByteCount
  )
  let appleReference = try RFC1950Zlib.inflate(
    compressed,
    expectedByteCount: expectedByteCount
  )
  guard reference == appleReference else { throw PerformanceBenchmarkError.unexpectedOutput }
  var streamingReference = Data(capacity: expectedByteCount)
  try RFC1950BoundedInflate.inflateStreaming(
    compressed,
    expectedByteCount: expectedByteCount
  ) { bytes in
    streamingReference.append(contentsOf: bytes)
  }
  guard streamingReference == reference else { throw PerformanceBenchmarkError.unexpectedOutput }

  let outputByteCount = reference.count
  let firstByte = reference.first
  let lastByte = reference.last
  func runPure() throws {
    let decoded = try RFC1950BoundedInflate.inflate(
      compressed,
      expectedByteCount: expectedByteCount
    )
    guard decoded.count == outputByteCount,
      decoded.first == firstByte,
      decoded.last == lastByte
    else { throw PerformanceBenchmarkError.unexpectedOutput }
  }
  func runStreaming() throws {
    var delivered = 0
    try RFC1950BoundedInflate.inflateStreaming(
      compressed,
      expectedByteCount: expectedByteCount
    ) { bytes in
      delivered += bytes.count
    }
    guard delivered == expectedByteCount else { throw PerformanceBenchmarkError.unexpectedOutput }
  }
  func runApple() throws {
    let decoded = try RFC1950Zlib.inflate(
      compressed,
      expectedByteCount: expectedByteCount
    )
    guard decoded.count == outputByteCount,
      decoded.first == firstByte,
      decoded.last == lastByte
    else { throw PerformanceBenchmarkError.unexpectedOutput }
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
      switch name {
      case "pure": pureSamples.append(elapsed)
      case "streaming": streamingSamples.append(elapsed)
      default: appleSamples.append(elapsed)
      }
    }
  }
  let pureStats = durationStatistics(pureSamples)
  let streamingStats = durationStatistics(streamingSamples)
  let appleStats = durationStatistics(appleSamples)
  let report = RFC1950FileComparisonReport(
    schemaVersion: 1,
    evidenceVersion: rfc1950FileComparisonEvidenceVersion,
    runtime: .capture(),
    environment: capturePerformanceEnvironment(),
    warmupIterationsPerImplementation: warmups,
    iterationsPerImplementation: iterations,
    rotatingOrder: true,
    compressedByteCount: compressed.count,
    compressedSHA256: sha256(compressed),
    outputByteCount: reference.count,
    outputSHA256: sha256(reference),
    exactOutputMatch: true,
    pure: RFC1950FileTimingEvidence(
      implementation: "ImageCraft.RFC1950BoundedInflate",
      samplesNanoseconds: pureSamples,
      duration: pureStats
    ),
    streamingPure: RFC1950FileTimingEvidence(
      implementation: "ImageCraft.RFC1950BoundedInflate.streaming",
      samplesNanoseconds: streamingSamples,
      duration: streamingStats
    ),
    appleCompression: RFC1950FileTimingEvidence(
      implementation: "Apple.Compression.COMPRESSION_ZLIB",
      samplesNanoseconds: appleSamples,
      duration: appleStats
    ),
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
