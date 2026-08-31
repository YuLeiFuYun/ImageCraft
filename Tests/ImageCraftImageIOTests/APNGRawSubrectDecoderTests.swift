import Foundation
import XCTest

@testable import ImageCraftImageIO

final class APNGRawSubrectDecoderTests: XCTestCase {
  func testDecodesRawSubrectsFiltersAndControls_IMG_ANIM_PT_034() throws {
    let fixture = try makeStandardAPNG()
    let image = try APNGRawSubrectDecoder.decode(fixture)
    XCTAssertEqual(image.canvasWidth, 4)
    XCTAssertEqual(image.canvasHeight, 4)
    XCTAssertEqual(image.numPlays, 2)
    XCTAssertTrue(image.firstAnimationFrameUsesIDAT)
    XCTAssertEqual(image.frames.count, 3)

    XCTAssertEqual(image.frames[0].control.sequenceNumber, 0)
    XCTAssertEqual(image.frames[0].control.width, 4)
    XCTAssertEqual(image.frames[0].control.height, 4)
    XCTAssertEqual(image.frames[0].straightAlphaRGBA, standardFrameZero())

    XCTAssertEqual(image.frames[1].control.sequenceNumber, 1)
    XCTAssertEqual(image.frames[1].control.xOffset, 1)
    XCTAssertEqual(image.frames[1].control.yOffset, 1)
    XCTAssertEqual(image.frames[1].control.disposal, 2)
    XCTAssertEqual(image.frames[1].control.blend, 1)
    XCTAssertEqual(image.frames[1].straightAlphaRGBA, standardFrameOne())

    XCTAssertEqual(image.frames[2].control.sequenceNumber, 3)
    XCTAssertEqual(image.frames[2].control.disposal, 1)
    XCTAssertEqual(image.frames[2].control.blend, 0)
    XCTAssertEqual(image.frames[2].control.durationNanoseconds, 10_000_000)
    XCTAssertEqual(image.frames[2].straightAlphaRGBA, Data([0, 255, 0, 255]))
  }

  func testSeparateDefaultImageIsExcludedFromAnimation_IMG_ANIM_PT_035() throws {
    let image = try APNGRawSubrectDecoder.decode(makeSeparateDefaultAPNG())
    XCTAssertFalse(image.firstAnimationFrameUsesIDAT)
    XCTAssertEqual(image.frames.count, 2)
    XCTAssertEqual(image.frames[0].straightAlphaRGBA, Data(repeating: 0x22, count: 4 * 4 * 4))
    XCTAssertEqual(image.frames[1].straightAlphaRGBA, Data([9, 8, 7, 6]))
    XCTAssertEqual(image.frames.map(\.control.sequenceNumber), [0, 2])
  }

  func testCRCSequenceAndChunkStructureFailClosed_IMG_ANIM_PT_036() throws {
    var badCRC = try makeStandardAPNG()
    let control = try XCTUnwrap(badCRC.range(of: Data("fcTL".utf8)))
    badCRC[control.upperBound + 4] ^= 1
    XCTAssertThrowsError(try APNGRawSubrectDecoder.decode(badCRC)) { error in
      XCTAssertEqual(error as? APNGRawSubrectDecodeError, .crcMismatch)
    }

    let sequenceGap = try mutateChunk(
      makeStandardAPNG(),
      type: "fcTL",
      occurrence: 1
    ) { payload in
      payload.replaceSubrange(0..<4, with: be32(9))
    }
    XCTAssertThrowsError(try APNGRawSubrectDecoder.decode(sequenceGap)) { error in
      XCTAssertEqual(error as? APNGRawSubrectDecodeError, .sequenceMismatch)
    }

    let unknownCritical = try insertingChunk(
      into: makeStandardAPNG(),
      after: "IHDR",
      type: "ABCD",
      payload: Data()
    )
    XCTAssertThrowsError(try APNGRawSubrectDecoder.decode(unknownCritical)) { error in
      XCTAssertEqual(error as? APNGRawSubrectDecodeError, .unsupportedFormat)
    }

    var trailing = try makeStandardAPNG()
    trailing.append(0)
    XCTAssertThrowsError(try APNGRawSubrectDecoder.decode(trailing)) { error in
      XCTAssertEqual(error as? APNGRawSubrectDecodeError, .invalidChunkOrder)
    }
  }

  func testUnsupportedFormatAndFilterFailClosed_IMG_ANIM_PT_037() throws {
    XCTAssertThrowsError(try APNGRawSubrectDecoder.decode(makeStandardAPNG(interlace: 1))) {
      error in
      XCTAssertEqual(error as? APNGRawSubrectDecodeError, .unsupportedFormat)
    }
    XCTAssertThrowsError(try APNGRawSubrectDecoder.decode(makeStandardAPNG(colorType: 2))) {
      error in
      XCTAssertEqual(error as? APNGRawSubrectDecodeError, .unsupportedFormat)
    }
    XCTAssertThrowsError(try APNGRawSubrectDecoder.decode(makeInvalidFilterAPNG())) { error in
      XCTAssertEqual(error as? APNGRawSubrectDecodeError, .invalidFilter)
    }
  }

  func testRFC1950RoundTripAndAdlerValidation_IMG_ANIM_PT_067() throws {
    var payload = Data()
    payload.reserveCapacity(32_768)
    for index in 0..<32_768 {
      payload.append(UInt8(truncatingIfNeeded: index &* 31 &+ index / 7))
    }
    let compressed = try RFC1950Zlib.deflate(payload)
    XCTAssertEqual(
      try RFC1950Zlib.inflate(compressed, expectedByteCount: payload.count),
      payload
    )

    var corruptAdler = compressed
    corruptAdler[corruptAdler.count - 1] ^= 1
    XCTAssertThrowsError(
      try RFC1950Zlib.inflate(corruptAdler, expectedByteCount: payload.count)
    ) { error in
      XCTAssertEqual(error as? RFC1950ZlibError, .decompressionFailed)
    }

    XCTAssertEqual(
      try RFC1950Zlib.inflate(compressed, maximumByteCount: payload.count),
      payload
    )
    XCTAssertThrowsError(
      try RFC1950Zlib.inflate(compressed, maximumByteCount: payload.count - 1)
    ) { error in
      XCTAssertEqual(error as? RFC1950ZlibError, .outputLimitExceeded)
    }
    XCTAssertThrowsError(
      try RFC1950Zlib.inflate(corruptAdler, maximumByteCount: payload.count)
    ) { error in
      XCTAssertEqual(error as? RFC1950ZlibError, .decompressionFailed)
    }
  }

  func testAdmissionBudgetsFailClosed_IMG_ANIM_PT_038() throws {
    let fixture = try makeStandardAPNG()
    XCTAssertThrowsError(
      try APNGRawSubrectDecoder.decode(
        fixture,
        policy: policy(maximumDimension: 3)
      )
    ) { error in
      XCTAssertEqual(error as? APNGRawSubrectDecodeError, .unsupportedFormat)
    }
    XCTAssertThrowsError(
      try APNGRawSubrectDecoder.decode(
        fixture,
        policy: policy(maximumFrameCount: 2)
      )
    ) { error in
      XCTAssertEqual(error as? APNGRawSubrectDecodeError, .frameLimitExceeded)
    }
    XCTAssertThrowsError(
      try APNGRawSubrectDecoder.decode(
        fixture,
        policy: policy(maximumRawBytes: 64)
      )
    ) { error in
      XCTAssertEqual(error as? APNGRawSubrectDecodeError, .decodedBudgetExceeded)
    }
    XCTAssertThrowsError(
      try APNGRawSubrectDecoder.decode(
        fixture,
        policy: policy(maximumEncodedBytes: fixture.count - 1)
      )
    ) { error in
      XCTAssertEqual(error as? APNGRawSubrectDecodeError, .encodedBytesExceeded)
    }
  }

  func testOwnedPlaybackSupportsRandomAccessAndPreviousDisposal_IMG_ANIM_PT_039() throws {
    let fixture = try makeStandardAPNG()
    let playback = try APNGOwnedStraightAlphaPlayback(
      encodedData: fixture,
      policy: playbackPolicy(maximumReplayFrames: 2)
    )
    let expected = try expectedPremultipliedFrames(fixture)
    XCTAssertEqual(try playback.frame(at: 2), expected[2])
    XCTAssertEqual(try playback.frame(at: 0), expected[0])
    XCTAssertEqual(try playback.frame(at: 1), expected[1])
    XCTAssertEqual(playback.diagnostics.retainedCheckpointCount, 1)
    XCTAssertEqual(playback.diagnostics.maximumReplayFrames, 2)
  }

  func testOwnedPlaybackSupportsSeparateDefaultAnimation_IMG_ANIM_PT_040() throws {
    let fixture = try makeSeparateDefaultAPNG()
    let playback = try APNGOwnedStraightAlphaPlayback(
      encodedData: fixture,
      policy: playbackPolicy(maximumReplayFrames: 2)
    )
    let expected = try expectedPremultipliedFrames(fixture)
    XCTAssertFalse(playback.encodedImage.firstAnimationFrameUsesIDAT)
    XCTAssertEqual(playback.encodedImage.frames.count, 2)
    XCTAssertEqual(try playback.frame(at: 1), expected[1])
    XCTAssertEqual(try playback.frame(at: 0), expected[0])
  }

  func testOwnedPlaybackDiagnosticsAccountForRetainedAndPeakBytes_IMG_ANIM_PT_041() throws {
    let fixture = try makeStandardAPNG()
    let encoded = try APNGRawSubrectDecoder.parseEncoded(fixture)
    let encodedPayloadBytes = encoded.frames.reduce(0) {
      $0 + $1.compressedPayload.count
    }
    let playback = try APNGOwnedStraightAlphaPlayback(
      encodedData: fixture,
      policy: playbackPolicy(maximumReplayFrames: 2, workspaceBytes: 32)
    )
    let diagnostics = playback.diagnostics
    XCTAssertEqual(diagnostics.encodedFramePayloadBytes, encodedPayloadBytes)
    XCTAssertGreaterThan(diagnostics.retainedCheckpointBytes, 0)
    XCTAssertEqual(
      diagnostics.retainedBytes,
      diagnostics.encodedFramePayloadBytes + diagnostics.retainedCheckpointBytes
    )
    XCTAssertEqual(diagnostics.canvasRGBABytes, 4 * 4 * 4)
    XCTAssertEqual(diagnostics.maximumRawSubrectRGBABytes, 4 * 4 * 4)
    XCTAssertEqual(diagnostics.maximumPreviousSaveRGBABytes, 2 * 2 * 4)
    XCTAssertEqual(diagnostics.materializedOutputRGBABytes, 4 * 4 * 4)
    XCTAssertEqual(diagnostics.decompressorWorkspaceBytes, 32)
    XCTAssertEqual(
      diagnostics.modeledPeakBytesUpperBound,
      diagnostics.retainedBytes + 64 + 64 + 16 + 32 + 64
    )
  }

  func testOwnedPlaybackRetainedBudgetFailsClosed_IMG_ANIM_PT_042() throws {
    let fixture = try makeStandardAPNG()
    let encoded = try APNGRawSubrectDecoder.parseEncoded(fixture)
    let encodedPayloadBytes = encoded.frames.reduce(0) {
      $0 + $1.compressedPayload.count
    }
    XCTAssertGreaterThan(encodedPayloadBytes, 0)
    XCTAssertThrowsError(
      try APNGOwnedStraightAlphaPlayback(
        encodedData: fixture,
        policy: playbackPolicy(
          maximumReplayFrames: 2,
          maximumRetainedBytes: encodedPayloadBytes - 1
        )
      )
    ) { error in
      XCTAssertEqual(
        error as? APNGCompressedCheckpointError,
        .retainedBudgetExceeded
      )
    }
  }

  func testOwnedPlaybackRangeSharesSequentialCanvas_IMG_ANIM_PT_051() throws {
    let fixture = try makeTenFrameCheckpointAPNG()
    let playback = try APNGOwnedStraightAlphaPlayback(
      encodedData: fixture,
      policy: playbackPolicy(maximumReplayFrames: 8)
    )
    let expected = try expectedPremultipliedFrames(fixture)
    XCTAssertEqual(try playback.frames(in: 0..<8), Array(expected[0..<8]))
    XCTAssertEqual(try playback.frames(in: 7..<10), Array(expected[7..<10]))
    XCTAssertThrowsError(try playback.frames(in: 4..<4)) { error in
      XCTAssertEqual(error as? APNGCompressedCheckpointError, .invalidFrameIndex)
    }
  }

  func testOwnedPlaybackRejectsOutOfRangeFrame_IMG_ANIM_PT_043() throws {
    let playback = try APNGOwnedStraightAlphaPlayback(
      encodedData: makeStandardAPNG(),
      policy: playbackPolicy(maximumReplayFrames: 2)
    )
    XCTAssertThrowsError(try playback.frame(at: -1)) { error in
      XCTAssertEqual(
        error as? APNGCompressedCheckpointError,
        .invalidFrameIndex
      )
    }
    XCTAssertThrowsError(try playback.frame(at: 3)) { error in
      XCTAssertEqual(
        error as? APNGCompressedCheckpointError,
        .invalidFrameIndex
      )
    }
  }

  func testOwnedPlaybackUsesFrameEightCheckpoint_IMG_ANIM_PT_044() throws {
    let fixture = try makeTenFrameCheckpointAPNG()
    let playback = try APNGOwnedStraightAlphaPlayback(
      encodedData: fixture,
      policy: playbackPolicy(maximumReplayFrames: 8)
    )
    let expected = try expectedPremultipliedFrames(fixture)
    XCTAssertEqual(playback.diagnostics.retainedCheckpointCount, 1)
    XCTAssertGreaterThan(playback.diagnostics.retainedCheckpointBytes, 0)
    XCTAssertEqual(try playback.frame(at: 9), expected[9])
    XCTAssertEqual(try playback.frame(at: 7), expected[7])
    XCTAssertEqual(try playback.frame(at: 0), expected[0])
  }

  func testOwnedPlaybackFullBackgroundSemanticResetEliminatesCheckpoints_IMG_ANIM_PT_054() throws {
    let fixture = try makeFullBackgroundCheckpointAPNG(frameCount: 10)
    let playback = try APNGOwnedStraightAlphaPlayback(
      encodedData: fixture,
      policy: playbackPolicy(maximumReplayFrames: 2)
    )
    let expected = try expectedPremultipliedFrames(fixture)
    XCTAssertEqual(playback.diagnostics.retainedCheckpointCount, 0)
    XCTAssertEqual(playback.diagnostics.retainedCheckpointBytes, 0)
    XCTAssertEqual(playback.diagnostics.semanticReplayResetCount, 9)
    XCTAssertEqual(playback.diagnostics.maximumResolvedReplayFrames, 1)
    XCTAssertEqual(try playback.frame(at: 9), expected[9])
    XCTAssertEqual(try playback.frame(at: 5), expected[5])
    XCTAssertEqual(try playback.frame(at: 0), expected[0])
    XCTAssertEqual(try playback.frames(in: 7..<10), Array(expected[7..<10]))
  }

  func testOwnedPlaybackFullSourcePreviousRemainsCheckpointBounded_IMG_ANIM_PT_055() throws {
    let fixture = try makeFullSourcePreviousControlAPNG()
    let playback = try APNGOwnedStraightAlphaPlayback(
      encodedData: fixture,
      policy: playbackPolicy(maximumReplayFrames: 2)
    )
    let expected = try expectedPremultipliedFrames(fixture)
    XCTAssertEqual(playback.diagnostics.retainedCheckpointCount, 1)
    XCTAssertGreaterThan(playback.diagnostics.retainedCheckpointBytes, 0)
    XCTAssertEqual(playback.diagnostics.semanticReplayResetCount, 0)
    XCTAssertEqual(playback.diagnostics.maximumResolvedReplayFrames, 2)
    XCTAssertEqual(try playback.frames(in: 2..<4), Array(expected[2..<4]))
    XCTAssertEqual(try playback.frame(at: 3), expected[3])
  }

  private func playbackPolicy(
    maximumReplayFrames: Int,
    maximumRetainedBytes: Int = 1 * 1_024 * 1_024,
    workspaceBytes: Int = 0
  ) -> APNGOwnedPlaybackPolicy {
    APNGOwnedPlaybackPolicy(
      decodePolicy: policy(),
      checkpointPolicy: APNGCompressedCheckpointPolicy(
        maximumCanvasDimension: 16,
        maximumRetainedBytes: maximumRetainedBytes,
        maximumReplayFrames: maximumReplayFrames,
        maximumCheckpointBlobRatioPPM: 1_000_000
      ),
      decompressorWorkspaceBytes: workspaceBytes
    )
  }

  private func policy(
    maximumEncodedBytes: Int = 64 * 1_024 * 1_024,
    maximumDimension: Int = 1_024,
    maximumFrameCount: Int = 512,
    maximumRawBytes: Int = 512 * 1_024 * 1_024
  ) -> APNGRawSubrectDecodePolicy {
    APNGRawSubrectDecodePolicy(
      maximumEncodedBytes: maximumEncodedBytes,
      maximumCanvasDimension: maximumDimension,
      maximumFrameCount: maximumFrameCount,
      maximumTotalRawRGBABytes: maximumRawBytes,
      maximumAncillaryBytes: min(1_024 * 1_024, maximumEncodedBytes)
    )
  }
}

private func makeFullBackgroundCheckpointAPNG(frameCount: Int) throws -> Data {
  precondition(frameCount > 1)
  let width = 4
  let height = 4
  var result = pngSignature()
  result.append(
    pngChunk(
      type: "IHDR",
      payload: be32(UInt32(width)) + be32(UInt32(height)) + Data([8, 6, 0, 0, 0])
    )
  )
  result.append(pngChunk(type: "acTL", payload: be32(UInt32(frameCount)) + be32(0)))
  var sequence = UInt32(0)
  for frameIndex in 0..<frameCount {
    result.append(
      pngChunk(
        type: "fcTL",
        payload: frameControl(
          sequence: sequence,
          width: UInt32(width),
          height: UInt32(height),
          x: 0,
          y: 0,
          delayNumerator: 1,
          delayDenominator: 10,
          disposal: 1,
          blend: 1
        )
      )
    )
    sequence += 1
    let rgba = Data(
      repeating: UInt8((frameIndex * 19 + 17) & 0xFF),
      count: width * height * 4
    )
    let compressed = try RFC1950Zlib.deflate(
      filteredRGBA(rgba, width: width, height: height, filters: [0, 0, 0, 0])
    )
    if frameIndex == 0 {
      result.append(pngChunk(type: "IDAT", payload: compressed))
    } else {
      result.append(
        pngChunk(type: "fdAT", payload: be32(sequence) + compressed)
      )
      sequence += 1
    }
  }
  result.append(pngChunk(type: "IEND", payload: Data()))
  return result
}

private func makeFullSourcePreviousControlAPNG() throws -> Data {
  let width = 4
  let height = 4
  var result = pngSignature()
  result.append(
    pngChunk(
      type: "IHDR",
      payload: be32(UInt32(width)) + be32(UInt32(height)) + Data([8, 6, 0, 0, 0])
    )
  )
  result.append(pngChunk(type: "acTL", payload: be32(4) + be32(0)))
  var sequence = UInt32(0)
  let controls:
    [(
      width: UInt32, height: UInt32, x: UInt32, y: UInt32, disposal: UInt8, blend: UInt8, rgba: Data
    )] = [
      (4, 4, 0, 0, 0, 0, Data(repeating: 0x22, count: 4 * 4 * 4)),
      (1, 1, 0, 0, 0, 0, Data([0x80, 0x10, 0x10, 0xFF])),
      (4, 4, 0, 0, 2, 0, Data(repeating: 0x66, count: 4 * 4 * 4)),
      (1, 1, 1, 0, 0, 0, Data([0x10, 0x80, 0x10, 0xFF])),
    ]
  for (index, control) in controls.enumerated() {
    result.append(
      pngChunk(
        type: "fcTL",
        payload: frameControl(
          sequence: sequence,
          width: control.width,
          height: control.height,
          x: control.x,
          y: control.y,
          delayNumerator: 1,
          delayDenominator: 10,
          disposal: control.disposal,
          blend: control.blend
        )
      )
    )
    sequence += 1
    let compressed = try RFC1950Zlib.deflate(
      filteredRGBA(
        control.rgba,
        width: Int(control.width),
        height: Int(control.height),
        filters: Array(repeating: 0, count: Int(control.height))
      )
    )
    if index == 0 {
      result.append(pngChunk(type: "IDAT", payload: compressed))
    } else {
      result.append(pngChunk(type: "fdAT", payload: be32(sequence) + compressed))
      sequence += 1
    }
  }
  result.append(pngChunk(type: "IEND", payload: Data()))
  return result
}

private func makeTenFrameCheckpointAPNG() throws -> Data {
  let width = 4
  let height = 4
  var result = pngSignature()
  result.append(
    pngChunk(
      type: "IHDR",
      payload: be32(UInt32(width)) + be32(UInt32(height)) + Data([8, 6, 0, 0, 0])
    )
  )
  result.append(pngChunk(type: "acTL", payload: be32(10) + be32(0)))
  let initial = Data(repeating: 0, count: width * height * 4)
  result.append(
    pngChunk(
      type: "fcTL",
      payload: frameControl(
        sequence: 0,
        width: UInt32(width),
        height: UInt32(height),
        x: 0,
        y: 0,
        delayNumerator: 1,
        delayDenominator: 10,
        disposal: 0,
        blend: 0
      )
    )
  )
  result.append(
    pngChunk(
      type: "IDAT",
      payload: try RFC1950Zlib.deflate(
        filteredRGBA(initial, width: width, height: height, filters: [0, 0, 0, 0])
      )
    )
  )
  var sequence = UInt32(1)
  for frameIndex in 1..<10 {
    let pixelIndex = frameIndex - 1
    let x = UInt32(pixelIndex % width)
    let y = UInt32(pixelIndex / width)
    result.append(
      pngChunk(
        type: "fcTL",
        payload: frameControl(
          sequence: sequence,
          width: 1,
          height: 1,
          x: x,
          y: y,
          delayNumerator: 1,
          delayDenominator: 10,
          disposal: 0,
          blend: 0
        )
      )
    )
    sequence += 1
    let pixel = Data([
      UInt8(frameIndex), UInt8(255 - frameIndex), UInt8(frameIndex * 7), 255,
    ])
    let compressed = try RFC1950Zlib.deflate(
      filteredRGBA(pixel, width: 1, height: 1, filters: [0])
    )
    result.append(
      pngChunk(
        type: "fdAT",
        payload: be32(sequence) + compressed
      )
    )
    sequence += 1
  }
  result.append(pngChunk(type: "IEND", payload: Data()))
  return result
}

private func makeStandardAPNG(
  interlace: UInt8 = 0,
  colorType: UInt8 = 6
) throws -> Data {
  var result = pngSignature()
  result.append(
    pngChunk(
      type: "IHDR",
      payload: be32(4) + be32(4) + Data([8, colorType, 0, 0, interlace])
    )
  )
  result.append(pngChunk(type: "acTL", payload: be32(3) + be32(2)))
  result.append(
    pngChunk(
      type: "fcTL",
      payload: frameControl(
        sequence: 0,
        width: 4,
        height: 4,
        x: 0,
        y: 0,
        delayNumerator: 1,
        delayDenominator: 10,
        disposal: 0,
        blend: 0
      )
    )
  )
  result.append(
    pngChunk(
      type: "IDAT",
      payload: try RFC1950Zlib.deflate(
        filteredRGBA(
          standardFrameZero(),
          width: 4,
          height: 4,
          filters: [0, 1, 2, 3]
        )
      )
    )
  )
  result.append(
    pngChunk(
      type: "fcTL",
      payload: frameControl(
        sequence: 1,
        width: 2,
        height: 2,
        x: 1,
        y: 1,
        delayNumerator: 1,
        delayDenominator: 5,
        disposal: 2,
        blend: 1
      )
    )
  )
  result.append(
    pngChunk(
      type: "fdAT",
      payload: be32(2)
        + (try RFC1950Zlib.deflate(
          filteredRGBA(
            standardFrameOne(),
            width: 2,
            height: 2,
            filters: [4, 1]
          )
        ))
    )
  )
  result.append(
    pngChunk(
      type: "fcTL",
      payload: frameControl(
        sequence: 3,
        width: 1,
        height: 1,
        x: 0,
        y: 3,
        delayNumerator: 1,
        delayDenominator: 0,
        disposal: 1,
        blend: 0
      )
    )
  )
  result.append(
    pngChunk(
      type: "fdAT",
      payload: be32(4)
        + (try RFC1950Zlib.deflate(
          filteredRGBA(
            Data([0, 255, 0, 255]),
            width: 1,
            height: 1,
            filters: [0]
          )
        ))
    )
  )
  result.append(pngChunk(type: "IEND", payload: Data()))
  return result
}

private func makeSeparateDefaultAPNG() throws -> Data {
  var result = pngSignature()
  result.append(
    pngChunk(
      type: "IHDR",
      payload: be32(4) + be32(4) + Data([8, 6, 0, 0, 0])
    )
  )
  result.append(pngChunk(type: "acTL", payload: be32(2) + be32(0)))
  result.append(
    pngChunk(
      type: "IDAT",
      payload: try RFC1950Zlib.deflate(
        filteredRGBA(
          Data(repeating: 0x11, count: 4 * 4 * 4),
          width: 4,
          height: 4,
          filters: [0, 0, 0, 0]
        )
      )
    )
  )
  result.append(
    pngChunk(
      type: "fcTL",
      payload: frameControl(
        sequence: 0,
        width: 4,
        height: 4,
        x: 0,
        y: 0,
        delayNumerator: 1,
        delayDenominator: 10,
        disposal: 0,
        blend: 0
      )
    )
  )
  result.append(
    pngChunk(
      type: "fdAT",
      payload: be32(1)
        + (try RFC1950Zlib.deflate(
          filteredRGBA(
            Data(repeating: 0x22, count: 4 * 4 * 4),
            width: 4,
            height: 4,
            filters: [1, 2, 3, 4]
          )
        ))
    )
  )
  result.append(
    pngChunk(
      type: "fcTL",
      payload: frameControl(
        sequence: 2,
        width: 1,
        height: 1,
        x: 2,
        y: 2,
        delayNumerator: 1,
        delayDenominator: 10,
        disposal: 0,
        blend: 1
      )
    )
  )
  result.append(
    pngChunk(
      type: "fdAT",
      payload: be32(3)
        + (try RFC1950Zlib.deflate(
          filteredRGBA(
            Data([9, 8, 7, 6]),
            width: 1,
            height: 1,
            filters: [0]
          )
        ))
    )
  )
  result.append(pngChunk(type: "IEND", payload: Data()))
  return result
}

private func makeInvalidFilterAPNG() throws -> Data {
  var result = pngSignature()
  result.append(
    pngChunk(
      type: "IHDR",
      payload: be32(1) + be32(1) + Data([8, 6, 0, 0, 0])
    )
  )
  result.append(pngChunk(type: "acTL", payload: be32(1) + be32(0)))
  result.append(
    pngChunk(
      type: "fcTL",
      payload: frameControl(
        sequence: 0,
        width: 1,
        height: 1,
        x: 0,
        y: 0,
        delayNumerator: 1,
        delayDenominator: 10,
        disposal: 0,
        blend: 0
      )
    )
  )
  result.append(
    pngChunk(
      type: "IDAT",
      payload: try RFC1950Zlib.deflate(Data([5, 1, 2, 3, 4]))
    )
  )
  result.append(pngChunk(type: "IEND", payload: Data()))
  return result
}

private func standardFrameZero() -> Data {
  var result = Data()
  for index in 0..<(4 * 4) {
    result.append(UInt8(index * 7))
    result.append(UInt8(255 - index * 5))
    result.append(UInt8(index * 11))
    result.append(index.isMultiple(of: 3) ? 96 : 255)
  }
  return result
}

private func standardFrameOne() -> Data {
  Data([
    10, 20, 30, 128,
    40, 50, 60, 255,
    70, 80, 90, 64,
    100, 110, 120, 192,
  ])
}

private func filteredRGBA(
  _ pixels: Data,
  width: Int,
  height: Int,
  filters: [UInt8]
) -> Data {
  let rowBytes = width * 4
  precondition(pixels.count == rowBytes * height)
  precondition(filters.count == height)
  var output = Data()
  output.reserveCapacity(height * (rowBytes + 1))
  for row in 0..<height {
    let filter = filters[row]
    output.append(filter)
    let rowStart = row * rowBytes
    let previousStart = (row - 1) * rowBytes
    for column in 0..<rowBytes {
      let value = pixels[rowStart + column]
      let left = column >= 4 ? pixels[rowStart + column - 4] : 0
      let above = row > 0 ? pixels[previousStart + column] : 0
      let upperLeft = row > 0 && column >= 4 ? pixels[previousStart + column - 4] : 0
      let prediction: UInt8
      switch filter {
      case 0: prediction = 0
      case 1: prediction = left
      case 2: prediction = above
      case 3: prediction = UInt8((UInt16(left) + UInt16(above)) / 2)
      case 4: prediction = testPaeth(left: left, above: above, upperLeft: upperLeft)
      default: prediction = 0
      }
      output.append(value &- prediction)
    }
  }
  return output
}

private func testPaeth(left: UInt8, above: UInt8, upperLeft: UInt8) -> UInt8 {
  let prediction = Int(left) + Int(above) - Int(upperLeft)
  let leftDistance = abs(prediction - Int(left))
  let aboveDistance = abs(prediction - Int(above))
  let upperLeftDistance = abs(prediction - Int(upperLeft))
  if leftDistance <= aboveDistance, leftDistance <= upperLeftDistance { return left }
  return aboveDistance <= upperLeftDistance ? above : upperLeft
}

private func frameControl(
  sequence: UInt32,
  width: UInt32,
  height: UInt32,
  x: UInt32,
  y: UInt32,
  delayNumerator: UInt16,
  delayDenominator: UInt16,
  disposal: UInt8,
  blend: UInt8
) -> Data {
  be32(sequence) + be32(width) + be32(height) + be32(x) + be32(y)
    + be16(delayNumerator) + be16(delayDenominator) + Data([disposal, blend])
}

private func pngSignature() -> Data {
  Data([137, 80, 78, 71, 13, 10, 26, 10])
}

private func pngChunk(type: String, payload: Data) -> Data {
  let kind = Data(type.utf8)
  var crcInput = kind
  crcInput.append(payload)
  return be32(UInt32(payload.count)) + kind + payload
    + be32(ImageCraftCRC32.checksum(crcInput))
}

private func be16(_ value: UInt16) -> Data {
  Data([UInt8(value >> 8), UInt8(value & 0xFF)])
}

private func be32(_ value: UInt32) -> Data {
  Data([
    UInt8((value >> 24) & 0xFF),
    UInt8((value >> 16) & 0xFF),
    UInt8((value >> 8) & 0xFF),
    UInt8(value & 0xFF),
  ])
}

private func pngChunks(_ data: Data) throws -> [(type: String, payload: Data)] {
  var result: [(String, Data)] = []
  var offset = 8
  while offset < data.count {
    guard offset + 12 <= data.count else { throw APNGRawSubrectDecodeError.truncatedChunk }
    let length = Int(
      UInt32(data[offset]) << 24
        | UInt32(data[offset + 1]) << 16
        | UInt32(data[offset + 2]) << 8
        | UInt32(data[offset + 3])
    )
    let type = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
    let payload = Data(data[(offset + 8)..<(offset + 8 + length)])
    result.append((type, payload))
    offset += 12 + length
  }
  return result
}

private func mutateChunk(
  _ data: Data,
  type: String,
  occurrence: Int,
  mutation: (inout Data) -> Void
) throws -> Data {
  let chunks = try pngChunks(data)
  var result = pngSignature()
  var seen = 0
  for chunk in chunks {
    var payload = chunk.payload
    if chunk.type == type {
      if seen == occurrence { mutation(&payload) }
      seen += 1
    }
    result.append(pngChunk(type: chunk.type, payload: payload))
  }
  return result
}

private func insertingChunk(
  into data: Data,
  after precedingType: String,
  type: String,
  payload: Data
) throws -> Data {
  let chunks = try pngChunks(data)
  var result = pngSignature()
  var inserted = false
  for chunk in chunks {
    result.append(pngChunk(type: chunk.type, payload: chunk.payload))
    if chunk.type == precedingType, !inserted {
      result.append(pngChunk(type: type, payload: payload))
      inserted = true
    }
  }
  return result
}

private func expectedPremultipliedFrames(_ encodedData: Data) throws -> [Data] {
  let image = try APNGRawSubrectDecoder.decode(encodedData)
  var canvas = Data(
    repeating: 0,
    count: image.canvasWidth * image.canvasHeight * 4
  )
  var outputs: [Data] = []
  for frame in image.frames {
    let control = frame.control
    let previous =
      control.disposal == 2
      ? expectedExtractRegion(
        canvas,
        canvasWidth: image.canvasWidth,
        control: control
      )
      : nil
    var sourceOffset = 0
    for row in 0..<control.height {
      for column in 0..<control.width {
        let destinationOffset =
          ((control.yOffset + row) * image.canvasWidth
            + control.xOffset + column) * 4
        let source = (
          frame.straightAlphaRGBA[sourceOffset],
          frame.straightAlphaRGBA[sourceOffset + 1],
          frame.straightAlphaRGBA[sourceOffset + 2],
          frame.straightAlphaRGBA[sourceOffset + 3]
        )
        sourceOffset += 4
        let result: (UInt8, UInt8, UInt8, UInt8)
        if control.blend == 0 {
          result = source
        } else {
          result = expectedStraightOver(
            source: source,
            destination: (
              canvas[destinationOffset],
              canvas[destinationOffset + 1],
              canvas[destinationOffset + 2],
              canvas[destinationOffset + 3]
            )
          )
        }
        canvas[destinationOffset] = result.0
        canvas[destinationOffset + 1] = result.1
        canvas[destinationOffset + 2] = result.2
        canvas[destinationOffset + 3] = result.3
      }
    }
    outputs.append(expectedPremultiply(canvas))
    if control.disposal == 1 {
      expectedClearRegion(
        &canvas,
        canvasWidth: image.canvasWidth,
        control: control
      )
    } else if control.disposal == 2 {
      expectedRestoreRegion(
        &canvas,
        canvasWidth: image.canvasWidth,
        control: control,
        bytes: try XCTUnwrap(previous)
      )
    }
  }
  return outputs
}

private func expectedStraightOver(
  source: (UInt8, UInt8, UInt8, UInt8),
  destination: (UInt8, UInt8, UInt8, UInt8)
) -> (UInt8, UInt8, UInt8, UInt8) {
  let sourceAlpha = Int(source.3)
  let destinationAlpha = Int(destination.3)
  let inverseAlpha = 255 - sourceAlpha
  let alphaNumerator = sourceAlpha * 255 + destinationAlpha * inverseAlpha
  guard alphaNumerator > 0 else { return (0, 0, 0, 0) }
  func channel(_ sourceChannel: UInt8, _ destinationChannel: UInt8) -> UInt8 {
    let numerator =
      Int(sourceChannel) * sourceAlpha * 255
      + Int(destinationChannel) * destinationAlpha * inverseAlpha
    return UInt8(numerator / alphaNumerator)
  }
  return (
    channel(source.0, destination.0),
    channel(source.1, destination.1),
    channel(source.2, destination.2),
    UInt8(alphaNumerator / 255)
  )
}

private func expectedPremultiply(_ canvas: Data) -> Data {
  var output = Data(count: canvas.count)
  for offset in stride(from: 0, to: canvas.count, by: 4) {
    let alpha = Int(canvas[offset + 3])
    output[offset] = UInt8((Int(canvas[offset]) * alpha + 127) / 255)
    output[offset + 1] = UInt8((Int(canvas[offset + 1]) * alpha + 127) / 255)
    output[offset + 2] = UInt8((Int(canvas[offset + 2]) * alpha + 127) / 255)
    output[offset + 3] = canvas[offset + 3]
  }
  return output
}

private func expectedExtractRegion(
  _ canvas: Data,
  canvasWidth: Int,
  control: APNGRawSubrectFrameControl
) -> Data {
  var result = Data()
  for row in 0..<control.height {
    let start = ((control.yOffset + row) * canvasWidth + control.xOffset) * 4
    result.append(canvas[start..<(start + control.width * 4)])
  }
  return result
}

private func expectedClearRegion(
  _ canvas: inout Data,
  canvasWidth: Int,
  control: APNGRawSubrectFrameControl
) {
  for row in 0..<control.height {
    let start = ((control.yOffset + row) * canvasWidth + control.xOffset) * 4
    canvas.replaceSubrange(
      start..<(start + control.width * 4),
      with: repeatElement(UInt8(0), count: control.width * 4)
    )
  }
}

private func expectedRestoreRegion(
  _ canvas: inout Data,
  canvasWidth: Int,
  control: APNGRawSubrectFrameControl,
  bytes: Data
) {
  var sourceOffset = 0
  for row in 0..<control.height {
    let start = ((control.yOffset + row) * canvasWidth + control.xOffset) * 4
    let count = control.width * 4
    canvas.replaceSubrange(
      start..<(start + count),
      with: bytes[sourceOffset..<(sourceOffset + count)]
    )
    sourceOffset += count
  }
}
