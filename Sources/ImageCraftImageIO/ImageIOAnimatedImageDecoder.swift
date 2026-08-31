import CoreGraphics
import Foundation
import ImageCraftCore
import ImageIO

/// ImageIO 参考动画后端：GIF/APNG 单容器与有界 JPEG 完整帧序列。
public struct ImageIOAnimatedImageDecoder: ImageAnimationDecoding {
  private let preparationExecutor: ImageIOAnimationWorkExecutor
  private let frameOperationHook: @Sendable () -> Void

  public let codecDescriptor = ImageCodecDescriptor(
    identifier: ImageCodecIdentifier(rawValue: "dev.fovea.imageio.animation"),
    implementationVersion: 2,
    capabilities: ImageCodecCapabilities(
      formats: [.png, .jpeg, .gif],
      deliveryModes: [.completeFrame],
      progressiveFormats: [],
      trackModes: [.animatedSequence],
      metadata: [.orientation, .sourceColorProfile, .frameTiming],
      dynamicRanges: [.standard],
      outputRepresentations: [.coreGraphicsImage],
      cancellationMode: .operationBoundary
    )
  )

  public init() {
    preparationExecutor = ImageIOAnimationWorkExecutor()
    frameOperationHook = {}
  }

  package init(frameOperationHook: @escaping @Sendable () -> Void) {
    preparationExecutor = ImageIOAnimationWorkExecutor()
    self.frameOperationHook = frameOperationHook
  }

  public func prepareAnimation(
    source: ImageAnimationSource,
    limits: ImageAnimationDecodeLimits = ImageAnimationDecodeLimits()
  ) async throws -> AnimatedImageAsset {
    try await prepareAnimationWithDiagnostics(
      source: source,
      limits: limits
    ).asset
  }

  package func prepareAnimationWithDiagnostics(
    source: ImageAnimationSource,
    limits: ImageAnimationDecodeLimits = ImageAnimationDecodeLimits()
  ) async throws -> ImageIOInstrumentedAnimatedImageAsset {
    try Task.checkCancellation()
    let result = try await preparationExecutor.run { [self] in
      switch source {
      case .encoded(let data):
        return try prepareEncoded(data, limits: limits)
      case .jpegSequence(let frames, let loopCount):
        return try prepareJPEGSequence(
          frames,
          loopCount: loopCount,
          limits: limits
        )
      }
    }
    try Task.checkCancellation()
    return result
  }

  private func prepareEncoded(
    _ data: Data,
    limits: ImageAnimationDecodeLimits
  ) throws -> ImageIOInstrumentedAnimatedImageAsset {
    let inspection = try AnimatedContainerInspector.inspect(data, limits: limits)
    try Self.validateTimeline(inspection, limits: limits)
    let ownedPlayback = try APNGOwnedAnimationIntegration.prepareIfSupported(
      data: data,
      inspection: inspection,
      limits: limits
    )
    let ownedGIF =
      ownedPlayback == nil
      ? try GIFOwnedPlayback.prepareIfSupported(
        data: data,
        inspection: inspection,
        maximumReplayFrames: limits.maximumFrameDecodeWindow
      )
      : nil
    let metadata = try ImageAnimationMetadata(
      container: inspection.container,
      canvasWidth: inspection.canvasWidth,
      canvasHeight: inspection.canvasHeight,
      loopCount: inspection.loopCount,
      frames: inspection.frames,
      encodedByteCount: inspection.encodedByteCount,
      codecFingerprint: codecDescriptor.cacheFingerprint
    )
    let backing: ImageIOAnimationBacking
    if let ownedPlayback {
      backing = .ownedAPNG(
        playback: ownedPlayback,
        inspection: inspection
      )
    } else if let ownedGIF {
      backing = .ownedGIF(
        playback: ownedGIF,
        inspection: inspection
      )
    } else {
      backing = .encoded(
        source: try Self.validatedImageIOSource(
          data,
          inspection: inspection
        ),
        inspection: inspection
      )
    }
    let provider = ImageIOAnimationFrameProvider(
      backing: backing,
      metadata: metadata,
      limits: limits,
      executor: ImageIOAnimationWorkExecutor(beforeOperation: frameOperationHook)
    )
    let diagnostics: ImageIOAnimationPreparationDiagnostics
    if let ownedPlayback {
      diagnostics = .ownedAPNG(
        ownedPlayback.diagnostics,
        imageIOSourceIndicesMatchTimeline: inspection.imageIOSourceIndicesMatchTimeline
      )
    } else if let ownedGIF {
      diagnostics = .ownedGIF(
        ownedGIF.diagnostics,
        imageIOSourceIndicesMatchTimeline: inspection.imageIOSourceIndicesMatchTimeline
      )
    } else {
      diagnostics = .imageIOEncoded(
        imageIOSourceIndicesMatchTimeline: inspection.imageIOSourceIndicesMatchTimeline
      )
    }
    let wholeTrackCostEstimateProvider:
      @Sendable (ImageDecodeRequest) -> ImageAnimationWholeTrackCostEstimate?
    let frameWindowCostEstimateProvider:
      @Sendable (ImageDecodeRequest, Int) -> ImageIOAnimationFrameWindowCostEstimate?
    let ownedCostModel:
      (
        canvasRGBABytes: Int,
        retainedBytes: Int,
        modeledPeakBytesUpperBound: Int
      )?
    if let ownedPlayback {
      ownedCostModel = (
        ownedPlayback.diagnostics.canvasRGBABytes,
        ownedPlayback.diagnostics.retainedBytes,
        ownedPlayback.diagnostics.modeledPeakBytesUpperBound
      )
    } else if let ownedGIF {
      ownedCostModel = (
        ownedGIF.diagnostics.materializedOutputRGBABytes,
        ownedGIF.diagnostics.retainedBytes,
        ownedGIF.diagnostics.modeledPeakBytesUpperBound
      )
    } else {
      ownedCostModel = nil
    }
    if let ownedCostModel {
      let canvasWidth = metadata.canvasWidth
      let canvasHeight = metadata.canvasHeight
      let frameCount = metadata.frameCount
      let imageLimits = limits.imageLimits
      let maximumFrameDecodeWindow = limits.maximumFrameDecodeWindow
      frameWindowCostEstimateProvider = { request, requestedFrameCount in
        guard requestedFrameCount > 0,
          requestedFrameCount <= frameCount,
          requestedFrameCount <= maximumFrameDecodeWindow,
          let decodedOutputBound =
            ImageIOAnimationFrameRenderer.ownedRGBAWholeTrackDecodedByteCostUpperBound(
              canvasWidth: canvasWidth,
              canvasHeight: canvasHeight,
              frameCount: requestedFrameCount,
              request: request,
              limits: imageLimits
            ),
          let rasterWindowBound =
            ImageIOAnimationFrameRenderer.ownedRGBARasterTrackByteCostUpperBound(
              canvasWidth: canvasWidth,
              canvasHeight: canvasHeight,
              frameCount: requestedFrameCount,
              request: request,
              limits: imageLimits
            )
        else { return nil }
        let extraMaterializedFrames = requestedFrameCount - 1
        let extraMaterialized = ownedCostModel.canvasRGBABytes.multipliedReportingOverflow(
          by: extraMaterializedFrames
        )
        let rasterPerFrame = rasterWindowBound.quotientAndRemainder(
          dividingBy: requestedFrameCount
        ).quotient
        let rendererTransient = rasterPerFrame.multipliedReportingOverflow(by: 2)
        guard !extraMaterialized.overflow, !rendererTransient.overflow else { return nil }
        var peak = ownedCostModel.modeledPeakBytesUpperBound.addingReportingOverflow(
          extraMaterialized.partialValue
        )
        guard !peak.overflow else { return nil }
        peak = peak.partialValue.addingReportingOverflow(rasterWindowBound)
        guard !peak.overflow else { return nil }
        peak = peak.partialValue.addingReportingOverflow(rendererTransient.partialValue)
        guard !peak.overflow else { return nil }
        return ImageIOAnimationFrameWindowCostEstimate(
          frameCount: requestedFrameCount,
          decodedOutputByteCostUpperBound: decodedOutputBound,
          providerRetainedByteCostUpperBound: ownedCostModel.retainedBytes,
          predecodePeakByteCostUpperBound: peak.partialValue
        )
      }
      wholeTrackCostEstimateProvider = { request in
        guard
          let residentBound =
            ImageIOAnimationFrameRenderer.ownedRGBAWholeTrackDecodedByteCostUpperBound(
              canvasWidth: canvasWidth,
              canvasHeight: canvasHeight,
              frameCount: frameCount,
              request: request,
              limits: imageLimits
            ),
          let rasterTrackBound =
            ImageIOAnimationFrameRenderer.ownedRGBARasterTrackByteCostUpperBound(
              canvasWidth: canvasWidth,
              canvasHeight: canvasHeight,
              frameCount: frameCount,
              request: request,
              limits: imageLimits
            )
        else { return nil }
        let chunkFrameCount = min(frameCount, maximumFrameDecodeWindow)
        let extraMaterializedFrames = max(0, chunkFrameCount - 1)
        let extraMaterialized = ownedCostModel.canvasRGBABytes.multipliedReportingOverflow(
          by: extraMaterializedFrames
        )
        let rasterPerFrame = rasterTrackBound.quotientAndRemainder(dividingBy: frameCount).quotient
        let rendererTransient = rasterPerFrame.multipliedReportingOverflow(by: 2)
        guard !extraMaterialized.overflow, !rendererTransient.overflow else { return nil }
        var peak = ownedCostModel.modeledPeakBytesUpperBound.addingReportingOverflow(
          extraMaterialized.partialValue
        )
        guard !peak.overflow else { return nil }
        peak = peak.partialValue.addingReportingOverflow(rasterTrackBound)
        guard !peak.overflow else { return nil }
        peak = peak.partialValue.addingReportingOverflow(rendererTransient.partialValue)
        guard !peak.overflow else { return nil }
        return ImageAnimationWholeTrackCostEstimate(
          residentDecodedByteCostUpperBound: residentBound,
          providerRetainedByteCostUpperBound: ownedCostModel.retainedBytes,
          predecodePeakByteCostUpperBound: peak.partialValue
        )
      }
    } else {
      frameWindowCostEstimateProvider = { _, _ in nil }
      wholeTrackCostEstimateProvider = { _ in nil }
    }
    return ImageIOInstrumentedAnimatedImageAsset(
      asset: AnimatedImageAsset(
        metadata: metadata,
        provider: provider,
        wholeTrackCostEstimateProvider: wholeTrackCostEstimateProvider
      ),
      diagnostics: diagnostics,
      lifecycleSnapshotProvider: { await provider.lifecycleSnapshot() },
      frameWindowCostEstimateProvider: frameWindowCostEstimateProvider
    )
  }

  private func prepareJPEGSequence(
    _ frames: [ImageJPEGAnimationFrame],
    loopCount: ImageAnimationLoopCount,
    limits: ImageAnimationDecodeLimits
  ) throws -> ImageIOInstrumentedAnimatedImageAsset {
    guard limits.imageLimits.allowedFormats.contains(.jpeg) else {
      throw ImageCraftError.unsupportedFormat
    }
    guard !frames.isEmpty,
      frames.count <= limits.imageLimits.maximumFrameCount
    else { throw ImageCraftError.frameLimitExceeded }
    var totalEncodedBytes = 0
    var totalMetadataBytes = 0
    var firstProbe: ImageProbe?
    var firstSourceProfile: SourceColorProfile?
    var firstICCProfile: Data?
    var descriptors: [ImageAnimationFrameDescriptor] = []
    var preparedFrames: [ImageIOJPEGAnimationFrameSource] = []
    descriptors.reserveCapacity(frames.count)
    preparedFrames.reserveCapacity(frames.count)
    let decoder = ImageIOImageDecoder()
    let jpegLimits = Self.jpegFrameLimits(from: limits.imageLimits)

    for (index, frame) in frames.enumerated() {
      let next = totalEncodedBytes.addingReportingOverflow(frame.data.count)
      guard !next.overflow, next.partialValue <= limits.imageLimits.maximumEncodedBytes else {
        throw ImageCraftError.encodedBytesExceeded
      }
      totalEncodedBytes = next.partialValue
      let probe = try decoder.probe(data: frame.data, limits: jpegLimits)
      guard probe.format == .jpeg, probe.frameCount == 1 else {
        throw ImageCraftError.formatMismatch
      }
      let security = try EncodedImageSecurityInspector.inspect(
        frame.data,
        maximumMetadataBytes: jpegLimits.maximumMetadataBytes
      )
      let nextMetadata = totalMetadataBytes.addingReportingOverflow(
        security.metadataByteCount
      )
      guard !nextMetadata.overflow,
        nextMetadata.partialValue <= jpegLimits.maximumMetadataBytes
      else { throw ImageCraftError.metadataLimitExceeded }
      totalMetadataBytes = nextMetadata.partialValue
      guard security.format == .jpeg,
        let source = CGImageSourceCreateWithData(frame.data as CFData, nil),
        CGImageSourceGetCount(source) == 1,
        CGImageSourceGetType(source) as String? == "public.jpeg"
      else { throw ImageCraftError.formatMismatch }
      if let firstSourceProfile {
        guard security.sourceColorProfile == firstSourceProfile,
          security.embeddedICCProfile == firstICCProfile
        else { throw ImageCraftError.animationTimelineInvalid }
      } else {
        firstSourceProfile = security.sourceColorProfile
        firstICCProfile = security.embeddedICCProfile
      }
      preparedFrames.append(
        ImageIOJPEGAnimationFrameSource(
          data: frame.data
        )
      )
      if let firstProbe {
        guard probe.pixelWidth == firstProbe.pixelWidth,
          probe.pixelHeight == firstProbe.pixelHeight,
          probe.orientation == firstProbe.orientation
        else { throw ImageCraftError.animationFrameRectInvalid }
      } else {
        firstProbe = probe
      }
      let rect = try ImageAnimationFrameRect(
        x: 0,
        y: 0,
        width: probe.pixelWidth,
        height: probe.pixelHeight
      )
      descriptors.append(
        try ImageAnimationFrameDescriptor(
          index: index,
          duration: frame.duration,
          rect: rect,
          disposal: .none,
          blend: .source
        )
      )
    }
    guard let probe = firstProbe,
      let sourceColorProfile = firstSourceProfile
    else { throw ImageCraftError.animationTimelineInvalid }
    let retainedProfileBytes = firstICCProfile?.count ?? 0
    let retainedBytes = totalEncodedBytes.addingReportingOverflow(retainedProfileBytes)
    guard !retainedBytes.overflow else { throw ImageCraftError.encodedBytesExceeded }
    let inspection = EncodedAnimationInspection(
      container: .jpegSequence,
      sourceColorProfile: .unknown,
      embeddedICCProfile: nil,
      canvasWidth: probe.pixelWidth,
      canvasHeight: probe.pixelHeight,
      loopCount: loopCount,
      frames: descriptors,
      imageIOSourceIndicesMatchTimeline: true,
      encodedByteCount: totalEncodedBytes
    )
    try Self.validateTimeline(inspection, limits: limits)
    let metadata = try ImageAnimationMetadata(
      container: .jpegSequence,
      canvasWidth: probe.pixelWidth,
      canvasHeight: probe.pixelHeight,
      loopCount: loopCount,
      frames: descriptors,
      encodedByteCount: totalEncodedBytes,
      codecFingerprint: codecDescriptor.cacheFingerprint
    )
    let provider = ImageIOAnimationFrameProvider(
      backing: .jpegSequence(
        frames: preparedFrames,
        sourceColorProfile: sourceColorProfile,
        embeddedICCProfile: firstICCProfile
      ),
      metadata: metadata,
      limits: limits,
      executor: ImageIOAnimationWorkExecutor(beforeOperation: frameOperationHook)
    )
    return ImageIOInstrumentedAnimatedImageAsset(
      asset: AnimatedImageAsset(metadata: metadata, provider: provider),
      diagnostics: .jpegSequence(
        encodedFramePayloadBytes: totalEncodedBytes,
        retainedProfileBytes: retainedProfileBytes,
        retainedBytes: retainedBytes.partialValue
      ),
      lifecycleSnapshotProvider: { await provider.lifecycleSnapshot() }
    )
  }

  private static func validatedImageIOSource(
    _ data: Data,
    inspection: EncodedAnimationInspection
  ) throws -> ImageIOAnimationSourceBox {
    guard inspection.imageIOSourceIndicesMatchTimeline else {
      throw ImageCraftError.animationUnsupported
    }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) == inspection.frames.count
    else { throw ImageCraftError.animationTimelineInvalid }
    for index in inspection.frames.indices {
      guard
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
          as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int,
        width == inspection.canvasWidth,
        height == inspection.canvasHeight
      else { throw ImageCraftError.animationUnsupported }
    }
    return ImageIOAnimationSourceBox(source: source)
  }

  private static func validateTimeline(
    _ inspection: EncodedAnimationInspection,
    limits: ImageAnimationDecodeLimits
  ) throws {
    let imageLimits = limits.imageLimits
    guard inspection.frames.count <= imageLimits.maximumFrameCount else {
      throw ImageCraftError.frameLimitExceeded
    }
    guard inspection.canvasWidth <= imageLimits.maximumDimension,
      inspection.canvasHeight <= imageLimits.maximumDimension
    else { throw ImageCraftError.dimensionLimitExceeded }
    let canvasPixels = inspection.canvasWidth.multipliedReportingOverflow(
      by: inspection.canvasHeight
    )
    guard !canvasPixels.overflow,
      canvasPixels.partialValue <= imageLimits.maximumPixelCount
    else { throw ImageCraftError.pixelLimitExceeded }
    let frameBytes = canvasPixels.partialValue.multipliedReportingOverflow(by: 4)
    let timelineBytes = frameBytes.partialValue.multipliedReportingOverflow(
      by: inspection.frames.count
    )
    guard !frameBytes.overflow, !timelineBytes.overflow,
      timelineBytes.partialValue <= limits.maximumTimelineDecodedBytes
    else { throw ImageCraftError.animationTimelineInvalid }
  }

  private static func jpegFrameLimits(from limits: DecodeLimits) -> DecodeLimits {
    DecodeLimits(
      maximumEncodedBytes: limits.maximumEncodedBytes,
      maximumDimension: limits.maximumDimension,
      maximumPixelCount: limits.maximumPixelCount,
      maximumFrameCount: 1,
      maximumMetadataBytes: limits.maximumMetadataBytes,
      maximumAuxiliaryAttachments: limits.maximumAuxiliaryAttachments,
      allowedFormats: [.jpeg]
    )
  }
}
