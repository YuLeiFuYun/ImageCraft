import CoreGraphics
import Foundation
import ImageCraftCore
import ImageCraftImageIO

private let progressiveTimelineBenchmarkVersion = "imagecraft-progressive-timeline-v1"

private enum ProgressiveTimelineBenchmarkError: Error {
  case invalidCase
  case invalidIterations
  case unexpectedOutput
}

private enum ProgressiveTimelineBenchmarkCase: String, CaseIterable {
  case chunk1K = "progressive-jpeg-timeline-fit-512-chunk-1024"
  case chunk32K = "progressive-jpeg-timeline-fit-512-chunk-32768"

  var chunkSize: Int {
    switch self {
    case .chunk1K: 1_024
    case .chunk32K: 32 * 1_024
    }
  }
}

private struct ProgressiveGenerationTimelineSample: Codable, Equatable {
  let generation: UInt32
  let sourceByteCount: Int
  let elapsedNanoseconds: UInt64
}

private struct ProgressiveTimelineIteration: Codable, Equatable {
  let generations: [ProgressiveGenerationTimelineSample]
  let finishElapsedNanoseconds: UInt64
  let totalElapsedNanoseconds: UInt64
}

private struct ProgressiveGenerationTimelineSummary: Codable, Equatable {
  let generation: UInt32
  let sourceByteCount: Int
  let encodedByteFractionPPM: Int
  let elapsed: PerformanceDurationStatistics
}

private struct ProgressiveTimelineSummary: Codable, Equatable {
  let generationCount: Int
  let firstPreviewSourceByteCount: Int
  let firstPreviewEncodedByteFractionPPM: Int
  let firstPreviewElapsed: PerformanceDurationStatistics
  let generations: [ProgressiveGenerationTimelineSummary]
  let finishElapsed: PerformanceDurationStatistics
  let totalElapsed: PerformanceDurationStatistics
}

private struct ProgressiveTimelineCaseReport: Codable {
  let schemaVersion: UInt16
  let benchmarkVersion: String
  let runtime: ImageIORuntimeFingerprint
  let decoderFingerprint: String
  let environment: PerformanceEnvironment
  let caseID: String
  let buildConfiguration: String
  let warmupIterations: Int
  let iterations: Int
  let chunkSizeBytes: Int
  let chunkCount: Int
  let source: PerformanceSource
  let output: PerformanceOutput
  let samples: [ProgressiveTimelineIteration]
  let summary: ProgressiveTimelineSummary
}

func writeProgressiveTimelineBenchmark(caseID: String, iterations: Int) throws {
  guard let benchmarkCase = ProgressiveTimelineBenchmarkCase(rawValue: caseID) else {
    throw ProgressiveTimelineBenchmarkError.invalidCase
  }
  guard (1...50).contains(iterations) else {
    throw ProgressiveTimelineBenchmarkError.invalidIterations
  }

  let fixture = try ProgressiveTimelineFixture(chunkSize: benchmarkCase.chunkSize)
  let reference = try fixture.execute()
  let warmupIterations = 2
  for _ in 0..<warmupIterations {
    _ = try autoreleasepool(invoking: fixture.execute)
  }

  var samples: [ProgressiveTimelineIteration] = []
  samples.reserveCapacity(iterations)
  for _ in 0..<iterations {
    let sample = try autoreleasepool(invoking: fixture.execute)
    try fixture.validate(sample, against: reference)
    samples.append(sample)
  }

  let report = ProgressiveTimelineCaseReport(
    schemaVersion: 1,
    benchmarkVersion: progressiveTimelineBenchmarkVersion,
    runtime: .capture(),
    decoderFingerprint: fixture.decoder.codecDescriptor.cacheFingerprint,
    environment: capturePerformanceEnvironment(),
    caseID: benchmarkCase.rawValue,
    buildConfiguration: "release",
    warmupIterations: warmupIterations,
    iterations: iterations,
    chunkSizeBytes: benchmarkCase.chunkSize,
    chunkCount: fixture.chunks.count,
    source: fixture.source,
    output: fixture.output,
    samples: samples,
    summary: try summarizeProgressiveTimeline(
      samples,
      encodedByteCount: fixture.encoded.count
    )
  )

  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  FileHandle.standardOutput.write(try encoder.encode(report))
  FileHandle.standardOutput.write(Data([0x0A]))
}

private struct ProgressiveTimelineFixture {
  let decoder = ImageIOImageDecoder()
  let encoded: Data
  let chunks: [Data]
  let limits: DecodeLimits
  let request: ImageDecodeRequest
  let source: PerformanceSource
  let output: PerformanceOutput

  init(chunkSize: Int) throws {
    let sourceWidth = 3_072
    let sourceHeight = 2_048
    let sourceRGB = makePatternRGBData(width: sourceWidth, height: sourceHeight)
    let sourceImage = try makePatternImage(
      width: sourceWidth,
      height: sourceHeight,
      rgb: sourceRGB
    )
    let encoded = try makeProgressiveJPEG(image: sourceImage, quality: 0.82)
    self.encoded = encoded
    self.chunks = stride(from: 0, to: encoded.count, by: chunkSize).map { offset in
      encoded.subdata(in: offset..<min(encoded.count, offset + chunkSize))
    }
    self.limits = DecodeLimits(
      maximumEncodedBytes: max(encoded.count, 1),
      maximumDimension: 16_384,
      maximumPixelCount: 100_000_000,
      maximumFrameCount: 1,
      maximumMetadataBytes: 4 * 1024 * 1024,
      maximumAuxiliaryAttachments: 0,
      allowedFormats: [.jpeg]
    )
    self.request = ImageDecodeRequest(
      target: try TargetPixels(width: 512, height: 512),
      contentMode: .fit,
      colorPolicy: .preserveSource
    )
    self.source = PerformanceSource(
      generator: "imagecraft-progressive-pattern-v1",
      representation: EncodedImageFormat.jpeg.rawValue,
      pixelWidth: sourceWidth,
      pixelHeight: sourceHeight,
      encodedByteCount: encoded.count,
      encodedSHA256: sha256(encoded),
      targetWidth: 512,
      targetHeight: 512,
      contentMode: ImageContentMode.fit.rawValue
    )

    let reference = try ImageIOImageDecoder().decode(
      data: encoded,
      request: request,
      limits: limits
    )
    self.output = PerformanceOutput(
      representation: "progressive-cgImage-source-color",
      pixelWidth: reference.pixelWidth,
      pixelHeight: reference.pixelHeight,
      encodedByteCount: nil,
      sha256: nil
    )
  }

  func execute() throws -> ProgressiveTimelineIteration {
    let started = DispatchTime.now().uptimeNanoseconds
    let session = try decoder.makeProgressiveSession(
      format: .jpeg,
      request: request,
      limits: limits
    )
    var generations: [ProgressiveGenerationTimelineSample] = []
    for chunk in chunks {
      if let generation = try session.append(chunk) {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- started
        guard generation.image.pixelWidth == output.pixelWidth,
          generation.image.pixelHeight == output.pixelHeight
        else {
          throw ProgressiveTimelineBenchmarkError.unexpectedOutput
        }
        generations.append(
          ProgressiveGenerationTimelineSample(
            generation: generation.generation,
            sourceByteCount: generation.sourceByteCount,
            elapsedNanoseconds: elapsed
          )
        )
      }
    }
    try session.finish()
    let finishElapsed = DispatchTime.now().uptimeNanoseconds &- started
    guard generations.count >= 2, generations.count <= 4 else {
      throw ProgressiveTimelineBenchmarkError.unexpectedOutput
    }
    let totalElapsed = DispatchTime.now().uptimeNanoseconds &- started
    return ProgressiveTimelineIteration(
      generations: generations,
      finishElapsedNanoseconds: finishElapsed,
      totalElapsedNanoseconds: totalElapsed
    )
  }

  func validate(
    _ sample: ProgressiveTimelineIteration,
    against reference: ProgressiveTimelineIteration
  ) throws {
    guard sample.generations.map(\.generation) == reference.generations.map(\.generation),
      sample.generations.map(\.sourceByteCount)
        == reference.generations.map(\.sourceByteCount),
      sample.generations.map(\.elapsedNanoseconds).elementsEqual(
        sample.generations.map(\.elapsedNanoseconds).sorted()
      ),
      sample.finishElapsedNanoseconds
        >= (sample.generations.last?.elapsedNanoseconds ?? UInt64.max),
      sample.totalElapsedNanoseconds >= sample.finishElapsedNanoseconds
    else {
      throw ProgressiveTimelineBenchmarkError.unexpectedOutput
    }
  }
}

private func summarizeProgressiveTimeline(
  _ samples: [ProgressiveTimelineIteration],
  encodedByteCount: Int
) throws -> ProgressiveTimelineSummary {
  guard let reference = samples.first, !reference.generations.isEmpty else {
    throw ProgressiveTimelineBenchmarkError.unexpectedOutput
  }
  let generationCount = reference.generations.count
  guard samples.allSatisfy({ $0.generations.count == generationCount }) else {
    throw ProgressiveTimelineBenchmarkError.unexpectedOutput
  }

  let generationSummaries = try (0..<generationCount).map { index in
    let generation = reference.generations[index].generation
    let sourceByteCount = reference.generations[index].sourceByteCount
    guard samples.allSatisfy({ sample in
      sample.generations[index].generation == generation
        && sample.generations[index].sourceByteCount == sourceByteCount
    }) else {
      throw ProgressiveTimelineBenchmarkError.unexpectedOutput
    }
    return ProgressiveGenerationTimelineSummary(
      generation: generation,
      sourceByteCount: sourceByteCount,
      encodedByteFractionPPM: fractionPPM(sourceByteCount, denominator: encodedByteCount),
      elapsed: durationStatistics(
        samples.map { $0.generations[index].elapsedNanoseconds }
      )
    )
  }

  let first = generationSummaries[0]
  return ProgressiveTimelineSummary(
    generationCount: generationCount,
    firstPreviewSourceByteCount: first.sourceByteCount,
    firstPreviewEncodedByteFractionPPM: first.encodedByteFractionPPM,
    firstPreviewElapsed: first.elapsed,
    generations: generationSummaries,
    finishElapsed: durationStatistics(samples.map(\.finishElapsedNanoseconds)),
    totalElapsed: durationStatistics(samples.map(\.totalElapsedNanoseconds))
  )
}

private func fractionPPM(_ numerator: Int, denominator: Int) -> Int {
  guard denominator > 0, numerator >= 0 else { return 0 }
  let scaled = numerator.multipliedReportingOverflow(by: 1_000_000)
  guard !scaled.overflow else { return Int.max }
  return min(1_000_000, scaled.partialValue / denominator)
}
