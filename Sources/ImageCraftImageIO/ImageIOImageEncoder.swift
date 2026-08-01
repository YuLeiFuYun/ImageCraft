import CoreGraphics
import Foundation
import ImageCraftCore
import ImageIO
import UniformTypeIdentifiers

/// 基于 Apple ImageIO 的静态 PNG/JPEG 编码器。
/// 编码器只负责把规范化像素和显式选项映射到 ImageIO；Fovea 的缓存身份、
/// namespace、发布资格与资源调度不进入该适配器。
public struct ImageIOImageEncoder: ImageEncoding {
  public let encoderDescriptor = ImageEncoderDescriptor(
    identifier: ImageEncoderIdentifier(rawValue: "dev.imagecraft.imageio.encoder"),
    implementationVersion: 2,
    capabilities: ImageEncoderCapabilities(
      formats: [.png, .jpeg],
      losslessFormats: [.png],
      lossyFormats: [.jpeg],
      alphaPreservingFormats: [.png],
      alphaFlatteningFormats: [.png, .jpeg],
      colorPolicies: Set(ImageEncodeColorPolicy.allCases),
      metadataPolicies: Set(ImageEncodeMetadataPolicy.allCases)
    )
  )

  public init() {}

  public func encode(
    image: CGImage,
    request: ImageEncodeRequest,
    limits: EncodeLimits = .coreV1
  ) throws -> EncodedImage {
    let sourceHasAlpha = Self.hasAlpha(image)
    try encoderDescriptor.requireSupport(request, sourceHasAlpha: sourceHasAlpha)
    guard limits.allowedFormats.contains(request.format) else {
      throw ImageEncodingError.formatNotAllowed(request.format)
    }
    if sourceHasAlpha, case .reject = request.alphaPolicy {
      throw ImageEncodingError.alphaRejected
    }
    try validate(image: image, limits: limits)

    let normalized = try normalizedImage(image, request: request)
    let boundedConsumer = try BoundedDataConsumer(maximumBytes: limits.maximumEncodedBytes)
    guard
      let destination = CGImageDestinationCreateWithDataConsumer(
        boundedConsumer.consumer,
        typeIdentifier(for: request.format),
        1,
        nil
      )
    else {
      throw ImageEncodingError.encodeFailed
    }

    var imageProperties: [CFString: Any] = [:]
    if request.metadataPolicy == .preserveRecognized,
      let orientation = request.orientation
    {
      imageProperties[kCGImagePropertyOrientation] = orientation.rawValue
    }
    if case .lossy(let quality) = request.compression {
      imageProperties[kCGImageDestinationLossyCompressionQuality] = quality.rawValue
    }
    CGImageDestinationAddImage(
      destination,
      normalized,
      imageProperties.isEmpty ? nil : imageProperties as CFDictionary
    )
    let finalized = CGImageDestinationFinalize(destination)
    let consumerSnapshot = boundedConsumer.snapshot
    if consumerSnapshot.didRejectWrite {
      throw ImageEncodingError.encodedBytesExceeded
    }
    guard finalized else {
      throw ImageEncodingError.encodeFailed
    }

    let encoded = consumerSnapshot.data
    let inspection: EncodedImageSecurityInspection
    do {
      inspection = try EncodedImageSecurityInspector.inspect(
        encoded,
        maximumMetadataBytes: limits.maximumEncodedBytes
      )
    } catch {
      throw ImageEncodingError.encodeFailed
    }
    guard inspection.format == request.format else {
      throw ImageEncodingError.encodeFailed
    }
    return EncodedImage(data: encoded, format: request.format)
  }

  private func normalizedImage(
    _ image: CGImage,
    request: ImageEncodeRequest
  ) throws -> CGImage {
    let flattenBackground: ImageEncodeBackgroundColor?
    if case .flatten(let background) = request.alphaPolicy {
      flattenBackground = background
    } else {
      flattenBackground = nil
    }

    if request.colorPolicy == .preserveSource,
      flattenBackground == nil,
      image.colorSpace != nil
    {
      return image
    }

    guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else {
      throw ImageEncodingError.colorConversionFailed
    }
    let targetColorSpace: CGColorSpace
    switch request.colorPolicy {
    case .convertToSRGB:
      targetColorSpace = srgb
    case .preserveSource:
      if let source = image.colorSpace, source.model == .rgb {
        targetColorSpace = source
      } else {
        targetColorSpace = srgb
      }
    }

    let bytesPerRow = image.width * 4
    let preserveAlpha = flattenBackground == nil && Self.hasAlpha(image)
    let alphaInfo: CGImageAlphaInfo = preserveAlpha ? .premultipliedLast : .noneSkipLast
    guard
      let context = CGContext(
        data: nil,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: targetColorSpace,
        bitmapInfo: alphaInfo.rawValue
      )
    else {
      throw ImageEncodingError.colorConversionFailed
    }

    context.setBlendMode(.copy)
    if let background = flattenBackground {
      context.setFillColor(
        red: CGFloat(background.red) / 255,
        green: CGFloat(background.green) / 255,
        blue: CGFloat(background.blue) / 255,
        alpha: 1
      )
      context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
      context.setBlendMode(.normal)
    }
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let result = context.makeImage() else {
      throw ImageEncodingError.colorConversionFailed
    }
    return result
  }

  private func validate(image: CGImage, limits: EncodeLimits) throws {
    guard image.width <= limits.maximumDimension, image.height <= limits.maximumDimension else {
      throw ImageEncodingError.dimensionLimitExceeded
    }
    let pixels = image.width.multipliedReportingOverflow(by: image.height)
    guard !pixels.overflow, pixels.partialValue <= limits.maximumPixelCount else {
      throw ImageEncodingError.pixelLimitExceeded
    }
  }

  private func typeIdentifier(for format: EncodedImageFormat) -> CFString {
    switch format {
    case .png: UTType.png.identifier as CFString
    case .jpeg: UTType.jpeg.identifier as CFString
    case .gif: UTType.gif.identifier as CFString
    }
  }

  private static func hasAlpha(_ image: CGImage) -> Bool {
    switch image.alphaInfo {
    case .premultipliedFirst, .premultipliedLast, .first, .last, .alphaOnly:
      true
    case .none, .noneSkipFirst, .noneSkipLast:
      false
    @unknown default:
      true
    }
  }
}
