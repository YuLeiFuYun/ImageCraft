import Foundation
import ImageCraftCore
import XCTest

final class ImagePackedRGBA8ConformanceTests: XCTestCase {
    private let generousOperationBudget = 1 << 20

    func testDescriptorQualifiesBoundedPNGProfile_PACKED_CT_001() throws {
        let first = try PackedDecoderUnderTest.make(
            maximumOperationByteCharge: generousOperationBudget
        ).codecDescriptor
        let second = try PackedDecoderUnderTest.make(
            maximumOperationByteCharge: generousOperationBudget
        ).codecDescriptor

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.contractVersion, ImageCodecDescriptor.currentContractVersion)
        XCTAssertFalse(first.identifier.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertGreaterThan(first.implementationVersion, 0)
        XCTAssertTrue(first.supports(qualifiedCapabilityRequest()))
    }

    func testReferencePNGProbeIsDeterministic_PACKED_CT_002() throws {
        let decoder = try makeDecoder()
        let data = try fixtureData()
        let first = try decoder.probe(data: data, limits: fixtureLimits())
        let second = try decoder.probe(data: data, limits: fixtureLimits())

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.format, .png)
        XCTAssertEqual(first.pixelWidth, 2)
        XCTAssertEqual(first.pixelHeight, 1)
        XCTAssertEqual(first.frameCount, 1)
        XCTAssertEqual(first.orientation, 1)
        XCTAssertEqual(first.sourceColorProfile, .standardSRGB)
    }

    func testResourceLedgerIsBoundedDeterministicAndComposable_PACKED_CT_003() throws {
        let decoder = try makeDecoder()
        let data = try fixtureData()
        let request = try fixtureRequest()
        let first = try decoder.packedRGBA8ResourceLedger(
            data: data,
            request: request,
            limits: fixtureLimits()
        )
        let second = try decoder.packedRGBA8ResourceLedger(
            data: data,
            request: request,
            limits: fixtureLimits()
        )

        XCTAssertEqual(first, second)
        XCTAssertFalse(first.isTerminal)
        XCTAssertEqual(first.outputLayoutAuthority, .codecOwnedRGBA8)
        for phase in ImageDecodeResourcePhase.allCases {
            XCTAssertNotNil(first.bytesUpperBound(for: phase), "profile requires a bound for \(phase)")
        }
        let operationBytes = try XCTUnwrap(first.bytesUpperBound(for: .operationPeak))
        let transferBytes = try XCTUnwrap(first.bytesUpperBound(for: .transferredOutput))
        XCTAssertGreaterThan(operationBytes, 0)
        XCTAssertGreaterThanOrEqual(transferBytes, 8)
        XCTAssertEqual(
            first.coexistenceBound(for: .operationPeak, callerRetainedBytes: data.count),
            .bounded(operationBytes + data.count)
        )
    }

    func testReferencePNGDecodesExactPackedRGBA8_PACKED_CT_004() throws {
        let decoder = try makeDecoder()
        let data = try fixtureData()
        let request = try fixtureRequest()
        let ledger = try decoder.packedRGBA8ResourceLedger(
            data: data,
            request: request,
            limits: fixtureLimits()
        )
        let first = try decoder.decodePackedRGBA8(
            data: data,
            request: request,
            limits: fixtureLimits()
        )
        let second = try decoder.decodePackedRGBA8(
            data: data,
            request: request,
            limits: fixtureLimits()
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.pixelWidth, 2)
        XCTAssertEqual(first.pixelHeight, 1)
        XCTAssertEqual(first.bytesPerRow, 8)
        XCTAssertEqual(first.data, Data([255, 0, 0, 255, 0, 128, 255, 255]))
        XCTAssertEqual(first.colorEncoding, .sRGB)
        XCTAssertEqual(first.sourceColorProfile, .standardSRGB)
        XCTAssertEqual(first.pixelByteCharge, 8)
        XCTAssertEqual(first.transferredByteCharge, 8)
        XCTAssertEqual(ledger.transferredOutput, .bounded(first.transferredByteCharge))
    }

    func testProbeHardLimitsFailClosed_PACKED_CT_005() throws {
        let decoder = try makeDecoder()
        let data = try fixtureData()

        XCTAssertThrowsError(
            try decoder.probe(
                data: data,
                limits: DecodeLimits(
                    maximumEncodedBytes: data.count - 1,
                    maximumFrameCount: 1,
                    allowedFormats: [.png]
                )
            )
        )
        XCTAssertThrowsError(
            try decoder.probe(
                data: data,
                limits: DecodeLimits(maximumFrameCount: 1, allowedFormats: [])
            )
        )
        XCTAssertThrowsError(
            try decoder.probe(
                data: data,
                limits: DecodeLimits(
                    maximumDimension: 1,
                    maximumFrameCount: 1,
                    allowedFormats: [.png]
                )
            )
        )
        XCTAssertThrowsError(
            try decoder.probe(
                data: data,
                limits: DecodeLimits(
                    maximumPixelCount: 1,
                    maximumFrameCount: 1,
                    allowedFormats: [.png]
                )
            )
        )
    }

    func testHardOperationBudgetFailsClosed_PACKED_CT_006() throws {
        let decoder = try PackedDecoderUnderTest.make(maximumOperationByteCharge: 1)
        let data = try fixtureData()
        XCTAssertThrowsError(try decoder.probe(data: data, limits: fixtureLimits()))
    }

    private func makeDecoder() throws -> any ImagePackedRGBA8Decoding {
        try PackedDecoderUnderTest.make(maximumOperationByteCharge: generousOperationBudget)
    }

    private func qualifiedCapabilityRequest() -> ImageDecodeCapabilityRequest {
        ImageDecodeCapabilityRequest(
            format: .png,
            deliveryMode: .completeFrame,
            trackMode: .primaryFrame,
            requiredMetadata: [],
            dynamicRange: .standard,
            outputRepresentation: .packedRGBA8,
            cancellationMode: .operationBoundary
        )
    }

    private func fixtureLimits() -> DecodeLimits {
        DecodeLimits(
            maximumEncodedBytes: 1 << 20,
            maximumDimension: 64,
            maximumPixelCount: 4_096,
            maximumFrameCount: 1,
            maximumMetadataBytes: 64 * 1024,
            maximumAuxiliaryAttachments: 0,
            allowedFormats: [.png]
        )
    }

    private func fixtureRequest() throws -> ImageDecodeRequest {
        ImageDecodeRequest(
            target: try TargetPixels(width: 2, height: 1),
            contentMode: .fit,
            colorPolicy: .preserveSource
        )
    }

    private func fixtureData() throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "reference-srgb-2x1.png",
                withExtension: nil,
                subdirectory: "Fixtures"
            )
        )
        return try Data(contentsOf: url)
    }
}
