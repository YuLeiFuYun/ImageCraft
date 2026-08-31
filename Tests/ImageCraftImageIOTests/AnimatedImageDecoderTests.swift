import CoreGraphics
import CryptoKit
import Foundation
import ImageCraftCore
import ImageCraftImageIO
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class AnimatedImageDecoderTests: XCTestCase {
  func testGIFTimelineLoopAndFramesAreDecodedOnDemand_IMG_ANIM_PT_001() async throws {
    let data = try makeAnimatedGIF()
    let decoder = ImageIOAnimatedImageDecoder()
    let asset = try await decoder.prepareAnimation(source: .encoded(data))

    XCTAssertEqual(asset.metadata.container, .gif)
    XCTAssertEqual(asset.metadata.frameCount, 2)
    XCTAssertEqual(asset.metadata.loopCount.additionalRepeatCount, 2)
    XCTAssertEqual(asset.metadata.frames[0].duration, try duration(1, 10))
    XCTAssertEqual(asset.metadata.frames[1].duration, try duration(1, 5))
    XCTAssertTrue(
      decoder.codecDescriptor.supports(
        ImageDecodeCapabilityRequest(
          format: .gif,
          trackMode: .animatedSequence,
          requiredMetadata: [.frameTiming]
        )
      )
    )

    let request = try decodeRequest(width: 4, height: 4)
    let first = try await asset.frame(at: 0, request: request)
    let second = try await asset.frame(at: 1, request: request)
    XCTAssertGreaterThan(try redComponent(first.image.cgImage, x: 1, y: 1), 200)
    XCTAssertGreaterThan(try blueComponent(second.image.cgImage, x: 1, y: 1), 200)
  }

  func testOwnedGIFFullCanvasMatchesImageIOAndPublishesCostBounds_IMG_ANIM_PT_057()
    async throws
  {
    let data = try makeAnimatedGIF()
    let decoder = ImageIOAnimatedImageDecoder()
    let prepared = try await decoder.prepareAnimationWithDiagnostics(source: .encoded(data))
    XCTAssertEqual(prepared.diagnostics.backingKind, .ownedGIF)
    XCTAssertGreaterThan(prepared.diagnostics.ownedEncodedFramePayloadBytes ?? 0, 0)
    XCTAssertGreaterThan(prepared.diagnostics.ownedRetainedBytes ?? 0, 0)
    XCTAssertGreaterThan(prepared.diagnostics.ownedModeledPeakBytesUpperBound ?? 0, 0)
    XCTAssertEqual(
      prepared.diagnostics.resourceLedger.bytesUpperBound(for: .retainedBetweenCalls),
      prepared.diagnostics.ownedRetainedBytes
    )
    XCTAssertEqual(
      prepared.diagnostics.resourceLedger.bound(for: .operationPeak),
      .unknown(.frameworkPrivateOperationAllocation)
    )
    XCTAssertEqual(
      prepared.diagnostics.resourceLedger.bound(for: .transferredOutput),
      .unknown(.frameworkChosenOutputLayout)
    )

    let request = try decodeRequest(width: 4, height: 4)
    let frames = try await prepared.asset.frames(in: 0..<2, request: request)
    let windowOneAsset = try await decoder.prepareAnimation(
      source: .encoded(data),
      limits: ImageAnimationDecodeLimits(maximumFrameDecodeWindow: 1)
    )
    let singleFrames = [
      try await windowOneAsset.frame(at: 0, request: request),
      try await windowOneAsset.frame(at: 1, request: request),
    ]
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    XCTAssertEqual(CGImageSourceGetCount(source), 2)
    for index in 0..<2 {
      let oracle = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
      let oracleDigest = try normalizedPixelDigest(oracle)
      XCTAssertEqual(try normalizedPixelDigest(frames[index].image.cgImage), oracleDigest)
      XCTAssertEqual(try normalizedPixelDigest(singleFrames[index].image.cgImage), oracleDigest)
    }
    let estimate = try XCTUnwrap(prepared.asset.wholeTrackCostEstimate(for: request))
    let actualResident = frames.reduce(0) { $0 + $1.image.estimatedByteCost }
    XCTAssertGreaterThanOrEqual(estimate.residentDecodedByteCostUpperBound, actualResident)
    XCTAssertEqual(
      estimate.providerRetainedByteCostUpperBound,
      try XCTUnwrap(prepared.diagnostics.ownedRetainedBytes)
    )
    let steadyState =
      estimate.residentDecodedByteCostUpperBound
      + estimate.providerRetainedByteCostUpperBound
    XCTAssertGreaterThanOrEqual(estimate.predecodePeakByteCostUpperBound, steadyState)
  }

  func testOwnedGIFLZWCrossesCodeSizeBoundaries_IMG_ANIM_PT_058() async throws {
    let data = try makePatternedAnimatedGIF(width: 64, height: 64)
    let prepared = try await ImageIOAnimatedImageDecoder().prepareAnimationWithDiagnostics(
      source: .encoded(data)
    )
    XCTAssertEqual(prepared.diagnostics.backingKind, .ownedGIF)
    let request = try decodeRequest(width: 64, height: 64)
    let frames = try await prepared.asset.frames(in: 0..<2, request: request)
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    for index in 0..<2 {
      let oracle = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
      XCTAssertEqual(
        try normalizedPixelDigest(frames[index].image.cgImage),
        try normalizedPixelDigest(oracle)
      )
    }
  }

  func testOwnedGIFRequiresExplicitLZWEndCode_IMG_ANIM_PT_060() async throws {
    let lenient = try XCTUnwrap(
      Data(
        base64Encoded:
          "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAAh+QQBAAAAACwAAAAAAQABAAACAUQAOw=="
      )
    )
    let data = try clearingUnusedGIFTransparencyFlags(lenient)
    let prepared = try await ImageIOAnimatedImageDecoder().prepareAnimationWithDiagnostics(
      source: .encoded(data)
    )
    XCTAssertEqual(prepared.diagnostics.backingKind, .imageIOEncoded)
    XCTAssertEqual(
      prepared.diagnostics.resourceLedger.bound(for: .retainedBetweenCalls),
      .unknown(.frameworkPrivateRetainedState)
    )
    XCTAssertNil(
      prepared.asset.wholeTrackCostEstimate(for: try decodeRequest(width: 1, height: 1))
    )
    _ = try await prepared.asset.frame(at: 0, request: decodeRequest(width: 1, height: 1))
  }

  func testOwnedGIFFullCanvasTransparencyAndBackgroundDisposalMatchImageIO_IMG_ANIM_PT_059()
    async throws
  {
    let data = try gifWithBackgroundDisposal(try makeTransparentAnimatedGIF())
    let decoder = ImageIOAnimatedImageDecoder()
    let prepared = try await decoder.prepareAnimationWithDiagnostics(source: .encoded(data))
    XCTAssertEqual(prepared.diagnostics.backingKind, .ownedGIF)
    XCTAssertEqual(prepared.asset.metadata.frames[1].disposal, .background)
    XCTAssertEqual(prepared.asset.metadata.frames[1].blend, .over)
    let request = try decodeRequest(width: 4, height: 4)
    let owned = try await prepared.asset.frames(in: 0..<2, request: request)
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    for index in 0..<2 {
      let oracle = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
      XCTAssertEqual(
        try normalizedPixelDigest(owned[index].image.cgImage),
        try normalizedPixelDigest(oracle)
      )
    }
    let estimate = try XCTUnwrap(prepared.asset.wholeTrackCostEstimate(for: request))
    XCTAssertGreaterThanOrEqual(
      estimate.residentDecodedByteCostUpperBound,
      owned.reduce(0) { $0 + $1.image.estimatedByteCost }
    )
  }

  func testOwnedGIFInterlacedRowsMatchImageIO_IMG_ANIM_PT_061() async throws {
    let data = try gifWithInterlaceFlag(try makePatternedAnimatedGIF(width: 16, height: 16))
    let decoder = ImageIOAnimatedImageDecoder()
    let prepared = try await decoder.prepareAnimationWithDiagnostics(source: .encoded(data))
    XCTAssertEqual(prepared.diagnostics.backingKind, .ownedGIF)
    let request = try decodeRequest(width: 16, height: 16)
    let owned = try await prepared.asset.frames(in: 0..<2, request: request)
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    for index in 0..<2 {
      let oracle = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
      XCTAssertEqual(
        try normalizedPixelDigest(owned[index].image.cgImage),
        try normalizedPixelDigest(oracle)
      )
    }
    XCTAssertNotNil(prepared.asset.wholeTrackCostEstimate(for: request))
  }

  func testOwnedGIFSubrectReplayMatchesImageIOAndRandomAccess_IMG_ANIM_PT_062() async throws {
    let data = try makeSubrectReplayGIF()
    let decoder = ImageIOAnimatedImageDecoder()
    let prepared = try await decoder.prepareAnimationWithDiagnostics(source: .encoded(data))
    XCTAssertEqual(prepared.diagnostics.backingKind, .ownedGIF)
    XCTAssertEqual(prepared.asset.metadata.frameCount, 2)
    XCTAssertEqual(prepared.asset.metadata.frames[1].rect.x, 1)
    XCTAssertEqual(prepared.asset.metadata.frames[1].rect.y, 1)
    XCTAssertEqual(prepared.asset.metadata.frames[1].rect.width, 1)
    XCTAssertEqual(prepared.asset.metadata.frames[1].rect.height, 1)
    XCTAssertEqual(prepared.asset.metadata.frames[1].disposal, .none)

    let request = try decodeRequest(width: 2, height: 2)
    let owned = try await prepared.asset.frames(in: 0..<2, request: request)
    let randomSecond = try await prepared.asset.frame(at: 1, request: request)
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    for index in 0..<2 {
      let oracle = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
      let oracleDigest = try normalizedPixelDigest(oracle)
      XCTAssertEqual(try normalizedPixelDigest(owned[index].image.cgImage), oracleDigest)
      if index == 1 {
        XCTAssertEqual(try normalizedPixelDigest(randomSecond.image.cgImage), oracleDigest)
      }
    }
    let estimate = try XCTUnwrap(prepared.asset.wholeTrackCostEstimate(for: request))
    XCTAssertGreaterThanOrEqual(
      estimate.residentDecodedByteCostUpperBound,
      owned.reduce(0) { $0 + $1.image.estimatedByteCost }
    )
  }

  func testOwnedGIFSubrectUnsupportedDisposalFallsBack_IMG_ANIM_PT_063() async throws {
    let data = try gifWithBackgroundDisposal(try makeSubrectReplayGIF())
    let prepared = try await ImageIOAnimatedImageDecoder().prepareAnimationWithDiagnostics(
      source: .encoded(data)
    )
    XCTAssertEqual(prepared.diagnostics.backingKind, .imageIOEncoded)
    XCTAssertNil(
      prepared.asset.wholeTrackCostEstimate(for: try decodeRequest(width: 2, height: 2))
    )
    _ = try await prepared.asset.frame(at: 1, request: decodeRequest(width: 2, height: 2))
  }

  func testOwnedGIFSubrectTransparencyCompositesOverPriorCanvas_IMG_ANIM_PT_064()
    async throws
  {
    let data = try XCTUnwrap(
      Data(
        base64Encoded:
          "R0lGODlhAgACAIAAAP8AAAAA/yH/C05FVFNDQVBFMi4wAwEAAAAh+QQEAQAAACwAAAAAAgACAAACBARBEAUAIfkEBQEAAAAsAAABAAIAAQAAAgIEUwA7"
      )
    )
    let decoder = ImageIOAnimatedImageDecoder()
    let prepared = try await decoder.prepareAnimationWithDiagnostics(source: .encoded(data))
    XCTAssertEqual(prepared.diagnostics.backingKind, .ownedGIF)
    XCTAssertEqual(prepared.asset.metadata.frames[1].blend, .over)
    let request = try decodeRequest(width: 2, height: 2)
    let owned = try await prepared.asset.frames(in: 0..<2, request: request)
    let randomSecond = try await prepared.asset.frame(at: 1, request: request)
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    for index in 0..<2 {
      let oracle = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
      let oracleDigest = try normalizedPixelDigest(oracle)
      XCTAssertEqual(try normalizedPixelDigest(owned[index].image.cgImage), oracleDigest)
      if index == 1 {
        XCTAssertEqual(try normalizedPixelDigest(randomSecond.image.cgImage), oracleDigest)
      }
    }
  }

  func testOwnedGIFSubrectReplayHonorsDecodeWindowBound_IMG_ANIM_PT_065() async throws {
    let data = try makeSubrectReplayGIF()
    let prepared = try await ImageIOAnimatedImageDecoder().prepareAnimationWithDiagnostics(
      source: .encoded(data),
      limits: ImageAnimationDecodeLimits(maximumFrameDecodeWindow: 1)
    )
    XCTAssertEqual(prepared.diagnostics.backingKind, .imageIOEncoded)
    XCTAssertNil(
      prepared.asset.wholeTrackCostEstimate(for: try decodeRequest(width: 2, height: 2))
    )
    let second = try await prepared.asset.frame(at: 1, request: decodeRequest(width: 2, height: 2))
    XCTAssertEqual(second.descriptor.index, 1)
  }

  func testOwnedGIFSubrectReplayResetsAtOpaqueFullCanvasFrame_IMG_ANIM_PT_066()
    async throws
  {
    let data = try XCTUnwrap(
      Data(
        base64Encoded:
          "R0lGODlhAgACAIEAAP8AAAAA/wD/AAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQEAQAAACwAAAAAAgACAAACBARBEAUAIfkEBAEAAAAsAQABAAEAAQAAAgJMAQAh+QQEAQAAACwAAAAAAgACAAACBBRFUQUAOw=="
      )
    )
    let decoder = ImageIOAnimatedImageDecoder()
    let prepared = try await decoder.prepareAnimationWithDiagnostics(
      source: .encoded(data),
      limits: ImageAnimationDecodeLimits(maximumFrameDecodeWindow: 2)
    )
    XCTAssertEqual(prepared.diagnostics.backingKind, .ownedGIF)
    XCTAssertEqual(prepared.asset.metadata.frameCount, 3)
    let request = try decodeRequest(width: 2, height: 2)
    let second = try await prepared.asset.frame(at: 1, request: request)
    let third = try await prepared.asset.frame(at: 2, request: request)
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    let secondOracle = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 1, nil))
    let thirdOracle = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 2, nil))
    XCTAssertEqual(
      try normalizedPixelDigest(second.image.cgImage),
      try normalizedPixelDigest(secondOracle)
    )
    XCTAssertEqual(
      try normalizedPixelDigest(third.image.cgImage),
      try normalizedPixelDigest(thirdOracle)
    )
  }

  func testAPNGPreservesRationalTimelineAndCompositedCanvas_IMG_ANIM_PT_002() async throws {
    let data = try makeAPNG()
    let asset = try await ImageIOAnimatedImageDecoder().prepareAnimation(
      source: .encoded(data)
    )

    XCTAssertEqual(asset.metadata.container, .apng)
    XCTAssertEqual(asset.metadata.canvasWidth, 8)
    XCTAssertEqual(asset.metadata.canvasHeight, 8)
    XCTAssertEqual(asset.metadata.loopCount.additionalRepeatCount, 2)
    XCTAssertEqual(asset.metadata.frames[0].duration, try duration(1, 10))
    XCTAssertEqual(asset.metadata.frames[1].duration, try duration(1, 5))
    XCTAssertEqual(
      asset.metadata.frames[1].rect,
      try ImageAnimationFrameRect(
        x: 2,
        y: 2,
        width: 2,
        height: 2
      ))
    XCTAssertEqual(asset.metadata.frames[1].disposal, .background)
    XCTAssertEqual(asset.metadata.frames[1].blend, .over)

    let frame = try await asset.frame(at: 1, request: decodeRequest(width: 8, height: 8))
    XCTAssertGreaterThan(try redComponent(frame.image.cgImage, x: 0, y: 0), 200)
    XCTAssertGreaterThan(try blueComponent(frame.image.cgImage, x: 2, y: 2), 200)
    let window = try await asset.frames(
      in: 0..<2,
      request: decodeRequest(width: 8, height: 8)
    )
    XCTAssertEqual(window.map(\.descriptor.index), [0, 1])
    XCTAssertEqual(
      try normalizedPixelDigest(window[1].image.cgImage),
      try normalizedPixelDigest(frame.image.cgImage)
    )
  }

  func testJPEGSequenceRequiresStableCanvasAndSupportsCancellation_IMG_ANIM_PT_003() async throws {
    let red = try makeJPEG(width: 12, height: 8, red: 255, blue: 0)
    let blue = try makeJPEG(width: 12, height: 8, red: 0, blue: 255)
    let frames = [
      ImageJPEGAnimationFrame(data: red, duration: try duration(1, 12)),
      ImageJPEGAnimationFrame(data: blue, duration: try duration(1, 24)),
    ]
    let decoder = ImageIOAnimatedImageDecoder()
    let asset = try await decoder.prepareAnimation(
      source: .jpegSequence(frames: frames, loopCount: .infinite)
    )
    XCTAssertEqual(asset.metadata.container, .jpegSequence)
    XCTAssertTrue(asset.metadata.loopCount.isInfinite)
    XCTAssertEqual(asset.metadata.frameCount, 2)

    let decoded = try await asset.frame(at: 1, request: decodeRequest(width: 12, height: 8))
    XCTAssertGreaterThan(try blueComponent(decoded.image.cgImage, x: 4, y: 4), 180)

    await asset.cancel()
    await assertThrowsErrorAsync(
      try await asset.frame(at: 0, request: decodeRequest(width: 12, height: 8))
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .animationSessionCancelled)
    }

    let mismatched = ImageJPEGAnimationFrame(
      data: try makeJPEG(width: 10, height: 8, red: 0, blue: 255),
      duration: try duration(1, 10)
    )
    await assertThrowsErrorAsync(
      try await decoder.prepareAnimation(
        source: .jpegSequence(
          frames: [frames[0], mismatched],
          loopCount: .playOnce
        )
      )
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .animationFrameRectInvalid)
    }
  }

  func testStaticAndHostileInputsFailClosed_IMG_ANIM_PT_004() async throws {
    let decoder = ImageIOAnimatedImageDecoder()
    let staticPNG = try makeSolidPNG(width: 4, height: 4, red: 255, blue: 0)
    await assertThrowsErrorAsync(
      try await decoder.prepareAnimation(source: .encoded(staticPNG))
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .animationUnsupported)
    }

    let gif = try makeAnimatedGIF()
    let limits = ImageAnimationDecodeLimits(
      imageLimits: DecodeLimits(maximumFrameCount: 2),
      maximumTimelineDecodedBytes: 4
    )
    await assertThrowsErrorAsync(
      try await decoder.prepareAnimation(source: .encoded(gif), limits: limits)
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .animationTimelineInvalid)
    }

    let asset = try await decoder.prepareAnimation(source: .encoded(gif))
    await assertThrowsErrorAsync(
      try await asset.frame(at: 2, request: decodeRequest(width: 4, height: 4))
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .animationFrameIndexOutOfRange)
    }
    await assertThrowsErrorAsync(
      try await asset.frame(at: Int.max, request: decodeRequest(width: 4, height: 4))
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .animationFrameIndexOutOfRange)
    }
    let narrowWindow = ImageAnimationDecodeLimits(maximumFrameDecodeWindow: 1)
    let bounded = try await decoder.prepareAnimation(source: .encoded(gif), limits: narrowWindow)
    await assertThrowsErrorAsync(
      try await bounded.frames(in: 0..<2, request: decodeRequest(width: 4, height: 4))
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .animationDecodeWindowExceeded)
    }
  }
  func testAPNGRejectsSequenceGapAndOutOfCanvasRect_IMG_ANIM_PT_007() async throws {
    let decoder = ImageIOAnimatedImageDecoder()
    let original = try makeAPNG()
    let sequenceGap = try mutatePNGChunk(
      original,
      type: "fcTL",
      occurrence: 1
    ) { payload in
      payload.replaceSubrange(0..<4, with: be32(9))
    }
    await assertThrowsErrorAsync(
      try await decoder.prepareAnimation(source: .encoded(sequenceGap))
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .animationTimelineInvalid)
    }

    let outside = try mutatePNGChunk(
      original,
      type: "fcTL",
      occurrence: 1
    ) { payload in
      payload.replaceSubrange(12..<16, with: be32(7))
    }
    await assertThrowsErrorAsync(
      try await decoder.prepareAnimation(source: .encoded(outside))
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .animationFrameRectInvalid)
    }
  }

  func testGIFRejectsReservedDisposalMethod_IMG_ANIM_PT_008() async throws {
    var data = try makeAnimatedGIF()
    let marker = Data([0x21, 0xF9, 0x04])
    let start = try XCTUnwrap(data.range(of: marker)?.lowerBound)
    data[start + 3] = (7 << 2) | (data[start + 3] & 0x03)
    await assertThrowsErrorAsync(
      try await ImageIOAnimatedImageDecoder().prepareAnimation(source: .encoded(data))
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .animationTimelineInvalid)
    }
  }

  func testAnimationFormatAllowlistRejectsEverySourceKind_IMG_ANIM_PT_009() async throws {
    let decoder = ImageIOAnimatedImageDecoder()
    let gifLimits = ImageAnimationDecodeLimits(
      imageLimits: DecodeLimits(maximumFrameCount: 2, allowedFormats: [.png])
    )
    await assertThrowsErrorAsync(
      try await decoder.prepareAnimation(
        source: .encoded(try makeAnimatedGIF()),
        limits: gifLimits
      )
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .unsupportedFormat)
    }

    let apngLimits = ImageAnimationDecodeLimits(
      imageLimits: DecodeLimits(maximumFrameCount: 2, allowedFormats: [.gif])
    )
    await assertThrowsErrorAsync(
      try await decoder.prepareAnimation(
        source: .encoded(try makeAPNG()),
        limits: apngLimits
      )
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .unsupportedFormat)
    }

    let jpeg = try makeJPEG(width: 8, height: 8, red: 255, blue: 0)
    let jpegLimits = ImageAnimationDecodeLimits(
      imageLimits: DecodeLimits(maximumFrameCount: 1, allowedFormats: [.gif])
    )
    await assertThrowsErrorAsync(
      try await decoder.prepareAnimation(
        source: .jpegSequence(
          frames: [
            ImageJPEGAnimationFrame(
              data: jpeg,
              duration: try duration(1, 10)
            )
          ],
          loopCount: .playOnce
        ),
        limits: jpegLimits
      )
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .unsupportedFormat)
    }
  }

  func testJPEGSequenceMetadataBudgetIsCumulative_IMG_ANIM_PT_010() async throws {
    let first = try jpegWithComment(
      makeJPEG(width: 8, height: 8, red: 255, blue: 0),
      byteCount: 80
    )
    let second = try jpegWithComment(
      makeJPEG(width: 8, height: 8, red: 0, blue: 255),
      byteCount: 80
    )
    let limits = ImageAnimationDecodeLimits(
      imageLimits: DecodeLimits(
        maximumEncodedBytes: 1_048_576,
        maximumDimension: 64,
        maximumPixelCount: 4_096,
        maximumFrameCount: 2,
        maximumMetadataBytes: 100,
        allowedFormats: [.jpeg]
      )
    )
    await assertThrowsErrorAsync(
      try await ImageIOAnimatedImageDecoder().prepareAnimation(
        source: .jpegSequence(
          frames: [
            ImageJPEGAnimationFrame(data: first, duration: try duration(1, 10)),
            ImageJPEGAnimationFrame(data: second, duration: try duration(1, 10)),
          ],
          loopCount: .playOnce
        ),
        limits: limits
      )
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .metadataLimitExceeded)
    }
  }

  func testAPNGRejectsCorruptCRCAndNonconsecutiveIDAT_IMG_ANIM_PT_011() async throws {
    let original = try makeAPNG()
    let corruptCRC = try corruptPNGChunkCRC(
      original,
      type: "fcTL",
      occurrence: 1
    )
    await assertThrowsErrorAsync(
      try await ImageIOAnimatedImageDecoder().prepareAnimation(source: .encoded(corruptCRC))
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .animationTimelineInvalid)
    }

    let separatedIDAT = try makeAPNGWithNonconsecutiveIDAT(original)
    await assertThrowsErrorAsync(
      try await ImageIOAnimatedImageDecoder().prepareAnimation(source: .encoded(separatedIDAT))
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .animationTimelineInvalid)
    }
  }

  func testAPNGDeclaredFrameCountIsRejectedAtAdmission_IMG_ANIM_PT_012() async throws {
    let declaredOverflow = try mutatePNGChunk(
      makeAPNG(),
      type: "acTL",
      occurrence: 0
    ) { payload in
      payload.replaceSubrange(0..<4, with: be32(UInt32.max))
    }
    let limits = ImageAnimationDecodeLimits(
      imageLimits: DecodeLimits(maximumFrameCount: 2)
    )
    await assertThrowsErrorAsync(
      try await ImageIOAnimatedImageDecoder().prepareAnimation(
        source: .encoded(declaredOverflow),
        limits: limits
      )
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .frameLimitExceeded)
    }
  }

  func testGIFRejectsReservedGraphicControlBits_IMG_ANIM_PT_013() async throws {
    var data = try makeAnimatedGIF()
    let marker = Data([0x21, 0xF9, 0x04])
    let start = try XCTUnwrap(data.range(of: marker)?.lowerBound)
    data[start + 3] |= 0x20
    await assertThrowsErrorAsync(
      try await ImageIOAnimatedImageDecoder().prepareAnimation(source: .encoded(data))
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .animationTimelineInvalid)
    }
  }

  func testAPNGRejectsFDATForIDATBackedFirstFrame_IMG_ANIM_PT_014() async throws {
    let malformed = try makeAPNGWithFDATReplacingFirstIDAT(makeAPNG())
    await assertThrowsErrorAsync(
      try await ImageIOAnimatedImageDecoder().prepareAnimation(source: .encoded(malformed))
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .animationTimelineInvalid)
    }
  }

  func testGIFRejectsInvalidLZWMinimumCodeSize_IMG_ANIM_PT_015() async throws {
    var data = try makeAnimatedGIF()
    let codeSizeOffset = try firstGIFImageCodeSizeOffset(data)
    data[codeSizeOffset] = 1
    await assertThrowsErrorAsync(
      try await ImageIOAnimatedImageDecoder().prepareAnimation(source: .encoded(data))
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .animationTimelineInvalid)
    }
  }

  func testAPNGExcludesSeparateDefaultImageFromAnimation_IMG_ANIM_PT_020() async throws {
    let data = try makeAPNGWithSeparateDefaultImage()
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    XCTAssertEqual(CGImageSourceGetCount(source), 1)

    let asset = try await ImageIOAnimatedImageDecoder().prepareAnimation(source: .encoded(data))
    XCTAssertEqual(asset.metadata.frameCount, 1)
    XCTAssertTrue(asset.metadata.loopCount.isInfinite)
    XCTAssertEqual(asset.metadata.frames[0].duration, try duration(1, 10))

    let frame = try await asset.frame(at: 0, request: decodeRequest(width: 2, height: 2))
    XCTAssertLessThan(try redComponent(frame.image.cgImage, x: 0, y: 0), 20)
    XCTAssertGreaterThan(try blueComponent(frame.image.cgImage, x: 0, y: 0), 240)
    await asset.cancel()

    let multiFrame = try makeMultiFrameAPNGWithSeparateDefaultImage()
    let multiAsset = try await ImageIOAnimatedImageDecoder().prepareAnimation(
      source: .encoded(multiFrame)
    )
    XCTAssertEqual(multiAsset.metadata.frameCount, 2)
    let animationFirst = try await multiAsset.frame(
      at: 0,
      request: decodeRequest(width: 2, height: 2)
    )
    let animationSecond = try await multiAsset.frame(
      at: 1,
      request: decodeRequest(width: 2, height: 2)
    )
    XCTAssertLessThan(try redComponent(animationFirst.image.cgImage, x: 0, y: 0), 20)
    XCTAssertGreaterThan(try blueComponent(animationFirst.image.cgImage, x: 0, y: 0), 240)
    XCTAssertGreaterThan(try redComponent(animationSecond.image.cgImage, x: 0, y: 0), 240)
    XCTAssertLessThan(try blueComponent(animationSecond.image.cgImage, x: 0, y: 0), 20)
    await multiAsset.cancel()
  }

  func testOwnedAPNGRespectsFitAndFillGeometry_IMG_ANIM_PT_045() async throws {
    let asset = try await ImageIOAnimatedImageDecoder().prepareAnimation(
      source: .encoded(try makeAPNG())
    )
    let fitRequest = ImageDecodeRequest(
      target: try TargetPixels(width: 4, height: 2),
      contentMode: .fit,
      colorPolicy: .convertToSRGB
    )
    let fit = try await asset.frame(at: 0, request: fitRequest)
    XCTAssertEqual(fit.image.pixelWidth, 2)
    XCTAssertEqual(fit.image.pixelHeight, 2)
    let fitWindow = try await asset.frames(in: 0..<2, request: fitRequest)
    let fitEstimate = try XCTUnwrap(asset.wholeTrackCostEstimate(for: fitRequest))
    XCTAssertLessThanOrEqual(
      fitWindow.reduce(0) { $0 + $1.image.estimatedByteCost },
      fitEstimate.residentDecodedByteCostUpperBound
    )
    XCTAssertGreaterThanOrEqual(
      fitEstimate.predecodePeakByteCostUpperBound,
      fitEstimate.residentDecodedByteCostUpperBound
    )

    let fillRequest = ImageDecodeRequest(
      target: try TargetPixels(width: 4, height: 2),
      contentMode: .fill,
      colorPolicy: .convertToSRGB
    )
    let fill = try await asset.frame(at: 0, request: fillRequest)
    XCTAssertEqual(fill.image.pixelWidth, 4)
    XCTAssertEqual(fill.image.pixelHeight, 2)
    let fillWindow = try await asset.frames(in: 0..<2, request: fillRequest)
    let fillEstimate = try XCTUnwrap(asset.wholeTrackCostEstimate(for: fillRequest))
    XCTAssertLessThanOrEqual(
      fillWindow.reduce(0) { $0 + $1.image.estimatedByteCost },
      fillEstimate.residentDecodedByteCostUpperBound
    )
    XCTAssertGreaterThanOrEqual(
      fillEstimate.predecodePeakByteCostUpperBound,
      fillEstimate.residentDecodedByteCostUpperBound
    )
  }

  func testAlignedRGBAPNGFallsBackToImageIO_IMG_ANIM_PT_046() async throws {
    let data = try makeRGBAPNG()
    let ihdr = try XCTUnwrap(try pngChunks(data).first { $0.type == "IHDR" })
    XCTAssertEqual(ihdr.payload[ihdr.payload.startIndex + 9], 2)

    let decoder = ImageIOAnimatedImageDecoder()
    XCTAssertEqual(decoder.codecDescriptor.implementationVersion, 2)
    let asset = try await decoder.prepareAnimation(source: .encoded(data))
    XCTAssertNil(
      asset.wholeTrackCostEstimate(
        for: try decodeRequest(width: 8, height: 8)
      )
    )
    let frame = try await asset.frame(
      at: 1,
      request: decodeRequest(width: 8, height: 8)
    )
    XCTAssertGreaterThan(try redComponent(frame.image.cgImage, x: 0, y: 0), 200)
    XCTAssertGreaterThan(try blueComponent(frame.image.cgImage, x: 2, y: 2), 200)
  }

  func testUnalignedRGBAPNGStillFailsClosed_IMG_ANIM_PT_047() async throws {
    let data = try makeMultiFrameRGBAPNGWithSeparateDefaultImage()
    await assertThrowsErrorAsync(
      try await ImageIOAnimatedImageDecoder().prepareAnimation(source: .encoded(data))
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .animationUnsupported)
    }
  }

  func testOwnedAPNGCancellationFencesFrames_IMG_ANIM_PT_048() async throws {
    let prepared = try await ImageIOAnimatedImageDecoder().prepareAnimationWithDiagnostics(
      source: .encoded(try makeMultiFrameAPNGWithSeparateDefaultImage())
    )
    let before = await prepared.lifecycleSnapshot()
    XCTAssertFalse(before.isCancelled)
    XCTAssertEqual(before.activeOperationCount, 0)
    XCTAssertTrue(before.holdsPreparedBacking)
    let beforeLedger = await prepared.resourceLedgerSnapshot()
    XCTAssertFalse(beforeLedger.isTerminal)

    await prepared.asset.cancel()
    let after = await prepared.lifecycleSnapshot()
    XCTAssertTrue(after.isCancelled)
    XCTAssertEqual(after.activeOperationCount, 0)
    XCTAssertFalse(after.holdsPreparedBacking)
    let afterLedger = await prepared.resourceLedgerSnapshot()
    XCTAssertTrue(afterLedger.isTerminal)
    await assertThrowsErrorAsync(
      try await prepared.asset.frame(at: 0, request: decodeRequest(width: 2, height: 2))
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .animationSessionCancelled)
    }
  }

  func testAnimationCancellationWaitsForInFlightWorkAndReleasesBacking_IMG_ANIM_PT_068()
    async throws
  {
    let operationStarted = DispatchSemaphore(value: 0)
    let allowOperationToFinish = DispatchSemaphore(value: 0)
    let cancellationReturned = DispatchSemaphore(value: 0)
    let decoder = ImageIOAnimatedImageDecoder(frameOperationHook: {
      operationStarted.signal()
      _ = allowOperationToFinish.wait(timeout: .now() + 5)
    })
    let prepared = try await decoder.prepareAnimationWithDiagnostics(
      source: .encoded(try makeMultiFrameAPNGWithSeparateDefaultImage())
    )
    let request = try decodeRequest(width: 2, height: 2)
    let frameTask = Task {
      try await prepared.asset.frame(at: 0, request: request)
    }

    XCTAssertEqual(operationStarted.wait(timeout: .now() + 2), .success)
    let active = await prepared.lifecycleSnapshot()
    XCTAssertFalse(active.isCancelled)
    XCTAssertEqual(active.activeOperationCount, 1)
    XCTAssertTrue(active.holdsPreparedBacking)

    let cancelTask = Task {
      await prepared.asset.cancel()
      cancellationReturned.signal()
    }
    var cancelling: ImageIOAnimationProviderLifecycleSnapshot?
    for _ in 0..<100 {
      let snapshot = await prepared.lifecycleSnapshot()
      if snapshot.isCancelled {
        cancelling = snapshot
        break
      }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    let duringCancel = try XCTUnwrap(cancelling)
    XCTAssertEqual(duringCancel.activeOperationCount, 1)
    XCTAssertFalse(duringCancel.holdsPreparedBacking)
    let duringCancelLedger = await prepared.resourceLedgerSnapshot()
    XCTAssertFalse(duringCancelLedger.isTerminal)
    XCTAssertEqual(cancellationReturned.wait(timeout: .now() + 0.02), .timedOut)

    allowOperationToFinish.signal()
    await cancelTask.value
    XCTAssertEqual(cancellationReturned.wait(timeout: .now() + 1), .success)
    let after = await prepared.lifecycleSnapshot()
    XCTAssertTrue(after.isCancelled)
    XCTAssertEqual(after.activeOperationCount, 0)
    XCTAssertFalse(after.holdsPreparedBacking)
    let terminalLedger = await prepared.resourceLedgerSnapshot()
    XCTAssertTrue(terminalLedger.isTerminal)

    do {
      _ = try await frameTask.value
      XCTFail("Cancelled in-flight animation work must not publish a frame")
    } catch {
      XCTAssertEqual(error as? ImageCraftError, .animationSessionCancelled)
    }
  }

  func testAnimationProviderSerializesConcurrentWindowsAndCancelsQueuedWork_IMG_ANIM_PT_070()
    async throws
  {
    let gate = AnimationOperationGate()
    let decoder = ImageIOAnimatedImageDecoder(frameOperationHook: {
      gate.beforeOperation()
    })
    let prepared = try await decoder.prepareAnimationWithDiagnostics(
      source: .encoded(try makeTenFramePublicAPNG()),
      limits: ImageAnimationDecodeLimits(maximumFrameDecodeWindow: 2)
    )
    let request = try decodeRequest(width: 4, height: 4)
    let firstTask = Task {
      try await prepared.asset.frames(in: 0..<2, request: request)
    }
    XCTAssertEqual(gate.firstStarted.wait(timeout: .now() + 2), .success)

    let secondTask = Task {
      try await prepared.asset.frames(in: 2..<4, request: request)
    }
    var queuedSnapshot: ImageIOAnimationProviderLifecycleSnapshot?
    for _ in 0..<100 {
      let snapshot = await prepared.lifecycleSnapshot()
      if snapshot.queuedOperationCount == 1 {
        queuedSnapshot = snapshot
        break
      }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    let queued = try XCTUnwrap(queuedSnapshot)
    XCTAssertEqual(queued.activeOperationCount, 1)
    XCTAssertEqual(queued.queuedOperationCount, 1)
    XCTAssertTrue(queued.holdsPreparedBacking)
    XCTAssertEqual(gate.secondStarted.wait(timeout: .now() + 0.02), .timedOut)

    let cancellationReturned = DispatchSemaphore(value: 0)
    let cancelTask = Task {
      await prepared.asset.cancel()
      cancellationReturned.signal()
    }
    var cancellingSnapshot: ImageIOAnimationProviderLifecycleSnapshot?
    for _ in 0..<100 {
      let snapshot = await prepared.lifecycleSnapshot()
      if snapshot.isCancelled {
        cancellingSnapshot = snapshot
        break
      }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    let cancelling = try XCTUnwrap(cancellingSnapshot)
    XCTAssertEqual(cancelling.activeOperationCount, 1)
    XCTAssertEqual(cancelling.queuedOperationCount, 0)
    XCTAssertFalse(cancelling.holdsPreparedBacking)
    XCTAssertEqual(gate.secondStarted.wait(timeout: .now() + 0.02), .timedOut)
    XCTAssertEqual(cancellationReturned.wait(timeout: .now() + 0.02), .timedOut)

    do {
      _ = try await secondTask.value
      XCTFail("Queued animation work must fail when provider cancellation starts")
    } catch {
      XCTAssertEqual(error as? ImageCraftError, .animationSessionCancelled)
    }

    gate.allowFirstToFinish.signal()
    await cancelTask.value
    XCTAssertEqual(cancellationReturned.wait(timeout: .now() + 1), .success)
    do {
      _ = try await firstTask.value
      XCTFail("In-flight animation work must not publish after cancellation")
    } catch {
      XCTAssertEqual(error as? ImageCraftError, .animationSessionCancelled)
    }
    let after = await prepared.lifecycleSnapshot()
    XCTAssertEqual(after.activeOperationCount, 0)
    XCTAssertEqual(after.queuedOperationCount, 0)
    XCTAssertFalse(after.holdsPreparedBacking)
    let terminalLedger = await prepared.resourceLedgerSnapshot()
    XCTAssertTrue(terminalLedger.isTerminal)
  }

  func testAnimationProviderTransfersSerializedSlotToNextWindow_IMG_ANIM_PT_071()
    async throws
  {
    let gate = AnimationOperationGate()
    let decoder = ImageIOAnimatedImageDecoder(frameOperationHook: {
      gate.beforeOperation()
    })
    let prepared = try await decoder.prepareAnimationWithDiagnostics(
      source: .encoded(try makeTenFramePublicAPNG()),
      limits: ImageAnimationDecodeLimits(maximumFrameDecodeWindow: 2)
    )
    let request = try decodeRequest(width: 4, height: 4)
    let firstTask = Task {
      try await prepared.asset.frames(in: 0..<2, request: request)
    }
    XCTAssertEqual(gate.firstStarted.wait(timeout: .now() + 2), .success)
    let secondTask = Task {
      try await prepared.asset.frames(in: 2..<4, request: request)
    }

    var queuedSnapshot: ImageIOAnimationProviderLifecycleSnapshot?
    for _ in 0..<100 {
      let snapshot = await prepared.lifecycleSnapshot()
      if snapshot.queuedOperationCount == 1 {
        queuedSnapshot = snapshot
        break
      }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    let queued = try XCTUnwrap(queuedSnapshot)
    XCTAssertEqual(queued.activeOperationCount, 1)
    XCTAssertEqual(queued.queuedOperationCount, 1)
    XCTAssertEqual(gate.secondStarted.wait(timeout: .now() + 0.02), .timedOut)

    gate.allowFirstToFinish.signal()
    XCTAssertEqual(gate.secondStarted.wait(timeout: .now() + 2), .success)
    let first = try await firstTask.value
    let second = try await secondTask.value
    XCTAssertEqual(first.map(\.descriptor.index), [0, 1])
    XCTAssertEqual(second.map(\.descriptor.index), [2, 3])
    let after = await prepared.lifecycleSnapshot()
    XCTAssertFalse(after.isCancelled)
    XCTAssertEqual(after.activeOperationCount, 0)
    XCTAssertEqual(after.queuedOperationCount, 0)
    XCTAssertTrue(after.holdsPreparedBacking)

    await prepared.asset.cancel()
    let terminalLedger = await prepared.resourceLedgerSnapshot()
    XCTAssertTrue(terminalLedger.isTerminal)
  }

  func testCancelledQueuedWindowTransfersSlotWithoutEnteringExecutor_IMG_ANIM_PT_072()
    async throws
  {
    let gate = AnimationOperationGate()
    let decoder = ImageIOAnimatedImageDecoder(frameOperationHook: {
      gate.beforeOperation()
    })
    let prepared = try await decoder.prepareAnimationWithDiagnostics(
      source: .encoded(try makeTenFramePublicAPNG()),
      limits: ImageAnimationDecodeLimits(maximumFrameDecodeWindow: 2)
    )
    let request = try decodeRequest(width: 4, height: 4)
    let firstTask = Task {
      try await prepared.asset.frames(in: 0..<2, request: request)
    }
    XCTAssertEqual(gate.firstStarted.wait(timeout: .now() + 2), .success)
    let cancelledTask = Task {
      try await prepared.asset.frames(in: 2..<4, request: request)
    }
    let successorTask = Task {
      try await prepared.asset.frames(in: 4..<6, request: request)
    }

    var queuedSnapshot: ImageIOAnimationProviderLifecycleSnapshot?
    for _ in 0..<100 {
      let snapshot = await prepared.lifecycleSnapshot()
      if snapshot.queuedOperationCount == 2 {
        queuedSnapshot = snapshot
        break
      }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    let queued = try XCTUnwrap(queuedSnapshot)
    XCTAssertEqual(queued.activeOperationCount, 1)
    XCTAssertEqual(queued.queuedOperationCount, 2)
    cancelledTask.cancel()
    XCTAssertEqual(gate.secondStarted.wait(timeout: .now() + 0.02), .timedOut)

    gate.allowFirstToFinish.signal()
    let first = try await firstTask.value
    XCTAssertEqual(first.map(\.descriptor.index), [0, 1])
    do {
      _ = try await cancelledTask.value
      XCTFail("Cancelled queued work must not enter the executor")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertEqual(gate.secondStarted.wait(timeout: .now() + 2), .success)
    let successor = try await successorTask.value
    XCTAssertEqual(successor.map(\.descriptor.index), [4, 5])
    let after = await prepared.lifecycleSnapshot()
    XCTAssertEqual(after.activeOperationCount, 0)
    XCTAssertEqual(after.queuedOperationCount, 0)

    await prepared.asset.cancel()
  }

  func testOwnedAnimationFrameWindowCostEstimateComposesCallerRetainedOutputs_IMG_ANIM_PT_069()
    async throws
  {
    let decoder = ImageIOAnimatedImageDecoder()
    let limits = ImageAnimationDecodeLimits(maximumFrameDecodeWindow: 3)
    let prepared = try await decoder.prepareAnimationWithDiagnostics(
      source: .encoded(try makeTenFramePublicAPNG()),
      limits: limits
    )
    XCTAssertEqual(prepared.diagnostics.backingKind, .ownedAPNG)
    let request = try decodeRequest(width: 4, height: 4)

    XCTAssertNil(prepared.frameWindowCostEstimate(for: request, frameCount: 0))
    XCTAssertNil(prepared.frameWindowCostEstimate(for: request, frameCount: 4))
    let one = try XCTUnwrap(prepared.frameWindowCostEstimate(for: request, frameCount: 1))
    let two = try XCTUnwrap(prepared.frameWindowCostEstimate(for: request, frameCount: 2))
    let three = try XCTUnwrap(prepared.frameWindowCostEstimate(for: request, frameCount: 3))
    XCTAssertEqual(one.frameCount, 1)
    XCTAssertEqual(two.frameCount, 2)
    XCTAssertEqual(three.frameCount, 3)
    XCTAssertEqual(
      three.providerRetainedByteCostUpperBound,
      try XCTUnwrap(prepared.diagnostics.ownedRetainedBytes)
    )
    XCTAssertLessThan(one.decodedOutputByteCostUpperBound, two.decodedOutputByteCostUpperBound)
    XCTAssertLessThan(two.decodedOutputByteCostUpperBound, three.decodedOutputByteCostUpperBound)
    XCTAssertLessThan(one.predecodePeakByteCostUpperBound, two.predecodePeakByteCostUpperBound)
    XCTAssertLessThan(two.predecodePeakByteCostUpperBound, three.predecodePeakByteCostUpperBound)

    let decoded = try await prepared.asset.frames(in: 0..<3, request: request)
    let decodedBytes = decoded.reduce(0) { $0 + $1.image.estimatedByteCost }
    XCTAssertLessThanOrEqual(decodedBytes, three.decodedOutputByteCostUpperBound)
    let callerRetained = decoded.prefix(2).reduce(0) { $0 + $1.image.estimatedByteCost }
    let coexistence = try XCTUnwrap(
      one.coexistencePeakByteCostUpperBound(callerRetainedOutputBytes: callerRetained)
    )
    XCTAssertEqual(coexistence, one.predecodePeakByteCostUpperBound + callerRetained)
    XCTAssertNil(one.coexistencePeakByteCostUpperBound(callerRetainedOutputBytes: -1))
    XCTAssertNil(one.coexistencePeakByteCostUpperBound(callerRetainedOutputBytes: .max))

    let wholeTrack = try XCTUnwrap(prepared.asset.wholeTrackCostEstimate(for: request))
    XCTAssertLessThanOrEqual(
      three.decodedOutputByteCostUpperBound,
      wholeTrack.residentDecodedByteCostUpperBound
    )

    let fallback = try await decoder.prepareAnimationWithDiagnostics(
      source: .encoded(try makeRGBAPNG())
    )
    XCTAssertEqual(fallback.diagnostics.backingKind, .imageIOEncoded)
    XCTAssertNil(fallback.frameWindowCostEstimate(for: request, frameCount: 1))
  }

  func testPublicOwnedAPNGCrossesFrameEightCheckpoint_IMG_ANIM_PT_049() async throws {
    let prepared = try await ImageIOAnimatedImageDecoder().prepareAnimationWithDiagnostics(
      source: .encoded(try makeTenFramePublicAPNG())
    )
    let diagnostics = prepared.diagnostics
    XCTAssertEqual(diagnostics.backingKind, .ownedAPNG)
    XCTAssertEqual(diagnostics.ownedRetainedCheckpointCount, 1)
    XCTAssertEqual(diagnostics.ownedMaximumReplayFrames, 8)
    XCTAssertGreaterThan(diagnostics.ownedRetainedCheckpointBytes ?? 0, 0)
    XCTAssertLessThanOrEqual(diagnostics.ownedRetainedBytes ?? .max, 32 * 1_024 * 1_024)
    XCTAssertGreaterThan(
      diagnostics.ownedModeledPeakBytesUpperBound ?? 0,
      diagnostics.ownedRetainedBytes ?? .max
    )
    let asset = prepared.asset
    let request = try decodeRequest(width: 4, height: 4)
    let estimate = try XCTUnwrap(asset.wholeTrackCostEstimate(for: request))
    XCTAssertEqual(
      estimate.providerRetainedByteCostUpperBound,
      try XCTUnwrap(diagnostics.ownedRetainedBytes)
    )
    let steadyState =
      estimate.residentDecodedByteCostUpperBound
      + estimate.providerRetainedByteCostUpperBound
    XCTAssertGreaterThanOrEqual(estimate.predecodePeakByteCostUpperBound, steadyState)
    let firstWindow = try await asset.frames(in: 0..<8, request: request)
    let secondWindow = try await asset.frames(in: 8..<10, request: request)
    let sequential = firstWindow + secondWindow
    XCTAssertEqual(sequential.map(\.descriptor.index), Array(0..<10))
    for index in [9, 7, 0] {
      let random = try await asset.frame(at: index, request: request)
      XCTAssertEqual(
        try normalizedPixelDigest(random.image.cgImage),
        try normalizedPixelDigest(sequential[index].image.cgImage)
      )
    }
  }

  func
    testPublicOwnedAPNGSemanticReplayDiagnosticsEliminateFullBackgroundCheckpoints_IMG_ANIM_PT_056()
    async throws
  {
    let prepared = try await ImageIOAnimatedImageDecoder().prepareAnimationWithDiagnostics(
      source: .encoded(try makeTenFrameFullBackgroundPublicAPNG())
    )
    let diagnostics = prepared.diagnostics
    XCTAssertEqual(diagnostics.backingKind, .ownedAPNG)
    XCTAssertEqual(diagnostics.ownedRetainedCheckpointCount, 0)
    XCTAssertEqual(diagnostics.ownedRetainedCheckpointBytes, 0)
    XCTAssertEqual(diagnostics.ownedSemanticReplayResetCount, 9)
    XCTAssertEqual(diagnostics.ownedMaximumReplayFrames, 8)
    XCTAssertEqual(diagnostics.ownedMaximumResolvedReplayFrames, 1)

    let request = try decodeRequest(width: 4, height: 4)
    let asset = prepared.asset
    let window = try await asset.frames(in: 7..<10, request: request)
    XCTAssertEqual(window.map(\.descriptor.index), [7, 8, 9])
    for frame in window {
      let random = try await asset.frame(at: frame.descriptor.index, request: request)
      XCTAssertEqual(
        try normalizedPixelDigest(random.image.cgImage),
        try normalizedPixelDigest(frame.image.cgImage)
      )
    }
  }

  func testPreparationDiagnosticsIdentifyBackingKinds_IMG_ANIM_PT_050() async throws {
    let decoder = ImageIOAnimatedImageDecoder()

    let owned = try await decoder.prepareAnimationWithDiagnostics(
      source: .encoded(try makeAPNG())
    )
    XCTAssertEqual(owned.diagnostics.backingKind, .ownedAPNG)
    XCTAssertEqual(owned.diagnostics.imageIOSourceIndicesMatchTimeline, true)
    XCTAssertEqual(owned.diagnostics.ownedRetainedCheckpointCount, 0)
    XCTAssertEqual(owned.diagnostics.ownedMaximumReplayFrames, 8)
    XCTAssertNotNil(owned.diagnostics.ownedRetainedBytes)
    XCTAssertNotNil(owned.diagnostics.ownedModeledPeakBytesUpperBound)

    let separateDefault = try await decoder.prepareAnimationWithDiagnostics(
      source: .encoded(try makeMultiFrameAPNGWithSeparateDefaultImage())
    )
    XCTAssertEqual(separateDefault.diagnostics.backingKind, .ownedAPNG)
    XCTAssertEqual(separateDefault.diagnostics.imageIOSourceIndicesMatchTimeline, false)

    let imageIOFallback = try await decoder.prepareAnimationWithDiagnostics(
      source: .encoded(try makeRGBAPNG())
    )
    XCTAssertEqual(imageIOFallback.diagnostics.backingKind, .imageIOEncoded)
    XCTAssertEqual(imageIOFallback.diagnostics.imageIOSourceIndicesMatchTimeline, true)
    XCTAssertNil(imageIOFallback.diagnostics.ownedRetainedBytes)

    let gif = try await decoder.prepareAnimationWithDiagnostics(
      source: .encoded(try makeAnimatedGIF())
    )
    XCTAssertEqual(gif.diagnostics.backingKind, .ownedGIF)
    XCTAssertEqual(gif.diagnostics.imageIOSourceIndicesMatchTimeline, true)
    XCTAssertNotNil(gif.diagnostics.ownedRetainedBytes)
    XCTAssertNotNil(gif.diagnostics.ownedModeledPeakBytesUpperBound)

    let jpegFrames = [
      ImageJPEGAnimationFrame(
        data: try makeJPEG(width: 4, height: 4, red: 255, blue: 0),
        duration: try duration(1, 10)
      ),
      ImageJPEGAnimationFrame(
        data: try makeJPEG(width: 4, height: 4, red: 0, blue: 255),
        duration: try duration(1, 10)
      ),
    ]
    let jpeg = try await decoder.prepareAnimationWithDiagnostics(
      source: .jpegSequence(frames: jpegFrames, loopCount: .playOnce)
    )
    let jpegEncodedBytes = jpegFrames.reduce(0) { $0 + $1.data.count }
    XCTAssertEqual(jpeg.diagnostics.backingKind, .jpegSequence)
    XCTAssertNil(jpeg.diagnostics.imageIOSourceIndicesMatchTimeline)
    XCTAssertEqual(jpeg.diagnostics.ownedEncodedFramePayloadBytes, jpegEncodedBytes)
    XCTAssertEqual(jpeg.diagnostics.ownedRetainedBytes, jpegEncodedBytes)
    XCTAssertEqual(
      jpeg.diagnostics.resourceLedger.retainedBetweenCalls,
      .bounded(jpegEncodedBytes)
    )
    XCTAssertEqual(
      jpeg.diagnostics.resourceLedger.bound(for: .operationPeak),
      .unknown(.frameworkPrivateOperationAllocation)
    )
    XCTAssertEqual(
      jpeg.diagnostics.resourceLedger.bound(for: .transferredOutput),
      .unknown(.frameworkChosenOutputLayout)
    )
  }

  func testJPEGSequencePureValueBackingIsBoundedAndReclaimed_IMG_ANIM_PT_073() async throws {
    let red = try makeJPEG(width: 12, height: 8, red: 255, blue: 0)
    let blue = try makeJPEG(width: 12, height: 8, red: 0, blue: 255)
    let frames = [
      ImageJPEGAnimationFrame(data: red, duration: try duration(1, 12)),
      ImageJPEGAnimationFrame(data: blue, duration: try duration(1, 24)),
    ]
    let prepared = try await ImageIOAnimatedImageDecoder().prepareAnimationWithDiagnostics(
      source: .jpegSequence(frames: frames, loopCount: .playOnce)
    )
    let retainedBytes = red.count + blue.count
    let before = await prepared.resourceLedgerSnapshot()
    XCTAssertEqual(before.retainedKnownBytes, retainedBytes)
    XCTAssertEqual(before.retainedBetweenCalls, .bounded(retainedBytes))
    XCTAssertEqual(before.bound(for: .operationPeak), .unknown(.frameworkPrivateOperationAllocation))
    XCTAssertFalse(before.isTerminal)

    let decoded = try await prepared.asset.frame(
      at: 1,
      request: decodeRequest(width: 12, height: 8)
    )
    XCTAssertGreaterThan(try blueComponent(decoded.image.cgImage, x: 4, y: 4), 180)
    let afterDecode = await prepared.resourceLedgerSnapshot()
    XCTAssertEqual(afterDecode, before)

    await prepared.asset.cancel()
    let after = await prepared.resourceLedgerSnapshot()
    XCTAssertTrue(after.isTerminal)
    let lifecycle = await prepared.lifecycleSnapshot()
    XCTAssertTrue(lifecycle.isCancelled)
    XCTAssertFalse(lifecycle.holdsPreparedBacking)
  }

  func testImageIOFallbackSingleAndWindowPixelsMatch_IMG_ANIM_PT_052() async throws {
    let asset = try await ImageIOAnimatedImageDecoder().prepareAnimation(
      source: .encoded(try makeRGBAPNG())
    )
    let request = try decodeRequest(width: 8, height: 8)
    let window = try await asset.frames(in: 0..<2, request: request)
    XCTAssertEqual(window.count, 2)
    for index in window.indices {
      let single = try await asset.frame(at: index, request: request)
      XCTAssertEqual(
        try normalizedPixelDigest(single.image.cgImage),
        try normalizedPixelDigest(window[index].image.cgImage)
      )
    }
  }

  func testAPNGRejectsUnknownCriticalAndInvalidReservedChunkTypes_IMG_ANIM_PT_022() async throws {
    let original = try makeAPNG()
    let unknownCritical = try insertingPNGChunk(
      in: original,
      after: "IHDR",
      type: "ABCD",
      payload: Data()
    )
    await assertThrowsErrorAsync(
      try await ImageIOAnimatedImageDecoder().prepareAnimation(source: .encoded(unknownCritical))
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .animationTimelineInvalid)
    }

    let invalidReserved = try insertingPNGChunk(
      in: original,
      after: "IHDR",
      type: "aabA",
      payload: Data()
    )
    await assertThrowsErrorAsync(
      try await ImageIOAnimatedImageDecoder().prepareAnimation(source: .encoded(invalidReserved))
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .animationTimelineInvalid)
    }
  }

  func testGIFRejectsUserInputControlFlag_IMG_ANIM_PT_025() async throws {
    var data = try makeAnimatedGIF()
    let marker = Data([0x21, 0xF9, 0x04])
    let start = try XCTUnwrap(data.range(of: marker)?.lowerBound)
    data[start + 3] |= 0x02
    await assertThrowsErrorAsync(
      try await ImageIOAnimatedImageDecoder().prepareAnimation(source: .encoded(data))
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .animationTimelineInvalid)
    }
  }

  func testGIFRejectsPlainTextGraphicRenderingBlock_IMG_ANIM_PT_026() async throws {
    let malformed = try insertingGIFPlainTextExtension(into: makeAnimatedGIF())
    await assertThrowsErrorAsync(
      try await ImageIOAnimatedImageDecoder().prepareAnimation(source: .encoded(malformed))
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .animationUnsupported)
    }
  }

  func testGIFRejectsDanglingGraphicControlExtension_IMG_ANIM_PT_023() async throws {
    let malformed = try appendingDanglingGIFGraphicControlExtension(to: makeAnimatedGIF())
    await assertThrowsErrorAsync(
      try await ImageIOAnimatedImageDecoder().prepareAnimation(source: .encoded(malformed))
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .animationTimelineInvalid)
    }
  }

}

private func duration(_ numerator: UInt32, _ denominator: UInt32) throws
  -> ImageAnimationFrameDuration
{
  try ImageAnimationFrameDuration(numerator: numerator, denominator: denominator)
}

private func decodeRequest(width: Int, height: Int) throws -> ImageDecodeRequest {
  ImageDecodeRequest(
    target: try TargetPixels(width: width, height: height),
    colorPolicy: .convertToSRGB
  )
}

private func makeAnimatedGIF() throws -> Data {
  let data = NSMutableData()
  let destination = try XCTUnwrap(
    CGImageDestinationCreateWithData(
      data,
      UTType.gif.identifier as CFString,
      2,
      nil
    )
  )
  CGImageDestinationSetProperties(
    destination,
    [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 3]] as CFDictionary
  )
  CGImageDestinationAddImage(
    destination,
    try solidImage(width: 4, height: 4, red: 255, blue: 0),
    [
      kCGImagePropertyGIFDictionary: [
        kCGImagePropertyGIFDelayTime: 0.1,
        kCGImagePropertyGIFUnclampedDelayTime: 0.1,
      ]
    ] as CFDictionary
  )
  CGImageDestinationAddImage(
    destination,
    try solidImage(width: 4, height: 4, red: 0, blue: 255),
    [
      kCGImagePropertyGIFDictionary: [
        kCGImagePropertyGIFDelayTime: 0.2,
        kCGImagePropertyGIFUnclampedDelayTime: 0.2,
      ]
    ] as CFDictionary
  )
  XCTAssertTrue(CGImageDestinationFinalize(destination))
  return data as Data
}

private func gifWithBackgroundDisposal(_ input: Data) throws -> Data {
  var bytes = [UInt8](input)
  guard bytes.count >= 13 else { throw ImageCraftError.animationTimelineInvalid }
  var offset = 13
  if bytes[10] & 0x80 != 0 { offset += 3 * (1 << (Int(bytes[10] & 0x07) + 1)) }
  while offset < bytes.count {
    let marker = bytes[offset]
    offset += 1
    if marker == 0x3B { return Data(bytes) }
    if marker == 0x21 {
      guard offset < bytes.count else { throw ImageCraftError.animationTimelineInvalid }
      let label = bytes[offset]
      offset += 1
      if label == 0xF9 {
        guard offset + 6 <= bytes.count, bytes[offset] == 4, bytes[offset + 5] == 0 else {
          throw ImageCraftError.animationTimelineInvalid
        }
        bytes[offset + 1] = (bytes[offset + 1] & 0xE3) | 0x08
        offset += 6
      } else {
        while true {
          guard offset < bytes.count else { throw ImageCraftError.animationTimelineInvalid }
          let count = Int(bytes[offset])
          offset += 1
          if count == 0 { break }
          guard offset + count <= bytes.count else {
            throw ImageCraftError.animationTimelineInvalid
          }
          offset += count
        }
      }
    } else if marker == 0x2C {
      guard offset + 9 <= bytes.count else { throw ImageCraftError.animationTimelineInvalid }
      let packed = bytes[offset + 8]
      offset += 9
      if packed & 0x80 != 0 { offset += 3 * (1 << (Int(packed & 0x07) + 1)) }
      guard offset < bytes.count else { throw ImageCraftError.animationTimelineInvalid }
      offset += 1
      while true {
        guard offset < bytes.count else { throw ImageCraftError.animationTimelineInvalid }
        let count = Int(bytes[offset])
        offset += 1
        if count == 0 { break }
        guard offset + count <= bytes.count else { throw ImageCraftError.animationTimelineInvalid }
        offset += count
      }
    } else {
      throw ImageCraftError.animationTimelineInvalid
    }
  }
  throw ImageCraftError.animationTimelineInvalid
}

private func gifWithInterlaceFlag(_ input: Data) throws -> Data {
  var bytes = [UInt8](input)
  guard bytes.count >= 13 else { throw ImageCraftError.animationTimelineInvalid }
  var offset = 13
  if bytes[10] & 0x80 != 0 { offset += 3 * (1 << (Int(bytes[10] & 0x07) + 1)) }
  var changed = false
  while offset < bytes.count {
    let marker = bytes[offset]
    offset += 1
    if marker == 0x3B { break }
    if marker == 0x21 {
      guard offset < bytes.count else { throw ImageCraftError.animationTimelineInvalid }
      offset += 1
      while true {
        guard offset < bytes.count else { throw ImageCraftError.animationTimelineInvalid }
        let count = Int(bytes[offset])
        offset += 1
        if count == 0 { break }
        guard offset + count <= bytes.count else { throw ImageCraftError.animationTimelineInvalid }
        offset += count
      }
    } else if marker == 0x2C {
      guard offset + 9 <= bytes.count else { throw ImageCraftError.animationTimelineInvalid }
      bytes[offset + 8] |= 0x40
      changed = true
      let packed = bytes[offset + 8]
      offset += 9
      if packed & 0x80 != 0 { offset += 3 * (1 << (Int(packed & 0x07) + 1)) }
      guard offset < bytes.count else { throw ImageCraftError.animationTimelineInvalid }
      offset += 1
      while true {
        guard offset < bytes.count else { throw ImageCraftError.animationTimelineInvalid }
        let count = Int(bytes[offset])
        offset += 1
        if count == 0 { break }
        guard offset + count <= bytes.count else { throw ImageCraftError.animationTimelineInvalid }
        offset += count
      }
    } else {
      throw ImageCraftError.animationTimelineInvalid
    }
  }
  guard changed else { throw ImageCraftError.animationTimelineInvalid }
  return Data(bytes)
}

private func clearingUnusedGIFTransparencyFlags(_ input: Data) throws -> Data {
  var bytes = [UInt8](input)
  guard bytes.count >= 13 else { throw ImageCraftError.animationTimelineInvalid }
  var offset = 13
  if bytes[10] & 0x80 != 0 {
    offset += 3 * (1 << (Int(bytes[10] & 0x07) + 1))
  }
  while offset < bytes.count {
    let marker = bytes[offset]
    offset += 1
    if marker == 0x3B { break }
    if marker == 0x21 {
      guard offset < bytes.count else { throw ImageCraftError.animationTimelineInvalid }
      let label = bytes[offset]
      offset += 1
      if label == 0xF9 {
        guard offset + 6 <= bytes.count, bytes[offset] == 4, bytes[offset + 5] == 0 else {
          throw ImageCraftError.animationTimelineInvalid
        }
        bytes[offset + 1] &= 0xFE
        offset += 6
      } else {
        while true {
          guard offset < bytes.count else { throw ImageCraftError.animationTimelineInvalid }
          let count = Int(bytes[offset])
          offset += 1
          if count == 0 { break }
          guard offset + count <= bytes.count else {
            throw ImageCraftError.animationTimelineInvalid
          }
          offset += count
        }
      }
    } else if marker == 0x2C {
      guard offset + 9 <= bytes.count else { throw ImageCraftError.animationTimelineInvalid }
      let packed = bytes[offset + 8]
      offset += 9
      if packed & 0x80 != 0 {
        offset += 3 * (1 << (Int(packed & 0x07) + 1))
      }
      guard offset < bytes.count else { throw ImageCraftError.animationTimelineInvalid }
      offset += 1
      while true {
        guard offset < bytes.count else { throw ImageCraftError.animationTimelineInvalid }
        let count = Int(bytes[offset])
        offset += 1
        if count == 0 { break }
        guard offset + count <= bytes.count else { throw ImageCraftError.animationTimelineInvalid }
        offset += count
      }
    } else {
      throw ImageCraftError.animationTimelineInvalid
    }
  }
  return Data(bytes)
}

private func makeSubrectReplayGIF() throws -> Data {
  try XCTUnwrap(
    Data(
      base64Encoded:
        "R0lGODlhAgACAIAAAP8AAAAA/yH/C05FVFNDQVBFMi4wAwEAAAAh+QQAAQAAACwAAAAAAgACAAACBARBEAUAIfkEAAEAAAAsAQABAAEAAQAAAgJMAQA7"
    )
  )
}

private func makePatternedAnimatedGIF(width: Int, height: Int) throws -> Data {
  let data = NSMutableData()
  let destination = try XCTUnwrap(
    CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil)
  )
  CGImageDestinationSetProperties(
    destination,
    [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
  )
  for seed in [17, 83] {
    CGImageDestinationAddImage(
      destination,
      try patternedImage(width: width, height: height, seed: seed),
      [
        kCGImagePropertyGIFDictionary: [
          kCGImagePropertyGIFDelayTime: 0.05,
          kCGImagePropertyGIFUnclampedDelayTime: 0.05,
        ]
      ] as CFDictionary
    )
  }
  XCTAssertTrue(CGImageDestinationFinalize(destination))
  return data as Data
}

private func makeTransparentAnimatedGIF() throws -> Data {
  let data = NSMutableData()
  let destination = try XCTUnwrap(
    CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil)
  )
  CGImageDestinationSetProperties(
    destination,
    [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
  )
  CGImageDestinationAddImage(
    destination,
    try solidImage(width: 4, height: 4, red: 255, blue: 0),
    [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary
  )
  CGImageDestinationAddImage(
    destination,
    try imageWithTransparentCorner(width: 4, height: 4),
    [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary
  )
  XCTAssertTrue(CGImageDestinationFinalize(destination))
  return data as Data
}

private func makeTenFrameFullBackgroundPublicAPNG() throws -> Data {
  let first = try makeSolidPNG(width: 4, height: 4, red: 17, blue: 43)
  let firstChunks = try pngChunks(first)
  let ihdr = try XCTUnwrap(firstChunks.first { $0.type == "IHDR" })
  var result = Data([137, 80, 78, 71, 13, 10, 26, 10])
  result.append(pngChunk(type: "IHDR", payload: ihdr.payload))
  result.append(pngChunk(type: "acTL", payload: be32(10) + be32(0)))
  var sequence = UInt32(0)
  for frameIndex in 0..<10 {
    let png = try makeSolidPNG(
      width: 4,
      height: 4,
      red: UInt8((frameIndex * 23 + 17) & 0xFF),
      blue: UInt8((frameIndex * 31 + 43) & 0xFF)
    )
    let payloads = try pngChunks(png).filter { $0.type == "IDAT" }.map(\.payload)
    result.append(
      pngChunk(
        type: "fcTL",
        payload: be32(sequence) + be32(4) + be32(4) + be32(0) + be32(0)
          + be16(1) + be16(10) + Data([1, 1])
      )
    )
    sequence += 1
    for payload in payloads {
      if frameIndex == 0 {
        result.append(pngChunk(type: "IDAT", payload: payload))
      } else {
        result.append(pngChunk(type: "fdAT", payload: be32(sequence) + payload))
        sequence += 1
      }
    }
  }
  result.append(pngChunk(type: "IEND", payload: Data()))
  return result
}

private func makeTenFramePublicAPNG() throws -> Data {
  let initial = try makeSolidPNG(width: 4, height: 4, red: 0, blue: 0)
  let initialChunks = try pngChunks(initial)
  let ihdr = try XCTUnwrap(initialChunks.first { $0.type == "IHDR" })
  let initialData = initialChunks.filter { $0.type == "IDAT" }.map(\.payload)
  var result = Data([137, 80, 78, 71, 13, 10, 26, 10])
  result.append(pngChunk(type: "IHDR", payload: ihdr.payload))
  result.append(pngChunk(type: "acTL", payload: be32(10) + be32(0)))
  result.append(
    pngChunk(
      type: "fcTL",
      payload: be32(0) + be32(4) + be32(4) + be32(0) + be32(0)
        + be16(1) + be16(10) + Data([0, 0])
    )
  )
  for payload in initialData {
    result.append(pngChunk(type: "IDAT", payload: payload))
  }
  var sequence = UInt32(1)
  for frameIndex in 1..<10 {
    let pixel = try makeSolidPNG(
      width: 1,
      height: 1,
      red: UInt8(frameIndex * 20),
      blue: UInt8(255 - frameIndex * 20)
    )
    let payloads = try pngChunks(pixel).filter { $0.type == "IDAT" }.map(\.payload)
    let pixelIndex = frameIndex - 1
    result.append(
      pngChunk(
        type: "fcTL",
        payload: be32(sequence) + be32(1) + be32(1)
          + be32(UInt32(pixelIndex % 4)) + be32(UInt32(pixelIndex / 4))
          + be16(1) + be16(10) + Data([0, 0])
      )
    )
    sequence += 1
    for payload in payloads {
      result.append(
        pngChunk(
          type: "fdAT",
          payload: be32(sequence) + payload
        )
      )
      sequence += 1
    }
  }
  result.append(pngChunk(type: "IEND", payload: Data()))
  return result
}

private func makeRGBAPNG() throws -> Data {
  let first = try makeSolidOpaquePNG(width: 8, height: 8, red: 255, blue: 0)
  let second = try makeSolidOpaquePNG(width: 2, height: 2, red: 0, blue: 255)
  let firstChunks = try pngChunks(first)
  let secondChunks = try pngChunks(second)
  let ihdr = try XCTUnwrap(firstChunks.first { $0.type == "IHDR" })
  let firstData = firstChunks.filter { $0.type == "IDAT" }.map(\.payload)
  let secondData = secondChunks.filter { $0.type == "IDAT" }.map(\.payload)
  var output = Data([137, 80, 78, 71, 13, 10, 26, 10])
  output.append(pngChunk(type: "IHDR", payload: ihdr.payload))
  output.append(pngChunk(type: "acTL", payload: be32(2) + be32(0)))
  output.append(
    pngChunk(
      type: "fcTL",
      payload: be32(0) + be32(8) + be32(8) + be32(0) + be32(0)
        + be16(1) + be16(10) + Data([0, 0])
    )
  )
  for payload in firstData { output.append(pngChunk(type: "IDAT", payload: payload)) }
  output.append(
    pngChunk(
      type: "fcTL",
      payload: be32(1) + be32(2) + be32(2) + be32(2) + be32(2)
        + be16(1) + be16(5) + Data([1, 1])
    )
  )
  var sequence: UInt32 = 2
  for payload in secondData {
    output.append(pngChunk(type: "fdAT", payload: be32(sequence) + payload))
    sequence += 1
  }
  output.append(pngChunk(type: "IEND", payload: Data()))
  return output
}

private func makeMultiFrameRGBAPNGWithSeparateDefaultImage() throws -> Data {
  let fallback = try makeSolidOpaquePNG(width: 2, height: 2, red: 255, blue: 0)
  let firstAnimation = try makeSolidOpaquePNG(width: 2, height: 2, red: 0, blue: 255)
  let secondAnimation = try makeSolidOpaquePNG(width: 2, height: 2, red: 255, blue: 0)
  let fallbackChunks = try pngChunks(fallback)
  let firstChunks = try pngChunks(firstAnimation)
  let secondChunks = try pngChunks(secondAnimation)
  let ihdr = try XCTUnwrap(fallbackChunks.first { $0.type == "IHDR" })
  let fallbackData = fallbackChunks.filter { $0.type == "IDAT" }.map(\.payload)
  let firstData = firstChunks.filter { $0.type == "IDAT" }.map(\.payload)
  let secondData = secondChunks.filter { $0.type == "IDAT" }.map(\.payload)

  var output = Data([137, 80, 78, 71, 13, 10, 26, 10])
  output.append(pngChunk(type: "IHDR", payload: ihdr.payload))
  output.append(pngChunk(type: "acTL", payload: be32(2) + be32(0)))
  for payload in fallbackData {
    output.append(pngChunk(type: "IDAT", payload: payload))
  }
  output.append(
    pngChunk(
      type: "fcTL",
      payload: be32(0) + be32(2) + be32(2) + be32(0) + be32(0)
        + be16(1) + be16(10) + Data([0, 0])
    )
  )
  var sequence: UInt32 = 1
  for payload in firstData {
    output.append(pngChunk(type: "fdAT", payload: be32(sequence) + payload))
    sequence += 1
  }
  output.append(
    pngChunk(
      type: "fcTL",
      payload: be32(sequence) + be32(2) + be32(2) + be32(0) + be32(0)
        + be16(1) + be16(10) + Data([0, 0])
    )
  )
  sequence += 1
  for payload in secondData {
    output.append(pngChunk(type: "fdAT", payload: be32(sequence) + payload))
    sequence += 1
  }
  output.append(pngChunk(type: "IEND", payload: Data()))
  return output
}

private func makeAPNG() throws -> Data {
  let first = try makeSolidPNG(width: 8, height: 8, red: 255, blue: 0)
  let second = try makeSolidPNG(width: 2, height: 2, red: 0, blue: 255)
  let firstChunks = try pngChunks(first)
  let secondChunks = try pngChunks(second)
  let ihdr = try XCTUnwrap(firstChunks.first { $0.type == "IHDR" })
  let firstData = firstChunks.filter { $0.type == "IDAT" }.map(\.payload)
  let secondData = secondChunks.filter { $0.type == "IDAT" }.map(\.payload)
  var output = Data([137, 80, 78, 71, 13, 10, 26, 10])
  output.append(pngChunk(type: "IHDR", payload: ihdr.payload))
  output.append(pngChunk(type: "acTL", payload: be32(2) + be32(3)))
  output.append(
    pngChunk(
      type: "fcTL",
      payload: be32(0) + be32(8) + be32(8) + be32(0) + be32(0)
        + be16(1) + be16(10) + Data([0, 0])
    )
  )
  for payload in firstData { output.append(pngChunk(type: "IDAT", payload: payload)) }
  output.append(
    pngChunk(
      type: "fcTL",
      payload: be32(1) + be32(2) + be32(2) + be32(2) + be32(2)
        + be16(1) + be16(5) + Data([1, 1])
    )
  )
  var sequence: UInt32 = 2
  for payload in secondData {
    output.append(pngChunk(type: "fdAT", payload: be32(sequence) + payload))
    sequence += 1
  }
  output.append(pngChunk(type: "IEND", payload: Data()))
  return output
}

private func makeAPNGWithSeparateDefaultImage() throws -> Data {
  let fallback = try makeSolidPNG(width: 2, height: 2, red: 255, blue: 0)
  let animation = try makeSolidPNG(width: 2, height: 2, red: 0, blue: 255)
  let fallbackChunks = try pngChunks(fallback)
  let animationChunks = try pngChunks(animation)
  let ihdr = try XCTUnwrap(fallbackChunks.first { $0.type == "IHDR" })
  let fallbackData = fallbackChunks.filter { $0.type == "IDAT" }.map(\.payload)
  let animationData = animationChunks.filter { $0.type == "IDAT" }.map(\.payload)

  var output = Data([137, 80, 78, 71, 13, 10, 26, 10])
  output.append(pngChunk(type: "IHDR", payload: ihdr.payload))
  output.append(pngChunk(type: "acTL", payload: be32(1) + be32(0)))
  for payload in fallbackData {
    output.append(pngChunk(type: "IDAT", payload: payload))
  }
  output.append(
    pngChunk(
      type: "fcTL",
      payload: be32(0) + be32(2) + be32(2) + be32(0) + be32(0)
        + be16(1) + be16(10) + Data([0, 0])
    )
  )
  var sequence: UInt32 = 1
  for payload in animationData {
    output.append(pngChunk(type: "fdAT", payload: be32(sequence) + payload))
    sequence += 1
  }
  output.append(pngChunk(type: "IEND", payload: Data()))
  return output
}

private func makeMultiFrameAPNGWithSeparateDefaultImage() throws -> Data {
  let fallback = try makeSolidPNG(width: 2, height: 2, red: 255, blue: 0)
  let firstAnimation = try makeSolidPNG(width: 2, height: 2, red: 0, blue: 255)
  let secondAnimation = try makeSolidPNG(width: 2, height: 2, red: 255, blue: 0)
  let fallbackChunks = try pngChunks(fallback)
  let firstChunks = try pngChunks(firstAnimation)
  let secondChunks = try pngChunks(secondAnimation)
  let ihdr = try XCTUnwrap(fallbackChunks.first { $0.type == "IHDR" })
  let fallbackData = fallbackChunks.filter { $0.type == "IDAT" }.map(\.payload)
  let firstData = firstChunks.filter { $0.type == "IDAT" }.map(\.payload)
  let secondData = secondChunks.filter { $0.type == "IDAT" }.map(\.payload)

  var output = Data([137, 80, 78, 71, 13, 10, 26, 10])
  output.append(pngChunk(type: "IHDR", payload: ihdr.payload))
  output.append(pngChunk(type: "acTL", payload: be32(2) + be32(0)))
  for payload in fallbackData {
    output.append(pngChunk(type: "IDAT", payload: payload))
  }
  output.append(
    pngChunk(
      type: "fcTL",
      payload: be32(0) + be32(2) + be32(2) + be32(0) + be32(0)
        + be16(1) + be16(10) + Data([0, 0])
    )
  )
  var sequence: UInt32 = 1
  for payload in firstData {
    output.append(pngChunk(type: "fdAT", payload: be32(sequence) + payload))
    sequence += 1
  }
  output.append(
    pngChunk(
      type: "fcTL",
      payload: be32(sequence) + be32(2) + be32(2) + be32(0) + be32(0)
        + be16(1) + be16(10) + Data([0, 0])
    )
  )
  sequence += 1
  for payload in secondData {
    output.append(pngChunk(type: "fdAT", payload: be32(sequence) + payload))
    sequence += 1
  }
  output.append(pngChunk(type: "IEND", payload: Data()))
  return output
}

private func insertingPNGChunk(
  in data: Data,
  after precedingType: String,
  type: String,
  payload: Data
) throws -> Data {
  let chunks = try pngChunks(data)
  var result = Data(data.prefix(8))
  var inserted = false
  for chunk in chunks {
    result.append(pngChunk(type: chunk.type, payload: chunk.payload))
    if chunk.type == precedingType, !inserted {
      result.append(pngChunk(type: type, payload: payload))
      inserted = true
    }
  }
  guard inserted else { throw ImageCraftError.animationTimelineInvalid }
  return result
}

private func insertingGIFPlainTextExtension(into data: Data) throws -> Data {
  guard let imageStart = data.firstIndex(of: 0x2C) else {
    throw ImageCraftError.animationTimelineInvalid
  }
  let header: [UInt8] = [
    0x21, 0x01, 0x0C,
    0x00, 0x00, 0x00, 0x00,
    0x04, 0x00, 0x04, 0x00,
    0x01, 0x01, 0x00, 0x01,
    0x01, 0x41, 0x00,
  ]
  var result = Data(data.prefix(upTo: imageStart))
  result.append(contentsOf: header)
  result.append(data.suffix(from: imageStart))
  return result
}

private func appendingDanglingGIFGraphicControlExtension(to data: Data) throws -> Data {
  guard data.last == 0x3B else { throw ImageCraftError.animationTimelineInvalid }
  var result = Data(data.dropLast())
  result.append(contentsOf: [0x21, 0xF9, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00])
  result.append(0x3B)
  return result
}

private func makeAPNGWithFDATReplacingFirstIDAT(_ data: Data) throws -> Data {
  let chunks = try pngChunks(data)
  var result = Data(data.prefix(8))
  var replaced = false
  for chunk in chunks {
    if chunk.type == "IDAT", !replaced {
      result.append(
        pngChunk(
          type: "fdAT",
          payload: be32(1) + chunk.payload
        )
      )
      replaced = true
    } else {
      result.append(pngChunk(type: chunk.type, payload: chunk.payload))
    }
  }
  guard replaced else { throw ImageCraftError.animationTimelineInvalid }
  return result
}

private func firstGIFImageCodeSizeOffset(_ data: Data) throws -> Int {
  guard data.count >= 13,
    data.starts(with: Data("GIF".utf8))
  else { throw ImageCraftError.animationTimelineInvalid }
  var offset = 13
  let logicalPacked = data[10]
  if logicalPacked & 0x80 != 0 {
    offset += 3 * (1 << (Int(logicalPacked & 0x07) + 1))
  }
  while offset < data.count {
    let marker = data[offset]
    offset += 1
    switch marker {
    case 0x21:
      guard offset < data.count else { throw ImageCraftError.animationTimelineInvalid }
      offset += 1
      while true {
        guard offset < data.count else { throw ImageCraftError.animationTimelineInvalid }
        let length = Int(data[offset])
        offset += 1
        if length == 0 { break }
        guard offset + length <= data.count else {
          throw ImageCraftError.animationTimelineInvalid
        }
        offset += length
      }
    case 0x2C:
      guard offset + 9 <= data.count else {
        throw ImageCraftError.animationTimelineInvalid
      }
      let packed = data[offset + 8]
      offset += 9
      if packed & 0x80 != 0 {
        offset += 3 * (1 << (Int(packed & 0x07) + 1))
      }
      guard offset < data.count else { throw ImageCraftError.animationTimelineInvalid }
      return offset
    default:
      throw ImageCraftError.animationTimelineInvalid
    }
  }
  throw ImageCraftError.animationTimelineInvalid
}

private func corruptPNGChunkCRC(
  _ data: Data,
  type: String,
  occurrence: Int
) throws -> Data {
  var result = data
  var offset = 8
  var matched = 0
  while offset < result.count {
    guard offset + 12 <= result.count else {
      throw ImageCraftError.animationTimelineInvalid
    }
    let length = Int(readBE32(result, at: offset))
    let typeData = result[(offset + 4)..<(offset + 8)]
    let currentType = String(decoding: typeData, as: UTF8.self)
    let payloadEnd = offset + 8 + length
    guard payloadEnd + 4 <= result.count else {
      throw ImageCraftError.animationTimelineInvalid
    }
    if currentType == type {
      if matched == occurrence {
        result[payloadEnd + 3] ^= 0x01
        return result
      }
      matched += 1
    }
    offset = payloadEnd + 4
  }
  throw ImageCraftError.animationTimelineInvalid
}

private func makeAPNGWithNonconsecutiveIDAT(_ data: Data) throws -> Data {
  let chunks = try pngChunks(data)
  var result = Data(data.prefix(8))
  var split = false
  for chunk in chunks {
    if chunk.type == "IDAT", !split {
      guard chunk.payload.count >= 2 else {
        throw ImageCraftError.animationTimelineInvalid
      }
      let midpoint = chunk.payload.count / 2
      result.append(
        pngChunk(
          type: "IDAT",
          payload: Data(chunk.payload.prefix(midpoint))
        )
      )
      result.append(
        pngChunk(
          type: "tEXt",
          payload: Data([0x6B, 0x00, 0x76])
        )
      )
      result.append(
        pngChunk(
          type: "IDAT",
          payload: Data(chunk.payload.dropFirst(midpoint))
        )
      )
      split = true
    } else {
      result.append(pngChunk(type: chunk.type, payload: chunk.payload))
    }
  }
  guard split else { throw ImageCraftError.animationTimelineInvalid }
  return result
}

private func jpegWithComment(_ data: Data, byteCount: Int) throws -> Data {
  guard data.count >= 2, data[0] == 0xFF, data[1] == 0xD8,
    byteCount >= 0, byteCount <= Int(UInt16.max) - 2
  else { throw ImageCraftError.unsupportedOrCorruptImage }
  let segmentLength = UInt16(byteCount + 2)
  var result = Data(data.prefix(2))
  result.append(contentsOf: [
    0xFF,
    0xFE,
    UInt8(segmentLength >> 8),
    UInt8(segmentLength & 0xFF),
  ])
  result.append(Data(repeating: 0x41, count: byteCount))
  result.append(data.dropFirst(2))
  return result
}

private func mutatePNGChunk(
  _ data: Data,
  type: String,
  occurrence: Int,
  mutate: (inout Data) -> Void
) throws -> Data {
  var result = Data(data.prefix(8))
  var offset = 8
  var matched = 0
  var mutated = false
  while offset < data.count {
    let length = Int(readBE32(data, at: offset))
    let typeData = Data(data[(offset + 4)..<(offset + 8)])
    let currentType = String(decoding: typeData, as: UTF8.self)
    let payloadStart = offset + 8
    let payloadEnd = payloadStart + length
    var payload = Data(data[payloadStart..<payloadEnd])
    if currentType == type {
      if matched == occurrence {
        mutate(&payload)
        mutated = true
      }
      matched += 1
    }
    result.append(pngChunk(type: currentType, payload: payload))
    offset = payloadEnd + 4
  }
  guard mutated else { throw ImageCraftError.animationTimelineInvalid }
  return result
}

private struct PNGChunk {
  let type: String
  let payload: Data
}

private func pngChunks(_ data: Data) throws -> [PNGChunk] {
  var offset = 8
  var chunks: [PNGChunk] = []
  while offset < data.count {
    guard offset + 12 <= data.count else { throw ImageCraftError.animationTimelineInvalid }
    let length = Int(readBE32(data, at: offset))
    let typeData = data[(offset + 4)..<(offset + 8)]
    let type = String(decoding: typeData, as: UTF8.self)
    let payloadStart = offset + 8
    let payloadEnd = payloadStart + length
    guard payloadEnd + 4 <= data.count else {
      throw ImageCraftError.animationTimelineInvalid
    }
    chunks.append(PNGChunk(type: type, payload: data[payloadStart..<payloadEnd]))
    offset = payloadEnd + 4
  }
  return chunks
}

private func pngChunk(type: String, payload: Data) -> Data {
  let typeData = Data(type.utf8)
  var result = be32(UInt32(payload.count))
  result.append(typeData)
  result.append(payload)
  result.append(be32(crc32(typeData + payload)))
  return result
}

private func crc32(_ data: Data) -> UInt32 {
  var crc = UInt32.max
  for byte in data {
    crc ^= UInt32(byte)
    for _ in 0..<8 {
      crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0xEDB8_8320
    }
  }
  return crc ^ UInt32.max
}

private func be16(_ value: UInt16) -> Data {
  Data([UInt8(value >> 8), UInt8(value & 0xff)])
}

private func be32(_ value: UInt32) -> Data {
  Data([
    UInt8((value >> 24) & 0xff),
    UInt8((value >> 16) & 0xff),
    UInt8((value >> 8) & 0xff),
    UInt8(value & 0xff),
  ])
}

private func readBE32(_ data: Data, at offset: Int) -> UInt32 {
  UInt32(data[offset]) << 24
    | UInt32(data[offset + 1]) << 16
    | UInt32(data[offset + 2]) << 8
    | UInt32(data[offset + 3])
}

private func makeSolidOpaquePNG(
  width: Int,
  height: Int,
  red: UInt8,
  blue: UInt8
) throws -> Data {
  try encodedImage(
    type: UTType.png.identifier as CFString,
    image: solidOpaqueImage(width: width, height: height, red: red, blue: blue)
  )
}

private func makeSolidPNG(
  width: Int,
  height: Int,
  red: UInt8,
  blue: UInt8
) throws -> Data {
  try encodedImage(
    type: UTType.png.identifier as CFString,
    image: solidImage(width: width, height: height, red: red, blue: blue)
  )
}

private func makeJPEG(
  width: Int,
  height: Int,
  red: UInt8,
  blue: UInt8
) throws -> Data {
  try encodedImage(
    type: UTType.jpeg.identifier as CFString,
    image: solidImage(width: width, height: height, red: red, blue: blue)
  )
}

private func encodedImage(type: CFString, image: CGImage) throws -> Data {
  let data = NSMutableData()
  let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type, 1, nil))
  CGImageDestinationAddImage(destination, image, nil)
  XCTAssertTrue(CGImageDestinationFinalize(destination))
  return data as Data
}

private func solidOpaqueImage(
  width: Int,
  height: Int,
  red: UInt8,
  blue: UInt8
) throws -> CGImage {
  let rowBytes = width * 3
  var pixels = Data(count: rowBytes * height)
  for offset in stride(from: 0, to: pixels.count, by: 3) {
    pixels[offset] = red
    pixels[offset + 2] = blue
  }
  let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
  return try XCTUnwrap(
    CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 24,
      bytesPerRow: rowBytes,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  )
}

private func solidImage(
  width: Int,
  height: Int,
  red: UInt8,
  blue: UInt8
) throws -> CGImage {
  let rowBytes = width * 4
  var pixels = Data(count: rowBytes * height)
  for offset in stride(from: 0, to: pixels.count, by: 4) {
    pixels[offset] = red
    pixels[offset + 2] = blue
    pixels[offset + 3] = 255
  }
  let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
  return try XCTUnwrap(
    CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: rowBytes,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  )
}

private func patternedImage(width: Int, height: Int, seed: Int) throws -> CGImage {
  let rowBytes = width * 4
  var pixels = Data(count: rowBytes * height)
  pixels.withUnsafeMutableBytes { raw in
    let bytes = raw.bindMemory(to: UInt8.self)
    for y in 0..<height {
      for x in 0..<width {
        let offset = y * rowBytes + x * 4
        bytes[offset] = UInt8((x * 29 + y * 7 + seed) & 0xFF)
        bytes[offset + 1] = UInt8((x * 11 + y * 31 + seed * 3) & 0xFF)
        bytes[offset + 2] = UInt8((x * 17 + y * 13 + seed * 5) & 0xFF)
        bytes[offset + 3] = 255
      }
    }
  }
  let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
  return try XCTUnwrap(
    CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    )
  )
}

private func imageWithTransparentCorner(width: Int, height: Int) throws -> CGImage {
  let rowBytes = width * 4
  var pixels = Data(count: rowBytes * height)
  pixels.withUnsafeMutableBytes { raw in
    let bytes = raw.bindMemory(to: UInt8.self)
    for pixel in 0..<(width * height) {
      let offset = pixel * 4
      bytes[offset] = 0
      bytes[offset + 1] = 0
      bytes[offset + 2] = 255
      bytes[offset + 3] = pixel == 0 ? 0 : 255
    }
  }
  let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
  return try XCTUnwrap(
    CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    )
  )
}

private func normalizedPixelDigest(_ image: CGImage) throws -> String {
  guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
    throw ImageCraftError.decodeFailed
  }
  let bytesPerRow = image.width * 4
  var pixels = Data(count: bytesPerRow * image.height)
  let rendered = pixels.withUnsafeMutableBytes { raw -> Bool in
    guard let address = raw.baseAddress,
      let context = CGContext(
        data: address,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue
      )
    else { return false }
    context.setBlendMode(.copy)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return true
  }
  guard rendered else { throw ImageCraftError.decodeFailed }
  return SHA256.hash(data: pixels).map { String(format: "%02x", $0) }.joined()
}

private func redComponent(_ image: CGImage, x: Int, y: Int) throws -> UInt8 {
  try pixel(image, x: x, y: y)[0]
}

private func blueComponent(_ image: CGImage, x: Int, y: Int) throws -> UInt8 {
  try pixel(image, x: x, y: y)[2]
}

private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
  guard image.width > 0, image.height > 0,
    (0..<image.width).contains(x),
    (0..<image.height).contains(y),
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
  else { throw ImageCraftError.decodeFailed }
  let bytesPerRow = image.width * 4
  var pixels = [UInt8](repeating: 0, count: bytesPerRow * image.height)
  guard
    let context = CGContext(
      data: &pixels,
      width: image.width,
      height: image.height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue
    )
  else { throw ImageCraftError.decodeFailed }
  context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
  let offset = y * bytesPerRow + x * 4
  return Array(pixels[offset..<(offset + 4)])
}

private func assertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  _ verify: (any Error) -> Void,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("Expected error", file: file, line: line)
  } catch {
    verify(error)
  }
}

private final class AnimationOperationGate: @unchecked Sendable {
  let firstStarted = DispatchSemaphore(value: 0)
  let allowFirstToFinish = DispatchSemaphore(value: 0)
  let secondStarted = DispatchSemaphore(value: 0)

  private let lock = NSLock()
  private var invocationCount = 0

  func beforeOperation() {
    let invocation = lock.withLock {
      invocationCount += 1
      return invocationCount
    }
    if invocation == 1 {
      firstStarted.signal()
      _ = allowFirstToFinish.wait(timeout: .now() + 5)
    } else if invocation == 2 {
      secondStarted.signal()
    }
  }
}
