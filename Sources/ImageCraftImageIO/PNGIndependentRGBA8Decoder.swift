import Foundation
import ImageCraftCore

package enum PNGIndependentRGBA8Error: Error, Equatable, Sendable {
  case unsupportedRequest
  case unsupportedSourceSemantics
  case operationBudgetExceeded
}

/// Package-only second implementation for the narrow static-PNG domain needed to pressure-test the
/// packed-pixel contract without Apple ImageIO rasterization.
///
/// Supported source domain:
/// - validated static PNG structure with one IHDR, contiguous IDAT run and terminal IEND;
/// - non-interlaced grayscale 1/2/4/8-bit, grayscale+alpha8, RGB8, RGBA8 and indexed 1/2/4/8-bit rows;
/// - Adam7-interlaced RGBA8 under explicit sRGB authority as a separately qualified first slice;
/// - indexed PLTE/tRNS, grayscale/RGB tRNS and truecolor suggested PLTE where structurally valid;
/// - full-resolution output only;
/// - explicit sRGB for either color policy; non-interlaced untagged input only when the caller
///   explicitly requests the stable convert-to-sRGB fallback; or a structurally valid RGB ICC value
///   for preserve-source on RGB/RGBA input.
///
/// Unqualified cICP/HDR, gAMA/cHRM, animation, Adam7 source types outside the explicit RGBA8 slice,
/// 16-bit samples and other unimplemented semantics fail closed rather than silently approximating
/// ImageIO behavior.
package struct PNGIndependentRGBA8Decoder: Sendable {
  private static let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])
  private let maximumOperationByteCharge: Int

  /// Qualification descriptor for the narrow bounded producer. The implementation remains
  /// package-only; the descriptor exists so host-selection experiments can use the same capability
  /// vocabulary as public codecs without mislabeling interleaved RGBA as planar pixels.
  package static let codecDescriptor = ImageCodecDescriptor(
    identifier: ImageCodecIdentifier(rawValue: "dev.fovea.independent-png-rgba8"),
    implementationVersion: 1,
    capabilities: ImageCodecCapabilities(
      formats: [.png],
      deliveryModes: [.completeFrame],
      progressiveFormats: [],
      trackModes: [.primaryFrame],
      metadata: [.sourceColorProfile],
      dynamicRanges: [.standard],
      outputRepresentations: [.packedRGBA8],
      cancellationMode: .operationBoundary
    )
  )

  /// The caller owns operation-budget authority. There is intentionally no implicit default: every
  /// independent-backend qualification site must state the maximum payload coexistence it admits.
  package init(maximumOperationByteCharge: Int) {
    self.maximumOperationByteCharge = max(1, maximumOperationByteCharge)
  }

  package func probe(
    data: Data,
    limits: DecodeLimits = .coreV1
  ) throws -> ImageProbe {
    guard data.count <= limits.maximumEncodedBytes else {
      throw ImageCraftError.encodedBytesExceeded
    }
    guard limits.allowedFormats.contains(.png) else { throw ImageCraftError.unsupportedFormat }
    _ = try preflightHeader(data, limits: limits)
    let securityPlan = try EncodedImageSecurityInspector.inspect(
      data,
      maximumMetadataBytes: limits.maximumMetadataBytes,
      materializePNGICCProfile: false
    )
    guard securityPlan.format == .png else { throw ImageCraftError.formatMismatch }
    let parsed = try qualifiedStaticFacts(security: securityPlan, limits: limits)
    // Probe validates exactly the same color authority as the packed producer. Embedded ICC
    // validation can inflate up to the metadata ceiling, so it must pass the decoder's hard
    // operation-budget admission before profile materialization rather than creating an uncharged
    // probe-only allocation path.
    let probePolicy: ImageColorPolicy = securityPlan.sourceColorProfile == .absent
      ? .convertToSRGB
      : .preserveSource
    try admitQualifiedOperation(
      security: securityPlan,
      policy: probePolicy,
      width: parsed.width,
      height: parsed.height,
      sourceBitsPerPixel: parsed.sourceBitsPerPixel,
      limits: limits
    )
    let security = try materializeQualifiedColorProfileIfNeeded(
      securityPlan,
      data: data,
      limits: limits
    )
    _ = try colorEncoding(security: security, policy: probePolicy)
    return try ImageProbe(
      pixelWidth: parsed.width,
      pixelHeight: parsed.height,
      frameCount: 1,
      orientation: 1,
      format: .png,
      metadataByteCount: security.metadataByteCount,
      auxiliaryAttachmentCount: 0,
      sourceColorProfile: security.sourceColorProfile
    )
  }

  /// Resource classification for the same narrow domain accepted by `decode`.
  ///
  /// The output payload and optional ICC bytes are codec-owned values with exact charges, and this
  /// one-shot backend retains no state between calls. Explicit-sRGB inputs now stream ImageCraft's
  /// pure RFC1950/DEFLATE output directly into row unfiltering, so the payload-level operation charge
  /// is final packed RGBA + two source rows at their exact packed byte width + the fixed 36 KiB
  /// unified DEFLATE history/pending-output window + bounded Huffman workspace. IDAT bytes are
  /// consumed directly from the caller-owned encoded PNG
  /// through a scalar chunk cursor, so neither a concatenated compressed copy nor the complete
  /// inflated scanline stream is retained. Embedded-ICC inputs are also bounded: the shared PNG
  /// security inspector uses the same pure bounded inflater, and its maximum-output iCCP phase is
  /// charged separately from the later pixel phase before taking the conservative maximum.
  package func resourceLedger(
    data: Data,
    request: ImageDecodeRequest,
    limits: DecodeLimits = .coreV1
  ) throws -> ImageDecodeResourceLedgerSnapshot {
    guard data.count <= limits.maximumEncodedBytes else {
      throw ImageCraftError.encodedBytesExceeded
    }
    guard limits.allowedFormats.contains(.png) else { throw ImageCraftError.unsupportedFormat }
    let dimensions = try preflightHeader(data, limits: limits)
    guard request.target.width == dimensions.width,
      request.target.height == dimensions.height
    else { throw PNGIndependentRGBA8Error.unsupportedRequest }
    try admitBaselineOperationPreflight(
      width: dimensions.width,
      height: dimensions.height,
      sourceBitsPerPixel: dimensions.sourceBitsPerPixelHint ?? 32
    )
    let securityPlan = try EncodedImageSecurityInspector.inspect(
      data,
      maximumMetadataBytes: limits.maximumMetadataBytes,
      materializePNGICCProfile: false
    )
    guard securityPlan.format == .png else { throw ImageCraftError.formatMismatch }
    let parsed = try qualifiedStaticFacts(security: securityPlan, limits: limits)
    try admitQualifiedOperation(
      security: securityPlan,
      policy: request.colorPolicy,
      width: dimensions.width,
      height: dimensions.height,
      sourceBitsPerPixel: parsed.sourceBitsPerPixel,
      limits: limits
    )
    let security = try materializeQualifiedColorProfileIfNeeded(
      securityPlan,
      data: data,
      limits: limits
    )
    let colorEncoding = try colorEncoding(security: security, policy: request.colorPolicy)
    let counts = try PNGScanlineRGBA8Decoder.expectedByteCounts(
      width: dimensions.width,
      height: dimensions.height,
      sourceBitsPerPixel: parsed.sourceBitsPerPixel
    )
    let rowBytes = try PNGScanlineRGBA8Decoder.sourceRowByteCount(
      width: dimensions.width,
      sourceBitsPerPixel: parsed.sourceBitsPerPixel
    )
    let transfer = ImageDecodeResourceLedgerSnapshot.saturatedAdding(
      counts.raw,
      colorEncoding.retainedByteCharge
    )
    var pixelPhaseCharge = counts.raw
    pixelPhaseCharge = ImageDecodeResourceLedgerSnapshot.saturatedAdding(
      pixelPhaseCharge,
      rowBytes
    )
    pixelPhaseCharge = ImageDecodeResourceLedgerSnapshot.saturatedAdding(
      pixelPhaseCharge,
      rowBytes
    )
    pixelPhaseCharge = ImageDecodeResourceLedgerSnapshot.saturatedAdding(
      pixelPhaseCharge,
      colorEncoding.retainedByteCharge
    )
    pixelPhaseCharge = ImageDecodeResourceLedgerSnapshot.saturatedAdding(
      pixelPhaseCharge,
      RFC1950BoundedInflate.algorithmicWorkspaceByteChargeUpperBound
    )
    pixelPhaseCharge = ImageDecodeResourceLedgerSnapshot.saturatedAdding(
      pixelPhaseCharge,
      RFC1950BoundedInflate.streamingOutputWorkspaceByteChargeUpperBound
    )

    let operationCharge: Int
    switch security.sourceColorProfile {
    case .standardSRGB:
      operationCharge = pixelPhaseCharge
    case .embeddedICC:
      let securityInflateCharge = RFC1950BoundedInflate.maximumModeByteChargeUpperBound(
        maximumOutputByteCount: limits.maximumMetadataBytes
      )
      operationCharge = max(pixelPhaseCharge, securityInflateCharge)
    case .absent:
      // `colorEncoding` already proves that only the explicit convert-to-sRGB fallback reaches
      // this phase; source provenance remains `.absent` and requires no retained color payload.
      operationCharge = pixelPhaseCharge
    case .unknown:
      guard qualifiedCICPEncoding(security: security) != nil else {
        throw ImagePackedPixelContractError.unclassifiedColorState
      }
      operationCharge = pixelPhaseCharge
    }
    guard let ledger = ImageDecodeResourceLedgerSnapshot(
      retainedKnownBytes: 0,
      retainedBetweenCalls: .bounded(0),
      operationPeak: .bounded(operationCharge),
      transferredOutput: .bounded(transfer),
      outputLayoutAuthority: .codecOwnedRGBA8
    ) else { throw ImagePackedPixelContractError.invalidBuffer }
    guard operationCharge <= maximumOperationByteCharge else {
      throw PNGIndependentRGBA8Error.operationBudgetExceeded
    }
    return ledger
  }

  package func decode(
    data: Data,
    request: ImageDecodeRequest,
    limits: DecodeLimits = .coreV1
  ) throws -> ImagePackedRGBA8 {
    guard data.count <= limits.maximumEncodedBytes else {
      throw ImageCraftError.encodedBytesExceeded
    }
    guard limits.allowedFormats.contains(.png) else { throw ImageCraftError.unsupportedFormat }
    let dimensions = try preflightHeader(data, limits: limits)
    guard request.target.width == dimensions.width,
      request.target.height == dimensions.height
    else { throw PNGIndependentRGBA8Error.unsupportedRequest }
    try admitBaselineOperationPreflight(
      width: dimensions.width,
      height: dimensions.height,
      sourceBitsPerPixel: dimensions.sourceBitsPerPixelHint ?? 32
    )

    let securityPlan = try EncodedImageSecurityInspector.inspect(
      data,
      maximumMetadataBytes: limits.maximumMetadataBytes,
      materializePNGICCProfile: false
    )
    guard securityPlan.format == .png else { throw ImageCraftError.formatMismatch }

    let parsed = try qualifiedStaticFacts(security: securityPlan, limits: limits)
    try admitQualifiedOperation(
      security: securityPlan,
      policy: request.colorPolicy,
      width: parsed.width,
      height: parsed.height,
      sourceBitsPerPixel: parsed.sourceBitsPerPixel,
      limits: limits
    )
    let security = try materializeQualifiedColorProfileIfNeeded(
      securityPlan,
      data: data,
      limits: limits
    )

    let colorEncoding = try colorEncoding(
      security: security,
      policy: request.colorPolicy
    )
    let premultiplied: Data
    do {
      premultiplied = try data.withUnsafeBytes { rawSource in
        let source = rawSource.bindMemory(to: UInt8.self)
        guard let base = source.baseAddress else {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
        let cursor = try PNGValidatedIDATByteCursor(
          sourceBase: base,
          sourceByteCount: source.count,
          firstChunkOffset: parsed.firstIDATChunkOffset,
          runEndOffset: parsed.idatRunEndOffset,
          compressedByteCount: parsed.compressedByteCount
        )
        let indexedPalette: PNGScanlineRGBA8Decoder.IndexedPaletteView?
        if let paletteRange = parsed.indexedPaletteRange {
          guard paletteRange.lowerBound >= 0,
            paletteRange.upperBound <= source.count,
            paletteRange.count >= 3,
            paletteRange.count <= 256 * 3,
            paletteRange.count.isMultiple(of: 3)
          else { throw ImageCraftError.unsupportedOrCorruptImage }
          let paletteEntryCount = paletteRange.count / 3
          let alphaBase: UnsafePointer<UInt8>?
          let alphaCount: Int
          if let alphaRange = parsed.indexedAlphaRange {
            guard alphaRange.lowerBound >= 0,
              alphaRange.upperBound <= source.count,
              alphaRange.count <= paletteEntryCount
            else { throw ImageCraftError.unsupportedOrCorruptImage }
            alphaBase = base.advanced(by: alphaRange.lowerBound)
            alphaCount = alphaRange.count
          } else {
            alphaBase = nil
            alphaCount = 0
          }
          indexedPalette = PNGScanlineRGBA8Decoder.IndexedPaletteView(
            rgbBase: base.advanced(by: paletteRange.lowerBound),
            entryCount: paletteEntryCount,
            alphaBase: alphaBase,
            alphaCount: alphaCount
          )
        } else {
          indexedPalette = nil
        }
        if parsed.interlaceMethod == 1 {
          return try PNGScanlineRGBA8Decoder.inflateAndDecodePremultipliedRGBA8Adam7(
            cursor: cursor,
            width: parsed.width,
            height: parsed.height
          )
        }
        if let indexedBitDepth = parsed.indexedBitDepth,
          let indexedPalette
        {
          return try PNGScanlineRGBA8Decoder.inflateAndDecodePremultipliedIndexedRowwise(
            cursor: cursor,
            width: parsed.width,
            height: parsed.height,
            bitDepth: indexedBitDepth,
            indexedPalette: indexedPalette
          )
        }
        if let grayscaleBitDepth = parsed.grayscaleBitDepth {
          return try PNGScanlineRGBA8Decoder.inflateAndDecodePremultipliedGrayscaleRowwise(
            cursor: cursor,
            width: parsed.width,
            height: parsed.height,
            bitDepth: grayscaleBitDepth,
            transparentSample: parsed.transparentGraySample
          )
        }
        return try PNGScanlineRGBA8Decoder.inflateAndDecodePremultipliedRowwise(
          cursor: cursor,
          width: parsed.width,
          height: parsed.height,
          sourceBytesPerPixel: try PNGScanlineRGBA8Decoder.filterBytesPerPixel(
            sourceBitsPerPixel: parsed.sourceBitsPerPixel
          ),
          transparentRGB8: parsed.transparentRGB8,
          transparentGray8: parsed.transparentGray8,
          indexedPalette: nil
        )
      }
    } catch {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    guard let result = ImagePackedRGBA8(
      data: premultiplied,
      pixelWidth: parsed.width,
      pixelHeight: parsed.height,
      colorEncoding: colorEncoding,
      sourceColorProfile: security.sourceColorProfile
    ) else { throw ImagePackedPixelContractError.invalidBuffer }
    return result
  }

  /// Runs after bounded IHDR parsing but before full CRC/security inspection. This first gate admits
  /// only the minimum codec-owned pixel path that every supported color authority requires; it does
  /// not reserve a hypothetical ICC ceiling for explicit-sRGB inputs. A second gate runs after the one
  /// CRC/bounds container scan reveals the actual color authority, but before any iCCP inflate.
  private func admitBaselineOperationPreflight(
    width: Int,
    height: Int,
    sourceBitsPerPixel: Int
  ) throws {
    let counts = try PNGScanlineRGBA8Decoder.expectedByteCounts(
      width: width,
      height: height,
      sourceBitsPerPixel: sourceBitsPerPixel
    )
    let rowBytes = try PNGScanlineRGBA8Decoder.sourceRowByteCount(
      width: width,
      sourceBitsPerPixel: sourceBitsPerPixel
    )

    var pixelWorstCase = counts.raw
    pixelWorstCase = ImageDecodeResourceLedgerSnapshot.saturatedAdding(
      pixelWorstCase,
      rowBytes
    )
    pixelWorstCase = ImageDecodeResourceLedgerSnapshot.saturatedAdding(
      pixelWorstCase,
      rowBytes
    )
    pixelWorstCase = ImageDecodeResourceLedgerSnapshot.saturatedAdding(
      pixelWorstCase,
      RFC1950BoundedInflate.algorithmicWorkspaceByteChargeUpperBound
    )
    pixelWorstCase = ImageDecodeResourceLedgerSnapshot.saturatedAdding(
      pixelWorstCase,
      RFC1950BoundedInflate.streamingOutputWorkspaceByteChargeUpperBound
    )
    guard pixelWorstCase <= maximumOperationByteCharge else {
      throw PNGIndependentRGBA8Error.operationBudgetExceeded
    }
  }

  /// Uses validated container facts to refine admission before any embedded ICC decompression. The
  /// source compressed range remains caller-owned; only decoded ICC value bytes and inflater
  /// workspace/ceiling enter the codec-owned coexistence model.
  private func admitQualifiedOperation(
    security: EncodedImageSecurityInspection,
    policy: ImageColorPolicy,
    width: Int,
    height: Int,
    sourceBitsPerPixel: Int,
    limits: DecodeLimits
  ) throws {
    let counts = try PNGScanlineRGBA8Decoder.expectedByteCounts(
      width: width,
      height: height,
      sourceBitsPerPixel: sourceBitsPerPixel
    )
    let rowBytes = try PNGScanlineRGBA8Decoder.sourceRowByteCount(
      width: width,
      sourceBitsPerPixel: sourceBitsPerPixel
    )
    var pixelWorstCase = counts.raw
    pixelWorstCase = ImageDecodeResourceLedgerSnapshot.saturatedAdding(pixelWorstCase, rowBytes)
    pixelWorstCase = ImageDecodeResourceLedgerSnapshot.saturatedAdding(pixelWorstCase, rowBytes)
    pixelWorstCase = ImageDecodeResourceLedgerSnapshot.saturatedAdding(
      pixelWorstCase,
      RFC1950BoundedInflate.algorithmicWorkspaceByteChargeUpperBound
    )
    pixelWorstCase = ImageDecodeResourceLedgerSnapshot.saturatedAdding(
      pixelWorstCase,
      RFC1950BoundedInflate.streamingOutputWorkspaceByteChargeUpperBound
    )

    let operationWorstCase: Int
    switch security.sourceColorProfile {
    case .standardSRGB:
      operationWorstCase = pixelWorstCase
    case .embeddedICC:
      guard policy == .preserveSource else {
        throw PNGIndependentRGBA8Error.unsupportedSourceSemantics
      }
      pixelWorstCase = ImageDecodeResourceLedgerSnapshot.saturatedAdding(
        pixelWorstCase,
        limits.maximumMetadataBytes
      )
      operationWorstCase = max(
        pixelWorstCase,
        RFC1950BoundedInflate.maximumModeByteChargeUpperBound(
          maximumOutputByteCount: limits.maximumMetadataBytes
        )
      )
    case .absent:
      guard policy == .convertToSRGB else {
        throw PNGIndependentRGBA8Error.unsupportedSourceSemantics
      }
      operationWorstCase = pixelWorstCase
    case .unknown:
      guard policy == .preserveSource,
        qualifiedCICPEncoding(security: security) != nil
      else { throw PNGIndependentRGBA8Error.unsupportedSourceSemantics }
      operationWorstCase = pixelWorstCase
    }
    guard operationWorstCase <= maximumOperationByteCharge else {
      throw PNGIndependentRGBA8Error.operationBudgetExceeded
    }
  }

  private func colorEncoding(
    security: EncodedImageSecurityInspection,
    policy: ImageColorPolicy
  ) throws -> ImagePackedPixelColorEncoding {
    switch policy {
    case .preserveSource:
      switch security.sourceColorProfile {
      case .standardSRGB:
        return .sRGB
      case .embeddedICC:
        guard let profile = security.embeddedICCProfile else {
          throw ImagePackedPixelContractError.invalidColorEncoding
        }
        guard isRGBICCProfile(profile) else {
          throw PNGIndependentRGBA8Error.unsupportedSourceSemantics
        }
        return .embeddedICC(profile)
      case .unknown:
        guard let cicp = qualifiedCICPEncoding(security: security) else {
          throw PNGIndependentRGBA8Error.unsupportedSourceSemantics
        }
        return .cicp(cicp)
      case .absent:
        throw PNGIndependentRGBA8Error.unsupportedSourceSemantics
      }
    case .convertToSRGB:
      switch security.sourceColorProfile {
      case .standardSRGB:
        return .sRGB
      case .absent:
        // Caller explicitly requested the stable untagged-PNG fallback. Source provenance remains
        // `.absent`; only the transferred pixel encoding is classified as sRGB.
        return .sRGB
      case .embeddedICC, .unknown:
        // Embedded ICC and cICP conversion require a separately qualified independent CMS before
        // this backend may advertise an sRGB conversion.
        throw PNGIndependentRGBA8Error.unsupportedSourceSemantics
      }
    }
  }

  private func isRGBICCProfile(_ profile: Data) -> Bool {
    PNGICCProfileSemantics.isRGB(profile)
  }

  private func materializeQualifiedColorProfileIfNeeded(
    _ security: EncodedImageSecurityInspection,
    data: Data,
    limits: DecodeLimits
  ) throws -> EncodedImageSecurityInspection {
    guard security.sourceColorProfile == .embeddedICC else { return security }
    return try EncodedImageSecurityInspector.materializingPNGICCProfile(
      security,
      in: data,
      maximumMetadataBytes: limits.maximumMetadataBytes
    )
  }

  /// Narrow cICP slice for the public RGBA8 value contract. Only full-range Display-P3 SDR is
  /// represented here; source precision, HDR static metadata, and lower-priority iCCP payloads
  /// remain fail-closed so the packed value/resource ledger never drops source semantics or
  /// materializes an overridden profile.
  private func qualifiedCICPEncoding(
    security: EncodedImageSecurityInspection
  ) -> ImagePackedCICPColorEncoding? {
    guard let facts = security.pngContainerFacts,
      let header = facts.header,
      header.bitDepth == 8,
      header.colorType == 2 || header.colorType == 6,
      !facts.hasSignificantBits,
      !facts.hasHDRMetadata,
      let cicp = facts.cicp,
      cicp.colorPrimaries == 12,
      cicp.transferFunction == 13,
      cicp.matrixCoefficients == 0,
      cicp.videoFullRangeFlag == 1
    else { return nil }
    return ImagePackedCICPColorEncoding(
      colorPrimaries: cicp.colorPrimaries,
      transferFunction: cicp.transferFunction,
      matrixCoefficients: cicp.matrixCoefficients,
      videoFullRangeFlag: cicp.videoFullRangeFlag
    )
  }

  private func qualifiedStaticFacts(
    security: EncodedImageSecurityInspection,
    limits: DecodeLimits
  ) throws -> (
    width: Int,
    height: Int,
    firstIDATChunkOffset: Int,
    idatRunEndOffset: Int,
    compressedByteCount: Int,
    sourceBitsPerPixel: Int,
    interlaceMethod: UInt8,
    indexedBitDepth: Int?,
    grayscaleBitDepth: Int?,
    transparentGraySample: UInt16?,
    transparentRGB8: PNGScanlineRGBA8Decoder.TransparentRGB8?,
    transparentGray8: UInt8?,
    indexedPaletteRange: Range<Int>?,
    indexedAlphaRange: Range<Int>?
  ) {
    guard let facts = security.pngContainerFacts,
      facts.allChunkTypeBytesAreLetters,
      facts.allChunkReservedBitsAreZero,
      facts.prePaletteAndIDATChunksAreOrdered,
      facts.knownPreIDATChunksAreOrdered,
      facts.ihdrCount == 1,
      facts.ihdrWasFirst,
      let header = facts.header,
      header.width > 0,
      header.height > 0,
      header.compressionMethod == 0,
      header.filterMethod == 0,
      facts.iendPayloadLength == 0,
      facts.idatRunIsContiguous,
      let firstIDATChunkOffset = facts.firstIDATChunkOffset,
      let idatRunEndOffset = facts.idatRunEndOffset,
      facts.compressedIDATByteCount >= 6
    else { throw ImageCraftError.unsupportedOrCorruptImage }

    guard header.interlaceMethod == 0 || header.interlaceMethod == 1 else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    let sourceBitsPerPixel: Int
    let indexedBitDepth: Int?
    let grayscaleBitDepth: Int?
    let transparentGraySample: UInt16?
    let transparentRGB8: PNGScanlineRGBA8Decoder.TransparentRGB8?
    let transparentGray8: UInt8?
    let indexedPaletteRange: Range<Int>?
    let indexedAlphaRange: Range<Int>?
    switch header.colorType {
    case 0:
      let bitDepth = Int(header.bitDepth)
      guard [1, 2, 4, 8].contains(bitDepth) else {
        throw PNGIndependentRGBA8Error.unsupportedSourceSemantics
      }
      sourceBitsPerPixel = bitDepth
      indexedBitDepth = nil
      if bitDepth < 8 {
        grayscaleBitDepth = bitDepth
        transparentGraySample = facts.grayscaleTransparency
        transparentGray8 = nil
      } else {
        grayscaleBitDepth = nil
        transparentGraySample = nil
        transparentGray8 = facts.grayscaleTransparency.map(UInt8.init(truncatingIfNeeded:))
      }
      transparentRGB8 = nil
      indexedPaletteRange = nil
      indexedAlphaRange = nil
    case 2:
      guard header.bitDepth == 8 else {
        throw PNGIndependentRGBA8Error.unsupportedSourceSemantics
      }
      sourceBitsPerPixel = 24
      indexedBitDepth = nil
      grayscaleBitDepth = nil
      transparentGraySample = nil
      transparentGray8 = nil
      indexedPaletteRange = nil
      indexedAlphaRange = nil
      if let transparency = facts.truecolorTransparency {
        transparentRGB8 = PNGScanlineRGBA8Decoder.TransparentRGB8(
          red: UInt8(truncatingIfNeeded: transparency.red),
          green: UInt8(truncatingIfNeeded: transparency.green),
          blue: UInt8(truncatingIfNeeded: transparency.blue)
        )
      } else {
        transparentRGB8 = nil
      }
    case 3:
      let bitDepth = Int(header.bitDepth)
      guard [1, 2, 4, 8].contains(bitDepth),
        let paletteRange = facts.palettePayloadRange,
        paletteRange.count >= 3,
        paletteRange.count <= (1 << bitDepth) * 3,
        paletteRange.count.isMultiple(of: 3)
      else {
        throw PNGIndependentRGBA8Error.unsupportedSourceSemantics
      }
      sourceBitsPerPixel = bitDepth
      indexedBitDepth = bitDepth
      grayscaleBitDepth = nil
      transparentGraySample = nil
      transparentRGB8 = nil
      transparentGray8 = nil
      indexedPaletteRange = paletteRange
      indexedAlphaRange = facts.indexedTransparencyPayloadRange
    case 4:
      guard header.bitDepth == 8 else {
        throw PNGIndependentRGBA8Error.unsupportedSourceSemantics
      }
      sourceBitsPerPixel = 16
      indexedBitDepth = nil
      grayscaleBitDepth = nil
      transparentGraySample = nil
      transparentRGB8 = nil
      transparentGray8 = nil
      indexedPaletteRange = nil
      indexedAlphaRange = nil
    case 6:
      guard header.bitDepth == 8 else {
        throw PNGIndependentRGBA8Error.unsupportedSourceSemantics
      }
      sourceBitsPerPixel = 32
      indexedBitDepth = nil
      grayscaleBitDepth = nil
      transparentGraySample = nil
      transparentRGB8 = nil
      transparentGray8 = nil
      indexedPaletteRange = nil
      indexedAlphaRange = nil
    default:
      throw PNGIndependentRGBA8Error.unsupportedSourceSemantics
    }
    if header.interlaceMethod == 1 {
      guard header.colorType == 6,
        header.bitDepth == 8,
        security.sourceColorProfile == .standardSRGB
      else { throw PNGIndependentRGBA8Error.unsupportedSourceSemantics }
    }
    try validateDimensions(width: header.width, height: header.height, limits: limits)
    switch security.sourceColorProfile {
    case .standardSRGB:
      break
    case .embeddedICC:
      // Grayscale and indexed ICC authority are intentionally separate qualification slices; this
      // backend's current embedded-ICC value contract is direct RGB/RGBA samples only.
      guard header.colorType == 2 || header.colorType == 6 else {
        throw PNGIndependentRGBA8Error.unsupportedSourceSemantics
      }
    case .unknown:
      guard qualifiedCICPEncoding(security: security) != nil else {
        throw PNGIndependentRGBA8Error.unsupportedSourceSemantics
      }
    case .absent:
      // Absence is a valid source fact. `preserveSource` still fails later because there is no
      // calibrated encoding to preserve; `.convertToSRGB` may deliberately choose ImageCraft's
      // stable untagged-PNG sRGB fallback while retaining `.absent` source provenance.
      break
    }

    guard !facts.hasUnknownCriticalChunk else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    // For truecolor source types 2/6, PLTE is only a suggested display palette and does not alter
    // source samples. Generic PNG security has already validated its structure and placement.
    if facts.hasTransparency,
      !(
        (header.colorType == 0 && (transparentGray8 != nil || transparentGraySample != nil))
          || (header.colorType == 2 && transparentRGB8 != nil)
          || (header.colorType == 3 && indexedAlphaRange != nil)
      )
    {
      throw PNGIndependentRGBA8Error.unsupportedSourceSemantics
    }
    guard !facts.hasAnimationChunks,
      !facts.hasEXIF,
      !facts.hasHDRMetadata,
      !facts.hasSignificantBits,
      !facts.hasGamma,
      !facts.hasChromaticities
    else { throw PNGIndependentRGBA8Error.unsupportedSourceSemantics }

    return (
      header.width,
      header.height,
      firstIDATChunkOffset,
      idatRunEndOffset,
      facts.compressedIDATByteCount,
      sourceBitsPerPixel,
      header.interlaceMethod,
      indexedBitDepth,
      grayscaleBitDepth,
      transparentGraySample,
      transparentRGB8,
      transparentGray8,
      indexedPaletteRange,
      indexedAlphaRange
    )
  }

  private func preflightHeader(
    _ data: Data,
    limits: DecodeLimits
  ) throws -> (width: Int, height: Int, sourceBitsPerPixelHint: Int?) {
    guard data.count >= 8 + 12 + 13,
      data.prefix(8) == Self.signature,
      readUInt32BE(data, at: 8) == 13,
      data[12] == 0x49,
      data[13] == 0x48,
      data[14] == 0x44,
      data[15] == 0x52,
      let rawWidth = readUInt32BE(data, at: 16),
      let rawHeight = readUInt32BE(data, at: 20),
      rawWidth > 0, rawHeight > 0,
      let width = Int(exactly: rawWidth),
      let height = Int(exactly: rawHeight)
    else { throw ImageCraftError.unsupportedOrCorruptImage }
    try validateDimensions(width: width, height: height, limits: limits)

    // These two bytes are only an admission hint before CRC/security validation. Unsupported or
    // corrupt sources still go through the full inspector, so reading the hint does not promote
    // source semantics or change the request-before-capability error precedence.
    let sourceBitsPerPixelHint: Int?
    let bitDepth = Int(data[24])
    let colorType = data[25]
    if [1, 2, 4, 8].contains(bitDepth), colorType == 0 {
      sourceBitsPerPixelHint = bitDepth
    } else if bitDepth == 8, colorType == 2 {
      sourceBitsPerPixelHint = 24
    } else if [1, 2, 4, 8].contains(bitDepth), colorType == 3 {
      sourceBitsPerPixelHint = bitDepth
    } else if bitDepth == 8, colorType == 4 {
      sourceBitsPerPixelHint = 16
    } else if bitDepth == 8, colorType == 6 {
      sourceBitsPerPixelHint = 32
    } else {
      sourceBitsPerPixelHint = nil
    }
    return (width, height, sourceBitsPerPixelHint)
  }

  private func validateDimensions(width: Int, height: Int, limits: DecodeLimits) throws {
    guard width <= limits.maximumDimension, height <= limits.maximumDimension else {
      throw ImageCraftError.dimensionLimitExceeded
    }
    let pixels = width.multipliedReportingOverflow(by: height)
    guard !pixels.overflow, pixels.partialValue <= limits.maximumPixelCount else {
      throw ImageCraftError.pixelLimitExceeded
    }
  }

  private func readUInt32BE(_ data: Data, at offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= data.count else { return nil }
    return UInt32(data[offset]) << 24
      | UInt32(data[offset + 1]) << 16
      | UInt32(data[offset + 2]) << 8
      | UInt32(data[offset + 3])
  }
}
