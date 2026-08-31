import Foundation
import ImageCraftCore
import ImageCraftImageIO
@testable import ImageCraftConsumerSmoke
import XCTest

final class ProgressiveFinalizationAdmissionTests: XCTestCase {
  func testHostCanComposeCallerOwnedSourceWithAnyResourcePhase() throws {
    let smoke = ImageCraftConsumerSmoke()
    let bounded = try XCTUnwrap(
      ImageDecodeResourceLedgerSnapshot(
        retainedKnownBytes: 0,
        retainedBetweenCalls: .bounded(0),
        operationPeak: .bounded(4_096),
        transferredOutput: .bounded(2_048),
        outputLayoutAuthority: .codecOwnedRGBA8
      )
    )
    XCTAssertEqual(
      smoke.operationLiveSetBound(ledger: bounded, encodedSourceByteCount: 787),
      .bounded(4_883)
    )
    XCTAssertEqual(
      bounded.coexistenceBound(for: .transferredOutput, callerRetainedBytes: 787),
      .bounded(2_835)
    )

    let unknown = try XCTUnwrap(
      ImageDecodeResourceLedgerSnapshot(
        retainedKnownBytes: 0,
        retainedBetweenCalls: .bounded(0),
        operationPeak: .unknown(.frameworkPrivateOperationAllocation),
        transferredOutput: .unknown(.frameworkChosenOutputLayout),
        outputLayoutAuthority: .frameworkChosen
      )
    )
    XCTAssertEqual(
      smoke.operationLiveSetBound(ledger: unknown, encodedSourceByteCount: 787),
      .unknown(.frameworkPrivateOperationAllocation)
    )
    XCTAssertEqual(
      unknown.coexistenceBound(for: .transferredOutput, callerRetainedBytes: 787),
      .unknown(.frameworkChosenOutputLayout)
    )
  }

  func testPackedRGBA8ValueContractIsPublicAndSelfDescribing() throws {
    let bytes = Data([10, 20, 30, 255, 40, 50, 60, 128])
    let value = try XCTUnwrap(
      ImagePackedRGBA8(
        data: bytes,
        pixelWidth: 2,
        pixelHeight: 1,
        colorEncoding: .sRGB,
        sourceColorProfile: .standardSRGB
      )
    )

    XCTAssertEqual(value.data, bytes)
    XCTAssertEqual(value.pixelWidth, 2)
    XCTAssertEqual(value.pixelHeight, 1)
    XCTAssertEqual(value.bytesPerRow, 8)
    XCTAssertEqual(value.colorEncoding, .sRGB)
    XCTAssertEqual(value.pixelByteCharge, 8)
    XCTAssertEqual(value.transferredByteCharge, 8)

    XCTAssertNil(
      ImagePackedRGBA8(
        data: Data([1, 2, 3, 255]),
        pixelWidth: 1,
        pixelHeight: 1,
        colorEncoding: .embeddedICC(Data()),
        sourceColorProfile: .embeddedICC
      )
    )
    XCTAssertNil(
      ImagePackedRGBA8(
        data: Data([1, 2, 3, 255]),
        pixelWidth: 1,
        pixelHeight: 1,
        colorEncoding: .embeddedICC(Data([1, 2, 3])),
        sourceColorProfile: .absent
      )
    )

    XCTAssertNil(
      ImagePackedCICPColorEncoding(
        colorPrimaries: 9,
        transferFunction: 16,
        matrixCoefficients: 1,
        videoFullRangeFlag: 1
      )
    )
    let cicp = try XCTUnwrap(
      ImagePackedCICPColorEncoding(
        colorPrimaries: 9,
        transferFunction: 16,
        matrixCoefficients: 0,
        videoFullRangeFlag: 1
      )
    )
    XCTAssertNil(
      ImagePackedRGBA8(
        data: Data([1, 2, 3, 255]),
        pixelWidth: 1,
        pixelHeight: 1,
        colorEncoding: .cicp(cicp),
        sourceColorProfile: .absent
      )
    )
  }

  func testBoundedHostRejectsResourceUnknownWithoutFallingBackToLegacyFinalizer() throws {
    let session = DualFinalizingSession(
      preflight: makeLedger(operationPeak: .unknown(.frameworkPrivateOperationAllocation))
    )

    XCTAssertEqual(
      try inspectProgressiveFinalizationAdmission(
        session,
        requireBoundedOperation: true
      ),
      .rejectedUnknown(.frameworkPrivateOperationAllocation)
    )
    XCTAssertEqual(session.preflightCallCount, 1)
    XCTAssertEqual(session.resourceAwareFinishCallCount, 0)
    XCTAssertEqual(session.legacyFinishCallCount, 0)
  }

  func testResourceAwareNotReadyDoesNotFallBackToLegacyFinalizer() throws {
    let session = DualFinalizingSession(preflight: nil)

    XCTAssertEqual(
      try inspectProgressiveFinalizationAdmission(
        session,
        requireBoundedOperation: true
      ),
      .notReady
    )
    XCTAssertEqual(session.preflightCallCount, 1)
    XCTAssertEqual(session.resourceAwareFinishCallCount, 0)
    XCTAssertEqual(session.legacyFinishCallCount, 0)
  }

  func testBoundedResourceAwareAuthorityWinsOverLegacyCapability() throws {
    let ledger = makeLedger(operationPeak: .bounded(2_048))
    let session = DualFinalizingSession(preflight: ledger)

    XCTAssertEqual(
      try inspectProgressiveFinalizationAdmission(
        session,
        requireBoundedOperation: true
      ),
      .resourceAware(ledger)
    )
    XCTAssertEqual(session.preflightCallCount, 1)
    XCTAssertEqual(session.resourceAwareFinishCallCount, 0)
    XCTAssertEqual(session.legacyFinishCallCount, 0)
  }

  func testHostCanExplicitlyAllowUnknownWithoutHidingIt() throws {
    let ledger = makeLedger(operationPeak: .unknown(.frameworkPrivateOperationAllocation))
    let session = DualFinalizingSession(preflight: ledger)

    XCTAssertEqual(
      try inspectProgressiveFinalizationAdmission(
        session,
        requireBoundedOperation: false
      ),
      .resourceAware(ledger)
    )
    XCTAssertEqual(session.preflightCallCount, 1)
    XCTAssertEqual(session.resourceAwareFinishCallCount, 0)
    XCTAssertEqual(session.legacyFinishCallCount, 0)
  }

  func testLegacyCapabilityIsVisibleOnlyWhenResourceAwareCapabilityIsAbsent() throws {
    let session = LegacyOnlySession()
    XCTAssertEqual(
      try inspectProgressiveFinalizationAdmission(
        session,
        requireBoundedOperation: true
      ),
      .legacyValueOnly
    )
    XCTAssertEqual(session.legacyFinishCallCount, 0)
  }

  func testRealImageIOProgressiveSessionExposesUnknownBeforeConsumingFinalization() throws {
    let fixtureURL = try XCTUnwrap(
      Bundle.module.url(forResource: "jpeg-progressive-420", withExtension: "jpg")
    )
    let source = try Data(contentsOf: fixtureURL)
    XCTAssertEqual(source.count, 787)

    let decoder = ImageIOImageDecoder()
    let session = try decoder.makeProgressiveSession(
      format: .jpeg,
      request: ImageDecodeRequest(target: try TargetPixels(width: 32, height: 32)),
      limits: .coreV1
    )
    var offset = 0
    while offset < source.count {
      let end = min(source.count, offset + 17)
      _ = try session.append(source.subdata(in: offset..<end))
      offset = end
    }
    XCTAssertEqual(session.receivedByteCount, source.count)

    XCTAssertEqual(
      try inspectProgressiveFinalizationAdmission(
        session,
        requireBoundedOperation: true
      ),
      .rejectedUnknown(.frameworkPrivateOperationAllocation)
    )
    XCTAssertEqual(session.receivedByteCount, source.count)

    let resourceAware = try XCTUnwrap(
      session as? any ProgressiveImageDecodedImageResourceFinalizingSession
    )
    let ledger = try XCTUnwrap(resourceAware.decodedImageFinalizationResourceLedger())
    XCTAssertEqual(ledger.retainedKnownBytes, source.count)
    XCTAssertEqual(ledger.retainedBetweenCalls, .bounded(source.count))
    XCTAssertEqual(
      ledger.operationPeak,
      .unknown(.frameworkPrivateOperationAllocation)
    )
    XCTAssertEqual(
      ledger.transferredOutput,
      .unknown(.frameworkChosenOutputLayout)
    )
    XCTAssertEqual(ledger.outputLayoutAuthority, .frameworkChosen)

    // Deliberately consume through the legacy API only to prove the preceding public preflight did
    // not close the real ImageIO session. A bounded host should instead honor the rejection above.
    let legacy = try XCTUnwrap(session as? any ProgressiveImageFinalizingSession)
    let finalization = try legacy.finishWithFinalImage()
    XCTAssertEqual(finalization.sourceByteCount, source.count)
    XCTAssertGreaterThan(finalization.image.pixelWidth, 0)
    XCTAssertGreaterThan(finalization.image.pixelHeight, 0)
  }

  func testRealImageIOPreparedTokenExposesResourceAuthorityBeforeDecode() throws {
    let fixtureURL = try XCTUnwrap(
      Bundle.module.url(forResource: "jpeg-progressive-420", withExtension: "jpg")
    )
    let source = try Data(contentsOf: fixtureURL)
    let decoder = ImageIOImageDecoder()
    let preparation = try decoder.prepare(data: source, limits: .coreV1)
    let request = ImageDecodeRequest(target: try TargetPixels(width: 32, height: 32))
    let resourceAware: any PreparedImageResourceInspecting = decoder

    let ledger = try XCTUnwrap(
      resourceAware.preparationResourceLedger(
        preparation,
        request: request,
        limits: .coreV1
      )
    )
    XCTAssertEqual(ledger.retainedKnownBytes, source.count)
    XCTAssertEqual(ledger.retainedBetweenCalls, .bounded(source.count))
    XCTAssertEqual(
      ledger.operationPeak,
      .unknown(.frameworkPrivateOperationAllocation)
    )
    XCTAssertEqual(
      ledger.transferredOutput,
      .unknown(.frameworkChosenOutputLayout)
    )
    XCTAssertEqual(ledger.outputLayoutAuthority, .frameworkChosen)
    XCTAssertEqual(
      resourceAware.preparationResourceLedger(
        preparation,
        request: request,
        limits: .coreV1
      ),
      ledger
    )

    let image = try resourceAware.decode(
      preparation: preparation,
      request: request,
      limits: .coreV1
    )
    XCTAssertGreaterThan(image.pixelWidth, 0)
    XCTAssertGreaterThan(image.pixelHeight, 0)
    XCTAssertNil(
      resourceAware.preparationResourceLedger(
        preparation,
        request: request,
        limits: .coreV1
      )
    )
  }

  func testRealImageIOProgressivePreparationCreationExposesUnknownBeforeCreatingToken() throws {
    let fixtureURL = try XCTUnwrap(
      Bundle.module.url(forResource: "jpeg-progressive-420", withExtension: "jpg")
    )
    let source = try Data(contentsOf: fixtureURL)
    let decoder = ImageIOImageDecoder()
    let session = try decoder.makeProgressiveSession(
      format: .jpeg,
      request: ImageDecodeRequest(target: try TargetPixels(width: 32, height: 32)),
      limits: .coreV1
    )
    let preparationResourceAware = try XCTUnwrap(
      session as? any ProgressiveImagePreparationResourceInspectingSession
    )
    let creationResourceAware = try XCTUnwrap(
      session as? any ProgressiveImagePreparationCreationResourceInspectingSession
    )

    XCTAssertNil(try preparationResourceAware.preparationFinalizationResourceLedger())
    XCTAssertNil(try creationResourceAware.preparationCreationResourceAuthority())
    var offset = 0
    while offset < source.count {
      let end = min(source.count, offset + 17)
      _ = try session.append(source.subdata(in: offset..<end))
      offset = end
    }
    XCTAssertEqual(session.receivedByteCount, source.count)

    let ledger = try XCTUnwrap(
      preparationResourceAware.preparationFinalizationResourceLedger()
    )
    XCTAssertEqual(ledger.retainedKnownBytes, source.count)
    XCTAssertEqual(ledger.retainedBetweenCalls, .bounded(source.count))
    XCTAssertEqual(
      ledger.operationPeak,
      .unknown(.frameworkPrivateOperationAllocation)
    )
    XCTAssertEqual(ledger.transferredOutput, .bounded(0))
    XCTAssertEqual(ledger.outputLayoutAuthority, .none)
    XCTAssertEqual(
      try preparationResourceAware.preparationFinalizationResourceLedger(),
      ledger
    )
    let creationAuthority = try XCTUnwrap(
      creationResourceAware.preparationCreationResourceAuthority()
    )
    XCTAssertEqual(creationAuthority.operationResourceLedger, ledger)
    XCTAssertEqual(
      creationAuthority.resultingPreparationRetainedKnownBytes,
      source.count
    )
    XCTAssertEqual(
      creationAuthority.resultingPreparationRetainedBetweenCalls,
      .bounded(source.count)
    )
    XCTAssertEqual(session.receivedByteCount, source.count)

    let finalization = try preparationResourceAware.finishWithPreparation()
    XCTAssertEqual(finalization.sourceByteCount, source.count)

    let preparedResourceAware: any PreparedImageResourceInspecting = decoder
    let request = ImageDecodeRequest(target: try TargetPixels(width: 32, height: 32))
    let preparedLedger = try XCTUnwrap(
      preparedResourceAware.preparationResourceLedger(
        finalization.preparation,
        request: request,
        limits: .coreV1
      )
    )
    XCTAssertEqual(preparedLedger.retainedKnownBytes, source.count)
    XCTAssertEqual(preparedLedger.retainedBetweenCalls, .bounded(source.count))
    XCTAssertEqual(
      preparedLedger.operationPeak,
      .unknown(.frameworkPrivateOperationAllocation)
    )
    XCTAssertEqual(
      preparedLedger.transferredOutput,
      .unknown(.frameworkChosenOutputLayout)
    )
    XCTAssertEqual(preparedLedger.outputLayoutAuthority, .frameworkChosen)
    XCTAssertEqual(
      preparedLedger.retainedKnownBytes,
      creationAuthority.resultingPreparationRetainedKnownBytes
    )
    XCTAssertEqual(
      preparedLedger.retainedBetweenCalls,
      creationAuthority.resultingPreparationRetainedBetweenCalls
    )
    decoder.discard(finalization.preparation)
  }

  func testRealImageIOPreparationStoreAdmissionIsRetryableBeforeCreationWork() throws {
    let fixtureURL = try XCTUnwrap(
      Bundle.module.url(forResource: "jpeg-progressive-420", withExtension: "jpg")
    )
    let source = try Data(contentsOf: fixtureURL)
    let decoder = ImageIOImageDecoder(
      preparationLimits: ImageDecodePreparationLimits(
        maximumEntryCount: 1,
        maximumRetainedByteCharge: source.count
      )
    )
    let occupyingPreparation = try decoder.prepare(data: source, limits: .coreV1)
    let session = try decoder.makeProgressiveSession(
      format: .jpeg,
      request: ImageDecodeRequest(target: try TargetPixels(width: 32, height: 32)),
      limits: .coreV1
    )
    let creating = try XCTUnwrap(
      session as? any ProgressiveImagePreparationCreationResourceInspectingSession
    )
    var offset = 0
    while offset < source.count {
      let end = min(source.count, offset + 17)
      _ = try session.append(source.subdata(in: offset..<end))
      offset = end
    }

    let authority = try XCTUnwrap(creating.preparationCreationResourceAuthority())
    XCTAssertEqual(authority.resultingPreparationRetainedKnownBytes, source.count)
    XCTAssertThrowsError(try creating.finishWithPreparation()) { error in
      XCTAssertEqual(error as? ImageCraftError, .preparedStateBudgetExceeded)
    }
    XCTAssertEqual(
      try creating.preparationCreationResourceAuthority(),
      authority
    )
    XCTAssertEqual(session.receivedByteCount, source.count)

    decoder.discard(occupyingPreparation)
    let finalization = try creating.finishWithPreparation()
    XCTAssertEqual(finalization.sourceByteCount, source.count)
    decoder.discard(finalization.preparation)
  }

  func testRealImageIOStaticPreparationCreationPreflightIsPublicAndNonConsuming() throws {
    let fixtureURL = try XCTUnwrap(
      Bundle.module.url(forResource: "jpeg-progressive-420", withExtension: "jpg")
    )
    let source = try Data(contentsOf: fixtureURL)
    let decoder = ImageIOImageDecoder()
    let creating: any PreparedImageCreationResourceInspecting = decoder

    let authority = try creating.preparationCreationResourceAuthority(
      data: source,
      limits: .coreV1
    )
    XCTAssertEqual(authority.operationResourceLedger.retainedKnownBytes, 0)
    XCTAssertEqual(authority.operationResourceLedger.retainedBetweenCalls, .bounded(0))
    XCTAssertEqual(
      authority.operationResourceLedger.operationPeak,
      .unknown(.frameworkPrivateOperationAllocation)
    )
    XCTAssertEqual(authority.operationResourceLedger.transferredOutput, .bounded(0))
    XCTAssertEqual(authority.operationResourceLedger.outputLayoutAuthority, .none)
    XCTAssertEqual(authority.resultingPreparationRetainedKnownBytes, source.count)
    XCTAssertEqual(
      authority.resultingPreparationRetainedBetweenCalls,
      .bounded(source.count)
    )

    let preparation = try creating.prepare(data: source, limits: .coreV1)
    let request = ImageDecodeRequest(target: try TargetPixels(width: 32, height: 32))
    let ledger = try XCTUnwrap(
      decoder.preparationResourceLedger(
        preparation,
        request: request,
        limits: .coreV1
      )
    )
    XCTAssertEqual(ledger.retainedKnownBytes, authority.resultingPreparationRetainedKnownBytes)
    XCTAssertEqual(
      ledger.retainedBetweenCalls,
      authority.resultingPreparationRetainedBetweenCalls
    )
    decoder.discard(preparation)
  }

  private func makeLedger(
    operationPeak: ImageDecodeResourceBound
  ) -> ImageDecodeResourceLedgerSnapshot {
    ImageDecodeResourceLedgerSnapshot(
      retainedKnownBytes: 0,
      retainedBetweenCalls: .bounded(0),
      operationPeak: operationPeak,
      transferredOutput: .bounded(897),
      outputLayoutAuthority: .codecOwnedRGB8
    )!
  }
}

private final class DualFinalizingSession:
  ProgressiveImageDecodedImageResourceFinalizingSession,
  ProgressiveImageFinalizingSession,
  @unchecked Sendable
{
  let preflight: ImageDecodeResourceLedgerSnapshot?
  var preflightCallCount = 0
  var resourceAwareFinishCallCount = 0
  var legacyFinishCallCount = 0

  init(preflight: ImageDecodeResourceLedgerSnapshot?) {
    self.preflight = preflight
  }

  var receivedByteCount: Int { 0 }

  func append(_ chunk: Data) throws -> ImageProgressiveDecodeGeneration? { nil }

  func finish() throws {}

  func cancel() {}

  func decodedImageFinalizationResourceLedger() throws
    -> ImageDecodeResourceLedgerSnapshot?
  {
    preflightCallCount += 1
    return preflight
  }

  func finishWithDecodedImageResourceAuthority() throws
    -> ImageProgressiveDecodedImageResourceFinalization
  {
    resourceAwareFinishCallCount += 1
    throw StubError.consumingFinalizerMustNotRun
  }

  func finishWithFinalImage() throws -> ImageProgressiveDecodeFinalization {
    legacyFinishCallCount += 1
    throw StubError.consumingFinalizerMustNotRun
  }
}

private final class LegacyOnlySession:
  ProgressiveImageFinalizingSession,
  @unchecked Sendable
{
  var legacyFinishCallCount = 0

  var receivedByteCount: Int { 0 }

  func append(_ chunk: Data) throws -> ImageProgressiveDecodeGeneration? { nil }

  func finish() throws {}

  func cancel() {}

  func finishWithFinalImage() throws -> ImageProgressiveDecodeFinalization {
    legacyFinishCallCount += 1
    throw StubError.consumingFinalizerMustNotRun
  }
}

private enum StubError: Error {
  case consumingFinalizerMustNotRun
}
