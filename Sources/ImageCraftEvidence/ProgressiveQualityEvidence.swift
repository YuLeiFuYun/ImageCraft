import Foundation
import ImageCraftCore
import ImageCraftImageIO

private let progressiveQualityEvidenceVersion = "imagecraft-progressive-quality-v1"

private enum ProgressiveQualityEvidenceError: Error {
  case invalidCase
  case unexpectedOutput
}

private enum ProgressiveQualityEvidenceCase: String, CaseIterable {
  case chunk1K = "progressive-jpeg-quality-fit-512-chunk-1024"
  case chunk32K = "progressive-jpeg-quality-fit-512-chunk-32768"

  var chunkSize: Int {
    switch self {
    case .chunk1K: 1_024
    case .chunk32K: 32 * 1_024
    }
  }
}

private struct ProgressivePixelErrorMetrics: Codable, Equatable {
  let channelCount: Int
  let differentChannelCount: Int
  let maximumAbsoluteError: Int
  let absoluteErrorSum: UInt64
  let squaredErrorSum: UInt64
  let meanAbsoluteErrorMicrounits: UInt64
  let meanSquaredErrorMicrounits: UInt64
  let psnrMicrodecibels: Int64
  let absoluteErrorAtMost8PPM: Int
  let absoluteErrorAtMost16PPM: Int
  let absoluteErrorAtMost32PPM: Int
  let absoluteErrorAtMost64PPM: Int
}

private struct ProgressiveQualityGeneration: Codable, Equatable {
  let generation: UInt32
  let sourceByteCount: Int
  let encodedByteFractionPPM: Int
  let pixelRGBSHA256: String
  let metricsAgainstFinal: ProgressivePixelErrorMetrics
}

private struct ProgressiveQualityEvidenceReport: Codable {
  let schemaVersion: UInt16
  let evidenceVersion: String
  let runtime: ImageIORuntimeFingerprint
  let decoderFingerprint: String
  let environment: PerformanceEnvironment
  let caseID: String
  let buildConfiguration: String
  let chunkSizeBytes: Int
  let chunkCount: Int
  let source: PerformanceSource
  let output: PerformanceOutput
  let finalPixelRGBSHA256: String
  let generations: [ProgressiveQualityGeneration]
}

func writeProgressiveQualityEvidence(caseID: String) throws {
  guard let evidenceCase = ProgressiveQualityEvidenceCase(rawValue: caseID) else {
    throw ProgressiveQualityEvidenceError.invalidCase
  }
  let fixture = try ProgressiveQualityFixture(chunkSize: evidenceCase.chunkSize)
  let report = try fixture.report(caseID: evidenceCase.rawValue)
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  FileHandle.standardOutput.write(try encoder.encode(report))
  FileHandle.standardOutput.write(Data([0x0A]))
}

private struct ProgressiveQualityFixture {
  let decoder = ImageIOImageDecoder()
  let encoded: Data
  let chunks: [Data]
  let limits: DecodeLimits
  let request: ImageDecodeRequest
  let source: PerformanceSource

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
  }

  func report(caseID: String) throws -> ProgressiveQualityEvidenceReport {
    let final = try decoder.decode(data: encoded, request: request, limits: limits)
    let finalRGB = try rgbData(from: final.cgImage)
    let output = PerformanceOutput(
      representation: "progressive-cgImage-source-color-rgb8-srgb-analysis",
      pixelWidth: final.pixelWidth,
      pixelHeight: final.pixelHeight,
      encodedByteCount: nil,
      sha256: nil
    )

    let session = try decoder.makeProgressiveSession(
      format: .jpeg,
      request: request,
      limits: limits
    )
    var generations: [ProgressiveQualityGeneration] = []
    for chunk in chunks {
      guard let generation = try session.append(chunk) else { continue }
      guard generation.image.pixelWidth == final.pixelWidth,
        generation.image.pixelHeight == final.pixelHeight
      else {
        throw ProgressiveQualityEvidenceError.unexpectedOutput
      }
      let rgb = try rgbData(from: generation.image.cgImage)
      generations.append(
        ProgressiveQualityGeneration(
          generation: generation.generation,
          sourceByteCount: generation.sourceByteCount,
          encodedByteFractionPPM: fractionPPM(
            generation.sourceByteCount,
            denominator: encoded.count
          ),
          pixelRGBSHA256: sha256(rgb),
          metricsAgainstFinal: try pixelMetrics(reference: finalRGB, candidate: rgb)
        )
      )
    }
    try session.finish()
    guard generations.map(\.generation) == [1, 2, 3, 4] else {
      throw ProgressiveQualityEvidenceError.unexpectedOutput
    }

    return ProgressiveQualityEvidenceReport(
      schemaVersion: 1,
      evidenceVersion: progressiveQualityEvidenceVersion,
      runtime: .capture(),
      decoderFingerprint: decoder.codecDescriptor.cacheFingerprint,
      environment: capturePerformanceEnvironment(),
      caseID: caseID,
      buildConfiguration: "release",
      chunkSizeBytes: chunks.first?.count ?? 0,
      chunkCount: chunks.count,
      source: source,
      output: output,
      finalPixelRGBSHA256: sha256(finalRGB),
      generations: generations
    )
  }
}

private func pixelMetrics(
  reference: Data,
  candidate: Data
) throws -> ProgressivePixelErrorMetrics {
  guard reference.count == candidate.count, !reference.isEmpty else {
    throw ProgressiveQualityEvidenceError.unexpectedOutput
  }
  var different = 0
  var maximum = 0
  var absoluteSum: UInt64 = 0
  var squaredSum: UInt64 = 0
  var atMost8 = 0
  var atMost16 = 0
  var atMost32 = 0
  var atMost64 = 0

  for index in reference.indices {
    let difference = abs(Int(reference[index]) - Int(candidate[index]))
    if difference != 0 { different += 1 }
    maximum = max(maximum, difference)
    absoluteSum += UInt64(difference)
    squaredSum += UInt64(difference * difference)
    if difference <= 8 { atMost8 += 1 }
    if difference <= 16 { atMost16 += 1 }
    if difference <= 32 { atMost32 += 1 }
    if difference <= 64 { atMost64 += 1 }
  }

  let count = UInt64(reference.count)
  let meanAbsoluteMicro = scaledRatio(absoluteSum, multiplier: 1_000_000, divisor: count)
  let meanSquaredMicro = scaledRatio(squaredSum, multiplier: 1_000_000, divisor: count)
  let mse = Double(squaredSum) / Double(reference.count)
  let psnr = mse == 0 ? 999.0 : 10.0 * log10((255.0 * 255.0) / mse)

  return ProgressivePixelErrorMetrics(
    channelCount: reference.count,
    differentChannelCount: different,
    maximumAbsoluteError: maximum,
    absoluteErrorSum: absoluteSum,
    squaredErrorSum: squaredSum,
    meanAbsoluteErrorMicrounits: meanAbsoluteMicro,
    meanSquaredErrorMicrounits: meanSquaredMicro,
    psnrMicrodecibels: Int64((psnr * 1_000_000.0).rounded()),
    absoluteErrorAtMost8PPM: fractionPPM(atMost8, denominator: reference.count),
    absoluteErrorAtMost16PPM: fractionPPM(atMost16, denominator: reference.count),
    absoluteErrorAtMost32PPM: fractionPPM(atMost32, denominator: reference.count),
    absoluteErrorAtMost64PPM: fractionPPM(atMost64, denominator: reference.count)
  )
}

private func scaledRatio(_ value: UInt64, multiplier: UInt64, divisor: UInt64) -> UInt64 {
  guard divisor > 0 else { return 0 }
  let product = value.multipliedReportingOverflow(by: multiplier)
  return product.overflow ? UInt64.max : product.partialValue / divisor
}

private func fractionPPM(_ numerator: Int, denominator: Int) -> Int {
  guard numerator >= 0, denominator > 0 else { return 0 }
  let product = numerator.multipliedReportingOverflow(by: 1_000_000)
  return product.overflow ? Int.max : min(1_000_000, product.partialValue / denominator)
}
