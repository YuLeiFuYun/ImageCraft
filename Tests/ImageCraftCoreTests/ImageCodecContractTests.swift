import ImageCraftCore
import XCTest

final class ImageCodecContractTests: XCTestCase {
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
                trackModes: Set(ImageDecodeTrackMode.allCases),
                metadata: Set(ImageDecodeMetadataCapability.allCases),
                dynamicRanges: Set(ImageDecodeDynamicRange.allCases),
                outputRepresentations: Set(ImageDecodeOutputRepresentation.allCases),
                cancellationMode: .interruptible
            )
        )
        XCTAssertTrue(superset.supports(request))
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

    private func makeDescriptor() -> ImageCodecDescriptor {
        ImageCodecDescriptor(
            identifier: ImageCodecIdentifier(rawValue: "test.codec"),
            implementationVersion: 7,
            capabilities: ImageCodecCapabilities(
                formats: [.png],
                deliveryModes: [.completeFrame],
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
