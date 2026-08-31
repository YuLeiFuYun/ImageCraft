import Dispatch
import CoreGraphics
import Foundation
import XCTest

@testable import ImageCraftCore
@testable import ImageCraftImageIO

final class JPEGIndependentProgressive420SessionQualificationTests: XCTestCase {
  private final class ConcurrentTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedWriterError: Error?
    private var storedSnapshotsWereValid = true

    func record(writerError: Error) {
      lock.lock()
      storedWriterError = writerError
      lock.unlock()
    }

    func invalidateSnapshot() {
      lock.lock()
      storedSnapshotsWereValid = false
      lock.unlock()
    }

    var writerError: Error? {
      lock.lock()
      defer { lock.unlock() }
      return storedWriterError
    }

    var snapshotsWereValid: Bool {
      lock.lock()
      defer { lock.unlock() }
      return storedSnapshotsWereValid
    }
  }

  func testQualificationMapsReclaimedInputAndKeepsPackedRepresentationSeparate() throws {
    let data = try fixture(named: "jpeg-progressive-420.jpg")
    let plan = try JPEGIndependentProgressive420StatePlan.inspect(data)
    let referenceCharge = plan.totalStateBytes + plan.width * plan.height * 3
    let reference = try JPEGIndependentProgressive420Decoder(
      maximumOperationByteCharge: referenceCharge
    ).decode(data)
    let sessionCharge = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(
        statePlan: plan,
        outputByteCount: reference.rgb.count,
        previewCadence: .finalOnly
      )
    let maximumRetainedCharge = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .retainedByteChargeBeforeFinalOnlyFinish(statePlan: plan)
    let retainedCharge = reference.rgb.count
    XCTAssertEqual(maximumRetainedCharge, 4_158)
    XCTAssertEqual(retainedCharge, 897)
    let adapter = try JPEGIndependentProgressive420SessionQualification(
      maximumCodecOwnedByteCharge: sessionCharge,
      previewCadence: .finalOnly
    )

    let initial = adapter.qualificationSnapshot
    XCTAssertNil(initial.inputProfile)
    XCTAssertEqual(initial.progress, .needMoreInput)
    XCTAssertEqual(initial.receivedByteCount, 0)
    XCTAssertEqual(initial.retainedEncodedBytes, 0)
    XCTAssertEqual(
      initial.maximumRetainedEncodedBytes,
      JPEGIndependentProgressive420Decoder.IncrementalSession.transportCapacityBytes
    )
    XCTAssertEqual(initial.maximumTightRGBABytes, 0)
    XCTAssertFalse(initial.retainsOpaqueFrameworkStateBetweenCalls)
    XCTAssertEqual(initial.previewSemanticState, .none)
    XCTAssertEqual(
      initial.resourceLedger.bytesUpperBound(for: .retainedBetweenCalls),
      JPEGIndependentProgressive420Decoder.IncrementalSession.transportCapacityBytes
    )

    var offset = 0
    while offset < data.count {
      let end = min(data.count, offset + 31)
      XCTAssertNil(try adapter.append(data.subdata(in: offset..<end)))
      let snapshot = adapter.qualificationSnapshot
      XCTAssertEqual(snapshot.receivedByteCount, end)
      XCTAssertGreaterThanOrEqual(snapshot.consumedThrough, 0)
      XCTAssertLessThanOrEqual(snapshot.consumedThrough, snapshot.receivedByteCount)
      XCTAssertLessThanOrEqual(
        snapshot.retainedEncodedBytes,
        snapshot.maximumRetainedEncodedBytes
      )
      if snapshot.retainedEncodedBytes == 0 {
        XCTAssertEqual(snapshot.retainFrom, snapshot.receivedByteCount)
      } else {
        XCTAssertEqual(snapshot.retainFrom, snapshot.consumedThrough)
      }
      XCTAssertFalse(snapshot.retainsOpaqueFrameworkStateBetweenCalls)
      XCTAssertEqual(snapshot.maximumTightRGBABytes, 0)
      XCTAssertTrue(snapshot.tentativeFacts.isEmpty)
      XCTAssertEqual(snapshot.previewSemanticState, .none)
      if snapshot.inputProfile != nil {
        XCTAssertEqual(snapshot.inputProfile, .arbitraryChunk)
        XCTAssertEqual(snapshot.stableFacts, [.dimensions, .frameCount])
        XCTAssertGreaterThan(
          snapshot.resourceLedger.bytesUpperBound(for: .retainedBetweenCalls) ?? 0,
          snapshot.retainedEncodedBytes
        )
        XCTAssertEqual(
          snapshot.resourceLedger.outputLayoutAuthority,
          .codecOwnedRGB8
        )
      }
      offset = end
    }

    let ready = adapter.qualificationSnapshot
    XCTAssertEqual(ready.progress, .finalReady)
    XCTAssertEqual(ready.receivedByteCount, data.count)
    XCTAssertEqual(ready.consumedThrough, data.count)
    XCTAssertEqual(ready.retainFrom, data.count)
    XCTAssertEqual(ready.retainedEncodedBytes, 0)
    XCTAssertEqual(ready.inputProfile, .arbitraryChunk)
    XCTAssertEqual(ready.stableFacts, [.dimensions, .frameCount])
    XCTAssertEqual(ready.previewSemanticState, .none)
    XCTAssertEqual(
      ready.resourceLedger.bytesUpperBound(for: .retainedBetweenCalls),
      retainedCharge
    )
    XCTAssertEqual(ready.resourceLedger.bytesUpperBound(for: .operationPeak), sessionCharge)
    XCTAssertEqual(
      ready.resourceLedger.bytesUpperBound(for: .transferredOutput),
      reference.rgb.count
    )

    let final = try adapter.finishWithKernelImage()
    XCTAssertEqual(final.rgb, reference.rgb)
    XCTAssertEqual(final.scanCount, reference.scanCount)
    let terminal = adapter.qualificationSnapshot
    XCTAssertEqual(terminal.progress, .terminal)
    XCTAssertEqual(terminal.receivedByteCount, data.count)
    XCTAssertEqual(terminal.retainedEncodedBytes, 0)
    XCTAssertEqual(terminal.retainFrom, data.count)
    XCTAssertEqual(terminal.inputProfile, .arbitraryChunk)
    XCTAssertEqual(terminal.stableFacts, [.dimensions, .frameCount])
    XCTAssertEqual(terminal.previewSemanticState, .finalStable)
    XCTAssertTrue(terminal.resourceLedger.isTerminal)
  }

  func testQualificationPreAcceptanceEncodedLimitFailureRemainsRetryable() throws {
    let data = try fixture(named: "jpeg-progressive-420.jpg")
    let plan = try JPEGIndependentProgressive420StatePlan.inspect(data)
    let sessionCharge = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(
        statePlan: plan,
        outputByteCount: plan.width * plan.height * 3,
        previewCadence: .finalOnly
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
    let adapter = try JPEGIndependentProgressive420SessionQualification(
      maximumCodecOwnedByteCharge: sessionCharge,
      limits: limits,
      previewCadence: .finalOnly
    )

    let prefixCount = 100
    XCTAssertNil(try adapter.append(data.prefix(prefixCount)))
    let before = adapter.qualificationSnapshot
    XCTAssertThrowsError(try adapter.append(data)) { error in
      XCTAssertEqual(error as? ImageCraftError, .encodedBytesExceeded)
    }
    let after = adapter.qualificationSnapshot
    XCTAssertEqual(after.receivedByteCount, before.receivedByteCount)
    XCTAssertEqual(after.consumedThrough, before.consumedThrough)
    XCTAssertEqual(after.retainFrom, before.retainFrom)
    XCTAssertEqual(after.retainedEncodedBytes, before.retainedEncodedBytes)
    XCTAssertEqual(after.progress, before.progress)
    XCTAssertEqual(after.resourceLedger, before.resourceLedger)

    XCTAssertNil(try adapter.append(data.dropFirst(prefixCount)))
    let finalization = try adapter.finishWithPackedRGB8()
    XCTAssertEqual(finalization.sourceByteCount, data.count)
    let final = finalization.image
    XCTAssertEqual(final.pixelWidth, plan.width)
    XCTAssertEqual(final.pixelHeight, plan.height)
    XCTAssertEqual(final.bytesPerRow, plan.width * 3)
    XCTAssertEqual(final.format, .rgb8)
    XCTAssertEqual(final.colorEncoding, .sRGB)
    XCTAssertEqual(final.sourceColorProfile, .absent)
    XCTAssertEqual(final.transferredByteCharge, plan.width * plan.height * 3)
  }

  func testQualificationFatalAcceptedInputTerminalizesAndFencesLateCalls() throws {
    let adapter = try JPEGIndependentProgressive420SessionQualification(
      maximumCodecOwnedByteCharge: 1_000_000
    )
    XCTAssertThrowsError(try adapter.append(Data([0x00, 0x00]))) { error in
      XCTAssertEqual(error as? ImageCraftError, .formatMismatch)
    }
    let failed = adapter.qualificationSnapshot
    XCTAssertEqual(failed.progress, .terminal)
    XCTAssertEqual(failed.receivedByteCount, 2)
    XCTAssertEqual(failed.retainedEncodedBytes, 0)
    XCTAssertEqual(failed.retainFrom, 2)
    XCTAssertTrue(failed.resourceLedger.isTerminal)

    XCTAssertThrowsError(try adapter.append(Data([0xFF, 0xD8]))) { error in
      XCTAssertEqual(error as? ImageCraftError, .progressiveSessionFinished)
    }
    XCTAssertThrowsError(try adapter.finish()) { error in
      XCTAssertEqual(error as? ImageCraftError, .progressiveSessionFinished)
    }
  }

  func testQualificationCancellationReclaimsAndUsesPublicCancellationFence() throws {
    let data = try fixture(named: "jpeg-progressive-420.jpg")
    let adapter = try JPEGIndependentProgressive420SessionQualification(
      maximumCodecOwnedByteCharge: 1_000_000
    )
    XCTAssertNil(try adapter.append(data.prefix(data.count / 2)))
    adapter.cancel()
    adapter.cancel()

    let cancelled = adapter.qualificationSnapshot
    XCTAssertEqual(cancelled.progress, .terminal)
    XCTAssertEqual(cancelled.retainedEncodedBytes, 0)
    XCTAssertTrue(cancelled.resourceLedger.isTerminal)
    XCTAssertThrowsError(try adapter.append(Data())) { error in
      XCTAssertEqual(error as? ImageCraftError, .progressiveSessionCancelled)
    }
    XCTAssertThrowsError(try adapter.finish()) { error in
      XCTAssertEqual(error as? ImageCraftError, .progressiveSessionCancelled)
    }
  }

  func testQualificationConcurrentReadsSerializeAgainstSingleOrderedWriter() throws {
    let data = try fixture(named: "jpeg-progressive-420.jpg")
    let plan = try JPEGIndependentProgressive420StatePlan.inspect(data)
    let referenceCharge = plan.totalStateBytes + plan.width * plan.height * 3
    let reference = try JPEGIndependentProgressive420Decoder(
      maximumOperationByteCharge: referenceCharge
    ).decode(data)
    let sessionCharge = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(
        statePlan: plan,
        outputByteCount: plan.width * plan.height * 3,
        previewCadence: .finalOnly
      )
    let adapter = try JPEGIndependentProgressive420SessionQualification(
      maximumCodecOwnedByteCharge: sessionCharge,
      previewCadence: .finalOnly
    )

    let group = DispatchGroup()
    let queue = DispatchQueue.global(qos: .userInitiated)
    let concurrentState = ConcurrentTestState()

    group.enter()
    queue.async {
      defer { group.leave() }
      do {
        var offset = 0
        while offset < data.count {
          let end = min(data.count, offset + 7)
          _ = try adapter.append(data.subdata(in: offset..<end))
          offset = end
        }
      } catch {
        concurrentState.record(writerError: error)
      }
    }

    for _ in 0..<8 {
      group.enter()
      queue.async {
        defer { group.leave() }
        for _ in 0..<200 {
          let snapshot = adapter.qualificationSnapshot
          if snapshot.consumedThrough > snapshot.receivedByteCount
            || snapshot.retainedEncodedBytes > snapshot.maximumRetainedEncodedBytes
          {
            concurrentState.invalidateSnapshot()
          }
          _ = adapter.receivedByteCount
        }
      }
    }
    group.wait()

    XCTAssertNil(concurrentState.writerError)
    XCTAssertTrue(concurrentState.snapshotsWereValid)
    XCTAssertEqual(adapter.receivedByteCount, data.count)
    let final = try adapter.finishWithKernelImage()
    XCTAssertEqual(final.rgb, reference.rgb)
  }

  func testPackedRGB8ValueStandardizesColorAndReusesKernelPixelBacking() throws {
    let data = try fixture(named: "jpeg-progressive-420.jpg")
    let plan = try JPEGIndependentProgressive420StatePlan.inspect(data)
    let referenceCharge = plan.totalStateBytes + plan.width * plan.height * 3
    let kernelImage = try JPEGIndependentProgressive420Decoder(
      maximumOperationByteCharge: referenceCharge
    ).decode(data)
    let packed = try JPEGIndependentProgressive420SessionQualification.packedRGB8Value(
      from: kernelImage
    )

    XCTAssertEqual(packed.data, kernelImage.rgb)
    XCTAssertEqual(packed.pixelWidth, kernelImage.width)
    XCTAssertEqual(packed.pixelHeight, kernelImage.height)
    XCTAssertEqual(packed.bytesPerRow, kernelImage.width * 3)
    XCTAssertEqual(packed.format, .rgb8)
    XCTAssertEqual(packed.colorEncoding, .sRGB)
    XCTAssertEqual(packed.sourceColorProfile, .absent)
    XCTAssertEqual(packed.pixelByteCharge, kernelImage.rgb.count)
    XCTAssertEqual(packed.transferredByteCharge, kernelImage.rgb.count)

    let kernelAddress = kernelImage.rgb.withUnsafeBytes { raw -> UInt? in
      raw.baseAddress.map { UInt(bitPattern: $0) }
    }
    let packedAddress = packed.data.withUnsafeBytes { raw -> UInt? in
      raw.baseAddress.map { UInt(bitPattern: $0) }
    }
    XCTAssertNotNil(kernelAddress)
    XCTAssertEqual(packedAddress, kernelAddress)
  }

  func testPackedRGB8FinalizationIsDiscoverableThroughBackendNeutralCapability() throws {
    let data = try fixture(named: "jpeg-progressive-420.jpg")
    let plan = try JPEGIndependentProgressive420StatePlan.inspect(data)
    let sessionCharge = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(
        statePlan: plan,
        outputByteCount: plan.width * plan.height * 3,
        previewCadence: .finalOnly
      )
    let adapter = try JPEGIndependentProgressive420SessionQualification(
      maximumCodecOwnedByteCharge: sessionCharge,
      previewCadence: .finalOnly
    )
    let baseSession: any ImageProgressiveDecodeSession = adapter
    let packedCapability = try XCTUnwrap(
      baseSession as? any ProgressiveImagePackedRGB8FinalizingSession
    )

    var offset = 0
    while offset < data.count {
      let end = min(data.count, offset + 17)
      XCTAssertNil(try packedCapability.append(data.subdata(in: offset..<end)))
      offset = end
    }
    let ready = adapter.qualificationSnapshot
    XCTAssertEqual(ready.progress, .finalReady)
    XCTAssertEqual(
      ready.resourceLedger.bytesUpperBound(for: .transferredOutput),
      plan.width * plan.height * 3
    )

    let finalization = try packedCapability.finishWithPackedRGB8()
    XCTAssertEqual(finalization.sourceByteCount, data.count)
    XCTAssertEqual(finalization.image.pixelWidth, plan.width)
    XCTAssertEqual(finalization.image.pixelHeight, plan.height)
    XCTAssertEqual(finalization.image.colorEncoding, .sRGB)
    XCTAssertEqual(finalization.image.sourceColorProfile, .absent)
    XCTAssertEqual(
      finalization.image.transferredByteCharge,
      ready.resourceLedger.bytesUpperBound(for: .transferredOutput)
    )
    XCTAssertEqual(adapter.qualificationSnapshot.progress, .terminal)
  }

  func testPackedRGB8DecodedImageMaterializerKeepsPixelAuthorityButFrameworkPeakUnknown() throws {
    let data = try fixture(named: "jpeg-progressive-420.jpg")
    let plan = try JPEGIndependentProgressive420StatePlan.inspect(data)
    let charge = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(
        statePlan: plan,
        outputByteCount: plan.width * plan.height * 3,
        previewCadence: .finalOnly
      )
    let adapter = try JPEGIndependentProgressive420SessionQualification(
      maximumCodecOwnedByteCharge: charge,
      previewCadence: .finalOnly
    )
    XCTAssertNil(try adapter.append(data))
    let packed = try adapter.finishWithPackedRGB8().image
    let materialized = try ImagePackedRGB8DecodedImageMaterializer.materialize(packed)
    let cgImage = materialized.image.cgImage

    XCTAssertEqual(materialized.copiedPixelPayloadByteCount, 0)
    XCTAssertTrue(materialized.providerBackingWasShared)
    XCTAssertEqual(cgImage.width, packed.pixelWidth)
    XCTAssertEqual(cgImage.height, packed.pixelHeight)
    XCTAssertEqual(cgImage.bytesPerRow, packed.bytesPerRow)
    XCTAssertEqual(cgImage.bitsPerComponent, 8)
    XCTAssertEqual(cgImage.bitsPerPixel, 24)
    XCTAssertEqual(cgImage.alphaInfo, .none)
    XCTAssertEqual(materialized.image.colorDescription.sourceProfile, .absent)
    XCTAssertEqual(
      materialized.resourceLedger.retainedBetweenCalls,
      .bounded(0)
    )
    XCTAssertEqual(
      materialized.resourceLedger.operationPeak,
      .unknown(.frameworkPrivateOperationAllocation)
    )
    XCTAssertEqual(
      materialized.resourceLedger.transferredOutput,
      .bounded(packed.transferredByteCharge)
    )
    XCTAssertEqual(materialized.resourceLedger.outputLayoutAuthority, .codecOwnedRGB8)

    let providerData = cgImage.dataProvider?.data as Data?
    XCTAssertEqual(providerData, packed.data)
    let packedAddress = packed.data.withUnsafeBytes { raw -> UInt? in
      raw.baseAddress.map { UInt(bitPattern: $0) }
    }
    let providerAddress = cgImage.dataProvider?.data.flatMap { data in
      CFDataGetBytePtr(data).map { UInt(bitPattern: $0) }
    }
    XCTAssertNotNil(packedAddress)
    XCTAssertEqual(providerAddress, packedAddress)
  }

  func testCFDataProviderCanRetainPackedRGBBackingWithoutSecondPixelPayload() throws {
    let data = try fixture(named: "jpeg-progressive-420.jpg")
    let plan = try JPEGIndependentProgressive420StatePlan.inspect(data)
    let charge = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(
        statePlan: plan,
        outputByteCount: plan.width * plan.height * 3,
        previewCadence: .finalOnly
      )
    let adapter = try JPEGIndependentProgressive420SessionQualification(
      maximumCodecOwnedByteCharge: charge,
      previewCadence: .finalOnly
    )
    XCTAssertNil(try adapter.append(data))
    let packed = try adapter.finishWithPackedRGB8().image
    let packedAddress = packed.data.withUnsafeBytes { raw -> UInt? in
      raw.baseAddress.map { UInt(bitPattern: $0) }
    }

    let provider = try XCTUnwrap(CGDataProvider(data: packed.data as CFData))
    let providerData = try XCTUnwrap(provider.data)
    let providerAddress = CFDataGetBytePtr(providerData).map { UInt(bitPattern: $0) }

    XCTAssertNotNil(packedAddress)
    XCTAssertEqual(providerData as Data, packed.data)
    XCTAssertEqual(providerAddress, packedAddress)
  }

  func testNoCopyDecodedImageProviderRetainsPackedBytesAfterPackedValueDies() throws {
    let source = try fixture(named: "jpeg-progressive-420.jpg")
    let plan = try JPEGIndependentProgressive420StatePlan.inspect(source)
    let charge = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(
        statePlan: plan,
        outputByteCount: plan.width * plan.height * 3,
        previewCadence: .finalOnly
      )

    var expectedPrefix: [UInt8] = []
    let decodedImage: DecodedImage = try {
      let adapter = try JPEGIndependentProgressive420SessionQualification(
        maximumCodecOwnedByteCharge: charge,
        previewCadence: .finalOnly
      )
      XCTAssertNil(try adapter.append(source))
      let packed = try adapter.finishWithPackedRGB8().image
      expectedPrefix = Array(packed.data.prefix(32))
      let result = try ImagePackedRGB8DecodedImageMaterializer.materialize(packed)
      XCTAssertTrue(result.providerBackingWasShared)
      XCTAssertEqual(result.copiedPixelPayloadByteCount, 0)
      return result.image
    }()

    let providerData = try XCTUnwrap(decodedImage.cgImage.dataProvider?.data as Data?)
    XCTAssertEqual(providerData.count, plan.width * plan.height * 3)
    XCTAssertEqual(Array(providerData.prefix(expectedPrefix.count)), expectedPrefix)
  }

  func testDecodedImageResourceFinalizationCapabilityKeepsFrameworkUnknownVisible() throws {
    let source = try fixture(named: "jpeg-progressive-420.jpg")
    let plan = try JPEGIndependentProgressive420StatePlan.inspect(source)
    let charge = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(
        statePlan: plan,
        outputByteCount: plan.width * plan.height * 3,
        previewCadence: .finalOnly
      )
    let adapter = try JPEGIndependentProgressive420SessionQualification(
      maximumCodecOwnedByteCharge: charge,
      previewCadence: .finalOnly
    )
    let baseSession: any ImageProgressiveDecodeSession = adapter
    let resourceAware = try XCTUnwrap(
      baseSession as? any ProgressiveImageDecodedImageResourceFinalizingSession
    )
    XCTAssertNil(baseSession as? any ProgressiveImageFinalizingSession)

    var offset = 0
    while offset < source.count {
      let end = min(source.count, offset + 17)
      XCTAssertNil(try resourceAware.append(source.subdata(in: offset..<end)))
      offset = end
    }
    let ready = adapter.qualificationSnapshot
    XCTAssertEqual(ready.progress, .finalReady)
    XCTAssertEqual(
      ready.resourceLedger.transferredOutput,
      .bounded(plan.width * plan.height * 3)
    )

    let finalization = try resourceAware.finishWithDecodedImageResourceAuthority()
    let inspection = try EncodedImageSecurityInspector.inspect(
      source,
      maximumMetadataBytes: DecodeLimits.coreV1.maximumMetadataBytes,
      materializePNGICCProfile: false,
      materializeJPEGICCProfile: false
    )
    XCTAssertEqual(finalization.sourceByteCount, source.count)
    XCTAssertEqual(finalization.probe.pixelWidth, plan.width)
    XCTAssertEqual(finalization.probe.pixelHeight, plan.height)
    XCTAssertEqual(finalization.probe.frameCount, 1)
    XCTAssertEqual(finalization.probe.orientation, 1)
    XCTAssertEqual(finalization.probe.format, .jpeg)
    XCTAssertEqual(finalization.probe.metadataByteCount, inspection.metadataByteCount)
    XCTAssertEqual(finalization.probe.auxiliaryAttachmentCount, 0)
    XCTAssertEqual(finalization.probe.sourceColorProfile, .absent)
    XCTAssertEqual(finalization.image.cgImage.width, plan.width)
    XCTAssertEqual(finalization.image.cgImage.height, plan.height)
    XCTAssertEqual(finalization.image.cgImage.bytesPerRow, plan.width * 3)
    XCTAssertEqual(finalization.image.colorDescription.sourceProfile, .absent)
    XCTAssertEqual(
      finalization.materializationResourceLedger.operationPeak,
      .unknown(.frameworkPrivateOperationAllocation)
    )
    XCTAssertEqual(
      finalization.materializationResourceLedger.transferredOutput,
      ready.resourceLedger.transferredOutput
    )
    XCTAssertEqual(
      finalization.materializationResourceLedger.outputLayoutAuthority,
      .codecOwnedRGB8
    )
    XCTAssertEqual(adapter.qualificationSnapshot.progress, .terminal)
  }

  func testDecodedImageResourceFinalizationPreflightExposesUnknownBeforeMaterialization() throws {
    let source = try fixture(named: "jpeg-progressive-420.jpg")
    let plan = try JPEGIndependentProgressive420StatePlan.inspect(source)
    let charge = try JPEGIndependentProgressive420Decoder.IncrementalSession
      .requiredOperationPeakByteCharge(
        statePlan: plan,
        outputByteCount: plan.width * plan.height * 3,
        previewCadence: .finalOnly
      )
    let adapter = try JPEGIndependentProgressive420SessionQualification(
      maximumCodecOwnedByteCharge: charge,
      previewCadence: .finalOnly
    )
    let baseSession: any ImageProgressiveDecodeSession = adapter
    let resourceAware = try XCTUnwrap(
      baseSession as? any ProgressiveImageDecodedImageResourceFinalizingSession
    )

    XCTAssertNil(try resourceAware.decodedImageFinalizationResourceLedger())
    let initial = adapter.qualificationSnapshot
    XCTAssertEqual(initial.progress, .needMoreInput)

    var offset = 0
    while offset < source.count {
      let end = min(source.count, offset + 17)
      XCTAssertNil(try resourceAware.append(source.subdata(in: offset..<end)))
      offset = end
    }
    let readyBeforePreflight = adapter.qualificationSnapshot
    XCTAssertEqual(readyBeforePreflight.progress, .finalReady)
    XCTAssertEqual(readyBeforePreflight.resourceLedger.retainedKnownBytes, plan.width * plan.height * 3)
    XCTAssertEqual(
      readyBeforePreflight.resourceLedger.retainedBetweenCalls,
      .bounded(plan.width * plan.height * 3)
    )

    let preflight = try XCTUnwrap(
      resourceAware.decodedImageFinalizationResourceLedger()
    )
    XCTAssertEqual(preflight.retainedKnownBytes, readyBeforePreflight.resourceLedger.retainedKnownBytes)
    XCTAssertEqual(preflight.retainedBetweenCalls, readyBeforePreflight.resourceLedger.retainedBetweenCalls)
    XCTAssertEqual(
      preflight.operationPeak,
      .unknown(.frameworkPrivateOperationAllocation)
    )
    XCTAssertEqual(
      preflight.transferredOutput,
      .bounded(plan.width * plan.height * 3)
    )
    XCTAssertEqual(preflight.outputLayoutAuthority, .codecOwnedRGB8)
    XCTAssertFalse(preflight.isTerminal)

    XCTAssertEqual(
      try resourceAware.decodedImageFinalizationResourceLedger(),
      preflight
    )
    XCTAssertEqual(adapter.qualificationSnapshot, readyBeforePreflight)

    let finalization = try resourceAware.finishWithDecodedImageResourceAuthority()
    XCTAssertEqual(finalization.materializationResourceLedger, preflight)
    XCTAssertEqual(adapter.qualificationSnapshot.progress, .terminal)
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
