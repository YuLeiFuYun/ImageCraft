import Foundation
import ImageCraftCore
import XCTest

final class ImageCodecConformanceTests: XCTestCase {
    func testDescriptorIsStableCurrentAndNonEmpty_ICT_001() throws {
        let codec = CodecUnderTest.make()
        let first = codec.codecDescriptor
        let second = CodecUnderTest.make().codecDescriptor

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.contractVersion, ImageCodecDescriptor.currentContractVersion)
        XCTAssertFalse(
            first.identifier.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertLessThanOrEqual(first.identifier.rawValue.utf8.count, 256)
        XCTAssertGreaterThan(first.implementationVersion, 0)
        XCTAssertFalse(first.decodeProfiles.isEmpty)
        for profile in first.decodeProfiles {
            XCTAssertFalse(profile.formats.isEmpty)
            XCTAssertFalse(profile.deliveryModes.isEmpty)
            XCTAssertFalse(profile.trackModes.isEmpty)
            XCTAssertFalse(profile.dynamicRanges.isEmpty)
            XCTAssertFalse(profile.outputRepresentations.isEmpty)
        }
        XCTAssertFalse(
            defaultStillFormats(first).isEmpty,
            "ImageCodec must advertise at least one complete primary-frame CGImage profile"
        )

        let progressiveProfileFormats = progressiveProfileFormats(first)
        if !progressiveProfileFormats.isEmpty {
            let progressive = try XCTUnwrap(codec as? any ProgressiveImageDecoding)
            let request = ImageDecodeRequest(
                target: try TargetPixels(width: 1, height: 1),
                contentMode: .fit,
                colorPolicy: .preserveSource
            )
            for format in progressiveProfileFormats.sorted(by: formatOrder) {
                let session = try progressive.makeProgressiveSession(
                    format: format,
                    request: request,
                    limits: fixtureLimits()
                )
                session.cancel()
            }
        }
        XCTAssertEqual(first.cacheFingerprint, second.cacheFingerprint)
    }

    func testFiniteCapabilityDomainMatchesIndependentOracle_ICT_002() throws {
        let descriptor = CodecUnderTest.make().codecDescriptor
        var checked = 0

        for request in finiteRequests() {
            let expectedFailure = independentFailure(descriptor.decodeProfiles, request)
            let expected = expectedFailure == nil
            let failure = descriptor.supportFailure(for: request)
            XCTAssertEqual(descriptor.supports(request), expected)
            XCTAssertEqual(failure, expectedFailure)
            if expected {
                XCTAssertNoThrow(try descriptor.requireSupport(request))
            } else {
                let expectedFailure = try XCTUnwrap(failure)
                XCTAssertThrowsError(try descriptor.requireSupport(request)) { error in
                    XCTAssertEqual(
                        error as? ImageCodecContractError,
                        .unsupportedCapability(expectedFailure)
                    )
                }
            }
            checked += 1
        }
        XCTAssertEqual(checked, 6_144)
    }

    func testAdvertisedFormatsProbeDeterministically_ICT_003() throws {
        let codec = CodecUnderTest.make()
        for format in advertisedFormats(codec.codecDescriptor).sorted(by: formatOrder) {
            let data = try fixtureData(for: format)
            let first = try codec.probe(data: data, limits: fixtureLimits())
            let second = try codec.probe(data: data, limits: fixtureLimits())

            XCTAssertEqual(first, second)
            XCTAssertEqual(first.format, format)
            XCTAssertEqual(first.pixelWidth, 2)
            XCTAssertEqual(first.pixelHeight, 2)
            XCTAssertGreaterThanOrEqual(first.frameCount, 1)
            XCTAssertTrue(
                codec.codecDescriptor.decodeProfiles.contains { profile in
                    profile.formats.contains(format)
                }
            )
        }
    }

    func testAdvertisedFormatsDecodeReferenceStillImage_ICT_004() throws {
        let codec = CodecUnderTest.make()
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: 1, height: 1),
            contentMode: .fit,
            colorPolicy: .convertToSRGB
        )
        for format in defaultStillFormats(codec.codecDescriptor).sorted(by: formatOrder) {
            let data = try fixtureData(for: format)
            let probe = try codec.probe(data: data, limits: fixtureLimits())
            let first = try codec.decode(
                data: data,
                probe: probe,
                request: request,
                limits: fixtureLimits()
            )
            let second = try codec.decode(
                data: data,
                probe: probe,
                request: request,
                limits: fixtureLimits()
            )

            XCTAssertEqual(first.pixelWidth, 1)
            XCTAssertEqual(first.pixelHeight, 1)
            XCTAssertEqual(second.pixelWidth, first.pixelWidth)
            XCTAssertEqual(second.pixelHeight, first.pixelHeight)
            XCTAssertGreaterThan(first.pixelFormat.bitsPerComponent, 0)
            XCTAssertGreaterThan(first.pixelFormat.bitsPerPixel, 0)
            XCTAssertGreaterThan(first.pixelFormat.bytesPerRow, 0)
            XCTAssertGreaterThan(first.estimatedByteCost, 0)
            XCTAssertFalse(first.colorDescription.outputColorSpaceName.isEmpty)
        }
    }

    func testResourceEstimatesArePositiveDeterministicAndComposable_ICT_005() throws {
        let codec = CodecUnderTest.make()
        let requests = [
            ImageDecodeRequest(
                target: try TargetPixels(width: 1, height: 1),
                contentMode: .fit,
                colorPolicy: .preserveSource
            ),
            ImageDecodeRequest(
                target: try TargetPixels(width: 3, height: 1),
                contentMode: .fill,
                colorPolicy: .convertToSRGB
            ),
        ]
        for format in defaultStillFormats(codec.codecDescriptor).sorted(by: formatOrder) {
            let data = try fixtureData(for: format)
            let probe = try codec.probe(data: data, limits: fixtureLimits())
            for request in requests {
                let first = try codec.resourceEstimate(probe: probe, request: request)
                let second = try codec.resourceEstimate(probe: probe, request: request)
                let generic = genericWorkingSetEstimate(probe: probe, request: request)
                let composed = try ImageDecodeResourceEstimate.conservativeMaximum(
                    genericBytes: generic,
                    backendBytes: first.workingSetBytes
                )

                XCTAssertEqual(first, second)
                XCTAssertGreaterThan(first.workingSetBytes, 0)
                XCTAssertGreaterThanOrEqual(composed.workingSetBytes, generic)
                XCTAssertGreaterThanOrEqual(
                    composed.workingSetBytes,
                    first.workingSetBytes
                )
            }
        }
    }

    func testProbeHardLimitsFailClosed_ICT_006() throws {
        let codec = CodecUnderTest.make()
        let format = try XCTUnwrap(
            advertisedFormats(codec.codecDescriptor).sorted(by: formatOrder).first
        )
        let data = try fixtureData(for: format)

        assertProbeFailure(
            codec,
            data: data,
            limits: DecodeLimits(
                maximumEncodedBytes: data.count - 1,
                maximumFrameCount: 8
            ),
            expected: .encodedBytesExceeded
        )
        assertProbeFailure(
            codec,
            data: data,
            limits: DecodeLimits(
                maximumFrameCount: 8,
                allowedFormats: Set(EncodedImageFormat.allCases).subtracting([format])
            ),
            expected: .unsupportedFormat
        )
        assertProbeFailure(
            codec,
            data: data,
            limits: DecodeLimits(
                maximumDimension: 1,
                maximumFrameCount: 8
            ),
            expected: .dimensionLimitExceeded
        )
        assertProbeFailure(
            codec,
            data: data,
            limits: DecodeLimits(
                maximumPixelCount: 1,
                maximumFrameCount: 8
            ),
            expected: .pixelLimitExceeded
        )
    }

    func testPreparedLifecycleIfExposed_ICT_007() throws {
        let codec = CodecUnderTest.make()
        guard let prepared = codec as? any PreparedImageDecoding else { return }
        let foreignCodec = CodecUnderTest.make()
        let foreignPrepared = try XCTUnwrap(foreignCodec as? any PreparedImageDecoding)
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: 1, height: 1),
            contentMode: .fit,
            colorPolicy: .convertToSRGB
        )
        let limits = fixtureLimits()

        for format in defaultStillFormats(codec.codecDescriptor).sorted(by: formatOrder) {
            let data = try fixtureData(for: format)
            let directProbe = try codec.probe(data: data, limits: limits)
            let discarded = try prepared.prepare(data: data, limits: limits)
            XCTAssertEqual(discarded.probe, directProbe)

            XCTAssertThrowsError(
                try foreignPrepared.decode(
                    preparation: discarded,
                    request: request,
                    limits: limits
                )
            )
            prepared.discard(discarded)
            prepared.discard(discarded)
            XCTAssertThrowsError(
                try prepared.decode(
                    preparation: discarded,
                    request: request,
                    limits: limits
                )
            )

            let consumed = try prepared.prepare(data: data, limits: limits)
            XCTAssertEqual(consumed.probe, directProbe)
            let image = try prepared.decode(
                preparation: consumed,
                request: request,
                limits: limits
            )
            XCTAssertEqual(image.pixelWidth, 1)
            XCTAssertEqual(image.pixelHeight, 1)
            XCTAssertThrowsError(
                try prepared.decode(
                    preparation: consumed,
                    request: request,
                    limits: limits
                )
            )
        }
    }

    func testPreparedResourceAuthorityIfExposed_ICT_008() throws {
        let codec = CodecUnderTest.make()
        guard let prepared = codec as? any PreparedImageDecoding else { return }
        let format = try XCTUnwrap(
            defaultStillFormats(codec.codecDescriptor).sorted(by: formatOrder).first
        )
        let data = try fixtureData(for: format)
        let limits = fixtureLimits()
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: 1, height: 1),
            contentMode: .fit,
            colorPolicy: .convertToSRGB
        )

        let creationAuthority: ImageDecodePreparationCreationResourceAuthority?
        if let creating = prepared as? any PreparedImageCreationResourceInspecting {
            let first = try creating.preparationCreationResourceAuthority(
                data: data,
                limits: limits
            )
            let second = try creating.preparationCreationResourceAuthority(
                data: data,
                limits: limits
            )
            XCTAssertEqual(first, second)
            XCTAssertEqual(first.operationResourceLedger.transferredOutput, .bounded(0))
            XCTAssertEqual(first.operationResourceLedger.outputLayoutAuthority, .none)
            creationAuthority = first
        } else {
            creationAuthority = nil
        }

        let preparation = try prepared.prepare(data: data, limits: limits)
        if let inspecting = prepared as? any PreparedImageResourceInspecting {
            let ledger = try XCTUnwrap(
                inspecting.preparationResourceLedger(
                    preparation,
                    request: request,
                    limits: limits
                )
            )
            if let creationAuthority {
                XCTAssertEqual(
                    ledger.retainedKnownBytes,
                    creationAuthority.resultingPreparationRetainedKnownBytes
                )
                XCTAssertEqual(
                    ledger.retainedBetweenCalls,
                    creationAuthority.resultingPreparationRetainedBetweenCalls
                )
            }
            prepared.discard(preparation)
            XCTAssertNil(
                inspecting.preparationResourceLedger(
                    preparation,
                    request: request,
                    limits: limits
                )
            )
        } else {
            prepared.discard(preparation)
        }
    }

    func testProgressiveCancellationFencesLaterPixels_ICT_009() throws {
        let codec = CodecUnderTest.make()
        let formats = progressiveProfileFormats(codec.codecDescriptor).sorted(by: formatOrder)
        guard !formats.isEmpty else { return }
        let progressive = try XCTUnwrap(codec as? any ProgressiveImageDecoding)
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: 1, height: 1),
            contentMode: .fit,
            colorPolicy: .preserveSource
        )

        for format in formats {
            let session = try progressive.makeProgressiveSession(
                format: format,
                request: request,
                limits: fixtureLimits()
            )
            session.cancel()
            session.cancel()
            let data = try fixtureData(for: format)
            do {
                let generation = try session.append(data)
                XCTAssertNil(generation, "cancelled session emitted a later generation")
            } catch {
                // A terminal cancellation error is also contract-conforming.
            }
            do {
                try session.finish()
            } catch {
                // A terminal cancellation error is also contract-conforming.
            }
        }
    }

    private func assertProbeFailure(
        _ codec: any ImageCodec,
        data: Data,
        limits: DecodeLimits,
        expected: ImageCraftError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try codec.probe(data: data, limits: limits),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? ImageCraftError, expected, file: file, line: line)
        }
    }

    private func fixtureLimits() -> DecodeLimits {
        DecodeLimits(maximumFrameCount: 8)
    }

    private func finiteRequests() -> [ImageDecodeCapabilityRequest] {
        var requests: [ImageDecodeCapabilityRequest] = []
        for format in EncodedImageFormat.allCases {
            for delivery in ImageDecodeDeliveryMode.allCases {
                for track in ImageDecodeTrackMode.allCases {
                    for metadata in allSubsets(ImageDecodeMetadataCapability.allCases) {
                        for range in ImageDecodeDynamicRange.allCases {
                            for output in ImageDecodeOutputRepresentation.allCases {
                                for cancellation in ImageDecodeCancellationMode.allCases {
                                    requests.append(
                                        ImageDecodeCapabilityRequest(
                                            format: format,
                                            deliveryMode: delivery,
                                            trackMode: track,
                                            requiredMetadata: metadata,
                                            dynamicRange: range,
                                            outputRepresentation: output,
                                            cancellationMode: cancellation
                                        )
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        return requests
    }

    private func allSubsets<Element: Hashable>(_ values: [Element]) -> [Set<Element>] {
        (0..<(1 << values.count)).map { mask in
            Set(
                values.enumerated().compactMap { index, value in
                    mask & (1 << index) == 0 ? nil : value
                }
            )
        }
    }

    private func independentSupport(
        _ profiles: [ImageDecodeCapabilityProfile],
        _ request: ImageDecodeCapabilityRequest
    ) -> Bool {
        independentFailure(profiles, request) == nil
    }

    private func independentFailure(
        _ profiles: [ImageDecodeCapabilityProfile],
        _ request: ImageDecodeCapabilityRequest
    ) -> ImageCodecSupportFailure? {
        var candidates = profiles.filter { $0.formats.contains(request.format) }
        guard !candidates.isEmpty else { return .format(request.format) }

        candidates = candidates.filter { $0.deliveryModes.contains(request.deliveryMode) }
        guard !candidates.isEmpty else { return .deliveryMode(request.deliveryMode) }

        candidates = candidates.filter { $0.trackModes.contains(request.trackMode) }
        guard !candidates.isEmpty else { return .trackMode(request.trackMode) }

        for metadata in request.requiredMetadata.sorted(by: { $0.rawValue < $1.rawValue }) {
            candidates = candidates.filter { $0.metadata.contains(metadata) }
            guard !candidates.isEmpty else { return .metadata(metadata) }
        }

        candidates = candidates.filter { $0.dynamicRanges.contains(request.dynamicRange) }
        guard !candidates.isEmpty else { return .dynamicRange(request.dynamicRange) }

        candidates = candidates.filter {
            $0.outputRepresentations.contains(request.outputRepresentation)
        }
        guard !candidates.isEmpty else {
            return .outputRepresentation(request.outputRepresentation)
        }

        let strongestCancellation =
            candidates.map(\.cancellationMode).max() ?? .operationBoundary
        candidates = candidates.filter { $0.cancellationMode >= request.cancellationMode }
        guard !candidates.isEmpty else {
            return .cancellation(
                required: request.cancellationMode,
                available: strongestCancellation
            )
        }
        return nil
    }

    private func advertisedFormats(_ descriptor: ImageCodecDescriptor) -> Set<EncodedImageFormat> {
        descriptor.decodeProfiles.reduce(into: []) { result, profile in
            result.formUnion(profile.formats)
        }
    }

    private func defaultStillFormats(_ descriptor: ImageCodecDescriptor) -> Set<EncodedImageFormat> {
        Set(
            advertisedFormats(descriptor).filter { format in
                descriptor.supports(ImageDecodeCapabilityRequest(format: format))
            }
        )
    }

    private func progressiveProfileFormats(
        _ descriptor: ImageCodecDescriptor
    ) -> Set<EncodedImageFormat> {
        descriptor.decodeProfiles.reduce(into: []) { result, profile in
            guard profile.deliveryModes.contains(.progressiveGenerations) else { return }
            result.formUnion(profile.formats)
        }
    }

    private func fixtureData(for format: EncodedImageFormat) throws -> Data {
        let fileName =
            switch format {
            case .png: "reference-2x2.png"
            case .jpeg: "reference-2x2.jpg"
            case .gif: "reference-2x2.gif"
            case .webp: "reference-2x2.webp"
            case .heif: "reference-2x2.heic"
            case .avif: "reference-2x2.avif"
            }
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: fileName,
                withExtension: nil,
                subdirectory: "Fixtures"
            )
        )
        return try Data(contentsOf: url)
    }

    private func genericWorkingSetEstimate(
        probe: ImageProbe,
        request: ImageDecodeRequest
    ) -> Int {
        let widthScale = Double(request.target.width) / Double(probe.pixelWidth)
        let heightScale = Double(request.target.height) / Double(probe.pixelHeight)
        let requestedScale =
            request.contentMode == .fit
            ? min(widthScale, heightScale)
            : max(widthScale, heightScale)
        let scale = min(1, max(0, requestedScale))
        let thumbnailWidth = max(
            1,
            min(probe.pixelWidth, Int(ceil(Double(probe.pixelWidth) * scale)))
        )
        let thumbnailHeight = max(
            1,
            min(probe.pixelHeight, Int(ceil(Double(probe.pixelHeight) * scale)))
        )
        let thumbnailBytes = saturatedProduct([thumbnailWidth, thumbnailHeight, 4])
        let outputBytes = saturatedProduct([
            min(thumbnailWidth, request.target.width),
            min(thumbnailHeight, request.target.height),
            4,
        ])
        return saturatedSum([thumbnailBytes, thumbnailBytes, outputBytes])
    }

    private func saturatedProduct(_ values: [Int]) -> Int {
        values.reduce(1) { partial, value in
            let (result, overflow) = partial.multipliedReportingOverflow(by: value)
            return overflow ? Int.max : result
        }
    }

    private func saturatedSum(_ values: [Int]) -> Int {
        values.reduce(0) { partial, value in
            let (result, overflow) = partial.addingReportingOverflow(value)
            return overflow ? Int.max : result
        }
    }

    private func formatOrder(
        _ lhs: EncodedImageFormat,
        _ rhs: EncodedImageFormat
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
