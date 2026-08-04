import CoreGraphics
import Foundation
import ImageCraftCore
import ImageCraftImageIO
import ImageIO
import UniformTypeIdentifiers

private let progressiveScanCheckpointEvidenceVersion =
  "imagecraft-progressive-scan-checkpoint-v1"

private enum ProgressiveScanCheckpointError: Error {
  case invalidManifest
  case invalidVariant
  case malformedJPEG
  case unsafePath
  case unexpectedOutput
}

private struct ProgressiveScanManifest: Decodable {
  let corpusVersion: String
  let sources: [ProgressiveScanSource]
  let scanScripts: [ProgressiveScanScript]
  let variants: [ProgressiveScanVariant]
}

private struct ProgressiveScanSource: Decodable {
  let id: String
  let description: String
  let contentClass: String
  let width: Int
  let height: Int
}

private struct ProgressiveScanScript: Decodable {
  let id: String
  let scanCount: Int
}

private struct ProgressiveScanVariant: Decodable {
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

private struct JPEGScanBoundary {
  let scan: Int
  let entropyStartOffset: Int
  let entropyEndMarkerStartOffset: Int
  let terminatingMarker: UInt8
  let terminatingMarkerCodeEndOffset: Int
  let immediateFollowingSegmentEndOffset: Int
  var nextScanEntropyStartOffset: Int?
}

private struct PrefixCheckpoint {
  let offset: Int
  let labels: [String]
}

private struct ScanCheckpointAttempt: Codable, Equatable {
  let sourceStatusRawValue: Int32
  let frameStatusRawValue: Int32
  let propertiesAvailable: Bool
  let rasterAvailable: Bool
  let outputPixelWidth: Int?
  let outputPixelHeight: Int?
  let pixelRGBSHA256: String?
  let metricsAgainstFinal: ProgressiveCorpusPixelErrorMetrics?
}

private struct ScanCheckpointObservation: Codable, Equatable {
  let offset: Int
  let encodedByteFractionPPM: Int
  let labels: [String]
  let freshSource: ScanCheckpointAttempt
  let sequentialSource: ScanCheckpointAttempt
}

private struct ScanBoundaryObservation: Codable, Equatable {
  let scan: Int
  let entropyStartOffset: Int
  let entropyEndMarkerStartOffset: Int
  let terminatingMarkerHex: String
  let terminatingMarkerCodeEndOffset: Int
  let immediateFollowingSegmentEndOffset: Int
  let nextScanEntropyStartOffset: Int?
  let checkpoints: [ScanCheckpointObservation]
}

private struct ProgressiveScanCheckpointEvidenceReport: Codable {
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
  let declaredScanCount: Int
  let encodedByteCount: Int
  let encodedSHA256: String
  let sourcePixelWidth: Int
  let sourcePixelHeight: Int
  let outputPixelWidth: Int
  let outputPixelHeight: Int
  let finalPixelRGBSHA256: String
  let scans: [ScanBoundaryObservation]
}

func writeProgressiveScanCheckpointEvidence(
  manifestURL: URL,
  variantID: String,
) throws {
  let manifestData = try Data(contentsOf: manifestURL)
  let manifest = try JSONDecoder().decode(ProgressiveScanManifest.self, from: manifestData)
  guard manifest.corpusVersion == "progressive-real-photo-v1",
        let variant = manifest.variants.first(where: { $0.id == variantID }),
        let source = manifest.sources.first(where: { $0.id == variant.sourceID }),
        let scanScript = manifest.scanScripts.first(where: { $0.id == variant.scanScriptID }),
        source.width == variant.width,
        source.height == variant.height,
        scanScript.scanCount == variant.scanCount
  else {
    throw ProgressiveScanCheckpointError.invalidManifest
  }

  let root = manifestURL.deletingLastPathComponent().standardizedFileURL
  let encodedURL = root.appendingPathComponent(variant.file).standardizedFileURL
  guard encodedURL.path == root.path || encodedURL.path.hasPrefix(root.path + "/") else {
    throw ProgressiveScanCheckpointError.unsafePath
  }
  let encoded = try Data(contentsOf: encodedURL)
  guard encoded.count == variant.byteCount, sha256(encoded) == variant.sha256 else {
    throw ProgressiveScanCheckpointError.invalidVariant
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
  let boundaries = try parseJPEGScanBoundaries(encoded)
  guard boundaries.count == variant.scanCount else {
    throw ProgressiveScanCheckpointError.unexpectedOutput
  }

  let sequentialSource = try makeIncrementalJPEGSource()
  var sequentialOffset = 0
  var scanObservations: [ScanBoundaryObservation] = []
  for boundary in boundaries {
    let checkpoints = prefixCheckpoints(for: boundary, encodedByteCount: encoded.count)
    var observations: [ScanCheckpointObservation] = []
    for checkpoint in checkpoints {
      let prefix = encoded.prefix(checkpoint.offset)
      let freshSource = try makeIncrementalJPEGSource()
      CGImageSourceUpdateData(freshSource, Data(prefix) as CFData, false)
      let freshAttempt = try observeCheckpoint(
        source: freshSource,
        finalRGB: finalRGB,
        expectedWidth: final.pixelWidth,
        expectedHeight: final.pixelHeight,
      )

      guard checkpoint.offset >= sequentialOffset else {
        throw ProgressiveScanCheckpointError.unexpectedOutput
      }
      CGImageSourceUpdateData(sequentialSource, Data(prefix) as CFData, false)
      sequentialOffset = checkpoint.offset
      let sequentialAttempt = try observeCheckpoint(
        source: sequentialSource,
        finalRGB: finalRGB,
        expectedWidth: final.pixelWidth,
        expectedHeight: final.pixelHeight,
      )
      observations.append(
        ScanCheckpointObservation(
          offset: checkpoint.offset,
          encodedByteFractionPPM: progressiveCorpusFractionPPM(
            checkpoint.offset,
            denominator: encoded.count,
          ),
          labels: checkpoint.labels,
          freshSource: freshAttempt,
          sequentialSource: sequentialAttempt,
        ),
      )
    }
    scanObservations.append(
      ScanBoundaryObservation(
        scan: boundary.scan,
        entropyStartOffset: boundary.entropyStartOffset,
        entropyEndMarkerStartOffset: boundary.entropyEndMarkerStartOffset,
        terminatingMarkerHex: String(format: "0x%02X", boundary.terminatingMarker),
        terminatingMarkerCodeEndOffset: boundary.terminatingMarkerCodeEndOffset,
        immediateFollowingSegmentEndOffset: boundary.immediateFollowingSegmentEndOffset,
        nextScanEntropyStartOffset: boundary.nextScanEntropyStartOffset,
        checkpoints: observations,
      ),
    )
  }

  let report = ProgressiveScanCheckpointEvidenceReport(
    schemaVersion: 1,
    evidenceVersion: progressiveScanCheckpointEvidenceVersion,
    runtime: .capture(),
    decoderFingerprint: decoder.codecDescriptor.cacheFingerprint,
    environment: capturePerformanceEnvironment(),
    buildConfiguration: "release",
    manifestSHA256: sha256(manifestData),
    corpusVersion: manifest.corpusVersion,
    caseID: variant.id,
    sourceID: source.id,
    sourceDescription: source.description,
    contentClass: source.contentClass,
    scanScriptID: scanScript.id,
    declaredScanCount: scanScript.scanCount,
    encodedByteCount: encoded.count,
    encodedSHA256: variant.sha256,
    sourcePixelWidth: source.width,
    sourcePixelHeight: source.height,
    outputPixelWidth: final.pixelWidth,
    outputPixelHeight: final.pixelHeight,
    finalPixelRGBSHA256: sha256(finalRGB),
    scans: scanObservations,
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  try FileHandle.standardOutput.write(encoder.encode(report))
  FileHandle.standardOutput.write(Data([0x0A]))
}

private func makeIncrementalJPEGSource() throws -> CGImageSource {
  let options: [CFString: Any] = [
    kCGImageSourceShouldCache: false,
    kCGImageSourceTypeIdentifierHint: UTType.jpeg.identifier,
  ]
  return CGImageSourceCreateIncremental(options as CFDictionary)
}

private func observeCheckpoint(
  source: CGImageSource,
  finalRGB: Data,
  expectedWidth: Int,
  expectedHeight: Int,
) throws -> ScanCheckpointAttempt {
  let sourceStatus = CGImageSourceGetStatus(source).rawValue
  let frameStatus = CGImageSourceGetStatusAtIndex(source, 0).rawValue
  let propertiesAvailable = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil
  let options: [CFString: Any] = [
    kCGImageSourceCreateThumbnailFromImageAlways: true,
    kCGImageSourceCreateThumbnailWithTransform: true,
    kCGImageSourceThumbnailMaxPixelSize: 512,
    kCGImageSourceShouldCacheImmediately: true,
  ]
  guard let raster = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
    return ScanCheckpointAttempt(
      sourceStatusRawValue: sourceStatus,
      frameStatusRawValue: frameStatus,
      propertiesAvailable: propertiesAvailable,
      rasterAvailable: false,
      outputPixelWidth: nil,
      outputPixelHeight: nil,
      pixelRGBSHA256: nil,
      metricsAgainstFinal: nil,
    )
  }
  guard raster.width == expectedWidth, raster.height == expectedHeight else {
    throw ProgressiveScanCheckpointError.unexpectedOutput
  }
  let rgb = try rgbData(from: raster)
  return try ScanCheckpointAttempt(
    sourceStatusRawValue: sourceStatus,
    frameStatusRawValue: frameStatus,
    propertiesAvailable: propertiesAvailable,
    rasterAvailable: true,
    outputPixelWidth: raster.width,
    outputPixelHeight: raster.height,
    pixelRGBSHA256: sha256(rgb),
    metricsAgainstFinal: progressiveCorpusPixelMetrics(
      reference: finalRGB,
      candidate: rgb,
    ),
  )
}

private func prefixCheckpoints(
  for boundary: JPEGScanBoundary,
  encodedByteCount: Int,
) -> [PrefixCheckpoint] {
  var labelsByOffset: [Int: [String]] = [:]
  func add(_ offset: Int?, label: String) {
    guard let offset, offset > 0, offset <= encodedByteCount else { return }
    labelsByOffset[offset, default: []].append(label)
  }
  add(boundary.entropyEndMarkerStartOffset, label: "entropy-end-before-marker")
  add(boundary.terminatingMarkerCodeEndOffset, label: "terminating-marker-code-end")
  add(boundary.immediateFollowingSegmentEndOffset, label: "immediate-following-segment-end")
  add(boundary.nextScanEntropyStartOffset, label: "next-scan-entropy-start")
  return labelsByOffset.keys.sorted().map { offset in
    PrefixCheckpoint(offset: offset, labels: labelsByOffset[offset, default: []].sorted())
  }
}

private func parseJPEGScanBoundaries(_ data: Data) throws -> [JPEGScanBoundary] {
  guard data.count >= 4, data[0] == 0xFF, data[1] == 0xD8 else {
    throw ProgressiveScanCheckpointError.malformedJPEG
  }
  var boundaries: [JPEGScanBoundary] = []
  var offset = 2
  var insideScan = false
  var currentScan = 0
  var currentEntropyStart = 0
  var pendingBoundaryIndex: Int?

  while offset < data.count {
    if insideScan {
      guard let marker = nextEntropyMarker(data, offset: &offset) else {
        throw ProgressiveScanCheckpointError.malformedJPEG
      }
      let immediateEnd = try segmentEnd(
        data,
        marker: marker.value,
        payloadOffset: marker.payloadOffset,
      )
      boundaries.append(
        JPEGScanBoundary(
          scan: currentScan,
          entropyStartOffset: currentEntropyStart,
          entropyEndMarkerStartOffset: marker.start,
          terminatingMarker: marker.value,
          terminatingMarkerCodeEndOffset: marker.payloadOffset,
          immediateFollowingSegmentEndOffset: immediateEnd,
          nextScanEntropyStartOffset: nil,
        ),
      )
      pendingBoundaryIndex = boundaries.count - 1
      insideScan = false
      offset = marker.start
      continue
    }

    guard let marker = nextMarker(data, offset: &offset) else {
      throw ProgressiveScanCheckpointError.malformedJPEG
    }
    switch marker.value {
    case 0xD8:
      throw ProgressiveScanCheckpointError.malformedJPEG
    case 0xD9:
      if let index = pendingBoundaryIndex {
        boundaries[index].nextScanEntropyStartOffset = marker.payloadOffset
        pendingBoundaryIndex = nil
      }
      guard offset == data.count else {
        throw ProgressiveScanCheckpointError.malformedJPEG
      }
      return boundaries
    case 0x01, 0xD0 ... 0xD7:
      offset = marker.payloadOffset
    default:
      let end = try segmentEnd(
        data,
        marker: marker.value,
        payloadOffset: marker.payloadOffset,
      )
      offset = end
      if marker.value == 0xDA {
        if let index = pendingBoundaryIndex {
          boundaries[index].nextScanEntropyStartOffset = end
          pendingBoundaryIndex = nil
        }
        currentScan += 1
        currentEntropyStart = end
        insideScan = true
      }
    }
  }
  throw ProgressiveScanCheckpointError.malformedJPEG
}

private func nextEntropyMarker(
  _ data: Data,
  offset: inout Int,
) -> (start: Int, value: UInt8, payloadOffset: Int)? {
  while offset < data.count {
    guard data[offset] == 0xFF else {
      offset += 1
      continue
    }
    let markerStart = offset
    var cursor = offset + 1
    while cursor < data.count, data[cursor] == 0xFF {
      cursor += 1
    }
    guard cursor < data.count else { return nil }
    let marker = data[cursor]
    if marker == 0x00 || (0xD0 ... 0xD7).contains(marker) {
      offset = cursor + 1
      continue
    }
    return (markerStart, marker, cursor + 1)
  }
  return nil
}

private func nextMarker(
  _ data: Data,
  offset: inout Int,
) -> (start: Int, value: UInt8, payloadOffset: Int)? {
  while offset < data.count {
    while offset < data.count, data[offset] != 0xFF {
      offset += 1
    }
    guard offset < data.count else { return nil }
    let markerStart = offset
    var cursor = offset + 1
    while cursor < data.count, data[cursor] == 0xFF {
      cursor += 1
    }
    guard cursor < data.count else { return nil }
    let marker = data[cursor]
    offset = cursor + 1
    if marker == 0x00 {
      continue
    }
    return (markerStart, marker, cursor + 1)
  }
  return nil
}

private func segmentEnd(
  _ data: Data,
  marker: UInt8,
  payloadOffset: Int,
) throws -> Int {
  if marker == 0xD8 || marker == 0xD9 || marker == 0x01 || (0xD0 ... 0xD7).contains(marker) {
    return payloadOffset
  }
  guard payloadOffset + 1 < data.count else {
    throw ProgressiveScanCheckpointError.malformedJPEG
  }
  let length = Int(data[payloadOffset]) << 8 | Int(data[payloadOffset + 1])
  guard length >= 2 else {
    throw ProgressiveScanCheckpointError.malformedJPEG
  }
  let result = payloadOffset.addingReportingOverflow(length)
  guard !result.overflow, result.partialValue <= data.count else {
    throw ProgressiveScanCheckpointError.malformedJPEG
  }
  return result.partialValue
}
