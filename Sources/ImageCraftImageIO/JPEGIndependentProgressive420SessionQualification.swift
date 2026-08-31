import Foundation
import ImageCraftCore

/// Package-only concurrency/lifecycle adapter for the owned progressive JFIF 4:2:0 kernel.
///
/// This adapter intentionally does not manufacture `DecodedImage` generations from the kernel's
/// raw RGB8 backing. Doing so would cross Core Graphics before that representation/resource seam is
/// qualified. It instead proves that the independent kernel can satisfy the existing session's
/// arbitrary-chunk, concurrent-call serialization, input-reclamation and terminal-lifecycle model.
package final class JPEGIndependentProgressive420SessionQualification:
  ImageProgressiveSessionQualifying,
  ProgressiveImagePackedRGB8FinalizingSession,
  ProgressiveImageDecodedImageResourceFinalizingSession,
  @unchecked Sendable
{
  private let lock = NSLock()
  private let limits: DecodeLimits
  private let maximumCodecOwnedByteCharge: Int
  private var kernel: JPEGIndependentProgressive420Decoder.IncrementalSession
  private var isCancelled = false
  private var isFinished = false
  private var hasQualifiedFrame = false
  private var finalPackedFactsStable = false
  private var lastProgress: ImageProgressiveQualificationProgress = .needMoreInput

  package init(
    maximumCodecOwnedByteCharge: Int,
    limits: DecodeLimits = .coreV1,
    previewCadence: JPEGIndependentProgressive420Decoder.IncrementalSessionPreviewCadence = .finalOnly
  ) throws {
    self.maximumCodecOwnedByteCharge = maximumCodecOwnedByteCharge
    self.limits = limits
    self.kernel = try JPEGIndependentProgressive420Decoder.IncrementalSession(
      maximumCodecOwnedByteCharge: maximumCodecOwnedByteCharge,
      limits: limits,
      previewCadence: previewCadence
    )
  }

  package var receivedByteCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return kernel.snapshot().acceptedEncodedBytes
  }

  package var qualificationSnapshot: ImageProgressiveQualificationSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return qualificationSnapshotLocked()
  }

  /// The qualification adapter deliberately publishes no public `DecodedImage` preview. A non-nil
  /// generation here would imply a representation conversion whose allocation/color authority has
  /// not yet been qualified. Scan completion remains visible through the kernel evidence/snapshot.
  package func append(_ chunk: Data) throws -> ImageProgressiveDecodeGeneration? {
    lock.lock()
    defer { lock.unlock() }
    try checkActiveLocked()
    guard !chunk.isEmpty else {
      let snapshot = kernel.snapshot()
      updateQualificationStateLocked(snapshot: snapshot, madeProgress: false)
      return nil
    }

    do {
      let completedScans = try kernel.append(chunk)
      let snapshot = kernel.snapshot()
      if snapshot.statePlan != nil { hasQualifiedFrame = true }
      updateQualificationStateLocked(
        snapshot: snapshot,
        madeProgress: !completedScans.isEmpty || !chunk.isEmpty
      )
      return nil
    } catch {
      let snapshot = kernel.snapshot()
      if snapshot.statePlan != nil { hasQualifiedFrame = true }
      if snapshot.phase == .terminal {
        isFinished = true
        lastProgress = .terminal
      }
      throw error
    }
  }

  package func finish() throws {
    lock.lock()
    defer { lock.unlock() }
    try checkActiveLocked()
    do {
      _ = try kernel.finish()
      isFinished = true
      finalPackedFactsStable = true
      lastProgress = .terminal
    } catch {
      if kernel.snapshot().phase == .terminal {
        isFinished = true
        lastProgress = .terminal
      }
      throw error
    }
  }

  /// Package-only kernel-value seam used when tests need scan/state-plan facts in addition to the
  /// packed pixel payload. Callers that only need a backend-neutral packed value should use
  /// `finishWithPackedRGB8()` instead.
  package func finishWithKernelImage() throws -> JPEGIndependentProgressive420Image {
    lock.lock()
    defer { lock.unlock() }
    try checkActiveLocked()
    return try finishKernelImageLocked()
  }

  private func finishKernelImageLocked() throws -> JPEGIndependentProgressive420Image {
    do {
      let image = try kernel.finish()
      isFinished = true
      hasQualifiedFrame = true
      finalPackedFactsStable = true
      lastProgress = .terminal
      return image
    } catch {
      if kernel.snapshot().phase == .terminal {
        isFinished = true
        lastProgress = .terminal
      }
      throw error
    }
  }

  /// Backend-neutral final packed value for the qualified JFIF slice. JFIF supplies no trusted ICC
  /// profile, so source-profile classification remains `.absent`; ImageCraft's stable fallback
  /// output interpretation for profile-absent RGB is sRGB, matching the existing packed ImageIO
  /// contract. Constructing the value does not synthesize alpha or rasterize through Core Graphics.
  package func finishWithPackedRGB8() throws -> ImageProgressivePackedRGB8Finalization {
    lock.lock()
    defer { lock.unlock() }
    try checkActiveLocked()
    let sourceByteCount = kernel.snapshot().acceptedEncodedBytes
    let image = try finishKernelImageLocked()
    return ImageProgressivePackedRGB8Finalization(
      image: try Self.packedRGB8Value(from: image),
      sourceByteCount: sourceByteCount
    )
  }

  package static func packedRGB8Value(
    from image: JPEGIndependentProgressive420Image
  ) throws -> ImagePackedRGB8 {
    guard let packed = ImagePackedRGB8(
      data: image.rgb,
      pixelWidth: image.width,
      pixelHeight: image.height,
      colorEncoding: .sRGB,
      sourceColorProfile: .absent
    ) else { throw ImagePackedPixelContractError.invalidBuffer }
    return packed
  }

  package func finishWithDecodedImageResourceAuthority() throws
    -> ImageProgressiveDecodedImageResourceFinalization
  {
    lock.lock()
    defer { lock.unlock() }
    try checkActiveLocked()
    guard let preflightLedger = try decodedImageFinalizationResourceLedgerLocked() else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    let ready = kernel.snapshot()
    guard ready.phase == .complete, let plan = ready.statePlan else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    let probe = try ImageProbe(
      pixelWidth: plan.width,
      pixelHeight: plan.height,
      frameCount: 1,
      orientation: 1,
      format: .jpeg,
      metadataByteCount: ready.metadataByteCount,
      auxiliaryAttachmentCount: 0,
      sourceColorProfile: .absent
    )
    let sourceByteCount = ready.acceptedEncodedBytes
    let kernelImage = try finishKernelImageLocked()
    let packed = try Self.packedRGB8Value(from: kernelImage)
    let materialized = try ImagePackedRGB8DecodedImageMaterializer.materialize(
      packed
    )
    guard materialized.resourceLedger.retainedKnownBytes == 0,
      materialized.resourceLedger.retainedBetweenCalls == .bounded(0),
      materialized.resourceLedger.operationPeak == preflightLedger.operationPeak,
      materialized.resourceLedger.transferredOutput == preflightLedger.transferredOutput,
      materialized.resourceLedger.outputLayoutAuthority == preflightLedger.outputLayoutAuthority
    else {
      throw ImageCraftError.decodeFailed
    }
    return ImageProgressiveDecodedImageResourceFinalization(
      image: materialized.image,
      probe: probe,
      sourceByteCount: sourceByteCount,
      materializationResourceLedger: preflightLedger
    )
  }

  package func decodedImageFinalizationResourceLedger() throws
    -> ImageDecodeResourceLedgerSnapshot?
  {
    lock.lock()
    defer { lock.unlock() }
    try checkActiveLocked()
    return try decodedImageFinalizationResourceLedgerLocked()
  }

  private func decodedImageFinalizationResourceLedgerLocked() throws
    -> ImageDecodeResourceLedgerSnapshot?
  {
    let ready = kernel.snapshot()
    guard ready.phase == .complete else { return nil }
    guard ready.resourceLedger.outputLayoutAuthority == .codecOwnedRGB8,
      let transferredOutput = ready.resourceLedger.bytesUpperBound(for: .transferredOutput),
      let ledger = ImageDecodeResourceLedgerSnapshot(
        retainedKnownBytes: ready.resourceLedger.retainedKnownBytes,
        retainedBetweenCalls: ready.resourceLedger.retainedBetweenCalls,
        operationPeak: .unknown(.frameworkPrivateOperationAllocation),
        transferredOutput: .bounded(transferredOutput),
        outputLayoutAuthority: .codecOwnedRGB8
      )
    else { throw ImageCraftError.decodeFailed }
    return ledger
  }

  package func cancel() {
    lock.lock()
    defer { lock.unlock() }
    guard !isCancelled, !isFinished else { return }
    isCancelled = true
    kernel.cancel()
    lastProgress = .terminal
  }

  private func checkActiveLocked() throws {
    if isCancelled { throw ImageCraftError.progressiveSessionCancelled }
    if isFinished { throw ImageCraftError.progressiveSessionFinished }
  }

  private func updateQualificationStateLocked(
    snapshot: JPEGIndependentProgressive420Decoder.IncrementalSessionSnapshot,
    madeProgress: Bool
  ) {
    switch snapshot.phase {
    case .complete:
      lastProgress = .finalReady
    case .terminal:
      lastProgress = .terminal
    default:
      lastProgress = madeProgress ? .madeProgress : .needMoreInput
    }
  }

  private func qualificationSnapshotLocked() -> ImageProgressiveQualificationSnapshot {
    let snapshot = kernel.snapshot()
    if snapshot.statePlan != nil { hasQualifiedFrame = true }

    let terminal = snapshot.phase == .terminal
    let received = snapshot.acceptedEncodedBytes
    let retainedEncoded = terminal ? 0 : snapshot.retainedTransportBytes
    let consumedThrough = min(snapshot.reclaimedEncodedBytes, received)
    let retainFrom = retainedEncoded == 0 ? received : consumedThrough
    let operationBytes = snapshot.resourceLedger.bytesUpperBound(for: .operationPeak) ?? Int.max

    var stableFacts = Set<ImageProgressiveSemanticFact>()
    if hasQualifiedFrame {
      stableFacts.insert(.dimensions)
      stableFacts.insert(.frameCount)
    }

    // The packed backend has no public orientation/source-color value contract yet, and this
    // adapter emits no DecodedImage preview, so do not relabel those semantics as tentative or final.
    let previewState: ImageProgressivePreviewSemanticState =
      finalPackedFactsStable ? .finalStable : .none

    return ImageProgressiveQualificationSnapshot(
      inputProfile: hasQualifiedFrame ? .arbitraryChunk : nil,
      progress: terminal ? .terminal : lastProgress,
      receivedByteCount: received,
      consumedThrough: consumedThrough,
      retainFrom: retainFrom,
      retainedEncodedBytes: retainedEncoded,
      maximumRetainedEncodedBytes: min(
        limits.maximumEncodedBytes,
        JPEGIndependentProgressive420Decoder.IncrementalSession.transportCapacityBytes
      ),
      modeledOwnedOperationBytes: operationBytes,
      maximumTightRGBABytes: 0,
      retainsOpaqueFrameworkStateBetweenCalls: false,
      resourceLedger: snapshot.resourceLedger,
      stableFacts: stableFacts,
      tentativeFacts: [],
      previewSemanticState: previewState
    )
  }
}
