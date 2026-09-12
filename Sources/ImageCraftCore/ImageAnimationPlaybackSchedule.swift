import Foundation

/// Package-only nanosecond-domain playback position derived from validated animation metadata.
///
/// Frame durations use `ImageAnimationFrameDuration.roundedUpNanoseconds`; this is therefore a
/// host scheduling policy over an integer nanosecond clock, not a replacement for the exact
/// rational durations retained in `ImageAnimationMetadata`.
package struct ImageAnimationPlaybackPosition: Equatable, Sendable {
  package let frameIndex: Int
  package let playIndex: UInt64
  package let frameStartNanoseconds: UInt64
  /// `nil` only when the next boundary is beyond the representable `UInt64` clock domain.
  package let nextFrameDeadlineNanoseconds: UInt64?
}

/// Pure-value playback scheduler for one validated animation track.
///
/// The scheduler owns no timer, display link, decoded frame, cache, visibility state, or dropping
/// policy. It only maps an elapsed monotonic nanosecond value to the frame that should be presented.
/// Zero-nanosecond frames are skipped. Finite loop exhaustion returns `nil`; infinite tracks repeat
/// without multiplying the cycle duration by an unbounded play count.
package struct ImageAnimationPlaybackSchedule: Sendable {
  private struct Entry: Sendable {
    let frameIndex: Int
    let startNanoseconds: UInt64
    let endNanoseconds: UInt64
  }

  package let cycleDurationNanoseconds: UInt64
  package let maximumPlayCount: UInt64?
  private let entries: [Entry]

  package init(metadata: ImageAnimationMetadata) throws {
    var cumulative: UInt64 = 0
    var entries: [Entry] = []
    entries.reserveCapacity(metadata.frames.count)

    for frame in metadata.frames {
      let duration = frame.duration.roundedUpNanoseconds
      let end = cumulative.addingReportingOverflow(duration)
      guard !end.overflow else { throw ImageCraftError.animationTimelineInvalid }
      if duration > 0 {
        entries.append(
          Entry(
            frameIndex: frame.index,
            startNanoseconds: cumulative,
            endNanoseconds: end.partialValue
          )
        )
      }
      cumulative = end.partialValue
    }

    guard cumulative > 0, !entries.isEmpty else {
      throw ImageCraftError.animationTimelineInvalid
    }
    self.cycleDurationNanoseconds = cumulative
    self.maximumPlayCount = metadata.loopCount.additionalRepeatCount.map { UInt64($0) + 1 }
    self.entries = entries
  }

  /// Returns the active frame at `elapsedNanoseconds`, or `nil` after a finite track exhausts all
  /// plays. Intervals are half-open: an exact frame boundary selects the following nonzero frame.
  package func position(atElapsedNanoseconds elapsedNanoseconds: UInt64)
    -> ImageAnimationPlaybackPosition?
  {
    let playIndex = elapsedNanoseconds / cycleDurationNanoseconds
    if let maximumPlayCount, playIndex >= maximumPlayCount { return nil }

    let offset = elapsedNanoseconds % cycleDurationNanoseconds
    guard let entry = entries.first(where: { offset < $0.endNanoseconds }) else {
      return nil
    }
    let cycleStart = elapsedNanoseconds - offset
    let frameStart = cycleStart.addingReportingOverflow(entry.startNanoseconds)
    guard !frameStart.overflow else { return nil }
    let deadline = cycleStart.addingReportingOverflow(entry.endNanoseconds)
    return ImageAnimationPlaybackPosition(
      frameIndex: entry.frameIndex,
      playIndex: playIndex,
      frameStartNanoseconds: frameStart.partialValue,
      nextFrameDeadlineNanoseconds: deadline.overflow ? nil : deadline.partialValue
    )
  }
}
