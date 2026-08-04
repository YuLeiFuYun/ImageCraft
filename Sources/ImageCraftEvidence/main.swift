import CoreGraphics
import CryptoKit
import Foundation
import ImageCraftCore
import ImageCraftImageIO

struct EvidenceReport: Codable {
  let schemaVersion: UInt16
  let runtime: ImageIORuntimeFingerprint
  let encoderFingerprint: String
  let source: SourceDescription
  let outputs: [OutputEvidence]
}

struct SourceDescription: Codable {
  let generator: String
  let width: Int
  let height: Int
  let colorSpace: String
  let alphaMode: String
}

struct OutputEvidence: Codable {
  let name: String
  let format: String
  let compression: String
  let byteCount: Int
  let sha256: String
  let jpegStructure: JPEGStructure?
}

struct JPEGStructure: Codable {
  let frameMarker: String
  let samplePrecision: Int
  let width: Int
  let height: Int
  let components: [JPEGComponent]
  let quantizationPayloadSHA256: String
}

struct JPEGComponent: Codable {
  let identifier: Int
  let horizontalSampling: Int
  let verticalSampling: Int
  let quantizationTable: Int
}

enum EvidenceCommand {
  case report(artifactDirectory: URL?)
  case decode(input: URL, output: URL)
  case benchmark(caseID: String, iterations: Int)
  case progressiveTimeline(caseID: String, iterations: Int)
  case progressiveQuality(caseID: String)
  case progressivePhotoCorpus(manifest: URL, variantID: String, chunkSize: Int)
}

enum EvidenceError: Error {
  case imageCreationFailed
  case invalidArguments
  case malformedJPEG
  case pixelConversionFailed
}

try run(command: parseCommand(CommandLine.arguments))

func parseCommand(_ arguments: [String]) throws -> EvidenceCommand {
  let parameters = Array(arguments.dropFirst())
  if parameters.isEmpty {
    return .report(artifactDirectory: nil)
  }
  if parameters.count == 2, parameters[0] == "--artifacts" {
    return .report(
      artifactDirectory: URL(fileURLWithPath: parameters[1], isDirectory: true)
    )
  }
  if parameters.count == 3, parameters[0] == "--decode" {
    return .decode(
      input: URL(fileURLWithPath: parameters[1]),
      output: URL(fileURLWithPath: parameters[2])
    )
  }
  if parameters.count == 4,
    parameters[0] == "--benchmark-case",
    parameters[2] == "--iterations",
    let iterations = Int(parameters[3])
  {
    return .benchmark(caseID: parameters[1], iterations: iterations)
  }
  if parameters.count == 4,
    parameters[0] == "--progressive-timeline-case",
    parameters[2] == "--iterations",
    let iterations = Int(parameters[3])
  {
    return .progressiveTimeline(caseID: parameters[1], iterations: iterations)
  }
  if parameters.count == 2, parameters[0] == "--progressive-quality-case" {
    return .progressiveQuality(caseID: parameters[1])
  }
  if parameters.count == 4,
    parameters[0] == "--progressive-photo-case",
    let chunkSize = Int(parameters[3])
  {
    return .progressivePhotoCorpus(
      manifest: URL(fileURLWithPath: parameters[1]),
      variantID: parameters[2],
      chunkSize: chunkSize
    )
  }
  throw EvidenceError.invalidArguments
}

func run(command: EvidenceCommand) throws {
  switch command {
  case .report(let artifactDirectory):
    try writeReport(artifactDirectory: artifactDirectory)
  case .decode(let input, let output):
    try decodeImageToPPM(input: input, output: output)
  case .benchmark(let caseID, let iterations):
    try writePerformanceBenchmark(caseID: caseID, iterations: iterations)
  case .progressiveTimeline(let caseID, let iterations):
    try writeProgressiveTimelineBenchmark(caseID: caseID, iterations: iterations)
  case .progressiveQuality(let caseID):
    try writeProgressiveQualityEvidence(caseID: caseID)
  case .progressivePhotoCorpus(let manifest, let variantID, let chunkSize):
    try writeProgressivePhotoCorpusEvidence(
      manifestURL: manifest,
      variantID: variantID,
      chunkSize: chunkSize
    )
  }
}

func writeReport(artifactDirectory: URL?) throws {
  let width = 96
  let height = 64
  let sourceRGB = makePatternRGBData(width: width, height: height)
  let image = try makePatternImage(width: width, height: height, rgb: sourceRGB)
  let encoder = ImageIOImageEncoder()
  var outputs: [OutputEvidence] = []
  var artifactData: [(name: String, data: Data)] = []

  let pngRequest = try ImageEncodeRequest.png(
    colorPolicy: .convertToSRGB,
    metadataPolicy: .discard,
    alphaPolicy: .reject
  )
  let png = try encoder.encode(image: image, request: pngRequest, limits: .coreV1)
  outputs.append(
    OutputEvidence(
      name: "png-lossless",
      format: png.format.rawValue,
      compression: "lossless",
      byteCount: png.byteCount,
      sha256: sha256(png.data),
      jpegStructure: nil
    )
  )
  artifactData.append((name: "imageio.png", data: png.data))

  for qualityValue in [0.25, 0.5, 0.75, 0.9] {
    let quality = try ImageEncodeQuality(rawValue: qualityValue)
    let request = try ImageEncodeRequest.jpeg(
      quality: quality,
      colorPolicy: .convertToSRGB,
      metadataPolicy: .discard,
      alphaPolicy: .reject
    )
    let encoded = try encoder.encode(image: image, request: request, limits: .coreV1)
    let qualityName = String(format: "%.2f", qualityValue)
    outputs.append(
      OutputEvidence(
        name: "jpeg-q\(qualityName)",
        format: encoded.format.rawValue,
        compression: "lossy:\(qualityName)",
        byteCount: encoded.byteCount,
        sha256: sha256(encoded.data),
        jpegStructure: try inspectJPEG(encoded.data)
      )
    )
    artifactData.append((name: "imageio-q\(qualityName).jpg", data: encoded.data))
  }

  let report = EvidenceReport(
    schemaVersion: 1,
    runtime: .capture(),
    encoderFingerprint: encoder.encoderDescriptor.cacheFingerprint,
    source: SourceDescription(
      generator: "imagecraft-pattern-v1",
      width: width,
      height: height,
      colorSpace: CGColorSpace.sRGB as String,
      alphaMode: "noneSkipLast"
    ),
    outputs: outputs
  )

  if let artifactDirectory {
    try FileManager.default.createDirectory(
      at: artifactDirectory,
      withIntermediateDirectories: true
    )
    try ppmData(width: width, height: height, rgb: sourceRGB).write(
      to: artifactDirectory.appendingPathComponent("source.ppm"),
      options: .atomic
    )
    for artifact in artifactData {
      try artifact.data.write(
        to: artifactDirectory.appendingPathComponent(artifact.name),
        options: .atomic
      )
    }
  }

  let jsonEncoder = JSONEncoder()
  jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  FileHandle.standardOutput.write(try jsonEncoder.encode(report))
  FileHandle.standardOutput.write(Data([0x0A]))
}

func decodeImageToPPM(input: URL, output: URL) throws {
  let data = try Data(contentsOf: input)
  let decoder = ImageIOImageDecoder()
  let limits = DecodeLimits(
    maximumEncodedBytes: max(data.count, 1),
    maximumDimension: 65_536,
    maximumPixelCount: 1_000_000_000,
    maximumFrameCount: 1,
    maximumMetadataBytes: 64 * 1024 * 1024,
    maximumAuxiliaryAttachments: 0
  )
  let probe = try decoder.probe(data: data, limits: limits)
  let target = try TargetPixels(width: probe.pixelWidth, height: probe.pixelHeight)
  let decoded = try decoder.decode(
    data: data,
    probe: probe,
    request: ImageDecodeRequest(target: target, colorPolicy: .convertToSRGB),
    limits: limits
  )
  let rgb = try rgbData(from: decoded.cgImage)
  try ppmData(width: decoded.pixelWidth, height: decoded.pixelHeight, rgb: rgb).write(
    to: output,
    options: .atomic
  )
}

func makePatternRGBData(width: Int, height: Int) -> Data {
  var pixels = Data(capacity: width * height * 3)
  for y in 0..<height {
    for x in 0..<width {
      let checker = ((x / 8) + (y / 8)).isMultiple(of: 2) ? 37 : 211
      pixels.append(UInt8((x * 17 + y * 3 + checker) & 0xFF))
      pixels.append(UInt8((x * 5 + y * 19 + checker / 2) & 0xFF))
      pixels.append(UInt8((x * 11 + y * 7 + 255 - checker) & 0xFF))
    }
  }
  return pixels
}

func makePatternImage(width: Int, height: Int, rgb: Data) throws -> CGImage {
  guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
    throw EvidenceError.imageCreationFailed
  }
  let bytesPerRow = width * 4
  var pixels = Data(capacity: bytesPerRow * height)
  for offset in stride(from: 0, to: rgb.count, by: 3) {
    pixels.append(rgb[offset])
    pixels.append(rgb[offset + 1])
    pixels.append(rgb[offset + 2])
    pixels.append(255)
  }
  guard let provider = CGDataProvider(data: pixels as CFData),
    let image = CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: bytesPerRow,
      space: colorSpace,
      bitmapInfo: CGBitmapInfo(
        rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue
      ),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  else {
    throw EvidenceError.imageCreationFailed
  }
  return image
}

func rgbData(from image: CGImage) throws -> Data {
  guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
    throw EvidenceError.pixelConversionFailed
  }
  let bytesPerRow = image.width * 4
  var rgba = Data(count: bytesPerRow * image.height)
  let created = rgba.withUnsafeMutableBytes { bytes -> Bool in
    guard let baseAddress = bytes.baseAddress,
      let context = CGContext(
        data: baseAddress,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue
      )
    else {
      return false
    }
    context.setBlendMode(.copy)
    context.interpolationQuality = .none
    context.draw(
      image,
      in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
    )
    return true
  }
  guard created else { throw EvidenceError.pixelConversionFailed }

  var rgb = Data(capacity: image.width * image.height * 3)
  for offset in stride(from: 0, to: rgba.count, by: 4) {
    rgb.append(rgba[offset])
    rgb.append(rgba[offset + 1])
    rgb.append(rgba[offset + 2])
  }
  return rgb
}

func ppmData(width: Int, height: Int, rgb: Data) throws -> Data {
  guard rgb.count == width * height * 3 else {
    throw EvidenceError.pixelConversionFailed
  }
  var data = Data("P6\n\(width) \(height)\n255\n".utf8)
  data.append(rgb)
  return data
}

func sha256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func inspectJPEG(_ data: Data) throws -> JPEGStructure {
  guard data.count >= 4, data[0] == 0xFF, data[1] == 0xD8 else {
    throw EvidenceError.malformedJPEG
  }
  var offset = 2
  var frame: JPEGStructure?
  var quantizationPayload = Data()
  while offset + 1 < data.count {
    guard data[offset] == 0xFF else { throw EvidenceError.malformedJPEG }
    while offset < data.count, data[offset] == 0xFF { offset += 1 }
    guard offset < data.count else { throw EvidenceError.malformedJPEG }
    let marker = data[offset]
    offset += 1
    if marker == 0xD9 { break }
    if marker == 0x01 || (0xD0...0xD7).contains(marker) { continue }
    guard offset + 2 <= data.count else { throw EvidenceError.malformedJPEG }
    let segmentLength = Int(data[offset]) << 8 | Int(data[offset + 1])
    guard segmentLength >= 2, offset + segmentLength <= data.count else {
      throw EvidenceError.malformedJPEG
    }
    let payloadStart = offset + 2
    let payloadEnd = offset + segmentLength
    if marker == 0xDB {
      quantizationPayload.append(data[payloadStart..<payloadEnd])
    } else if marker == 0xC0 || marker == 0xC2 {
      guard payloadEnd - payloadStart >= 6 else { throw EvidenceError.malformedJPEG }
      let precision = Int(data[payloadStart])
      let imageHeight = Int(data[payloadStart + 1]) << 8 | Int(data[payloadStart + 2])
      let imageWidth = Int(data[payloadStart + 3]) << 8 | Int(data[payloadStart + 4])
      let componentCount = Int(data[payloadStart + 5])
      guard payloadStart + 6 + componentCount * 3 <= payloadEnd else {
        throw EvidenceError.malformedJPEG
      }
      var components: [JPEGComponent] = []
      for index in 0..<componentCount {
        let start = payloadStart + 6 + index * 3
        let sampling = data[start + 1]
        components.append(
          JPEGComponent(
            identifier: Int(data[start]),
            horizontalSampling: Int(sampling >> 4),
            verticalSampling: Int(sampling & 0x0F),
            quantizationTable: Int(data[start + 2])
          )
        )
      }
      frame = JPEGStructure(
        frameMarker: marker == 0xC0 ? "SOF0-baseline" : "SOF2-progressive",
        samplePrecision: precision,
        width: imageWidth,
        height: imageHeight,
        components: components,
        quantizationPayloadSHA256: "pending"
      )
    }
    if marker == 0xDA { break }
    offset += segmentLength
  }
  guard let frame else { throw EvidenceError.malformedJPEG }
  return JPEGStructure(
    frameMarker: frame.frameMarker,
    samplePrecision: frame.samplePrecision,
    width: frame.width,
    height: frame.height,
    components: frame.components,
    quantizationPayloadSHA256: sha256(quantizationPayload)
  )
}
