import Compression
import CoreGraphics
import Foundation
import ImageCraftCore
import ImageCraftImageIO

private struct DerivedRasterDurationSummary: Codable {
  let medianNanoseconds: UInt64
  let p95Nanoseconds: UInt64
  let samplesNanoseconds: [UInt64]
}

private struct DerivedRasterTargetEvidence: Codable {
  let requestedWidth: Int
  let requestedHeight: Int
  let outputWidth: Int
  let outputHeight: Int
  let directPixelRGBSHA256: String
  let derivedPNGPixelRGBSHA256: String
  let derivedLZFSEPixelRGBSHA256: String
  let derivedAdaptiveLZFSEPixelRGBSHA256: String
  let pngPixelsEqual: Bool
  let lzfsePixelsEqual: Bool
  let adaptiveLZFSEPixelsEqual: Bool
  let derivedPNGByteCount: Int
  let derivedPNGSHA256: String
  let derivedLZFSEByteCount: Int
  let derivedLZFSESHA256: String
  let derivedAdaptiveLZFSEByteCount: Int
  let derivedAdaptiveLZFSESHA256: String
  let rawRGBByteCount: Int
  let directOriginalDecode: DerivedRasterDurationSummary
  let cachedImageMaterialization: DerivedRasterDurationSummary
  let derivedPNGDecode: DerivedRasterDurationSummary
  let derivedLZFSEDecode: DerivedRasterDurationSummary
  let derivedAdaptiveLZFSEDecode: DerivedRasterDurationSummary
  let derivedPNGCreationDecodeAndEncode: DerivedRasterDurationSummary
  let derivedLZFSECreationDecodeDrawAndCompress: DerivedRasterDurationSummary
  let derivedAdaptiveLZFSECreationDecodeDrawFilterAndCompress:
    DerivedRasterDurationSummary
}

private struct DerivedRasterPrototypeReport: Codable {
  let schemaVersion: UInt16
  let evidenceVersion: String
  let runtime: ImageIORuntimeFingerprint
  let inputByteCount: Int
  let inputSHA256: String
  let inputPixelWidth: Int
  let inputPixelHeight: Int
  let contentMode: String
  let colorPolicy: String
  let warmupIterations: Int
  let measuredIterations: Int
  let targetSpecificDerivedPNGByteCount: Int
  let originalPlusDerivedPNGByteCount: Int
  let originalPlusDerivedPNGToOriginalPermille: Int
  let targetSpecificDerivedLZFSEByteCount: Int
  let originalPlusDerivedLZFSEByteCount: Int
  let originalPlusDerivedLZFSEToOriginalPermille: Int
  let targetSpecificDerivedAdaptiveLZFSEByteCount: Int
  let originalPlusDerivedAdaptiveLZFSEByteCount: Int
  let originalPlusDerivedAdaptiveLZFSEToOriginalPermille: Int
  let allTargetPNGPixelsEqual: Bool
  let allTargetLZFSEPixelsEqual: Bool
  let allTargetAdaptiveLZFSEPixelsEqual: Bool
  let targets: [DerivedRasterTargetEvidence]
}

func writeDerivedRasterPrototypeEvidence(
  input: URL,
  iterations: Int
) throws {
  guard (1...50).contains(iterations) else { throw EvidenceError.invalidArguments }
  let data = try Data(contentsOf: input)
  guard !data.isEmpty else { throw EvidenceError.invalidArguments }
  let decoder = ImageIOImageDecoder()
  let encoder = ImageIOImageEncoder()
  let inputLimits = DecodeLimits(
    maximumEncodedBytes: max(data.count, 1),
    maximumDimension: 16_384,
    maximumPixelCount: 100_000_000,
    maximumFrameCount: 1,
    maximumMetadataBytes: 4 * 1_024 * 1_024,
    maximumAuxiliaryAttachments: 0,
    allowedFormats: [.jpeg]
  )
  let probe = try decoder.probe(data: data, limits: inputLimits)
  let targetPairs = [(390, 260), (780, 520), (1_170, 780)]
  let warmups = 2
  var results: [DerivedRasterTargetEvidence] = []

  for (requestedWidth, requestedHeight) in targetPairs {
    let requestedTarget = try TargetPixels(width: requestedWidth, height: requestedHeight)
    let directRequest = ImageDecodeRequest(
      target: requestedTarget,
      contentMode: .fit,
      colorPolicy: .convertToSRGB
    )
    let directReference = try decoder.decode(
      data: data,
      probe: probe,
      request: directRequest,
      limits: inputLimits
    )
    let directRGB = try rgbData(from: directReference.cgImage)
    let lzfse = try derivedRasterLZFSECompress(directRGB)
    let lzfseRoundTrip = try derivedRasterLZFSEDecompress(
      lzfse,
      expectedByteCount: directRGB.count
    )
    let lzfseReference = try derivedRasterRGBImage(
      rgb: lzfseRoundTrip,
      width: directReference.pixelWidth,
      height: directReference.pixelHeight
    )
    let adaptiveFiltered = derivedRasterAdaptiveRowFilter(
      directRGB,
      width: directReference.pixelWidth,
      height: directReference.pixelHeight
    )
    let adaptiveLZFSE = try derivedRasterLZFSECompress(adaptiveFiltered)
    let adaptiveRoundTrip = try derivedRasterAdaptiveRowUnfilter(
      try derivedRasterLZFSEDecompress(
        adaptiveLZFSE,
        expectedByteCount: adaptiveFiltered.count
      ),
      width: directReference.pixelWidth,
      height: directReference.pixelHeight
    )
    let adaptiveReference = try derivedRasterRGBImage(
      rgb: adaptiveRoundTrip,
      width: directReference.pixelWidth,
      height: directReference.pixelHeight
    )

    let pngRequest = try ImageEncodeRequest.png(
      colorPolicy: .convertToSRGB,
      metadataPolicy: .discard,
      alphaPolicy: .preserve
    )
    let encodeLimits = EncodeLimits(maximumEncodedBytes: 128 * 1_024 * 1_024)
    let derivedPNG = try encoder.encode(
      image: directReference.cgImage,
      request: pngRequest,
      limits: encodeLimits
    )
    let derivedLimits = DecodeLimits(
      maximumEncodedBytes: max(derivedPNG.byteCount, 1),
      maximumDimension: 16_384,
      maximumPixelCount: 100_000_000,
      maximumFrameCount: 1,
      maximumMetadataBytes: 4 * 1_024 * 1_024,
      maximumAuxiliaryAttachments: 0,
      allowedFormats: [.png]
    )
    let exactTarget = try TargetPixels(
      width: directReference.pixelWidth,
      height: directReference.pixelHeight
    )
    let derivedRequest = ImageDecodeRequest(
      target: exactTarget,
      contentMode: .fit,
      colorPolicy: .convertToSRGB
    )
    let derivedProbe = try decoder.probe(data: derivedPNG.data, limits: derivedLimits)
    let derivedReference = try decoder.decode(
      data: derivedPNG.data,
      probe: derivedProbe,
      request: derivedRequest,
      limits: derivedLimits
    )
    let directHash = sha256(directRGB)
    let pngHash = sha256(try rgbData(from: derivedReference.cgImage))
    let lzfseHash = sha256(try rgbData(from: lzfseReference))
    let adaptiveHash = sha256(try rgbData(from: adaptiveReference))

    var directSamples: [UInt64] = []
    var cachedMaterializationSamples: [UInt64] = []
    var pngSamples: [UInt64] = []
    var lzfseSamples: [UInt64] = []
    var adaptiveSamples: [UInt64] = []
    var pngCreationSamples: [UInt64] = []
    var lzfseCreationSamples: [UInt64] = []
    var adaptiveCreationSamples: [UInt64] = []
    for index in 0..<(warmups + iterations) {
      var durations = [UInt64](repeating: 0, count: 5)
      for offset in 0..<5 {
        let operation = (index + offset) % 5
        switch operation {
        case 0:
          durations[operation] = try derivedRasterMeasure {
            _ = try decoder.decode(
              data: data, probe: probe, request: directRequest, limits: inputLimits
            )
          }
        case 1:
          durations[operation] = try derivedRasterMeasure {
            _ = try derivedRasterMaterializePixels(directReference.cgImage)
          }
        case 2:
          durations[operation] = try derivedRasterMeasure {
            _ = try decoder.decode(
              data: derivedPNG.data,
              probe: derivedProbe,
              request: derivedRequest,
              limits: derivedLimits
            )
          }
        case 3:
          durations[operation] = try derivedRasterMeasure {
            let rgb = try derivedRasterLZFSEDecompress(
              lzfse, expectedByteCount: directRGB.count
            )
            _ = try derivedRasterRGBImage(
              rgb: rgb,
              width: directReference.pixelWidth,
              height: directReference.pixelHeight
            )
          }
        default:
          durations[operation] = try derivedRasterMeasure {
            let filtered = try derivedRasterLZFSEDecompress(
              adaptiveLZFSE, expectedByteCount: adaptiveFiltered.count
            )
            let rgb = try derivedRasterAdaptiveRowUnfilter(
              filtered,
              width: directReference.pixelWidth,
              height: directReference.pixelHeight
            )
            _ = try derivedRasterRGBImage(
              rgb: rgb,
              width: directReference.pixelWidth,
              height: directReference.pixelHeight
            )
          }
        }
      }
      let pngCreationDuration = try derivedRasterMeasure {
        let image = try decoder.decode(
          data: data, probe: probe, request: directRequest, limits: inputLimits
        )
        _ = try encoder.encode(
          image: image.cgImage, request: pngRequest, limits: encodeLimits
        )
      }
      let lzfseCreationDuration = try derivedRasterMeasure {
        let image = try decoder.decode(
          data: data, probe: probe, request: directRequest, limits: inputLimits
        )
        let rgb = try rgbData(from: image.cgImage)
        _ = try derivedRasterLZFSECompress(rgb)
      }
      let adaptiveCreationDuration = try derivedRasterMeasure {
        let image = try decoder.decode(
          data: data, probe: probe, request: directRequest, limits: inputLimits
        )
        let rgb = try rgbData(from: image.cgImage)
        let filtered = derivedRasterAdaptiveRowFilter(
          rgb,
          width: image.pixelWidth,
          height: image.pixelHeight
        )
        _ = try derivedRasterLZFSECompress(filtered)
      }
      if index >= warmups {
        directSamples.append(durations[0])
        cachedMaterializationSamples.append(durations[1])
        pngSamples.append(durations[2])
        lzfseSamples.append(durations[3])
        adaptiveSamples.append(durations[4])
        pngCreationSamples.append(pngCreationDuration)
        lzfseCreationSamples.append(lzfseCreationDuration)
        adaptiveCreationSamples.append(adaptiveCreationDuration)
      }
    }

    results.append(
      DerivedRasterTargetEvidence(
        requestedWidth: requestedWidth,
        requestedHeight: requestedHeight,
        outputWidth: directReference.pixelWidth,
        outputHeight: directReference.pixelHeight,
        directPixelRGBSHA256: directHash,
        derivedPNGPixelRGBSHA256: pngHash,
        derivedLZFSEPixelRGBSHA256: lzfseHash,
        derivedAdaptiveLZFSEPixelRGBSHA256: adaptiveHash,
        pngPixelsEqual: directHash == pngHash,
        lzfsePixelsEqual: directHash == lzfseHash,
        adaptiveLZFSEPixelsEqual: directHash == adaptiveHash,
        derivedPNGByteCount: derivedPNG.byteCount,
        derivedPNGSHA256: sha256(derivedPNG.data),
        derivedLZFSEByteCount: lzfse.count,
        derivedLZFSESHA256: sha256(lzfse),
        derivedAdaptiveLZFSEByteCount: adaptiveLZFSE.count,
        derivedAdaptiveLZFSESHA256: sha256(adaptiveLZFSE),
        rawRGBByteCount: directRGB.count,
        directOriginalDecode: derivedRasterSummary(directSamples),
        cachedImageMaterialization: derivedRasterSummary(cachedMaterializationSamples),
        derivedPNGDecode: derivedRasterSummary(pngSamples),
        derivedLZFSEDecode: derivedRasterSummary(lzfseSamples),
        derivedAdaptiveLZFSEDecode: derivedRasterSummary(adaptiveSamples),
        derivedPNGCreationDecodeAndEncode: derivedRasterSummary(pngCreationSamples),
        derivedLZFSECreationDecodeDrawAndCompress: derivedRasterSummary(
          lzfseCreationSamples
        ),
        derivedAdaptiveLZFSECreationDecodeDrawFilterAndCompress:
          derivedRasterSummary(adaptiveCreationSamples)
      )
    )
  }

  let pngBytes = results.reduce(0) { $0 + $1.derivedPNGByteCount }
  let lzfseBytes = results.reduce(0) { $0 + $1.derivedLZFSEByteCount }
  let adaptiveBytes = results.reduce(0) { $0 + $1.derivedAdaptiveLZFSEByteCount }
  let pngTotalBytes = data.count + pngBytes
  let lzfseTotalBytes = data.count + lzfseBytes
  let adaptiveTotalBytes = data.count + adaptiveBytes
  let report = DerivedRasterPrototypeReport(
    schemaVersion: 5,
    evidenceVersion: "imagecraft-target-derived-raster-prototype-v5",
    runtime: .capture(),
    inputByteCount: data.count,
    inputSHA256: sha256(data),
    inputPixelWidth: probe.pixelWidth,
    inputPixelHeight: probe.pixelHeight,
    contentMode: "fit",
    colorPolicy: "convert-to-srgb",
    warmupIterations: warmups,
    measuredIterations: iterations,
    targetSpecificDerivedPNGByteCount: pngBytes,
    originalPlusDerivedPNGByteCount: pngTotalBytes,
    originalPlusDerivedPNGToOriginalPermille: Int(
      (UInt64(pngTotalBytes) * 1_000) / UInt64(max(data.count, 1))
    ),
    targetSpecificDerivedLZFSEByteCount: lzfseBytes,
    originalPlusDerivedLZFSEByteCount: lzfseTotalBytes,
    originalPlusDerivedLZFSEToOriginalPermille: Int(
      (UInt64(lzfseTotalBytes) * 1_000) / UInt64(max(data.count, 1))
    ),
    targetSpecificDerivedAdaptiveLZFSEByteCount: adaptiveBytes,
    originalPlusDerivedAdaptiveLZFSEByteCount: adaptiveTotalBytes,
    originalPlusDerivedAdaptiveLZFSEToOriginalPermille: Int(
      (UInt64(adaptiveTotalBytes) * 1_000) / UInt64(max(data.count, 1))
    ),
    allTargetPNGPixelsEqual: results.allSatisfy(\.pngPixelsEqual),
    allTargetLZFSEPixelsEqual: results.allSatisfy(\.lzfsePixelsEqual),
    allTargetAdaptiveLZFSEPixelsEqual: results.allSatisfy(\.adaptiveLZFSEPixelsEqual),
    targets: results
  )
  let json = JSONEncoder()
  json.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  FileHandle.standardOutput.write(try json.encode(report))
  FileHandle.standardOutput.write(Data([0x0A]))
}

private func derivedRasterMaterializePixels(_ image: CGImage) throws -> UInt8 {
  guard image.width > 0, image.height > 0,
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
  else { throw EvidenceError.pixelConversionFailed }
  let bytesPerRow = image.width * 4
  var pixels = Data(count: bytesPerRow * image.height)
  let drew = pixels.withUnsafeMutableBytes { storage -> Bool in
    guard let baseAddress = storage.baseAddress,
      let context = CGContext(
        data: baseAddress,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue
      )
    else { return false }
    context.setBlendMode(.copy)
    context.interpolationQuality = .none
    context.draw(
      image,
      in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
    )
    return true
  }
  guard drew else { throw EvidenceError.pixelConversionFailed }
  return pixels.withUnsafeBytes { storage in
    guard let first = storage.first, let last = storage.last else { return 0 }
    return first &+ last
  }
}

private func derivedRasterMeasure(_ operation: () throws -> Void) rethrows -> UInt64 {
  let started = DispatchTime.now().uptimeNanoseconds
  try autoreleasepool(invoking: operation)
  return DispatchTime.now().uptimeNanoseconds &- started
}

private func derivedRasterSummary(
  _ samples: [UInt64]
) -> DerivedRasterDurationSummary {
  let sorted = samples.sorted()
  let middle = sorted.count / 2
  let median: UInt64
  if sorted.count.isMultiple(of: 2) {
    median = sorted[middle - 1] / 2 + sorted[middle] / 2
      + (sorted[middle - 1] % 2 + sorted[middle] % 2) / 2
  } else {
    median = sorted[middle]
  }
  let p95Index = min(
    sorted.count - 1,
    max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
  )
  return DerivedRasterDurationSummary(
    medianNanoseconds: median,
    p95Nanoseconds: sorted[p95Index],
    samplesNanoseconds: samples
  )
}

private func derivedRasterRGBImage(rgb: Data, width: Int, height: Int) throws -> CGImage {
  guard rgb.count == width * height * 3,
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
    let provider = CGDataProvider(data: rgb as CFData),
    let image = CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 24,
      bytesPerRow: width * 3,
      space: colorSpace,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  else { throw EvidenceError.pixelConversionFailed }
  return image
}

private func derivedRasterAdaptiveRowFilter(
  _ rgb: Data,
  width: Int,
  height: Int
) -> Data {
  precondition(rgb.count == width * height * 3)
  let bytesPerRow = width * 3
  var filtered = Data(count: rgb.count + height)
  filtered.withUnsafeMutableBytes { output in
    rgb.withUnsafeBytes { input in
      let source = input.bindMemory(to: UInt8.self)
      let destination = output.bindMemory(to: UInt8.self)
      for row in 0..<height {
        let sourceStart = row * bytesPerRow
        let destinationStart = row * (bytesPerRow + 1)
        var noneScore = 0
        var subScore = 0
        var upScore = 0
        for column in 0..<bytesPerRow {
          let value = source[sourceStart + column]
          let left = column >= 3 ? source[sourceStart + column - 3] : 0
          let above = row > 0 ? source[sourceStart + column - bytesPerRow] : 0
          noneScore += abs(Int(Int8(bitPattern: value)))
          subScore += abs(Int(Int8(bitPattern: value &- left)))
          upScore += abs(Int(Int8(bitPattern: value &- above)))
        }
        let filter: UInt8
        if subScore <= noneScore && subScore <= upScore {
          filter = 1
        } else if upScore <= noneScore {
          filter = 2
        } else {
          filter = 0
        }
        destination[destinationStart] = filter
        for column in 0..<bytesPerRow {
          let value = source[sourceStart + column]
          switch filter {
          case 1:
            let left = column >= 3 ? source[sourceStart + column - 3] : 0
            destination[destinationStart + 1 + column] = value &- left
          case 2:
            let above = row > 0 ? source[sourceStart + column - bytesPerRow] : 0
            destination[destinationStart + 1 + column] = value &- above
          default:
            destination[destinationStart + 1 + column] = value
          }
        }
      }
    }
  }
  return filtered
}

private func derivedRasterAdaptiveRowUnfilter(
  _ filtered: Data,
  width: Int,
  height: Int
) throws -> Data {
  let bytesPerRow = width * 3
  guard filtered.count == (bytesPerRow + 1) * height else {
    throw EvidenceError.pixelConversionFailed
  }
  var rgb = Data(count: bytesPerRow * height)
  var valid = true
  rgb.withUnsafeMutableBytes { output in
    filtered.withUnsafeBytes { input in
      let source = input.bindMemory(to: UInt8.self)
      let destination = output.bindMemory(to: UInt8.self)
      for row in 0..<height {
        let sourceStart = row * (bytesPerRow + 1)
        let destinationStart = row * bytesPerRow
        let filter = source[sourceStart]
        if filter > 2 {
          valid = false
          return
        }
        for column in 0..<bytesPerRow {
          let residual = source[sourceStart + 1 + column]
          switch filter {
          case 1:
            let left = column >= 3 ? destination[destinationStart + column - 3] : 0
            destination[destinationStart + column] = residual &+ left
          case 2:
            let above = row > 0 ? destination[destinationStart + column - bytesPerRow] : 0
            destination[destinationStart + column] = residual &+ above
          default:
            destination[destinationStart + column] = residual
          }
        }
      }
    }
  }
  guard valid else { throw EvidenceError.pixelConversionFailed }
  return rgb
}

private func derivedRasterLZFSECompress(_ source: Data) throws -> Data {
  var capacity = max(1_024, source.count + source.count / 8 + 65_536)
  for _ in 0..<4 {
    var destination = Data(count: capacity)
    let written = destination.withUnsafeMutableBytes { output in
      source.withUnsafeBytes { input in
        guard let outputBase = output.bindMemory(to: UInt8.self).baseAddress,
          let inputBase = input.bindMemory(to: UInt8.self).baseAddress
        else { return 0 }
        return compression_encode_buffer(
          outputBase,
          capacity,
          inputBase,
          source.count,
          nil,
          COMPRESSION_LZFSE
        )
      }
    }
    if written > 0 {
      destination.removeSubrange(written..<destination.count)
      return destination
    }
    capacity *= 2
  }
  throw EvidenceError.pixelConversionFailed
}

private func derivedRasterLZFSEDecompress(
  _ source: Data,
  expectedByteCount: Int
) throws -> Data {
  var destination = Data(count: expectedByteCount)
  let written = destination.withUnsafeMutableBytes { output in
    source.withUnsafeBytes { input in
      guard let outputBase = output.bindMemory(to: UInt8.self).baseAddress,
        let inputBase = input.bindMemory(to: UInt8.self).baseAddress
      else { return 0 }
      return compression_decode_buffer(
        outputBase,
        expectedByteCount,
        inputBase,
        source.count,
        nil,
        COMPRESSION_LZFSE
      )
    }
  }
  guard written == expectedByteCount else { throw EvidenceError.pixelConversionFailed }
  return destination
}
