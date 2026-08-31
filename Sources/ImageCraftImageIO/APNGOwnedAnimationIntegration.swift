import Foundation
import ImageCraftCore

enum APNGOwnedAnimationIntegration {
  static func prepareIfSupported(
    data: Data,
    inspection: EncodedAnimationInspection,
    limits: ImageAnimationDecodeLimits
  ) throws -> APNGOwnedStraightAlphaPlayback? {
    guard inspection.container == .apng else { return nil }
    do {
      let playback = try APNGOwnedStraightAlphaPlayback(
        encodedData: data,
        policy: policy(from: limits)
      )
      try validate(playback, inspection: inspection)
      return playback
    } catch let error as APNGRawSubrectDecodeError {
      if isFallbackEligible(error) {
        return try fallbackOrReject(inspection: inspection)
      }
      throw map(error)
    } catch let error as APNGCompressedCheckpointError {
      if isFallbackEligible(error) {
        return try fallbackOrReject(inspection: inspection)
      }
      throw map(error)
    }
  }

  static func mapFrameError(_ error: any Error) -> ImageCraftError {
    if let error = error as? APNGRawSubrectDecodeError {
      return map(error)
    }
    if let error = error as? APNGCompressedCheckpointError {
      return map(error)
    }
    return .decodeFailed
  }

  private static func policy(
    from limits: ImageAnimationDecodeLimits
  ) -> APNGOwnedPlaybackPolicy {
    let imageLimits = limits.imageLimits
    let maximumEncodedBytes = min(64 * 1_024 * 1_024, imageLimits.maximumEncodedBytes)
    let maximumAncillaryBytes = min(
      1 * 1_024 * 1_024,
      imageLimits.maximumMetadataBytes,
      maximumEncodedBytes
    )
    return APNGOwnedPlaybackPolicy(
      decodePolicy: APNGRawSubrectDecodePolicy(
        maximumEncodedBytes: maximumEncodedBytes,
        maximumCanvasDimension: min(1_024, imageLimits.maximumDimension),
        maximumFrameCount: min(512, imageLimits.maximumFrameCount),
        maximumTotalRawRGBABytes: min(
          512 * 1_024 * 1_024,
          limits.maximumTimelineDecodedBytes
        ),
        maximumAncillaryBytes: maximumAncillaryBytes
      ),
      checkpointPolicy: APNGCompressedCheckpointPolicy(
        maximumCanvasDimension: min(1_024, imageLimits.maximumDimension),
        maximumRetainedBytes: min(
          32 * 1_024 * 1_024,
          limits.maximumTimelineDecodedBytes
        ),
        maximumReplayFrames: 8,
        maximumCheckpointBlobRatioPPM: 100_000
      ),
      decompressorWorkspaceBytes: 256 * 1_024
    )
  }

  private static func validate(
    _ playback: APNGOwnedStraightAlphaPlayback,
    inspection: EncodedAnimationInspection
  ) throws {
    let image = playback.encodedImage
    guard image.canvasWidth == inspection.canvasWidth,
      image.canvasHeight == inspection.canvasHeight,
      image.frames.count == inspection.frames.count,
      loopCount(for: image.numPlays) == inspection.loopCount
    else { throw ImageCraftError.animationTimelineInvalid }

    for (encodedFrame, descriptor) in zip(image.frames, inspection.frames) {
      let control = encodedFrame.control
      let duration = try ImageAnimationFrameDuration(
        numerator: UInt32(control.delayNumerator),
        denominator: control.delayDenominator == 0
          ? 100
          : UInt32(control.delayDenominator)
      )
      let rect = try ImageAnimationFrameRect(
        x: control.xOffset,
        y: control.yOffset,
        width: control.width,
        height: control.height
      )
      guard descriptor.duration == duration,
        descriptor.rect == rect,
        descriptor.disposal == disposal(for: control.disposal),
        descriptor.blend == blend(for: control.blend)
      else { throw ImageCraftError.animationTimelineInvalid }
    }
  }

  private static func loopCount(for numPlays: UInt32) -> ImageAnimationLoopCount {
    numPlays == 0
      ? .infinite
      : ImageAnimationLoopCount(additionalRepeatCount: numPlays - 1)
  }

  private static func disposal(
    for value: UInt8
  ) -> ImageAnimationDisposalMethod? {
    switch value {
    case 0: ImageAnimationDisposalMethod.none
    case 1: .background
    case 2: .previous
    default: nil
    }
  }

  private static func blend(
    for value: UInt8
  ) -> ImageAnimationBlendOperation? {
    switch value {
    case 0: .source
    case 1: .over
    default: nil
    }
  }

  private static func fallbackOrReject(
    inspection: EncodedAnimationInspection
  ) throws -> APNGOwnedStraightAlphaPlayback? {
    guard inspection.imageIOSourceIndicesMatchTimeline else {
      throw ImageCraftError.animationUnsupported
    }
    return nil
  }

  private static func isFallbackEligible(
    _ error: APNGRawSubrectDecodeError
  ) -> Bool {
    switch error {
    case .encodedBytesExceeded,
      .metadataBudgetExceeded,
      .unsupportedFormat,
      .frameLimitExceeded,
      .decodedBudgetExceeded:
      true
    default:
      false
    }
  }

  private static func isFallbackEligible(
    _ error: APNGCompressedCheckpointError
  ) -> Bool {
    switch error {
    case .invalidCanvas,
      .compressionFailed,
      .checkpointRatioExceeded,
      .retainedBudgetExceeded:
      true
    default:
      false
    }
  }

  private static func map(
    _ error: APNGRawSubrectDecodeError
  ) -> ImageCraftError {
    switch error {
    case .encodedBytesExceeded:
      .encodedBytesExceeded
    case .frameLimitExceeded:
      .frameLimitExceeded
    case .frameRectOutOfBounds:
      .animationFrameRectInvalid
    case .unsupportedFormat:
      .animationUnsupported
    default:
      .animationTimelineInvalid
    }
  }

  private static func map(
    _ error: APNGCompressedCheckpointError
  ) -> ImageCraftError {
    switch error {
    case .invalidFrameIndex:
      .animationFrameIndexOutOfRange
    case .replayLimitExceeded:
      .animationDecodeWindowExceeded
    case .decompressionFailed, .checksumMismatch:
      .decodeFailed
    case .invalidCanvas,
      .compressionFailed,
      .checkpointRatioExceeded,
      .retainedBudgetExceeded:
      .animationUnsupported
    default:
      .animationTimelineInvalid
    }
  }
}
