import CoreGraphics
import Foundation
import ImageCraftCore
import ImageCraftImageIO

enum ProgressiveFinalizationAdmission: Equatable {
  case unavailable
  case notReady
  case resourceAware(ImageDecodeResourceLedgerSnapshot)
  case rejectedUnknown(ImageDecodeResourceUnknownReason)
  case legacyValueOnly
}

/// Example host-owned finalization admission policy compiled outside the ImageCraft package.
/// Resource-aware authority always takes precedence over the legacy value-only capability so an
/// unknown operation peak cannot disappear through fallback. This function only inspects; it never
/// calls a consuming finalizer.
func inspectProgressiveFinalizationAdmission(
  _ session: any ImageProgressiveDecodeSession,
  requireBoundedOperation: Bool
) throws -> ProgressiveFinalizationAdmission {
  if let resourceAware =
    session as? any ProgressiveImageDecodedImageResourceFinalizingSession
  {
    guard let ledger = try resourceAware.decodedImageFinalizationResourceLedger() else {
      return .notReady
    }
    if requireBoundedOperation,
      case .unknown(let reason) = ledger.operationPeak
    {
      return .rejectedUnknown(reason)
    }
    return .resourceAware(ledger)
  }

  if session is any ProgressiveImageFinalizingSession {
    return .legacyValueOnly
  }
  return .unavailable
}

/// 只通过 ImageCraft 的公开 SwiftPM 产品编译的外部消费者烟雾目标。
public struct ImageCraftConsumerSmoke: Sendable {
  public init() {}

  public var decoderFingerprint: String {
    ImageIOImageDecoder().codecDescriptor.cacheFingerprint
  }

  public var encoderFingerprint: String {
    ImageIOImageEncoder().encoderDescriptor.cacheFingerprint
  }

  /// Compile-time witness that hosts can request the backend-neutral packed RGBA8 representation
  /// without importing any package-only producer implementation.
  public var packedRGBA8OutputRepresentation: ImageDecodeOutputRepresentation {
    .packedRGBA8
  }

  /// Example host-side total-live-set composition: encoded input remains caller-owned while the
  /// codec operation runs, so it is added at the ownership boundary rather than hidden in the
  /// codec's phase ledger.
  public func operationLiveSetBound(
    ledger: ImageDecodeResourceLedgerSnapshot,
    encodedSourceByteCount: Int
  ) -> ImageDecodeResourceBound? {
    ledger.coexistenceBound(
      for: .operationPeak,
      callerRetainedBytes: encodedSourceByteCount
    )
  }

  public func decodeJPEG(_ data: Data) throws -> DecodedImage {
    let target = try TargetPixels(width: 512, height: 512)
    return try ImageIOImageDecoder().decode(
      data: data,
      request: ImageDecodeRequest(
        target: target,
        contentMode: .fit,
        colorPolicy: .convertToSRGB
      ),
      limits: DecodeLimits(
        maximumEncodedBytes: 16 * 1024 * 1024,
        maximumDimension: 8_192,
        maximumPixelCount: 40_000_000,
        maximumFrameCount: 1,
        maximumMetadataBytes: 2 * 1024 * 1024,
        maximumAuxiliaryAttachments: 0,
        allowedFormats: [.jpeg]
      )
    )
  }

  public func encodePNG(_ image: CGImage) throws -> EncodedImage {
    let request = try ImageEncodeRequest.png(
      colorPolicy: .convertToSRGB,
      metadataPolicy: .discard,
      alphaPolicy: .preserve
    )
    return try ImageIOImageEncoder().encode(
      image: image,
      request: request,
      limits: EncodeLimits(
        maximumDimension: 8_192,
        maximumPixelCount: 40_000_000,
        maximumEncodedBytes: 32 * 1024 * 1024,
        allowedFormats: [.png]
      )
    )
  }
  public func prepareAnimation(_ data: Data) async throws -> AnimatedImageAsset {
    try await ImageIOAnimatedImageDecoder().prepareAnimation(
      source: .encoded(data),
      limits: ImageAnimationDecodeLimits(
        imageLimits: DecodeLimits(
          maximumEncodedBytes: 16 * 1024 * 1024,
          maximumDimension: 4_096,
          maximumPixelCount: 16_000_000,
          maximumFrameCount: 128,
          maximumMetadataBytes: 2 * 1024 * 1024,
          maximumAuxiliaryAttachments: 0,
          allowedFormats: [.png, .gif]
        ),
        maximumTimelineDecodedBytes: 256 * 1024 * 1024,
        maximumFrameDecodeWindow: 8
      )
    )
  }

  public func exerciseAnimationPublicSurface(_ data: Data) async throws
    -> [DecodedAnimationFrame]
  {
    let asset = try await prepareAnimation(data)
    do {
      let request = ImageDecodeRequest(
        target: try TargetPixels(width: 256, height: 256),
        contentMode: .fit,
        colorPolicy: .convertToSRGB
      )
      if let estimate = asset.wholeTrackCostEstimate(for: request) {
        _ = estimate.residentDecodedByteCostUpperBound
        _ = estimate.providerRetainedByteCostUpperBound
        _ = estimate.predecodePeakByteCostUpperBound
      }
      let upperBound = min(2, asset.metadata.frameCount)
      let window = try await asset.frames(in: 0..<upperBound, request: request)
      _ = try await asset.frame(at: 0, request: request)
      await asset.cancel()
      return window
    } catch {
      await asset.cancel()
      throw error
    }
  }
}
