import CoreGraphics
import Foundation
import ImageCraftCore
import ImageCraftImageIO
import ImageIO
import UniformTypeIdentifiers

private struct RasterComparisonSample: Codable {
  let finalSourceUpdateNanoseconds: UInt64
  let preparationFinalizationNanoseconds: UInt64?
  let rasterCreationNanoseconds: UInt64
  let postProcessingNanoseconds: UInt64
  let totalAfterLastChunkNanoseconds: UInt64
  let pixelWidth: Int
  let pixelHeight: Int
  let pixelRGBSHA256: String
}

private struct RasterComparisonSummary: Codable {
  let medianFinalSourceUpdateNanoseconds: UInt64
  let medianPreparationFinalizationNanoseconds: UInt64?
  let medianRasterCreationNanoseconds: UInt64
  let medianPostProcessingNanoseconds: UInt64
  let medianTotalAfterLastChunkNanoseconds: UInt64
  let p95TotalAfterLastChunkNanoseconds: UInt64
}

private struct RasterComparisonPath: Codable {
  let summary: RasterComparisonSummary
  let samples: [RasterComparisonSample]
}

private struct RasterComparisonReport: Codable {
  let schemaVersion: UInt16
  let evidenceVersion: String
  let runtime: ImageIORuntimeFingerprint
  let inputByteCount: Int
  let inputSHA256: String
  let chunkSize: Int
  let targetWidth: Int
  let targetHeight: Int
  let contentMode: String
  let colorPolicy: String
  let warmupIterations: Int
  let measuredIterations: Int
  let measurementOrder: String
  let appleFirstMeasuredIterations: Int
  let imageCraftFirstMeasuredIterations: Int
  let apple: RasterComparisonPath
  let imageCraft: RasterComparisonPath
  let outputPixelsEqualAcrossPaths: Bool
}

func writeRasterComparisonEvidence(
  input: URL,
  chunkSize: Int,
  iterations: Int
) throws {
  guard chunkSize > 0, iterations > 0 else { throw EvidenceError.invalidArguments }
  let data = try Data(contentsOf: input)
  guard data.count > chunkSize else { throw EvidenceError.invalidArguments }
  let target = try TargetPixels(width: 512, height: 512)
  let request = ImageDecodeRequest(
    target: target,
    contentMode: .fit,
    colorPolicy: .preserveSource
  )
  let limits = DecodeLimits(
    maximumEncodedBytes: max(data.count, 1),
    maximumDimension: 16_384,
    maximumPixelCount: 100_000_000,
    maximumFrameCount: 1,
    maximumMetadataBytes: 4 * 1_024 * 1_024,
    maximumAuxiliaryAttachments: 0,
    allowedFormats: [.jpeg]
  )
  let warmups = 3
  var appleSamples: [RasterComparisonSample] = []
  var imageCraftSamples: [RasterComparisonSample] = []
  var appleFirstMeasuredIterations = 0
  var imageCraftFirstMeasuredIterations = 0
  for index in 0..<(warmups + iterations) {
    let apple: RasterComparisonSample
    let imageCraft: RasterComparisonSample
    if index.isMultiple(of: 2) {
      apple = try appleRasterComparisonSample(
        data: data,
        chunkSize: chunkSize,
        target: target
      )
      imageCraft = try imageCraftRasterComparisonSample(
        data: data,
        chunkSize: chunkSize,
        request: request,
        limits: limits
      )
    } else {
      imageCraft = try imageCraftRasterComparisonSample(
        data: data,
        chunkSize: chunkSize,
        request: request,
        limits: limits
      )
      apple = try appleRasterComparisonSample(
        data: data,
        chunkSize: chunkSize,
        target: target
      )
    }
    if index >= warmups {
      appleSamples.append(apple)
      imageCraftSamples.append(imageCraft)
      if index.isMultiple(of: 2) {
        appleFirstMeasuredIterations += 1
      } else {
        imageCraftFirstMeasuredIterations += 1
      }
    }
  }
  let report = RasterComparisonReport(
    schemaVersion: 2,
    evidenceVersion: "imagecraft-raster-comparison-v2",
    runtime: .capture(),
    inputByteCount: data.count,
    inputSHA256: sha256(data),
    chunkSize: chunkSize,
    targetWidth: target.width,
    targetHeight: target.height,
    contentMode: "fit",
    colorPolicy: "preserve-source",
    warmupIterations: warmups,
    measuredIterations: iterations,
    measurementOrder: "alternating-apple-first-imagecraft-first",
    appleFirstMeasuredIterations: appleFirstMeasuredIterations,
    imageCraftFirstMeasuredIterations: imageCraftFirstMeasuredIterations,
    apple: RasterComparisonPath(
      summary: rasterComparisonSummary(appleSamples),
      samples: appleSamples
    ),
    imageCraft: RasterComparisonPath(
      summary: rasterComparisonSummary(imageCraftSamples),
      samples: imageCraftSamples
    ),
    outputPixelsEqualAcrossPaths: Set(
      appleSamples.map(\.pixelRGBSHA256) + imageCraftSamples.map(\.pixelRGBSHA256)
    ).count == 1
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  FileHandle.standardOutput.write(try encoder.encode(report))
  FileHandle.standardOutput.write(Data([0x0A]))
}

private func appleRasterComparisonSample(
  data: Data,
  chunkSize: Int,
  target: TargetPixels
) throws -> RasterComparisonSample {
  let source = CGImageSourceCreateIncremental([
    kCGImageSourceShouldCache: false,
    kCGImageSourceTypeIdentifierHint: UTType.jpeg.identifier,
  ] as CFDictionary)
  let split = lastChunkStart(dataCount: data.count, chunkSize: chunkSize)
  if split > 0 {
    var offset = chunkSize
    while offset <= split {
      CGImageSourceUpdateData(source, data.prefix(offset) as CFData, false)
      offset += chunkSize
    }
  }
  let totalStarted = DispatchTime.now().uptimeNanoseconds
  let updateStarted = DispatchTime.now().uptimeNanoseconds
  CGImageSourceUpdateData(source, data as CFData, true)
  let updateDuration = DispatchTime.now().uptimeNanoseconds &- updateStarted
  let rasterStarted = DispatchTime.now().uptimeNanoseconds
  guard
    let image = CGImageSourceCreateThumbnailAtIndex(
      source,
      0,
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max(target.width, target.height),
        kCGImageSourceShouldCacheImmediately: true,
      ] as CFDictionary
    )
  else {
    throw EvidenceError.imageCreationFailed
  }
  let rasterDuration = DispatchTime.now().uptimeNanoseconds &- rasterStarted
  let totalDuration = DispatchTime.now().uptimeNanoseconds &- totalStarted
  return RasterComparisonSample(
    finalSourceUpdateNanoseconds: updateDuration,
    preparationFinalizationNanoseconds: nil,
    rasterCreationNanoseconds: rasterDuration,
    postProcessingNanoseconds: 0,
    totalAfterLastChunkNanoseconds: totalDuration,
    pixelWidth: image.width,
    pixelHeight: image.height,
    pixelRGBSHA256: sha256(try rgbData(from: image))
  )
}

private func imageCraftRasterComparisonSample(
  data: Data,
  chunkSize: Int,
  request: ImageDecodeRequest,
  limits: DecodeLimits
) throws -> RasterComparisonSample {
  let decoder = ImageIOImageDecoder()
  let session = try decoder.makeProgressiveSession(
    format: .jpeg,
    request: request,
    limits: limits
  )
  let split = lastChunkStart(dataCount: data.count, chunkSize: chunkSize)
  var offset = 0
  while offset < split {
    let end = min(split, offset + chunkSize)
    _ = try session.append(data.subdata(in: offset..<end))
    offset = end
  }
  let totalStarted = DispatchTime.now().uptimeNanoseconds
  let appendStarted = DispatchTime.now().uptimeNanoseconds
  _ = try session.append(data.subdata(in: split..<data.count))
  let appendDuration = DispatchTime.now().uptimeNanoseconds &- appendStarted
  guard let preparing = session as? any ProgressiveImagePreparingSession else {
    throw EvidenceError.invalidArguments
  }
  let finalizationStarted = DispatchTime.now().uptimeNanoseconds
  let finalization = try preparing.finishWithPreparation()
  let finalizationDuration = DispatchTime.now().uptimeNanoseconds &- finalizationStarted
  let decoded = try decoder.decodeWithDiagnostics(
    preparation: finalization.preparation,
    request: request,
    limits: limits
  )
  let totalDuration = DispatchTime.now().uptimeNanoseconds &- totalStarted
  return RasterComparisonSample(
    finalSourceUpdateNanoseconds: appendDuration,
    preparationFinalizationNanoseconds: finalizationDuration,
    rasterCreationNanoseconds: decoded.diagnostics.rasterCreationNanoseconds,
    postProcessingNanoseconds: decoded.diagnostics.postProcessingNanoseconds,
    totalAfterLastChunkNanoseconds: totalDuration,
    pixelWidth: decoded.image.pixelWidth,
    pixelHeight: decoded.image.pixelHeight,
    pixelRGBSHA256: sha256(try rgbData(from: decoded.image.cgImage))
  )
}

private func lastChunkStart(dataCount: Int, chunkSize: Int) -> Int {
  max(0, ((dataCount - 1) / chunkSize) * chunkSize)
}

private func rasterComparisonSummary(
  _ samples: [RasterComparisonSample]
) -> RasterComparisonSummary {
  RasterComparisonSummary(
    medianFinalSourceUpdateNanoseconds: median(
      samples.map(\.finalSourceUpdateNanoseconds)
    ),
    medianPreparationFinalizationNanoseconds: samples.first?
      .preparationFinalizationNanoseconds == nil
      ? nil
      : median(samples.compactMap(\.preparationFinalizationNanoseconds)),
    medianRasterCreationNanoseconds: median(samples.map(\.rasterCreationNanoseconds)),
    medianPostProcessingNanoseconds: median(samples.map(\.postProcessingNanoseconds)),
    medianTotalAfterLastChunkNanoseconds: median(
      samples.map(\.totalAfterLastChunkNanoseconds)
    ),
    p95TotalAfterLastChunkNanoseconds: percentile95(
      samples.map(\.totalAfterLastChunkNanoseconds)
    )
  )
}

private func median(_ values: [UInt64]) -> UInt64 {
  let sorted = values.sorted()
  guard !sorted.isEmpty else { return 0 }
  let middle = sorted.count / 2
  if sorted.count.isMultiple(of: 2) {
    return sorted[middle - 1] / 2 + sorted[middle] / 2
      + (sorted[middle - 1] % 2 + sorted[middle] % 2) / 2
  }
  return sorted[middle]
}

private func percentile95(_ values: [UInt64]) -> UInt64 {
  let sorted = values.sorted()
  guard !sorted.isEmpty else { return 0 }
  let index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
  return sorted[index]
}
