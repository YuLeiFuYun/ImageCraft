import Foundation
import ImageCraftCore
import ImageCraftImageIO

private let independentPNGDecodeComparisonEvidenceVersion =
  "imagecraft-independent-png-decode-comparison-v1"

private struct IndependentPNGDecodeTimingEvidence: Codable {
  let implementation: String
  let samplesNanoseconds: [UInt64]
  let duration: PerformanceDurationStatistics
}

private struct IndependentPNGDecodeComparisonReport: Codable {
  let schemaVersion: UInt16
  let evidenceVersion: String
  let runtime: ImageIORuntimeFingerprint
  let environment: PerformanceEnvironment
  let imageIODecoderFingerprint: String
  let warmupIterationsPerImplementation: Int
  let iterationsPerImplementation: Int
  let alternatingOrder: Bool
  let inputByteCount: Int
  let inputSHA256: String
  let pixelWidth: Int
  let pixelHeight: Int
  let outputByteCount: Int
  let outputSHA256: String
  let exactPackedOutputMatch: Bool
  let independentOperationBudgetBytes: Int
  let independentOperationByteChargeUpperBound: Int
  let independent: IndependentPNGDecodeTimingEvidence
  let imageIO: IndependentPNGDecodeTimingEvidence
  let independentToImageIOMedianRatio: Double
}

func writeIndependentPNGDecodeComparisonEvidence(
  input: URL,
  width: Int,
  height: Int,
  operationBudgetBytes: Int,
  iterations: Int
) throws {
  guard width > 0,
    height > 0,
    width <= 8_192,
    height <= 8_192,
    operationBudgetBytes > 0,
    (1...50).contains(iterations)
  else { throw PerformanceBenchmarkError.invalidIterations }

  let data = try Data(contentsOf: input)
  let pixelCount = width.multipliedReportingOverflow(by: height)
  guard !pixelCount.overflow else { throw PerformanceBenchmarkError.unexpectedOutput }
  let limits = DecodeLimits(
    maximumEncodedBytes: max(1, data.count),
    maximumDimension: max(width, height),
    maximumPixelCount: max(1, pixelCount.partialValue),
    maximumFrameCount: 1,
    maximumMetadataBytes: 1_024,
    maximumAuxiliaryAttachments: 0,
    allowedFormats: [.png]
  )
  let request = ImageDecodeRequest(
    target: try TargetPixels(width: width, height: height),
    contentMode: .fit,
    colorPolicy: .preserveSource
  )
  let independent = PNGIndependentRGBA8Decoder(
    maximumOperationByteCharge: operationBudgetBytes
  )
  let imageIO = ImageIOImageDecoder()

  let ledger = try independent.resourceLedger(data: data, request: request, limits: limits)
  guard let operationBound = ledger.operationPeak.bytesUpperBound else {
    throw PerformanceBenchmarkError.unexpectedOutput
  }
  let independentReference = try independent.decode(data: data, request: request, limits: limits)
  let imageIOReference = try imageIO.decodePackedRGBA8(data: data, request: request, limits: limits)
  guard independentReference == imageIOReference else {
    throw PerformanceBenchmarkError.unexpectedOutput
  }
  let output = independentReference.data
  let expectedByteCount = output.count
  let firstByte = output.first
  let lastByte = output.last

  func runIndependent() throws {
    let decoded = try independent.decode(data: data, request: request, limits: limits)
    guard decoded.data.count == expectedByteCount,
      decoded.data.first == firstByte,
      decoded.data.last == lastByte
    else { throw PerformanceBenchmarkError.unexpectedOutput }
  }

  func runImageIO() throws {
    let decoded = try imageIO.decodePackedRGBA8(data: data, request: request, limits: limits)
    guard decoded.data.count == expectedByteCount,
      decoded.data.first == firstByte,
      decoded.data.last == lastByte
    else { throw PerformanceBenchmarkError.unexpectedOutput }
  }

  let warmups = 2
  for _ in 0..<warmups {
    try autoreleasepool(invoking: runIndependent)
    try autoreleasepool(invoking: runImageIO)
  }

  var independentSamples: [UInt64] = []
  var imageIOSamples: [UInt64] = []
  independentSamples.reserveCapacity(iterations)
  imageIOSamples.reserveCapacity(iterations)
  for iteration in 0..<iterations {
    let operations: [(String, () throws -> Void)] = iteration.isMultiple(of: 2)
      ? [("independent", runIndependent), ("imageio", runImageIO)]
      : [("imageio", runImageIO), ("independent", runIndependent)]
    for (name, operation) in operations {
      let started = DispatchTime.now().uptimeNanoseconds
      try autoreleasepool(invoking: operation)
      let elapsed = DispatchTime.now().uptimeNanoseconds &- started
      if name == "independent" {
        independentSamples.append(elapsed)
      } else {
        imageIOSamples.append(elapsed)
      }
    }
  }

  let independentStats = durationStatistics(independentSamples)
  let imageIOStats = durationStatistics(imageIOSamples)
  let report = IndependentPNGDecodeComparisonReport(
    schemaVersion: 1,
    evidenceVersion: independentPNGDecodeComparisonEvidenceVersion,
    runtime: .capture(),
    environment: capturePerformanceEnvironment(),
    imageIODecoderFingerprint: imageIO.codecDescriptor.cacheFingerprint,
    warmupIterationsPerImplementation: warmups,
    iterationsPerImplementation: iterations,
    alternatingOrder: true,
    inputByteCount: data.count,
    inputSHA256: sha256(data),
    pixelWidth: width,
    pixelHeight: height,
    outputByteCount: output.count,
    outputSHA256: sha256(output),
    exactPackedOutputMatch: true,
    independentOperationBudgetBytes: operationBudgetBytes,
    independentOperationByteChargeUpperBound: operationBound,
    independent: IndependentPNGDecodeTimingEvidence(
      implementation: "ImageCraft.PNGIndependentRGBA8Decoder",
      samplesNanoseconds: independentSamples,
      duration: independentStats
    ),
    imageIO: IndependentPNGDecodeTimingEvidence(
      implementation: "ImageCraft.ImageIOImageDecoder.decodePackedRGBA8",
      samplesNanoseconds: imageIOSamples,
      duration: imageIOStats
    ),
    independentToImageIOMedianRatio: Double(independentStats.medianNanoseconds)
      / Double(imageIOStats.medianNanoseconds)
  )

  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  FileHandle.standardOutput.write(try encoder.encode(report))
  FileHandle.standardOutput.write(Data([0x0A]))
}
