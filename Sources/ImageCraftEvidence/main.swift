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
  case preparedStateRetention(strategyID: String, preparationCount: Int, iterations: Int)
  case packedRGBAExport(input: URL, output: URL)
  case jpegFrameSamplingGeometry(input: URL)
  case progressiveJPEGResourceGeometry(input: URL)
  case progressiveJPEGOwnedVariableState(input: URL)
  case centeredChromaReconstruct(
    input: URL,
    output: URL,
    mode: String,
    sourceWidth: Int,
    sourceHeight: Int,
    outputWidth: Int,
    outputHeight: Int
  )
  case jpegISlowIDCTBlock(input: URL, output: URL)
  case independentBaselineGrayscale(input: URL, output: URL)
  case independentProgressiveGrayscale(input: URL, output: URL)
  case independentProgressiveGrayscaleCoefficients(input: URL, output: URL)
  case jpegYCbCrToRGB(input: URL, output: URL)
  case independentBaseline444(input: URL, output: URL)
  case independentBaseline420(input: URL, output: URL)
  case independentProgressive420(input: URL, output: URL, coefficientsOutput: URL)
  case independentProgressive420Session(input: URL, scheduleID: String, previewCadenceID: String)
  case independentProgressive420PackedFinalization(input: URL)
  case progressiveJPEGPreparationCreation(input: URL)
  case staticPreparationCreation(input: URL)
  case independentProgressive420Scans(input: URL, outputDirectory: URL)
  case independentProgressive420SmoothedScans(input: URL, outputDirectory: URL)
  case rfc1950InflateComparison(profileID: String, payloadByteCount: Int, iterations: Int)
  case rfc1950FileComparison(input: URL, expectedByteCount: Int, iterations: Int)
  case independentPNGDecodeComparison(
    input: URL,
    width: Int,
    height: Int,
    operationBudgetBytes: Int,
    iterations: Int
  )
  case progressiveTimeline(caseID: String, iterations: Int)
  case progressiveQuality(caseID: String)
  case progressivePhotoCorpus(manifest: URL, variantID: String, chunkSize: Int)
  case progressiveScanCheckpoints(manifest: URL, variantID: String)
  case progressivePipelineProfile(manifest: URL, variantID: String, chunkSize: Int, iterations: Int)
  case rasterComparison(input: URL, chunkSize: Int, iterations: Int)
  case derivedRasterPrototype(input: URL, iterations: Int)
  case animationPerformance(AnimationPerformanceArguments)
  case apngCheckpointEncode(input: URL, width: Int, height: Int, output: URL)
  case apngCheckpointDecode(input: URL, output: URL)
  case apngOwnedPlayback(input: URL, outputDirectory: URL)
  case animationDecoderPlayback(input: URL, outputDirectory: URL)
}

enum EvidenceError: Error {
  case imageCreationFailed
  case invalidArguments
  case malformedJPEG
  case pixelConversionFailed
}

try await run(command: parseCommand(CommandLine.arguments))

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
    parameters[0] == "--packed-rgba-export",
    parameters[2] == "--output"
  {
    return .packedRGBAExport(
      input: URL(fileURLWithPath: parameters[1]),
      output: URL(fileURLWithPath: parameters[3])
    )
  }
  if parameters.count == 2, parameters[0] == "--jpeg-frame-sampling-geometry" {
    return .jpegFrameSamplingGeometry(
      input: URL(fileURLWithPath: parameters[1])
    )
  }
  if parameters.count == 2, parameters[0] == "--progressive-jpeg-resource-geometry" {
    return .progressiveJPEGResourceGeometry(
      input: URL(fileURLWithPath: parameters[1])
    )
  }
  if parameters.count == 2, parameters[0] == "--progressive-jpeg-owned-variable-state" {
    return .progressiveJPEGOwnedVariableState(
      input: URL(fileURLWithPath: parameters[1])
    )
  }
  if parameters.count == 8,
    parameters[0] == "--jpeg-centered-chroma-reconstruct",
    let sourceWidth = Int(parameters[4]),
    let sourceHeight = Int(parameters[5]),
    let outputWidth = Int(parameters[6]),
    let outputHeight = Int(parameters[7])
  {
    return .centeredChromaReconstruct(
      input: URL(fileURLWithPath: parameters[1]),
      output: URL(fileURLWithPath: parameters[2]),
      mode: parameters[3],
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      outputWidth: outputWidth,
      outputHeight: outputHeight
    )
  }
  if parameters.count == 4,
    parameters[0] == "--jpeg-islow-idct-block",
    parameters[2] == "--output"
  {
    return .jpegISlowIDCTBlock(
      input: URL(fileURLWithPath: parameters[1]),
      output: URL(fileURLWithPath: parameters[3])
    )
  }
  if parameters.count == 4,
    parameters[0] == "--independent-baseline-grayscale-jpeg",
    parameters[2] == "--output"
  {
    return .independentBaselineGrayscale(
      input: URL(fileURLWithPath: parameters[1]),
      output: URL(fileURLWithPath: parameters[3])
    )
  }
  if parameters.count == 4,
    parameters[0] == "--independent-progressive-grayscale-jpeg",
    parameters[2] == "--output"
  {
    return .independentProgressiveGrayscale(
      input: URL(fileURLWithPath: parameters[1]),
      output: URL(fileURLWithPath: parameters[3])
    )
  }
  if parameters.count == 4,
    parameters[0] == "--independent-progressive-grayscale-coefficients",
    parameters[2] == "--output"
  {
    return .independentProgressiveGrayscaleCoefficients(
      input: URL(fileURLWithPath: parameters[1]),
      output: URL(fileURLWithPath: parameters[3])
    )
  }
  if parameters.count == 4,
    parameters[0] == "--jpeg-ycbcr-to-rgb",
    parameters[2] == "--output"
  {
    return .jpegYCbCrToRGB(
      input: URL(fileURLWithPath: parameters[1]),
      output: URL(fileURLWithPath: parameters[3])
    )
  }
  if parameters.count == 4,
    parameters[0] == "--independent-baseline-jpeg-444",
    parameters[2] == "--output"
  {
    return .independentBaseline444(
      input: URL(fileURLWithPath: parameters[1]),
      output: URL(fileURLWithPath: parameters[3])
    )
  }
  if parameters.count == 4,
    parameters[0] == "--independent-baseline-jpeg-420",
    parameters[2] == "--output"
  {
    return .independentBaseline420(
      input: URL(fileURLWithPath: parameters[1]),
      output: URL(fileURLWithPath: parameters[3])
    )
  }
  if parameters.count == 6,
    parameters[0] == "--independent-progressive-jpeg-420",
    parameters[2] == "--output",
    parameters[4] == "--coefficients-output"
  {
    return .independentProgressive420(
      input: URL(fileURLWithPath: parameters[1]),
      output: URL(fileURLWithPath: parameters[3]),
      coefficientsOutput: URL(fileURLWithPath: parameters[5])
    )
  }
  if parameters.count == 6,
    parameters[0] == "--independent-progressive-jpeg-420-session",
    parameters[2] == "--schedule",
    parameters[4] == "--preview-cadence"
  {
    return .independentProgressive420Session(
      input: URL(fileURLWithPath: parameters[1]),
      scheduleID: parameters[3],
      previewCadenceID: parameters[5]
    )
  }
  if parameters.count == 2,
    parameters[0] == "--independent-progressive-jpeg-420-packed-finalization"
  {
    return .independentProgressive420PackedFinalization(
      input: URL(fileURLWithPath: parameters[1])
    )
  }
  if parameters.count == 2,
    parameters[0] == "--progressive-jpeg-preparation-creation"
  {
    return .progressiveJPEGPreparationCreation(
      input: URL(fileURLWithPath: parameters[1])
    )
  }
  if parameters.count == 2,
    parameters[0] == "--static-preparation-creation"
  {
    return .staticPreparationCreation(
      input: URL(fileURLWithPath: parameters[1])
    )
  }
  if parameters.count == 4,
    parameters[0] == "--independent-progressive-jpeg-420-scans",
    parameters[2] == "--output-directory"
  {
    return .independentProgressive420Scans(
      input: URL(fileURLWithPath: parameters[1]),
      outputDirectory: URL(fileURLWithPath: parameters[3])
    )
  }
  if parameters.count == 4,
    parameters[0] == "--independent-progressive-jpeg-420-smoothed-scans",
    parameters[2] == "--output-directory"
  {
    return .independentProgressive420SmoothedScans(
      input: URL(fileURLWithPath: parameters[1]),
      outputDirectory: URL(fileURLWithPath: parameters[3])
    )
  }
  if parameters.count == 5,
    parameters[0] == "--rfc1950-inflate-comparison",
    parameters[1] == "--bytes",
    let payloadByteCount = Int(parameters[2]),
    parameters[3] == "--iterations",
    let iterations = Int(parameters[4])
  {
    return .rfc1950InflateComparison(
      profileID: "repetitive-v1",
      payloadByteCount: payloadByteCount,
      iterations: iterations
    )
  }
  if parameters.count == 7,
    parameters[0] == "--rfc1950-inflate-comparison",
    parameters[1] == "--profile",
    parameters[3] == "--bytes",
    let payloadByteCount = Int(parameters[4]),
    parameters[5] == "--iterations",
    let iterations = Int(parameters[6])
  {
    return .rfc1950InflateComparison(
      profileID: parameters[2],
      payloadByteCount: payloadByteCount,
      iterations: iterations
    )
  }
  if parameters.count == 6,
    parameters[0] == "--rfc1950-file-comparison",
    parameters[2] == "--expected-bytes",
    let expectedByteCount = Int(parameters[3]),
    parameters[4] == "--iterations",
    let iterations = Int(parameters[5])
  {
    return .rfc1950FileComparison(
      input: URL(fileURLWithPath: parameters[1]),
      expectedByteCount: expectedByteCount,
      iterations: iterations
    )
  }
  if parameters.count == 10,
    parameters[0] == "--independent-png-decode-comparison",
    parameters[2] == "--width",
    let width = Int(parameters[3]),
    parameters[4] == "--height",
    let height = Int(parameters[5]),
    parameters[6] == "--operation-budget",
    let operationBudgetBytes = Int(parameters[7]),
    parameters[8] == "--iterations",
    let iterations = Int(parameters[9])
  {
    return .independentPNGDecodeComparison(
      input: URL(fileURLWithPath: parameters[1]),
      width: width,
      height: height,
      operationBudgetBytes: operationBudgetBytes,
      iterations: iterations
    )
  }
  if parameters.count == 7,
    parameters[0] == "--prepared-state-retention",
    parameters[2] == "--preparations",
    let preparationCount = Int(parameters[3]),
    parameters[4] == "--iterations",
    let iterations = Int(parameters[5]),
    parameters[6] == "--emit-json"
  {
    return .preparedStateRetention(
      strategyID: parameters[1],
      preparationCount: preparationCount,
      iterations: iterations
    )
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
  if parameters.count == 3, parameters[0] == "--progressive-scan-checkpoints" {
    return .progressiveScanCheckpoints(
      manifest: URL(fileURLWithPath: parameters[1]),
      variantID: parameters[2]
    )
  }
  if parameters.count == 6,
    parameters[0] == "--raster-comparison",
    parameters[2] == "--chunk-size",
    parameters[4] == "--iterations",
    let chunkSize = Int(parameters[3]),
    let iterations = Int(parameters[5])
  {
    return .rasterComparison(
      input: URL(fileURLWithPath: parameters[1]),
      chunkSize: chunkSize,
      iterations: iterations
    )
  }
  if parameters.count == 4,
    parameters[0] == "--derived-raster-prototype",
    parameters[2] == "--iterations",
    let iterations = Int(parameters[3])
  {
    return .derivedRasterPrototype(
      input: URL(fileURLWithPath: parameters[1]),
      iterations: iterations
    )
  }
  if parameters.count == 8,
    parameters[0] == "--apng-checkpoint-encode",
    parameters[2] == "--width",
    let width = Int(parameters[3]),
    parameters[4] == "--height",
    let height = Int(parameters[5]),
    parameters[6] == "--output"
  {
    return .apngCheckpointEncode(
      input: URL(fileURLWithPath: parameters[1]),
      width: width,
      height: height,
      output: URL(fileURLWithPath: parameters[7])
    )
  }
  if parameters.count == 4,
    parameters[0] == "--apng-checkpoint-decode",
    parameters[2] == "--output"
  {
    return .apngCheckpointDecode(
      input: URL(fileURLWithPath: parameters[1]),
      output: URL(fileURLWithPath: parameters[3])
    )
  }
  if parameters.count == 4,
    parameters[0] == "--apng-owned-playback",
    parameters[2] == "--output-directory"
  {
    return .apngOwnedPlayback(
      input: URL(fileURLWithPath: parameters[1]),
      outputDirectory: URL(fileURLWithPath: parameters[3], isDirectory: true)
    )
  }
  if parameters.count == 4,
    parameters[0] == "--animation-decoder-playback",
    parameters[2] == "--output-directory"
  {
    return .animationDecoderPlayback(
      input: URL(fileURLWithPath: parameters[1]),
      outputDirectory: URL(fileURLWithPath: parameters[3], isDirectory: true)
    )
  }
  if let animation = try? AnimationPerformanceArguments([arguments[0]] + parameters) {
    return .animationPerformance(animation)
  }
  if parameters.count == 6,
    parameters[0] == "--progressive-pipeline-profile",
    parameters[4] == "--iterations",
    let chunkSize = Int(parameters[3]),
    let iterations = Int(parameters[5])
  {
    return .progressivePipelineProfile(
      manifest: URL(fileURLWithPath: parameters[1]),
      variantID: parameters[2],
      chunkSize: chunkSize,
      iterations: iterations
    )
  }
  throw EvidenceError.invalidArguments
}

func run(command: EvidenceCommand) async throws {
  switch command {
  case .report(let artifactDirectory):
    try writeReport(artifactDirectory: artifactDirectory)
  case .decode(let input, let output):
    try decodeImageToPPM(input: input, output: output)
  case .benchmark(let caseID, let iterations):
    try writePerformanceBenchmark(caseID: caseID, iterations: iterations)
  case .preparedStateRetention(let strategyID, let preparationCount, let iterations):
    try writePreparedStateRetentionEvidence(
      strategyID: strategyID,
      preparationCount: preparationCount,
      iterations: iterations
    )
  case .packedRGBAExport(let input, let output):
    try writePackedRGBAExportEvidence(input: input, output: output)
  case .jpegFrameSamplingGeometry(let input):
    try writeJPEGFrameSamplingGeometryEvidence(input: input)
  case .progressiveJPEGResourceGeometry(let input):
    try writeProgressiveJPEGResourceGeometryEvidence(input: input)
  case .progressiveJPEGOwnedVariableState(let input):
    try writeProgressiveJPEGOwnedVariableStateEvidence(input: input)
  case .centeredChromaReconstruct(
    let input,
    let output,
    let mode,
    let sourceWidth,
    let sourceHeight,
    let outputWidth,
    let outputHeight
  ):
    try writeCenteredChromaReconstructionEvidence(
      input: input,
      output: output,
      mode: mode,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      outputWidth: outputWidth,
      outputHeight: outputHeight
    )
  case .jpegISlowIDCTBlock(let input, let output):
    try writeJPEGISlowIDCTEvidence(input: input, output: output)
  case .independentBaselineGrayscale(let input, let output):
    try writeIndependentBaselineGrayscaleEvidence(input: input, output: output)
  case .independentProgressiveGrayscale(let input, let output):
    try writeIndependentProgressiveGrayscaleEvidence(input: input, output: output)
  case .independentProgressiveGrayscaleCoefficients(let input, let output):
    try writeIndependentProgressiveGrayscaleCoefficientEvidence(input: input, output: output)
  case .jpegYCbCrToRGB(let input, let output):
    try writeJPEGYCbCrToRGBEvidence(input: input, output: output)
  case .independentBaseline444(let input, let output):
    try writeIndependentBaseline444Evidence(input: input, output: output)
  case .independentBaseline420(let input, let output):
    try writeIndependentBaseline420Evidence(input: input, output: output)
  case .independentProgressive420(let input, let output, let coefficientsOutput):
    try writeIndependentProgressive420Evidence(
      input: input,
      output: output,
      coefficientsOutput: coefficientsOutput
    )
  case .independentProgressive420Session(let input, let scheduleID, let previewCadenceID):
    try writeIndependentProgressive420SessionEvidence(
      input: input,
      scheduleID: scheduleID,
      previewCadenceID: previewCadenceID
    )
  case .independentProgressive420PackedFinalization(let input):
    try writeIndependentProgressive420PackedFinalizationEvidence(input: input)
  case .progressiveJPEGPreparationCreation(let input):
    try writeProgressiveJPEGPreparationCreationEvidence(input: input)
  case .staticPreparationCreation(let input):
    try writeStaticPreparationCreationEvidence(input: input)
  case .independentProgressive420Scans(let input, let outputDirectory):
    try writeIndependentProgressive420ScanEvidence(
      input: input,
      outputDirectory: outputDirectory
    )
  case .independentProgressive420SmoothedScans(let input, let outputDirectory):
    try writeIndependentProgressive420SmoothedScanEvidence(
      input: input,
      outputDirectory: outputDirectory
    )
  case .rfc1950InflateComparison(let profileID, let payloadByteCount, let iterations):
    try writeRFC1950InflateComparisonEvidence(
      profileID: profileID,
      payloadByteCount: payloadByteCount,
      iterations: iterations
    )
  case .rfc1950FileComparison(let input, let expectedByteCount, let iterations):
    try writeRFC1950FileComparisonEvidence(
      input: input,
      expectedByteCount: expectedByteCount,
      iterations: iterations
    )
  case .independentPNGDecodeComparison(
    let input,
    let width,
    let height,
    let operationBudgetBytes,
    let iterations
  ):
    try writeIndependentPNGDecodeComparisonEvidence(
      input: input,
      width: width,
      height: height,
      operationBudgetBytes: operationBudgetBytes,
      iterations: iterations
    )
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
  case .progressiveScanCheckpoints(let manifest, let variantID):
    try writeProgressiveScanCheckpointEvidence(
      manifestURL: manifest,
      variantID: variantID
    )
  case .progressivePipelineProfile(let manifest, let variantID, let chunkSize, let iterations):
    try await writeProgressivePipelineProfile(
      manifestURL: manifest,
      variantID: variantID,
      chunkSize: chunkSize,
      iterations: iterations
    )
  case .rasterComparison(let input, let chunkSize, let iterations):
    try writeRasterComparisonEvidence(
      input: input,
      chunkSize: chunkSize,
      iterations: iterations
    )
  case .derivedRasterPrototype(let input, let iterations):
    try writeDerivedRasterPrototypeEvidence(
      input: input,
      iterations: iterations
    )
  case .animationPerformance(let arguments):
    try await writeAnimationPerformanceEvidence(arguments: arguments)
  case .apngCheckpointEncode(let input, let width, let height, let output):
    try writeAPNGCheckpointInteropEncode(
      input: input,
      width: width,
      height: height,
      output: output
    )
  case .apngCheckpointDecode(let input, let output):
    try writeAPNGCheckpointInteropDecode(input: input, output: output)
  case .apngOwnedPlayback(let input, let outputDirectory):
    try writeAPNGOwnedPlaybackEvidence(
      input: input,
      outputDirectory: outputDirectory
    )
  case .animationDecoderPlayback(let input, let outputDirectory):
    try await writeAnimationDecoderPlaybackEvidence(
      input: input,
      outputDirectory: outputDirectory
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
