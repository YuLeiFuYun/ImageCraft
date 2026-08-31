import Foundation
import ImageCraftCore
import XCTest

private enum ResourceAwareFinalizationStubError: Error {
    case expected
}

private final class ResourceAwareFinalizationStub:
    ProgressiveImageDecodedImageResourceFinalizingSession, @unchecked Sendable
{
    private(set) var receivedByteCount = 0

    func append(_ chunk: Data) throws -> ImageProgressiveDecodeGeneration? {
        receivedByteCount += chunk.count
        return nil
    }

    func finish() throws {}

    func cancel() {}

    func decodedImageFinalizationResourceLedger() throws
        -> ImageDecodeResourceLedgerSnapshot?
    {
        ImageDecodeResourceLedgerSnapshot(
            retainedKnownBytes: 0,
            retainedBetweenCalls: .bounded(0),
            operationPeak: .unknown(.frameworkPrivateOperationAllocation),
            transferredOutput: .bounded(2),
            outputLayoutAuthority: .codecOwnedRGB8
        )
    }

    func finishWithDecodedImageResourceAuthority() throws
        -> ImageProgressiveDecodedImageResourceFinalization
    {
        throw ResourceAwareFinalizationStubError.expected
    }
}

final class ImageCodecContractTests: XCTestCase {
    func testPreparationCreationResourceAuthoritySeparatesOperationFromResultingState() throws {
        let operation = try XCTUnwrap(
            ImageDecodeResourceLedgerSnapshot(
                retainedKnownBytes: 787,
                retainedBetweenCalls: .bounded(787),
                operationPeak: .unknown(.frameworkPrivateOperationAllocation),
                transferredOutput: .bounded(0),
                outputLayoutAuthority: .none
            )
        )
        let authority = try XCTUnwrap(
            ImageProgressivePreparationCreationResourceAuthority(
                operationResourceLedger: operation,
                resultingPreparationRetainedKnownBytes: 1_024,
                resultingPreparationRetainedBetweenCalls: .bounded(1_024)
            )
        )
        XCTAssertEqual(authority.operationResourceLedger, operation)
        XCTAssertEqual(authority.resultingPreparationRetainedKnownBytes, 1_024)
        XCTAssertEqual(authority.resultingPreparationRetainedBetweenCalls, .bounded(1_024))
        XCTAssertNil(
            ImageProgressivePreparationCreationResourceAuthority(
                operationResourceLedger: operation,
                resultingPreparationRetainedKnownBytes: 1_024,
                resultingPreparationRetainedBetweenCalls: .bounded(1_023)
            )
        )
        XCTAssertNotNil(
            ImageProgressivePreparationCreationResourceAuthority(
                operationResourceLedger: operation,
                resultingPreparationRetainedKnownBytes: 1_024,
                resultingPreparationRetainedBetweenCalls: .unknown(.frameworkPrivateRetainedState)
            )
        )
    }

    func testResourceAwareDecodedImageFinalizationIsPublicCoreCapability() throws {
        let concrete = ResourceAwareFinalizationStub()
        let base: any ImageProgressiveDecodeSession = concrete
        let capability = try XCTUnwrap(
            base as? any ProgressiveImageDecodedImageResourceFinalizingSession
        )
        XCTAssertNil(try capability.append(Data([0x01, 0x02])))
        XCTAssertEqual(capability.receivedByteCount, 2)
        let preflight = try XCTUnwrap(capability.decodedImageFinalizationResourceLedger())
        XCTAssertEqual(
            preflight.operationPeak,
            .unknown(.frameworkPrivateOperationAllocation)
        )
        XCTAssertEqual(preflight.transferredOutput, .bounded(2))
        XCTAssertThrowsError(try capability.finishWithDecodedImageResourceAuthority()) { error in
            XCTAssertTrue(error is ResourceAwareFinalizationStubError)
        }
    }

    func testPublicResourceLedgerPreservesFrameworkPrivateUnknownAuthority() throws {
        let ledger = try XCTUnwrap(
            ImageDecodeResourceLedgerSnapshot(
                retainedKnownBytes: 0,
                retainedBetweenCalls: .bounded(0),
                operationPeak: .unknown(.frameworkPrivateOperationAllocation),
                transferredOutput: .bounded(897),
                outputLayoutAuthority: .codecOwnedRGB8
            )
        )
        XCTAssertEqual(ledger.retainedKnownBytes, 0)
        XCTAssertEqual(ledger.retainedBetweenCalls, .bounded(0))
        XCTAssertEqual(
            ledger.operationPeak,
            .unknown(.frameworkPrivateOperationAllocation)
        )
        XCTAssertEqual(ledger.transferredOutput, .bounded(897))
        XCTAssertEqual(ledger.outputLayoutAuthority, .codecOwnedRGB8)
        XCTAssertNil(ledger.bytesUpperBound(for: .operationPeak))
        XCTAssertEqual(ledger.bytesUpperBound(for: .transferredOutput), 897)
        XCTAssertEqual(
            ledger.branchCoexistenceBound(callerRetainedOutputBytes: 123),
            .unknown(.frameworkPrivateOperationAllocation)
        )
    }

    func testDescriptorReportsEveryUnsupportedCapabilityDeterministically() {
        let descriptor = makeDescriptor()
        XCTAssertNil(descriptor.supportFailure(for: baselineRequest()))
        XCTAssertEqual(
            descriptor.supportFailure(for: request(delivery: .progressiveGenerations)),
            .deliveryMode(.progressiveGenerations)
        )
        XCTAssertEqual(
            descriptor.supportFailure(for: request(track: .animatedSequence)),
            .trackMode(.animatedSequence)
        )
        XCTAssertEqual(
            descriptor.supportFailure(for: request(metadata: [.frameTiming])),
            .metadata(.frameTiming)
        )
        XCTAssertEqual(
            descriptor.supportFailure(for: request(dynamicRange: .high)),
            .dynamicRange(.high)
        )
        XCTAssertEqual(
            descriptor.supportFailure(for: request(output: .pixelBuffer)),
            .outputRepresentation(.pixelBuffer)
        )
        XCTAssertEqual(
            descriptor.supportFailure(for: request(cancellation: .interruptible)),
            .cancellation(required: .interruptible, available: .operationBoundary)
        )
    }

    func testCapabilitySupersetCannotInvalidatePreviouslySupportedRequest() {
        let baseline = makeDescriptor()
        let request = baselineRequest()
        XCTAssertTrue(baseline.supports(request))

        let superset = ImageCodecDescriptor(
            identifier: ImageCodecIdentifier(rawValue: "test.superset"),
            implementationVersion: 1,
            capabilities: ImageCodecCapabilities(
                formats: Set(EncodedImageFormat.allCases),
                deliveryModes: Set(ImageDecodeDeliveryMode.allCases),
                progressiveFormats: Set(EncodedImageFormat.allCases),
                trackModes: Set(ImageDecodeTrackMode.allCases),
                metadata: Set(ImageDecodeMetadataCapability.allCases),
                dynamicRanges: Set(ImageDecodeDynamicRange.allCases),
                outputRepresentations: Set(ImageDecodeOutputRepresentation.allCases),
                cancellationMode: .interruptible
            )
        )
        XCTAssertTrue(superset.supports(request))
    }

    func testMissingProgressiveFormatFieldFailsClosed() throws {
        let capabilities = ImageCodecCapabilities(
            formats: [.jpeg],
            deliveryModes: [.completeFrame, .progressiveGenerations],
            progressiveFormats: [.jpeg],
            trackModes: [.primaryFrame],
            metadata: [.orientation],
            dynamicRanges: [.standard],
            outputRepresentations: [.coreGraphicsImage],
            cancellationMode: .operationBoundary
        )
        let encoded = try JSONEncoder().encode(capabilities)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "progressiveFormats")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ImageCodecCapabilities.self, from: legacy)

        XCTAssertEqual(decoded.progressiveFormats, [])
        let descriptor = ImageCodecDescriptor(
            identifier: ImageCodecIdentifier(rawValue: "test.legacy-capabilities"),
            implementationVersion: 1,
            capabilities: decoded
        )
        XCTAssertEqual(
            descriptor.supportFailure(
                for: ImageDecodeCapabilityRequest(
                    format: .jpeg,
                    deliveryMode: .progressiveGenerations
                )
            ),
            .deliveryMode(.progressiveGenerations)
        )
    }

    func testConservativeResourceEstimateNeverTrustsBackendUnderreporting() throws {
        XCTAssertEqual(
            try ImageDecodeResourceEstimate.conservativeMaximum(
                genericBytes: 4_096,
                backendBytes: 1
            ).workingSetBytes,
            4_096
        )
        XCTAssertEqual(
            try ImageDecodeResourceEstimate.conservativeMaximum(
                genericBytes: 4_096,
                backendBytes: 8_192
            ).workingSetBytes,
            8_192
        )
        XCTAssertThrowsError(
            try ImageDecodeResourceEstimate.conservativeMaximum(
                genericBytes: 0,
                backendBytes: 1
            )
        ) { XCTAssertEqual($0 as? ImageCodecContractError, .invalidResourceEstimate) }
    }

    func testPreparationLimitsHaveIndependentBoundedDefaultsAndStrictCodable() throws {
        let defaults = ImageDecodePreparationLimits.coreV1
        XCTAssertEqual(defaults.maximumEntryCount, 1_024)
        XCTAssertEqual(defaults.maximumRetainedByteCharge, 64 * 1_024 * 1_024)

        let normalized = ImageDecodePreparationLimits(
            maximumEntryCount: 0,
            maximumRetainedByteCharge: 0
        )
        XCTAssertEqual(normalized.maximumEntryCount, 1)
        XCTAssertEqual(normalized.maximumRetainedByteCharge, 1)

        let encoded = try JSONEncoder().encode(defaults)
        XCTAssertEqual(
            try JSONDecoder().decode(ImageDecodePreparationLimits.self, from: encoded),
            defaults
        )

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["maximumRetainedByteCharge"] = 0
        let invalid = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try JSONDecoder().decode(ImageDecodePreparationLimits.self, from: invalid)
        )
    }

    private func makeDescriptor() -> ImageCodecDescriptor {
        ImageCodecDescriptor(
            identifier: ImageCodecIdentifier(rawValue: "test.codec"),
            implementationVersion: 7,
            capabilities: ImageCodecCapabilities(
                formats: [.png],
                deliveryModes: [.completeFrame],
                progressiveFormats: [],
                trackModes: [.primaryFrame],
                metadata: [.orientation, .sourceColorProfile],
                dynamicRanges: [.standard],
                outputRepresentations: [.coreGraphicsImage],
                cancellationMode: .operationBoundary
            )
        )
    }

    private func baselineRequest() -> ImageDecodeCapabilityRequest {
        request(metadata: [.orientation, .sourceColorProfile])
    }

    private func request(
        delivery: ImageDecodeDeliveryMode = .completeFrame,
        track: ImageDecodeTrackMode = .primaryFrame,
        metadata: Set<ImageDecodeMetadataCapability> = [.orientation],
        dynamicRange: ImageDecodeDynamicRange = .standard,
        output: ImageDecodeOutputRepresentation = .coreGraphicsImage,
        cancellation: ImageDecodeCancellationMode = .operationBoundary
    ) -> ImageDecodeCapabilityRequest {
        ImageDecodeCapabilityRequest(
            format: .png,
            deliveryMode: delivery,
            trackMode: track,
            requiredMetadata: metadata,
            dynamicRange: dynamicRange,
            outputRepresentation: output,
            cancellationMode: cancellation
        )
    }
}
