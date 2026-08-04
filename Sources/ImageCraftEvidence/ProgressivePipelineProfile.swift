import Foundation
import ImageCraftCore
import ImageCraftImageIO

private let progressivePipelineProfileVersion = "imagecraft-progressive-pipeline-profile-v1"

private enum ProgressivePipelineProfileError: Error {
  case invalidArguments
  case invalidManifest
  case invalidVariant
  case unsafePath
  case unexpectedOutput
}

private struct ProgressivePipelineManifest: Decodable {
  let corpusVersion: String
  let sources: [ProgressivePipelineSource]
  let variants: [ProgressivePipelineVariant]
}

private struct ProgressivePipelineSource: Decodable {
  let id: String
  let description: String
  let contentClass: String
  let width: Int
  let height: Int
}

private struct ProgressivePipelineVariant: Decodable {
  let id: String
  let sourceID: String
  let scanScriptID: String
  let file: String
  let width: Int
  let height: Int
  let byteCount: Int
  let sha256: String
}

private struct ProgressivePipelineChunkSample: Codable, Equatable, Sendable {
  let chunkIndex: Int
  let chunkByteCount: Int
  let cumulativeByteCount: Int
  let appendDurationNanoseconds: UInt64
  let generation: UInt32?
  let generationSourceByteCount: Int?
  let mainActorHandoffNanoseconds: UInt64?
}

private struct ProgressivePipelineIteration: Codable, Equatable, Sendable {
  let chunks: [ProgressivePipelineChunkSample]
  let finishDurationNanoseconds: UInt64
  let finalDecodeDurationNanoseconds: UInt64
  let finalMainActorHandoffNanoseconds: UInt64
  let finalAnalysisHashDurationNanoseconds: UInt64
  let finalPixelRGBSHA256: String
  let finalPixelWidth: Int
  let finalPixelHeight: Int
  let totalDurationNanoseconds: UInt64
}

private struct ProgressivePipelineChunkSummary: Codable, Equatable {
  let chunkIndex: Int
  let chunkByteCount: Int
  let cumulativeByteCount: Int
  let generation: UInt32?
  let generationSourceByteCount: Int?
  let appendDuration: PerformanceDurationStatistics
  let mainActorHandoff: PerformanceDurationStatistics?
}

private struct ProgressivePipelineProfileSummary: Codable, Equatable {
  let generationCount: Int
  let generationSequence: [UInt32]
  let generationSourceByteCounts: [Int]
  let chunks: [ProgressivePipelineChunkSummary]
  let finishDuration: PerformanceDurationStatistics
  let finalDecodeDuration: PerformanceDurationStatistics
  let finalMainActorHandoff: PerformanceDurationStatistics
  let finalAnalysisHashDuration: PerformanceDurationStatistics
  let totalDuration: PerformanceDurationStatistics
}

private struct ProgressivePipelineProfileReport: Codable {
  let schemaVersion: UInt16
  let profileVersion: String
  let runtime: ImageIORuntimeFingerprint
  let decoderFingerprint: String
  let environment: PerformanceEnvironment
  let buildConfiguration: String
  let manifestSHA256: String
  let corpusVersion: String
  let caseID: String
  let sourceID: String
  let sourceDescription: String
  let contentClass: String
  let scanScriptID: String
  let encodedByteCount: Int
  let encodedSHA256: String
  let chunkSizeBytes: Int
  let chunkCount: Int
  let targetWidth: Int
  let targetHeight: Int
  let warmupIterations: Int
  let iterations: Int
  let handoffBoundary: String
  let samples: [ProgressivePipelineIteration]
  let summary: ProgressivePipelineProfileSummary
}

func writeProgressivePipelineProfile(
  manifestURL: URL,
  variantID: String,
  chunkSize: Int,
  iterations: Int,
) async throws {
  guard (1 ... 1_048_576).contains(chunkSize), (1 ... 20).contains(iterations) else {
    throw ProgressivePipelineProfileError.invalidArguments
  }

  let manifestData = try Data(contentsOf: manifestURL)
  let manifest = try JSONDecoder().decode(
    ProgressivePipelineManifest.self,
    from: manifestData,
  )
  guard manifest.corpusVersion == "progressive-real-photo-v1",
        let variant = manifest.variants.first(where: { $0.id == variantID }),
        let source = manifest.sources.first(where: { $0.id == variant.sourceID }),
        source.width == variant.width,
        source.height == variant.height
  else {
    throw ProgressivePipelineProfileError.invalidManifest
  }

  let root = manifestURL.deletingLastPathComponent().standardizedFileURL
  let encodedURL = root.appendingPathComponent(variant.file).standardizedFileURL
  guard encodedURL.path == root.path || encodedURL.path.hasPrefix(root.path + "/") else {
    throw ProgressivePipelineProfileError.unsafePath
  }
  let encoded = try Data(contentsOf: encodedURL)
  guard encoded.count == variant.byteCount, sha256(encoded) == variant.sha256 else {
    throw ProgressivePipelineProfileError.invalidVariant
  }

  let warmupIterations = 1
  for _ in 0 ..< warmupIterations {
    _ = try await Task.detached {
      try await executeProgressivePipelineProfileIteration(
        encoded: encoded,
        chunkSize: chunkSize,
      )
    }.value
  }

  var samples: [ProgressivePipelineIteration] = []
  samples.reserveCapacity(iterations)
  for _ in 0 ..< iterations {
    try await samples.append(
      Task.detached {
        try await executeProgressivePipelineProfileIteration(
          encoded: encoded,
          chunkSize: chunkSize,
        )
      }.value,
    )
  }
  let summary = try summarizeProgressivePipelineProfile(samples)

  let decoder = ImageIOImageDecoder()
  let report = ProgressivePipelineProfileReport(
    schemaVersion: 1,
    profileVersion: progressivePipelineProfileVersion,
    runtime: .capture(),
    decoderFingerprint: decoder.codecDescriptor.cacheFingerprint,
    environment: capturePerformanceEnvironment(),
    buildConfiguration: "release",
    manifestSHA256: sha256(manifestData),
    corpusVersion: manifest.corpusVersion,
    caseID: "\(variant.id)--chunk-\(chunkSize)",
    sourceID: source.id,
    sourceDescription: source.description,
    contentClass: source.contentClass,
    scanScriptID: variant.scanScriptID,
    encodedByteCount: encoded.count,
    encodedSHA256: variant.sha256,
    chunkSizeBytes: chunkSize,
    chunkCount: samples[0].chunks.count,
    targetWidth: 512,
    targetHeight: 512,
    warmupIterations: warmupIterations,
    iterations: iterations,
    handoffBoundary: "detached orchestration to MainActor.run; not Core Animation or GPU presentation",
    samples: samples,
    summary: summary,
  )

  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  try FileHandle.standardOutput.write(encoder.encode(report))
  FileHandle.standardOutput.write(Data([0x0A]))
}

private func executeProgressivePipelineProfileIteration(
  encoded: Data,
  chunkSize: Int,
) async throws -> ProgressivePipelineIteration {
  let started = DispatchTime.now().uptimeNanoseconds
  let decoder = ImageIOImageDecoder()
  let limits = DecodeLimits(
    maximumEncodedBytes: max(encoded.count, 1),
    maximumDimension: 16384,
    maximumPixelCount: 100_000_000,
    maximumFrameCount: 1,
    maximumMetadataBytes: 4 * 1024 * 1024,
    maximumAuxiliaryAttachments: 0,
    allowedFormats: [.jpeg],
  )
  let request = try ImageDecodeRequest(
    target: TargetPixels(width: 512, height: 512),
    contentMode: .fit,
    colorPolicy: .preserveSource,
  )
  let session = try decoder.makeProgressiveSession(
    format: .jpeg,
    request: request,
    limits: limits,
  )

  var chunkSamples: [ProgressivePipelineChunkSample] = []
  var cumulativeByteCount = 0
  for (chunkIndex, offset) in stride(from: 0, to: encoded.count, by: chunkSize).enumerated() {
    let end = min(encoded.count, offset + chunkSize)
    let chunk = encoded.subdata(in: offset ..< end)
    cumulativeByteCount += chunk.count
    let appendStarted = DispatchTime.now().uptimeNanoseconds
    let generation = try session.append(chunk)
    let appendDuration = DispatchTime.now().uptimeNanoseconds &- appendStarted
    let handoffDuration: UInt64? = if let generation {
      await measureMainActorHandoff(generation.image)
    } else {
      nil
    }
    chunkSamples.append(
      ProgressivePipelineChunkSample(
        chunkIndex: chunkIndex,
        chunkByteCount: chunk.count,
        cumulativeByteCount: cumulativeByteCount,
        appendDurationNanoseconds: appendDuration,
        generation: generation?.generation,
        generationSourceByteCount: generation?.sourceByteCount,
        mainActorHandoffNanoseconds: handoffDuration,
      ),
    )
  }

  let finishStarted = DispatchTime.now().uptimeNanoseconds
  try session.finish()
  let finishDuration = DispatchTime.now().uptimeNanoseconds &- finishStarted

  let finalDecodeStarted = DispatchTime.now().uptimeNanoseconds
  let final = try decoder.decode(data: encoded, request: request, limits: limits)
  let finalDecodeDuration = DispatchTime.now().uptimeNanoseconds &- finalDecodeStarted
  let finalHandoffDuration = await measureMainActorHandoff(final)
  let hashStarted = DispatchTime.now().uptimeNanoseconds
  let finalDigest = try sha256(rgbData(from: final.cgImage))
  let hashDuration = DispatchTime.now().uptimeNanoseconds &- hashStarted

  guard cumulativeByteCount == encoded.count,
        chunkSamples.count >= 1,
        chunkSamples.compactMap(\.generation).count <= 4
  else {
    throw ProgressivePipelineProfileError.unexpectedOutput
  }

  return ProgressivePipelineIteration(
    chunks: chunkSamples,
    finishDurationNanoseconds: finishDuration,
    finalDecodeDurationNanoseconds: finalDecodeDuration,
    finalMainActorHandoffNanoseconds: finalHandoffDuration,
    finalAnalysisHashDurationNanoseconds: hashDuration,
    finalPixelRGBSHA256: finalDigest,
    finalPixelWidth: final.pixelWidth,
    finalPixelHeight: final.pixelHeight,
    totalDurationNanoseconds: DispatchTime.now().uptimeNanoseconds &- started,
  )
}

private func measureMainActorHandoff(_ image: DecodedImage) async -> UInt64 {
  let started = DispatchTime.now().uptimeNanoseconds
  let dimensions = await MainActor.run { (image.pixelWidth, image.pixelHeight) }
  precondition(dimensions.0 > 0 && dimensions.1 > 0)
  return DispatchTime.now().uptimeNanoseconds &- started
}

private func summarizeProgressivePipelineProfile(
  _ samples: [ProgressivePipelineIteration],
) throws -> ProgressivePipelineProfileSummary {
  guard let reference = samples.first, !reference.chunks.isEmpty else {
    throw ProgressivePipelineProfileError.unexpectedOutput
  }
  let finalDigests = Set(samples.map(\.finalPixelRGBSHA256))
  guard finalDigests.count == 1,
        samples.allSatisfy({ $0.finalPixelWidth == reference.finalPixelWidth }),
        samples.allSatisfy({ $0.finalPixelHeight == reference.finalPixelHeight }),
        samples.allSatisfy({ $0.chunks.count == reference.chunks.count })
  else {
    throw ProgressivePipelineProfileError.unexpectedOutput
  }

  var chunkSummaries: [ProgressivePipelineChunkSummary] = []
  for index in reference.chunks.indices {
    let referenceChunk = reference.chunks[index]
    let peers = samples.map { $0.chunks[index] }
    guard peers.allSatisfy({ peer in
      peer.chunkIndex == referenceChunk.chunkIndex
        && peer.chunkByteCount == referenceChunk.chunkByteCount
        && peer.cumulativeByteCount == referenceChunk.cumulativeByteCount
        && peer.generation == referenceChunk.generation
        && peer.generationSourceByteCount == referenceChunk.generationSourceByteCount
    }) else {
      throw ProgressivePipelineProfileError.unexpectedOutput
    }
    let handoffSamples = peers.compactMap(\.mainActorHandoffNanoseconds)
    chunkSummaries.append(
      ProgressivePipelineChunkSummary(
        chunkIndex: referenceChunk.chunkIndex,
        chunkByteCount: referenceChunk.chunkByteCount,
        cumulativeByteCount: referenceChunk.cumulativeByteCount,
        generation: referenceChunk.generation,
        generationSourceByteCount: referenceChunk.generationSourceByteCount,
        appendDuration: durationStatistics(peers.map(\.appendDurationNanoseconds)),
        mainActorHandoff: handoffSamples.isEmpty
          ? nil : durationStatistics(handoffSamples),
      ),
    )
  }

  let generationChunks = reference.chunks.filter { $0.generation != nil }
  return ProgressivePipelineProfileSummary(
    generationCount: generationChunks.count,
    generationSequence: generationChunks.compactMap(\.generation),
    generationSourceByteCounts: generationChunks.compactMap(\.generationSourceByteCount),
    chunks: chunkSummaries,
    finishDuration: durationStatistics(samples.map(\.finishDurationNanoseconds)),
    finalDecodeDuration: durationStatistics(samples.map(\.finalDecodeDurationNanoseconds)),
    finalMainActorHandoff: durationStatistics(samples.map(\.finalMainActorHandoffNanoseconds)),
    finalAnalysisHashDuration: durationStatistics(
      samples.map(\.finalAnalysisHashDurationNanoseconds),
    ),
    totalDuration: durationStatistics(samples.map(\.totalDurationNanoseconds)),
  )
}
