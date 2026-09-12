import CryptoKit
import Foundation
import ImageCraftCore
import XCTest

final class ImageProgressivePackedRGB8ConformanceTests: XCTestCase {
    private let sourceByteCount = 787
    private let outputByteCount = 897
    private let outputSHA256 = "c7807abef8ee1d20dcdaa4953e0767518aab1485578dca5a9ae7c0bb3d146861"

    func testPublicRGB8ValueContract_PROGRESSIVE_PACKED_CT_001() throws {
        let bytes = Data(repeating: 7, count: 6)
        let value = try XCTUnwrap(
            ImagePackedRGB8(
                data: bytes,
                pixelWidth: 2,
                pixelHeight: 1,
                colorEncoding: .sRGB,
                sourceColorProfile: .absent
            )
        )
        XCTAssertEqual(value.data, bytes)
        XCTAssertEqual(value.pixelWidth, 2)
        XCTAssertEqual(value.pixelHeight, 1)
        XCTAssertEqual(value.bytesPerRow, 6)
        XCTAssertEqual(value.pixelByteCharge, 6)
        XCTAssertEqual(value.transferredByteCharge, 6)
        XCTAssertNil(
            ImagePackedRGB8(
                data: Data(bytes.dropLast()),
                pixelWidth: 2,
                pixelHeight: 1,
                colorEncoding: .sRGB,
                sourceColorProfile: .absent
            )
        )
    }

    func testArbitraryChunkSessionIsFinalOnlyAndNonConsumingPreflight_PROGRESSIVE_PACKED_CT_002() throws {
        let source = try fixture("reference-progressive-jfif-420.jpg")
        let session = try makeSession()
        XCTAssertNil(try session.packedRGB8FinalizationResourceLedger())

        var offset = 0
        while offset < source.count {
            let end = min(source.count, offset + 17)
            XCTAssertNil(try session.append(source.subdata(in: offset..<end)))
            offset = end
        }
        XCTAssertEqual(session.receivedByteCount, sourceByteCount)
        let before = session.receivedByteCount
        XCTAssertNotNil(try session.packedRGB8FinalizationResourceLedger())
        XCTAssertEqual(session.receivedByteCount, before)
    }

    func testFinalReadyResourceLedgerIsExactBoundedAndComposable_PROGRESSIVE_PACKED_CT_003() throws {
        let source = try fixture("reference-progressive-jfif-420.jpg")
        let session = try makeSession()
        XCTAssertNil(try session.append(source))
        let ledger = try XCTUnwrap(session.packedRGB8FinalizationResourceLedger())

        XCTAssertEqual(ledger.retainedKnownBytes, outputByteCount)
        XCTAssertEqual(ledger.retainedBetweenCalls, .bounded(outputByteCount))
        XCTAssertEqual(ledger.operationPeak, .bounded(6_590))
        XCTAssertEqual(ledger.transferredOutput, .bounded(outputByteCount))
        XCTAssertEqual(ledger.outputLayoutAuthority, .codecOwnedRGB8)
        XCTAssertEqual(
            ledger.coexistenceBound(for: .operationPeak, callerRetainedBytes: source.count),
            .bounded(6_590 + source.count)
        )
    }

    func testFinalizationTransfersExactFrozenRGBAndSourceBinding_PROGRESSIVE_PACKED_CT_004() throws {
        let source = try fixture("reference-progressive-jfif-420.jpg")
        let session = try makeSession()
        XCTAssertNil(try session.append(source))
        let ledger = try XCTUnwrap(session.packedRGB8FinalizationResourceLedger())
        let finalization = try session.finishWithPackedRGB8()

        XCTAssertEqual(finalization.sourceByteCount, sourceByteCount)
        XCTAssertEqual(finalization.image.pixelWidth, 23)
        XCTAssertEqual(finalization.image.pixelHeight, 13)
        XCTAssertEqual(finalization.image.bytesPerRow, 69)
        XCTAssertEqual(finalization.image.data.count, outputByteCount)
        XCTAssertEqual(finalization.image.colorEncoding, .sRGB)
        XCTAssertEqual(finalization.image.sourceColorProfile, .absent)
        XCTAssertEqual(sha256(finalization.image.data), outputSHA256)
        XCTAssertEqual(ledger.transferredOutput, .bounded(finalization.image.transferredByteCharge))
        XCTAssertThrowsError(try session.finishWithPackedRGB8()) { error in
            XCTAssertEqual(error as? ImageCraftError, .progressiveSessionFinished)
        }
    }

    func testChunkPartitionDoesNotChangeFinalPackedValue_PROGRESSIVE_PACKED_CT_005() throws {
        let source = try fixture("reference-progressive-jfif-420.jpg")
        let whole = try decode(source, chunkSize: source.count)
        let bytewise = try decode(source, chunkSize: 1)
        let uneven = try decode(source, chunkSize: 29)
        XCTAssertEqual(whole.image, bytewise.image)
        XCTAssertEqual(whole.image, uneven.image)
        XCTAssertEqual(sha256(whole.image.data), outputSHA256)
    }

    func testLimitsAndICCSourceAuthorityFailClosed_PROGRESSIVE_PACKED_CT_006() throws {
        let source = try fixture("reference-progressive-jfif-420.jpg")
        let tightLimits = DecodeLimits(
            maximumEncodedBytes: source.count - 1,
            maximumFrameCount: 1,
            allowedFormats: [.jpeg]
        )
        let limited = try PackedSessionUnderTest.make(
            maximumCodecOwnedByteCharge: 1 << 20,
            limits: tightLimits
        )
        XCTAssertThrowsError(try limited.append(source)) { error in
            XCTAssertEqual(error as? ImageCraftError, .encodedBytesExceeded)
        }
        XCTAssertEqual(limited.receivedByteCount, 0)

        XCTAssertThrowsError(
            try PackedSessionUnderTest.make(
                maximumCodecOwnedByteCharge: 1 << 20,
                limits: DecodeLimits(maximumFrameCount: 1, allowedFormats: [])
            )
        ) { error in
            XCTAssertEqual(error as? ImageCraftError, .unsupportedFormat)
        }

        let hostile = try fixture("hostile-icc-progressive-jfif-420.jpg")
        let session = try makeSession()
        XCTAssertThrowsError(try session.append(hostile))
        XCTAssertThrowsError(try session.finishWithPackedRGB8()) { error in
            XCTAssertEqual(error as? ImageCraftError, .progressiveSessionFinished)
        }
    }

    func testCancellationReclaimsAndFencesLateCalls_PROGRESSIVE_PACKED_CT_007() throws {
        let source = try fixture("reference-progressive-jfif-420.jpg")
        let session = try makeSession()
        XCTAssertNil(try session.append(source.prefix(source.count / 2)))
        session.cancel()
        session.cancel()
        XCTAssertThrowsError(try session.append(source.suffix(1))) { error in
            XCTAssertEqual(error as? ImageCraftError, .progressiveSessionCancelled)
        }
        XCTAssertThrowsError(try session.packedRGB8FinalizationResourceLedger()) { error in
            XCTAssertEqual(error as? ImageCraftError, .progressiveSessionCancelled)
        }
        XCTAssertThrowsError(try session.finishWithPackedRGB8()) { error in
            XCTAssertEqual(error as? ImageCraftError, .progressiveSessionCancelled)
        }
    }

    func testHardCodecOwnedBudgetIsEnforcedAtConstruction_PROGRESSIVE_PACKED_CT_008() throws {
        XCTAssertThrowsError(
            try PackedSessionUnderTest.make(
                maximumCodecOwnedByteCharge: 1,
                limits: fixtureLimits()
            )
        )
    }

    private func makeSession() throws -> any ProgressiveImagePackedRGB8FinalizingSession {
        try PackedSessionUnderTest.make(
            maximumCodecOwnedByteCharge: 1 << 20,
            limits: fixtureLimits()
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
            allowedFormats: [.jpeg]
        )
    }

    private func decode(
        _ source: Data,
        chunkSize: Int
    ) throws -> ImageProgressivePackedRGB8Finalization {
        let session = try makeSession()
        var offset = 0
        while offset < source.count {
            let end = min(source.count, offset + chunkSize)
            XCTAssertNil(try session.append(source.subdata(in: offset..<end)))
            offset = end
        }
        _ = try XCTUnwrap(session.packedRGB8FinalizationResourceLedger())
        return try session.finishWithPackedRGB8()
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        )
        return try Data(contentsOf: url)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
