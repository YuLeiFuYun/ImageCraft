import Foundation
import CryptoKit
import XCTest

@testable import ImageCraftCore
@testable import ImageCraftImageIO

final class JPEGIndependentProgressive420DecoderTests: XCTestCase {
  func testRetainedProgressive420OwnsActualCoefficientsAndExactRenderState() throws {
    let data = try fixture(named: "jpeg-progressive-420.jpg")
    let statePlan = try JPEGIndependentProgressive420StatePlan.inspect(data)
    XCTAssertEqual(statePlan.width, 23)
    XCTAssertEqual(statePlan.height, 13)
    XCTAssertEqual(statePlan.mcuColumns, 2)
    XCTAssertEqual(statePlan.mcuRows, 1)
    XCTAssertEqual(statePlan.yActualWidthBlocks, 3)
    XCTAssertEqual(statePlan.yActualHeightBlocks, 2)
    XCTAssertEqual(statePlan.yPaddedWidthBlocks, 4)
    XCTAssertEqual(statePlan.yPaddedHeightBlocks, 2)
    XCTAssertEqual(statePlan.yCoefficientBytes, 768)
    XCTAssertEqual(statePlan.chromaCoefficientBytesPerComponent, 256)
    XCTAssertEqual(statePlan.coefficientStateBytes, 1_280)
    XCTAssertEqual(statePlan.rowStateBytes, 2_176)
    XCTAssertEqual(JPEGIndependentProgressive420StatePlan.persistentBaseFixedStateByteCount, 288)
    XCTAssertEqual(JPEGIndependentProgressive420StatePlan.maximumHuffmanStateByteCount, 2_176)
    XCTAssertEqual(JPEGIndependentProgressive420StatePlan.persistentFixedStateByteCount, 2_464)
    XCTAssertEqual(JPEGIndependentProgressive420StatePlan.quantizationSourceStateByteCount, 256)
    XCTAssertEqual(JPEGIndependentProgressive420StatePlan.renderFixedScratchByteCount, 512)
    XCTAssertEqual(statePlan.persistentBaseStateBytes, 1_568)
    XCTAssertEqual(statePlan.persistentStateBytes, 3_744)
    XCTAssertEqual(statePlan.renderScratchBytes, 2_688)
    XCTAssertEqual(statePlan.persistentStateBytes + statePlan.renderScratchBytes, statePlan.totalStateBytes)
    XCTAssertEqual(
      JPEGIndependentProgressive420StatePlan.fixedStateByteCount,
      JPEGIndependentProgressive420StatePlan.persistentFixedStateByteCount
        + JPEGIndependentProgressive420StatePlan.renderFixedScratchByteCount
    )
    XCTAssertEqual(statePlan.totalStateBytes, 6_432)
    XCTAssertTrue(statePlan.usesFancyGlobalContext)

    let exactCharge = 23 * 13 * 3 + statePlan.totalStateBytes
    XCTAssertEqual(exactCharge, 7_329)
    XCTAssertThrowsError(
      try JPEGIndependentProgressive420Decoder(
        maximumOperationByteCharge: exactCharge - 1
      ).decode(data)
    ) { error in
      XCTAssertEqual(
        error as? JPEGIndependentProgressive420Error,
        .operationBudgetExceeded(requiredBytes: exactCharge, maximumBytes: exactCharge - 1)
      )
    }

    var observedCoefficientCount = 0
    var observedCoefficientData = Data()
    let decoded = try JPEGIndependentProgressive420Decoder(
      maximumOperationByteCharge: exactCharge
    ).decode(data) { coefficients in
      observedCoefficientCount = coefficients.count
      observedCoefficientData = Data(
        bytes: coefficients.baseAddress!,
        count: coefficients.count * MemoryLayout<Int16>.stride
      )
    }
    XCTAssertEqual(observedCoefficientCount * MemoryLayout<Int16>.stride, 1_280)
    XCTAssertEqual(observedCoefficientData.count, statePlan.coefficientStateBytes)
    XCTAssertEqual(decoded.width, 23)
    XCTAssertEqual(decoded.height, 13)
    XCTAssertEqual(decoded.rgb.count, 897)
    XCTAssertEqual(decoded.scanCount, 10)
    XCTAssertEqual(decoded.statePlan, statePlan)
    XCTAssertEqual(decoded.operationByteCharge, exactCharge)

    var previewScans: [Int] = []
    var previewBackingAddresses: [UInt] = []
    var finalPreview = Data()
    let previewed = try JPEGIndependentProgressive420Decoder(
      maximumOperationByteCharge: exactCharge
    ).decode(
      data,
      scanPreviewObserver: { scan, pixels in
        previewScans.append(scan)
        previewBackingAddresses.append(UInt(bitPattern: pixels.baseAddress!))
        if scan == 10 {
          finalPreview = Data(bytes: pixels.baseAddress!, count: pixels.count)
        }
      },
      finalCoefficientObserver: nil
    )
    XCTAssertEqual(previewScans, Array(1...10))
    XCTAssertEqual(Set(previewBackingAddresses).count, 1)
    XCTAssertEqual(finalPreview, previewed.rgb)
    XCTAssertEqual(previewed.operationByteCharge, exactCharge)
  }

  func testPersistentCoefficientPlaneExcludesPaddedYDummyBlocks() throws {
    let data = try fixture(named: "jpeg-progressive-420.jpg")
    let plan = try JPEGIndependentProgressive420StatePlan.inspect(data)
    XCTAssertEqual(plan.yActualWidthBlocks, 3)
    XCTAssertEqual(plan.yActualHeightBlocks, 2)
    XCTAssertEqual(plan.yPaddedWidthBlocks, 4)
    XCTAssertEqual(plan.yPaddedHeightBlocks, 2)
    XCTAssertEqual(plan.yCoefficientBytes, 3 * 2 * 128)
    XCTAssertEqual(plan.chromaCoefficientBytesPerComponent, 2 * 1 * 128)
    XCTAssertEqual(plan.coefficientStateBytes, 1_280)
  }

  func testPersistentComponentQuantizationUsesEightBitStorageAndRenderOnlyWideningScratch() throws {
    let data = try fixture(named: "jpeg-progressive-420.jpg")
    let plan = try JPEGIndependentProgressive420StatePlan.inspect(data)

    // The qualified decoder accepts only 8-bit DQT precision, so three bound component tables need
    // only 3*64 bytes across scans. IDCT's UInt16 view is a render-only widening scratch.
    XCTAssertEqual(
      JPEGIndependentProgressive420StatePlan.persistentBaseFixedStateByteCount
        - JPEGIndependentProgressive420StatePlan.progressionStateByteCount,
      3 * 64
    )
    XCTAssertEqual(JPEGIndependentProgressive420StatePlan.renderFixedScratchByteCount, 512)
    XCTAssertEqual(plan.persistentBaseStateBytes, 1_568)
    XCTAssertEqual(plan.persistentStateBytes, 3_744)
    XCTAssertEqual(plan.renderScratchBytes, 2_688)
    XCTAssertEqual(plan.totalStateBytes, 6_432)

    let outputByteCount = plan.width * plan.height * 3
    let sessionPeak = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(
        statePlan: plan,
        outputByteCount: outputByteCount,
        previewCadence: .everyCompletedScan
      )
    XCTAssertEqual(sessionPeak, 7_743)
  }

  func testProgressionStateUsesFourBitSemanticStorageAcrossScans() throws {
    let data = try fixture(named: "jpeg-progressive-420.jpg")
    let plan = try JPEGIndependentProgressive420StatePlan.inspect(data)

    // Each of the 3*64 progression entries has exactly 15 semantic states in the qualified domain:
    // unseen plus successive-low 0...13. Two entries therefore fit in one byte without weakening
    // the scan-order authority.
    XCTAssertEqual(JPEGIndependentProgressive420StatePlan.progressionStateByteCount, 96)
    for value in -1...13 {
      let nibble = try XCTUnwrap(
        JPEGIndependentProgressive420StatePlan.progressionNibble(for: value)
      )
      XCTAssertLessThan(nibble, 16)
      XCTAssertEqual(
        JPEGIndependentProgressive420StatePlan.progressionValue(forNibble: nibble),
        Int8(value)
      )
    }
    XCTAssertNil(JPEGIndependentProgressive420StatePlan.progressionNibble(for: 14))
    XCTAssertNil(JPEGIndependentProgressive420StatePlan.progressionValue(forNibble: 0x0E))
    XCTAssertNil(JPEGIndependentProgressive420StatePlan.progressionValue(forNibble: 0x1F))
    XCTAssertEqual(JPEGIndependentProgressive420StatePlan.persistentBaseFixedStateByteCount, 288)
    XCTAssertEqual(JPEGIndependentProgressive420StatePlan.persistentFixedStateByteCount, 2_464)
    XCTAssertEqual(plan.persistentBaseStateBytes, 1_568)
    XCTAssertEqual(plan.persistentStateBytes, 3_744)
    XCTAssertEqual(plan.renderScratchBytes, 2_688)
    XCTAssertEqual(plan.totalStateBytes, 6_432)

    let outputByteCount = plan.width * plan.height * 3
    XCTAssertEqual(outputByteCount + plan.totalStateBytes, 7_329)
    let sessionPeak = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(
        statePlan: plan,
        outputByteCount: outputByteCount,
        previewCadence: .everyCompletedScan
      )
    XCTAssertEqual(sessionPeak, 7_743)
  }

  func testDuplicateFirstScanFailsClosedAfterProgressionHasAlreadyBeenEstablished() throws {
    let control = try sessionStressFixture(
      named: "canonical-zero-23x13-q75-progressive-420.jpg"
    )
    let hostile = try duplicatingFirstScan(in: control)
    let plan = try JPEGIndependentProgressive420StatePlan.inspect(control)
    let outputByteCount = plan.width * plan.height * 3
    let oneShotCharge = outputByteCount + plan.totalStateBytes

    // This control deliberately uses four spectral-selection scans with Ah=0/Al=0 throughout.
    // Once the first DC scan establishes progression=0 for all three components, repeating that
    // same Ah=0 scan would be a second "first" scan over already-established coefficients. The
    // narrow ImageCraft backend treats that non-monotone progression as unsupported semantics even
    // though permissive JPEG decoders may accept it and reproduce the same final pixels.
    let decoded = try JPEGIndependentProgressive420Decoder(
      maximumOperationByteCharge: oneShotCharge
    ).decode(control)
    XCTAssertEqual(decoded.scanCount, 4)

    XCTAssertThrowsError(
      try JPEGIndependentProgressive420Decoder(
        maximumOperationByteCharge: oneShotCharge
      ).decode(hostile)
    ) { error in
      XCTAssertEqual(
        error as? JPEGIndependentProgressive420Error,
        .unsupportedSourceSemantics
      )
    }

    let session = try JPEGIndependentProgressive420Decoder.IncrementalSession(
      maximumCodecOwnedByteCharge: 1_000_000,
      previewCadence: .finalOnly
    )
    XCTAssertThrowsError(try session.append(hostile)) { error in
      XCTAssertEqual(
        error as? JPEGIndependentProgressive420Error,
        .unsupportedSourceSemantics
      )
    }
    XCTAssertEqual(session.snapshot().phase, .terminal)
    XCTAssertEqual(session.snapshot().resourceLedger, .terminal)
  }

  func testEXIFOrientationAuthorityFailsClosedBeforeIndependentRasterSemantics() throws {
    let control = try fixture(named: "jpeg-progressive-420.jpg")
    let exif = Data([
      0x45, 0x78, 0x69, 0x66, 0x00, 0x00,
      0x49, 0x49, 0x2A, 0x00,
      0x08, 0x00, 0x00, 0x00,
      0x01, 0x00,
      0x12, 0x01,
      0x03, 0x00,
      0x01, 0x00, 0x00, 0x00,
      0x06, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00
    ])
    let hostile = try insertingAPPAfterFirstSegment(marker: 0xE1, payload: exif, into: control)
    let imageIOProbe = try ImageIOImageDecoder().probe(data: hostile, limits: .coreV1)
    XCTAssertEqual(imageIOProbe.orientation, 6)
    XCTAssertEqual(imageIOProbe.pixelWidth, 13)
    XCTAssertEqual(imageIOProbe.pixelHeight, 23)

    XCTAssertThrowsError(
      try JPEGIndependentProgressive420Decoder(maximumOperationByteCharge: 1_000_000)
        .decode(hostile)
    ) { error in
      XCTAssertEqual(
        error as? JPEGIndependentProgressive420Error,
        .unsupportedSourceSemantics
      )
    }
    let session = try JPEGIndependentProgressive420Decoder.IncrementalSession(
      maximumCodecOwnedByteCharge: 1_000_000
    )
    XCTAssertThrowsError(try session.append(hostile)) { error in
      XCTAssertEqual(
        error as? JPEGIndependentProgressive420Error,
        .unsupportedSourceSemantics
      )
    }
    XCTAssertEqual(session.snapshot().phase, .terminal)
  }

  func testMPFAuxiliaryAuthorityFailsClosed() throws {
    let control = try fixture(named: "jpeg-progressive-420.jpg")
    let hostile = try insertingAPPAfterFirstSegment(
      marker: 0xE2,
      payload: Data([0x4D, 0x50, 0x46, 0x00, 0x00, 0x00, 0x00, 0x00]),
      into: control
    )
    XCTAssertThrowsError(
      try JPEGIndependentProgressive420Decoder(maximumOperationByteCharge: 1_000_000)
        .decode(hostile)
    ) { error in
      XCTAssertEqual(
        error as? JPEGIndependentProgressive420Error,
        .unsupportedSourceSemantics
      )
    }
    let session = try JPEGIndependentProgressive420Decoder.IncrementalSession(
      maximumCodecOwnedByteCharge: 1_000_000
    )
    XCTAssertThrowsError(try session.append(hostile)) { error in
      XCTAssertEqual(
        error as? JPEGIndependentProgressive420Error,
        .unsupportedSourceSemantics
      )
    }
    XCTAssertEqual(session.snapshot().phase, .terminal)
  }

  func testIncrementalMetadataByteCountMatchesSharedJPEGInspectorWithoutRetainingPayload() throws {
    let control = try fixture(named: "jpeg-progressive-420.jpg")
    let controlInspection = try EncodedImageSecurityInspector.inspect(
      control,
      maximumMetadataBytes: DecodeLimits.coreV1.maximumMetadataBytes,
      materializePNGICCProfile: false,
      materializeJPEGICCProfile: false
    )
    var enriched = try insertingAPPAfterFirstSegment(
      marker: 0xED,
      payload: Data(repeating: 0x41, count: 31),
      into: control
    )
    enriched = try insertingAPPAfterFirstSegment(
      marker: 0xED,
      payload: Data(repeating: 0x42, count: 17),
      into: enriched
    )
    let inspection = try EncodedImageSecurityInspector.inspect(
      enriched,
      maximumMetadataBytes: DecodeLimits.coreV1.maximumMetadataBytes,
      materializePNGICCProfile: false,
      materializeJPEGICCProfile: false
    )
    XCTAssertEqual(inspection.metadataByteCount, controlInspection.metadataByteCount + 48)

    let plan = try JPEGIndependentProgressive420StatePlan.inspect(enriched)
    let charge = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(
        statePlan: plan,
        outputByteCount: plan.width * plan.height * 3,
        previewCadence: .finalOnly
      )
    let session = try JPEGIndependentProgressive420Decoder.IncrementalSession(
      maximumCodecOwnedByteCharge: charge,
      previewCadence: .finalOnly
    )
    var offset = 0
    while offset < enriched.count {
      let end = min(enriched.count, offset + 7)
      _ = try session.append(enriched.subdata(in: offset..<end))
      offset = end
    }
    let ready = session.snapshot()
    XCTAssertEqual(ready.phase, .complete)
    XCTAssertEqual(ready.metadataByteCount, inspection.metadataByteCount)
    XCTAssertEqual(ready.retainedTransportBytes, 0)
    XCTAssertEqual(ready.codecOwnedByteCharge, plan.width * plan.height * 3)
  }

  func testPersistentHuffmanStorageChargesOnlyPresentTablePayloads() throws {
    let data = try fixture(named: "jpeg-progressive-420.jpg")
    let plan = try JPEGIndependentProgressive420StatePlan.inspect(data)
    let outputByteCount = plan.width * plan.height * 3
    let sessionCharge = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(
        statePlan: plan,
        outputByteCount: outputByteCount,
        previewCadence: .everyCompletedScan
      )
    let session = try JPEGIndependentProgressive420Decoder.IncrementalSession(
      maximumCodecOwnedByteCharge: sessionCharge,
      previewCadence: .everyCompletedScan
    )
    _ = try session.append(data.dropLast(2))
    let complete = session.snapshot()
    XCTAssertEqual(complete.phase, .awaitingMarker)

    // Final retained DHT authority in this source is four slots:
    // DC0 16+4, DC1 16+3, AC0 16+10, AC1 16+9 = 90 bytes. Empty future slots and each
    // slot's unused 256-symbol capacity are not current codec-owned state.
    let retainedHuffmanPayloadBytes = 90
    let persistentBaseBytes =
      plan.coefficientStateBytes
      + 3 * 64
      + JPEGIndependentProgressive420StatePlan.progressionStateByteCount
    XCTAssertEqual(persistentBaseBytes, 1_568)
    let expectedRetained =
      JPEGIndependentProgressive420Decoder.IncrementalSession.transportCapacityBytes
      + persistentBaseBytes
      + retainedHuffmanPayloadBytes
      + outputByteCount
    XCTAssertEqual(expectedRetained, 2_969)
    XCTAssertEqual(complete.retainedHuffmanTableBytes, retainedHuffmanPayloadBytes)
    XCTAssertEqual(complete.maximumObservedHuffmanTableBytes, 95)
    XCTAssertNil(complete.finalHuffmanTableBytesBeforeCompaction)
    XCTAssertEqual(complete.codecOwnedByteCharge, expectedRetained)
    XCTAssertEqual(complete.resourceLedger.retainedBetweenCalls, .bounded(expectedRetained))

    _ = try session.append(data.suffix(2))
    let compacted = session.snapshot()
    XCTAssertEqual(compacted.phase, .complete)
    XCTAssertEqual(compacted.retainedHuffmanTableBytes, 0)
    XCTAssertEqual(compacted.finalHuffmanTableBytesBeforeCompaction, 90)
    _ = try session.finish()
  }

  func testEmbeddedICCIsValidatedWithoutUnchargedMaterializationAndFailsClosed() throws {
    let profile = Data(repeating: 0xA5, count: 4_096)
    let data = try insertingICCProfile(
      profile,
      sequence: 1,
      count: 1,
      into: fixture(named: "jpeg-progressive-420.jpg")
    )

    let inspection = try EncodedImageSecurityInspector.inspect(
      data,
      maximumMetadataBytes: 8_192,
      materializePNGICCProfile: false,
      materializeJPEGICCProfile: false
    )
    XCTAssertEqual(inspection.sourceColorProfile, .embeddedICC)
    XCTAssertNil(inspection.embeddedICCProfile)

    let materialized = try EncodedImageSecurityInspector.inspect(
      data,
      maximumMetadataBytes: 8_192,
      materializePNGICCProfile: false
    )
    XCTAssertEqual(materialized.embeddedICCProfile, profile)

    let statePlan = try JPEGIndependentProgressive420StatePlan.inspect(data)
    let exactPixelAndStateCharge = 23 * 13 * 3 + statePlan.totalStateBytes
    XCTAssertThrowsError(
      try JPEGIndependentProgressive420Decoder(
        maximumOperationByteCharge: exactPixelAndStateCharge,
        maximumMetadataBytes: 8_192
      ).decode(data)
    ) { error in
      XCTAssertEqual(
        error as? JPEGIndependentProgressive420Error,
        .unsupportedSourceSemantics
      )
    }
  }

  func testAdobeAPP14ColorAuthorityMustAgreeWithJFIFYCbCr() throws {
    let original = try fixture(named: "jpeg-progressive-420.jpg")
    let insertionOffset = try firstMarkerOffset(marker: 0xDB, in: original)

    func sourceWithAdobeTransform(_ transform: UInt8) -> Data {
      var app14 = Data([0xFF, 0xEE, 0x00, 0x0E])
      app14.append(Data("Adobe".utf8))
      app14.append(contentsOf: [0x00, 0x64, 0x00, 0x00, 0x00, 0x00, transform])
      var result = Data()
      result.reserveCapacity(original.count + app14.count)
      result.append(original.prefix(insertionOffset))
      result.append(app14)
      result.append(original.dropFirst(insertionOffset))
      return result
    }

    let yCbCr = sourceWithAdobeTransform(1)
    let yCbCrPlan = try JPEGIndependentProgressive420StatePlan.inspect(yCbCr)
    let outputByteCount = yCbCrPlan.width * yCbCrPlan.height * 3
    let reference = try JPEGIndependentProgressive420Decoder(
      maximumOperationByteCharge: yCbCrPlan.totalStateBytes + outputByteCount
    ).decode(original)
    let accepted = try JPEGIndependentProgressive420Decoder(
      maximumOperationByteCharge: yCbCrPlan.totalStateBytes + outputByteCount
    ).decode(yCbCr)
    XCTAssertEqual(accepted.rgb, reference.rgb)

    let sessionCharge = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(statePlan: yCbCrPlan, outputByteCount: outputByteCount)
    let acceptedSession = try JPEGIndependentProgressive420Decoder.IncrementalSession(
      maximumCodecOwnedByteCharge: sessionCharge,
      previewCadence: .finalOnly
    )
    _ = try acceptedSession.append(yCbCr)
    XCTAssertEqual(try acceptedSession.finish().rgb, reference.rgb)

    for conflictingTransform in [UInt8(0), UInt8(2)] {
      let conflicting = sourceWithAdobeTransform(conflictingTransform)
      XCTAssertThrowsError(
        try JPEGIndependentProgressive420Decoder(
          maximumOperationByteCharge: yCbCrPlan.totalStateBytes + outputByteCount
        ).decode(conflicting)
      ) { error in
        XCTAssertEqual(
          error as? JPEGIndependentProgressive420Error,
          .unsupportedSourceSemantics
        )
      }
      let rejectingSession = try JPEGIndependentProgressive420Decoder.IncrementalSession(
        maximumCodecOwnedByteCharge: sessionCharge,
        previewCadence: .finalOnly
      )
      XCTAssertThrowsError(try rejectingSession.append(conflicting)) { error in
        XCTAssertEqual(
          error as? JPEGIndependentProgressive420Error,
          .unsupportedSourceSemantics
        )
      }
      XCTAssertEqual(rejectingSession.snapshot().phase, .terminal)
      XCTAssertEqual(rejectingSession.snapshot().resourceLedger, .terminal)
    }
  }

  func testTruncatedJFIFAuthorityFailsClosedInsteadOfUsingSignatureOnly() throws {
    let original = try fixture(named: "jpeg-progressive-420.jpg")
    XCTAssertGreaterThanOrEqual(original.count, 20)
    XCTAssertEqual(Array(original[0..<6]), [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
    var truncated = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x07])
    truncated.append(Data("JFIF\u{0}".utf8))
    truncated.append(original.dropFirst(20))

    let plan = try JPEGIndependentProgressive420StatePlan.inspect(truncated)
    let outputByteCount = plan.width * plan.height * 3
    XCTAssertThrowsError(
      try JPEGIndependentProgressive420Decoder(
        maximumOperationByteCharge: plan.totalStateBytes + outputByteCount
      ).decode(truncated)
    ) { error in
      XCTAssertEqual(
        error as? JPEGIndependentProgressive420Error,
        .unsupportedSourceSemantics
      )
    }

    let sessionCharge = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(statePlan: plan, outputByteCount: outputByteCount)
    let session = try JPEGIndependentProgressive420Decoder.IncrementalSession(
      maximumCodecOwnedByteCharge: sessionCharge,
      previewCadence: .finalOnly
    )
    XCTAssertThrowsError(try session.append(truncated)) { error in
      XCTAssertEqual(
        error as? JPEGIndependentProgressive420Error,
        .unsupportedSourceSemantics
      )
    }
    XCTAssertEqual(session.snapshot().phase, .terminal)
    XCTAssertEqual(session.snapshot().resourceLedger, .terminal)
  }

  func testJFIFAuthorityMustBeFirstMarkerAfterSOI() throws {
    let original = try fixture(named: "jpeg-progressive-420.jpg")
    let jfifOffset = try firstMarkerOffset(marker: 0xE0, in: original)
    let dqtOffset = try firstMarkerOffset(marker: 0xDB, in: original)
    XCTAssertEqual(jfifOffset, 2)
    XCTAssertGreaterThan(dqtOffset, jfifOffset)
    let jfif = try firstSegment(marker: 0xE0, in: original)
    let dqt = try firstSegment(marker: 0xDB, in: original)
    let restStart = dqtOffset + dqt.count
    var reordered = Data([0xFF, 0xD8])
    reordered.append(dqt)
    reordered.append(jfif)
    reordered.append(original.dropFirst(restStart))

    let plan = try JPEGIndependentProgressive420StatePlan.inspect(reordered)
    let outputByteCount = plan.width * plan.height * 3
    XCTAssertThrowsError(
      try JPEGIndependentProgressive420Decoder(
        maximumOperationByteCharge: plan.totalStateBytes + outputByteCount
      ).decode(reordered)
    ) { error in
      XCTAssertEqual(
        error as? JPEGIndependentProgressive420Error,
        .unsupportedSourceSemantics
      )
    }

    let sessionCharge = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(statePlan: plan, outputByteCount: outputByteCount)
    let session = try JPEGIndependentProgressive420Decoder.IncrementalSession(
      maximumCodecOwnedByteCharge: sessionCharge,
      previewCadence: .finalOnly
    )
    XCTAssertThrowsError(try session.append(reordered)) { error in
      XCTAssertEqual(
        error as? JPEGIndependentProgressive420Error,
        .unsupportedSourceSemantics
      )
    }
    XCTAssertEqual(session.snapshot().phase, .terminal)
    XCTAssertEqual(session.snapshot().resourceLedger, .terminal)
  }

  func testNonmaterializedICCStillValidatesChunkCompleteness() throws {
    let incomplete = try insertingICCProfile(
      Data(repeating: 0x5A, count: 128),
      sequence: 1,
      count: 2,
      into: fixture(named: "jpeg-progressive-420.jpg")
    )
    XCTAssertThrowsError(
      try EncodedImageSecurityInspector.inspect(
        incomplete,
        maximumMetadataBytes: 1_024,
        materializePNGICCProfile: false,
        materializeJPEGICCProfile: false
      )
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .unsupportedOrCorruptImage)
    }
  }

  func testIncrementalSessionSingleByteChunksMatchCompleteDecoderAndReclaimInput() throws {
    let data = try fixture(named: "jpeg-progressive-420.jpg")
    let plan = try JPEGIndependentProgressive420StatePlan.inspect(data)
    let reference = try JPEGIndependentProgressive420Decoder(
      maximumOperationByteCharge: 23 * 13 * 3 + plan.totalStateBytes
    ).decode(data)
    let sessionCharge = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(statePlan: plan, outputByteCount: reference.rgb.count)
    let maximumRetainedCharge = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .retainedByteChargeAfterFrame(statePlan: plan, outputByteCount: reference.rgb.count)
    let retainedCharge = reference.rgb.count
    XCTAssertEqual(maximumRetainedCharge, 5_055)
    XCTAssertEqual(retainedCharge, 897)
    let session = try JPEGIndependentProgressive420Decoder.IncrementalSession(
      maximumCodecOwnedByteCharge: sessionCharge
    )

    let initial = session.snapshot()
    XCTAssertEqual(initial.phase, .awaitingHeader)
    XCTAssertEqual(initial.initialRetainedByteCharge, 2_846)
    XCTAssertEqual(
      initial.codecOwnedByteCharge,
      JPEGIndependentProgressive420Decoder.IncrementalSession.transportCapacityBytes
    )
    XCTAssertEqual(
      initial.operationScratchByteCharge,
      JPEGIndependentProgressive420Decoder.IncrementalSession.operationScratchByteCharge
    )
    XCTAssertEqual(
      initial.resourceLedger.retainedBetweenCalls,
      .bounded(JPEGIndependentProgressive420Decoder.IncrementalSession.transportCapacityBytes)
    )
    XCTAssertEqual(
      initial.resourceLedger.operationPeak,
      .bounded(sessionCharge),
      "initial operation peak: \(initial.resourceLedger.operationPeak), expected \(sessionCharge)"
    )
    XCTAssertEqual(initial.resourceLedger.transferredOutput, .bounded(0))
    XCTAssertEqual(initial.resourceLedger.outputLayoutAuthority, .none)

    var completedScans: [Int] = []
    var previewBackingAddresses: [UInt] = []
    for byte in data {
      let newlyCompleted = try session.append(Data([byte]))
      completedScans.append(contentsOf: newlyCompleted)
      if !newlyCompleted.isEmpty {
        try session.withCurrentPreview { _, pixels in
          previewBackingAddresses.append(UInt(bitPattern: pixels.baseAddress!))
        }
      }
    }
    XCTAssertEqual(completedScans, Array(1...10))
    XCTAssertEqual(previewBackingAddresses.count, completedScans.count)
    XCTAssertEqual(Set(previewBackingAddresses).count, 1)

    let complete = session.snapshot()
    XCTAssertEqual(complete.phase, .complete)
    XCTAssertEqual(complete.acceptedEncodedBytes, data.count)
    XCTAssertEqual(complete.reclaimedEncodedBytes, data.count)
    XCTAssertEqual(complete.retainedTransportBytes, 0)
    XCTAssertLessThan(complete.maximumObservedTransportBytes, data.count)
    XCTAssertEqual(complete.completedScanCount, 10)
    XCTAssertEqual(complete.statePlan, plan)
    XCTAssertEqual(
      complete.codecOwnedByteCharge,
      retainedCharge,
      "complete retained: \(complete.codecOwnedByteCharge), expected \(retainedCharge)"
    )
    XCTAssertEqual(complete.resourceLedger.retainedBetweenCalls, .bounded(retainedCharge))
    XCTAssertEqual(complete.resourceLedger.operationPeak, .bounded(sessionCharge))
    XCTAssertEqual(complete.resourceLedger.transferredOutput, .bounded(reference.rgb.count))
    XCTAssertEqual(complete.resourceLedger.outputLayoutAuthority, .codecOwnedRGB8)

    try session.withCurrentPreview { scan, pixels in
      XCTAssertEqual(scan, 10)
      XCTAssertEqual(Data(bytes: pixels.baseAddress!, count: pixels.count), reference.rgb)
    }

    let streamed = try session.finish()
    XCTAssertEqual(streamed.width, reference.width)
    XCTAssertEqual(streamed.height, reference.height)
    XCTAssertEqual(streamed.scanCount, reference.scanCount)
    XCTAssertEqual(streamed.statePlan, reference.statePlan)
    XCTAssertEqual(streamed.rgb, reference.rgb)
    XCTAssertEqual(streamed.operationByteCharge, sessionCharge)
    XCTAssertEqual(session.snapshot().resourceLedger, .terminal)
  }

  func testPreFrameRetainedStateChargesOnlyActuallyDefinedTablePayloads() throws {
    let data = try fixture(named: "jpeg-progressive-420.jpg")
    let session = try JPEGIndependentProgressive420Decoder.IncrementalSession(
      maximumCodecOwnedByteCharge: 20_000,
      previewCadence: .finalOnly
    )

    let initial = session.snapshot()
    XCTAssertEqual(initial.phase, .awaitingHeader)
    XCTAssertEqual(
      initial.codecOwnedByteCharge,
      JPEGIndependentProgressive420Decoder.IncrementalSession.transportCapacityBytes
    )
    XCTAssertEqual(initial.codecOwnedByteCharge, 414)

    // Tiny retained fixture: JFIF APP0, then DQT0 and DQT1, then SOF2 at byte offset 158.
    // Before SOF2 there are exactly two live 64-byte quantization payloads and no DHT payloads.
    _ = try session.append(data.prefix(158))
    let beforeSOF = session.snapshot()
    XCTAssertEqual(beforeSOF.phase, .awaitingHeader)
    XCTAssertEqual(beforeSOF.retainedTransportBytes, 0)
    XCTAssertEqual(beforeSOF.codecOwnedByteCharge, 414 + 2 * 64)
    XCTAssertEqual(beforeSOF.codecOwnedByteCharge, 542)
  }

  func testSOFTransitionTransfersOnlyPresentQuantizationPayloadsWithoutFixedFrameArena() throws {
    let data = try fixture(named: "jpeg-progressive-420.jpg")
    let plan = try JPEGIndependentProgressive420StatePlan.inspect(data)
    let session = try JPEGIndependentProgressive420Decoder.IncrementalSession(
      maximumCodecOwnedByteCharge: 20_000,
      previewCadence: .finalOnly
    )

    // SOF2 starts at byte 158 and occupies 19 bytes including marker+length+payload. DHT begins at
    // byte 177, so this prefix observes the exact post-SOF / pre-DHT / pre-SOS phase.
    _ = try session.append(data.prefix(177))
    let afterSOF = session.snapshot()
    XCTAssertEqual(afterSOF.phase, .awaitingMarker)
    XCTAssertEqual(afterSOF.retainedPreFrameTableBytes, 0)
    XCTAssertEqual(afterSOF.maximumObservedPreFrameTableBytes, 128)
    XCTAssertEqual(afterSOF.retainedFrameQuantizationSourceBytes, 2 * 64)
    XCTAssertEqual(afterSOF.maximumObservedFrameQuantizationSourceBytes, 2 * 64)
    XCTAssertEqual(plan.persistentBaseStateBytes, 1_568)
    let expectedRetained =
      JPEGIndependentProgressive420Decoder.IncrementalSession.transportCapacityBytes
      + plan.persistentBaseStateBytes
      + 2 * 64
    XCTAssertEqual(expectedRetained, 2_110)
    XCTAssertEqual(afterSOF.codecOwnedByteCharge, expectedRetained)
  }

  func testIncrementalSessionReclaimsAcrossScanLargerThanTransportWindow() throws {
    let data = try sessionStressFixture(named: "noise576-q95-progressive-420.jpg")
    let maximumScanBytes = try maximumEntropyScanByteCount(in: data)
    XCTAssertGreaterThan(
      maximumScanBytes,
      JPEGIndependentProgressive420Decoder.IncrementalSession.transportCapacityBytes
    )

    let plan = try JPEGIndependentProgressive420StatePlan.inspect(data)
    let outputBytes = plan.width * plan.height * 3
    let referenceCharge = plan.totalStateBytes + outputBytes
    let reference = try JPEGIndependentProgressive420Decoder(
      maximumOperationByteCharge: referenceCharge
    ).decode(data)
    let sessionCharge = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(
        statePlan: plan,
        outputByteCount: plan.width * plan.height * 3
      )
    let session = try JPEGIndependentProgressive420Decoder.IncrementalSession(
      maximumCodecOwnedByteCharge: sessionCharge,
      previewCadence: .finalOnly
    )

    var scans: [Int] = []
    let chunkSize = 32 * 1024 + 17
    var offset = 0
    while offset < data.count {
      let end = min(data.count, offset + chunkSize)
      scans.append(contentsOf: try session.append(data.subdata(in: offset..<end)))
      let snapshot = session.snapshot()
      XCTAssertLessThanOrEqual(
        snapshot.retainedTransportBytes,
        JPEGIndependentProgressive420Decoder.IncrementalSession.transportCapacityBytes
      )
      offset = end
    }
    XCTAssertEqual(scans, Array(1...10))
    let beforeFinish = session.snapshot()
    XCTAssertEqual(
      beforeFinish.maximumObservedTransportBytes,
      JPEGIndependentProgressive420Decoder.IncrementalSession.transportCapacityBytes
    )
    XCTAssertEqual(beforeFinish.reclaimedEncodedBytes, data.count)
    XCTAssertEqual(beforeFinish.retainedTransportBytes, 0)

    let streamed = try session.finish()
    XCTAssertEqual(streamed.rgb, reference.rgb)
    XCTAssertEqual(streamed.scanCount, reference.scanCount)
    XCTAssertEqual(streamed.statePlan, reference.statePlan)
  }

  func testFinalReadyCompactsDecoderStateToRGBWithoutExposingFinalOnlyPreview() throws {
    let data = try sessionStressFixture(named: "noise576-q95-progressive-420.jpg")
    let plan = try JPEGIndependentProgressive420StatePlan.inspect(data)
    let outputByteCount = plan.width * plan.height * 3
    let maximumRetainedBeforeFinish =
      JPEGIndependentProgressive420Decoder.IncrementalSession.transportCapacityBytes
      + plan.persistentStateBytes
    let transitionPeak =
      JPEGIndependentProgressive420Decoder.IncrementalSession.initialRetainedByteCharge
      + plan.persistentStateBytes
    let entropyPeak = maximumRetainedBeforeFinish
      + JPEGIndependentProgressive420Decoder.IncrementalSession.operationScratchByteCharge
    let finalSampleBytes = plan.width * plan.height
      + 2 * plan.chromaWidth * plan.chromaHeight
    let finalSampleMaterializationPeak = plan.persistentStateBytes
      + finalSampleBytes
      + JPEGIndependentProgressive420Decoder.IncrementalSession
        .finalSampleMaterializationScratchByteCount
    let finalRGBPeak = finalSampleBytes + outputByteCount
    let huffmanMutationPeak = maximumRetainedBeforeFinish
      + JPEGIndependentProgressive420StatePlan.maximumHuffmanTablePayloadByteCount
    let exactPeak = max(
      transitionPeak,
      entropyPeak,
      finalSampleMaterializationPeak,
      finalRGBPeak,
      huffmanMutationPeak
    )
    XCTAssertEqual(maximumRetainedBeforeFinish, 998_206)
    XCTAssertEqual(finalSampleBytes, 497_664)
    XCTAssertEqual(exactPeak, 1_495_840)

    let session = try JPEGIndependentProgressive420Decoder.IncrementalSession(
      maximumCodecOwnedByteCharge: exactPeak,
      previewCadence: .finalOnly
    )
    _ = try session.append(data)
    let beforeFinish = session.snapshot()
    XCTAssertEqual(beforeFinish.phase, .complete)
    XCTAssertEqual(beforeFinish.retainedHuffmanTableBytes, 0)
    XCTAssertEqual(beforeFinish.maximumObservedHuffmanTableBytes, 169)
    XCTAssertEqual(beforeFinish.finalHuffmanTableBytesBeforeCompaction, 98)
    XCTAssertEqual(beforeFinish.retainedTransportBytes, 0)
    XCTAssertEqual(beforeFinish.codecOwnedByteCharge, outputByteCount)
    XCTAssertEqual(
      beforeFinish.resourceLedger.retainedBetweenCalls,
      .bounded(outputByteCount)
    )
    XCTAssertEqual(beforeFinish.resourceLedger.operationPeak, .bounded(exactPeak))
    XCTAssertThrowsError(try session.withCurrentPreview { _, _ in () }) { error in
      XCTAssertEqual(error as? ImageCraftError, .progressiveDecodingUnsupported)
    }

    let final = try session.finish()
    XCTAssertEqual(final.rgb.count, outputByteCount)
    XCTAssertEqual(final.operationByteCharge, exactPeak)
  }

  func testFinalOnlyDoesNotRetainRenderRowsOrIDCTScratchBetweenScans() throws {
    let data = try sessionStressFixture(named: "noise576-q95-progressive-420.jpg")
    let plan = try JPEGIndependentProgressive420StatePlan.inspect(data)
    let outputByteCount = plan.width * plan.height * 3
    let renderFixedScratchBytes = 256 + 128 + 128
    let renderScratchBytes = plan.rowStateBytes + renderFixedScratchBytes
    let maximumPersistentStateBytes = plan.totalStateBytes - renderScratchBytes
    XCTAssertEqual(renderScratchBytes, 15_488)
    XCTAssertEqual(maximumPersistentStateBytes, 997_792)
    let maximumRetained =
      JPEGIndependentProgressive420Decoder.IncrementalSession.transportCapacityBytes
      + maximumPersistentStateBytes
    let expectedRetained =
      JPEGIndependentProgressive420Decoder.IncrementalSession.transportCapacityBytes
      + plan.persistentBaseStateBytes
      + 98
    XCTAssertEqual(maximumRetained, 998_206)
    XCTAssertEqual(expectedRetained, 996_128)

    let existingPeak = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(
        statePlan: plan,
        outputByteCount: outputByteCount,
        previewCadence: .finalOnly
      )
    let session = try JPEGIndependentProgressive420Decoder.IncrementalSession(
      maximumCodecOwnedByteCharge: existingPeak,
      previewCadence: .finalOnly
    )
    _ = try session.append(data.dropLast(2))
    let beforeFinish = session.snapshot()
    XCTAssertEqual(beforeFinish.phase, .awaitingMarker)
    XCTAssertEqual(beforeFinish.codecOwnedByteCharge, expectedRetained)
    XCTAssertEqual(beforeFinish.resourceLedger.retainedBetweenCalls, .bounded(expectedRetained))

    _ = try session.append(data.suffix(2))
    let finalReady = session.snapshot()
    XCTAssertEqual(finalReady.phase, .complete)
    XCTAssertEqual(finalReady.codecOwnedByteCharge, outputByteCount)
    XCTAssertEqual(finalReady.resourceLedger.retainedBetweenCalls, .bounded(outputByteCount))

    let final = try session.finish()
    XCTAssertEqual(final.rgb.count, outputByteCount)
  }

  func testFancyBoundaryReusesLivePreviousYStripWithoutDeferredRowCopy() throws {
    let data = try sessionStressFixture(named: "noise576-q95-progressive-420.jpg")
    let plan = try JPEGIndependentProgressive420StatePlan.inspect(data)
    XCTAssertTrue(plan.usesFancyGlobalContext)
    XCTAssertEqual(plan.mcuRows, 36)

    // Boundary row 15 can be reconstructed after the next chroma strip is rendered but before the
    // next Y strip overwrites yStrip. Only prior Cb/Cr row 7 needs a retained copy.
    XCTAssertEqual(plan.rowStateBytes, 14_976)
    XCTAssertEqual(plan.renderScratchBytes, 15_488)
    XCTAssertEqual(plan.totalStateBytes, 1_013_280)

    let outputByteCount = plan.width * plan.height * 3
    let sessionPeak = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(
        statePlan: plan,
        outputByteCount: outputByteCount,
        previewCadence: .everyCompletedScan
      )
    XCTAssertEqual(sessionPeak, 2_009_022)

    // Do not use incremental==complete as the pixel oracle: both paths share this renderer. This is
    // the frozen v14 RGB value for the multi-iMCU source, so a render-order bug cannot self-agree.
    let decoded = try JPEGIndependentProgressive420Decoder(
      maximumOperationByteCharge: plan.totalStateBytes + outputByteCount
    ).decode(data)
    let digest = SHA256.hash(data: decoded.rgb)
      .map { String(format: "%02x", $0) }
      .joined()
    XCTAssertEqual(digest, "5b1738e18c84104586fbe59f37348d8bf1fd9af2cd7036874f156625549bafbb")
  }

  func testRenderStateFusesChromaReconstructionIntoRGBWithoutFullWidthStagingRows() throws {
    let tiny = try JPEGIndependentProgressive420StatePlan.inspect(
      sessionStressFixture(named: "canonical-zero-23x13-q75-progressive-420.jpg")
    )
    XCTAssertEqual(tiny.yRowStrideBytes, 64)
    XCTAssertEqual(tiny.chromaRowStrideBytes, 64)
    XCTAssertEqual(
      tiny.rowStateBytes,
      16 * tiny.yRowStrideBytes + 18 * tiny.chromaRowStrideBytes
    )
    XCTAssertEqual(tiny.rowStateBytes, 2_176)
    XCTAssertEqual(tiny.renderScratchBytes, 2_688)
    XCTAssertEqual(tiny.totalStateBytes, 6_432)

    let noise = try JPEGIndependentProgressive420StatePlan.inspect(
      sessionStressFixture(named: "noise576-q95-progressive-420.jpg")
    )
    XCTAssertEqual(noise.yRowStrideBytes, 576)
    XCTAssertEqual(noise.chromaRowStrideBytes, 320)
    XCTAssertEqual(noise.rowStateBytes, 14_976)
    XCTAssertEqual(noise.renderScratchBytes, 15_488)
    XCTAssertEqual(noise.totalStateBytes, 1_013_280)
    let peak = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(
        statePlan: noise,
        outputByteCount: noise.width * noise.height * 3,
        previewCadence: .everyCompletedScan
      )
    XCTAssertEqual(peak, 2_009_022)
  }

  func testFinalOnlyEOIMaterializesTightSamplePlanesBeforeAllocatingRGB() throws {
    let noise = try JPEGIndependentProgressive420StatePlan.inspect(
      sessionStressFixture(named: "noise576-q95-progressive-420.jpg")
    )
    let noiseSamples = noise.width * noise.height
      + 2 * noise.chromaWidth * noise.chromaHeight
    XCTAssertEqual(noiseSamples, 497_664)
    let noisePeak = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(
        statePlan: noise,
        outputByteCount: noise.width * noise.height * 3,
        previewCadence: .finalOnly
      )
    XCTAssertEqual(noisePeak, 1_495_840)

    let restart = try JPEGIndependentProgressive420StatePlan.inspect(
      sessionStressFixture(named: "restart64-q90-progressive-420-rst1b.jpg")
    )
    let restartSamples = restart.width * restart.height
      + 2 * restart.chromaWidth * restart.chromaHeight
    XCTAssertEqual(restartSamples, 6_144)
    let restartPeak = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(
        statePlan: restart,
        outputByteCount: restart.width * restart.height * 3,
        previewCadence: .finalOnly
      )
    XCTAssertEqual(restartPeak, 21_280)

    let tiny = try JPEGIndependentProgressive420StatePlan.inspect(
      sessionStressFixture(named: "canonical-zero-23x13-q75-progressive-420.jpg")
    )
    let everyScanPeak = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(
        statePlan: tiny,
        outputByteCount: tiny.width * tiny.height * 3,
        previewCadence: .everyCompletedScan
      )
    XCTAssertEqual(everyScanPeak, 7_743)
  }

  func testFirstSOSReleasesRawQuantizationSourceStateAfterTablesAreLatched() throws {
    let data = try fixture(named: "jpeg-progressive-420.jpg")
    let plan = try JPEGIndependentProgressive420StatePlan.inspect(data)
    let sessionCharge = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(
        statePlan: plan,
        outputByteCount: plan.width * plan.height * 3,
        previewCadence: .finalOnly
      )
    let session = try JPEGIndependentProgressive420Decoder.IncrementalSession(
      maximumCodecOwnedByteCharge: sessionCharge,
      previewCadence: .finalOnly
    )

    var completedScans: [Int] = []
    var offset = 0
    while completedScans.isEmpty, offset < data.count {
      completedScans.append(contentsOf: try session.append(data.subdata(in: offset..<(offset + 1))))
      offset += 1
    }
    XCTAssertEqual(completedScans, [1])

    // After the first SOS, raw DQT source state is gone. At this exact boundary only the two
    // pre-scan DC Huffman tables are retained: DC0 = 16 counts + 4 symbols, DC1 = 16 + 3 = 39 B.
    let retainedHuffmanBytes = 39
    let expectedRetained =
      JPEGIndependentProgressive420Decoder.IncrementalSession.transportCapacityBytes
      + plan.persistentBaseStateBytes
      + retainedHuffmanBytes
    let afterFirstScan = session.snapshot()
    XCTAssertEqual(afterFirstScan.phase, .awaitingMarker)
    XCTAssertEqual(afterFirstScan.retainedFrameQuantizationSourceBytes, 0)
    XCTAssertEqual(afterFirstScan.retainedHuffmanTableBytes, retainedHuffmanBytes)
    XCTAssertEqual(afterFirstScan.maximumObservedHuffmanTableBytes, retainedHuffmanBytes)
    XCTAssertEqual(
      afterFirstScan.maximumObservedFrameQuantizationSourceBytes,
      128
    )
    XCTAssertEqual(afterFirstScan.codecOwnedByteCharge, expectedRetained)
    XCTAssertEqual(
      afterFirstScan.resourceLedger.retainedBetweenCalls,
      .bounded(expectedRetained)
    )
  }

  func testDQTCanStillRedefineAfterSOF2UntilFirstSOSLatch() throws {
    let original = try fixture(named: "jpeg-progressive-420.jpg")
    let frameOffset = try firstMarkerOffset(marker: 0xC2, in: original)
    let frameSegment = try firstSegment(marker: 0xC2, in: original)
    let firstDQT = try firstSegment(marker: 0xDB, in: original)
    let insertionOffset = frameOffset + frameSegment.count
    XCTAssertLessThan(insertionOffset, try firstMarkerOffset(marker: 0xDA, in: original))

    // Redefine the same source quantization slots after SOF2. The bytes are intentionally identical
    // so this isolates table-authority lifetime from pixel changes: both complete and incremental
    // decoders must accept the late pre-SOS definition and remain byte-identical to the source.
    var redefined = Data()
    redefined.reserveCapacity(original.count + firstDQT.count)
    redefined.append(original.prefix(insertionOffset))
    redefined.append(firstDQT)
    redefined.append(original.dropFirst(insertionOffset))

    let plan = try JPEGIndependentProgressive420StatePlan.inspect(redefined)
    let outputByteCount = plan.width * plan.height * 3
    let reference = try JPEGIndependentProgressive420Decoder(
      maximumOperationByteCharge: plan.totalStateBytes + outputByteCount
    ).decode(original)
    let complete = try JPEGIndependentProgressive420Decoder(
      maximumOperationByteCharge: plan.totalStateBytes + outputByteCount
    ).decode(redefined)
    XCTAssertEqual(complete.rgb, reference.rgb)

    let sessionCharge = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(
        statePlan: plan,
        outputByteCount: outputByteCount,
        previewCadence: .finalOnly
      )
    let session = try JPEGIndependentProgressive420Decoder.IncrementalSession(
      maximumCodecOwnedByteCharge: sessionCharge,
      previewCadence: .finalOnly
    )
    _ = try session.append(redefined)
    let streamed = try session.finish()
    XCTAssertEqual(streamed.rgb, reference.rgb)
    XCTAssertEqual(streamed.scanCount, reference.scanCount)
  }

  func testDQTRedefinitionAfterFirstSOSFailsClosedBecauseQuantizationIsLatched() throws {
    let original = try fixture(named: "jpeg-progressive-420.jpg")
    let firstDQT = try firstSegment(marker: 0xDB, in: original)
    let sosOffsets = (0..<(original.count - 1)).filter {
      original[$0] == 0xFF && original[$0 + 1] == 0xDA
    }
    XCTAssertEqual(sosOffsets.count, 10)
    let insertionOffset = sosOffsets[1]

    var redefined = Data()
    redefined.reserveCapacity(original.count + firstDQT.count)
    redefined.append(original.prefix(insertionOffset))
    redefined.append(firstDQT)
    redefined.append(original.dropFirst(insertionOffset))

    let plan = try JPEGIndependentProgressive420StatePlan.inspect(redefined)
    let outputByteCount = plan.width * plan.height * 3
    XCTAssertThrowsError(
      try JPEGIndependentProgressive420Decoder(
        maximumOperationByteCharge: plan.totalStateBytes + outputByteCount
      ).decode(redefined)
    ) { error in
      XCTAssertEqual(
        error as? JPEGIndependentProgressive420Error,
        .unsupportedSourceSemantics
      )
    }

    let sessionCharge = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(
        statePlan: plan,
        outputByteCount: outputByteCount,
        previewCadence: .finalOnly
      )
    let session = try JPEGIndependentProgressive420Decoder.IncrementalSession(
      maximumCodecOwnedByteCharge: sessionCharge,
      previewCadence: .finalOnly
    )
    XCTAssertThrowsError(try session.append(redefined)) { error in
      XCTAssertEqual(
        error as? JPEGIndependentProgressive420Error,
        .unsupportedSourceSemantics
      )
    }
    let failed = session.snapshot()
    XCTAssertEqual(failed.phase, .terminal)
    XCTAssertEqual(failed.resourceLedger, .terminal)
  }

  func testIncrementalSessionSuspendsAcrossEverySplitRestartMarker() throws {
    let data = try sessionStressFixture(named: "restart64-q90-progressive-420-rst1b.jpg")
    let restartOffsets = restartMarkerOffsets(in: data)
    XCTAssertEqual(restartOffsets.count, 342)

    let plan = try JPEGIndependentProgressive420StatePlan.inspect(data)
    let referenceCharge = plan.totalStateBytes + plan.width * plan.height * 3
    let reference = try JPEGIndependentProgressive420Decoder(
      maximumOperationByteCharge: referenceCharge
    ).decode(data)
    let sessionCharge = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(
        statePlan: plan,
        outputByteCount: plan.width * plan.height * 3
      )
    let session = try JPEGIndependentProgressive420Decoder.IncrementalSession(
      maximumCodecOwnedByteCharge: sessionCharge,
      previewCadence: .finalOnly
    )

    var sourceOffset = 0
    var completedScans: [Int] = []
    for restartOffset in restartOffsets {
      let splitAfterFF = restartOffset + 1
      guard splitAfterFF > sourceOffset else { continue }
      completedScans.append(
        contentsOf: try session.append(data.subdata(in: sourceOffset..<splitAfterFF))
      )
      let suspended = session.snapshot()
      XCTAssertEqual(suspended.phase, .decodingEntropy)
      XCTAssertEqual(suspended.retainedTransportBytes, 1)
      sourceOffset = splitAfterFF
    }
    if sourceOffset < data.count {
      completedScans.append(contentsOf: try session.append(data.subdata(in: sourceOffset..<data.count)))
    }

    XCTAssertEqual(completedScans, Array(1...10))
    let streamed = try session.finish()
    XCTAssertEqual(streamed.rgb, reference.rgb)
    XCTAssertEqual(streamed.scanCount, reference.scanCount)
    XCTAssertEqual(streamed.statePlan, reference.statePlan)
  }

  func testIncrementalSessionReclaimsLegalFillBeforeRestartMarkerBeyondTransportCapacity() throws {
    let original = try sessionStressFixture(named: "restart64-q90-progressive-420-rst1b.jpg")
    let restartOffset = try XCTUnwrap(restartMarkerOffsets(in: original).first)
    let fillByteCount =
      JPEGIndependentProgressive420Decoder.IncrementalSession.maximumMarkerSegmentEncodedBytes * 2
      + 29
    var padded = Data()
    padded.reserveCapacity(original.count + fillByteCount)
    padded.append(original.prefix(restartOffset))
    padded.append(Data(repeating: 0xFF, count: fillByteCount))
    padded.append(original.dropFirst(restartOffset))

    let plan = try JPEGIndependentProgressive420StatePlan.inspect(padded)
    let outputByteCount = plan.width * plan.height * 3
    let reference = try JPEGIndependentProgressive420Decoder(
      maximumOperationByteCharge: plan.totalStateBytes + outputByteCount
    ).decode(padded)
    let sessionCharge = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(statePlan: plan, outputByteCount: outputByteCount)
    let session = try JPEGIndependentProgressive420Decoder.IncrementalSession(
      maximumCodecOwnedByteCharge: sessionCharge,
      previewCadence: .finalOnly
    )

    var offset = 0
    while offset < padded.count {
      let end = min(padded.count, offset + 4093)
      _ = try session.append(padded.subdata(in: offset..<end))
      offset = end
    }
    let beforeFinish = session.snapshot()
    XCTAssertLessThanOrEqual(
      beforeFinish.maximumObservedTransportBytes,
      JPEGIndependentProgressive420Decoder.IncrementalSession.transportCapacityBytes
    )
    XCTAssertEqual(beforeFinish.reclaimedEncodedBytes, padded.count)
    let streamed = try session.finish()
    XCTAssertEqual(streamed.rgb, reference.rgb)
    XCTAssertEqual(streamed.scanCount, reference.scanCount)
  }

  func testRepeatedFFBeforeStuffedZeroFailsClosed() throws {
    let original = try sessionStressFixture(named: "noise576-q95-progressive-420.jpg")
    let stuffedOffset = try XCTUnwrap(
      (0..<(original.count - 1)).first { offset in
        original[offset] == 0xFF && original[offset + 1] == 0x00
      }
    )
    var malformed = original
    malformed.insert(0xFF, at: stuffedOffset + 1)

    let plan = try JPEGIndependentProgressive420StatePlan.inspect(malformed)
    let outputByteCount = plan.width * plan.height * 3
    XCTAssertThrowsError(
      try JPEGIndependentProgressive420Decoder(
        maximumOperationByteCharge: plan.totalStateBytes + outputByteCount
      ).decode(malformed)
    )

    let sessionCharge = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(statePlan: plan, outputByteCount: outputByteCount)
    let session = try JPEGIndependentProgressive420Decoder.IncrementalSession(
      maximumCodecOwnedByteCharge: sessionCharge,
      previewCadence: .finalOnly
    )
    XCTAssertThrowsError(try session.append(malformed))
    XCTAssertEqual(session.snapshot().phase, .terminal)
    XCTAssertEqual(session.snapshot().resourceLedger, .terminal)
  }

  func testIncrementalSessionEncodedLimitRejectionIsRetryableBeforeAcceptance() throws {
    let data = try fixture(named: "jpeg-progressive-420.jpg")
    let plan = try JPEGIndependentProgressive420StatePlan.inspect(data)
    let referenceCharge = plan.totalStateBytes + plan.width * plan.height * 3
    let reference = try JPEGIndependentProgressive420Decoder(
      maximumOperationByteCharge: referenceCharge
    ).decode(data)
    let sessionCharge = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(
        statePlan: plan,
        outputByteCount: plan.width * plan.height * 3
      )
    let limits = DecodeLimits(
      maximumEncodedBytes: data.count,
      maximumDimension: 16_384,
      maximumPixelCount: 100_000_000,
      maximumFrameCount: 1,
      maximumMetadataBytes: 4 * 1024 * 1024,
      maximumAuxiliaryAttachments: 0,
      allowedFormats: [.jpeg]
    )
    let session = try JPEGIndependentProgressive420Decoder.IncrementalSession(
      maximumCodecOwnedByteCharge: sessionCharge,
      limits: limits,
      previewCadence: .finalOnly
    )

    let prefixCount = 100
    _ = try session.append(data.prefix(prefixCount))
    let beforeRejectedCandidate = session.snapshot()
    XCTAssertThrowsError(try session.append(data)) { error in
      XCTAssertEqual(error as? ImageCraftError, .encodedBytesExceeded)
    }
    XCTAssertEqual(session.snapshot(), beforeRejectedCandidate)

    _ = try session.append(data.dropFirst(prefixCount))
    let streamed = try session.finish()
    XCTAssertEqual(streamed.rgb, reference.rgb)
    XCTAssertEqual(streamed.scanCount, reference.scanCount)
  }

  func testIncrementalSessionCancellationReclaimsAndFencesFutureCalls() throws {
    let data = try fixture(named: "jpeg-progressive-420.jpg")
    let session = try JPEGIndependentProgressive420Decoder.IncrementalSession(
      maximumCodecOwnedByteCharge: 1_000_000
    )
    _ = try session.append(data.prefix(data.count / 2))
    XCTAssertNotEqual(session.snapshot().phase, .terminal)

    session.cancel()
    let terminal = session.snapshot()
    XCTAssertEqual(terminal.phase, .terminal)
    XCTAssertEqual(terminal.codecOwnedByteCharge, 0)
    XCTAssertEqual(terminal.retainedTransportBytes, 0)
    XCTAssertEqual(terminal.resourceLedger, .terminal)
    session.cancel()
    XCTAssertEqual(session.snapshot(), terminal)

    XCTAssertThrowsError(try session.append(Data())) { error in
      XCTAssertEqual(
        error as? JPEGIndependentProgressive420Decoder.IncrementalSessionError,
        .sessionTerminal
      )
    }
    XCTAssertThrowsError(try session.finish()) { error in
      XCTAssertEqual(
        error as? JPEGIndependentProgressive420Decoder.IncrementalSessionError,
        .sessionTerminal
      )
    }
  }

  func testIncrementalSessionIncompleteEntropyFinishTerminalizesAndReclaims() throws {
    let data = try fixture(named: "jpeg-progressive-420.jpg")
    let session = try JPEGIndependentProgressive420Decoder.IncrementalSession(
      maximumCodecOwnedByteCharge: 1_000_000,
      previewCadence: .finalOnly
    )
    _ = try session.append(data.prefix(data.count - 20))
    XCTAssertThrowsError(try session.finish()) { error in
      XCTAssertEqual(error as? ImageCraftError, .unsupportedOrCorruptImage)
    }
    let terminal = session.snapshot()
    XCTAssertEqual(terminal.phase, .terminal)
    XCTAssertEqual(terminal.codecOwnedByteCharge, 0)
    XCTAssertEqual(terminal.retainedTransportBytes, 0)
    XCTAssertEqual(terminal.resourceLedger, .terminal)
  }

  func testIncrementalSessionTrailingByteAfterEOITerminalizesAcceptedInput() throws {
    var data = try fixture(named: "jpeg-progressive-420.jpg")
    data.append(0x00)
    let session = try JPEGIndependentProgressive420Decoder.IncrementalSession(
      maximumCodecOwnedByteCharge: 1_000_000,
      previewCadence: .finalOnly
    )
    XCTAssertThrowsError(try session.append(data)) { error in
      XCTAssertEqual(error as? ImageCraftError, .unsupportedOrCorruptImage)
    }
    XCTAssertEqual(session.snapshot().phase, .terminal)
    XCTAssertEqual(session.snapshot().resourceLedger, .terminal)
  }

  func testIncrementalSessionPreFrameTablesNormalizeBySlotCardinality() throws {
    let original = try fixture(named: "jpeg-progressive-420.jpg")
    XCTAssertEqual(
      JPEGIndependentProgressive420Decoder.IncrementalSession.preFrameTableStateByteCount,
      2_432
    )
    XCTAssertEqual(
      JPEGIndependentProgressive420Decoder.IncrementalSession.initialRetainedByteCharge,
      2_846
    )
    XCTAssertEqual(
      JPEGIndependentProgressive420Decoder.IncrementalSession.maximumMarkerSegmentEncodedBytes,
      65_537
    )
    XCTAssertEqual(
      JPEGIndependentProgressive420Decoder.IncrementalSession.maximumMarkerSemanticUnitBytes,
      273
    )
    XCTAssertEqual(
      JPEGIndependentProgressive420Decoder.IncrementalSession.maximumACFirstTransactionBitCount,
      1_642
    )
    XCTAssertEqual(
      JPEGIndependentProgressive420Decoder.IncrementalSession
        .maximumInterleavedDCFirstTransactionBitCount,
      162
    )
    XCTAssertEqual(
      JPEGIndependentProgressive420Decoder.IncrementalSession.maximumACRefineTransactionBitCount,
      1_085
    )
    XCTAssertEqual(
      JPEGIndependentProgressive420Decoder.IncrementalSession.maximumEntropyTransactionEncodedBytes,
      414
    )
    XCTAssertEqual(
      JPEGIndependentProgressive420Decoder.IncrementalSession.transportCapacityBytes,
      414
    )
    XCTAssertEqual(
      JPEGIndependentProgressive420Decoder.IncrementalSession.operationScratchByteCharge,
      768
    )

    let firstDQT = try firstSegment(marker: 0xDB, in: original)
    let firstDHT = try firstSegment(marker: 0xC4, in: original)
    let frameOffset = try firstMarkerOffset(marker: 0xC2, in: original)
    var expanded = Data()
    expanded.reserveCapacity(original.count + 64 * (firstDQT.count + firstDHT.count))
    expanded.append(original.prefix(frameOffset))
    for _ in 0..<64 {
      expanded.append(firstDQT)
      expanded.append(firstDHT)
    }
    expanded.append(original.dropFirst(frameOffset))

    let plan = try JPEGIndependentProgressive420StatePlan.inspect(original)
    let referenceCharge = plan.totalStateBytes + plan.width * plan.height * 3
    let sessionCharge = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(
        statePlan: plan,
        outputByteCount: plan.width * plan.height * 3
      )
    let reference = try JPEGIndependentProgressive420Decoder(
      maximumOperationByteCharge: referenceCharge
    ).decode(original)

    let session = try JPEGIndependentProgressive420Decoder.IncrementalSession(
      maximumCodecOwnedByteCharge: sessionCharge,
      previewCadence: .finalOnly
    )
    _ = try session.append(expanded)
    let decoded = try session.finish()
    XCTAssertEqual(decoded.rgb, reference.rgb)
    XCTAssertEqual(decoded.scanCount, reference.scanCount)
    XCTAssertEqual(decoded.statePlan, reference.statePlan)
  }

  func testIncrementalSessionStreamsNearMaximumSingleDQTSegmentByTableUnit() throws {
    let original = try fixture(named: "jpeg-progressive-420.jpg")
    let firstDQT = try firstSegment(marker: 0xDB, in: original)
    XCTAssertEqual(firstDQT.count, 69)
    let tablePayload = firstDQT.subdata(in: 4..<69)
    XCTAssertEqual(tablePayload.count, 65)
    let repeatCount = 1_000
    let payloadByteCount = tablePayload.count * repeatCount
    let markerLength = payloadByteCount + 2
    XCTAssertLessThanOrEqual(markerLength, Int(UInt16.max))

    var giantDQT = Data([0xFF, 0xDB, UInt8(markerLength >> 8), UInt8(markerLength & 0xFF)])
    giantDQT.reserveCapacity(payloadByteCount + 4)
    for _ in 0..<repeatCount { giantDQT.append(tablePayload) }
    XCTAssertGreaterThan(
      giantDQT.count,
      JPEGIndependentProgressive420Decoder.IncrementalSession.transportCapacityBytes * 100
    )

    let insertionOffset = try firstMarkerOffset(marker: 0xDB, in: original)
    var expanded = Data()
    expanded.reserveCapacity(original.count + giantDQT.count)
    expanded.append(original.prefix(insertionOffset))
    expanded.append(giantDQT)
    expanded.append(original.dropFirst(insertionOffset))

    let plan = try JPEGIndependentProgressive420StatePlan.inspect(expanded)
    let outputByteCount = plan.width * plan.height * 3
    let reference = try JPEGIndependentProgressive420Decoder(
      maximumOperationByteCharge: plan.totalStateBytes + outputByteCount
    ).decode(expanded)
    let sessionCharge = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(statePlan: plan, outputByteCount: outputByteCount)
    let session = try JPEGIndependentProgressive420Decoder.IncrementalSession(
      maximumCodecOwnedByteCharge: sessionCharge,
      previewCadence: .finalOnly
    )
    var offset = 0
    while offset < expanded.count {
      let end = min(expanded.count, offset + 997)
      _ = try session.append(expanded.subdata(in: offset..<end))
      offset = end
    }
    let beforeFinish = session.snapshot()
    XCTAssertLessThanOrEqual(
      beforeFinish.maximumObservedTransportBytes,
      JPEGIndependentProgressive420Decoder.IncrementalSession.transportCapacityBytes
    )
    XCTAssertEqual(beforeFinish.reclaimedEncodedBytes, expanded.count)
    let streamed = try session.finish()
    XCTAssertEqual(streamed.rgb, reference.rgb)
    XCTAssertEqual(streamed.scanCount, reference.scanCount)
  }

  func testIncrementalSessionStreamsNearMaximumSingleDHTSegmentByTableUnit() throws {
    let original = try fixture(named: "jpeg-progressive-420.jpg")
    let firstDHT = try firstSegment(marker: 0xC4, in: original)
    XCTAssertGreaterThan(firstDHT.count, 21)
    let payload = firstDHT.dropFirst(4)
    let symbolCount = (1...16).reduce(0) { $0 + Int(payload[payload.startIndex + $1]) }
    let firstUnitByteCount = 17 + symbolCount
    XCTAssertGreaterThan(symbolCount, 0)
    XCTAssertLessThanOrEqual(firstUnitByteCount, 273)
    let firstUnit = Data(payload.prefix(firstUnitByteCount))
    let repeatCount = max(2, (Int(UInt16.max) - 2) / firstUnitByteCount)
    let repeatedPayloadByteCount = firstUnitByteCount * repeatCount
    let markerLength = repeatedPayloadByteCount + 2
    XCTAssertLessThanOrEqual(markerLength, Int(UInt16.max))

    var giantDHT = Data([0xFF, 0xC4, UInt8(markerLength >> 8), UInt8(markerLength & 0xFF)])
    giantDHT.reserveCapacity(repeatedPayloadByteCount + 4)
    for _ in 0..<repeatCount { giantDHT.append(firstUnit) }
    XCTAssertGreaterThan(
      giantDHT.count,
      JPEGIndependentProgressive420Decoder.IncrementalSession.transportCapacityBytes * 100
    )

    let insertionOffset = try firstMarkerOffset(marker: 0xC4, in: original)
    var expanded = Data()
    expanded.reserveCapacity(original.count + giantDHT.count)
    expanded.append(original.prefix(insertionOffset))
    expanded.append(giantDHT)
    expanded.append(original.dropFirst(insertionOffset))

    let plan = try JPEGIndependentProgressive420StatePlan.inspect(expanded)
    let outputByteCount = plan.width * plan.height * 3
    let reference = try JPEGIndependentProgressive420Decoder(
      maximumOperationByteCharge: plan.totalStateBytes + outputByteCount
    ).decode(expanded)
    let sessionCharge = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(statePlan: plan, outputByteCount: outputByteCount)
    let session = try JPEGIndependentProgressive420Decoder.IncrementalSession(
      maximumCodecOwnedByteCharge: sessionCharge,
      previewCadence: .finalOnly
    )
    var offset = 0
    while offset < expanded.count {
      let end = min(expanded.count, offset + 991)
      _ = try session.append(expanded.subdata(in: offset..<end))
      offset = end
    }
    let beforeFinish = session.snapshot()
    XCTAssertLessThanOrEqual(
      beforeFinish.maximumObservedTransportBytes,
      JPEGIndependentProgressive420Decoder.IncrementalSession.transportCapacityBytes
    )
    XCTAssertEqual(beforeFinish.reclaimedEncodedBytes, expanded.count)
    let streamed = try session.finish()
    XCTAssertEqual(streamed.rgb, reference.rgb)
    XCTAssertEqual(streamed.scanCount, reference.scanCount)
  }

  func testIncrementalSessionStreamsLargeJFIFThumbnailAfterHeaderAuthority() throws {
    let original = try fixture(named: "jpeg-progressive-420.jpg")
    let originalAPP0 = try firstSegment(marker: 0xE0, in: original)
    XCTAssertEqual(try firstMarkerOffset(marker: 0xE0, in: original), 2)
    let xThumbnail = 145
    let yThumbnail = 150
    let thumbnailByteCount = 3 * xThumbnail * yThumbnail
    let payloadByteCount = 14 + thumbnailByteCount
    let markerLength = payloadByteCount + 2
    XCTAssertLessThanOrEqual(markerLength, Int(UInt16.max))
    var app0 = Data([0xFF, 0xE0, UInt8(markerLength >> 8), UInt8(markerLength & 0xFF)])
    app0.append(Data("JFIF\u{0}".utf8))
    app0.append(contentsOf: [0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01])
    app0.append(UInt8(xThumbnail))
    app0.append(UInt8(yThumbnail))
    app0.append(Data(repeating: 0x80, count: thumbnailByteCount))
    XCTAssertEqual(app0.count, markerLength + 2)
    XCTAssertGreaterThan(
      app0.count,
      JPEGIndependentProgressive420Decoder.IncrementalSession.transportCapacityBytes * 100
    )

    var expanded = Data()
    expanded.reserveCapacity(original.count - originalAPP0.count + app0.count)
    expanded.append(original.prefix(2))
    expanded.append(app0)
    expanded.append(original.dropFirst(2 + originalAPP0.count))

    let plan = try JPEGIndependentProgressive420StatePlan.inspect(expanded)
    let outputByteCount = plan.width * plan.height * 3
    let reference = try JPEGIndependentProgressive420Decoder(
      maximumOperationByteCharge: plan.totalStateBytes + outputByteCount,
      maximumMetadataBytes: 128 * 1024
    ).decode(expanded)
    let sessionCharge = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(statePlan: plan, outputByteCount: outputByteCount)
    let session = try JPEGIndependentProgressive420Decoder.IncrementalSession(
      maximumCodecOwnedByteCharge: sessionCharge,
      limits: DecodeLimits(
        maximumEncodedBytes: 256 * 1024,
        maximumPixelCount: DecodeLimits.coreV1.maximumPixelCount,
        maximumFrameCount: DecodeLimits.coreV1.maximumFrameCount,
        maximumMetadataBytes: 128 * 1024,
        allowedFormats: DecodeLimits.coreV1.allowedFormats
      ),
      previewCadence: .finalOnly
    )
    var offset = 0
    while offset < expanded.count {
      let end = min(expanded.count, offset + 983)
      _ = try session.append(expanded.subdata(in: offset..<end))
      offset = end
    }
    let beforeFinish = session.snapshot()
    XCTAssertLessThanOrEqual(
      beforeFinish.maximumObservedTransportBytes,
      JPEGIndependentProgressive420Decoder.IncrementalSession.transportCapacityBytes
    )
    let streamed = try session.finish()
    XCTAssertEqual(streamed.rgb, reference.rgb)
    XCTAssertEqual(streamed.scanCount, reference.scanCount)
  }

  func testIncrementalSessionMetadataCeilingRejectsLargeCOMFromHeaderBeforePayload() throws {
    let original = try fixture(named: "jpeg-progressive-420.jpg")
    let insertionOffset = try firstMarkerOffset(marker: 0xDB, in: original)
    let commentPayloadByteCount = Int(UInt16.max) - 2
    var comment = Data([0xFF, 0xFE, 0xFF, 0xFF])
    comment.append(Data(repeating: 0x41, count: commentPayloadByteCount))
    let existingJFIFPayloadBytes = 14
    let exactMetadataBytes = existingJFIFPayloadBytes + commentPayloadByteCount

    var expanded = Data()
    expanded.reserveCapacity(original.count + comment.count)
    expanded.append(original.prefix(insertionOffset))
    expanded.append(comment)
    expanded.append(original.dropFirst(insertionOffset))

    let plan = try JPEGIndependentProgressive420StatePlan.inspect(expanded)
    let outputByteCount = plan.width * plan.height * 3
    let sessionCharge = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(statePlan: plan, outputByteCount: outputByteCount)

    let rejectingLimits = DecodeLimits(
      maximumEncodedBytes: 256 * 1024,
      maximumPixelCount: DecodeLimits.coreV1.maximumPixelCount,
      maximumFrameCount: DecodeLimits.coreV1.maximumFrameCount,
      maximumMetadataBytes: exactMetadataBytes - 1,
      allowedFormats: DecodeLimits.coreV1.allowedFormats
    )
    let rejecting = try JPEGIndependentProgressive420Decoder.IncrementalSession(
      maximumCodecOwnedByteCharge: sessionCharge,
      limits: rejectingLimits,
      previewCadence: .finalOnly
    )
    let headerEnd = insertionOffset + 4
    XCTAssertThrowsError(try rejecting.append(expanded.prefix(headerEnd))) { error in
      XCTAssertEqual(error as? ImageCraftError, .metadataLimitExceeded)
    }
    let rejected = rejecting.snapshot()
    XCTAssertEqual(rejected.phase, .terminal)
    XCTAssertEqual(rejected.resourceLedger, .terminal)
    XCTAssertEqual(rejected.acceptedEncodedBytes, headerEnd)

    let exactLimits = DecodeLimits(
      maximumEncodedBytes: 256 * 1024,
      maximumPixelCount: DecodeLimits.coreV1.maximumPixelCount,
      maximumFrameCount: DecodeLimits.coreV1.maximumFrameCount,
      maximumMetadataBytes: exactMetadataBytes,
      allowedFormats: DecodeLimits.coreV1.allowedFormats
    )
    let exact = try JPEGIndependentProgressive420Decoder.IncrementalSession(
      maximumCodecOwnedByteCharge: sessionCharge,
      limits: exactLimits,
      previewCadence: .finalOnly
    )
    var offset = 0
    while offset < expanded.count {
      let end = min(expanded.count, offset + 997)
      _ = try exact.append(expanded.subdata(in: offset..<end))
      offset = end
    }
    let streamed = try exact.finish()
    let reference = try JPEGIndependentProgressive420Decoder(
      maximumOperationByteCharge: plan.totalStateBytes + outputByteCount,
      maximumMetadataBytes: exactMetadataBytes
    ).decode(expanded)
    XCTAssertEqual(streamed.rgb, reference.rgb)
    XCTAssertLessThanOrEqual(
      exact.snapshot().maximumObservedTransportBytes,
      JPEGIndependentProgressive420Decoder.IncrementalSession.transportCapacityBytes
    )
  }

  func testIncrementalSessionReclaimsLegalMarkerFillBeyondTransportCapacity() throws {
    let original = try fixture(named: "jpeg-progressive-420.jpg")
    let insertionOffset = try firstMarkerOffset(marker: 0xDB, in: original)
    let fillByteCount =
      JPEGIndependentProgressive420Decoder.IncrementalSession.maximumMarkerSegmentEncodedBytes * 2
      + 17
    var padded = Data()
    padded.reserveCapacity(original.count + fillByteCount)
    padded.append(original.prefix(insertionOffset))
    padded.append(Data(repeating: 0xFF, count: fillByteCount))
    padded.append(original.dropFirst(insertionOffset))

    let plan = try JPEGIndependentProgressive420StatePlan.inspect(padded)
    let outputByteCount = plan.width * plan.height * 3
    let reference = try JPEGIndependentProgressive420Decoder(
      maximumOperationByteCharge: plan.totalStateBytes + outputByteCount
    ).decode(padded)
    let sessionCharge = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(statePlan: plan, outputByteCount: outputByteCount)
    let session = try JPEGIndependentProgressive420Decoder.IncrementalSession(
      maximumCodecOwnedByteCharge: sessionCharge,
      previewCadence: .finalOnly
    )

    var offset = 0
    while offset < padded.count {
      let end = min(padded.count, offset + 4093)
      _ = try session.append(padded.subdata(in: offset..<end))
      offset = end
    }
    let beforeFinish = session.snapshot()
    XCTAssertLessThanOrEqual(
      beforeFinish.maximumObservedTransportBytes,
      JPEGIndependentProgressive420Decoder.IncrementalSession.transportCapacityBytes
    )
    XCTAssertEqual(beforeFinish.reclaimedEncodedBytes, padded.count)
    let streamed = try session.finish()
    XCTAssertEqual(streamed.rgb, reference.rgb)
    XCTAssertEqual(streamed.scanCount, reference.scanCount)
  }

  func testIncrementalSessionStreamsMaximumLengthMarkerWithoutWholeResidency() throws {
    let original = try fixture(named: "jpeg-progressive-420.jpg")
    let insertionOffset = try firstMarkerOffset(marker: 0xDB, in: original)
    var comment = Data([0xFF, 0xFE, 0xFF, 0xFF])
    comment.append(Data(repeating: 0x41, count: Int(UInt16.max) - 2))
    XCTAssertEqual(
      comment.count,
      JPEGIndependentProgressive420Decoder.IncrementalSession.maximumMarkerSegmentEncodedBytes
    )
    XCTAssertGreaterThan(
      comment.count,
      JPEGIndependentProgressive420Decoder.IncrementalSession.transportCapacityBytes
    )

    var expanded = Data()
    expanded.reserveCapacity(original.count + comment.count)
    expanded.append(original.prefix(insertionOffset))
    expanded.append(comment)
    expanded.append(original.dropFirst(insertionOffset))

    let plan = try JPEGIndependentProgressive420StatePlan.inspect(expanded)
    let outputByteCount = plan.width * plan.height * 3
    let reference = try JPEGIndependentProgressive420Decoder(
      maximumOperationByteCharge: plan.totalStateBytes + outputByteCount,
      maximumMetadataBytes: 128 * 1024
    ).decode(expanded)
    let sessionCharge = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(statePlan: plan, outputByteCount: outputByteCount)
    let session = try JPEGIndependentProgressive420Decoder.IncrementalSession(
      maximumCodecOwnedByteCharge: sessionCharge,
      limits: DecodeLimits(
        maximumEncodedBytes: 256 * 1024,
        maximumPixelCount: DecodeLimits.coreV1.maximumPixelCount,
        maximumFrameCount: DecodeLimits.coreV1.maximumFrameCount,
        maximumMetadataBytes: 128 * 1024,
        allowedFormats: DecodeLimits.coreV1.allowedFormats
      ),
      previewCadence: .finalOnly
    )
    var offset = 0
    while offset < expanded.count {
      let end = min(expanded.count, offset + 4093)
      _ = try session.append(expanded.subdata(in: offset..<end))
      offset = end
    }
    let beforeFinish = session.snapshot()
    XCTAssertLessThanOrEqual(
      beforeFinish.maximumObservedTransportBytes,
      JPEGIndependentProgressive420Decoder.IncrementalSession.transportCapacityBytes
    )
    XCTAssertLessThan(beforeFinish.maximumObservedTransportBytes, comment.count)
    XCTAssertEqual(beforeFinish.reclaimedEncodedBytes, expanded.count)
    let streamed = try session.finish()
    XCTAssertEqual(streamed.rgb, reference.rgb)
    XCTAssertEqual(streamed.scanCount, reference.scanCount)
  }

  func testIncrementalSessionBudgetFailsAtFrameAdmissionAndTerminalizesAcceptedInput() throws {
    let data = try fixture(named: "jpeg-progressive-420.jpg")
    let plan = try JPEGIndependentProgressive420StatePlan.inspect(data)
    let required = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(
        statePlan: plan,
        outputByteCount: 23 * 13 * 3,
        previewCadence: .everyCompletedScan
      )
    let session = try JPEGIndependentProgressive420Decoder.IncrementalSession(
      maximumCodecOwnedByteCharge: required - 1
    )

    XCTAssertThrowsError(try session.append(data)) { error in
      XCTAssertEqual(
        error as? JPEGIndependentProgressive420Decoder.IncrementalSessionError,
        .codecOwnedBudgetExceeded(requiredBytes: required, maximumBytes: required - 1)
      )
    }
    let terminal = session.snapshot()
    XCTAssertEqual(terminal.phase, .terminal)
    XCTAssertEqual(terminal.resourceLedger, .terminal)
    XCTAssertEqual(terminal.codecOwnedByteCharge, 0)
    XCTAssertThrowsError(try session.append(Data([0x00]))) { error in
      XCTAssertEqual(
        error as? JPEGIndependentProgressive420Decoder.IncrementalSessionError,
        .sessionTerminal
      )
    }
  }

  func testBaselineAndGrayscaleFailClosed() throws {
    let decoder = JPEGIndependentProgressive420Decoder(maximumOperationByteCharge: 1_000_000)
    for name in ["jpeg-baseline-420.jpg", "jpeg-grayscale.jpg"] {
      XCTAssertThrowsError(try decoder.decode(try fixture(named: name)))
    }
  }

  private func insertingICCProfile(
    _ profile: Data,
    sequence: UInt8,
    count: UInt8,
    into jpeg: Data
  ) throws -> Data {
    guard jpeg.count >= 2, jpeg[0] == 0xFF, jpeg[1] == 0xD8 else {
      throw ImageCraftError.formatMismatch
    }
    var payload = Data("ICC_PROFILE\u{0}".utf8)
    payload.append(sequence)
    payload.append(count)
    payload.append(profile)
    let segmentLength = payload.count + 2
    guard segmentLength <= Int(UInt16.max) else {
      throw ImageCraftError.metadataLimitExceeded
    }

    var result = Data(jpeg.prefix(2))
    result.append(0xFF)
    result.append(0xE2)
    result.append(UInt8((segmentLength >> 8) & 0xFF))
    result.append(UInt8(segmentLength & 0xFF))
    result.append(payload)
    result.append(jpeg.dropFirst(2))
    return result
  }

  private func insertingAPPAfterFirstSegment(
    marker: UInt8,
    payload: Data,
    into jpeg: Data
  ) throws -> Data {
    guard (0xE0...0xEF).contains(marker),
      jpeg.count >= 6,
      jpeg[0] == 0xFF,
      jpeg[1] == 0xD8
    else { throw ImageCraftError.formatMismatch }
    let firstMarker = try firstMarkerOffset(marker: 0xE0, in: jpeg)
    let lengthOffset = firstMarker + 2
    guard lengthOffset + 2 <= jpeg.count else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    let firstLength = Int(jpeg[lengthOffset]) << 8 | Int(jpeg[lengthOffset + 1])
    let insertionOffset = lengthOffset + firstLength
    guard firstLength >= 2, insertionOffset <= jpeg.count else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    let segmentLength = payload.count + 2
    guard segmentLength <= Int(UInt16.max) else {
      throw ImageCraftError.metadataLimitExceeded
    }
    var segment = Data([
      0xFF, marker,
      UInt8((segmentLength >> 8) & 0xFF), UInt8(segmentLength & 0xFF)
    ])
    segment.append(payload)
    var result = jpeg
    result.insert(contentsOf: segment, at: insertionOffset)
    return result
  }

  private func firstMarkerOffset(marker target: UInt8, in data: Data) throws -> Int {
    guard data.count >= 4, data[0] == 0xFF, data[1] == 0xD8 else {
      throw ImageCraftError.formatMismatch
    }
    var offset = 2
    while offset < data.count {
      let markerStart = offset
      guard data[offset] == 0xFF else { throw ImageCraftError.unsupportedOrCorruptImage }
      while offset < data.count, data[offset] == 0xFF { offset += 1 }
      guard offset < data.count else { throw ImageCraftError.unsupportedOrCorruptImage }
      let marker = data[offset]
      offset += 1
      if marker == target { return markerStart }
      if marker == 0xD9 || marker == 0xDA {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      if marker == 0x01 { continue }
      guard offset + 2 <= data.count else { throw ImageCraftError.unsupportedOrCorruptImage }
      let length = Int(data[offset]) << 8 | Int(data[offset + 1])
      guard length >= 2, offset + length <= data.count else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      offset += length
    }
    throw ImageCraftError.unsupportedOrCorruptImage
  }

  private func firstSegment(marker target: UInt8, in data: Data) throws -> Data {
    let markerStart = try firstMarkerOffset(marker: target, in: data)
    var cursor = markerStart
    while cursor < data.count, data[cursor] == 0xFF { cursor += 1 }
    guard cursor < data.count, data[cursor] == target else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    cursor += 1
    guard cursor + 2 <= data.count else { throw ImageCraftError.unsupportedOrCorruptImage }
    let length = Int(data[cursor]) << 8 | Int(data[cursor + 1])
    guard length >= 2, cursor + length <= data.count else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    return data.subdata(in: markerStart..<(cursor + length))
  }

  private func restartMarkerOffsets(in data: Data) -> [Int] {
    guard data.count >= 2 else { return [] }
    return (0..<(data.count - 1)).compactMap { offset in
      data[offset] == 0xFF && (0xD0...0xD7).contains(data[offset + 1]) ? offset : nil
    }
  }

  private func maximumEntropyScanByteCount(in data: Data) throws -> Int {
    guard data.count >= 4, data[0] == 0xFF, data[1] == 0xD8 else {
      throw ImageCraftError.formatMismatch
    }
    var offset = 2
    var maximum = 0
    while offset < data.count {
      guard data[offset] == 0xFF else { throw ImageCraftError.unsupportedOrCorruptImage }
      while offset < data.count, data[offset] == 0xFF { offset += 1 }
      guard offset < data.count else { throw ImageCraftError.unsupportedOrCorruptImage }
      let marker = data[offset]
      offset += 1
      if marker == 0xD9 { return maximum }
      if marker == 0x01 || (0xD0...0xD7).contains(marker) { continue }
      guard offset + 2 <= data.count else { throw ImageCraftError.unsupportedOrCorruptImage }
      let length = Int(data[offset]) << 8 | Int(data[offset + 1])
      guard length >= 2, offset + length <= data.count else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      let segmentEnd = offset + length
      if marker != 0xDA {
        offset = segmentEnd
        continue
      }

      let entropyStart = segmentEnd
      var cursor = entropyStart
      while cursor < data.count {
        if data[cursor] != 0xFF {
          cursor += 1
          continue
        }
        var markerCursor = cursor
        while markerCursor < data.count, data[markerCursor] == 0xFF { markerCursor += 1 }
        guard markerCursor < data.count else { throw ImageCraftError.unsupportedOrCorruptImage }
        let code = data[markerCursor]
        if code == 0x00 || (0xD0...0xD7).contains(code) {
          cursor = markerCursor + 1
          continue
        }
        break
      }
      maximum = max(maximum, cursor - entropyStart)
      offset = cursor
    }
    throw ImageCraftError.unsupportedOrCorruptImage
  }

  private func duplicatingFirstScan(in data: Data) throws -> Data {
    let scanStart = try firstMarkerOffset(marker: 0xDA, in: data)
    var markerCursor = scanStart
    while markerCursor < data.count, data[markerCursor] == 0xFF { markerCursor += 1 }
    guard markerCursor < data.count, data[markerCursor] == 0xDA else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    let lengthOffset = markerCursor + 1
    guard lengthOffset + 2 <= data.count else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }
    let length = Int(data[lengthOffset]) << 8 | Int(data[lengthOffset + 1])
    guard length >= 2, lengthOffset + length <= data.count else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }

    var cursor = lengthOffset + length
    while cursor < data.count {
      if data[cursor] != 0xFF {
        cursor += 1
        continue
      }
      var codeOffset = cursor + 1
      while codeOffset < data.count, data[codeOffset] == 0xFF { codeOffset += 1 }
      guard codeOffset < data.count else {
        throw ImageCraftError.unsupportedOrCorruptImage
      }
      let code = data[codeOffset]
      if code == 0x00 || (0xD0...0xD7).contains(code) {
        cursor = codeOffset + 1
        continue
      }
      break
    }
    guard cursor > scanStart, cursor < data.count else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }

    let scan = data.subdata(in: scanStart..<cursor)
    var hostile = data
    hostile.insert(contentsOf: scan, at: cursor)
    return hostile
  }

  private func sessionStressFixture(named name: String) throws -> Data {
    let url = try XCTUnwrap(
      Bundle.module.url(
        forResource: name,
        withExtension: nil,
        subdirectory: "Corpus/SessionStress"
      )
    )
    return try Data(contentsOf: url)
  }

  private func fixture(named name: String) throws -> Data {
    let url = try XCTUnwrap(
      Bundle.module.url(
        forResource: name,
        withExtension: nil,
        subdirectory: "Corpus/v1"
      )
    )
    return try Data(contentsOf: url)
  }
}
