import CoreGraphics
import Foundation
import ImageCraftCore
import ImageCraftImageIO
import XCTest

final class ImageEncoderTests: XCTestCase {
  func testDescriptorAdvertisesOnlyImplementedEncodingSemantics() {
    let descriptor = ImageIOImageEncoder().encoderDescriptor
    XCTAssertEqual(descriptor.identifier.rawValue, "dev.imagecraft.imageio.encoder")
    XCTAssertEqual(descriptor.implementationVersion, 2)
    XCTAssertEqual(descriptor.capabilities.formats, [.png, .jpeg])
    XCTAssertEqual(descriptor.capabilities.losslessFormats, [.png])
    XCTAssertEqual(descriptor.capabilities.lossyFormats, [.jpeg])
    XCTAssertEqual(descriptor.capabilities.alphaPreservingFormats, [.png])
    XCTAssertEqual(descriptor.capabilities.alphaFlatteningFormats, [.png, .jpeg])
  }

  func testPNGRoundTripPreservesDimensionsAndAlpha() throws {
    let source = try makeEncoderImage(
      width: 12,
      height: 7,
      colorSpace: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
      rgba: (32, 16, 8, 64)
    )
    let encoded = try ImageIOImageEncoder().encode(
      image: source,
      request: ImageEncodeRequest.png(),
      limits: .coreV1
    )
    let decoded = try ImageIOImageDecoder().decode(
      data: encoded.data,
      target: TargetPixels(width: 12, height: 7)
    )

    XCTAssertEqual(encoded.format, .png)
    XCTAssertEqual(decoded.pixelWidth, 12)
    XCTAssertEqual(decoded.pixelHeight, 7)
    XCTAssertNotEqual(decoded.alphaMode, .none)
    XCTAssertEqual(try centerRGBA(of: decoded.cgImage).3, 64, accuracy: 2)
  }

  func testJPEGNeverSilentlyDropsAlpha() throws {
    let source = try makeEncoderImage(
      width: 8,
      height: 8,
      colorSpace: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
      rgba: (0, 0, 0, 0)
    )
    let encoder = ImageIOImageEncoder()

    XCTAssertThrowsError(
      try encoder.encode(
        image: source,
        request: ImageEncodeRequest.jpeg(alphaPolicy: .preserve),
        limits: .coreV1
      )
    ) {
      XCTAssertEqual(
        $0 as? ImageEncodingError,
        .unsupportedCapability(.alphaPreservation(format: .jpeg))
      )
    }
    XCTAssertThrowsError(
      try encoder.encode(
        image: source,
        request: ImageEncodeRequest.jpeg(alphaPolicy: .reject),
        limits: .coreV1
      )
    ) {
      XCTAssertEqual($0 as? ImageEncodingError, .alphaRejected)
    }
  }

  func testJPEGExplicitFlattenProducesOpaqueBackground() throws {
    let source = try makeEncoderImage(
      width: 8,
      height: 8,
      colorSpace: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
      rgba: (0, 0, 0, 0)
    )
    let encoded = try ImageIOImageEncoder().encode(
      image: source,
      request: ImageEncodeRequest.jpeg(
        quality: ImageEncodeQuality(rawValue: 0.95),
        alphaPolicy: .flatten(background: .white)
      ),
      limits: .coreV1
    )
    let decoded = try ImageIOImageDecoder().decode(
      data: encoded.data,
      target: TargetPixels(width: 8, height: 8)
    )
    let pixel = try centerRGBA(of: decoded.cgImage)

    XCTAssertEqual(encoded.format, .jpeg)
    XCTAssertEqual(decoded.alphaMode, .none)
    XCTAssertGreaterThanOrEqual(pixel.0, 245)
    XCTAssertGreaterThanOrEqual(pixel.1, 245)
    XCTAssertGreaterThanOrEqual(pixel.2, 245)
  }

  func testOrientationRoundTripIsExplicitAndVerified() throws {
    let source = try makeEncoderImage(
      width: 32,
      height: 16,
      colorSpace: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
      rgba: (120, 80, 40, 255)
    )
    let orientation = try ImageEncodeOrientation(rawValue: 6)
    let encoded = try ImageIOImageEncoder().encode(
      image: source,
      request: ImageEncodeRequest.jpeg(
        metadataPolicy: .preserveRecognized,
        orientation: orientation,
        alphaPolicy: .reject
      ),
      limits: .coreV1
    )
    let probe = try ImageIOImageDecoder().probe(data: encoded.data, limits: .coreV1)

    XCTAssertEqual(probe.orientation, 6)
    XCTAssertEqual(probe.pixelWidth, 16)
    XCTAssertEqual(probe.pixelHeight, 32)
  }

  func testPreserveSourceEmbedsDisplayP3Semantics() throws {
    let displayP3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
    let source = try makeEncoderImage(
      width: 16,
      height: 8,
      colorSpace: displayP3,
      rgba: (180, 90, 40, 255)
    )
    let encoded = try ImageIOImageEncoder().encode(
      image: source,
      request: ImageEncodeRequest.png(colorPolicy: .preserveSource),
      limits: .coreV1
    )
    let decoder = ImageIOImageDecoder()
    let probe = try decoder.probe(data: encoded.data, limits: .coreV1)
    let decoded = try decoder.decode(
      data: encoded.data,
      probe: probe,
      request: ImageDecodeRequest(
        target: TargetPixels(width: 16, height: 8),
        colorPolicy: .preserveSource
      ),
      limits: .coreV1
    )

    // Current ImageIO PNG output carries cICP in addition to lower-priority ICC metadata.
    // SourceColorProfile cannot represent cICP yet, so the probe must not mispublish iCCP as the
    // effective authority. Preserve-source decode must still preserve the framework-resolved P3 value.
    XCTAssertEqual(probe.sourceColorProfile, .unknown)
    XCTAssertEqual(decoded.colorDescription.sourceProfile, .unknown)
    XCTAssertEqual(
      decoded.colorDescription.outputColorSpaceName,
      CGColorSpace.displayP3 as String
    )
  }

  func testConvertToSRGBChangesOutputColorContract() throws {
    let source = try makeEncoderImage(
      width: 16,
      height: 8,
      colorSpace: try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3)),
      rgba: (180, 90, 40, 255)
    )
    let encoded = try ImageIOImageEncoder().encode(
      image: source,
      request: ImageEncodeRequest.png(colorPolicy: .convertToSRGB),
      limits: .coreV1
    )
    let decoded = try ImageIOImageDecoder().decode(
      data: encoded.data,
      request: ImageDecodeRequest(
        target: TargetPixels(width: 16, height: 8),
        colorPolicy: .preserveSource
      )
    )

    XCTAssertEqual(
      decoded.colorDescription.outputColorSpaceName,
      CGColorSpace.sRGB as String
    )
  }

  func testCompressionMismatchAndGIFFailClosed() throws {
    let source = try makeEncoderImage(
      width: 4,
      height: 4,
      colorSpace: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
      rgba: (1, 2, 3, 255)
    )
    let encoder = ImageIOImageEncoder()
    let lossyPNG = try ImageEncodeRequest(
      format: .png,
      compression: .lossy(ImageEncodeQuality(rawValue: 0.5)),
      alphaPolicy: .reject
    )
    XCTAssertThrowsError(try encoder.encode(image: source, request: lossyPNG)) {
      XCTAssertEqual(
        $0 as? ImageEncodingError,
        .unsupportedCapability(
          .compression(format: .png, compression: lossyPNG.compression)
        )
      )
    }

    let gif = try ImageEncodeRequest(
      format: .gif,
      compression: .lossless,
      alphaPolicy: .reject
    )
    XCTAssertThrowsError(try encoder.encode(image: source, request: gif)) {
      XCTAssertEqual(
        $0 as? ImageEncodingError,
        .unsupportedCapability(.format(.gif))
      )
    }
  }

  func testCapabilityFailurePrecedesSourceAndResourceFailures() throws {
    let source = try makeEncoderImage(
      width: 8,
      height: 8,
      colorSpace: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
      rgba: (10, 20, 30, 64)
    )
    let request = try ImageEncodeRequest(
      format: .png,
      compression: .lossy(ImageEncodeQuality(rawValue: 0.5)),
      alphaPolicy: .reject
    )

    XCTAssertThrowsError(
      try ImageIOImageEncoder().encode(
        image: source,
        request: request,
        limits: EncodeLimits(maximumDimension: 1)
      )
    ) {
      XCTAssertEqual(
        $0 as? ImageEncodingError,
        .unsupportedCapability(
          .compression(format: .png, compression: request.compression)
        )
      )
    }
  }

  func testHostFormatPolicyIsDistinctFromBackendCapability() throws {
    let source = try makeEncoderImage(
      width: 4,
      height: 4,
      colorSpace: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
      rgba: (10, 20, 30, 255)
    )
    let request = try ImageEncodeRequest.png(alphaPolicy: .reject)

    XCTAssertThrowsError(
      try ImageIOImageEncoder().encode(
        image: source,
        request: request,
        limits: EncodeLimits(allowedFormats: [.jpeg])
      )
    ) {
      XCTAssertEqual($0 as? ImageEncodingError, .formatNotAllowed(.png))
    }
  }

  func testUnlabeledSourceFallsBackToStableSRGB() throws {
    let source = try makeUnlabeledMaskImage(width: 4, height: 4)
    let encoded = try ImageIOImageEncoder().encode(
      image: source,
      request: ImageEncodeRequest.png(
        colorPolicy: .preserveSource,
        alphaPolicy: .preserve
      )
    )
    let decoded = try ImageIOImageDecoder().decode(
      data: encoded.data,
      target: TargetPixels(width: 4, height: 4)
    )

    XCTAssertEqual(
      decoded.colorDescription.outputColorSpaceName,
      CGColorSpace.sRGB as String
    )
  }

  func testBoundedConsumerRejectsWholeWriteWithoutExceedingBudget() throws {
    let consumer = try BoundedDataConsumer(maximumBytes: 4)

    XCTAssertEqual(consumer.consumeForTesting(Data([1, 2])), 2)
    XCTAssertEqual(consumer.consumeForTesting(Data([3, 4, 5])), 0)
    XCTAssertEqual(consumer.consumeForTesting(Data([6])), 0)

    let snapshot = consumer.snapshot
    XCTAssertEqual(snapshot.data, Data([1, 2]))
    XCTAssertEqual(snapshot.maximumBytes, 4)
    XCTAssertEqual(snapshot.maximumObservedByteCount, 2)
    XCTAssertTrue(snapshot.didRejectWrite)
    XCTAssertLessThanOrEqual(snapshot.data.count, snapshot.maximumBytes)
  }

  func testEncodedByteLimitIsAnExactWriteTimeBoundary() throws {
    let source = try makeEncoderImage(
      width: 16,
      height: 16,
      colorSpace: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
      rgba: (17, 43, 89, 255)
    )
    let request = try ImageEncodeRequest.png(alphaPolicy: .reject)
    let encoder = ImageIOImageEncoder()
    let baseline = try encoder.encode(image: source, request: request, limits: .coreV1)

    let exact = try encoder.encode(
      image: source,
      request: request,
      limits: EncodeLimits(maximumEncodedBytes: baseline.byteCount)
    )
    XCTAssertEqual(exact.data, baseline.data)

    XCTAssertThrowsError(
      try encoder.encode(
        image: source,
        request: request,
        limits: EncodeLimits(maximumEncodedBytes: baseline.byteCount - 1)
      )
    ) {
      XCTAssertEqual($0 as? ImageEncodingError, .encodedBytesExceeded)
    }
  }

  func testDimensionPixelAndEncodedByteLimitsFailClosed() throws {
    let source = try makeEncoderImage(
      width: 8,
      height: 8,
      colorSpace: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
      rgba: (20, 40, 60, 255)
    )
    let encoder = ImageIOImageEncoder()
    let request = try ImageEncodeRequest.png(alphaPolicy: .reject)

    XCTAssertThrowsError(
      try encoder.encode(
        image: source,
        request: request,
        limits: EncodeLimits(maximumDimension: 4)
      )
    ) {
      XCTAssertEqual($0 as? ImageEncodingError, .dimensionLimitExceeded)
    }
    XCTAssertThrowsError(
      try encoder.encode(
        image: source,
        request: request,
        limits: EncodeLimits(maximumPixelCount: 32)
      )
    ) {
      XCTAssertEqual($0 as? ImageEncodingError, .pixelLimitExceeded)
    }
    XCTAssertThrowsError(
      try encoder.encode(
        image: source,
        request: request,
        limits: EncodeLimits(maximumEncodedBytes: 1)
      )
    ) {
      XCTAssertEqual($0 as? ImageEncodingError, .encodedBytesExceeded)
    }
  }
}

private func makeEncoderImage(
  width: Int,
  height: Int,
  colorSpace: CGColorSpace,
  rgba: (UInt8, UInt8, UInt8, UInt8)
) throws -> CGImage {
  let bytesPerRow = width * 4
  let hasAlpha = rgba.3 < 255
  var bytes = Data(capacity: bytesPerRow * height)
  for _ in 0..<(width * height) {
    if hasAlpha {
      let alpha = UInt16(rgba.3)
      bytes.append(UInt8((UInt16(rgba.0) * alpha + 127) / 255))
      bytes.append(UInt8((UInt16(rgba.1) * alpha + 127) / 255))
      bytes.append(UInt8((UInt16(rgba.2) * alpha + 127) / 255))
      bytes.append(rgba.3)
    } else {
      bytes.append(rgba.0)
      bytes.append(rgba.1)
      bytes.append(rgba.2)
      bytes.append(255)
    }
  }
  let alphaInfo: CGImageAlphaInfo = hasAlpha ? .premultipliedLast : .noneSkipLast
  guard let provider = CGDataProvider(data: bytes as CFData),
    let image = CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: bytesPerRow,
      space: colorSpace,
      bitmapInfo: CGBitmapInfo(rawValue: alphaInfo.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  else {
    throw ImageCraftFixtureError.creationFailed
  }
  return image
}

private func makeUnlabeledMaskImage(width: Int, height: Int) throws -> CGImage {
  let bytes = Data(repeating: 255, count: width * height)
  guard let provider = CGDataProvider(data: bytes as CFData),
    let image = CGImage(
      maskWidth: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 8,
      bytesPerRow: width,
      provider: provider,
      decode: nil,
      shouldInterpolate: false
    )
  else {
    throw ImageCraftFixtureError.creationFailed
  }
  return image
}

private func centerRGBA(of image: CGImage) throws -> (Double, Double, Double, Double) {
  var pixel = [UInt8](repeating: 0, count: 4)
  guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
    let context = CGContext(
      data: &pixel,
      width: 1,
      height: 1,
      bitsPerComponent: 8,
      bytesPerRow: 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
  else {
    throw ImageCraftFixtureError.creationFailed
  }
  context.setBlendMode(.copy)
  context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
  return (Double(pixel[0]), Double(pixel[1]), Double(pixel[2]), Double(pixel[3]))
}
