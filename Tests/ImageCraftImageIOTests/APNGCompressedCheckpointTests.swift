import Foundation
import XCTest

@testable import ImageCraftImageIO

final class APNGCompressedCheckpointTests: XCTestCase {
  func testTransparentAndStructuredCanvasesRoundTrip_IMG_ANIM_PT_027() throws {
    let transparent = Data(repeating: 0, count: 16 * 16 * 4)
    var structured = Data()
    structured.reserveCapacity(16 * 16 * 4)
    for index in 0..<(16 * 16) {
      structured.append(UInt8(index & 0xFF))
      structured.append(UInt8((index * 3) & 0xFF))
      structured.append(127)
      structured.append(255)
    }
    for source in [transparent, structured] {
      let blob = try APNGCompressedCheckpointCodec.encode(
        straightAlphaRGBA: source,
        width: 16,
        height: 16,
        policy: permissivePolicy(maximumDimension: 16)
      )
      XCTAssertEqual(blob.prefix(8), Data("FOVAPNG1".utf8))
      let decoded = try APNGCompressedCheckpointCodec.decode(
        blob,
        policy: permissivePolicy(maximumDimension: 16)
      )
      XCTAssertEqual(decoded.metadata.width, 16)
      XCTAssertEqual(decoded.metadata.height, 16)
      XCTAssertEqual(decoded.metadata.rawByteCount, source.count)
      XCTAssertEqual(decoded.straightAlphaRGBA, source)
    }
  }

  func testPythonRFC1950FixtureDecodes_IMG_ANIM_PT_033() throws {
    let fixture = try XCTUnwrap(
      Data(
        base64Encoded: "Rk9WQVBORzEAAAACAAAAAgAAABAcfZ5EAAAAFHja+8/A8B8IG4CUAwMQAAAzogS9"
      )
    )
    let expected = Data([
      255, 0, 0, 255,
      0, 255, 0, 128,
      0, 0, 255, 64,
      0, 0, 0, 0,
    ])
    let decoded = try APNGCompressedCheckpointCodec.decode(
      fixture,
      policy: permissivePolicy(maximumDimension: 2)
    )
    XCTAssertEqual(decoded.metadata.width, 2)
    XCTAssertEqual(decoded.metadata.height, 2)
    XCTAssertEqual(decoded.straightAlphaRGBA, expected)
  }

  func testBlobTamperingFailsClosed_IMG_ANIM_PT_028() throws {
    let policy = permissivePolicy(maximumDimension: 8)
    let source = Data(repeating: 0x5A, count: 8 * 8 * 4)
    let blob = try APNGCompressedCheckpointCodec.encode(
      straightAlphaRGBA: source,
      width: 8,
      height: 8,
      policy: policy
    )

    var badMagic = blob
    badMagic[0] ^= 1
    XCTAssertThrowsError(try APNGCompressedCheckpointCodec.decode(badMagic, policy: policy)) {
      XCTAssertEqual($0 as? APNGCompressedCheckpointError, .invalidBlobHeader)
    }

    var badPayloadCount = blob
    badPayloadCount[27] &+= 1
    XCTAssertThrowsError(
      try APNGCompressedCheckpointCodec.decode(badPayloadCount, policy: policy)
    ) { error in
      XCTAssertEqual(error as? APNGCompressedCheckpointError, .payloadByteCountMismatch)
    }

    var badChecksum = blob
    badChecksum[23] ^= 1
    XCTAssertThrowsError(try APNGCompressedCheckpointCodec.decode(badChecksum, policy: policy)) {
      XCTAssertEqual($0 as? APNGCompressedCheckpointError, .checksumMismatch)
    }

    var corruptPayload = blob
    let payloadOffset = APNGCompressedCheckpointCodec.headerByteCount
    corruptPayload[payloadOffset] ^= 0xFF
    XCTAssertThrowsError(
      try APNGCompressedCheckpointCodec.decode(corruptPayload, policy: policy)
    ) { error in
      XCTAssertTrue(
        error as? APNGCompressedCheckpointError == .decompressionFailed
          || error as? APNGCompressedCheckpointError == .checksumMismatch
      )
    }

    XCTAssertThrowsError(
      try APNGCompressedCheckpointCodec.decode(Data(blob.dropLast()), policy: policy)
    ) { error in
      XCTAssertEqual(error as? APNGCompressedCheckpointError, .payloadByteCountMismatch)
    }
  }

  func testCanvasAndRatioAdmissionFailClosed_IMG_ANIM_PT_029() throws {
    let source = Data(repeating: 0, count: 4 * 4 * 4)
    XCTAssertThrowsError(
      try APNGCompressedCheckpointCodec.encode(
        straightAlphaRGBA: source,
        width: 4,
        height: 4,
        policy: APNGCompressedCheckpointPolicy(
          maximumCanvasDimension: 3,
          maximumRetainedBytes: 1_024,
          maximumReplayFrames: 2,
          maximumCheckpointBlobRatioPPM: 1_000_000
        )
      )
    ) { error in
      XCTAssertEqual(error as? APNGCompressedCheckpointError, .invalidCanvas)
    }

    XCTAssertThrowsError(
      try APNGCompressedCheckpointCodec.encode(
        straightAlphaRGBA: Data(source.dropLast()),
        width: 4,
        height: 4,
        policy: permissivePolicy(maximumDimension: 4)
      )
    ) { error in
      XCTAssertEqual(error as? APNGCompressedCheckpointError, .rawByteCountMismatch)
    }

    let noisy = deterministicNoise(byteCount: 32 * 32 * 4)
    XCTAssertThrowsError(
      try APNGCompressedCheckpointCodec.encode(
        straightAlphaRGBA: noisy,
        width: 32,
        height: 32,
        policy: APNGCompressedCheckpointPolicy(
          maximumCanvasDimension: 32,
          maximumRetainedBytes: 1_024 * 1_024,
          maximumReplayFrames: 8,
          maximumCheckpointBlobRatioPPM: 10_000
        )
      )
    ) { error in
      XCTAssertEqual(error as? APNGCompressedCheckpointError, .checkpointRatioExceeded)
    }
  }

  func testStoreUsesImplicitFrameZeroAndNearestCheckpoint_IMG_ANIM_PT_030() throws {
    let policy = permissivePolicy(maximumDimension: 8, replay: 4)
    var store = try APNGCompressedCheckpointStore(
      frameCount: 12,
      width: 8,
      height: 8,
      policy: policy
    )
    XCTAssertEqual(store.retainedBytes, 0)
    XCTAssertEqual(store.retainedCheckpointCount, 0)

    let firstState = Data(repeating: 1, count: 8 * 8 * 4)
    let secondState = Data(repeating: 2, count: 8 * 8 * 4)
    try store.insert(preFrameStraightAlphaRGBA: firstState, at: 4)
    try store.insert(preFrameStraightAlphaRGBA: secondState, at: 8)
    XCTAssertGreaterThan(store.retainedBytes, 0)
    XCTAssertEqual(store.retainedCheckpointCount, 2)

    let frameZero = try store.resolve(targetFrameIndex: 0)
    XCTAssertEqual(frameZero.checkpointFrameIndex, 0)
    XCTAssertEqual(frameZero.replayFrameCount, 1)
    XCTAssertNil(try store.decode(frameZero))

    let frameTen = try store.resolve(targetFrameIndex: 10)
    XCTAssertEqual(frameTen.checkpointFrameIndex, 8)
    XCTAssertEqual(frameTen.replayFrameCount, 3)
    XCTAssertEqual(try store.decode(frameTen), secondState)
  }

  func testStoreRejectsReplayIndexOrderAndRetainedBudget_IMG_ANIM_PT_031() throws {
    let state = Data(repeating: 0, count: 8 * 8 * 4)
    var store = try APNGCompressedCheckpointStore(
      frameCount: 12,
      width: 8,
      height: 8,
      policy: permissivePolicy(maximumDimension: 8, replay: 4)
    )
    XCTAssertThrowsError(try store.resolve(targetFrameIndex: 4)) { error in
      XCTAssertEqual(error as? APNGCompressedCheckpointError, .replayLimitExceeded)
    }
    try store.insert(preFrameStraightAlphaRGBA: state, at: 4)
    XCTAssertThrowsError(try store.insert(preFrameStraightAlphaRGBA: state, at: 4)) {
      XCTAssertEqual($0 as? APNGCompressedCheckpointError, .frameIndicesNotIncreasing)
    }
    XCTAssertThrowsError(try store.insert(preFrameStraightAlphaRGBA: state, at: 12)) {
      XCTAssertEqual($0 as? APNGCompressedCheckpointError, .invalidFrameIndex)
    }

    let encodedState = try APNGCompressedCheckpointCodec.encode(
      straightAlphaRGBA: state,
      width: 8,
      height: 8,
      policy: permissivePolicy(maximumDimension: 8)
    )
    var budgetStore = try APNGCompressedCheckpointStore(
      frameCount: 4,
      width: 8,
      height: 8,
      policy: APNGCompressedCheckpointPolicy(
        maximumCanvasDimension: 8,
        maximumRetainedBytes: encodedState.count - 1,
        maximumReplayFrames: 4,
        maximumCheckpointBlobRatioPPM: 1_000_000
      )
    )
    XCTAssertThrowsError(
      try budgetStore.insert(preFrameStraightAlphaRGBA: state, at: 1)
    ) { error in
      XCTAssertEqual(error as? APNGCompressedCheckpointError, .retainedBudgetExceeded)
    }
  }

  func testStoreCanPreferSemanticReplayStartOverOlderCheckpoint_IMG_ANIM_PT_053() throws {
    let policy = permissivePolicy(maximumDimension: 8, replay: 4)
    var store = try APNGCompressedCheckpointStore(
      frameCount: 12,
      width: 8,
      height: 8,
      policy: policy
    )
    let state = Data(repeating: 7, count: 8 * 8 * 4)
    try store.insert(preFrameStraightAlphaRGBA: state, at: 4)

    let semantic = try store.resolve(
      targetFrameIndex: 10,
      semanticReplayStart: 9
    )
    XCTAssertEqual(semantic.checkpointFrameIndex, 9)
    XCTAssertEqual(semantic.replayFrameCount, 2)
    XCTAssertNil(semantic.compressedBlob)
    XCTAssertNil(try store.decode(semantic))

    XCTAssertThrowsError(
      try store.resolve(targetFrameIndex: 10, semanticReplayStart: 11)
    ) { error in
      XCTAssertEqual(error as? APNGCompressedCheckpointError, .invalidFrameIndex)
    }
  }

  func testDefaultPolicyIsExplicitlyBounded_IMG_ANIM_PT_032() throws {
    let policy = APNGCompressedCheckpointPolicy.bounded1024
    XCTAssertEqual(policy.maximumCanvasDimension, 1_024)
    XCTAssertEqual(policy.maximumRetainedBytes, 32 * 1_024 * 1_024)
    XCTAssertEqual(policy.maximumReplayFrames, 8)
    XCTAssertEqual(policy.maximumCheckpointBlobRatioPPM, 100_000)
    XCTAssertNoThrow(try policy.validate())
  }

  private func permissivePolicy(
    maximumDimension: Int,
    replay: Int = 8
  ) -> APNGCompressedCheckpointPolicy {
    APNGCompressedCheckpointPolicy(
      maximumCanvasDimension: maximumDimension,
      maximumRetainedBytes: 32 * 1_024 * 1_024,
      maximumReplayFrames: replay,
      maximumCheckpointBlobRatioPPM: 1_000_000
    )
  }

  private func deterministicNoise(byteCount: Int) -> Data {
    var state = UInt64(0x9E37_79B9_7F4A_7C15)
    return Data(
      (0..<byteCount).map { _ in
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return UInt8(truncatingIfNeeded: state)
      })
  }
}
