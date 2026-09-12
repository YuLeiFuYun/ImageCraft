import Foundation
import ImageCraftCore
import XCTest

final class ImagePackedRGB8ConformanceTests: XCTestCase {
    private let generousOperationBudget = 1 << 20

    private struct Fixture {
        let id: String
        let sourceFile: String
        let expectedRGB8File: String
        let width: Int
        let height: Int
        let sourceByteCount: Int
        let exactOperationByteCharge: Int

        var transferByteCount: Int { width * height * 3 }
    }

    private let fixtures = [
        Fixture(
            id: "grayscale",
            sourceFile: "reference-baseline-jfif-grayscale-19x11.jpg",
            expectedRGB8File: "reference-baseline-jfif-grayscale-19x11.rgb",
            width: 19,
            height: 11,
            sourceByteCount: 543,
            exactOperationByteCharge: 836
        ),
        Fixture(
            id: "4:4:4",
            sourceFile: "reference-baseline-jfif-444-23x13.jpg",
            expectedRGB8File: "reference-baseline-jfif-444-23x13.rgb",
            width: 23,
            height: 13,
            sourceByteCount: 613,
            exactOperationByteCharge: 1_601
        ),
        Fixture(
            id: "4:2:2",
            sourceFile: "reference-baseline-jfif-422-23x13.jpg",
            expectedRGB8File: "reference-baseline-jfif-422-23x13.rgb",
            width: 23,
            height: 13,
            sourceByteCount: 552,
            exactOperationByteCharge: 3_073
        ),
        Fixture(
            id: "4:2:0",
            sourceFile: "reference-baseline-jfif-420-23x13.jpg",
            expectedRGB8File: "reference-baseline-jfif-420-23x13.rgb",
            width: 23,
            height: 13,
            sourceByteCount: 856,
            exactOperationByteCharge: 3_777
        ),
    ]

    func testReferenceJPEGProbeIsDeterministic_PACKED_RGB8_CT_001() throws {
        let decoder = try makeDecoder()
        for fixture in fixtures {
            let data = try fixtureData(fixture)
            XCTAssertEqual(data.count, fixture.sourceByteCount, fixture.id)
            let first = try decoder.probe(data: data, limits: fixtureLimits())
            let second = try decoder.probe(data: data, limits: fixtureLimits())
            XCTAssertEqual(first, second, fixture.id)
            XCTAssertEqual(first.format, .jpeg, fixture.id)
            XCTAssertEqual(first.pixelWidth, fixture.width, fixture.id)
            XCTAssertEqual(first.pixelHeight, fixture.height, fixture.id)
            XCTAssertEqual(first.frameCount, 1, fixture.id)
            XCTAssertEqual(first.orientation, 1, fixture.id)
            XCTAssertEqual(first.sourceColorProfile, .absent, fixture.id)
            XCTAssertEqual(first.sourceBitsPerComponent, 8, fixture.id)
        }
    }

    func testResourceLedgerIsExactBoundedAndComposable_PACKED_RGB8_CT_002() throws {
        let decoder = try makeDecoder()
        for fixture in fixtures {
            let data = try fixtureData(fixture)
            let request = try fixtureRequest(fixture)
            let first = try decoder.packedRGB8ResourceLedger(
                data: data,
                request: request,
                limits: fixtureLimits()
            )
            let second = try decoder.packedRGB8ResourceLedger(
                data: data,
                request: request,
                limits: fixtureLimits()
            )
            XCTAssertEqual(first, second, fixture.id)
            XCTAssertFalse(first.isTerminal, fixture.id)
            XCTAssertEqual(first.retainedKnownBytes, 0, fixture.id)
            XCTAssertEqual(first.retainedBetweenCalls, .bounded(0), fixture.id)
            XCTAssertEqual(first.operationPeak, .bounded(fixture.exactOperationByteCharge), fixture.id)
            XCTAssertEqual(first.transferredOutput, .bounded(fixture.transferByteCount), fixture.id)
            XCTAssertEqual(first.outputLayoutAuthority, .codecOwnedRGB8, fixture.id)
            for phase in ImageDecodeResourcePhase.allCases {
                XCTAssertNotNil(first.bytesUpperBound(for: phase), "\(fixture.id): missing \(phase)")
            }
            XCTAssertEqual(
                first.coexistenceBound(for: .operationPeak, callerRetainedBytes: data.count),
                .bounded(fixture.exactOperationByteCharge + data.count),
                fixture.id
            )
        }
    }

    func testReferenceJPEGDecodesIndependentExactRGB8_PACKED_RGB8_CT_003() throws {
        let decoder = try makeDecoder()
        for fixture in fixtures {
            let data = try fixtureData(fixture)
            let expected = try expectedRGB8Data(fixture)
            XCTAssertEqual(expected.count, fixture.transferByteCount, fixture.id)
            let request = try fixtureRequest(fixture)
            let ledger = try decoder.packedRGB8ResourceLedger(
                data: data,
                request: request,
                limits: fixtureLimits()
            )
            let first = try decoder.decodePackedRGB8(
                data: data,
                request: request,
                limits: fixtureLimits()
            )
            let second = try decoder.decodePackedRGB8(
                data: data,
                request: request,
                limits: fixtureLimits()
            )
            XCTAssertEqual(first, second, fixture.id)
            XCTAssertEqual(first.pixelWidth, fixture.width, fixture.id)
            XCTAssertEqual(first.pixelHeight, fixture.height, fixture.id)
            XCTAssertEqual(first.bytesPerRow, fixture.width * 3, fixture.id)
            XCTAssertEqual(first.data, expected, fixture.id)
            XCTAssertEqual(first.colorEncoding, .sRGB, fixture.id)
            XCTAssertEqual(first.sourceColorProfile, .absent, fixture.id)
            XCTAssertEqual(first.pixelByteCharge, fixture.transferByteCount, fixture.id)
            XCTAssertEqual(first.transferredByteCharge, fixture.transferByteCount, fixture.id)
            XCTAssertEqual(ledger.transferredOutput, .bounded(first.transferredByteCharge), fixture.id)
        }
    }

    func testProbeHardLimitsFailClosed_PACKED_RGB8_CT_004() throws {
        let decoder = try makeDecoder()
        for fixture in fixtures {
            let data = try fixtureData(fixture)
            XCTAssertThrowsError(
                try decoder.probe(
                    data: data,
                    limits: DecodeLimits(
                        maximumEncodedBytes: data.count - 1,
                        maximumFrameCount: 1,
                        allowedFormats: [.jpeg]
                    )
                ), fixture.id
            )
            XCTAssertThrowsError(
                try decoder.probe(
                    data: data,
                    limits: DecodeLimits(maximumFrameCount: 1, allowedFormats: [.png])
                ), fixture.id
            )
            XCTAssertThrowsError(
                try decoder.probe(
                    data: data,
                    limits: DecodeLimits(
                        maximumDimension: max(fixture.width, fixture.height) - 1,
                        maximumFrameCount: 1,
                        allowedFormats: [.jpeg]
                    )
                ), fixture.id
            )
            XCTAssertThrowsError(
                try decoder.probe(
                    data: data,
                    limits: DecodeLimits(
                        maximumPixelCount: fixture.width * fixture.height - 1,
                        maximumFrameCount: 1,
                        allowedFormats: [.jpeg]
                    )
                ), fixture.id
            )
        }
    }

    func testRequestSliceFailsClosed_PACKED_RGB8_CT_005() throws {
        let decoder = try makeDecoder()
        for fixture in fixtures {
            let data = try fixtureData(fixture)
            let requests = [
                ImageDecodeRequest(
                    target: try TargetPixels(width: fixture.width, height: fixture.height),
                    contentMode: .fit,
                    colorPolicy: .preserveSource
                ),
                ImageDecodeRequest(
                    target: try TargetPixels(width: fixture.width, height: fixture.height),
                    contentMode: .fill,
                    colorPolicy: .convertToSRGB
                ),
                ImageDecodeRequest(
                    target: try TargetPixels(width: fixture.width - 1, height: fixture.height),
                    contentMode: .fit,
                    colorPolicy: .convertToSRGB
                ),
                ImageDecodeRequest(
                    target: try TargetPixels(width: fixture.width, height: fixture.height),
                    contentMode: .fit,
                    colorPolicy: .convertToSRGB,
                    dynamicRange: .high
                ),
            ]
            for request in requests {
                XCTAssertThrowsError(
                    try decoder.packedRGB8ResourceLedger(
                        data: data,
                        request: request,
                        limits: fixtureLimits()
                    ), fixture.id
                )
                XCTAssertThrowsError(
                    try decoder.decodePackedRGB8(
                        data: data,
                        request: request,
                        limits: fixtureLimits()
                    ), fixture.id
                )
            }
        }
    }

    func testHardOperationBudgetFailsClosed_PACKED_RGB8_CT_006() throws {
        for fixture in fixtures {
            let decoder = try PackedDecoderUnderTest.make(
                maximumOperationByteCharge: fixture.exactOperationByteCharge - 1
            )
            let data = try fixtureData(fixture)
            let request = try fixtureRequest(fixture)
            XCTAssertThrowsError(
                try decoder.packedRGB8ResourceLedger(
                    data: data,
                    request: request,
                    limits: fixtureLimits()
                ), fixture.id
            )
            XCTAssertThrowsError(
                try decoder.decodePackedRGB8(
                    data: data,
                    request: request,
                    limits: fixtureLimits()
                ), fixture.id
            )
        }
    }

    private func makeDecoder() throws -> any ImagePackedRGB8Decoding {
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
            allowedFormats: [.jpeg]
        )
    }

    private func fixtureRequest(_ fixture: Fixture) throws -> ImageDecodeRequest {
        ImageDecodeRequest(
            target: try TargetPixels(width: fixture.width, height: fixture.height),
            contentMode: .fit,
            colorPolicy: .convertToSRGB
        )
    }

    private func fixtureData(_ fixture: Fixture) throws -> Data {
        try resourceData(named: fixture.sourceFile)
    }

    private func expectedRGB8Data(_ fixture: Fixture) throws -> Data {
        try resourceData(named: fixture.expectedRGB8File)
    }

    private func resourceData(named name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: name,
                withExtension: nil,
                subdirectory: "Fixtures"
            )
        )
        return try Data(contentsOf: url)
    }
}
