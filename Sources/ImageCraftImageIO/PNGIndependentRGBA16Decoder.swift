import Foundation
import ImageCraftCore

package enum PNGIndependentRGBA16Error: Error, Equatable, Sendable {
  case unsupportedRequest
  case unsupportedSourceSemantics
  case targetColorGamutExceeded
  case operationBudgetExceeded
}

/// Package-only exact high-depth PNG backend for the first source-faithful representation slice.
///
/// Qualified domain:
/// - static non-interlaced or Adam7 grayscale16, grayscale+alpha16, RGB16 and RGBA16 PNG;
/// - optional exact 16-bit tRNS on grayscale16/RGB16 in either scan order;
/// - explicit sRGB for every qualified source model, preserve-source RGB ICC for RGB16/RGBA16, narrow in-gamut monitor/input RGB/XYZ matrix/TRC ICC -> sRGB conversion with shared or per-channel independently-qualified parametric type-0...type-4 / curveType identity-single-gamma-normalized-sampled curves, and full-range P3/PQ/HLG cICP raw signaling for RGB16/RGBA16;
/// - full-resolution output only;
/// - straight RGBA16 samples in canonical little-endian packed storage;
/// - optional validated sBIT metadata preserving the actual source channel model without rewriting pixels.
///
/// Gray/RGB transparency is tested against complete stored UInt16 samples before alpha is injected.
/// GA/RGBA stored alpha remains straight. sBIT describes source significant depth only; stored samples
/// remain byte-exact. The backend intentionally does not materialize a CGImage and does not premultiply
/// alpha. Adam7 uses pass-local filter history and direct scatter/expansion into the final straight
/// value without pass surfaces; exact source rows remain 2/4/6/8 Bpp for gray/GA/RGB/RGBA. A synthesized
/// opaque or tRNS-derived output alpha never acquires source alpha significance. Preserve-source RGB ICC
/// bytes are retained as value authority without transforming pixels. A separate conversion slice parses
/// qualified monitor/input RGB/XYZ matrix/TRC profile tags. Monitor profiles retain the D50/reconstructed-white gate; input profiles keep a plausible captured-medium `wtpt` without requiring device code white to equal D50. Shared R/G/B TRCs may use the
/// full normalized parametric type-0...type-4 or curveType identity/gamma/sampled domain; profiles with
/// distinct channel curves qualify when every channel independently passes the same curve-specific validation,
/// and per-channel curves may mix individually-qualified curveType and parametric encodings. Sampled entries
/// are read from the retained profile bytes rather than copied into a second table; retained qualification covers
/// both small and 1025-node sampled tables without a cardinality-dependent decoded-table payload. The
/// backend then converts only in-gamut RGB/RGBA16 to standard sRGB. Profile tags, channel-specific TRC kind,
/// function number, parameters and sampled table—not profile names, a P3 constant, or a shared-curve
/// assumption—drive the transform. Profile bytes remain part of the operation phase but are not transferred with converted
/// output, and no gamut mapping is implied. Full-range Display-P3, BT.2100 PQ and BT.2100 HLG cICP are
/// retained as fixed structured raw-sample authority for RGB/RGBA16; P3 cICP also has its own narrow
/// in-gamut conversion slice. Full-range BT.2100 PQ may additionally retain exact typed mDCV/cLLI integers
/// without changing pixels or resource charge. Grayscale/GA cICP, narrow/unqualified tuples, P3/HLG static
/// HDR metadata, arbitrary/LUT ICC conversion, out-of-gamut P3, PQ/HLG conversion and resizing remain
/// fail-closed.
package struct PNGIndependentRGBA16Decoder: Sendable {
  private static let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])
  private let maximumOperationByteCharge: Int

  package init(maximumOperationByteCharge: Int = 512 * 1024 * 1024) {
    self.maximumOperationByteCharge = max(1, maximumOperationByteCharge)
  }

  package func resourceLedger(
    data: Data,
    request: ImageDecodeRequest,
    limits: DecodeLimits = .coreV1
  ) throws -> ImageDecodeResourceLedgerSnapshot {
    guard data.count <= limits.maximumEncodedBytes else {
      throw ImageCraftError.encodedBytesExceeded
    }
    guard limits.allowedFormats.contains(.png) else { throw ImageCraftError.unsupportedFormat }
    let preflight = try preflightHeader(data, limits: limits)
    guard request.target.width == preflight.width,
      request.target.height == preflight.height
    else { throw PNGIndependentRGBA16Error.unsupportedRequest }
    try admitOperation(
      width: preflight.width,
      height: preflight.height,
      sourceBytesPerPixel: preflight.sourceBytesPerPixel
    )

    var security = try EncodedImageSecurityInspector.inspect(
      data,
      maximumMetadataBytes: limits.maximumMetadataBytes,
      materializePNGICCProfile: false
    )
    guard security.format == .png else { throw ImageCraftError.formatMismatch }
    security = try materializeQualifiedColorProfileIfNeeded(
      security,
      data: data,
      request: request,
      limits: limits,
      preflight: preflight
    )
    let facts = try qualifiedFacts(security: security, request: request, limits: limits)

    let outputBytes = try outputByteCount(width: facts.width, height: facts.height)
    let transferredOutput = try checkedAdd(outputBytes, facts.colorEncoding.retainedByteCharge)
    let operationCharge = try qualifiedOperationByteCharge(
      width: facts.width,
      height: facts.height,
      sourceBytesPerPixel: facts.sourceBytesPerPixel,
      operationRetainedColorByteCount: facts.operationRetainedColorByteCount,
      maximumMetadataBytes: limits.maximumMetadataBytes
    )
    guard operationCharge <= maximumOperationByteCharge else {
      throw PNGIndependentRGBA16Error.operationBudgetExceeded
    }
    guard let ledger = ImageDecodeResourceLedgerSnapshot(
      retainedKnownBytes: 0,
      retainedBetweenCalls: .bounded(0),
      operationPeak: .bounded(operationCharge),
      transferredOutput: .bounded(transferredOutput),
      outputLayoutAuthority: .codecOwnedStraightRGBA16LE
    ) else { throw ImagePackedPixelContractError.invalidBuffer }
    return ledger
  }

  package func decode(
    data: Data,
    request: ImageDecodeRequest,
    limits: DecodeLimits = .coreV1
  ) throws -> ImagePackedRGBA16Straight {
    guard data.count <= limits.maximumEncodedBytes else {
      throw ImageCraftError.encodedBytesExceeded
    }
    guard limits.allowedFormats.contains(.png) else { throw ImageCraftError.unsupportedFormat }
    let preflight = try preflightHeader(data, limits: limits)
    guard request.target.width == preflight.width,
      request.target.height == preflight.height
    else { throw PNGIndependentRGBA16Error.unsupportedRequest }
    try admitOperation(
      width: preflight.width,
      height: preflight.height,
      sourceBytesPerPixel: preflight.sourceBytesPerPixel
    )

    var security = try EncodedImageSecurityInspector.inspect(
      data,
      maximumMetadataBytes: limits.maximumMetadataBytes,
      materializePNGICCProfile: false
    )
    guard security.format == .png else { throw ImageCraftError.formatMismatch }
    security = try materializeQualifiedColorProfileIfNeeded(
      security,
      data: data,
      request: request,
      limits: limits,
      preflight: preflight
    )
    let facts = try qualifiedFacts(security: security, request: request, limits: limits)
    let operationCharge = try qualifiedOperationByteCharge(
      width: facts.width,
      height: facts.height,
      sourceBytesPerPixel: facts.sourceBytesPerPixel,
      operationRetainedColorByteCount: facts.operationRetainedColorByteCount,
      maximumMetadataBytes: limits.maximumMetadataBytes
    )
    guard operationCharge <= maximumOperationByteCharge else {
      throw PNGIndependentRGBA16Error.operationBudgetExceeded
    }

    do {
      let output = try data.withUnsafeBytes { rawSource -> Data in
        let source = rawSource.bindMemory(to: UInt8.self)
        guard let base = source.baseAddress else {
          throw ImageCraftError.unsupportedOrCorruptImage
        }
        let cursor = try PNGValidatedIDATByteCursor(
          sourceBase: base,
          sourceByteCount: source.count,
          firstChunkOffset: facts.firstIDATChunkOffset,
          runEndOffset: facts.idatRunEndOffset,
          compressedByteCount: facts.compressedByteCount
        )
        if facts.interlaceMethod == 1 {
          return try PNGScanlineRGBA16Decoder.inflateAndDecodeStraightRGBA16LittleEndianAdam7(
            cursor: cursor,
            width: facts.width,
            height: facts.height,
            sourceLayout: facts.sourceLayout,
            outputColorTransform: facts.outputColorTransform
          )
        }
        return try PNGScanlineRGBA16Decoder.inflateAndDecodeStraightRGBA16LittleEndian(
          cursor: cursor,
          width: facts.width,
          height: facts.height,
          sourceLayout: facts.sourceLayout,
          outputColorTransform: facts.outputColorTransform
        )
      }
      guard let value = ImagePackedRGBA16Straight(
        data: output,
        pixelWidth: facts.width,
        pixelHeight: facts.height,
        colorEncoding: facts.colorEncoding,
        sourceColorProfile: facts.sourceColorProfile,
        sourceSignificantBits: facts.sourceSignificantBits,
        hdrStaticMetadata: facts.hdrStaticMetadata
      ) else { throw ImagePackedPixelContractError.invalidBuffer }
      return value
    } catch let error as PNGIndependentRGBA16Error {
      throw error
    } catch let error as PNGDisplayP3ToSRGBConversionError {
      switch error {
      case .targetColorGamutExceeded:
        throw PNGIndependentRGBA16Error.targetColorGamutExceeded
      }
    } catch let error as PNGICCMatrixTRCToSRGBConversionError {
      switch error {
      case .targetColorGamutExceeded:
        throw PNGIndependentRGBA16Error.targetColorGamutExceeded
      }
    } catch let error as ImagePackedPixelContractError {
      throw error
    } catch let error as ImageCraftError {
      throw error
    } catch {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
  }

  private func materializeQualifiedColorProfileIfNeeded(
    _ security: EncodedImageSecurityInspection,
    data: Data,
    request: ImageDecodeRequest,
    limits: DecodeLimits,
    preflight: (width: Int, height: Int, sourceBytesPerPixel: Int, bitDepth: UInt8, colorType: UInt8)
  ) throws -> EncodedImageSecurityInspection {
    guard security.sourceColorProfile == .embeddedICC else { return security }
    guard preflight.bitDepth == 16,
      preflight.colorType == 2 || preflight.colorType == 6
    else { throw PNGIndependentRGBA16Error.unsupportedSourceSemantics }

    // Admission precedes ICC inflate. The pixel phase may retain up to the metadata ceiling while
    // decoding, and the security phase independently has the bounded RFC1950 maximum-output charge.
    let basePixelCharge = try operationByteCharge(
      width: preflight.width,
      height: preflight.height,
      sourceBytesPerPixel: preflight.sourceBytesPerPixel
    )
    let worstPixelPhase = try checkedAdd(basePixelCharge, limits.maximumMetadataBytes)
    let securityInflateCharge = RFC1950BoundedInflate.maximumModeByteChargeUpperBound(
      maximumOutputByteCount: limits.maximumMetadataBytes
    )
    guard max(worstPixelPhase, securityInflateCharge) <= maximumOperationByteCharge else {
      throw PNGIndependentRGBA16Error.operationBudgetExceeded
    }
    return try EncodedImageSecurityInspector.materializingPNGICCProfile(
      security,
      in: data,
      maximumMetadataBytes: limits.maximumMetadataBytes
    )
  }

  private func qualifiedOperationByteCharge(
    width: Int,
    height: Int,
    sourceBytesPerPixel: Int,
    operationRetainedColorByteCount: Int,
    maximumMetadataBytes: Int
  ) throws -> Int {
    let basePixelCharge = try operationByteCharge(
      width: width,
      height: height,
      sourceBytesPerPixel: sourceBytesPerPixel
    )
    let pixelPhaseCharge = try checkedAdd(basePixelCharge, operationRetainedColorByteCount)
    guard operationRetainedColorByteCount > 0 else { return pixelPhaseCharge }
    let securityInflateCharge = RFC1950BoundedInflate.maximumModeByteChargeUpperBound(
      maximumOutputByteCount: maximumMetadataBytes
    )
    return max(pixelPhaseCharge, securityInflateCharge)
  }

  private func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
    let result = lhs.addingReportingOverflow(rhs)
    guard !result.overflow else { throw PNGIndependentRGBA16Error.operationBudgetExceeded }
    return result.partialValue
  }

  private func qualifiedFacts(
    security: EncodedImageSecurityInspection,
    request: ImageDecodeRequest,
    limits: DecodeLimits
  ) throws -> (
    width: Int,
    height: Int,
    firstIDATChunkOffset: Int,
    idatRunEndOffset: Int,
    compressedByteCount: Int,
    sourceBytesPerPixel: Int,
    sourceLayout: PNGScanlineRGBA16Decoder.SourceLayout,
    sourceSignificantBits: ImagePackedSourceSignificantBits?,
    interlaceMethod: UInt8,
    colorEncoding: ImagePackedPixelColorEncoding,
    sourceColorProfile: SourceColorProfile,
    operationRetainedColorByteCount: Int,
    hdrStaticMetadata: ImagePackedHDRStaticMetadata?,
    outputColorTransform: PNG16OutputColorTransform
  ) {
    guard security.format == .png,
      let facts = security.pngContainerFacts,
      let header = facts.header,
      facts.ihdrCount == 1,
      facts.ihdrWasFirst,
      facts.allChunkTypeBytesAreLetters,
      facts.allChunkReservedBitsAreZero,
      facts.prePaletteAndIDATChunksAreOrdered,
      facts.knownPreIDATChunksAreOrdered,
      let firstIDATChunkOffset = facts.firstIDATChunkOffset,
      let idatRunEndOffset = facts.idatRunEndOffset,
      facts.compressedIDATByteCount >= 6,
      facts.idatRunIsContiguous,
      facts.iendPayloadLength == 0,
      header.bitDepth == 16,
      [UInt8(0), UInt8(2), UInt8(4), UInt8(6)].contains(header.colorType),
      header.compressionMethod == 0,
      header.filterMethod == 0,
      (header.interlaceMethod == 0 || header.interlaceMethod == 1),
      !facts.hasPalette,
      facts.indexedTransparencyPayloadRange == nil,
      !facts.hasEXIF,
      !facts.hasAnimationChunks,
      !facts.hasUnknownCriticalChunk
    else { throw PNGIndependentRGBA16Error.unsupportedSourceSemantics }

    let sourceBytesPerPixel: Int
    let sourceLayout: PNGScanlineRGBA16Decoder.SourceLayout
    let sourceSignificantBits: ImagePackedSourceSignificantBits?
    switch header.colorType {
    case 0:
      guard facts.hasTransparency == (facts.grayscaleTransparency != nil),
        facts.truecolorTransparency == nil
      else { throw PNGIndependentRGBA16Error.unsupportedSourceSemantics }
      if let significantBits = facts.significantBits {
        guard case .grayscale(let gray) = significantBits,
          let mapped = ImagePackedSourceSignificantBits(
            sampleBitDepth: 16,
            channels: .grayscale(gray: gray)
          )
        else { throw PNGIndependentRGBA16Error.unsupportedSourceSemantics }
        sourceSignificantBits = mapped
      } else {
        sourceSignificantBits = nil
      }
      sourceBytesPerPixel = 2
      sourceLayout = .grayscale(transparent: facts.grayscaleTransparency)
    case 4:
      guard !facts.hasTransparency,
        facts.grayscaleTransparency == nil,
        facts.truecolorTransparency == nil
      else { throw PNGIndependentRGBA16Error.unsupportedSourceSemantics }
      if let significantBits = facts.significantBits {
        guard case .grayscaleAlpha(let gray, let alpha) = significantBits,
          let mapped = ImagePackedSourceSignificantBits(
            sampleBitDepth: 16,
            channels: .grayscaleAlpha(gray: gray, alpha: alpha)
          )
        else { throw PNGIndependentRGBA16Error.unsupportedSourceSemantics }
        sourceSignificantBits = mapped
      } else {
        sourceSignificantBits = nil
      }
      sourceBytesPerPixel = 4
      sourceLayout = .grayscaleAlpha
    case 2:
      guard facts.hasTransparency == (facts.truecolorTransparency != nil) else {
        throw PNGIndependentRGBA16Error.unsupportedSourceSemantics
      }
      let transparent = facts.truecolorTransparency.map {
        PNGScanlineRGBA16Decoder.TransparentRGB16(
          red: $0.red,
          green: $0.green,
          blue: $0.blue
        )
      }
      if let significantBits = facts.significantBits {
        guard case .rgb(let red, let green, let blue) = significantBits,
          let mapped = ImagePackedSourceSignificantBits(
            sampleBitDepth: 16,
            channels: .rgb(red: red, green: green, blue: blue)
          )
        else { throw PNGIndependentRGBA16Error.unsupportedSourceSemantics }
        sourceSignificantBits = mapped
      } else {
        sourceSignificantBits = nil
      }
      sourceBytesPerPixel = 6
      sourceLayout = .rgb(transparent: transparent)
    case 6:
      guard !facts.hasTransparency, facts.truecolorTransparency == nil else {
        throw PNGIndependentRGBA16Error.unsupportedSourceSemantics
      }
      if let significantBits = facts.significantBits {
        guard case .rgba(let red, let green, let blue, let alpha) = significantBits,
          let mapped = ImagePackedSourceSignificantBits(
            sampleBitDepth: 16,
            channels: .rgba(red: red, green: green, blue: blue, alpha: alpha)
          )
        else { throw PNGIndependentRGBA16Error.unsupportedSourceSemantics }
        sourceSignificantBits = mapped
      } else {
        sourceSignificantBits = nil
      }
      sourceBytesPerPixel = 8
      sourceLayout = .rgba
    default:
      throw PNGIndependentRGBA16Error.unsupportedSourceSemantics
    }

    let colorEncoding: ImagePackedPixelColorEncoding
    let sourceColorProfile: SourceColorProfile
    let operationRetainedColorByteCount: Int
    let hdrStaticMetadata: ImagePackedHDRStaticMetadata?
    let outputColorTransform: PNG16OutputColorTransform
    switch security.sourceColorProfile {
    case .standardSRGB:
      guard security.embeddedICCProfile == nil,
        facts.embeddedICCCompressedRange == nil,
        facts.cicp == nil,
        !facts.hasGamma,
        !facts.hasChromaticities,
        !facts.hasHDRMetadata
      else { throw PNGIndependentRGBA16Error.unsupportedSourceSemantics }
      colorEncoding = .sRGB
      sourceColorProfile = .standardSRGB
      operationRetainedColorByteCount = 0
      hdrStaticMetadata = nil
      outputColorTransform = .preserve
    case .embeddedICC:
      guard header.colorType == 2 || header.colorType == 6,
        facts.cicp == nil,
        !facts.hasGamma,
        !facts.hasChromaticities,
        !facts.hasHDRMetadata,
        facts.embeddedICCCompressedRange != nil,
        let profile = security.embeddedICCProfile,
        PNGICCProfileSemantics.isRGB(profile)
      else { throw PNGIndependentRGBA16Error.unsupportedSourceSemantics }
      sourceColorProfile = .embeddedICC
      operationRetainedColorByteCount = profile.count
      hdrStaticMetadata = nil
      switch request.colorPolicy {
      case .preserveSource:
        colorEncoding = .embeddedICC(profile)
        outputColorTransform = .preserve
      case .convertToSRGB:
        guard facts.significantBits == nil,
          let transform = PNGICCProfileSemantics.matrixTRCToSRGBTransform(profile)
        else { throw PNGIndependentRGBA16Error.unsupportedSourceSemantics }
        colorEncoding = .sRGB
        outputColorTransform = .iccMatrixTRCToSRGBInGamut(transform)
      }
    case .unknown:
      guard header.colorType == 2 || header.colorType == 6,
        let cicp = facts.cicp,
        let qualifiedCICP = qualifiedCICPEncoding(cicp)
      else { throw PNGIndependentRGBA16Error.unsupportedSourceSemantics }
      sourceColorProfile = .unknown
      operationRetainedColorByteCount = 0
      switch request.colorPolicy {
      case .preserveSource:
        // cICP is the highest-precedence PNG color authority. Lower-priority iCCP/sRGB/cHRM/gAMA
        // may remain in the validated container, but none is materialized or used by this raw path.
        colorEncoding = .cicp(qualifiedCICP)
        hdrStaticMetadata = try qualifiedHDRStaticMetadata(facts: facts, cicp: cicp)
        outputColorTransform = .preserve
      case .convertToSRGB:
        guard cicp.colorPrimaries == 0x0C,
          cicp.transferFunction == 0x0D,
          cicp.matrixCoefficients == 0,
          cicp.videoFullRangeFlag == 1,
          facts.significantBits == nil,
          !facts.hasHDRMetadata
        else { throw PNGIndependentRGBA16Error.unsupportedSourceSemantics }
        colorEncoding = .sRGB
        hdrStaticMetadata = nil
        outputColorTransform = .displayP3ToSRGBInGamut
      }
    case .absent:
      throw PNGIndependentRGBA16Error.unsupportedSourceSemantics
    }

    try validateDimensions(width: header.width, height: header.height, limits: limits)
    return (
      header.width,
      header.height,
      firstIDATChunkOffset,
      idatRunEndOffset,
      facts.compressedIDATByteCount,
      sourceBytesPerPixel,
      sourceLayout,
      sourceSignificantBits,
      header.interlaceMethod,
      colorEncoding,
      sourceColorProfile,
      operationRetainedColorByteCount,
      hdrStaticMetadata,
      outputColorTransform
    )
  }

  private func qualifiedCICPEncoding(
    _ cicp: PNGValidatedContainerFacts.CICP
  ) -> ImagePackedCICPColorEncoding? {
    guard cicp.videoFullRangeFlag == 1 else { return nil }
    switch (cicp.colorPrimaries, cicp.transferFunction) {
    case (0x0C, 0x0D),  // Display-P3 SDR, full range.
      (0x09, 0x10),    // BT.2100 primaries + PQ, full range.
      (0x09, 0x12):    // BT.2100 primaries + HLG, full range.
      return ImagePackedCICPColorEncoding(
        colorPrimaries: cicp.colorPrimaries,
        transferFunction: cicp.transferFunction,
        matrixCoefficients: cicp.matrixCoefficients,
        videoFullRangeFlag: cicp.videoFullRangeFlag
      )
    default:
      return nil
    }
  }

  private func qualifiedHDRStaticMetadata(
    facts: PNGValidatedContainerFacts,
    cicp: PNGValidatedContainerFacts.CICP
  ) throws -> ImagePackedHDRStaticMetadata? {
    guard facts.hasHDRMetadata else { return nil }
    guard cicp.colorPrimaries == 0x09,
      cicp.transferFunction == 0x10,
      cicp.matrixCoefficients == 0,
      cicp.videoFullRangeFlag == 1
    else { throw PNGIndependentRGBA16Error.unsupportedSourceSemantics }

    let masteringDisplay: ImagePackedMasteringDisplayColorVolume?
    if let source = facts.masteringDisplayColorVolume {
      guard let mapped = ImagePackedMasteringDisplayColorVolume(
        redX: source.redX,
        redY: source.redY,
        greenX: source.greenX,
        greenY: source.greenY,
        blueX: source.blueX,
        blueY: source.blueY,
        whiteX: source.whiteX,
        whiteY: source.whiteY,
        maximumLuminanceScaledBy10000: source.maximumLuminanceScaledBy10000,
        minimumLuminanceScaledBy10000: source.minimumLuminanceScaledBy10000
      ) else { throw ImagePackedPixelContractError.invalidBuffer }
      masteringDisplay = mapped
    } else {
      masteringDisplay = nil
    }

    let contentLight: ImagePackedContentLightLevel?
    if let source = facts.contentLightLevel {
      guard let mapped = ImagePackedContentLightLevel(
        maximumContentLightLevelScaledBy10000: source.maximumContentLightLevelScaledBy10000,
        maximumFrameAverageLightLevelScaledBy10000: source.maximumFrameAverageLightLevelScaledBy10000
      ) else { throw ImagePackedPixelContractError.invalidBuffer }
      contentLight = mapped
    } else {
      contentLight = nil
    }

    guard let metadata = ImagePackedHDRStaticMetadata(
      masteringDisplayColorVolume: masteringDisplay,
      contentLightLevel: contentLight
    ) else { throw ImagePackedPixelContractError.invalidBuffer }
    return metadata
  }

  private func preflightHeader(
    _ data: Data,
    limits: DecodeLimits
  ) throws -> (width: Int, height: Int, sourceBytesPerPixel: Int, bitDepth: UInt8, colorType: UInt8) {
    guard data.count >= 8 + 12 + 13,
      data.prefix(8) == Self.signature,
      readUInt32BE(data, at: 8) == 13,
      data[12] == 0x49,
      data[13] == 0x48,
      data[14] == 0x44,
      data[15] == 0x52,
      let rawWidth = readUInt32BE(data, at: 16),
      let rawHeight = readUInt32BE(data, at: 20),
      rawWidth > 0,
      rawHeight > 0,
      let width = Int(exactly: rawWidth),
      let height = Int(exactly: rawHeight)
    else { throw ImageCraftError.unsupportedOrCorruptImage }
    try validateDimensions(width: width, height: height, limits: limits)
    let sourceBytesPerPixel: Int
    if data[24] == 16 {
      switch data[25] {
      case 0: sourceBytesPerPixel = 2
      case 4: sourceBytesPerPixel = 4
      case 2: sourceBytesPerPixel = 6
      case 6: sourceBytesPerPixel = 8
      default: sourceBytesPerPixel = 8
      }
    } else {
      sourceBytesPerPixel = 8
    }
    return (width, height, sourceBytesPerPixel, data[24], data[25])
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

  private func admitOperation(
    width: Int,
    height: Int,
    sourceBytesPerPixel: Int
  ) throws {
    let charge = try operationByteCharge(
      width: width,
      height: height,
      sourceBytesPerPixel: sourceBytesPerPixel
    )
    guard charge <= maximumOperationByteCharge else {
      throw PNGIndependentRGBA16Error.operationBudgetExceeded
    }
  }

  private func operationByteCharge(
    width: Int,
    height: Int,
    sourceBytesPerPixel: Int
  ) throws -> Int {
    guard [2, 4, 6, 8].contains(sourceBytesPerPixel) else {
      throw PNGIndependentRGBA16Error.operationBudgetExceeded
    }
    let output = try outputByteCount(width: width, height: height)
    let row = width.multipliedReportingOverflow(by: sourceBytesPerPixel)
    guard !row.overflow else { throw PNGIndependentRGBA16Error.operationBudgetExceeded }
    var charge = output
    charge = ImageDecodeResourceLedgerSnapshot.saturatedAdding(charge, row.partialValue)
    charge = ImageDecodeResourceLedgerSnapshot.saturatedAdding(charge, row.partialValue)
    charge = ImageDecodeResourceLedgerSnapshot.saturatedAdding(
      charge,
      RFC1950BoundedInflate.algorithmicWorkspaceByteChargeUpperBound
    )
    charge = ImageDecodeResourceLedgerSnapshot.saturatedAdding(
      charge,
      RFC1950BoundedInflate.streamingOutputWorkspaceByteChargeUpperBound
    )
    return charge
  }

  private func outputByteCount(width: Int, height: Int) throws -> Int {
    let row = width.multipliedReportingOverflow(by: 8)
    guard !row.overflow else { throw PNGIndependentRGBA16Error.operationBudgetExceeded }
    let total = row.partialValue.multipliedReportingOverflow(by: height)
    guard !total.overflow, total.partialValue > 0 else {
      throw PNGIndependentRGBA16Error.operationBudgetExceeded
    }
    return total.partialValue
  }

  private func readUInt32BE(_ data: Data, at offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= data.count else { return nil }
    return UInt32(data[offset]) << 24
      | UInt32(data[offset + 1]) << 16
      | UInt32(data[offset + 2]) << 8
      | UInt32(data[offset + 3])
  }
}
