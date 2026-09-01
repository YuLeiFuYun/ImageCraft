import ImageCraftCore

package enum ImageIOAnimationBackingKind: String, Codable, Sendable {
  case ownedAPNG
  case ownedGIF
  case imageIOEncoded
  case jpegSequence
}

package struct ImageIOAnimationPreparationDiagnostics: Codable, Sendable {
  package let backingKind: ImageIOAnimationBackingKind
  package let imageIOSourceIndicesMatchTimeline: Bool?
  package let resourceLedger: ImageDecodeResourceLedgerSnapshot
  package let ownedEncodedFramePayloadBytes: Int?
  package let ownedRetainedCheckpointBytes: Int?
  package let ownedRetainedBytes: Int?
  package let ownedRetainedCheckpointCount: Int?
  package let ownedMaximumReplayFrames: Int?
  package let ownedSemanticReplayResetCount: Int?
  package let ownedMaximumResolvedReplayFrames: Int?
  package let ownedCanvasRGBABytes: Int?
  package let ownedMaximumRawSubrectRGBABytes: Int?
  package let ownedMaximumPreviousSaveRGBABytes: Int?
  package let ownedMaterializedOutputRGBABytes: Int?
  package let ownedDecompressorWorkspaceBytes: Int?
  package let ownedModeledPeakBytesUpperBound: Int?

  static func ownedAPNG(
    _ diagnostics: APNGOwnedPlaybackDiagnostics,
    imageIOSourceIndicesMatchTimeline: Bool
  ) -> Self {
    Self(
      backingKind: .ownedAPNG,
      imageIOSourceIndicesMatchTimeline: imageIOSourceIndicesMatchTimeline,
      resourceLedger: ImageDecodeResourceLedgerSnapshot(
        retainedKnownBytes: diagnostics.retainedBytes,
        retainedBetweenCalls: .bounded(diagnostics.retainedBytes),
        operationPeak: .unknown(.frameworkPrivateOperationAllocation),
        transferredOutput: .unknown(.frameworkChosenOutputLayout)
      )!,
      ownedEncodedFramePayloadBytes: diagnostics.encodedFramePayloadBytes,
      ownedRetainedCheckpointBytes: diagnostics.retainedCheckpointBytes,
      ownedRetainedBytes: diagnostics.retainedBytes,
      ownedRetainedCheckpointCount: diagnostics.retainedCheckpointCount,
      ownedMaximumReplayFrames: diagnostics.maximumReplayFrames,
      ownedSemanticReplayResetCount: diagnostics.semanticReplayResetCount,
      ownedMaximumResolvedReplayFrames: diagnostics.maximumResolvedReplayFrames,
      ownedCanvasRGBABytes: diagnostics.canvasRGBABytes,
      ownedMaximumRawSubrectRGBABytes: diagnostics.maximumRawSubrectRGBABytes,
      ownedMaximumPreviousSaveRGBABytes: diagnostics.maximumPreviousSaveRGBABytes,
      ownedMaterializedOutputRGBABytes: diagnostics.materializedOutputRGBABytes,
      ownedDecompressorWorkspaceBytes: diagnostics.decompressorWorkspaceBytes,
      ownedModeledPeakBytesUpperBound: diagnostics.modeledPeakBytesUpperBound
    )
  }

  static func ownedGIF(
    _ diagnostics: GIFOwnedPlaybackDiagnostics,
    imageIOSourceIndicesMatchTimeline: Bool
  ) -> Self {
    Self(
      backingKind: .ownedGIF,
      imageIOSourceIndicesMatchTimeline: imageIOSourceIndicesMatchTimeline,
      resourceLedger: ImageDecodeResourceLedgerSnapshot(
        retainedKnownBytes: diagnostics.retainedBytes,
        retainedBetweenCalls: .bounded(diagnostics.retainedBytes),
        operationPeak: .unknown(.frameworkPrivateOperationAllocation),
        transferredOutput: .unknown(.frameworkChosenOutputLayout)
      )!,
      ownedEncodedFramePayloadBytes: diagnostics.encodedFramePayloadBytes,
      ownedRetainedCheckpointBytes: nil,
      ownedRetainedBytes: diagnostics.retainedBytes,
      ownedRetainedCheckpointCount: nil,
      ownedMaximumReplayFrames: nil,
      ownedSemanticReplayResetCount: nil,
      ownedMaximumResolvedReplayFrames: nil,
      ownedCanvasRGBABytes: diagnostics.materializedOutputRGBABytes,
      ownedMaximumRawSubrectRGBABytes: nil,
      ownedMaximumPreviousSaveRGBABytes: nil,
      ownedMaterializedOutputRGBABytes: diagnostics.materializedOutputRGBABytes,
      ownedDecompressorWorkspaceBytes: diagnostics.lzwWorkspaceBytes,
      ownedModeledPeakBytesUpperBound: diagnostics.modeledPeakBytesUpperBound
    )
  }

  static func imageIOEncoded(
    imageIOSourceIndicesMatchTimeline: Bool
  ) -> Self {
    Self(
      backingKind: .imageIOEncoded,
      imageIOSourceIndicesMatchTimeline: imageIOSourceIndicesMatchTimeline,
      resourceLedger: ImageDecodeResourceLedgerSnapshot(
        retainedKnownBytes: 0,
        retainedBetweenCalls: .unknown(.frameworkPrivateRetainedState),
        operationPeak: .unknown(.frameworkPrivateOperationAllocation),
        transferredOutput: .unknown(.frameworkChosenOutputLayout)
      )!,
      ownedEncodedFramePayloadBytes: nil,
      ownedRetainedCheckpointBytes: nil,
      ownedRetainedBytes: nil,
      ownedRetainedCheckpointCount: nil,
      ownedMaximumReplayFrames: nil,
      ownedSemanticReplayResetCount: nil,
      ownedMaximumResolvedReplayFrames: nil,
      ownedCanvasRGBABytes: nil,
      ownedMaximumRawSubrectRGBABytes: nil,
      ownedMaximumPreviousSaveRGBABytes: nil,
      ownedMaterializedOutputRGBABytes: nil,
      ownedDecompressorWorkspaceBytes: nil,
      ownedModeledPeakBytesUpperBound: nil
    )
  }

  static func jpegSequence(
    encodedFramePayloadBytes: Int,
    retainedProfileBytes: Int,
    retainedBytes: Int
  ) -> Self {
    precondition(encodedFramePayloadBytes >= 0)
    precondition(retainedProfileBytes >= 0)
    precondition(retainedBytes >= encodedFramePayloadBytes)
    precondition(retainedBytes - encodedFramePayloadBytes == retainedProfileBytes)
    return Self(
      backingKind: .jpegSequence,
      imageIOSourceIndicesMatchTimeline: nil,
      resourceLedger: ImageDecodeResourceLedgerSnapshot(
        retainedKnownBytes: retainedBytes,
        retainedBetweenCalls: .bounded(retainedBytes),
        operationPeak: .unknown(.frameworkPrivateOperationAllocation),
        transferredOutput: .unknown(.frameworkChosenOutputLayout)
      )!,
      ownedEncodedFramePayloadBytes: encodedFramePayloadBytes,
      ownedRetainedCheckpointBytes: nil,
      ownedRetainedBytes: retainedBytes,
      ownedRetainedCheckpointCount: nil,
      ownedMaximumReplayFrames: nil,
      ownedSemanticReplayResetCount: nil,
      ownedMaximumResolvedReplayFrames: nil,
      ownedCanvasRGBABytes: nil,
      ownedMaximumRawSubrectRGBABytes: nil,
      ownedMaximumPreviousSaveRGBABytes: nil,
      ownedMaterializedOutputRGBABytes: nil,
      ownedDecompressorWorkspaceBytes: nil,
      ownedModeledPeakBytesUpperBound: nil
    )
  }
}

package typealias ImageIOAnimationFrameWindowCostEstimate = ImageAnimationFrameWindowCostEstimate

package struct ImageIOInstrumentedAnimatedImageAsset: Sendable {
  package let asset: AnimatedImageAsset
  package let diagnostics: ImageIOAnimationPreparationDiagnostics
  private let lifecycleSnapshotProvider:
    @Sendable () async -> ImageIOAnimationProviderLifecycleSnapshot
  private let frameWindowCostEstimateProvider:
    @Sendable (ImageDecodeRequest, Int) -> ImageIOAnimationFrameWindowCostEstimate?

  package init(
    asset: AnimatedImageAsset,
    diagnostics: ImageIOAnimationPreparationDiagnostics,
    lifecycleSnapshotProvider:
      @escaping @Sendable () async -> ImageIOAnimationProviderLifecycleSnapshot,
    frameWindowCostEstimateProvider:
      @escaping @Sendable (ImageDecodeRequest, Int) -> ImageIOAnimationFrameWindowCostEstimate? = {
        _, _ in nil
      }
  ) {
    self.asset = asset
    self.diagnostics = diagnostics
    self.lifecycleSnapshotProvider = lifecycleSnapshotProvider
    self.frameWindowCostEstimateProvider = frameWindowCostEstimateProvider
  }

  package func lifecycleSnapshot() async -> ImageIOAnimationProviderLifecycleSnapshot {
    await lifecycleSnapshotProvider()
  }

  /// Returns the current codec-owned payload ledger. Cancellation becomes terminal only after all
  /// registered operations drain, so an in-flight closure that still owns the prepared backing is
  /// never relabeled as reclaimed state.
  package func resourceLedgerSnapshot() async -> ImageDecodeResourceLedgerSnapshot {
    let lifecycle = await lifecycleSnapshotProvider()
    guard lifecycle.isCancelled,
      lifecycle.activeOperationCount == 0,
      lifecycle.queuedOperationCount == 0,
      !lifecycle.holdsPreparedBacking
    else { return diagnostics.resourceLedger }
    return .terminal
  }

  package func frameWindowCostEstimate(
    for request: ImageDecodeRequest,
    frameCount: Int
  ) -> ImageIOAnimationFrameWindowCostEstimate? {
    frameWindowCostEstimateProvider(request, frameCount)
  }
}
