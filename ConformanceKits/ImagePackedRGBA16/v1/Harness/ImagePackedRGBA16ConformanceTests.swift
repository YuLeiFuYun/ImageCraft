import Foundation
import ImageCraftCore
import XCTest

final class ImagePackedRGBA16ConformanceTests: XCTestCase {
    private let generousOperationBudget = 1 << 20

    func testPublicStraightRGBA16ValueContract_PACKED16_CT_001() throws {
        let bytes = expectedRGBA16LE()
        let value = try XCTUnwrap(
            ImagePackedRGBA16Straight(
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
        XCTAssertEqual(value.bytesPerRow, 16)
        XCTAssertEqual(value.colorEncoding, .sRGB)
        XCTAssertEqual(value.sourceColorProfile, .standardSRGB)
        XCTAssertEqual(value.pixelByteCharge, 16)
        XCTAssertEqual(value.transferredByteCharge, 16)
        XCTAssertNil(
            ImagePackedRGBA16Straight(
                data: Data(bytes.dropLast()),
                pixelWidth: 2,
                pixelHeight: 1,
                colorEncoding: .sRGB,
                sourceColorProfile: .standardSRGB
            )
        )
    }

    func testReferencePNGProbeIsDeterministicAndHighDepth_PACKED16_CT_002() throws {
        let decoder = try makeDecoder()
        let data = try fixtureData("reference-srgb-rgba16-2x1.png")
        let first = try decoder.probe(data: data, limits: fixtureLimits())
        let second = try decoder.probe(data: data, limits: fixtureLimits())

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.format, .png)
        XCTAssertEqual(first.pixelWidth, 2)
        XCTAssertEqual(first.pixelHeight, 1)
        XCTAssertEqual(first.frameCount, 1)
        XCTAssertEqual(first.orientation, 1)
        XCTAssertEqual(first.sourceColorProfile, .standardSRGB)
        XCTAssertEqual(first.sourceBitsPerComponent, 16)
    }

    func testResourceLedgerIsBoundedDeterministicAndComposable_PACKED16_CT_003() throws {
        let decoder = try makeDecoder()
        let data = try fixtureData("reference-srgb-rgba16-2x1.png")
        let request = try fixtureRequest()
        let first = try decoder.packedRGBA16ResourceLedger(
            data: data,
            request: request,
            limits: fixtureLimits()
        )
        let second = try decoder.packedRGBA16ResourceLedger(
            data: data,
            request: request,
            limits: fixtureLimits()
        )

        XCTAssertEqual(first, second)
        XCTAssertFalse(first.isTerminal)
        XCTAssertEqual(first.retainedKnownBytes, 0)
        XCTAssertEqual(first.retainedBetweenCalls, .bounded(0))
        XCTAssertEqual(first.outputLayoutAuthority, .codecOwnedStraightRGBA16LE)
        for phase in ImageDecodeResourcePhase.allCases {
            XCTAssertNotNil(first.bytesUpperBound(for: phase), "profile requires a bound for \(phase)")
        }
        let operationBytes = try XCTUnwrap(first.bytesUpperBound(for: .operationPeak))
        XCTAssertGreaterThanOrEqual(operationBytes, 16)
        XCTAssertEqual(first.transferredOutput, .bounded(16))
        XCTAssertEqual(
            first.coexistenceBound(for: .operationPeak, callerRetainedBytes: data.count),
            .bounded(operationBytes + data.count)
        )
    }

    func testReferencePNGDecodesExactStraightRGBA16LE_PACKED16_CT_004() throws {
        let decoder = try makeDecoder()
        let data = try fixtureData("reference-srgb-rgba16-2x1.png")
        let request = try fixtureRequest()
        let ledger = try decoder.packedRGBA16ResourceLedger(
            data: data,
            request: request,
            limits: fixtureLimits()
        )
        let first = try decoder.decodePackedRGBA16(
            data: data,
            request: request,
            limits: fixtureLimits()
        )
        let second = try decoder.decodePackedRGBA16(
            data: data,
            request: request,
            limits: fixtureLimits()
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.pixelWidth, 2)
        XCTAssertEqual(first.pixelHeight, 1)
        XCTAssertEqual(first.bytesPerRow, 16)
        XCTAssertEqual(first.data, expectedRGBA16LE())
        XCTAssertEqual(first.colorEncoding, .sRGB)
        XCTAssertEqual(first.sourceColorProfile, .standardSRGB)
        XCTAssertEqual(first.pixelByteCharge, 16)
        XCTAssertEqual(first.transferredByteCharge, 16)
        XCTAssertEqual(ledger.transferredOutput, .bounded(first.transferredByteCharge))
    }

    func testProbeHardLimitsFailClosed_PACKED16_CT_005() throws {
        let decoder = try makeDecoder()
        let data = try fixtureData("reference-srgb-rgba16-2x1.png")

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

    func testUnsupportedRequestSemanticsFailClosed_PACKED16_CT_006() throws {
        let decoder = try makeDecoder()
        let data = try fixtureData("reference-srgb-rgba16-2x1.png")
        let target = try TargetPixels(width: 2, height: 1)
        let requests = [
            ImageDecodeRequest(target: target, colorPolicy: .convertToSRGB),
            ImageDecodeRequest(
                target: target,
                colorPolicy: .preserveSource,
                dynamicRange: .high
            ),
            ImageDecodeRequest(
                target: try TargetPixels(width: 1, height: 1),
                colorPolicy: .preserveSource
            ),
        ]
        for request in requests {
            XCTAssertThrowsError(
                try decoder.packedRGBA16ResourceLedger(
                    data: data,
                    request: request,
                    limits: fixtureLimits()
                )
            )
            XCTAssertThrowsError(
                try decoder.decodePackedRGBA16(
                    data: data,
                    request: request,
                    limits: fixtureLimits()
                )
            )
        }
    }

    func testUnsupportedSourceSemanticsFailBeforePackedPublication_PACKED16_CT_007() throws {
        let decoder = try makeDecoder()
        let request = try fixtureRequest()
        for name in [
            "hostile-untagged-rgba16-2x1.png",
            "hostile-sbit-rgba16-2x1.png",
        ] {
            let data = try fixtureData(name)
            XCTAssertThrowsError(try decoder.probe(data: data, limits: fixtureLimits()), name)
            XCTAssertThrowsError(
                try decoder.packedRGBA16ResourceLedger(
                    data: data,
                    request: request,
                    limits: fixtureLimits()
                ),
                name
            )
            XCTAssertThrowsError(
                try decoder.decodePackedRGBA16(
                    data: data,
                    request: request,
                    limits: fixtureLimits()
                ),
                name
            )
        }
    }

    func testHardOperationBudgetFailsClosed_PACKED16_CT_008() throws {
        let decoder = try PackedDecoderUnderTest.make(maximumOperationByteCharge: 1)
        let data = try fixtureData("reference-srgb-rgba16-2x1.png")
        XCTAssertThrowsError(try decoder.probe(data: data, limits: fixtureLimits()))
    }

    private func makeDecoder() throws -> any ImagePackedRGBA16Decoding {
        try PackedDecoderUnderTest.make(maximumOperationByteCharge: generousOperationBudget)
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

    private func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: name,
                withExtension: nil,
                subdirectory: "Fixtures"
            )
        )
        return try Data(contentsOf: url)
    }

    private func expectedRGBA16LE() -> Data {
        Data([
            0x34, 0x12, 0x78, 0x56, 0xBC, 0x9A, 0xF0, 0xDE,
            0xFF, 0xFF, 0x01, 0x00, 0x00, 0x80, 0x34, 0x12,
        ])
    }
}
