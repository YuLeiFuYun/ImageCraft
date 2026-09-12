import Foundation
import ImageCraftCore

/// Stable public failures specific to the opt-in bounded 16-bit PNG producer.
public enum BoundedPNG16DecodeError: Error, Equatable, Sendable {
  /// The requested target geometry, color policy or dynamic range is outside the public slice.
  case unsupportedRequest
  /// The PNG uses source semantics outside the deliberately narrow public 16-bit sRGB slice.
  case unsupportedSourceSemantics
  /// The codec-owned operation would exceed the hard budget supplied at initialization.
  case operationBudgetExceeded
}

/// Opt-in high-depth PNG decoder exposing a narrow public straight RGBA16LE value surface.
///
/// Publicly admitted inputs are static grayscale16, grayscale+alpha16, RGB16 or RGBA16 PNG in
/// non-interlaced or Adam7 scan order with explicit sRGB authority. Grayscale/RGB `tRNS` is allowed.
/// The public slice rejects sBIT, ICC, cICP, HDR metadata, EXIF, animation, gamma/chromaticity-only
/// authority, color conversion, resizing and `.high` requests. Package-only qualification remains
/// broader; this wrapper intentionally does not promote those semantics.
public struct BoundedPNG16Decoder: ImagePackedRGBA16Decoding, Sendable {
  private let implementation: PNGIndependentRGBA16Decoder

  public init(maximumOperationByteCharge: Int) throws {
    guard maximumOperationByteCharge > 0 else {
      throw ImageCodecContractError.invalidResourceEstimate
    }
    implementation = PNGIndependentRGBA16Decoder(
      maximumOperationByteCharge: maximumOperationByteCharge
    )
  }

  public func probe(data: Data, limits: DecodeLimits) throws -> ImageProbe {
    try translated {
      let facts = try publicSliceFacts(data: data, limits: limits)
      let request = ImageDecodeRequest(
        target: try TargetPixels(width: facts.width, height: facts.height),
        colorPolicy: .preserveSource
      )
      _ = try implementation.resourceLedger(data: data, request: request, limits: limits)
      return try ImageProbe(
        pixelWidth: facts.width,
        pixelHeight: facts.height,
        frameCount: 1,
        orientation: 1,
        format: .png,
        metadataByteCount: facts.metadataByteCount,
        auxiliaryAttachmentCount: 0,
        sourceColorProfile: .standardSRGB,
        sourceBitsPerComponent: 16
      )
    }
  }

  public func packedRGBA16ResourceLedger(
    data: Data,
    request: ImageDecodeRequest,
    limits: DecodeLimits
  ) throws -> ImageDecodeResourceLedgerSnapshot {
    try translated {
      let facts = try publicSliceFacts(data: data, limits: limits)
      try validateRequest(request, width: facts.width, height: facts.height)
      return try implementation.resourceLedger(data: data, request: request, limits: limits)
    }
  }

  public func decodePackedRGBA16(
    data: Data,
    request: ImageDecodeRequest,
    limits: DecodeLimits
  ) throws -> ImagePackedRGBA16Straight {
    try translated {
      let facts = try publicSliceFacts(data: data, limits: limits)
      try validateRequest(request, width: facts.width, height: facts.height)
      let value = try implementation.decode(data: data, request: request, limits: limits)
      guard value.colorEncoding == .sRGB,
        value.sourceColorProfile == .standardSRGB,
        value.sourceSignificantBits == nil,
        value.hdrStaticMetadata == nil
      else { throw BoundedPNG16DecodeError.unsupportedSourceSemantics }
      return value
    }
  }

  private func validateRequest(
    _ request: ImageDecodeRequest,
    width: Int,
    height: Int
  ) throws {
    guard request.target.width == width,
      request.target.height == height,
      request.colorPolicy == .preserveSource,
      request.dynamicRange == .standard
    else { throw BoundedPNG16DecodeError.unsupportedRequest }
  }

  private func publicSliceFacts(
    data: Data,
    limits: DecodeLimits
  ) throws -> (width: Int, height: Int, metadataByteCount: Int) {
    guard data.count <= limits.maximumEncodedBytes else {
      throw ImageCraftError.encodedBytesExceeded
    }
    guard limits.allowedFormats.contains(.png) else { throw ImageCraftError.unsupportedFormat }
    let security = try EncodedImageSecurityInspector.inspect(
      data,
      maximumMetadataBytes: limits.maximumMetadataBytes,
      materializePNGICCProfile: false
    )
    guard security.format == .png,
      security.sourceColorProfile == .standardSRGB,
      security.embeddedICCProfile == nil,
      security.embeddedICCProfileByteCount == nil,
      let container = security.pngContainerFacts,
      let header = container.header,
      header.bitDepth == 16,
      [UInt8(0), 2, 4, 6].contains(header.colorType),
      header.compressionMethod == 0,
      header.filterMethod == 0,
      header.interlaceMethod <= 1,
      !container.hasGamma,
      !container.hasChromaticities,
      !container.hasSignificantBits,
      !container.hasCICP,
      !container.hasHDRMetadata,
      !container.hasEXIF,
      !container.hasAnimationChunks,
      !container.hasPalette,
      !container.hasUnknownCriticalChunk
    else { throw BoundedPNG16DecodeError.unsupportedSourceSemantics }
    guard header.width <= limits.maximumDimension,
      header.height <= limits.maximumDimension
    else { throw ImageCraftError.dimensionLimitExceeded }
    let pixels = header.width.multipliedReportingOverflow(by: header.height)
    guard !pixels.overflow, pixels.partialValue <= limits.maximumPixelCount else {
      throw ImageCraftError.pixelLimitExceeded
    }
    return (header.width, header.height, security.metadataByteCount)
  }

  private func translated<T>(_ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch let error as BoundedPNG16DecodeError {
      throw error
    } catch let error as PNGIndependentRGBA16Error {
      switch error {
      case .unsupportedRequest:
        throw BoundedPNG16DecodeError.unsupportedRequest
      case .unsupportedSourceSemantics, .targetColorGamutExceeded:
        throw BoundedPNG16DecodeError.unsupportedSourceSemantics
      case .operationBudgetExceeded:
        throw BoundedPNG16DecodeError.operationBudgetExceeded
      }
    } catch is ImagePackedPixelContractError {
      throw ImageCraftError.decodeFailed
    }
  }
}
