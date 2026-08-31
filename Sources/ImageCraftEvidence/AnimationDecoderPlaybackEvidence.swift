import CoreGraphics
import Foundation
import ImageCraftCore
import ImageCraftImageIO

private struct AnimationDecoderFrameEvidence: Codable {
  let index: Int
  let file: String
  let byteCount: Int
  let sha256: String
  let rect: AnimationDecoderFrameRectEvidence
  let durationNumerator: UInt32
  let durationDenominator: UInt32
  let disposal: String
  let blend: String
  let reverseRandomAccessExact: Bool
}

private struct AnimationDecoderFrameRectEvidence: Codable {
  let x: Int
  let y: Int
  let width: Int
  let height: Int
}

private struct AnimationDecoderPlaybackEvidenceReport: Codable {
  let schemaVersion: Int
  let implementation: String
  let codecFingerprint: String
  let container: String
  let canvasWidth: Int
  let canvasHeight: Int
  let frameCount: Int
  let loopAdditionalRepeatCount: UInt32?
  let preparationDiagnostics: ImageIOAnimationPreparationDiagnostics
  let frames: [AnimationDecoderFrameEvidence]
  let allReverseRandomAccessExact: Bool
  let cancellationFenced: Bool
  let claimBoundary: [String]
}

func writeAnimationDecoderPlaybackEvidence(
  input: URL,
  outputDirectory: URL
) async throws {
  let encodedData = try Data(contentsOf: input, options: [.mappedIfSafe])
  let decoder = ImageIOAnimatedImageDecoder()
  let prepared = try await decoder.prepareAnimationWithDiagnostics(
    source: .encoded(encodedData)
  )
  let asset = prepared.asset
  let request = ImageDecodeRequest(
    target: try TargetPixels(
      width: asset.metadata.canvasWidth,
      height: asset.metadata.canvasHeight
    ),
    contentMode: .fit,
    colorPolicy: .convertToSRGB
  )
  let fileManager = FileManager.default
  if fileManager.fileExists(atPath: outputDirectory.path) {
    try fileManager.removeItem(at: outputDirectory)
  }
  try fileManager.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
  )

  var sequentialFrames: [DecodedAnimationFrame] = []
  var lowerBound = 0
  while lowerBound < asset.metadata.frameCount {
    let upperBound = min(asset.metadata.frameCount, lowerBound + 8)
    sequentialFrames.append(
      contentsOf: try await asset.frames(
        in: lowerBound..<upperBound,
        request: request
      )
    )
    lowerBound = upperBound
  }
  let sequentialBytes = try sequentialFrames.map { frame in
    try normalizedAnimationRGBA(frame.image.cgImage)
  }
  var reverseExact = Array(repeating: false, count: sequentialFrames.count)
  for index in asset.metadata.frames.indices.reversed() {
    let frame = try await asset.frame(at: index, request: request)
    reverseExact[index] = try normalizedAnimationRGBA(frame.image.cgImage) == sequentialBytes[index]
  }

  var frames: [AnimationDecoderFrameEvidence] = []
  frames.reserveCapacity(sequentialFrames.count)
  for (frame, bytes) in zip(sequentialFrames, sequentialBytes) {
    let index = frame.descriptor.index
    let name = String(format: "frame-%03d.rgba", index)
    try bytes.write(
      to: outputDirectory.appendingPathComponent(name),
      options: .atomic
    )
    let rect = frame.descriptor.rect
    frames.append(
      AnimationDecoderFrameEvidence(
        index: index,
        file: name,
        byteCount: bytes.count,
        sha256: sha256(bytes),
        rect: AnimationDecoderFrameRectEvidence(
          x: rect.x,
          y: rect.y,
          width: rect.width,
          height: rect.height
        ),
        durationNumerator: frame.descriptor.duration.numerator,
        durationDenominator: frame.descriptor.duration.denominator,
        disposal: frame.descriptor.disposal.rawValue,
        blend: frame.descriptor.blend.rawValue,
        reverseRandomAccessExact: reverseExact[index]
      )
    )
  }

  await asset.cancel()
  let cancellationFenced: Bool
  do {
    _ = try await asset.frame(at: 0, request: request)
    cancellationFenced = false
  } catch let error as ImageCraftError {
    cancellationFenced = error == .animationSessionCancelled
  } catch {
    cancellationFenced = false
  }
  guard cancellationFenced else { throw EvidenceError.pixelConversionFailed }

  let report = AnimationDecoderPlaybackEvidenceReport(
    schemaVersion: 1,
    implementation: "imagecraft-public-imageio-animated-decoder-v2-owned-apng-route",
    codecFingerprint: asset.metadata.codecFingerprint,
    container: asset.metadata.container.rawValue,
    canvasWidth: asset.metadata.canvasWidth,
    canvasHeight: asset.metadata.canvasHeight,
    frameCount: asset.metadata.frameCount,
    loopAdditionalRepeatCount: asset.metadata.loopCount.additionalRepeatCount,
    preparationDiagnostics: prepared.diagnostics,
    frames: frames,
    allReverseRandomAccessExact: reverseExact.allSatisfy { $0 },
    cancellationFenced: cancellationFenced,
    claimBoundary: [
      "public ImageIOAnimatedImageDecoder and AnimatedImageAsset provider route",
      "full-canvas convertToSRGB requests only",
      "correctness and lifecycle evidence only",
      "no latency, energy, thermal, or physical-device claim",
      "the owned route is admitted only for the internal RGBA8 non-interlaced <=1024 policy",
    ]
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  let reportURL = outputDirectory.appendingPathComponent("report.json")
  try encoder.encode(report).write(to: reportURL, options: .atomic)
  print(reportURL.path)
}

func normalizedAnimationRGBA(_ image: CGImage) throws -> Data {
  guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
    throw EvidenceError.pixelConversionFailed
  }
  let rowBytes = image.width.multipliedReportingOverflow(by: 4)
  let total = rowBytes.partialValue.multipliedReportingOverflow(by: image.height)
  guard !rowBytes.overflow, !total.overflow else {
    throw EvidenceError.pixelConversionFailed
  }
  var pixels = Data(count: total.partialValue)
  let rendered = pixels.withUnsafeMutableBytes { raw -> Bool in
    guard let address = raw.baseAddress,
      let context = CGContext(
        data: address,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: rowBytes.partialValue,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue
      )
    else { return false }
    context.setBlendMode(.copy)
    context.draw(
      image,
      in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
    )
    return true
  }
  guard rendered else { throw EvidenceError.pixelConversionFailed }
  return pixels
}
