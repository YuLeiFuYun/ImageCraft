import CoreGraphics
import Foundation
import ImageCraftCore
import ImageIO

enum ImageIOAnimationFrameRenderer {
  static func decode(
    source: ImageIOAnimationSourceBox,
    index: Int,
    inspection: EncodedAnimationInspection,
    request: ImageDecodeRequest,
    limits: DecodeLimits,
    prefersCachedFullImage: Bool
  ) throws -> DecodedImage {
    let maximumDimension = targetMaximumDimension(
      canvasWidth: inspection.canvasWidth,
      canvasHeight: inspection.canvasHeight,
      request: request,
      limits: limits
    )
    let raster: CGImage
    if prefersCachedFullImage,
      maximumDimension == max(inspection.canvasWidth, inspection.canvasHeight)
    {
      raster = try source.image(
        at: index,
        options: [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
      )
    } else {
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
        kCGImageSourceShouldCacheImmediately: true,
      ]
      raster = try source.thumbnail(at: index, options: options as CFDictionary)
    }
    let normalized = try colorNormalizedImage(
      raster,
      sourceColorProfile: inspection.sourceColorProfile,
      embeddedICCProfile: inspection.embeddedICCProfile,
      policy: request.colorPolicy
    )
    return try finalize(
      normalized,
      request: request,
      limits: limits,
      sourceProfile: inspection.sourceColorProfile
    )
  }

  static func decodeOwnedRGBA(
    premultipliedRGBA: Data,
    inspection: EncodedAnimationInspection,
    request: ImageDecodeRequest,
    limits: DecodeLimits
  ) throws -> DecodedImage {
    let source = try imageFromPremultipliedRGBA(
      premultipliedRGBA,
      width: inspection.canvasWidth,
      height: inspection.canvasHeight,
      sourceColorProfile: inspection.sourceColorProfile,
      embeddedICCProfile: inspection.embeddedICCProfile
    )
    let maximumDimension = targetMaximumDimension(
      canvasWidth: inspection.canvasWidth,
      canvasHeight: inspection.canvasHeight,
      request: request,
      limits: limits
    )
    let raster = try scaledImage(
      source,
      maximumDimension: maximumDimension
    )
    let normalized = try colorNormalizedImage(
      raster,
      sourceColorProfile: inspection.sourceColorProfile,
      embeddedICCProfile: inspection.embeddedICCProfile,
      policy: request.colorPolicy
    )
    return try finalize(
      normalized,
      request: request,
      limits: limits,
      sourceProfile: inspection.sourceColorProfile
    )
  }

  static func decodeJPEG(
    frame: ImageIOJPEGAnimationFrameSource,
    sourceColorProfile: SourceColorProfile,
    embeddedICCProfile: Data?,
    request: ImageDecodeRequest,
    canvasWidth: Int,
    canvasHeight: Int,
    limits: DecodeLimits,
    prefersCachedFullImage: Bool
  ) throws -> DecodedImage {
    guard let rawSource = CGImageSourceCreateWithData(frame.data as CFData, nil),
      CGImageSourceGetCount(rawSource) == 1,
      CGImageSourceGetType(rawSource) as String? == "public.jpeg"
    else { throw ImageCraftError.formatMismatch }
    // The source is intentionally reconstructed inside the operation. Prepared JPEG sequences retain
    // immutable encoded Data + validated color facts across calls, not framework-private CGImageSource
    // state whose retained allocation cannot be bounded by ImageCraft.
    let source = ImageIOAnimationSourceBox(source: rawSource)
    let maximumDimension = targetMaximumDimension(
      canvasWidth: canvasWidth,
      canvasHeight: canvasHeight,
      request: request,
      limits: limits
    )
    let raster: CGImage
    if prefersCachedFullImage,
      maximumDimension == max(canvasWidth, canvasHeight)
    {
      raster = try source.image(
        at: 0,
        options: [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
      )
    } else {
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
        kCGImageSourceShouldCacheImmediately: true,
      ]
      raster = try source.thumbnail(at: 0, options: options as CFDictionary)
    }
    let normalized = try colorNormalizedImage(
      raster,
      sourceColorProfile: sourceColorProfile,
      embeddedICCProfile: embeddedICCProfile,
      policy: request.colorPolicy
    )
    return try finalize(
      normalized,
      request: request,
      limits: limits,
      sourceProfile: sourceColorProfile
    )
  }

  private static func imageFromPremultipliedRGBA(
    _ bytes: Data,
    width: Int,
    height: Int,
    sourceColorProfile: SourceColorProfile,
    embeddedICCProfile: Data?
  ) throws -> CGImage {
    let rowBytes = width.multipliedReportingOverflow(by: 4)
    let totalBytes = rowBytes.partialValue.multipliedReportingOverflow(by: height)
    guard width > 0, height > 0,
      !rowBytes.overflow,
      !totalBytes.overflow,
      totalBytes.partialValue == bytes.count,
      let provider = CGDataProvider(data: bytes as CFData),
      let colorSpace = try sourceColorSpace(
        sourceColorProfile: sourceColorProfile,
        embeddedICCProfile: embeddedICCProfile
      )
    else { throw ImageCraftError.decodeFailed }
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
      CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    )
    guard
      let image = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: rowBytes.partialValue,
        space: colorSpace,
        bitmapInfo: bitmapInfo,
        provider: provider,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
      )
    else { throw ImageCraftError.decodeFailed }
    return image
  }

  private static func sourceColorSpace(
    sourceColorProfile: SourceColorProfile,
    embeddedICCProfile: Data?
  ) throws -> CGColorSpace? {
    switch sourceColorProfile {
    case .embeddedICC:
      guard let embeddedICCProfile,
        let colorSpace = CGColorSpace(iccData: embeddedICCProfile as CFData),
        colorSpace.model == .rgb
      else { throw ImageCraftError.unsupportedOrCorruptImage }
      return colorSpace
    case .absent, .standardSRGB, .unknown:
      return CGColorSpace(name: CGColorSpace.sRGB)
    }
  }

  private static func scaledImage(
    _ image: CGImage,
    maximumDimension: Int
  ) throws -> CGImage {
    let sourceMaximum = max(image.width, image.height)
    guard maximumDimension > 0 else { throw ImageCraftError.invalidTarget }
    guard maximumDimension < sourceMaximum else { return image }
    let scale = Double(maximumDimension) / Double(sourceMaximum)
    let width = max(1, Int(floor(Double(image.width) * scale)))
    let height = max(1, Int(floor(Double(image.height) * scale)))
    let rowBytes = width.multipliedReportingOverflow(by: 4)
    guard !rowBytes.overflow,
      let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: rowBytes.partialValue,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
          CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        ).rawValue
      )
    else { throw ImageCraftError.decodeFailed }
    context.interpolationQuality = .high
    context.setBlendMode(.copy)
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let result = context.makeImage() else { throw ImageCraftError.decodeFailed }
    return result
  }

  /// Returns a no-decode whole-track byte-cost upper bound for the owned-RGBA path.
  ///
  /// The owned APNG path starts with exactly `canvasWidth * 4` bytes per row. Any scale or color
  /// conversion creates another explicit four-byte RGBA context with `rowBytes = width * 4`. A
  /// fill crop can retain the parent stride, so its conservative per-frame cost uses the pre-crop
  /// raster width and the cropped height. Other backends do not use this estimator.
  static func ownedRGBAWholeTrackDecodedByteCostUpperBound(
    canvasWidth: Int,
    canvasHeight: Int,
    frameCount: Int,
    request: ImageDecodeRequest,
    limits: DecodeLimits
  ) -> Int? {
    guard
      let geometry = ownedRGBAOutputGeometry(
        canvasWidth: canvasWidth,
        canvasHeight: canvasHeight,
        request: request,
        limits: limits
      )
    else { return nil }
    let rowBytes = geometry.rasterWidth.multipliedReportingOverflow(by: 4)
    guard !rowBytes.overflow else { return nil }
    let frameBytes = rowBytes.partialValue.multipliedReportingOverflow(
      by: geometry.retainedHeight
    )
    guard !frameBytes.overflow else { return nil }
    let totalBytes = frameBytes.partialValue.multipliedReportingOverflow(by: frameCount)
    guard !totalBytes.overflow, totalBytes.partialValue > 0 else { return nil }
    return totalBytes.partialValue
  }

  static func ownedRGBARasterTrackByteCostUpperBound(
    canvasWidth: Int,
    canvasHeight: Int,
    frameCount: Int,
    request: ImageDecodeRequest,
    limits: DecodeLimits
  ) -> Int? {
    guard
      let geometry = ownedRGBAOutputGeometry(
        canvasWidth: canvasWidth,
        canvasHeight: canvasHeight,
        request: request,
        limits: limits
      )
    else { return nil }
    let rowBytes = geometry.rasterWidth.multipliedReportingOverflow(by: 4)
    guard !rowBytes.overflow else { return nil }
    let frameBytes = rowBytes.partialValue.multipliedReportingOverflow(by: geometry.rasterHeight)
    guard !frameBytes.overflow else { return nil }
    let totalBytes = frameBytes.partialValue.multipliedReportingOverflow(by: frameCount)
    guard !totalBytes.overflow, totalBytes.partialValue > 0 else { return nil }
    return totalBytes.partialValue
  }

  private static func ownedRGBAOutputGeometry(
    canvasWidth: Int,
    canvasHeight: Int,
    request: ImageDecodeRequest,
    limits: DecodeLimits
  ) -> (rasterWidth: Int, rasterHeight: Int, retainedHeight: Int)? {
    guard canvasWidth > 0, canvasHeight > 0 else { return nil }
    let maximumDimension = targetMaximumDimension(
      canvasWidth: canvasWidth,
      canvasHeight: canvasHeight,
      request: request,
      limits: limits
    )
    let sourceMaximum = max(canvasWidth, canvasHeight)
    let rasterWidth: Int
    let rasterHeight: Int
    if maximumDimension >= sourceMaximum {
      rasterWidth = canvasWidth
      rasterHeight = canvasHeight
    } else {
      let scale = Double(maximumDimension) / Double(sourceMaximum)
      rasterWidth = max(1, Int(floor(Double(canvasWidth) * scale)))
      rasterHeight = max(1, Int(floor(Double(canvasHeight) * scale)))
    }
    let retainedHeight: Int
    switch request.contentMode {
    case .fit:
      retainedHeight = rasterHeight
    case .fill:
      retainedHeight = min(request.target.height, rasterHeight)
    }
    return (rasterWidth, rasterHeight, retainedHeight)
  }

  private static func targetMaximumDimension(
    canvasWidth: Int,
    canvasHeight: Int,
    request: ImageDecodeRequest,
    limits: DecodeLimits
  ) -> Int {
    let widthScale = Double(request.target.width) / Double(canvasWidth)
    let heightScale = Double(request.target.height) / Double(canvasHeight)
    let requestedScale =
      request.contentMode == .fit
      ? min(widthScale, heightScale)
      : max(widthScale, heightScale)
    let scale = min(1, requestedScale)
    return max(
      1,
      min(
        limits.maximumDimension,
        Int(floor(Double(max(canvasWidth, canvasHeight)) * scale))
      )
    )
  }

  private static func colorNormalizedImage(
    _ image: CGImage,
    sourceColorProfile: SourceColorProfile,
    embeddedICCProfile: Data?,
    policy: ImageColorPolicy
  ) throws -> CGImage {
    let interpreted: CGColorSpace?
    switch sourceColorProfile {
    case .absent, .standardSRGB:
      interpreted = CGColorSpace(name: CGColorSpace.sRGB)
    case .embeddedICC:
      if let profile = embeddedICCProfile {
        guard let colorSpace = CGColorSpace(iccData: profile as CFData),
          colorSpace.model == .rgb
        else { throw ImageCraftError.unsupportedOrCorruptImage }
        interpreted = colorSpace
      } else {
        interpreted = image.colorSpace
      }
    case .unknown:
      interpreted = image.colorSpace
    }
    let tagged = try applyColorSpace(interpreted, to: image)
    guard policy == .convertToSRGB else { return tagged }
    guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else {
      throw ImageCraftError.decodeFailed
    }
    if colorSpacesMatch(tagged.colorSpace, srgb) { return tagged }
    return try convert(tagged, to: srgb)
  }

  private static func applyColorSpace(
    _ colorSpace: CGColorSpace?,
    to image: CGImage
  ) throws -> CGImage {
    guard let colorSpace else { return image }
    if colorSpacesMatch(image.colorSpace, colorSpace) { return image }
    if image.colorSpace?.model == colorSpace.model || image.colorSpace == nil {
      return try ImageIOImageDecoder.imageByAssigningColorSpace(colorSpace, to: image)
    }
    return try convert(image, to: colorSpace)
  }

  private static func convert(_ image: CGImage, to colorSpace: CGColorSpace) throws -> CGImage {
    guard colorSpace.model == .rgb else { throw ImageCraftError.decodeFailed }
    let rowBytes = image.width.multipliedReportingOverflow(by: 4)
    guard !rowBytes.overflow else { throw ImageCraftError.decodeFailed }
    let alpha: CGImageAlphaInfo
    switch image.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast: alpha = .noneSkipLast
    default: alpha = .premultipliedLast
    }
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
      CGBitmapInfo(rawValue: alpha.rawValue)
    )
    guard
      let context = CGContext(
        data: nil,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: rowBytes.partialValue,
        space: colorSpace,
        bitmapInfo: bitmapInfo.rawValue
      )
    else { throw ImageCraftError.decodeFailed }
    context.setBlendMode(.copy)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let converted = context.makeImage() else { throw ImageCraftError.decodeFailed }
    return converted
  }

  private static func colorSpacesMatch(
    _ lhs: CGColorSpace?,
    _ rhs: CGColorSpace?
  ) -> Bool {
    guard let lhs, let rhs else { return lhs == nil && rhs == nil }
    if CFEqual(lhs, rhs) { return true }
    return (lhs.name as String?) == (rhs.name as String?)
  }

  private static func finalize(
    _ image: CGImage,
    request: ImageDecodeRequest,
    limits: DecodeLimits,
    sourceProfile: SourceColorProfile
  ) throws -> DecodedImage {
    try validate(image, limits: limits)
    switch request.contentMode {
    case .fit:
      guard image.width <= request.target.width,
        image.height <= request.target.height
      else { throw ImageCraftError.decodeFailed }
      return DecodedImage(cgImage: image, sourceColorProfile: sourceProfile)
    case .fill:
      let width = min(request.target.width, image.width)
      let height = min(request.target.height, image.height)
      let rect = CGRect(
        x: (image.width - width) / 2,
        y: (image.height - height) / 2,
        width: width,
        height: height
      )
      guard let cropped = image.cropping(to: rect) else {
        throw ImageCraftError.decodeFailed
      }
      try validate(cropped, limits: limits)
      return DecodedImage(cgImage: cropped, sourceColorProfile: sourceProfile)
    }
  }

  private static func validate(_ image: CGImage, limits: DecodeLimits) throws {
    guard image.width > 0, image.height > 0 else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    guard image.width <= limits.maximumDimension,
      image.height <= limits.maximumDimension
    else { throw ImageCraftError.dimensionLimitExceeded }
    let pixels = image.width.multipliedReportingOverflow(by: image.height)
    guard !pixels.overflow, pixels.partialValue <= limits.maximumPixelCount else {
      throw ImageCraftError.pixelLimitExceeded
    }
  }
}
