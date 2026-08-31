import CoreGraphics
import CryptoKit
import Foundation
import ImageCraftCore
import ImageCraftImageIO
import ImageIO

private struct TimingReport: Codable {
  let medianNanoseconds: UInt64
  let p95Nanoseconds: UInt64
  let samplesNanoseconds: [UInt64]
}

private struct MeasurementOrderReport: Codable {
  let preparation: [String]
  let selectedFrame: [String]
  let sequentialFrames: [String]
}

private struct AnimationReport: Codable {
  let schemaVersion: Int
  let inputPath: String
  let inputByteCount: Int
  let inputSHA256: String
  let container: String
  let frameCount: Int
  let canvasWidth: Int
  let canvasHeight: Int
  let targetWidth: Int
  let targetHeight: Int
  let selectedFrameIndex: Int
  let frameDecodeWindowSize: Int
  let selectedFramePixelSHA256: String
  let directFramePixelSHA256: String
  let measurementOrders: MeasurementOrderReport
  let imageCraftPrepare: TimingReport
  let directImageIOPrepareLowerBound: TimingReport
  let imageCraftSelectedFrame: TimingReport
  let directImageIOColdSelectedFrame: TimingReport
  let directImageIORetainedSourceSelectedFrame: TimingReport
  let imageCraftSequentialAllFrames: TimingReport
  let directImageIORetainedSourceAllFrames: TimingReport
  let directImageIOUnboundedCachedAllFrames: TimingReport
}

private enum LabInput {
  case encoded(url: URL, data: Data)
  case jpegSequence(directory: URL, frames: [Data])

  func source() throws -> ImageAnimationSource {
    switch self {
    case .encoded(_, let data):
      return .encoded(data)
    case .jpegSequence(_, let frames):
      let duration = try ImageAnimationFrameDuration(numerator: 1, denominator: 24)
      return .jpegSequence(
        frames: frames.map { ImageJPEGAnimationFrame(data: $0, duration: duration) },
        loopCount: .infinite
      )
    }
  }

  var path: String {
    switch self {
    case .encoded(let url, _), .jpegSequence(let url, _): url.path
    }
  }

  var byteCount: Int {
    switch self {
    case .encoded(_, let data): data.count
    case .jpegSequence(_, let frames): frames.reduce(0) { $0 + $1.count }
    }
  }

  var digest: String {
    var canonical = Data()
    switch self {
    case .encoded(_, let data):
      canonical.append(data)
    case .jpegSequence(_, let frames):
      for frame in frames {
        canonical.appendBigEndian(UInt64(frame.count))
        canonical.append(frame)
      }
    }
    return animationSHA256(canonical)
  }
}

private enum DirectInput {
  case encoded(data: Data, source: CGImageSource)
  case jpegSequence(data: [Data], sources: [CGImageSource])

  static func prepare(from input: LabInput) throws -> DirectInput {
    switch input {
    case .encoded(_, let data):
      return .encoded(data: data, source: try makeSource(data))
    case .jpegSequence(_, let frames):
      return .jpegSequence(data: frames, sources: try frames.map(makeSource))
    }
  }

  func validate(expectedFrameCount: Int) throws {
    switch self {
    case .encoded(_, let source):
      guard CGImageSourceGetCount(source) == expectedFrameCount else {
        throw LabError.imageSourceFailure
      }
      for index in 0..<expectedFrameCount {
        guard CGImageSourceCopyPropertiesAtIndex(source, index, nil) != nil else {
          throw LabError.imageSourceFailure
        }
      }
    case .jpegSequence(_, let sources):
      guard sources.count == expectedFrameCount else { throw LabError.imageSourceFailure }
      for source in sources {
        guard CGImageSourceGetCount(source) == 1,
          CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil
        else { throw LabError.imageSourceFailure }
      }
    }
  }

  func coldFrame(
    at index: Int,
    request: ImageDecodeRequest,
    canvasWidth: Int,
    canvasHeight: Int
  ) throws -> DecodedImage {
    switch self {
    case .encoded(let data, _):
      return try directFrame(
        source: makeSource(data),
        index: index,
        request: request,
        canvasWidth: canvasWidth,
        canvasHeight: canvasHeight,
        allowsFullImageCache: true
      )
    case .jpegSequence(let frames, _):
      return try directFrame(
        source: makeSource(frames[index]),
        index: 0,
        request: request,
        canvasWidth: canvasWidth,
        canvasHeight: canvasHeight,
        allowsFullImageCache: true
      )
    }
  }

  func retainedFrame(
    at index: Int,
    request: ImageDecodeRequest,
    canvasWidth: Int,
    canvasHeight: Int,
    allowsFullImageCache: Bool
  ) throws -> DecodedImage {
    switch self {
    case .encoded(_, let source):
      return try directFrame(
        source: source,
        index: index,
        request: request,
        canvasWidth: canvasWidth,
        canvasHeight: canvasHeight,
        allowsFullImageCache: allowsFullImageCache
      )
    case .jpegSequence(_, let sources):
      return try directFrame(
        source: sources[index],
        index: 0,
        request: request,
        canvasWidth: canvasWidth,
        canvasHeight: canvasHeight,
        allowsFullImageCache: allowsFullImageCache
      )
    }
  }
}

func writeAnimationPerformanceEvidence(
  arguments: AnimationPerformanceArguments
) async throws {
  let input = try arguments.loadInput()
  let animationSource = try input.source()
  let target = try TargetPixels(width: arguments.targetWidth, height: arguments.targetHeight)
  let request = ImageDecodeRequest(target: target, colorPolicy: .convertToSRGB)
  let decoder = ImageIOAnimatedImageDecoder()
  let asset = try await decoder.prepareAnimation(source: animationSource)
  guard asset.metadata.frames.indices.contains(arguments.frameIndex) else {
    throw LabError.invalidArguments
  }
  let direct = try DirectInput.prepare(from: input)
  try direct.validate(expectedFrameCount: asset.metadata.frameCount)
  let frameWindowSize = min(8, asset.metadata.frameCount)

  for _ in 0..<arguments.warmupIterations {
    _ = try await decoder.prepareAnimation(source: animationSource)
    _ = try await asset.frame(at: arguments.frameIndex, request: request)
    _ = try direct.coldFrame(
      at: arguments.frameIndex,
      request: request,
      canvasWidth: asset.metadata.canvasWidth,
      canvasHeight: asset.metadata.canvasHeight
    )
    for index in asset.metadata.frames.indices {
      _ = try direct.retainedFrame(
        at: index,
        request: request,
        canvasWidth: asset.metadata.canvasWidth,
        canvasHeight: asset.metadata.canvasHeight,
        allowsFullImageCache: true
      )
    }
  }

  let preparation = try await measurePair(
    count: arguments.iterations,
    firstLabel: "imagecraft",
    secondLabel: "direct-imageio"
  ) {
    _ = try await decoder.prepareAnimation(source: animationSource)
  } second: {
    let prepared = try DirectInput.prepare(from: input)
    try prepared.validate(expectedFrameCount: asset.metadata.frameCount)
  }
  let selectedFrames = try await measureTriple(
    count: arguments.iterations,
    labels: ["imagecraft", "direct-cold", "direct-retained"],
    operations: [
      {
        _ = try await asset.frame(at: arguments.frameIndex, request: request)
      },
      {
        _ = try direct.coldFrame(
          at: arguments.frameIndex,
          request: request,
          canvasWidth: asset.metadata.canvasWidth,
          canvasHeight: asset.metadata.canvasHeight
        )
      },
      {
        _ = try direct.retainedFrame(
          at: arguments.frameIndex,
          request: request,
          canvasWidth: asset.metadata.canvasWidth,
          canvasHeight: asset.metadata.canvasHeight,
          allowsFullImageCache: false
        )
      },
    ]
  )
  let sequences = try await measurePair(
    count: arguments.iterations,
    firstLabel: "imagecraft-windowed",
    secondLabel: "direct-retained"
  ) {
    var lowerBound = 0
    while lowerBound < asset.metadata.frameCount {
      let upperBound = min(asset.metadata.frameCount, lowerBound + frameWindowSize)
      _ = try await asset.frames(in: lowerBound..<upperBound, request: request)
      lowerBound = upperBound
    }
  } second: {
    for index in asset.metadata.frames.indices {
      _ = try direct.retainedFrame(
        at: index,
        request: request,
        canvasWidth: asset.metadata.canvasWidth,
        canvasHeight: asset.metadata.canvasHeight,
        allowsFullImageCache: false
      )
    }
  }
  let unboundedCachedSequence = try await measurePair(
    count: arguments.iterations,
    firstLabel: "imagecraft-windowed",
    secondLabel: "direct-unbounded-cached"
  ) {
    var lowerBound = 0
    while lowerBound < asset.metadata.frameCount {
      let upperBound = min(asset.metadata.frameCount, lowerBound + frameWindowSize)
      _ = try await asset.frames(in: lowerBound..<upperBound, request: request)
      lowerBound = upperBound
    }
  } second: {
    for index in asset.metadata.frames.indices {
      _ = try direct.retainedFrame(
        at: index,
        request: request,
        canvasWidth: asset.metadata.canvasWidth,
        canvasHeight: asset.metadata.canvasHeight,
        allowsFullImageCache: true
      )
    }
  }

  let selectedFrame = try await asset.frame(
    at: arguments.frameIndex,
    request: request
  )
  let selected = selectedFrame.image
  let directSelected = try direct.retainedFrame(
    at: arguments.frameIndex,
    request: request,
    canvasWidth: asset.metadata.canvasWidth,
    canvasHeight: asset.metadata.canvasHeight,
    allowsFullImageCache: false
  )
  let report = AnimationReport(
    schemaVersion: 3,
    inputPath: input.path,
    inputByteCount: input.byteCount,
    inputSHA256: input.digest,
    container: asset.metadata.container.rawValue,
    frameCount: asset.metadata.frameCount,
    canvasWidth: asset.metadata.canvasWidth,
    canvasHeight: asset.metadata.canvasHeight,
    targetWidth: target.width,
    targetHeight: target.height,
    selectedFrameIndex: arguments.frameIndex,
    frameDecodeWindowSize: frameWindowSize,
    selectedFramePixelSHA256: try pixelSHA256(selected.cgImage),
    directFramePixelSHA256: try pixelSHA256(directSelected.cgImage),
    measurementOrders: MeasurementOrderReport(
      preparation: preparation.orders,
      selectedFrame: selectedFrames.orders,
      sequentialFrames: sequences.orders
    ),
    imageCraftPrepare: timing(preparation.first),
    directImageIOPrepareLowerBound: timing(preparation.second),
    imageCraftSelectedFrame: timing(selectedFrames.samples[0]),
    directImageIOColdSelectedFrame: timing(selectedFrames.samples[1]),
    directImageIORetainedSourceSelectedFrame: timing(selectedFrames.samples[2]),
    imageCraftSequentialAllFrames: timing(sequences.first),
    directImageIORetainedSourceAllFrames: timing(sequences.second),
    directImageIOUnboundedCachedAllFrames: timing(unboundedCachedSequence.second)
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  let output = try encoder.encode(report)
  try output.write(to: arguments.output, options: .atomic)
  print(arguments.output.path)
}

struct AnimationPerformanceArguments: Sendable {
  let input: URL?
  let jpegSequenceDirectory: URL?
  let output: URL
  let targetWidth: Int
  let targetHeight: Int
  let frameIndex: Int
  let iterations: Int
  let warmupIterations: Int

  init(_ values: [String]) throws {
    func value(_ name: String) -> String? {
      guard let index = values.firstIndex(of: name), index + 1 < values.count else {
        return nil
      }
      return values[index + 1]
    }
    let input = value("--input").map { URL(fileURLWithPath: $0) }
    let jpegDirectory = value("--jpeg-sequence-directory").map {
      URL(fileURLWithPath: $0, isDirectory: true)
    }
    guard (input == nil) != (jpegDirectory == nil),
      let output = value("--output"),
      let targetWidth = value("--target-width").flatMap(Int.init),
      let targetHeight = value("--target-height").flatMap(Int.init),
      let frameIndex = value("--frame-index").flatMap(Int.init),
      let iterations = value("--iterations").flatMap(Int.init),
      let warmups = value("--warmups").flatMap(Int.init),
      targetWidth > 0, targetHeight > 0, frameIndex >= 0,
      iterations > 0, warmups >= 0
    else { throw LabError.invalidArguments }
    self.input = input
    self.jpegSequenceDirectory = jpegDirectory
    self.output = URL(fileURLWithPath: output)
    self.targetWidth = targetWidth
    self.targetHeight = targetHeight
    self.frameIndex = frameIndex
    self.iterations = iterations
    self.warmupIterations = warmups
  }

  fileprivate func loadInput() throws -> LabInput {
    if let input { return .encoded(url: input, data: try Data(contentsOf: input)) }
    guard let directory = jpegSequenceDirectory else { throw LabError.invalidArguments }
    let urls = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    ).filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !urls.isEmpty else { throw LabError.invalidArguments }
    return .jpegSequence(
      directory: directory,
      frames: try urls.map { try Data(contentsOf: $0) }
    )
  }
}

private enum LabError: Error {
  case invalidArguments
  case imageSourceFailure
  case imageDecodeFailure
}

private func makeSource(_ data: Data) throws -> CGImageSource {
  guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
    throw LabError.imageSourceFailure
  }
  return source
}

private func directFrame(
  source: CGImageSource,
  index: Int,
  request: ImageDecodeRequest,
  canvasWidth: Int,
  canvasHeight: Int,
  allowsFullImageCache: Bool
) throws -> DecodedImage {
  let widthScale = Double(request.target.width) / Double(canvasWidth)
  let heightScale = Double(request.target.height) / Double(canvasHeight)
  let scale = min(
    1,
    request.contentMode == .fit
      ? min(widthScale, heightScale)
      : max(widthScale, heightScale))
  let maximumDimension = max(1, Int(floor(Double(max(canvasWidth, canvasHeight)) * scale)))
  let image: CGImage?
  if allowsFullImageCache,
    maximumDimension == max(canvasWidth, canvasHeight)
  {
    image = CGImageSourceCreateImageAtIndex(
      source,
      index,
      [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
    )
  } else {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    image = CGImageSourceCreateThumbnailAtIndex(
      source,
      index,
      options as CFDictionary
    )
  }
  guard let image else { throw LabError.imageDecodeFailure }
  return DecodedImage(cgImage: image, sourceColorProfile: .unknown)
}

private typealias AnimationMeasurementOperation = () async throws -> Void

private func measurePair(
  count: Int,
  firstLabel: String,
  secondLabel: String,
  first: AnimationMeasurementOperation,
  second: AnimationMeasurementOperation
) async throws -> (first: [UInt64], second: [UInt64], orders: [String]) {
  var firstSamples: [UInt64] = []
  var secondSamples: [UInt64] = []
  var orders: [String] = []
  firstSamples.reserveCapacity(count)
  secondSamples.reserveCapacity(count)
  orders.reserveCapacity(count)
  for index in 0..<count {
    if index.isMultiple(of: 2) {
      firstSamples.append(try await measured(first))
      secondSamples.append(try await measured(second))
      orders.append("\(firstLabel)>\(secondLabel)")
    } else {
      secondSamples.append(try await measured(second))
      firstSamples.append(try await measured(first))
      orders.append("\(secondLabel)>\(firstLabel)")
    }
  }
  return (firstSamples, secondSamples, orders)
}

private func measureTriple(
  count: Int,
  labels: [String],
  operations: [AnimationMeasurementOperation]
) async throws -> (samples: [[UInt64]], orders: [String]) {
  guard labels.count == 3, operations.count == 3 else { throw LabError.invalidArguments }
  var samples = Array(repeating: [UInt64](), count: 3)
  var orders: [String] = []
  for index in 0..<3 { samples[index].reserveCapacity(count) }
  orders.reserveCapacity(count)
  for iteration in 0..<count {
    let order = (0..<3).map { (iteration + $0) % 3 }
    for operationIndex in order {
      samples[operationIndex].append(try await measured(operations[operationIndex]))
    }
    orders.append(order.map { labels[$0] }.joined(separator: ">"))
  }
  return (samples, orders)
}

private func measured(_ operation: AnimationMeasurementOperation) async throws -> UInt64 {
  let start = DispatchTime.now().uptimeNanoseconds
  try await operation()
  return DispatchTime.now().uptimeNanoseconds &- start
}

private func timing(_ samples: [UInt64]) -> TimingReport {
  let sorted = samples.sorted()
  let median = sorted[sorted.count / 2]
  let p95Index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
  return TimingReport(
    medianNanoseconds: median,
    p95Nanoseconds: sorted[p95Index],
    samplesNanoseconds: samples
  )
}

private func animationSHA256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func pixelSHA256(_ image: CGImage) throws -> String {
  guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
    throw LabError.imageDecodeFailure
  }
  let bytesPerRow = image.width * 4
  var bytes = Data(count: bytesPerRow * image.height)
  let rendered = bytes.withUnsafeMutableBytes { raw -> Bool in
    guard let address = raw.baseAddress,
      let context = CGContext(
        data: address,
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
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return true
  }
  guard rendered else { throw LabError.imageDecodeFailure }
  return animationSHA256(bytes)
}

extension Data {
  fileprivate mutating func appendBigEndian(_ value: UInt64) {
    for shift in stride(from: 56, through: 0, by: -8) {
      append(UInt8((value >> UInt64(shift)) & 0xff))
    }
  }
}
