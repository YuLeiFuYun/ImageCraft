import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import ImageCraftCore
import ImageCraftImageIO
import UniformTypeIdentifiers

private let performanceBenchmarkVersion = "imagecraft-performance-v1"
private let performanceRSSSampleIntervalMicroseconds: UInt32 = 500

struct PerformanceEnvironment: Codable, Equatable {
  let hardwareModel: String
  let activeProcessorCount: Int
  let physicalMemoryBytes: UInt64
  let lowPowerModeEnabled: Bool
  let thermalState: String
}

struct PerformanceSource: Codable, Equatable {
  let generator: String
  let representation: String
  let pixelWidth: Int
  let pixelHeight: Int
  let encodedByteCount: Int?
  let encodedSHA256: String?
  let targetWidth: Int?
  let targetHeight: Int?
  let contentMode: String?
}

struct PerformanceOutput: Codable, Equatable {
  let representation: String
  let pixelWidth: Int?
  let pixelHeight: Int?
  let encodedByteCount: Int?
  let sha256: String?
}

struct PerformanceDurationStatistics: Codable, Equatable {
  let minimumNanoseconds: UInt64
  let medianNanoseconds: UInt64
  let p90Nanoseconds: UInt64
  let maximumNanoseconds: UInt64
  let meanNanoseconds: UInt64
}

struct PerformanceMemoryStatistics: Codable, Equatable {
  let baselineResidentBytes: UInt64
  let sampledPeakResidentBytes: UInt64
  let sampledPeakDeltaBytes: UInt64
  let estimatedWorkingSetBytes: Int?
}

struct PerformanceCaseReport: Codable {
  let schemaVersion: UInt16
  let benchmarkVersion: String
  let runtime: ImageIORuntimeFingerprint
  let decoderFingerprint: String
  let encoderFingerprint: String
  let environment: PerformanceEnvironment
  let rssSampleIntervalMicroseconds: UInt32
  let caseID: String
  let memoryIterations: Int
  let warmupIterations: Int
  let iterations: Int
  let source: PerformanceSource
  let samplesNanoseconds: [UInt64]
  let duration: PerformanceDurationStatistics
  let memory: PerformanceMemoryStatistics
  let output: PerformanceOutput
}

enum PerformanceBenchmarkError: Error {
  case invalidCase
  case invalidIterations
  case residentMemoryUnavailable
  case unexpectedOutput
}

enum PerformanceBenchmarkCase: String, CaseIterable {
  case decodeJPEGFull = "decode-jpeg-full"
  case decodeJPEGFit512 = "decode-jpeg-fit-512"
  case decodeJPEGFit1024 = "decode-jpeg-fit-1024"
  case decodeJPEGFill1024 = "decode-jpeg-fill-1024"
  case probeThenDecodeJPEGFit512 = "probe-then-decode-jpeg-fit-512"
  case prepareThenDecodeJPEGFit512 = "prepare-then-decode-jpeg-fit-512"
  case progressiveJPEGFit512Chunk1K = "progressive-jpeg-fit-512-chunk-1024"
  case progressiveJPEGFit512Chunk32K = "progressive-jpeg-fit-512-chunk-32768"
  case encodePNG = "encode-png"
  case encodeJPEG75 = "encode-jpeg-q75"
}

private struct BenchmarkOperation {
  let source: PerformanceSource
  let estimatedWorkingSetBytes: Int?
  let output: PerformanceOutput
  let run: () throws -> Void
}

func writePerformanceBenchmark(caseID: String, iterations: Int) throws {
  guard let benchmarkCase = PerformanceBenchmarkCase(rawValue: caseID) else {
    throw PerformanceBenchmarkError.invalidCase
  }
  guard (1...50).contains(iterations) else {
    throw PerformanceBenchmarkError.invalidIterations
  }

  let operation = try makeBenchmarkOperation(benchmarkCase)
  let memoryIterations = 1
  _ = malloc_zone_pressure_relief(nil, 0)
  let baselineResidentBytes = try residentBytes()
  let sampler = ResidentMemorySampler(initialResidentBytes: baselineResidentBytes)
  sampler.start()
  for _ in 0..<memoryIterations {
    try autoreleasepool(invoking: operation.run)
  }
  let sampledPeakResidentBytes = sampler.stop()

  let warmupIterations = 2
  for _ in 0..<warmupIterations {
    try autoreleasepool(invoking: operation.run)
  }
  var samples: [UInt64] = []
  for _ in 0..<iterations {
    let started = DispatchTime.now().uptimeNanoseconds
    try autoreleasepool(invoking: operation.run)
    samples.append(DispatchTime.now().uptimeNanoseconds &- started)
  }

  let report = PerformanceCaseReport(
    schemaVersion: 1,
    benchmarkVersion: performanceBenchmarkVersion,
    runtime: .capture(),
    decoderFingerprint: ImageIOImageDecoder().codecDescriptor.cacheFingerprint,
    encoderFingerprint: ImageIOImageEncoder().encoderDescriptor.cacheFingerprint,
    environment: capturePerformanceEnvironment(),
    rssSampleIntervalMicroseconds: performanceRSSSampleIntervalMicroseconds,
    caseID: benchmarkCase.rawValue,
    memoryIterations: memoryIterations,
    warmupIterations: warmupIterations,
    iterations: iterations,
    source: operation.source,
    samplesNanoseconds: samples,
    duration: durationStatistics(samples),
    memory: PerformanceMemoryStatistics(
      baselineResidentBytes: baselineResidentBytes,
      sampledPeakResidentBytes: sampledPeakResidentBytes,
      sampledPeakDeltaBytes: sampledPeakResidentBytes >= baselineResidentBytes
        ? sampledPeakResidentBytes - baselineResidentBytes
        : 0,
      estimatedWorkingSetBytes: operation.estimatedWorkingSetBytes
    ),
    output: operation.output
  )

  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  FileHandle.standardOutput.write(try encoder.encode(report))
  FileHandle.standardOutput.write(Data([0x0A]))
}

private func makeBenchmarkOperation(
  _ benchmarkCase: PerformanceBenchmarkCase
) throws -> BenchmarkOperation {
  switch benchmarkCase {
  case .decodeJPEGFull:
    return try makeJPEGDecodeOperation(
      targetWidth: 3_072,
      targetHeight: 2_048,
      contentMode: .fit,
      strategy: .direct
    )
  case .decodeJPEGFit512:
    return try makeJPEGDecodeOperation(
      targetWidth: 512,
      targetHeight: 512,
      contentMode: .fit,
      strategy: .direct
    )
  case .decodeJPEGFit1024:
    return try makeJPEGDecodeOperation(
      targetWidth: 1_024,
      targetHeight: 1_024,
      contentMode: .fit,
      strategy: .direct
    )
  case .decodeJPEGFill1024:
    return try makeJPEGDecodeOperation(
      targetWidth: 1_024,
      targetHeight: 1_024,
      contentMode: .fill,
      strategy: .direct
    )
  case .probeThenDecodeJPEGFit512:
    return try makeJPEGDecodeOperation(
      targetWidth: 512,
      targetHeight: 512,
      contentMode: .fit,
      strategy: .probeThenDecode
    )
  case .prepareThenDecodeJPEGFit512:
    return try makeJPEGDecodeOperation(
      targetWidth: 512,
      targetHeight: 512,
      contentMode: .fit,
      strategy: .prepareThenDecode
    )
  case .progressiveJPEGFit512Chunk1K:
    return try makeProgressiveJPEGOperation(chunkSize: 1_024)
  case .progressiveJPEGFit512Chunk32K:
    return try makeProgressiveJPEGOperation(chunkSize: 32 * 1_024)
  case .encodePNG:
    return try makeEncodeOperation(format: .png, width: 1_600, height: 1_200)
  case .encodeJPEG75:
    return try makeEncodeOperation(format: .jpeg, width: 3_072, height: 2_048)
  }
}

private enum DecodeStrategy {
  case direct
  case probeThenDecode
  case prepareThenDecode
}

private func makeJPEGDecodeOperation(
  targetWidth: Int,
  targetHeight: Int,
  contentMode: ImageContentMode,
  strategy: DecodeStrategy
) throws -> BenchmarkOperation {
  let sourceWidth = 3_072
  let sourceHeight = 2_048
  let sourceRGB = makePatternRGBData(width: sourceWidth, height: sourceHeight)
  let sourceImage = try makePatternImage(width: sourceWidth, height: sourceHeight, rgb: sourceRGB)
  let encodeRequest = try ImageEncodeRequest.jpeg(
    quality: ImageEncodeQuality(rawValue: 0.82),
    colorPolicy: .convertToSRGB,
    metadataPolicy: .discard,
    alphaPolicy: .reject
  )
  let encoded = try ImageIOImageEncoder().encode(
    image: sourceImage,
    request: encodeRequest,
    limits: EncodeLimits(maximumEncodedBytes: 128 * 1024 * 1024)
  )
  let limits = DecodeLimits(
    maximumEncodedBytes: max(encoded.byteCount, 1),
    maximumDimension: 16_384,
    maximumPixelCount: 100_000_000,
    maximumFrameCount: 1,
    maximumMetadataBytes: 4 * 1024 * 1024,
    maximumAuxiliaryAttachments: 0,
    allowedFormats: [.jpeg]
  )
  let target = try TargetPixels(width: targetWidth, height: targetHeight)
  let request = ImageDecodeRequest(
    target: target,
    contentMode: contentMode,
    colorPolicy: .convertToSRGB
  )
  let estimateProbe = try ImageIOImageDecoder().probe(data: encoded.data, limits: limits)
  let estimatedWorkingSetBytes = try ImageIOImageDecoder().resourceEstimate(
    probe: estimateProbe,
    request: request
  ).workingSetBytes
  let decoder = ImageIOImageDecoder()
  let reference = try decoder.decode(data: encoded.data, request: request, limits: limits)
  let output = PerformanceOutput(
    representation: "cgImage-srgb",
    pixelWidth: reference.pixelWidth,
    pixelHeight: reference.pixelHeight,
    encodedByteCount: nil,
    sha256: nil
  )

  let run: () throws -> Void = {
    let decoded: DecodedImage
    switch strategy {
    case .direct:
      decoded = try decoder.decode(data: encoded.data, request: request, limits: limits)
    case .probeThenDecode:
      let probe = try decoder.probe(data: encoded.data, limits: limits)
      decoded = try decoder.decode(
        data: encoded.data,
        probe: probe,
        request: request,
        limits: limits
      )
    case .prepareThenDecode:
      let preparation = try decoder.prepare(data: encoded.data, limits: limits)
      decoded = try decoder.decode(
        preparation: preparation,
        request: request,
        limits: limits
      )
    }
    guard decoded.pixelWidth == output.pixelWidth,
      decoded.pixelHeight == output.pixelHeight
    else {
      throw PerformanceBenchmarkError.unexpectedOutput
    }
  }

  return BenchmarkOperation(
    source: PerformanceSource(
      generator: "imagecraft-pattern-v1",
      representation: EncodedImageFormat.jpeg.rawValue,
      pixelWidth: sourceWidth,
      pixelHeight: sourceHeight,
      encodedByteCount: encoded.byteCount,
      encodedSHA256: sha256(encoded.data),
      targetWidth: targetWidth,
      targetHeight: targetHeight,
      contentMode: contentMode.rawValue
    ),
    estimatedWorkingSetBytes: estimatedWorkingSetBytes,
    output: output,
    run: run
  )
}

private func makeProgressiveJPEGOperation(chunkSize: Int) throws -> BenchmarkOperation {
  let sourceWidth = 3_072
  let sourceHeight = 2_048
  let sourceRGB = makePatternRGBData(width: sourceWidth, height: sourceHeight)
  let sourceImage = try makePatternImage(width: sourceWidth, height: sourceHeight, rgb: sourceRGB)
  let encoded = try makeProgressiveJPEG(image: sourceImage, quality: 0.82)
  let limits = DecodeLimits(
    maximumEncodedBytes: max(encoded.count, 1),
    maximumDimension: 16_384,
    maximumPixelCount: 100_000_000,
    maximumFrameCount: 1,
    maximumMetadataBytes: 4 * 1024 * 1024,
    maximumAuxiliaryAttachments: 0,
    allowedFormats: [.jpeg]
  )
  let request = ImageDecodeRequest(
    target: try TargetPixels(width: 512, height: 512),
    contentMode: .fit,
    colorPolicy: .preserveSource
  )
  let chunks = stride(from: 0, to: encoded.count, by: chunkSize).map { offset in
    encoded.subdata(in: offset..<min(encoded.count, offset + chunkSize))
  }
  let decoder = ImageIOImageDecoder()
  let probe = try decoder.probe(data: encoded, limits: limits)
  let estimatedWorkingSetBytes = try decoder.resourceEstimate(
    probe: probe,
    request: request
  ).workingSetBytes

  func execute() throws -> (generationCount: Int, last: DecodedImage) {
    let session = try decoder.makeProgressiveSession(
      format: .jpeg,
      request: request,
      limits: limits
    )
    var generationCount = 0
    var last: DecodedImage?
    for chunk in chunks {
      if let generation = try session.append(chunk) {
        generationCount += 1
        last = generation.image
      }
    }
    try session.finish()
    guard generationCount >= 2, let last else {
      throw PerformanceBenchmarkError.unexpectedOutput
    }
    return (generationCount, last)
  }

  let reference = try execute()
  let output = PerformanceOutput(
    representation: "progressive-cgImage-source-color",
    pixelWidth: reference.last.pixelWidth,
    pixelHeight: reference.last.pixelHeight,
    encodedByteCount: nil,
    sha256: nil
  )
  let run: () throws -> Void = {
    let result = try execute()
    guard result.generationCount == reference.generationCount,
      result.last.pixelWidth == output.pixelWidth,
      result.last.pixelHeight == output.pixelHeight
    else {
      throw PerformanceBenchmarkError.unexpectedOutput
    }
  }

  return BenchmarkOperation(
    source: PerformanceSource(
      generator: "imagecraft-progressive-pattern-v1",
      representation: EncodedImageFormat.jpeg.rawValue,
      pixelWidth: sourceWidth,
      pixelHeight: sourceHeight,
      encodedByteCount: encoded.count,
      encodedSHA256: sha256(encoded),
      targetWidth: 512,
      targetHeight: 512,
      contentMode: ImageContentMode.fit.rawValue
    ),
    estimatedWorkingSetBytes: estimatedWorkingSetBytes,
    output: output,
    run: run
  )
}

private func makeProgressiveJPEG(image: CGImage, quality: Double) throws -> Data {
  let output = NSMutableData()
  guard let destination = CGImageDestinationCreateWithData(
    output,
    UTType.jpeg.identifier as CFString,
    1,
    nil
  ) else {
    throw PerformanceBenchmarkError.unexpectedOutput
  }
  let properties: [CFString: Any] = [
    kCGImageDestinationLossyCompressionQuality: quality,
    kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: true],
  ]
  CGImageDestinationAddImage(destination, image, properties as CFDictionary)
  guard CGImageDestinationFinalize(destination) else {
    throw PerformanceBenchmarkError.unexpectedOutput
  }
  return output as Data
}

private func makeEncodeOperation(
  format: EncodedImageFormat,
  width: Int,
  height: Int
) throws -> BenchmarkOperation {
  let sourceRGB = makePatternRGBData(width: width, height: height)
  let sourceImage = try makePatternImage(width: width, height: height, rgb: sourceRGB)
  let request: ImageEncodeRequest
  switch format {
  case .png:
    request = try ImageEncodeRequest.png(
      colorPolicy: .convertToSRGB,
      metadataPolicy: .discard,
      alphaPolicy: .reject
    )
  case .jpeg:
    request = try ImageEncodeRequest.jpeg(
      quality: ImageEncodeQuality(rawValue: 0.75),
      colorPolicy: .convertToSRGB,
      metadataPolicy: .discard,
      alphaPolicy: .reject
    )
  case .gif:
    throw PerformanceBenchmarkError.invalidCase
  }
  let encoder = ImageIOImageEncoder()
  let limits = EncodeLimits(maximumEncodedBytes: 128 * 1024 * 1024)
  let reference = try encoder.encode(image: sourceImage, request: request, limits: limits)
  let output = PerformanceOutput(
    representation: reference.format.rawValue,
    pixelWidth: nil,
    pixelHeight: nil,
    encodedByteCount: reference.byteCount,
    sha256: sha256(reference.data)
  )
  let run: () throws -> Void = {
    let encoded = try encoder.encode(image: sourceImage, request: request, limits: limits)
    guard encoded.format == reference.format,
      encoded.byteCount == reference.byteCount
    else {
      throw PerformanceBenchmarkError.unexpectedOutput
    }
  }
  return BenchmarkOperation(
    source: PerformanceSource(
      generator: "imagecraft-pattern-v1",
      representation: "cgImage-srgb-rgb8",
      pixelWidth: width,
      pixelHeight: height,
      encodedByteCount: nil,
      encodedSHA256: nil,
      targetWidth: nil,
      targetHeight: nil,
      contentMode: nil
    ),
    estimatedWorkingSetBytes: nil,
    output: output,
    run: run
  )
}

private func durationStatistics(_ samples: [UInt64]) -> PerformanceDurationStatistics {
  let sorted = samples.sorted()
  let sum = samples.reduce(UInt64(0), &+)
  return PerformanceDurationStatistics(
    minimumNanoseconds: sorted[0],
    medianNanoseconds: percentile(sorted, numerator: 50, denominator: 100),
    p90Nanoseconds: percentile(sorted, numerator: 90, denominator: 100),
    maximumNanoseconds: sorted[sorted.count - 1],
    meanNanoseconds: sum / UInt64(samples.count)
  )
}

private func percentile(
  _ sorted: [UInt64],
  numerator: Int,
  denominator: Int
) -> UInt64 {
  let rank = max(1, (sorted.count * numerator + denominator - 1) / denominator)
  return sorted[min(sorted.count - 1, rank - 1)]
}

private func capturePerformanceEnvironment() -> PerformanceEnvironment {
  let processInfo = ProcessInfo.processInfo
  return PerformanceEnvironment(
    hardwareModel: sysctlString("hw.model") ?? "unknown",
    activeProcessorCount: processInfo.activeProcessorCount,
    physicalMemoryBytes: processInfo.physicalMemory,
    lowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
    thermalState: thermalStateName(processInfo.thermalState)
  )
}

private func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
  switch state {
  case .nominal: "nominal"
  case .fair: "fair"
  case .serious: "serious"
  case .critical: "critical"
  @unknown default: "unknown"
  }
}

private func sysctlString(_ name: String) -> String? {
  var size = 0
  guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
  var bytes = [CChar](repeating: 0, count: size)
  guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
  let terminator = bytes.firstIndex(of: 0) ?? bytes.endIndex
  return String(decoding: bytes[..<terminator].map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

private func residentBytes() throws -> UInt64 {
  var info = mach_task_basic_info_data_t()
  var count = mach_msg_type_number_t(
    MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
  )
  let result = withUnsafeMutablePointer(to: &info) { pointer in
    pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
      task_info(
        mach_task_self_,
        task_flavor_t(MACH_TASK_BASIC_INFO),
        rebound,
        &count
      )
    }
  }
  guard result == KERN_SUCCESS else {
    throw PerformanceBenchmarkError.residentMemoryUnavailable
  }
  return UInt64(info.resident_size)
}

private final class ResidentMemorySampler: @unchecked Sendable {
  private let lock = NSLock()
  private let group = DispatchGroup()
  private var running = false
  private var maximumResidentBytes: UInt64

  init(initialResidentBytes: UInt64) {
    self.maximumResidentBytes = initialResidentBytes
  }

  func start() {
    lock.lock()
    running = true
    lock.unlock()
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      defer { group.leave() }
      while isRunning {
        if let current = try? residentBytes() {
          lock.lock()
          maximumResidentBytes = max(maximumResidentBytes, current)
          lock.unlock()
        }
        usleep(performanceRSSSampleIntervalMicroseconds)
      }
    }
  }

  func stop() -> UInt64 {
    lock.lock()
    running = false
    lock.unlock()
    group.wait()
    lock.lock()
    defer { lock.unlock() }
    return maximumResidentBytes
  }

  private var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return running
  }
}
