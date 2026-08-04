import Foundation
import ImageCraftCore
import ImageCraftImageIO

private let progressivePhotoCorpusEvidenceVersion = "imagecraft-progressive-photo-corpus-v1"
private enum ProgressivePhotoCorpusEvidenceError: Error {
  case invalidManifest
  case invalidVariant
  case invalidChunkSize
  case unsafePath
  case unexpectedOutput
}

private struct ProgressivePhotoManifest: Decodable {
  let corpusVersion: String
  let sources: [ProgressivePhotoSource]
  let scanScripts: [ProgressivePhotoScanScript]
  let variants: [ProgressivePhotoVariant]
}

private struct ProgressivePhotoSource: Decodable {
  let id: String
  let description: String
  let contentClass: String
  let width: Int
  let height: Int
}

private struct ProgressivePhotoScanScript: Decodable {
  let id: String
  let scanCount: Int
}

private struct ProgressivePhotoVariant: Decodable {
  let id: String
  let sourceID: String
  let scanScriptID: String
  let file: String
  let width: Int
  let height: Int
  let scanCount: Int
  let byteCount: Int
  let sha256: String
}

private struct ProgressivePhotoGeneration: Codable, Equatable {
  let generation: UInt32
  let sourceByteCount: Int
  let encodedByteFractionPPM: Int
  let pixelRGBSHA256: String
  let metricsAgainstFinal: ProgressiveCorpusPixelErrorMetrics
}

private struct ProgressivePhotoCorpusEvidenceReport: Codable {
  let schemaVersion: UInt16
  let evidenceVersion: String
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
  let scanCount: Int
  let chunkSizeBytes: Int
  let chunkCount: Int
  let encodedByteCount: Int
  let encodedSHA256: String
  let sourcePixelWidth: Int
  let sourcePixelHeight: Int
  let outputPixelWidth: Int
  let outputPixelHeight: Int
  let finalPixelRGBSHA256: String
  let generations: [ProgressivePhotoGeneration]
}

func writeProgressivePhotoCorpusEvidence(
  manifestURL: URL,
  variantID: String,
  chunkSize: Int,
) throws {
  guard (1 ... 1_048_576).contains(chunkSize) else {
    throw ProgressivePhotoCorpusEvidenceError.invalidChunkSize
  }
  let manifestData = try Data(contentsOf: manifestURL)
  let manifest = try JSONDecoder().decode(ProgressivePhotoManifest.self, from: manifestData)
  guard manifest.corpusVersion == "progressive-real-photo-v1",
        let variant = manifest.variants.first(where: { $0.id == variantID }),
        let source = manifest.sources.first(where: { $0.id == variant.sourceID }),
        let scanScript = manifest.scanScripts.first(where: { $0.id == variant.scanScriptID }),
        source.width == variant.width,
        source.height == variant.height,
        scanScript.scanCount == variant.scanCount
  else {
    throw ProgressivePhotoCorpusEvidenceError.invalidManifest
  }

  let root = manifestURL.deletingLastPathComponent().standardizedFileURL
  let encodedURL = root.appendingPathComponent(variant.file).standardizedFileURL
  guard encodedURL.path == root.path || encodedURL.path.hasPrefix(root.path + "/") else {
    throw ProgressivePhotoCorpusEvidenceError.unsafePath
  }
  let encoded = try Data(contentsOf: encodedURL)
  guard encoded.count == variant.byteCount, sha256(encoded) == variant.sha256 else {
    throw ProgressivePhotoCorpusEvidenceError.invalidVariant
  }

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
  let final = try decoder.decode(data: encoded, request: request, limits: limits)
  let finalRGB = try rgbData(from: final.cgImage)
  let chunks = stride(from: 0, to: encoded.count, by: chunkSize).map { offset in
    encoded.subdata(in: offset ..< min(encoded.count, offset + chunkSize))
  }
  let session = try decoder.makeProgressiveSession(
    format: .jpeg,
    request: request,
    limits: limits,
  )
  var generations: [ProgressivePhotoGeneration] = []
  for chunk in chunks {
    guard let generation = try session.append(chunk) else { continue }
    guard generation.image.pixelWidth == final.pixelWidth,
          generation.image.pixelHeight == final.pixelHeight
    else {
      throw ProgressivePhotoCorpusEvidenceError.unexpectedOutput
    }
    let rgb = try rgbData(from: generation.image.cgImage)
    try generations.append(
      ProgressivePhotoGeneration(
        generation: generation.generation,
        sourceByteCount: generation.sourceByteCount,
        encodedByteFractionPPM: progressiveCorpusFractionPPM(
          generation.sourceByteCount,
          denominator: encoded.count,
        ),
        pixelRGBSHA256: sha256(rgb),
        metricsAgainstFinal: progressiveCorpusPixelMetrics(reference: finalRGB, candidate: rgb),
      ),
    )
  }
  try session.finish()

  guard (1 ... 4).contains(generations.count),
        generations.map(\.generation) == Array(1 ... UInt32(generations.count)),
        generations.map(\.sourceByteCount) == generations.map(\.sourceByteCount).sorted()
  else {
    throw ProgressivePhotoCorpusEvidenceError.unexpectedOutput
  }

  let report = ProgressivePhotoCorpusEvidenceReport(
    schemaVersion: 1,
    evidenceVersion: progressivePhotoCorpusEvidenceVersion,
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
    scanScriptID: scanScript.id,
    scanCount: scanScript.scanCount,
    chunkSizeBytes: chunkSize,
    chunkCount: chunks.count,
    encodedByteCount: encoded.count,
    encodedSHA256: variant.sha256,
    sourcePixelWidth: source.width,
    sourcePixelHeight: source.height,
    outputPixelWidth: final.pixelWidth,
    outputPixelHeight: final.pixelHeight,
    finalPixelRGBSHA256: sha256(finalRGB),
    generations: generations,
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  try FileHandle.standardOutput.write(encoder.encode(report))
  FileHandle.standardOutput.write(Data([0x0A]))
}
