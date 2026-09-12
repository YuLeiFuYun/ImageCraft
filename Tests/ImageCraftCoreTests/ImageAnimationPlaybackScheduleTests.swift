import Foundation
@testable import ImageCraftCore
import XCTest

final class ImageAnimationPlaybackScheduleTests: XCTestCase {
  func testFiniteLoopBoundariesSelectHalfOpenFrames_IMG_ANIM_PT_074() throws {
    let metadata = try makeMetadata(
      durations: [(1, 10), (1, 5)],
      loopCount: ImageAnimationLoopCount(additionalRepeatCount: 1)
    )
    let schedule = try ImageAnimationPlaybackSchedule(metadata: metadata)
    XCTAssertEqual(schedule.cycleDurationNanoseconds, 300_000_000)
    XCTAssertEqual(schedule.maximumPlayCount, 2)

    XCTAssertEqual(
      schedule.position(atElapsedNanoseconds: 0),
      ImageAnimationPlaybackPosition(
        frameIndex: 0,
        playIndex: 0,
        frameStartNanoseconds: 0,
        nextFrameDeadlineNanoseconds: 100_000_000
      )
    )
    XCTAssertEqual(schedule.position(atElapsedNanoseconds: 99_999_999)?.frameIndex, 0)
    XCTAssertEqual(schedule.position(atElapsedNanoseconds: 100_000_000)?.frameIndex, 1)
    XCTAssertEqual(schedule.position(atElapsedNanoseconds: 299_999_999)?.frameIndex, 1)
    XCTAssertEqual(schedule.position(atElapsedNanoseconds: 300_000_000)?.frameIndex, 0)
    XCTAssertEqual(schedule.position(atElapsedNanoseconds: 300_000_000)?.playIndex, 1)
    XCTAssertEqual(schedule.position(atElapsedNanoseconds: 599_999_999)?.frameIndex, 1)
    XCTAssertNil(schedule.position(atElapsedNanoseconds: 600_000_000))
    XCTAssertNil(schedule.position(atElapsedNanoseconds: UInt64.max))
  }

  func testInfiniteScheduleSkipsZeroDurationFramesAndRepeats_IMG_ANIM_PT_075() throws {
    let metadata = try makeMetadata(
      durations: [(0, 1), (1, UInt32.max), (2, 1_000_000_000)],
      loopCount: .infinite
    )
    let schedule = try ImageAnimationPlaybackSchedule(metadata: metadata)
    XCTAssertNil(schedule.maximumPlayCount)
    XCTAssertEqual(schedule.cycleDurationNanoseconds, 3)
    XCTAssertEqual(schedule.position(atElapsedNanoseconds: 0)?.frameIndex, 1)
    XCTAssertEqual(schedule.position(atElapsedNanoseconds: 1)?.frameIndex, 2)
    XCTAssertEqual(schedule.position(atElapsedNanoseconds: 2)?.frameIndex, 2)
    XCTAssertEqual(schedule.position(atElapsedNanoseconds: 3)?.frameIndex, 1)
    XCTAssertEqual(schedule.position(atElapsedNanoseconds: 3)?.playIndex, 1)
  }

  func testAllZeroDurationTrackFailsClosed_IMG_ANIM_PT_076() throws {
    let metadata = try makeMetadata(
      durations: [(0, 1), (0, 7)],
      loopCount: .playOnce
    )
    XCTAssertThrowsError(try ImageAnimationPlaybackSchedule(metadata: metadata)) { error in
      XCTAssertEqual(error as? ImageCraftError, .animationTimelineInvalid)
    }
  }

  func testCycleDurationOverflowFailsClosed_IMG_ANIM_PT_077() throws {
    let durations = Array(repeating: (UInt32.max, UInt32(1)), count: 5)
    let metadata = try makeMetadata(durations: durations, loopCount: .infinite)
    XCTAssertThrowsError(try ImageAnimationPlaybackSchedule(metadata: metadata)) { error in
      XCTAssertEqual(error as? ImageCraftError, .animationTimelineInvalid)
    }
  }

  func testDeadlineBeyondUInt64ClockDomainRemainsExplicit_IMG_ANIM_PT_078() throws {
    let metadata = try makeMetadata(
      durations: [(1, 1_000_000_000), (2, 1_000_000_000)],
      loopCount: .infinite
    )
    let schedule = try ImageAnimationPlaybackSchedule(metadata: metadata)
    let position = try XCTUnwrap(
      schedule.position(atElapsedNanoseconds: UInt64.max)
    )
    XCTAssertEqual(position.frameIndex, 0)
    XCTAssertNil(position.nextFrameDeadlineNanoseconds)
    XCTAssertLessThanOrEqual(position.frameStartNanoseconds, UInt64.max)
  }

  private func makeMetadata(
    durations: [(UInt32, UInt32)],
    loopCount: ImageAnimationLoopCount
  ) throws -> ImageAnimationMetadata {
    let rect = try ImageAnimationFrameRect(x: 0, y: 0, width: 2, height: 2)
    let frames = try durations.enumerated().map { index, raw in
      try ImageAnimationFrameDescriptor(
        index: index,
        duration: ImageAnimationFrameDuration(numerator: raw.0, denominator: raw.1),
        rect: rect,
        disposal: .none,
        blend: .source
      )
    }
    return try ImageAnimationMetadata(
      container: .gif,
      canvasWidth: 2,
      canvasHeight: 2,
      loopCount: loopCount,
      frames: frames,
      encodedByteCount: 1,
      codecFingerprint: "playback-schedule-test#1"
    )
  }
}
