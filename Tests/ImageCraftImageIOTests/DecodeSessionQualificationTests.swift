import CoreGraphics
import Foundation
import XCTest

@testable import ImageCraftCore
@testable import ImageCraftImageIO

final class DecodeSessionQualificationTests: XCTestCase {
  private struct QualifiedRun {
    let generations: [UInt32]
    let snapshots: [ImageProgressiveQualificationSnapshot]
    let finalization: ImageProgressiveDecodeFinalization
    let finalSnapshot: ImageProgressiveQualificationSnapshot
  }

  func testCurrentRuntimeImageIOPropertyMetadataPreventsPureProbeSubstitution() throws {
    let data = try fixture(named: "jpeg-progressive-420.jpg")
    let security = try EncodedImageSecurityInspector.inspect(
      data,
      maximumMetadataBytes: DecodeLimits.coreV1.maximumMetadataBytes
    )
    let geometry = try JPEGFrameSamplingGeometry.inspect(data)
    let decoder = ImageIOImageDecoder()
    let preparation = try decoder.prepare(data: data, limits: .coreV1)
    defer { decoder.discard(preparation) }
    let probe = preparation.probe

    XCTAssertEqual(probe.pixelWidth, geometry.width)
    XCTAssertEqual(probe.pixelHeight, geometry.height)
    XCTAssertEqual(probe.frameCount, 1)
    XCTAssertEqual(probe.orientation, 1)
    XCTAssertEqual(probe.format, .jpeg)
    XCTAssertEqual(probe.auxiliaryAttachmentCount, 0)
    XCTAssertEqual(probe.sourceColorProfile, security.sourceColorProfile)
    XCTAssertGreaterThan(
      probe.metadataByteCount,
      security.metadataByteCount,
      "If ImageIO stops adding property-derived metadata charge on this retained control, the "
        + "pure-JPEG preparation fast-path hypothesis should be re-evaluated rather than this "
        + "runtime-specific falsification being silently preserved."
    )
  }

  func testChunkMetamorphicFinalPixelsAndCapabilityProfile() throws {
    let data = try fixture(named: "jpeg-progressive-420.jpg")
    let request = ImageDecodeRequest(target: try TargetPixels(width: 32, height: 32))
    let directDecoder = ImageIOImageDecoder()
    let direct = try directDecoder.decode(data: data, request: request, limits: .coreV1)
    let directBytes = try rgbaBytes(direct.cgImage)

    for chunkSize in [1, 17, data.count] {
      let run = try qualifiedRun(data: data, request: request, chunkSize: chunkSize)
      XCTAssertEqual(try rgbaBytes(run.finalization.image.cgImage), directBytes)
      XCTAssertEqual(run.finalization.sourceByteCount, data.count)
      XCTAssertEqual(run.generations, run.generations.sorted())
      XCTAssertEqual(Set(run.generations).count, run.generations.count)
      XCTAssertTrue(
        run.snapshots.allSatisfy { snapshot in
          snapshot.inputProfile == nil || snapshot.inputProfile == .arbitraryChunk
        })
      XCTAssertTrue(run.snapshots.contains { $0.inputProfile == .arbitraryChunk })
      XCTAssertEqual(run.finalSnapshot.inputProfile, .arbitraryChunk)
      XCTAssertEqual(run.finalSnapshot.stableFacts, Set(ImageProgressiveSemanticFact.allCases))
      XCTAssertEqual(run.finalSnapshot.previewSemanticState, .finalStable)
    }
  }

  func testQualificationSnapshotKeepsPreviewFactsProvisionalUntilFinal() throws {
    let data = try fixture(named: "jpeg-progressive-420.jpg")
    let request = ImageDecodeRequest(target: try TargetPixels(width: 32, height: 32))
    let decoder = ImageIOImageDecoder()
    let session = try decoder.makeProgressiveSession(
      format: .jpeg,
      request: request,
      limits: .coreV1
    )
    let qualifying = try XCTUnwrap(session as? any ImageProgressiveSessionQualifying)
    let finalizing = try XCTUnwrap(session as? any ProgressiveImageFinalizingSession)
    let allFacts = Set(ImageProgressiveSemanticFact.allCases)

    var previousConsumedThrough = 0
    var observedPreview = false
    for chunk in chunks(data, maximumSize: 32) {
      let generation = try session.append(chunk)
      let snapshot = qualifying.qualificationSnapshot
      XCTAssertEqual(snapshot.retainFrom, 0)
      XCTAssertGreaterThanOrEqual(snapshot.consumedThrough, previousConsumedThrough)
      XCTAssertLessThanOrEqual(snapshot.consumedThrough, snapshot.receivedByteCount)
      XCTAssertEqual(snapshot.retainedEncodedBytes, snapshot.receivedByteCount)
      XCTAssertLessThanOrEqual(
        snapshot.retainedEncodedBytes,
        snapshot.maximumRetainedEncodedBytes
      )
      XCTAssertFalse(snapshot.retainsOpaqueFrameworkStateBetweenCalls)
      XCTAssertEqual(
        snapshot.resourceLedger.bytesUpperBound(for: .retainedBetweenCalls),
        snapshot.retainedEncodedBytes
      )
      XCTAssertEqual(
        snapshot.resourceLedger.bound(for: .operationPeak),
        .unknown(.frameworkPrivateOperationAllocation)
      )
      XCTAssertEqual(
        snapshot.resourceLedger.bound(for: .transferredOutput),
        .unknown(.frameworkChosenOutputLayout)
      )
      XCTAssertGreaterThanOrEqual(
        snapshot.modeledOwnedOperationBytes,
        snapshot.maximumTightRGBABytes
      )
      previousConsumedThrough = snapshot.consumedThrough

      if generation != nil {
        observedPreview = true
        XCTAssertEqual(snapshot.previewSemanticState, .provisionalNoncacheable)
        XCTAssertTrue(snapshot.stableFacts.isEmpty)
        XCTAssertEqual(snapshot.tentativeFacts, allFacts)
      }
    }
    XCTAssertTrue(observedPreview)

    _ = try finalizing.finishWithFinalImage()
    let finalSnapshot = qualifying.qualificationSnapshot
    XCTAssertEqual(finalSnapshot.progress, .terminal)
    XCTAssertEqual(finalSnapshot.retainedEncodedBytes, 0)
    XCTAssertTrue(finalSnapshot.resourceLedger.isTerminal)
    XCTAssertEqual(finalSnapshot.resourceLedger.bytesUpperBound(for: .retainedBetweenCalls), 0)
    XCTAssertEqual(finalSnapshot.resourceLedger.bytesUpperBound(for: .operationPeak), 0)
    XCTAssertEqual(finalSnapshot.previewSemanticState, .finalStable)
    XCTAssertEqual(finalSnapshot.stableFacts, allFacts)
    XCTAssertTrue(finalSnapshot.tentativeFacts.isEmpty)
  }

  func testImageIOProgressiveResourceAwareFinalizationPreflightsExistingUnknownAuthority() throws {
    let data = try fixture(named: "jpeg-progressive-420.jpg")
    let request = ImageDecodeRequest(target: try TargetPixels(width: 32, height: 32))
    let decoder = ImageIOImageDecoder()
    let direct = try decoder.decode(data: data, request: request, limits: .coreV1)
    let directBytes = try rgbaBytes(direct.cgImage)
    let session = try decoder.makeProgressiveSession(
      format: .jpeg,
      request: request,
      limits: .coreV1
    )
    let qualifying = try XCTUnwrap(session as? any ImageProgressiveSessionQualifying)
    let resourceAware = try XCTUnwrap(
      session as? any ProgressiveImageDecodedImageResourceFinalizingSession
    )
    XCTAssertNotNil(session as? any ProgressiveImageFinalizingSession)

    XCTAssertNil(try resourceAware.decodedImageFinalizationResourceLedger())
    for chunk in chunks(data, maximumSize: 17) {
      _ = try session.append(chunk)
    }
    let readyBeforePreflight = qualifying.qualificationSnapshot
    XCTAssertEqual(readyBeforePreflight.progress, .finalReady)
    XCTAssertEqual(readyBeforePreflight.retainedEncodedBytes, data.count)

    let preflight = try XCTUnwrap(
      resourceAware.decodedImageFinalizationResourceLedger()
    )
    XCTAssertEqual(preflight.retainedKnownBytes, data.count)
    XCTAssertEqual(preflight.retainedBetweenCalls, .bounded(data.count))
    XCTAssertEqual(
      preflight.operationPeak,
      .unknown(.frameworkPrivateOperationAllocation)
    )
    XCTAssertEqual(
      preflight.transferredOutput,
      .unknown(.frameworkChosenOutputLayout)
    )
    XCTAssertEqual(preflight.outputLayoutAuthority, .frameworkChosen)
    XCTAssertFalse(preflight.isTerminal)
    XCTAssertEqual(preflight, readyBeforePreflight.resourceLedger)
    XCTAssertEqual(qualifying.qualificationSnapshot, readyBeforePreflight)

    let finalization = try resourceAware.finishWithDecodedImageResourceAuthority()
    XCTAssertEqual(finalization.materializationResourceLedger, preflight)
    XCTAssertEqual(finalization.sourceByteCount, data.count)
    XCTAssertEqual(try rgbaBytes(finalization.image.cgImage), directBytes)
    XCTAssertEqual(finalization.probe.pixelWidth, direct.pixelWidth)
    XCTAssertEqual(finalization.probe.pixelHeight, direct.pixelHeight)

    let terminal = qualifying.qualificationSnapshot
    XCTAssertEqual(terminal.progress, .terminal)
    XCTAssertEqual(terminal.retainedEncodedBytes, 0)
    XCTAssertTrue(terminal.resourceLedger.isTerminal)
  }

  func testCancellationReleasesRetainedInputAndFencesLateCalls() throws {
    let decoder = ImageIOImageDecoder()
    let session = try decoder.makeProgressiveSession(
      format: .jpeg,
      request: ImageDecodeRequest(target: try TargetPixels(width: 32, height: 32)),
      limits: .coreV1
    )
    let qualifying = try XCTUnwrap(session as? any ImageProgressiveSessionQualifying)
    _ = try session.append(Data([0xFF, 0xD8]))
    XCTAssertGreaterThan(qualifying.qualificationSnapshot.retainedEncodedBytes, 0)

    session.cancel()
    let cancelled = qualifying.qualificationSnapshot
    XCTAssertEqual(cancelled.progress, .terminal)
    XCTAssertEqual(cancelled.retainedEncodedBytes, 0)
    XCTAssertFalse(cancelled.retainsOpaqueFrameworkStateBetweenCalls)
    XCTAssertTrue(cancelled.resourceLedger.isTerminal)
    XCTAssertThrowsError(try session.append(Data([0xFF, 0xD9])))
    XCTAssertThrowsError(try session.finish())
  }

  func testFatalAppendFailureIsTerminalAndReclaimsAcceptedInput() throws {
    let decoder = ImageIOImageDecoder()
    let session = try decoder.makeProgressiveSession(
      format: .jpeg,
      request: ImageDecodeRequest(target: try TargetPixels(width: 32, height: 32)),
      limits: .coreV1
    )
    let qualifying = try XCTUnwrap(session as? any ImageProgressiveSessionQualifying)

    XCTAssertThrowsError(try session.append(Data([0x00, 0x00]))) { error in
      XCTAssertEqual(error as? ImageCraftError, .formatMismatch)
    }
    let failed = qualifying.qualificationSnapshot
    XCTAssertEqual(failed.progress, .terminal)
    XCTAssertEqual(failed.receivedByteCount, 2)
    XCTAssertEqual(failed.retainedEncodedBytes, 0)
    XCTAssertFalse(failed.retainsOpaqueFrameworkStateBetweenCalls)
    XCTAssertTrue(failed.resourceLedger.isTerminal)
    XCTAssertEqual(failed.resourceLedger.bytesUpperBound(for: .retainedBetweenCalls), 0)
    XCTAssertEqual(failed.resourceLedger.bytesUpperBound(for: .operationPeak), 0)

    XCTAssertThrowsError(try session.append(Data([0xFF, 0xD8]))) { error in
      XCTAssertEqual(error as? ImageCraftError, .progressiveSessionFinished)
    }
    XCTAssertThrowsError(try session.finish()) { error in
      XCTAssertEqual(error as? ImageCraftError, .progressiveSessionFinished)
    }
  }

  func testBaselineCapabilityFailureIsTerminalAndReclaimsAcceptedInput() throws {
    let decoder = ImageIOImageDecoder()
    let session = try decoder.makeProgressiveSession(
      format: .jpeg,
      request: ImageDecodeRequest(target: try TargetPixels(width: 32, height: 32)),
      limits: .coreV1
    )
    let qualifying = try XCTUnwrap(session as? any ImageProgressiveSessionQualifying)
    let data = try fixture(named: "jpeg-baseline-420.jpg")

    var observedFailure: ImageCraftError?
    for chunk in chunks(data, maximumSize: 32) {
      do {
        _ = try session.append(chunk)
      } catch let error as ImageCraftError {
        observedFailure = error
        break
      }
    }
    XCTAssertEqual(observedFailure, .progressiveDecodingUnsupported)
    let failed = qualifying.qualificationSnapshot
    XCTAssertEqual(failed.progress, .terminal)
    XCTAssertGreaterThan(failed.receivedByteCount, 0)
    XCTAssertEqual(failed.retainedEncodedBytes, 0)
    XCTAssertTrue(failed.resourceLedger.isTerminal)
    XCTAssertThrowsError(try session.append(Data([0xFF, 0xD9]))) { error in
      XCTAssertEqual(error as? ImageCraftError, .progressiveSessionFinished)
    }
  }

  func testProgressiveScanLimitFailsBeforePreviewWorkAndReclaimsAcceptedInput() throws {
    let decoder = ImageIOImageDecoder()
    let session = try decoder.makeProgressiveSession(
      format: .jpeg,
      request: ImageDecodeRequest(target: try TargetPixels(width: 32, height: 32)),
      limits: .coreV1
    )
    let qualifying = try XCTUnwrap(session as? any ImageProgressiveSessionQualifying)

    var data = Data([0xFF, 0xD8, 0xFF, 0xC2, 0x00, 0x02])
    for _ in 0...EncodedImageSecurityInspector.maximumJPEGScanCount {
      data.append(contentsOf: [0xFF, 0xDA, 0x00, 0x02])
    }

    XCTAssertThrowsError(try session.append(data)) { error in
      XCTAssertEqual(error as? ImageCraftError, .unsupportedOrCorruptImage)
    }
    let failed = qualifying.qualificationSnapshot
    XCTAssertEqual(failed.progress, .terminal)
    XCTAssertEqual(failed.receivedByteCount, data.count)
    XCTAssertEqual(failed.retainedEncodedBytes, 0)
    XCTAssertTrue(failed.resourceLedger.isTerminal)
  }

  func testJPEGStructuralScanLimitIsInclusiveAt500AndRejects501() throws {
    func structurallyScannedJPEG(scanCount: Int) -> Data {
      var data = Data([0xFF, 0xD8])
      for _ in 0..<scanCount {
        data.append(contentsOf: [0xFF, 0xDA, 0x00, 0x02])
      }
      data.append(contentsOf: [0xFF, 0xD9])
      return data
    }

    XCTAssertNoThrow(
      try EncodedImageSecurityInspector.inspect(
        structurallyScannedJPEG(scanCount: EncodedImageSecurityInspector.maximumJPEGScanCount),
        maximumMetadataBytes: DecodeLimits.coreV1.maximumMetadataBytes
      )
    )
    XCTAssertThrowsError(
      try EncodedImageSecurityInspector.inspect(
        structurallyScannedJPEG(scanCount: EncodedImageSecurityInspector.maximumJPEGScanCount + 1),
        maximumMetadataBytes: DecodeLimits.coreV1.maximumMetadataBytes
      )
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .unsupportedOrCorruptImage)
    }
  }

  func testPreAcceptanceEncodedLimitFailureRemainsRetryable() throws {
    let decoder = ImageIOImageDecoder()
    let session = try decoder.makeProgressiveSession(
      format: .jpeg,
      request: ImageDecodeRequest(target: try TargetPixels(width: 32, height: 32)),
      limits: DecodeLimits(maximumEncodedBytes: 8)
    )
    let qualifying = try XCTUnwrap(session as? any ImageProgressiveSessionQualifying)

    XCTAssertThrowsError(try session.append(Data(repeating: 0, count: 9))) { error in
      XCTAssertEqual(error as? ImageCraftError, .encodedBytesExceeded)
    }
    let rejected = qualifying.qualificationSnapshot
    XCTAssertEqual(rejected.progress, .needMoreInput)
    XCTAssertEqual(rejected.receivedByteCount, 0)
    XCTAssertEqual(rejected.retainedEncodedBytes, 0)
    XCTAssertFalse(rejected.resourceLedger.isTerminal)

    XCTAssertNoThrow(try session.append(Data([0xFF, 0xD8])))
    let retried = qualifying.qualificationSnapshot
    XCTAssertEqual(retried.receivedByteCount, 2)
    XCTAssertEqual(retried.retainedEncodedBytes, 2)
    XCTAssertEqual(retried.progress, .madeProgress)
  }

  func testFinalPreparationStoreAdmissionFailureIsRetryableBeforeFrameworkWork() throws {
    let data = try fixture(named: "jpeg-progressive-420.jpg")
    let request = ImageDecodeRequest(target: try TargetPixels(width: 32, height: 32))
    let decoder = ImageIOImageDecoder(
      preparationLimits: ImageDecodePreparationLimits(
        maximumEntryCount: 1,
        maximumRetainedByteCharge: Int.max
      )
    )
    let occupyingPreparation = try decoder.prepare(data: data, limits: .coreV1)

    let session = try decoder.makeProgressiveSession(
      format: .jpeg,
      request: request,
      limits: .coreV1
    )
    let qualifying = try XCTUnwrap(session as? any ImageProgressiveSessionQualifying)
    let creating = try XCTUnwrap(
      session as? any ProgressiveImagePreparationCreationResourceInspectingSession
    )
    for chunk in chunks(data, maximumSize: 32) {
      _ = try session.append(chunk)
    }

    let authorityBeforeFailure = try XCTUnwrap(
      creating.preparationCreationResourceAuthority()
    )
    XCTAssertEqual(authorityBeforeFailure.operationResourceLedger.retainedKnownBytes, data.count)
    XCTAssertEqual(
      authorityBeforeFailure.operationResourceLedger.operationPeak,
      .unknown(.frameworkPrivateOperationAllocation)
    )
    XCTAssertEqual(
      authorityBeforeFailure.resultingPreparationRetainedKnownBytes,
      data.count
    )
    XCTAssertEqual(
      authorityBeforeFailure.resultingPreparationRetainedBetweenCalls,
      .bounded(data.count)
    )

    XCTAssertThrowsError(try creating.finishWithPreparation()) { error in
      XCTAssertEqual(error as? ImageCraftError, .preparedStateBudgetExceeded)
    }
    let failed = qualifying.qualificationSnapshot
    XCTAssertEqual(failed.progress, .finalReady)
    XCTAssertEqual(failed.receivedByteCount, data.count)
    XCTAssertEqual(failed.retainedEncodedBytes, data.count)
    XCTAssertFalse(failed.resourceLedger.isTerminal)
    XCTAssertEqual(
      try creating.preparationCreationResourceAuthority(),
      authorityBeforeFailure
    )

    decoder.discard(occupyingPreparation)
    let finalization = try creating.finishWithPreparation()
    XCTAssertEqual(finalization.sourceByteCount, data.count)
    let terminal = qualifying.qualificationSnapshot
    XCTAssertEqual(terminal.progress, .terminal)
    XCTAssertEqual(terminal.retainedEncodedBytes, 0)
    XCTAssertTrue(terminal.resourceLedger.isTerminal)
    decoder.discard(finalization.preparation)
  }

  func testPreparationCreationAuthorityIncludesEmbeddedICCValueRetention() throws {
    let base = try fixture(named: "jpeg-progressive-420.jpg")
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let profile = try XCTUnwrap(colorSpace.copyICCData() as Data?)
    XCTAssertFalse(profile.isEmpty)
    let data = try insertingSingleChunkICCProfile(profile, intoJFIF: base)
    let inspection = try EncodedImageSecurityInspector.inspect(
      data,
      maximumMetadataBytes: DecodeLimits.coreV1.maximumMetadataBytes
    )
    let assembledProfile = try XCTUnwrap(inspection.embeddedICCProfile)
    XCTAssertEqual(assembledProfile, profile)

    let decoder = ImageIOImageDecoder()
    let request = ImageDecodeRequest(target: try TargetPixels(width: 32, height: 32))
    let session = try decoder.makeProgressiveSession(
      format: .jpeg,
      request: request,
      limits: .coreV1
    )
    let creating = try XCTUnwrap(
      session as? any ProgressiveImagePreparationCreationResourceInspectingSession
    )
    for chunk in chunks(data, maximumSize: 23) {
      _ = try session.append(chunk)
    }

    let authority = try XCTUnwrap(creating.preparationCreationResourceAuthority())
    let resultingKnownBytes = data.count + assembledProfile.count
    XCTAssertEqual(authority.operationResourceLedger.retainedKnownBytes, data.count)
    XCTAssertEqual(
      authority.resultingPreparationRetainedKnownBytes,
      resultingKnownBytes
    )
    XCTAssertEqual(
      authority.resultingPreparationRetainedBetweenCalls,
      .bounded(resultingKnownBytes)
    )

    let finalization = try creating.finishWithPreparation()
    let preparedLedger = try XCTUnwrap(
      decoder.preparationResourceLedger(
        finalization.preparation,
        request: request,
        limits: .coreV1
      )
    )
    XCTAssertEqual(preparedLedger.retainedKnownBytes, resultingKnownBytes)
    XCTAssertEqual(preparedLedger.retainedBetweenCalls, .bounded(resultingKnownBytes))
    decoder.discard(finalization.preparation)
  }

  func testJPEGSecurityInspectionPublishesExactICCByteCountWithoutMaterialization() throws {
    let base = try fixture(named: "jpeg-progressive-420.jpg")
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let profile = try XCTUnwrap(colorSpace.copyICCData() as Data?)
    let data = try insertingSingleChunkICCProfile(profile, intoJFIF: base)

    let valueOnly = try EncodedImageSecurityInspector.inspect(
      data,
      maximumMetadataBytes: DecodeLimits.coreV1.maximumMetadataBytes,
      materializePNGICCProfile: false,
      materializeJPEGICCProfile: false
    )
    XCTAssertEqual(valueOnly.sourceColorProfile, .embeddedICC)
    XCTAssertNil(valueOnly.embeddedICCProfile)
    XCTAssertEqual(valueOnly.embeddedICCProfileByteCount, profile.count)

    let materialized = try EncodedImageSecurityInspector.inspect(
      data,
      maximumMetadataBytes: DecodeLimits.coreV1.maximumMetadataBytes
    )
    XCTAssertEqual(materialized.embeddedICCProfile, profile)
    XCTAssertEqual(
      materialized.embeddedICCProfileByteCount,
      valueOnly.embeddedICCProfileByteCount
    )
  }

  func testProgressiveSessionRejectsIncompleteICCChunkSetAtEOI() throws {
    let base = try fixture(named: "jpeg-progressive-420.jpg")
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let profile = try XCTUnwrap(colorSpace.copyICCData() as Data?)
    var data = try insertingSingleChunkICCProfile(profile, intoJFIF: base)
    let signature = Data("ICC_PROFILE\u{0}".utf8)
    let signatureRange = try XCTUnwrap(data.range(of: signature))
    let countIndex = signatureRange.upperBound + 1
    XCTAssertLessThan(countIndex, data.count)
    data[countIndex] = 2

    XCTAssertThrowsError(
      try EncodedImageSecurityInspector.inspect(
        data,
        maximumMetadataBytes: DecodeLimits.coreV1.maximumMetadataBytes
      )
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .unsupportedOrCorruptImage)
    }

    let decoder = ImageIOImageDecoder()
    let session = try decoder.makeProgressiveSession(
      format: .jpeg,
      request: ImageDecodeRequest(target: try TargetPixels(width: 32, height: 32)),
      limits: .coreV1
    )
    let qualifying = try XCTUnwrap(session as? any ImageProgressiveSessionQualifying)
    var thrown: Error?
    for chunk in chunks(data, maximumSize: 17) {
      do {
        _ = try session.append(chunk)
      } catch {
        thrown = error
        break
      }
    }
    XCTAssertEqual(thrown as? ImageCraftError, .unsupportedOrCorruptImage)
    let terminal = qualifying.qualificationSnapshot
    XCTAssertEqual(terminal.progress, .terminal)
    XCTAssertEqual(terminal.retainedEncodedBytes, 0)
    XCTAssertTrue(terminal.resourceLedger.isTerminal)
  }

  func testFinalImageValidationFailureStillTerminatesAndReclaimsSession() throws {
    let data = try fixture(named: "jpeg-progressive-420.jpg")
    let decoder = ImageIOImageDecoder()
    let limits = DecodeLimits(maximumMetadataBytes: 0)
    let session = try decoder.makeProgressiveSession(
      format: .jpeg,
      request: ImageDecodeRequest(target: try TargetPixels(width: 32, height: 32)),
      limits: limits
    )
    let qualifying = try XCTUnwrap(session as? any ImageProgressiveSessionQualifying)
    let finalizing = try XCTUnwrap(session as? any ProgressiveImageFinalizingSession)
    _ = try session.append(data)
    XCTAssertEqual(qualifying.qualificationSnapshot.progress, .finalReady)

    XCTAssertThrowsError(try finalizing.finishWithFinalImage()) { error in
      XCTAssertEqual(error as? ImageCraftError, .metadataLimitExceeded)
    }
    let failed = qualifying.qualificationSnapshot
    XCTAssertEqual(failed.progress, .terminal)
    XCTAssertEqual(failed.receivedByteCount, data.count)
    XCTAssertEqual(failed.retainedEncodedBytes, 0)
    XCTAssertTrue(failed.resourceLedger.isTerminal)
    XCTAssertThrowsError(try session.finish()) { error in
      XCTAssertEqual(error as? ImageCraftError, .progressiveSessionFinished)
    }
  }

  func testPostEOITrailingAppendIsTerminalAndDoesNotRetainSuffix() throws {
    let data = try fixture(named: "jpeg-progressive-420.jpg")
    let decoder = ImageIOImageDecoder()
    let session = try decoder.makeProgressiveSession(
      format: .jpeg,
      request: ImageDecodeRequest(target: try TargetPixels(width: 32, height: 32)),
      limits: .coreV1
    )
    let qualifying = try XCTUnwrap(session as? any ImageProgressiveSessionQualifying)
    _ = try session.append(data)
    let ready = qualifying.qualificationSnapshot
    XCTAssertEqual(ready.progress, .finalReady)
    XCTAssertEqual(ready.receivedByteCount, data.count)
    XCTAssertEqual(ready.retainedEncodedBytes, data.count)

    XCTAssertThrowsError(try session.append(Data([0x00]))) { error in
      XCTAssertEqual(error as? ImageCraftError, .unsupportedOrCorruptImage)
    }
    let failed = qualifying.qualificationSnapshot
    XCTAssertEqual(failed.progress, .terminal)
    XCTAssertEqual(failed.receivedByteCount, data.count + 1)
    XCTAssertEqual(failed.retainedEncodedBytes, 0)
    XCTAssertTrue(failed.resourceLedger.isTerminal)
  }

  func testArithmeticProgressiveMarkerNeverClaimsArbitraryChunkProfile() throws {
    var data = try fixture(named: "jpeg-progressive-420.jpg")
    let markerOffset = try XCTUnwrap(sof2MarkerOffset(in: data))
    data[markerOffset + 1] = 0xCA  // SOF10: progressive arithmetic coding.

    let decoder = ImageIOImageDecoder()
    let session = try decoder.makeProgressiveSession(
      format: .jpeg,
      request: ImageDecodeRequest(target: try TargetPixels(width: 32, height: 32)),
      limits: .coreV1
    )
    let qualifying = try XCTUnwrap(session as? any ImageProgressiveSessionQualifying)
    var producedPreview = false
    for chunk in chunks(data, maximumSize: 32) {
      producedPreview = (try session.append(chunk) != nil) || producedPreview
    }

    XCTAssertFalse(producedPreview)
    XCTAssertNil(qualifying.qualificationSnapshot.inputProfile)
    XCTAssertThrowsError(try session.finish()) { error in
      XCTAssertEqual(error as? ImageCraftError, .unsupportedOrCorruptImage)
    }
  }

  private func qualifiedRun(
    data: Data,
    request: ImageDecodeRequest,
    chunkSize: Int
  ) throws -> QualifiedRun {
    let decoder = ImageIOImageDecoder()
    let session = try decoder.makeProgressiveSession(
      format: .jpeg,
      request: request,
      limits: .coreV1
    )
    let qualifying = try XCTUnwrap(session as? any ImageProgressiveSessionQualifying)
    let finalizing = try XCTUnwrap(session as? any ProgressiveImageFinalizingSession)
    var generations: [UInt32] = []
    var snapshots: [ImageProgressiveQualificationSnapshot] = []
    for chunk in chunks(data, maximumSize: chunkSize) {
      if let generation = try session.append(chunk) {
        generations.append(generation.generation)
      }
      snapshots.append(qualifying.qualificationSnapshot)
    }
    let finalization = try finalizing.finishWithFinalImage()
    return QualifiedRun(
      generations: generations,
      snapshots: snapshots,
      finalization: finalization,
      finalSnapshot: qualifying.qualificationSnapshot
    )
  }

  private func sof2MarkerOffset(in data: Data) -> Int? {
    guard data.count >= 2 else { return nil }
    for index in 0..<(data.count - 1) where data[index] == 0xFF && data[index + 1] == 0xC2 {
      return index
    }
    return nil
  }

  private func insertingSingleChunkICCProfile(_ profile: Data, intoJFIF source: Data) throws
    -> Data
  {
    let signature = Data("ICC_PROFILE\u{0}".utf8)
    let payloadByteCount = signature.count + 2 + profile.count
    guard payloadByteCount <= Int(UInt16.max) - 2,
      source.count >= 6,
      source[0] == 0xFF,
      source[1] == 0xD8,
      source[2] == 0xFF,
      source[3] == 0xE0
    else { throw ImageCraftError.unsupportedOrCorruptImage }
    let app0Length = Int(source[4]) << 8 | Int(source[5])
    let insertionOffset = 4 + app0Length
    guard app0Length >= 2, insertionOffset <= source.count else {
      throw ImageCraftError.unsupportedOrCorruptImage
    }

    let segmentLength = payloadByteCount + 2
    var segment = Data([0xFF, 0xE2, UInt8(segmentLength >> 8), UInt8(segmentLength & 0xFF)])
    segment.append(signature)
    segment.append(contentsOf: [1, 1])
    segment.append(profile)
    var result = source
    result.insert(contentsOf: segment, at: insertionOffset)
    return result
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

  private func chunks(_ data: Data, maximumSize: Int) -> [Data] {
    stride(from: 0, to: data.count, by: maximumSize).map { offset in
      data.subdata(in: offset..<min(data.count, offset + maximumSize))
    }
  }

  private func rgbaBytes(_ image: CGImage) throws -> Data {
    let bytesPerRow = image.width * 4
    var bytes = Data(count: bytesPerRow * image.height)
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    try bytes.withUnsafeMutableBytes { raw in
      let context = try XCTUnwrap(
        CGContext(
          data: raw.baseAddress,
          width: image.width,
          height: image.height,
          bitsPerComponent: 8,
          bytesPerRow: bytesPerRow,
          space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
      )
      context.setBlendMode(.copy)
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
  }
}
