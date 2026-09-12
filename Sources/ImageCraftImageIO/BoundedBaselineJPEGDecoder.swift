import Foundation
import ImageCraftCore

/// Stable public failures for the opt-in bounded baseline JFIF JPEG producer.
public enum BoundedBaselineJPEGDecodeError: Error, Equatable, Sendable {
  /// The requested geometry, content mode, color policy or dynamic range is outside the slice.
  case unsupportedRequest
  /// The JPEG uses source/container/sampling semantics outside the qualified baseline domain.
  case unsupportedSourceSemantics
  /// The codec-owned peak exceeds the hard budget supplied at initialization.
  case operationBudgetExceeded(requiredBytes: Int, maximumBytes: Int)
}

/// Opt-in complete-input baseline JFIF JPEG decoder with exact codec-owned resource authority.
///
/// The public slice is the finite union of one 8-bit SOF0 JFIF grayscale mode and three already-
/// qualified YCbCr sampling modes: 4:4:4 (`1x1/1x1/1x1`), 4:2:2 (`2x1/1x1/1x1`) and 4:2:0
/// (`2x2/1x1/1x1`). Every source requires exact first JFIF APP0 authority. Color sources require
/// component IDs 1/2/3, one interleaved sequential Huffman scan and may carry one agreeing Adobe
/// transform=1 authority; grayscale uses one 1x1 component. All modes require 8-bit DQT and allow
/// optional DRI/RST plus opaque COM metadata.
/// Full-resolution `.fit + .convertToSRGB + .standard` is the only request slice. ICC, Exif,
/// auxiliary/unknown APP semantics, non-JFIF grayscale, progressive/arithmetic coding, DNL, resizing and HDR
/// fail closed. The default ImageIO backend is unchanged.
///
/// Encoded bytes remain caller-owned. Resource preflight validates the complete source semantics
/// before publishing a ledger, then reports tight RGB8 transfer plus the exact owned kernel state:
/// 704 bytes for 4:4:4, geometry-derived 8-row strip state for 4:2:2, or geometry-derived 16-row
/// H2V2 strip/context state for 4:2:0. No frame-sized coefficient surface is retained.
public struct BoundedBaselineJPEGDecoder: ImagePackedRGB8Decoding, Sendable {
  private enum Sampling: Sendable {
    case grayscale
    case ycbcr444
    case ycbcr422
    case ycbcr420
  }

  private struct Facts: Sendable {
    let width: Int
    let height: Int
    let metadataByteCount: Int
    let stateByteCount: Int
    let sampling: Sampling
  }

  private let maximumOperationByteCharge: Int

  public init(maximumOperationByteCharge: Int) throws {
    guard maximumOperationByteCharge > 0 else {
      throw ImageCodecContractError.invalidResourceEstimate
    }
    self.maximumOperationByteCharge = maximumOperationByteCharge
  }

  public func probe(data: Data, limits: DecodeLimits) throws -> ImageProbe {
    try translated {
      let facts = try publicSliceFacts(data: data, limits: limits)
      return try ImageProbe(
        pixelWidth: facts.width,
        pixelHeight: facts.height,
        frameCount: 1,
        orientation: 1,
        format: .jpeg,
        metadataByteCount: facts.metadataByteCount,
        auxiliaryAttachmentCount: 0,
        sourceColorProfile: .absent,
        sourceBitsPerComponent: 8
      )
    }
  }

  public func packedRGB8ResourceLedger(
    data: Data,
    request: ImageDecodeRequest,
    limits: DecodeLimits
  ) throws -> ImageDecodeResourceLedgerSnapshot {
    try translated {
      let facts = try publicSliceFacts(data: data, limits: limits)
      try validateRequest(request, width: facts.width, height: facts.height)
      let outputByteCount = try outputByteCount(width: facts.width, height: facts.height)
      let operationByteCharge = try operationByteCharge(
        facts: facts,
        outputByteCount: outputByteCount
      )
      guard operationByteCharge <= maximumOperationByteCharge else {
        throw BoundedBaselineJPEGDecodeError.operationBudgetExceeded(
          requiredBytes: operationByteCharge,
          maximumBytes: maximumOperationByteCharge
        )
      }
      guard let ledger = ImageDecodeResourceLedgerSnapshot(
        retainedKnownBytes: 0,
        retainedBetweenCalls: .bounded(0),
        operationPeak: .bounded(operationByteCharge),
        transferredOutput: .bounded(outputByteCount),
        outputLayoutAuthority: .codecOwnedRGB8
      ) else { throw ImagePackedPixelContractError.invalidBuffer }
      return ledger
    }
  }

  public func decodePackedRGB8(
    data: Data,
    request: ImageDecodeRequest,
    limits: DecodeLimits
  ) throws -> ImagePackedRGB8 {
    try translated {
      let facts = try publicSliceFacts(data: data, limits: limits)
      try validateRequest(request, width: facts.width, height: facts.height)
      let outputByteCount = try outputByteCount(width: facts.width, height: facts.height)
      let required = try operationByteCharge(facts: facts, outputByteCount: outputByteCount)
      guard required <= maximumOperationByteCharge else {
        throw BoundedBaselineJPEGDecodeError.operationBudgetExceeded(
          requiredBytes: required,
          maximumBytes: maximumOperationByteCharge
        )
      }

      let rgb: Data
      let decodedWidth: Int
      let decodedHeight: Int
      let decodedOperationByteCharge: Int
      switch facts.sampling {
      case .grayscale:
        let decoded = try JPEGIndependentBaselineGrayscaleDecoder(
          maximumOperationByteCharge: maximumOperationByteCharge,
          maximumMetadataBytes: limits.maximumMetadataBytes
        ).decode(data)
        decodedWidth = decoded.width
        decodedHeight = decoded.height
        decodedOperationByteCharge = decoded.operationByteCharge
        let pixelCount = decoded.pixels.count
        guard pixelCount == decodedWidth * decodedHeight,
          outputByteCount == pixelCount * 3
        else { throw ImagePackedPixelContractError.invalidBuffer }
        var expanded = Data(count: outputByteCount)
        try decoded.pixels.withUnsafeBytes { rawGray in
          let gray = rawGray.bindMemory(to: UInt8.self)
          try expanded.withUnsafeMutableBytes { rawRGB in
            let destination = rawRGB.bindMemory(to: UInt8.self)
            guard gray.count == pixelCount, destination.count == outputByteCount else {
              throw ImagePackedPixelContractError.invalidBuffer
            }
            for index in 0..<pixelCount {
              let value = gray[index]
              let output = index * 3
              destination[output] = value
              destination[output + 1] = value
              destination[output + 2] = value
            }
          }
        }
        rgb = expanded
      case .ycbcr420:
        let decoded = try JPEGIndependentBaseline420Decoder(
          maximumOperationByteCharge: maximumOperationByteCharge,
          maximumMetadataBytes: limits.maximumMetadataBytes
        ).decode(data)
        rgb = decoded.rgb
        decodedWidth = decoded.width
        decodedHeight = decoded.height
        decodedOperationByteCharge = decoded.operationByteCharge
        guard decoded.statePlan.totalStateBytes == facts.stateByteCount else {
          throw ImagePackedPixelContractError.invalidBuffer
        }
      case .ycbcr422:
        let decoded = try JPEGIndependentBaseline422Decoder(
          maximumOperationByteCharge: maximumOperationByteCharge,
          maximumMetadataBytes: limits.maximumMetadataBytes
        ).decode(data)
        rgb = decoded.rgb
        decodedWidth = decoded.width
        decodedHeight = decoded.height
        decodedOperationByteCharge = decoded.operationByteCharge
        guard decoded.statePlan.totalStateBytes == facts.stateByteCount else {
          throw ImagePackedPixelContractError.invalidBuffer
        }
      case .ycbcr444:
        let decoded = try JPEGIndependentBaseline444Decoder(
          maximumOperationByteCharge: maximumOperationByteCharge,
          maximumMetadataBytes: limits.maximumMetadataBytes
        ).decode(data)
        rgb = decoded.rgb
        decodedWidth = decoded.width
        decodedHeight = decoded.height
        decodedOperationByteCharge = decoded.operationByteCharge
        guard decoded.fixedScratchByteCount == facts.stateByteCount else {
          throw ImagePackedPixelContractError.invalidBuffer
        }
      }

      let expectedKernelOperation: Int
      switch facts.sampling {
      case .grayscale:
        let pixels = facts.width.multipliedReportingOverflow(by: facts.height)
        guard !pixels.overflow else { throw ImageCraftError.unsupportedOrCorruptImage }
        expectedKernelOperation = ImageDecodeResourceLedgerSnapshot.saturatedAdding(
          pixels.partialValue,
          JPEGIndependentBaselineGrayscaleDecoder.fixedScratchByteCount
        )
      case .ycbcr444, .ycbcr422, .ycbcr420:
        expectedKernelOperation = required
      }
      guard decodedWidth == facts.width,
        decodedHeight == facts.height,
        decodedOperationByteCharge == expectedKernelOperation,
        let packed = ImagePackedRGB8(
          data: rgb,
          pixelWidth: decodedWidth,
          pixelHeight: decodedHeight,
          colorEncoding: .sRGB,
          sourceColorProfile: .absent
        )
      else { throw ImagePackedPixelContractError.invalidBuffer }
      return packed
    }
  }

  private func validateRequest(
    _ request: ImageDecodeRequest,
    width: Int,
    height: Int
  ) throws {
    guard request.target.width == width,
      request.target.height == height,
      request.contentMode == .fit,
      request.colorPolicy == .convertToSRGB,
      request.dynamicRange == .standard
    else { throw BoundedBaselineJPEGDecodeError.unsupportedRequest }
  }

  private func publicSliceFacts(data: Data, limits: DecodeLimits) throws -> Facts {
    guard data.count <= limits.maximumEncodedBytes else {
      throw ImageCraftError.encodedBytesExceeded
    }
    guard limits.allowedFormats.contains(.jpeg) else { throw ImageCraftError.unsupportedFormat }
    let security = try EncodedImageSecurityInspector.inspect(
      data,
      maximumMetadataBytes: limits.maximumMetadataBytes,
      materializePNGICCProfile: false,
      materializeJPEGICCProfile: false
    )
    guard security.format == .jpeg,
      security.sourceColorProfile == .absent,
      security.embeddedICCProfile == nil
    else { throw BoundedBaselineJPEGDecodeError.unsupportedSourceSemantics }

    let geometry = try JPEGFrameSamplingGeometry.inspect(data)
    guard geometry.codingMode == .baselineDCT,
      geometry.precision == 8
    else { throw BoundedBaselineJPEGDecodeError.unsupportedSourceSemantics }

    let facts: Facts
    switch geometry.samplingMode {
    case .threeComponent420:
      let statePlan = try JPEGIndependentBaseline420StatePlan.inspect(data)
      let decodePlan = try JPEGIndependentBaseline420Decoder.DecodePlan.inspect(
        data,
        sampling: .h2v2
      )
      guard statePlan.width == decodePlan.width, statePlan.height == decodePlan.height else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      facts = Facts(
        width: statePlan.width,
        height: statePlan.height,
        metadataByteCount: security.metadataByteCount,
        stateByteCount: statePlan.totalStateBytes,
        sampling: .ycbcr420
      )
    case .threeComponent422:
      let statePlan = try JPEGIndependentBaseline422StatePlan.inspect(data)
      let decodePlan = try JPEGIndependentBaseline420Decoder.DecodePlan.inspect(
        data,
        sampling: .h2v1
      )
      guard statePlan.width == decodePlan.width, statePlan.height == decodePlan.height else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      facts = Facts(
        width: statePlan.width,
        height: statePlan.height,
        metadataByteCount: security.metadataByteCount,
        stateByteCount: statePlan.totalStateBytes,
        sampling: .ycbcr422
      )
    case .threeComponent444:
      let dimensions = try JPEGIndependentBaseline444Decoder.qualifiedDimensions(data)
      facts = Facts(
        width: dimensions.width,
        height: dimensions.height,
        metadataByteCount: security.metadataByteCount,
        stateByteCount: JPEGIndependentBaseline444Decoder.fixedScratchByteCount,
        sampling: .ycbcr444
      )
    case .singleComponent:
      let dimensions = try JPEGIndependentBaselineGrayscaleDecoder.qualifiedJFIFDimensions(data)
      guard dimensions.width == geometry.width, dimensions.height == geometry.height else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      facts = Facts(
        width: dimensions.width,
        height: dimensions.height,
        metadataByteCount: security.metadataByteCount,
        stateByteCount: JPEGIndependentBaselineGrayscaleDecoder.fixedScratchByteCount,
        sampling: .grayscale
      )
    case .threeComponent440:
      throw BoundedBaselineJPEGDecodeError.unsupportedSourceSemantics
    }

    guard facts.width <= limits.maximumDimension,
      facts.height <= limits.maximumDimension
    else { throw ImageCraftError.dimensionLimitExceeded }
    let pixels = facts.width.multipliedReportingOverflow(by: facts.height)
    guard !pixels.overflow, pixels.partialValue <= limits.maximumPixelCount else {
      throw ImageCraftError.pixelLimitExceeded
    }
    return facts
  }

  private func outputByteCount(width: Int, height: Int) throws -> Int {
    let pixels = width.multipliedReportingOverflow(by: height)
    guard !pixels.overflow else { throw ImageCraftError.unsupportedOrCorruptImage }
    let bytes = pixels.partialValue.multipliedReportingOverflow(by: 3)
    guard !bytes.overflow else { throw ImageCraftError.unsupportedOrCorruptImage }
    return bytes.partialValue
  }

  private func operationByteCharge(facts: Facts, outputByteCount: Int) throws -> Int {
    switch facts.sampling {
    case .grayscale:
      let pixels = facts.width.multipliedReportingOverflow(by: facts.height)
      guard !pixels.overflow else { throw ImageCraftError.unsupportedOrCorruptImage }
      let kernelPeak = ImageDecodeResourceLedgerSnapshot.saturatedAdding(
        pixels.partialValue,
        facts.stateByteCount
      )
      let expansionPeak = ImageDecodeResourceLedgerSnapshot.saturatedAdding(
        pixels.partialValue,
        outputByteCount
      )
      return max(kernelPeak, expansionPeak)
    case .ycbcr444, .ycbcr422, .ycbcr420:
      return ImageDecodeResourceLedgerSnapshot.saturatedAdding(
        facts.stateByteCount,
        outputByteCount
      )
    }
  }

  private func translated<T>(_ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch let error as BoundedBaselineJPEGDecodeError {
      throw error
    } catch let error as JPEGIndependentBaseline420Error {
      switch error {
      case .unsupportedSourceSemantics:
        throw BoundedBaselineJPEGDecodeError.unsupportedSourceSemantics
      case .invalidOperationBudget:
        throw ImageCodecContractError.invalidResourceEstimate
      case .operationBudgetExceeded(let requiredBytes, let maximumBytes):
        throw BoundedBaselineJPEGDecodeError.operationBudgetExceeded(
          requiredBytes: requiredBytes,
          maximumBytes: maximumBytes
        )
      case .stateAllocationFailed:
        throw ImageCraftError.decodeFailed
      }
    } catch let error as JPEGIndependentBaseline422Error {
      switch error {
      case .unsupportedSourceSemantics:
        throw BoundedBaselineJPEGDecodeError.unsupportedSourceSemantics
      case .invalidOperationBudget:
        throw ImageCodecContractError.invalidResourceEstimate
      case .operationBudgetExceeded(let requiredBytes, let maximumBytes):
        throw BoundedBaselineJPEGDecodeError.operationBudgetExceeded(
          requiredBytes: requiredBytes,
          maximumBytes: maximumBytes
        )
      case .stateAllocationFailed:
        throw ImageCraftError.decodeFailed
      }
    } catch let error as JPEGIndependentBaseline444Error {
      switch error {
      case .unsupportedSourceSemantics:
        throw BoundedBaselineJPEGDecodeError.unsupportedSourceSemantics
      case .invalidOperationBudget:
        throw ImageCodecContractError.invalidResourceEstimate
      case .operationBudgetExceeded(let requiredBytes, let maximumBytes):
        throw BoundedBaselineJPEGDecodeError.operationBudgetExceeded(
          requiredBytes: requiredBytes,
          maximumBytes: maximumBytes
        )
      case .scratchAllocationFailed:
        throw ImageCraftError.decodeFailed
      }
    } catch let error as JPEGIndependentBaselineGrayscaleError {
      switch error {
      case .unsupportedSourceSemantics:
        throw BoundedBaselineJPEGDecodeError.unsupportedSourceSemantics
      case .invalidOperationBudget:
        throw ImageCodecContractError.invalidResourceEstimate
      case .operationBudgetExceeded(let requiredBytes, let maximumBytes):
        throw BoundedBaselineJPEGDecodeError.operationBudgetExceeded(
          requiredBytes: requiredBytes,
          maximumBytes: maximumBytes
        )
      case .scratchAllocationFailed:
        throw ImageCraftError.decodeFailed
      }
    } catch is ImagePackedPixelContractError {
      throw ImageCraftError.decodeFailed
    }
  }
}
