import CoreGraphics
import Foundation
import ImageCraftCore
import ImageCraftImageIO
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class ImageDecoderTests: XCTestCase {
    func testDefaultPreparedResourceLedgerBoundsRetainedPureValueState() throws {
        let data = try makeOrientedJPEG(width: 120, height: 60, orientation: 1)
        let decoder = ImageIOImageDecoder()
        let preparation = try decoder.prepare(data: data, limits: .coreV1)
        let request = ImageDecodeRequest(target: try TargetPixels(width: 60, height: 30))
        let ledger = try XCTUnwrap(
            decoder.preparationResourceLedger(
                preparation,
                request: request,
                limits: .coreV1
            )
        )

        XCTAssertEqual(ledger.retainedKnownBytes, data.count)
        XCTAssertEqual(ledger.outputLayoutAuthority, .frameworkChosen)
        XCTAssertEqual(ledger.bound(for: .retainedBetweenCalls), .bounded(data.count))
        XCTAssertEqual(
            ledger.bound(for: .operationPeak),
            .unknown(.frameworkPrivateOperationAllocation)
        )
        XCTAssertEqual(
            ledger.bound(for: .transferredOutput),
            .unknown(.frameworkChosenOutputLayout)
        )

        decoder.discard(preparation)
        XCTAssertNil(
            decoder.preparationResourceLedger(
                preparation,
                request: request,
                limits: .coreV1
            )
        )
    }

    func testRetainedSourceQualificationLedgerFailsClosedForOpaqueImageIOState() throws {
        let data = try makeOrientedJPEG(width: 120, height: 60, orientation: 1)
        let decoder = ImageIOImageDecoder(
            qualificationPreparationRetentionMode: .retainedSource
        )
        let preparation = try decoder.prepare(data: data, limits: .coreV1)
        let request = ImageDecodeRequest(target: try TargetPixels(width: 60, height: 30))
        let ledger = try XCTUnwrap(
            decoder.preparationResourceLedger(
                preparation,
                request: request,
                limits: .coreV1
            )
        )
        XCTAssertEqual(
            ledger.retainedBetweenCalls,
            .unknown(.frameworkPrivateRetainedState)
        )
        decoder.discard(preparation)
    }

    func testDataOnlyPreparedStateBoundsRetainedBytesAndRepreparesWithoutPixelDrift() throws {
        let data = try makeOrientedJPEG(width: 120, height: 60, orientation: 1)
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: 60, height: 30),
            contentMode: .fit,
            colorPolicy: .convertToSRGB
        )

        let referenceDecoder = ImageIOImageDecoder()
        let referencePreparation = try referenceDecoder.prepare(data: data, limits: .coreV1)
        let reference = try referenceDecoder.decode(
            preparation: referencePreparation,
            request: request,
            limits: .coreV1
        )

        let decoder = ImageIOImageDecoder(
            qualificationPreparationRetentionMode: .encodedDataOnly
        )
        let preparation = try decoder.prepareWithDiagnostics(data: data, limits: .coreV1)
        let ledger = try XCTUnwrap(
            decoder.preparationResourceLedger(
                preparation.preparation,
                request: request,
                limits: .coreV1
            )
        )
        XCTAssertEqual(ledger.retainedKnownBytes, data.count)
        XCTAssertEqual(ledger.retainedBetweenCalls, .bounded(data.count))
        XCTAssertEqual(
            ledger.operationPeak,
            .unknown(.frameworkPrivateOperationAllocation)
        )
        XCTAssertEqual(
            ledger.transferredOutput,
            .unknown(.frameworkChosenOutputLayout)
        )

        let result = try decoder.decodeWithDiagnostics(
            preparation: preparation.preparation,
            request: request,
            limits: .coreV1
        )
        let repeated = try XCTUnwrap(result.diagnostics.repeatedPreparationDiagnostics)
        XCTAssertEqual(repeated.containerInspectionNanoseconds, 0)
        XCTAssertGreaterThan(repeated.imageSourceCreationNanoseconds, 0)
        XCTAssertGreaterThan(repeated.imagePropertiesReadNanoseconds, 0)
        XCTAssertEqual(
            result.diagnostics.sourceCreationNanoseconds,
            repeated.imageSourceCreationNanoseconds
        )
        XCTAssertEqual(result.image.colorDescription, reference.colorDescription)
        XCTAssertEqual(result.image.alphaMode, reference.alphaMode)
        XCTAssertEqual(result.image.pixelFormat, reference.pixelFormat)
        XCTAssertEqual(
            try normalizedRGBABytes(result.image.cgImage),
            try normalizedRGBABytes(reference.cgImage)
        )
        XCTAssertNil(
            decoder.preparationResourceLedger(
                preparation.preparation,
                request: request,
                limits: .coreV1
            )
        )
    }

    func testDataOnlyPreparedStateMatchesRetainedSourceAcrossStaticFormats() throws {
        let fixtures = [
            try makePNG(width: 24, height: 12),
            try makeOrientedJPEG(width: 24, height: 12, orientation: 1),
            try makeStaticGIF(width: 24, height: 12),
        ]
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: 12, height: 6),
            colorPolicy: .convertToSRGB
        )

        for data in fixtures {
            let referenceDecoder = ImageIOImageDecoder()
            let referencePreparation = try referenceDecoder.prepare(data: data, limits: .coreV1)
            let reference = try referenceDecoder.decode(
                preparation: referencePreparation,
                request: request,
                limits: .coreV1
            )

            let decoder = ImageIOImageDecoder(
                qualificationPreparationRetentionMode: .encodedDataOnly
            )
            let preparation = try decoder.prepare(data: data, limits: .coreV1)
            let result = try decoder.decodeWithDiagnostics(
                preparation: preparation,
                request: request,
                limits: .coreV1
            )
            let repeated = try XCTUnwrap(result.diagnostics.repeatedPreparationDiagnostics)
            XCTAssertEqual(repeated.containerInspectionNanoseconds, 0)
            XCTAssertEqual(result.image.colorDescription, reference.colorDescription)
            XCTAssertEqual(result.image.alphaMode, reference.alphaMode)
            XCTAssertEqual(result.image.pixelFormat, reference.pixelFormat)
            XCTAssertEqual(
                try normalizedRGBABytes(result.image.cgImage),
                try normalizedRGBABytes(reference.cgImage)
            )
        }
    }

    func testDataOnlyPreparationOwnsSourceSnapshotAgainstCallerMutation() throws {
        var data = try makeOrientedJPEG(width: 24, height: 12, orientation: 1)
        let original = data
        let request = ImageDecodeRequest(target: try TargetPixels(width: 12, height: 6))
        let decoder = ImageIOImageDecoder(
            qualificationPreparationRetentionMode: .encodedDataOnly
        )
        let preparation = try decoder.prepare(data: data, limits: .coreV1)
        data[0] ^= 0xFF

        let prepared = try decoder.decode(
            preparation: preparation,
            request: request,
            limits: .coreV1
        )
        let direct = try ImageIOImageDecoder().decode(
            data: original,
            request: request,
            limits: .coreV1
        )
        XCTAssertEqual(
            try normalizedRGBABytes(prepared.cgImage),
            try normalizedRGBABytes(direct.cgImage)
        )
    }

    func testDataOnlyPreparedStateRetainsICCValueFactsWithoutOpaqueSource() throws {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.adobeRGB1998))
        let data = try makeColorManagedJPEG(colorSpace: colorSpace)
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: 16, height: 8),
            colorPolicy: .preserveSource
        )
        let referenceDecoder = ImageIOImageDecoder()
        let referencePreparation = try referenceDecoder.prepare(data: data, limits: .coreV1)
        let reference = try referenceDecoder.decode(
            preparation: referencePreparation,
            request: request,
            limits: .coreV1
        )

        let decoder = ImageIOImageDecoder(
            qualificationPreparationRetentionMode: .encodedDataOnly
        )
        let preparation = try decoder.prepare(data: data, limits: .coreV1)
        let ledger = try XCTUnwrap(
            decoder.preparationResourceLedger(preparation, request: request, limits: .coreV1)
        )
        XCTAssertGreaterThan(ledger.retainedKnownBytes, data.count)
        XCTAssertEqual(ledger.retainedBetweenCalls, .bounded(ledger.retainedKnownBytes))

        let result = try decoder.decodeWithDiagnostics(
            preparation: preparation,
            request: request,
            limits: .coreV1
        )
        let repeated = try XCTUnwrap(result.diagnostics.repeatedPreparationDiagnostics)
        XCTAssertEqual(repeated.containerInspectionNanoseconds, 0)
        XCTAssertEqual(
            result.image.colorDescription.outputColorSpaceName,
            CGColorSpace.adobeRGB1998 as String
        )
        XCTAssertEqual(
            try normalizedRGBABytes(result.image.cgImage),
            try normalizedRGBABytes(reference.cgImage)
        )
    }

    func testPreparedStoreEnforcesAggregateChargeAndReclaimsOnConsumeOrDiscard() throws {
        let data = try makeOrientedJPEG(width: 120, height: 60, orientation: 1)
        let budget = data.count * 2
        let decoder = ImageIOImageDecoder(
            preparationLimits: ImageDecodePreparationLimits(
                maximumEntryCount: 2,
                maximumRetainedByteCharge: budget
            )
        )
        let first = try decoder.prepare(data: data, limits: .coreV1)
        let second = try decoder.prepare(data: data, limits: .coreV1)
        XCTAssertEqual(
            decoder.preparationStoreQualificationSnapshot(),
            ImageIOPreparationStoreQualificationSnapshot(
                entryCount: 2,
                reservationCount: 0,
                maximumEntryCount: 2,
                retainedKnownByteCharge: budget,
                maximumRetainedKnownByteCharge: budget
            )
        )
        XCTAssertThrowsError(try decoder.prepare(data: data, limits: .coreV1)) { error in
            XCTAssertEqual(error as? ImageCraftError, .preparedStateBudgetExceeded)
        }

        decoder.discard(first)
        XCTAssertEqual(decoder.preparationStoreQualificationSnapshot().retainedKnownByteCharge, data.count)
        let third = try decoder.prepare(data: data, limits: .coreV1)
        XCTAssertEqual(decoder.preparationStoreQualificationSnapshot().entryCount, 2)

        let request = ImageDecodeRequest(target: try TargetPixels(width: 60, height: 30))
        _ = try decoder.decode(preparation: second, request: request, limits: .coreV1)
        XCTAssertEqual(decoder.preparationStoreQualificationSnapshot().retainedKnownByteCharge, data.count)
        decoder.discard(third)
        XCTAssertEqual(
            decoder.preparationStoreQualificationSnapshot(),
            ImageIOPreparationStoreQualificationSnapshot(
                entryCount: 0,
                reservationCount: 0,
                maximumEntryCount: 2,
                retainedKnownByteCharge: 0,
                maximumRetainedKnownByteCharge: budget
            )
        )
    }

    func testStaticPreparationCreationPreflightIsNonConsumingAndExactWithoutICC() throws {
        let data = try makeOrientedJPEG(width: 120, height: 60, orientation: 1)
        let decoder = ImageIOImageDecoder()
        let inspecting = decoder as any PreparedImageCreationResourceInspecting
        let before = decoder.preparationStoreQualificationSnapshot()

        let authority = try inspecting.preparationCreationResourceAuthority(
            data: data,
            limits: .coreV1
        )
        XCTAssertEqual(decoder.preparationStoreQualificationSnapshot(), before)
        XCTAssertEqual(authority.operationResourceLedger.retainedKnownBytes, 0)
        XCTAssertEqual(authority.operationResourceLedger.retainedBetweenCalls, .bounded(0))
        XCTAssertEqual(
            authority.operationResourceLedger.operationPeak,
            .unknown(.frameworkPrivateOperationAllocation)
        )
        XCTAssertEqual(authority.operationResourceLedger.transferredOutput, .bounded(0))
        XCTAssertEqual(authority.operationResourceLedger.outputLayoutAuthority, .none)
        XCTAssertEqual(authority.resultingPreparationRetainedKnownBytes, data.count)
        XCTAssertEqual(
            authority.resultingPreparationRetainedBetweenCalls,
            .bounded(data.count)
        )

        let preparation = try decoder.prepare(data: data, limits: .coreV1)
        let request = ImageDecodeRequest(target: try TargetPixels(width: 60, height: 30))
        let ledger = try XCTUnwrap(
            decoder.preparationResourceLedger(preparation, request: request, limits: .coreV1)
        )
        XCTAssertEqual(ledger.retainedKnownBytes, authority.resultingPreparationRetainedKnownBytes)
        XCTAssertEqual(
            ledger.retainedBetweenCalls,
            authority.resultingPreparationRetainedBetweenCalls
        )
        decoder.discard(preparation)
    }

    func testStaticJPEGPreparationCreationPreflightIsExactWithEmbeddedICCWithoutMaterializingProfile() throws {
        let adobeRGB = try XCTUnwrap(CGColorSpace(name: CGColorSpace.adobeRGB1998))
        let data = try makeColorManagedJPEG(colorSpace: adobeRGB)
        let decoder = ImageIOImageDecoder()
        let inspecting = decoder as any PreparedImageCreationResourceInspecting
        let before = decoder.preparationStoreQualificationSnapshot()

        let authority = try inspecting.preparationCreationResourceAuthority(
            data: data,
            limits: .coreV1
        )
        XCTAssertEqual(decoder.preparationStoreQualificationSnapshot(), before)
        XCTAssertGreaterThan(authority.resultingPreparationRetainedKnownBytes, data.count)
        XCTAssertEqual(
            authority.resultingPreparationRetainedBetweenCalls,
            .bounded(authority.resultingPreparationRetainedKnownBytes)
        )

        let preparation = try decoder.prepare(data: data, limits: .coreV1)
        let request = ImageDecodeRequest(target: try TargetPixels(width: 32, height: 32))
        let ledger = try XCTUnwrap(
            decoder.preparationResourceLedger(preparation, request: request, limits: .coreV1)
        )
        XCTAssertEqual(ledger.retainedKnownBytes, authority.resultingPreparationRetainedKnownBytes)
        XCTAssertEqual(
            ledger.retainedBetweenCalls,
            authority.resultingPreparationRetainedBetweenCalls
        )
        decoder.discard(preparation)
    }

    func testPreparedReservationRollsBackOnContainerAndICCAdmissionFailure() throws {
        let valid = try makeOrientedJPEG(width: 64, height: 32, orientation: 1)
        var corrupt = valid
        corrupt[0] ^= 0xFF
        let decoder = ImageIOImageDecoder(
            preparationLimits: ImageDecodePreparationLimits(
                maximumEntryCount: 1,
                maximumRetainedByteCharge: valid.count
            )
        )
        XCTAssertThrowsError(try decoder.prepare(data: corrupt, limits: .coreV1))
        XCTAssertEqual(decoder.preparationStoreQualificationSnapshot().entryCount, 0)
        XCTAssertEqual(decoder.preparationStoreQualificationSnapshot().reservationCount, 0)
        XCTAssertEqual(decoder.preparationStoreQualificationSnapshot().retainedKnownByteCharge, 0)
        let validPreparation = try decoder.prepare(data: valid, limits: .coreV1)
        decoder.discard(validPreparation)

        let adobeRGB = try XCTUnwrap(CGColorSpace(name: CGColorSpace.adobeRGB1998))
        let iccData = try makeColorManagedJPEG(colorSpace: adobeRGB)
        let iccDecoder = ImageIOImageDecoder(
            preparationLimits: ImageDecodePreparationLimits(
                maximumEntryCount: 1,
                maximumRetainedByteCharge: iccData.count
            )
        )
        XCTAssertThrowsError(try iccDecoder.prepare(data: iccData, limits: .coreV1)) { error in
            XCTAssertEqual(error as? ImageCraftError, .preparedStateBudgetExceeded)
        }
        XCTAssertEqual(iccDecoder.preparationStoreQualificationSnapshot().entryCount, 0)
        XCTAssertEqual(iccDecoder.preparationStoreQualificationSnapshot().reservationCount, 0)
        XCTAssertEqual(iccDecoder.preparationStoreQualificationSnapshot().retainedKnownByteCharge, 0)
    }

    func testPreparedStoreConcurrentAdmissionAndDecodeReclaim() async throws {
        let data = try makeOrientedJPEG(width: 64, height: 32, orientation: 1)
        let request = ImageDecodeRequest(target: try TargetPixels(width: 32, height: 16))
        let decoder = ImageIOImageDecoder(
            preparationLimits: ImageDecodePreparationLimits(
                maximumEntryCount: 8,
                maximumRetainedByteCharge: data.count * 8
            )
        )

        let admitted = try await withThrowingTaskGroup(
            of: ImageDecodePreparation?.self,
            returning: [ImageDecodePreparation].self
        ) { group in
            for _ in 0..<32 {
                group.addTask {
                    do {
                        return try decoder.prepare(data: data, limits: .coreV1)
                    } catch ImageCraftError.preparedStateBudgetExceeded {
                        return nil
                    }
                }
            }
            var values: [ImageDecodePreparation] = []
            for try await value in group {
                if let value { values.append(value) }
            }
            return values
        }
        XCTAssertEqual(admitted.count, 8)
        XCTAssertEqual(decoder.preparationStoreQualificationSnapshot().entryCount, 8)
        XCTAssertEqual(
            decoder.preparationStoreQualificationSnapshot().retainedKnownByteCharge,
            data.count * 8
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            for preparation in admitted {
                group.addTask {
                    let image = try decoder.decode(
                        preparation: preparation,
                        request: request,
                        limits: .coreV1
                    )
                    guard image.pixelWidth == 32, image.pixelHeight == 16 else {
                        throw ImageCraftError.decodeFailed
                    }
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(decoder.preparationStoreQualificationSnapshot().entryCount, 0)
        XCTAssertEqual(decoder.preparationStoreQualificationSnapshot().retainedKnownByteCharge, 0)
    }

    func testInstrumentedPreparationMatchesStandardProbe_DIAG_PT_013() throws {
        let data = try makeOrientedJPEG(width: 120, height: 60, orientation: 6)
        let decoder = ImageIOImageDecoder()
        let expected = try decoder.probe(data: data, limits: .coreV1)
        let result = try decoder.prepareWithDiagnostics(data: data, limits: .coreV1)
        defer { decoder.discard(result.preparation) }

        XCTAssertEqual(result.preparation.probe, expected)
        XCTAssertGreaterThan(result.diagnostics.containerInspectionNanoseconds, 0)
        XCTAssertGreaterThan(result.diagnostics.imageSourceCreationNanoseconds, 0)
        XCTAssertGreaterThan(result.diagnostics.imageSourceTypeNanoseconds, 0)
        XCTAssertGreaterThan(result.diagnostics.imageFrameCountNanoseconds, 0)
        XCTAssertGreaterThan(result.diagnostics.imagePropertiesReadNanoseconds, 0)
        XCTAssertGreaterThan(result.diagnostics.probeValidationNanoseconds, 0)
    }

    func testP3AndSRGBPoliciesProduceDistinctColorOutputs_IMG_PT_002() throws {
        let data = try makeColorManagedPNG(
            colorSpace: try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        )
        let decoder = ImageIOImageDecoder()
        let probe = try decoder.probe(data: data, limits: .coreV1)
        let preservedImage = try decoder.decode(
            data: data,
            probe: probe,
            request: ImageDecodeRequest(
                target: try TargetPixels(width: 16, height: 8),
                colorPolicy: .preserveSource
            ),
            limits: .coreV1
        )
        let convertedImage = try decoder.decode(
            data: data,
            probe: probe,
            request: ImageDecodeRequest(
                target: try TargetPixels(width: 16, height: 8),
                colorPolicy: .convertToSRGB
            ),
            limits: .coreV1
        )
        XCTAssertEqual(
            preservedImage.colorDescription.outputColorSpaceName,
            CGColorSpace.displayP3 as String
        )
        XCTAssertEqual(
            convertedImage.colorDescription.outputColorSpaceName,
            CGColorSpace.sRGB as String
        )
        XCTAssertNotEqual(preservedImage.colorDescription, convertedImage.colorDescription)
    }

    func testPNGICCPIsValueBoundedAndHostileProfilePathsFailClosed() throws {
        let displayP3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let expectedProfile = try XCTUnwrap(displayP3.copyICCData()).bridgeToData()
        let data = try makeRawRGBA8PNG(
            width: 31,
            height: 19,
            straightRGBA: Data(repeating: 127, count: 31 * 19 * 4),
            includeSRGB: false,
            embeddedICCProfile: expectedProfile
        )
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: 16, height: 8),
            colorPolicy: .preserveSource
        )
        let decoder = ImageIOImageDecoder()
        let preparation = try decoder.prepare(data: data, limits: .coreV1)
        let ledger = try XCTUnwrap(
            decoder.preparationResourceLedger(
                preparation,
                request: request,
                limits: .coreV1
            )
        )
        let profileByteCount = ledger.retainedKnownBytes - data.count
        XCTAssertEqual(profileByteCount, expectedProfile.count)
        XCTAssertGreaterThan(profileByteCount, 128)
        XCTAssertEqual(ledger.retainedBetweenCalls, .bounded(ledger.retainedKnownBytes))
        decoder.discard(preparation)

        let packed = try decoder.decodePackedRGBA8(
            data: data,
            request: request,
            limits: .coreV1
        )
        guard case .embeddedICC(let packedProfile) = packed.colorEncoding else {
            return XCTFail("iCCP-only PNG must publish the validated ICC profile as a value")
        }
        XCTAssertEqual(packedProfile, expectedProfile)
        XCTAssertEqual(packedProfile.count, profileByteCount)
        XCTAssertEqual(packed.transferredByteCharge, packed.data.count + packedProfile.count)

        let chunks = try pngTestChunks(data)
        let iccp = try XCTUnwrap(chunks.first { $0.type == "iCCP" })
        let iend = try XCTUnwrap(chunks.first { $0.type == "IEND" })

        var badCRC = data
        badCRC[iccp.payloadEnd] ^= 1
        XCTAssertThrowsError(try ImageIOImageDecoder().probe(data: badCRC, limits: .coreV1)) {
            XCTAssertEqual($0 as? ImageCraftError, .unsupportedOrCorruptImage)
        }

        var invalidKeyword = data
        invalidKeyword[iccp.payloadStart] = 0x20
        try rewritePNGTestChunkCRC(&invalidKeyword, chunk: iccp)
        XCTAssertThrowsError(
            try ImageIOImageDecoder().probe(data: invalidKeyword, limits: .coreV1)
        ) {
            XCTAssertEqual($0 as? ImageCraftError, .unsupportedOrCorruptImage)
        }

        var corruptProfileStream = data
        var separator = iccp.payloadStart
        while separator < iccp.payloadEnd, corruptProfileStream[separator] != 0 {
            separator += 1
        }
        let compressedStart = separator + 2
        XCTAssertLessThan(compressedStart + 5, iccp.payloadEnd)
        corruptProfileStream[compressedStart + 5] ^= 0x40
        try rewritePNGTestChunkCRC(&corruptProfileStream, chunk: iccp)
        XCTAssertThrowsError(
            try ImageIOImageDecoder().probe(data: corruptProfileStream, limits: .coreV1)
        ) {
            XCTAssertEqual($0 as? ImageCraftError, .unsupportedOrCorruptImage)
        }

        var duplicateICCP = data
        duplicateICCP.insert(contentsOf: data[iccp.start..<iccp.end], at: iend.start)
        XCTAssertThrowsError(
            try ImageIOImageDecoder().probe(data: duplicateICCP, limits: .coreV1)
        ) {
            XCTAssertEqual($0 as? ImageCraftError, .unsupportedOrCorruptImage)
        }

        var iccWithInvalidTag = expectedProfile
        let tagCount =
            Int(iccWithInvalidTag[128]) << 24
            | Int(iccWithInvalidTag[129]) << 16
            | Int(iccWithInvalidTag[130]) << 8
            | Int(iccWithInvalidTag[131])
        XCTAssertGreaterThan(tagCount, 0)
        let firstTagOffsetField = 132 + 4
        iccWithInvalidTag.replaceSubrange(
            firstTagOffsetField..<(firstTagOffsetField + 4),
            with: [0xFF, 0xFF, 0xFF, 0xFC]
        )
        let recompressedInvalidICC = try RFC1950Zlib.deflate(iccWithInvalidTag)
        let profilePrefix = data[iccp.payloadStart..<compressedStart]
        var invalidICCPPayload = Data(profilePrefix)
        invalidICCPPayload.append(recompressedInvalidICC)
        let invalidICCPChunk = try makePNGTestChunk(type: "iCCP", payload: invalidICCPPayload)
        var invalidICCTagTable = data
        invalidICCTagTable.replaceSubrange(iccp.start..<iccp.end, with: invalidICCPChunk)
        XCTAssertThrowsError(
            try ImageIOImageDecoder().probe(data: invalidICCTagTable, limits: .coreV1)
        ) {
            XCTAssertEqual($0 as? ImageCraftError, .unsupportedOrCorruptImage)
        }

        let sRGBChunk = try makePNGTestChunk(type: "sRGB", payload: Data([0]))
        let ihdr = try XCTUnwrap(chunks.first { $0.type == "IHDR" })
        var lowerPrioritySRGB = data
        lowerPrioritySRGB.insert(contentsOf: sRGBChunk, at: ihdr.end)
        XCTAssertEqual(
            try ImageIOImageDecoder().probe(data: lowerPrioritySRGB, limits: .coreV1).sourceColorProfile,
            .embeddedICC
        )

        let invalidSRGBChunk = try makePNGTestChunk(type: "sRGB", payload: Data([4]))
        let srgbData = try makeRawRGBA8PNG(
            width: 2,
            height: 2,
            straightRGBA: Data(repeating: 127, count: 16),
            includeSRGB: true
        )
        let srgbChunks = try pngTestChunks(srgbData)
        let srgb = try XCTUnwrap(srgbChunks.first { $0.type == "sRGB" })
        var invalidIntent = srgbData
        invalidIntent.replaceSubrange(srgb.start..<srgb.end, with: invalidSRGBChunk)
        XCTAssertThrowsError(
            try ImageIOImageDecoder().probe(data: invalidIntent, limits: .coreV1)
        ) {
            XCTAssertEqual($0 as? ImageCraftError, .unsupportedOrCorruptImage)
        }

        let decompressedLimit = DecodeLimits(maximumMetadataBytes: profileByteCount - 1)
        XCTAssertThrowsError(
            try ImageIOImageDecoder().probe(data: data, limits: decompressedLimit)
        ) {
            XCTAssertEqual($0 as? ImageCraftError, .metadataLimitExceeded)
        }
    }

    func testPNGContainerSecurityRejectsKnownStructuralViolationsBeforeImageIO() throws {
        let base = try makeRawRGBA8PNG(
            width: 4,
            height: 3,
            straightRGBA: Data(repeating: 127, count: 4 * 3 * 4),
            includeSRGB: true
        )
        let chunks = try pngTestChunks(base)
        let ihdr = try XCTUnwrap(chunks.first { $0.type == "IHDR" })
        let srgb = try XCTUnwrap(chunks.first { $0.type == "sRGB" })
        let idat = try XCTUnwrap(chunks.first { $0.type == "IDAT" })
        let iend = try XCTUnwrap(chunks.first { $0.type == "IEND" })

        func assertCorrupt(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(
                try ImageIOImageDecoder().probe(data: data, limits: .coreV1),
                file: file,
                line: line
            ) {
                XCTAssertEqual(
                    $0 as? ImageCraftError,
                    .unsupportedOrCorruptImage,
                    file: file,
                    line: line
                )
            }
        }

        var duplicateIHDR = base
        duplicateIHDR.insert(contentsOf: base[ihdr.start..<ihdr.end], at: ihdr.end)
        assertCorrupt(duplicateIHDR)

        var oversizedDimension = base
        oversizedDimension.replaceSubrange(
            ihdr.payloadStart..<(ihdr.payloadStart + 4),
            with: pngTestUInt32Bytes(0x8000_0000)
        )
        try rewritePNGTestChunkCRC(&oversizedDimension, chunk: ihdr)
        assertCorrupt(oversizedDimension)

        var invalidCompressionMethod = base
        invalidCompressionMethod[ihdr.payloadStart + 10] = 1
        try rewritePNGTestChunkCRC(&invalidCompressionMethod, chunk: ihdr)
        assertCorrupt(invalidCompressionMethod)

        let compressed = Data(base[idat.payloadStart..<idat.payloadEnd])
        let split = compressed.count / 2
        var noncontiguous = base
        var splitRun = Data()
        splitRun.append(try makePNGTestChunk(type: "IDAT", payload: Data(compressed[..<split])))
        splitRun.append(try makePNGTestChunk(type: "tEXt", payload: Data("k\u{0}v".utf8)))
        splitRun.append(try makePNGTestChunk(type: "IDAT", payload: Data(compressed[split...])))
        noncontiguous.replaceSubrange(idat.start..<idat.end, with: splitRun)
        assertCorrupt(noncontiguous)

        var lateSRGB = base
        lateSRGB.removeSubrange(srgb.start..<srgb.end)
        let lateChunks = try pngTestChunks(lateSRGB)
        let lateIEND = try XCTUnwrap(lateChunks.first { $0.type == "IEND" })
        lateSRGB.insert(
            contentsOf: try makePNGTestChunk(type: "sRGB", payload: Data([0])),
            at: lateIEND.start
        )
        assertCorrupt(lateSRGB)

        var nonemptyIEND = base
        nonemptyIEND.replaceSubrange(
            iend.start..<iend.end,
            with: try makePNGTestChunk(type: "IEND", payload: Data([0]))
        )
        assertCorrupt(nonemptyIEND)

        var zeroGamma = base
        zeroGamma.insert(
            contentsOf: try makePNGTestChunk(
                type: "gAMA",
                payload: Data(pngTestUInt32Bytes(0))
            ),
            at: srgb.end
        )
        assertCorrupt(zeroGamma)

        var orphanMDCV = base
        orphanMDCV.insert(
            contentsOf: try makePNGTestChunk(type: "mDCV", payload: Data(repeating: 0, count: 24)),
            at: srgb.end
        )
        assertCorrupt(orphanMDCV)
    }

    func testAssigningColorSpaceReusesImmutablePixelProvider_IMG_PT_009() throws {
        let original = try makeTestCGImage(width: 16, height: 8)
        let provider = try XCTUnwrap(original.dataProvider)
        let displayP3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))

        let tagged = try ImageIOImageDecoder.imageByAssigningColorSpace(
            displayP3,
            to: original
        )

        XCTAssertTrue(tagged.dataProvider === provider)
        XCTAssertEqual(tagged.width, original.width)
        XCTAssertEqual(tagged.height, original.height)
        XCTAssertEqual(tagged.bitsPerComponent, original.bitsPerComponent)
        XCTAssertEqual(tagged.bitsPerPixel, original.bitsPerPixel)
        XCTAssertEqual(tagged.bytesPerRow, original.bytesPerRow)
        XCTAssertEqual(tagged.colorSpace?.name as String?, CGColorSpace.displayP3 as String)
    }

    func testJPEGEmbeddedICCIsReassembledAndPreservedWithoutChangingPixels_IMG_PT_010()
        throws
    {
        let adobeRGB = try XCTUnwrap(CGColorSpace(name: CGColorSpace.adobeRGB1998))
        let data = try makeColorManagedJPEG(colorSpace: adobeRGB)
        let decoder = ImageIOImageDecoder()
        let probe = try decoder.probe(data: data, limits: .coreV1)
        let target = try TargetPixels(width: 16, height: 8)

        let preserved = try decoder.decode(
            data: data,
            probe: probe,
            request: ImageDecodeRequest(target: target, colorPolicy: .preserveSource),
            limits: .coreV1
        )
        let converted = try decoder.decode(
            data: data,
            probe: probe,
            request: ImageDecodeRequest(target: target, colorPolicy: .convertToSRGB),
            limits: .coreV1
        )

        XCTAssertEqual(probe.sourceColorProfile, .embeddedICC)
        XCTAssertEqual(
            preserved.colorDescription.outputColorSpaceName,
            CGColorSpace.adobeRGB1998 as String
        )
        XCTAssertEqual(
            converted.colorDescription.outputColorSpaceName,
            CGColorSpace.sRGB as String
        )
        XCTAssertEqual(preserved.pixelWidth, converted.pixelWidth)
        XCTAssertEqual(preserved.pixelHeight, converted.pixelHeight)
    }

    func testJPEGICCChunkSequenceMustBeCompleteUniqueAndConsistent_SEC_CASE_044() throws {
        let data = try makeColorManagedJPEG(
            colorSpace: try XCTUnwrap(CGColorSpace(name: CGColorSpace.adobeRGB1998))
        )
        let segment = try XCTUnwrap(firstJPEGICCProfileSegment(in: data))
        let decoder = ImageIOImageDecoder()

        var missing = data
        missing[segment.sequenceIndex] = 1
        missing[segment.countIndex] = 2

        var duplicate = data
        duplicate.insert(contentsOf: data[segment.range], at: segment.range.upperBound)

        var conflictingSegment = Data(data[segment.range])
        let relativeCountIndex = segment.countIndex - segment.range.lowerBound
        conflictingSegment[relativeCountIndex] = 2
        var conflicting = data
        conflicting.insert(contentsOf: conflictingSegment, at: segment.range.upperBound)

        for malformed in [missing, duplicate, conflicting] {
            XCTAssertThrowsError(try decoder.probe(data: malformed, limits: .coreV1)) { error in
                XCTAssertEqual(error as? ImageCraftError, .unsupportedOrCorruptImage)
            }
        }
    }

    func testUnlabeledGrayscalePNGConvertsToStableSRGB() throws {
        let data = try XCTUnwrap(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP4/x8AAwAB/2+Bq7YAAAAASUVORK5CYII="
            )
        )
        let decoded = try ImageIOImageDecoder().decode(
            data: data,
            target: try TargetPixels(width: 1, height: 1)
        )

        XCTAssertEqual(decoded.pixelWidth, 1)
        XCTAssertEqual(decoded.pixelHeight, 1)
        XCTAssertEqual(decoded.colorDescription.sourceProfile, .absent)
        XCTAssertEqual(
            decoded.colorDescription.outputColorSpaceName,
            CGColorSpace.sRGB as String
        )
        XCTAssertEqual(decoded.cgImage.colorSpace?.model, .rgb)
    }

    func testMissingColorProfileUsesStableSRGBFallback_IMG_PT_003() throws {
        let tagged = try makeColorManagedPNG(
            colorSpace: try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        )
        let data = try removingPNGChunks(
            ["cICP", "iCCP", "sRGB", "gAMA", "cHRM", "mDCV", "cLLI"],
            from: tagged
        )
        let decoder = ImageIOImageDecoder()
        let target = try TargetPixels(width: 16, height: 8)
        let first = try decoder.decode(data: data, target: target)
        let second = try decoder.decode(data: data, target: target)

        XCTAssertEqual(first.colorDescription.sourceProfile, .absent)
        XCTAssertEqual(first.colorDescription.outputColorSpaceName, CGColorSpace.sRGB as String)
        XCTAssertEqual(second.colorDescription, first.colorDescription)
    }

    func testDownsamplePreservesP3OutputWithCICPAuthority_IMG_PT_006() throws {
        let data = try makeColorManagedPNG(
            width: 64,
            height: 32,
            colorSpace: try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        )
        let decoder = ImageIOImageDecoder()
        let probe = try decoder.probe(data: data, limits: .coreV1)
        let decoded = try decoder.decode(
            data: data,
            probe: probe,
            request: ImageDecodeRequest(
                target: try TargetPixels(width: 16, height: 16),
                colorPolicy: .preserveSource
            ),
            limits: .coreV1
        )

        XCTAssertEqual(probe.sourceColorProfile, .unknown)
        XCTAssertEqual(decoded.colorDescription.sourceProfile, .unknown)
        XCTAssertEqual(
            decoded.colorDescription.outputColorSpaceName,
            CGColorSpace.displayP3 as String
        )
        XCTAssertEqual(decoded.pixelWidth, 16)
        XCTAssertEqual(decoded.pixelHeight, 8)
    }

    func testPNGColorAuthorityPrecedencePublishesOnlyRepresentableValue() throws {
        let width = 3
        let height = 2
        let straight = Data(repeating: 127, count: width * height * 4)
        let decoder = ImageIOImageDecoder()

        let srgbOnly = try makeRawRGBA8PNG(
            width: width,
            height: height,
            straightRGBA: straight,
            includeSRGB: true
        )
        XCTAssertEqual(
            try decoder.probe(data: srgbOnly, limits: .coreV1).sourceColorProfile,
            .standardSRGB
        )

        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let p3Profile = try XCTUnwrap(p3.copyICCData()).bridgeToData()
        let iccOnly = try makeRawRGBA8PNG(
            width: width,
            height: height,
            straightRGBA: straight,
            includeSRGB: false,
            embeddedICCProfile: p3Profile
        )
        XCTAssertEqual(
            try decoder.probe(data: iccOnly, limits: .coreV1).sourceColorProfile,
            .embeddedICC
        )

        let iccChunks = try pngTestChunks(iccOnly)
        let iccIHDR = try XCTUnwrap(iccChunks.first { $0.type == "IHDR" })
        var srgbAndICC = iccOnly
        srgbAndICC.insert(
            contentsOf: try makePNGTestChunk(type: "sRGB", payload: Data([0])),
            at: iccIHDR.end
        )
        XCTAssertEqual(
            try decoder.probe(data: srgbAndICC, limits: .coreV1).sourceColorProfile,
            .embeddedICC
        )

        let cicpOverICC = try makeColorManagedPNG(
            width: width,
            height: height,
            colorSpace: p3
        )
        XCTAssertEqual(
            try decoder.probe(data: cicpOverICC, limits: .coreV1).sourceColorProfile,
            .unknown
        )

        let untagged = try makeRawRGBA8PNG(
            width: width,
            height: height,
            straightRGBA: straight,
            includeSRGB: false
        )
        let untaggedIHDR = try XCTUnwrap(try pngTestChunks(untagged).first { $0.type == "IHDR" })
        let srgbChromaticities = [31_270, 32_900, 64_000, 33_000, 30_000, 60_000, 15_000, 6_000]
            .flatMap { pngTestUInt32Bytes(UInt32($0)) }
        for ancillary in [
            try makePNGTestChunk(type: "gAMA", payload: Data(pngTestUInt32Bytes(45_455))),
            try makePNGTestChunk(type: "cHRM", payload: Data(srgbChromaticities)),
        ] {
            var candidate = untagged
            candidate.insert(contentsOf: ancillary, at: untaggedIHDR.end)
            XCTAssertEqual(
                try decoder.probe(data: candidate, limits: .coreV1).sourceColorProfile,
                .unknown
            )
        }
    }

    func testPNGCICPOverridesLowerPriorityICCPWithoutRetainingUnusedProfile() throws {
        let data = try makeColorManagedPNG(
            width: 31,
            height: 19,
            colorSpace: try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        )
        let chunks = try pngTestChunks(data)
        XCTAssertNotNil(chunks.first { $0.type == "cICP" })
        XCTAssertNotNil(chunks.first { $0.type == "iCCP" })

        let decoder = ImageIOImageDecoder()
        let probe = try decoder.probe(data: data, limits: .coreV1)
        XCTAssertEqual(probe.sourceColorProfile, .unknown)

        let request = ImageDecodeRequest(
            target: try TargetPixels(width: 16, height: 8),
            colorPolicy: .preserveSource
        )
        let preparation = try decoder.prepare(data: data, limits: .coreV1)
        let ledger = try XCTUnwrap(
            decoder.preparationResourceLedger(
                preparation,
                request: request,
                limits: .coreV1
            )
        )
        XCTAssertEqual(ledger.retainedKnownBytes, data.count)
        XCTAssertEqual(ledger.retainedBetweenCalls, .bounded(data.count))
        decoder.discard(preparation)

        XCTAssertThrowsError(
            try decoder.decodePackedRGBA8(data: data, request: request, limits: .coreV1)
        ) {
            XCTAssertEqual($0 as? ImagePackedPixelContractError, .unclassifiedColorState)
        }

        let converted = try decoder.decodePackedRGBA8(
            data: data,
            request: ImageDecodeRequest(
                target: request.target,
                colorPolicy: .convertToSRGB
            ),
            limits: .coreV1
        )
        XCTAssertEqual(converted.colorEncoding, .sRGB)
    }

    func testAlphaAndPixelFormatMatchTransparentReference_IMG_PT_007() throws {
        let data = try makeColorManagedPNG(
            width: 8,
            height: 8,
            colorSpace: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            rgba: (32, 16, 8, 64)
        )
        let decoded = try ImageIOImageDecoder().decode(
            data: data,
            target: try TargetPixels(width: 8, height: 8)
        )

        XCTAssertEqual(decoded.alphaMode, .premultipliedFirst)
        XCTAssertEqual(decoded.pixelFormat.bitsPerComponent, 8)
        XCTAssertEqual(decoded.pixelFormat.bitsPerPixel, 32)
        XCTAssertEqual(try centerAlpha(of: decoded.cgImage), 64, accuracy: 2)
    }

    func testOrdinaryImageProbeReportsNoAuxiliaryAttachments() throws {
        let probe = try ImageIOImageDecoder().probe(
            data: makePNG(width: 16, height: 8),
            limits: .coreV1
        )

        XCTAssertEqual(probe.auxiliaryAttachmentCount, 0)
    }

    func testTargetDecodeAvoidsFullSizeBitmap() throws {
        let data = try makePNG(width: 100, height: 50)
        let decoded = try ImageIOImageDecoder().decode(
            data: data,
            target: try TargetPixels(width: 20, height: 20)
        )
        XCTAssertEqual(decoded.pixelWidth, 20)
        XCTAssertEqual(decoded.pixelHeight, 10)
    }

    func testFillDecodeCoversAndCenterCropsTargetGeoPt004() throws {
        let data = try makePNG(width: 100, height: 50)
        let decoder = ImageIOImageDecoder()
        let fit = try decoder.decode(
            data: data,
            request: ImageDecodeRequest(
                target: try TargetPixels(width: 20, height: 20),
                contentMode: .fit
            )
        )
        let fill = try decoder.decode(
            data: data,
            request: ImageDecodeRequest(
                target: try TargetPixels(width: 20, height: 20),
                contentMode: .fill
            )
        )

        XCTAssertEqual(fit.pixelWidth, 20)
        XCTAssertEqual(fit.pixelHeight, 10)
        XCTAssertEqual(fill.pixelWidth, 20)
        XCTAssertEqual(fill.pixelHeight, 20)
    }

    func testTargetDecodeRespectsBothDimensions() throws {
        let data = try makePNG(width: 100, height: 50)
        let decoded = try ImageIOImageDecoder().decode(
            data: data,
            target: try TargetPixels(width: 200, height: 20)
        )
        XCTAssertEqual(decoded.pixelWidth, 40)
        XCTAssertEqual(decoded.pixelHeight, 20)
    }

    func testCorruptImageIsRejectedBeforeCommit() throws {
        XCTAssertThrowsError(
            try ImageIOImageDecoder().decode(
                data: Data("not-an-image".utf8),
                target: try TargetPixels(width: 20, height: 20)
            )
        )
    }
}

extension ImageDecoderTests {
    func testCoreV1RejectsMultiFrameImagesSecCase003() throws {
        let data = try makeAnimatedGIF()
        XCTAssertThrowsError(
            try ImageIOImageDecoder().decode(
                data: data,
                target: try TargetPixels(width: 20, height: 20)
            )
        ) { error in
            XCTAssertEqual(error as? ImageCraftError, .frameLimitExceeded)
        }
    }

    func testExifOrientationParticipatesInTargetGeometryImgPt001() throws {
        let data = try makeOrientedJPEG(width: 120, height: 60, orientation: 6)
        let decoder = ImageIOImageDecoder()
        let probe = try decoder.probe(data: data, limits: .coreV1)
        XCTAssertEqual(probe.pixelWidth, 60)
        XCTAssertEqual(probe.pixelHeight, 120)

        let decoded = try decoder.decode(
            data: data,
            probe: probe,
            request: ImageDecodeRequest(target: try TargetPixels(width: 30, height: 60)),
            limits: .coreV1
        )
        XCTAssertEqual(decoded.pixelWidth, 30)
        XCTAssertEqual(decoded.pixelHeight, 60)
    }

    func testDecodeRejectsProbeFromDifferentBitstream() throws {
        let data = try makePNG(width: 100, height: 50)
        let forged = try ImageProbe(pixelWidth: 10, pixelHeight: 10, frameCount: 1)
        XCTAssertThrowsError(
            try ImageIOImageDecoder().decode(
                data: data,
                probe: forged,
                request: ImageDecodeRequest(target: try TargetPixels(width: 20, height: 20)),
                limits: .coreV1
            )
        ) { error in
            XCTAssertEqual(error as? ImageCraftError, .probeMismatch)
        }
    }

    func testUnmeasurableImagePropertiesFailClosedAsOversizedMetadata() {
        let properties: [CFString: Any] = ["unsupported" as CFString: NSObject()]
        XCTAssertEqual(ImageIOImageDecoder.serializedPropertySize(properties), Int.max)
    }

    func testOversizedContainerMetadataIsRejectedBeforeDecodeSecCase004() throws {
        let data = try makePNGWithTextMetadata(payloadBytes: 1_024)
        let limits = DecodeLimits(maximumMetadataBytes: 128)

        XCTAssertThrowsError(
            try ImageIOImageDecoder().probe(data: data, limits: limits)
        ) { error in
            XCTAssertEqual(error as? ImageCraftError, .metadataLimitExceeded)
        }
    }

    func testJPEGApplicationSegmentsCountTowardMetadataLimit() throws {
        let data = makeJPEGWithMetadataSegment(marker: 0xE0, payloadBytes: 256)
        XCTAssertThrowsError(
            try ImageIOImageDecoder().probe(
                data: data,
                limits: DecodeLimits(maximumMetadataBytes: 128)
            )
        ) { error in
            XCTAssertEqual(error as? ImageCraftError, .metadataLimitExceeded)
        }
    }

    func testJPEGMetadataAfterFirstScanCountsTowardLimit() throws {
        let data = makeJPEGWithPostScanMetadata(payloadBytes: 256)
        XCTAssertThrowsError(
            try ImageIOImageDecoder().probe(
                data: data,
                limits: DecodeLimits(maximumMetadataBytes: 128)
            )
        ) { error in
            XCTAssertEqual(error as? ImageCraftError, .metadataLimitExceeded)
        }
    }

    func testJPEGRestartMarkersDoNotHidePostScanMetadata() throws {
        let data = makeJPEGWithRestartMarkerAndPostScanMetadata(payloadBytes: 256)
        XCTAssertThrowsError(
            try ImageIOImageDecoder().probe(
                data: data,
                limits: DecodeLimits(maximumMetadataBytes: 128)
            )
        ) { error in
            XCTAssertEqual(error as? ImageCraftError, .metadataLimitExceeded)
        }
    }

    func testJPEGProbeRejectsExcessiveProgressiveScanCountBeforeImageIO() throws {
        let aboveLimit = makeJPEGWithStructuralScanCount(501)
        XCTAssertThrowsError(
            try ImageIOImageDecoder().probe(data: aboveLimit, limits: .coreV1)
        ) { error in
            XCTAssertEqual(error as? ImageCraftError, .unsupportedOrCorruptImage)
        }
    }

    func testInstrumentedDecodeMatchesOrdinaryPreparedDecodeDiagPt014() throws {
        let data = try makeOrientedJPEG(width: 120, height: 60, orientation: 1)
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: 60, height: 30),
            contentMode: .fit
        )
        let ordinaryDecoder = ImageIOImageDecoder()
        let ordinaryPreparation = try ordinaryDecoder.prepare(data: data, limits: .coreV1)
        let ordinary = try ordinaryDecoder.decode(
            preparation: ordinaryPreparation,
            request: request,
            limits: .coreV1
        )

        let instrumentedDecoder = ImageIOImageDecoder()
        let instrumentedPreparation = try instrumentedDecoder.prepare(
            data: data,
            limits: .coreV1
        )
        let result = try instrumentedDecoder.decodeWithDiagnostics(
            preparation: instrumentedPreparation,
            request: request,
            limits: .coreV1
        )

        XCTAssertEqual(result.image.pixelWidth, ordinary.pixelWidth)
        XCTAssertEqual(result.image.pixelHeight, ordinary.pixelHeight)
        XCTAssertEqual(result.image.colorDescription, ordinary.colorDescription)
        XCTAssertEqual(result.image.alphaMode, ordinary.alphaMode)
        XCTAssertEqual(result.image.pixelFormat, ordinary.pixelFormat)
        let repeated = try XCTUnwrap(result.diagnostics.repeatedPreparationDiagnostics)
        XCTAssertEqual(repeated.containerInspectionNanoseconds, 0)
        XCTAssertGreaterThan(result.diagnostics.sourceCreationNanoseconds, 0)
        XCTAssertGreaterThan(result.diagnostics.sourceTypeNanoseconds, 0)
        XCTAssertGreaterThan(result.diagnostics.frameCountNanoseconds, 0)
        XCTAssertGreaterThan(repeated.imagePropertiesReadNanoseconds, 0)
        XCTAssertGreaterThan(repeated.probeValidationNanoseconds, 0)
        XCTAssertGreaterThan(result.diagnostics.rasterCreationNanoseconds, 0)
        XCTAssertGreaterThan(result.diagnostics.postProcessingNanoseconds, 0)
    }

    func testJPEGAndGIFRejectBytesAfterTerminalMarkerSecCase045() throws {
        var jpeg = try makeOrientedJPEG(width: 8, height: 8, orientation: 1)
        jpeg.append(contentsOf: [0x00, 0x01])
        XCTAssertThrowsError(try ImageIOImageDecoder().probe(data: jpeg, limits: .coreV1)) {
            error in
            XCTAssertEqual(error as? ImageCraftError, .unsupportedOrCorruptImage)
        }

        var gif = Data([
            0x47, 0x49, 0x46, 0x38, 0x39, 0x61,
            0x01, 0x00, 0x01, 0x00,
            0x00, 0x00, 0x00,
            0x3B,
        ])
        gif.append(0x00)
        XCTAssertThrowsError(try ImageIOImageDecoder().probe(data: gif, limits: .coreV1)) { error in
            XCTAssertEqual(error as? ImageCraftError, .unsupportedOrCorruptImage)
        }
    }

    func testPNGRejectsBytesAfterIEND() throws {
        var data = try makePNG(width: 10, height: 10)
        data.append(Data("unexpected-trailing-payload".utf8))
        XCTAssertThrowsError(
            try ImageIOImageDecoder().probe(data: data, limits: .coreV1)
        ) { error in
            XCTAssertEqual(error as? ImageCraftError, .unsupportedOrCorruptImage)
        }
    }

    func testUnknownAndDisallowedFormatsAreRejectedSecCase021() throws {
        XCTAssertThrowsError(
            try ImageIOImageDecoder().probe(
                data: Data("BM-not-a-supported-core-format".utf8),
                limits: .coreV1
            )
        ) { error in
            XCTAssertEqual(error as? ImageCraftError, .unsupportedFormat)
        }

        let png = try makePNG(width: 10, height: 10)
        XCTAssertThrowsError(
            try ImageIOImageDecoder().probe(
                data: png,
                limits: DecodeLimits(allowedFormats: [.jpeg])
            )
        ) { error in
            XCTAssertEqual(error as? ImageCraftError, .unsupportedFormat)
        }
    }

    func testTargetPixelCountSaturatesOnOverflow() throws {
        let target = try TargetPixels(width: Int.max, height: Int.max)
        XCTAssertEqual(target.pixelCount, Int.max)
    }

    func testPackedRGBA8MaterializerPreservesExplicitTopToBottomPremultipliedBytes() throws {
        let bytes = Data([
            255, 0, 0, 255, 0, 128, 0, 128,
            0, 0, 255, 255, 128, 128, 128, 128,
        ])
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        let image = try XCTUnwrap(
            CGImage(
                width: 2,
                height: 2,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: 8,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
                    CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        )
        let packed = try ImageIOOwnedRGBAOutputMaterializer.materializePacked(
            DecodedImage(cgImage: image, sourceColorProfile: .standardSRGB),
            colorEncoding: .sRGB
        )

        XCTAssertEqual(packed.data, bytes)
        XCTAssertEqual(packed.pixelWidth, 2)
        XCTAssertEqual(packed.pixelHeight, 2)
        XCTAssertEqual(packed.bytesPerRow, 8)
        XCTAssertEqual(packed.pixelByteCharge, 16)
        XCTAssertEqual(packed.transferredByteCharge, 16)
        XCTAssertEqual(packed.colorEncoding, .sRGB)
    }

    func testDecodePackedRGBA8MatchesSRGBRasterAcrossStaticFormats() throws {
        let fixtures = [
            try makePNG(width: 31, height: 19),
            try makeOrientedJPEG(width: 31, height: 19, orientation: 1),
            try makeStaticGIF(width: 31, height: 19),
        ]
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: 17, height: 13),
            contentMode: .fit,
            colorPolicy: .convertToSRGB
        )
        let decoder = ImageIOImageDecoder()

        for data in fixtures {
            let reference = try decoder.decode(data: data, request: request, limits: .coreV1)
            let packed = try decoder.decodePackedRGBA8(
                data: data,
                request: request,
                limits: .coreV1
            )
            XCTAssertEqual(packed.pixelWidth, reference.pixelWidth)
            XCTAssertEqual(packed.pixelHeight, reference.pixelHeight)
            XCTAssertEqual(packed.bytesPerRow, packed.pixelWidth * 4)
            XCTAssertEqual(packed.colorEncoding, .sRGB)
            XCTAssertEqual(packed.data, try normalizedRGBABytes(reference.cgImage))
        }
    }

    func testOwnedRGBAOutputBoundsTransferChargeAndPreservesPixelsAcrossFormats() throws {
        let displayP3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let fixtures: [(data: Data, preserveSourceTransferIsUnknown: Bool)] = [
            (try makePNG(width: 31, height: 19), false),
            (try makeOrientedJPEG(width: 31, height: 19, orientation: 1), false),
            (try makeStaticGIF(width: 31, height: 19), false),
            (try makeColorManagedPNG(colorSpace: displayP3), true),
        ]
        for fixture in fixtures {
            let data = fixture.data
            for contentMode in [ImageContentMode.fit, .fill] {
                for colorPolicy in [ImageColorPolicy.preserveSource, .convertToSRGB] {
                    let request = ImageDecodeRequest(
                        target: try TargetPixels(width: 17, height: 13),
                        contentMode: contentMode,
                        colorPolicy: colorPolicy
                    )
                    let reference = try ImageIOImageDecoder().decode(
                        data: data,
                        request: request,
                        limits: .coreV1
                    )
                    let decoder = ImageIOImageDecoder(
                        qualificationPreparationRetentionMode: .encodedDataOnly,
                        outputMaterializationMode: .ownedRGBA8
                    )
                    let preparation = try decoder.prepare(data: data, limits: .coreV1)
                    let ledger = try XCTUnwrap(
                        decoder.preparationResourceLedger(
                            preparation,
                            request: request,
                            limits: .coreV1
                        )
                    )
                    let transferBound: Int?
                    if fixture.preserveSourceTransferIsUnknown,
                        colorPolicy == .preserveSource
                    {
                        XCTAssertEqual(
                            ledger.transferredOutput,
                            .unknown(.frameworkChosenOutputColorState)
                        )
                        transferBound = nil
                    } else {
                        guard case .bounded(let bounded) = ledger.transferredOutput else {
                            return XCTFail("owned RGBA output must publish a bounded transfer charge")
                        }
                        transferBound = bounded
                    }
                    XCTAssertEqual(ledger.outputLayoutAuthority, .codecOwnedRGBA8)
                    let result = try decoder.decode(
                        preparation: preparation,
                        request: request,
                        limits: .coreV1
                    )
                    XCTAssertEqual(result.cgImage.bytesPerRow, result.pixelWidth * 4)
                    if let transferBound {
                        XCTAssertLessThanOrEqual(result.estimatedByteCost, transferBound)
                    }
                    XCTAssertEqual(result.pixelWidth, reference.pixelWidth)
                    XCTAssertEqual(result.pixelHeight, reference.pixelHeight)
                    XCTAssertEqual(
                        try normalizedRGBABytes(result.cgImage),
                        try normalizedRGBABytes(reference.cgImage)
                    )
                }
            }
        }
    }

    func testOwnedRGBAQualificationIsDistinctFromFrameworkNativePixelRepresentation() throws {
        let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let data = try makeColorManagedPNG(
            width: 31,
            height: 19,
            colorSpace: srgb,
            rgba: (120, 60, 20, 128)
        )
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: 17, height: 13),
            contentMode: .fill,
            colorPolicy: .convertToSRGB
        )
        let native = try ImageIOImageDecoder().decode(data: data, request: request, limits: .coreV1)
        let decoder = ImageIOImageDecoder(
            qualificationPreparationRetentionMode: .encodedDataOnly,
            outputMaterializationMode: .ownedRGBA8
        )
        let preparation = try decoder.prepare(data: data, limits: .coreV1)
        let owned = try decoder.decode(
            preparation: preparation,
            request: request,
            limits: .coreV1
        )
        XCTAssertEqual(try normalizedRGBABytes(owned.cgImage), try normalizedRGBABytes(native.cgImage))
        XCTAssertEqual(owned.alphaMode, .premultipliedLast)
        XCTAssertNotEqual(owned.alphaMode, native.alphaMode)
        XCTAssertNotEqual(owned.pixelFormat, native.pixelFormat)
        XCTAssertEqual(owned.cgImage.bytesPerRow, owned.pixelWidth * 4)
    }

    func testIndependentPNGBackendMatchesImageIOPackedValueForRGB8RGBA8SRGBAndP3() throws {
        let displayP3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let displayP3ICC = try XCTUnwrap(displayP3.copyICCData()).bridgeToData()
        var straightRGBA = Data()
        for _ in 0..<(31 * 19) {
            straightRGBA.append(contentsOf: [190, 80, 30, 137])
        }
        var straightRGB = Data(capacity: 31 * 19 * 3)
        for index in 0..<(31 * 19) {
            straightRGB.append(UInt8((index * 31 + 17) & 0xFF))
            straightRGB.append(UInt8((index * 47 + 53) & 0xFF))
            straightRGB.append(UInt8((index * 73 + 101) & 0xFF))
        }
        let rgbFixture = try makeRawRGB8PNG(
            width: 31,
            height: 19,
            straightRGB: straightRGB,
            includeSRGB: true
        )
        let rgbaSRGBFixture = try makeRawRGBA8PNG(
            width: 31,
            height: 19,
            straightRGBA: straightRGBA,
            includeSRGB: true
        )
        let rgbaP3Fixture = try makeRawRGBA8PNG(
            width: 31,
            height: 19,
            straightRGBA: straightRGBA,
            includeSRGB: false,
            embeddedICCProfile: displayP3ICC
        )
        let fixtures: [(data: Data, sourceProfile: SourceColorProfile, embeddedICC: Data?)] = [
            (rgbFixture, .standardSRGB, nil),
            (rgbaSRGBFixture, .standardSRGB, nil),
            (rgbaP3Fixture, .embeddedICC, displayP3ICC),
        ]
        let oracle = ImageIOImageDecoder()
        let candidate = PNGIndependentRGBA8Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)
        for fixture in fixtures {
            let data = fixture.data
            let probe = try oracle.probe(data: data, limits: .coreV1)
            let request = ImageDecodeRequest(
                target: try TargetPixels(
                    width: probe.pixelWidth,
                    height: probe.pixelHeight
                ),
                colorPolicy: .preserveSource
            )
            let expected = try oracle.decodePackedRGBA8(
                data: data,
                request: request,
                limits: .coreV1
            )
            let actual = try candidate.decode(
                data: data,
                request: request,
                limits: .coreV1
            )
            XCTAssertEqual(actual, expected)
            XCTAssertEqual(actual.format, .rgba8Premultiplied)
            XCTAssertEqual(actual.bytesPerRow, actual.pixelWidth * 4)
            XCTAssertEqual(actual.sourceColorProfile, fixture.sourceProfile)
            switch (actual.colorEncoding, fixture.embeddedICC) {
            case (.sRGB, nil):
                break
            case (.embeddedICC(let profile), .some(let expectedProfile)):
                XCTAssertEqual(profile, expectedProfile)
            default:
                XCTFail("cross-backend packed color authority drifted")
            }
            let ledger = try candidate.resourceLedger(
                data: data,
                request: request,
                limits: .coreV1
            )
            XCTAssertNotNil(ledger.operationPeak.bytesUpperBound)
            XCTAssertEqual(ledger.outputLayoutAuthority, .codecOwnedRGBA8)
            XCTAssertEqual(
                ledger.transferredOutput.bytesUpperBound,
                actual.transferredByteCharge
            )
            XCTAssertEqual(actual.transferredByteCharge, expected.transferredByteCharge)
        }
        XCTAssertEqual(
            try candidate.decode(
                data: rgbaSRGBFixture,
                request: ImageDecodeRequest(
                    target: try TargetPixels(width: 31, height: 19),
                    colorPolicy: .preserveSource
                ),
                limits: .coreV1
            ).data,
            premultipliedRGBA8TestData(straightRGBA)
        )
    }

    func testIndependentPNGAdam7RGBA8MatchesManualValueImageIOAndResourceLedger() throws {
        let width = 13
        let height = 11
        var straightRGBA = Data(capacity: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                straightRGBA.append(UInt8((x * 37 + y * 11 + 17) & 0xFF))
                straightRGBA.append(UInt8((x * 19 + y * 53 + 29) & 0xFF))
                straightRGBA.append(UInt8((x * 71 + y * 23 + 41) & 0xFF))
                let alphaCycle: [UInt8] = [0, 1, 64, 127, 128, 200, 254, 255]
                straightRGBA.append(alphaCycle[(x + y * 3) % alphaCycle.count])
            }
        }
        let interlaced = try makeRawAdam7PNG(
            width: width,
            height: height,
            straightPixels: straightRGBA,
            bytesPerPixel: 4,
            colorType: 6,
            includeSRGB: true
        )
        let noninterlaced = try makeRawRGBA8PNG(
            width: width,
            height: height,
            straightRGBA: straightRGBA,
            includeSRGB: true
        )
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .preserveSource
        )
        let candidate = PNGIndependentRGBA8Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)
        let actual = try candidate.decode(data: interlaced, request: request, limits: .coreV1)
        let manual = premultipliedRGBA8TestData(straightRGBA)
        XCTAssertEqual(actual.data, manual)
        XCTAssertEqual(actual.bytesPerRow, width * 4)

        let oracle = try ImageIOImageDecoder().decodePackedRGBA8(
            data: interlaced,
            request: request,
            limits: .coreV1
        )
        XCTAssertEqual(actual, oracle)

        let interlacedLedger = try candidate.resourceLedger(
            data: interlaced,
            request: request,
            limits: .coreV1
        )
        let noninterlacedLedger = try candidate.resourceLedger(
            data: noninterlaced,
            request: request,
            limits: .coreV1
        )
        XCTAssertEqual(
            interlacedLedger.bound(for: .operationPeak),
            noninterlacedLedger.bound(for: .operationPeak)
        )
        XCTAssertEqual(
            interlacedLedger.bound(for: .transferredOutput),
            noninterlacedLedger.bound(for: .transferredOutput)
        )
        XCTAssertEqual(interlacedLedger.outputLayoutAuthority, .codecOwnedRGBA8)
    }

    func testIndependentPNGAdam7FailsClosedForMalformedStreamAndUnqualifiedRGB8() throws {
        let width = 13
        let height = 11
        var rgba = Data(capacity: width * height * 4)
        var rgb = Data(capacity: width * height * 3)
        for index in 0..<(width * height) {
            let red = UInt8((index * 31 + 7) & 0xFF)
            let green = UInt8((index * 47 + 13) & 0xFF)
            let blue = UInt8((index * 61 + 23) & 0xFF)
            rgb.append(contentsOf: [red, green, blue])
            rgba.append(contentsOf: [red, green, blue, UInt8((index * 17 + 3) & 0xFF)])
        }
        let malformed = try makeRawAdam7PNG(
            width: width,
            height: height,
            straightPixels: rgba,
            bytesPerPixel: 4,
            colorType: 6,
            includeSRGB: true,
            truncateInflatedTailByteCount: 1
        )
        let validRGBAdam7 = try makeRawAdam7PNG(
            width: width,
            height: height,
            straightPixels: rgb,
            bytesPerPixel: 3,
            colorType: 2,
            includeSRGB: true
        )
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .preserveSource
        )
        let candidate = PNGIndependentRGBA8Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)
        XCTAssertThrowsError(try candidate.decode(data: malformed, request: request)) { error in
            XCTAssertEqual(error as? ImageCraftError, .unsupportedOrCorruptImage)
        }
        _ = try ImageIOImageDecoder().decodePackedRGBA8(
            data: validRGBAdam7,
            request: request,
            limits: .coreV1
        )
        XCTAssertThrowsError(try candidate.decode(data: validRGBAdam7, request: request)) { error in
            XCTAssertEqual(error as? PNGIndependentRGBA8Error, .unsupportedSourceSemantics)
        }
    }

    func testIndependentPNG16PreserveSourceICCTransfersProfileAndAdmitsBeforeInflate() throws {
        let width = 7
        let height = 5
        var samples: [UInt16] = []
        samples.reserveCapacity(width * height * 4)
        for index in 0..<(width * height) {
            samples.append(UInt16((index * 8_111 + 0x1234) & 0xFFFF))
            samples.append(UInt16((index * 2_911 + 0xABCD) & 0xFFFF))
            samples.append(UInt16((index * 6_173 + 0x00FF) & 0xFFFF))
            samples.append(UInt16((index * 4_021 + 0x7FFF) & 0xFFFF))
        }
        let displayP3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let profile = try XCTUnwrap(displayP3.copyICCData()).bridgeToData()
        let iccPNG = try makeRawRGBA16PNG(
            width: width,
            height: height,
            samples: samples,
            filters: [0, 1, 2, 3, 4],
            splitIDAT: 3,
            includeSRGB: false,
            significantBits: [12, 13, 14, 15],
            embeddedICCProfile: profile
        )
        let sRGBPNG = try makeRawRGBA16PNG(
            width: width,
            height: height,
            samples: samples,
            filters: [0, 1, 2, 3, 4],
            splitIDAT: 3,
            includeSRGB: true,
            significantBits: [12, 13, 14, 15]
        )
        let maximumMetadataBytes = profile.count + 256
        let limits = DecodeLimits(
            maximumEncodedBytes: max(iccPNG.count, sRGBPNG.count) + 64,
            maximumDimension: 128,
            maximumPixelCount: 128 * 128,
            maximumFrameCount: 1,
            maximumMetadataBytes: maximumMetadataBytes,
            maximumAuxiliaryAttachments: 0,
            allowedFormats: [.png]
        )
        let preserve = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .preserveSource
        )
        let convert = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .convertToSRGB
        )
        let decoder = PNGIndependentRGBA16Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)

        let value = try decoder.decode(data: iccPNG, request: preserve, limits: limits)
        XCTAssertEqual(value.data, rgba16LittleEndianTestData(samples))
        XCTAssertEqual(value.colorEncoding, .embeddedICC(profile))
        XCTAssertEqual(value.sourceColorProfile, .embeddedICC)
        XCTAssertEqual(
            value.sourceSignificantBits?.channels,
            .rgba(red: 12, green: 13, blue: 14, alpha: 15)
        )
        XCTAssertEqual(value.transferredByteCharge, width * height * 8 + profile.count)

        let iccLedger = try decoder.resourceLedger(data: iccPNG, request: preserve, limits: limits)
        XCTAssertEqual(
            iccLedger.bytesUpperBound(for: .transferredOutput),
            width * height * 8 + profile.count
        )
        let iccPeak = try XCTUnwrap(iccLedger.bytesUpperBound(for: .operationPeak))
        let sRGBPeak = try XCTUnwrap(
            decoder.resourceLedger(data: sRGBPNG, request: preserve, limits: limits)
                .bytesUpperBound(for: .operationPeak)
        )
        XCTAssertGreaterThan(iccPeak, sRGBPeak)
        XCTAssertLessThan(
            sRGBPeak,
            max(
                sRGBPeak + maximumMetadataBytes,
                RFC1950BoundedInflate.maximumModeByteChargeUpperBound(
                    maximumOutputByteCount: maximumMetadataBytes
                )
            )
        )

        XCTAssertThrowsError(try decoder.decode(data: iccPNG, request: convert, limits: limits)) { error in
            XCTAssertEqual(error as? PNGIndependentRGBA16Error, .unsupportedSourceSemantics)
        }

        var rgba8ICC = try makeRawRGBA8PNG(
            width: width,
            height: height,
            straightRGBA: Data(repeating: 127, count: width * height * 4),
            includeSRGB: false,
            embeddedICCProfile: profile
        )
        let rgba8ICCP = try XCTUnwrap(
            try pngTestChunks(rgba8ICC).first(where: { $0.type == "iCCP" })
        )
        rgba8ICC[rgba8ICCP.payloadEnd - 1] ^= 0x01
        try rewritePNGTestChunkCRC(&rgba8ICC, chunk: rgba8ICCP)
        XCTAssertThrowsError(try decoder.decode(data: rgba8ICC, request: preserve, limits: limits)) { error in
            XCTAssertEqual(error as? PNGIndependentRGBA16Error, .unsupportedSourceSemantics)
        }

        var malformedICC = iccPNG
        let iccp = try XCTUnwrap(
            try pngTestChunks(malformedICC).first(where: { $0.type == "iCCP" })
        )
        malformedICC[iccp.payloadEnd - 1] ^= 0x01
        try rewritePNGTestChunkCRC(&malformedICC, chunk: iccp)
        let securityInflatePeak = RFC1950BoundedInflate.maximumModeByteChargeUpperBound(
            maximumOutputByteCount: maximumMetadataBytes
        )
        let worstPixelPeak = sRGBPeak + maximumMetadataBytes
        let preinflateAdmission = max(worstPixelPeak, securityInflatePeak)
        let tooSmall = PNGIndependentRGBA16Decoder(
            maximumOperationByteCharge: max(1, preinflateAdmission - 1)
        )
        XCTAssertThrowsError(
            try tooSmall.decode(data: malformedICC, request: preserve, limits: limits)
        ) { error in
            XCTAssertEqual(error as? PNGIndependentRGBA16Error, .operationBudgetExceeded)
        }
        XCTAssertThrowsError(
            try decoder.decode(data: malformedICC, request: preserve, limits: limits)
        ) { error in
            XCTAssertEqual(error as? ImageCraftError, .unsupportedOrCorruptImage)
        }
    }

    func testIndependentPNG16DisplayP3MatrixTRCICCConvertToSRGBIsExactAndResourceSeparated() throws {
        let displayP3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let profile = try XCTUnwrap(displayP3.copyICCData()).bridgeToData()
        let sourceRGB: [(UInt16, UInt16, UInt16)] = [
            (0, 0, 0),
            (0xFFFF, 0xFFFF, 0xFFFF),
            (32_768, 32_768, 32_768),
            (40_000, 30_000, 20_000),
            (50_000, 40_000, 30_000),
            (32_000, 30_000, 28_000),
            (25_000, 27_000, 26_000),
            (10_000, 12_000, 11_000),
            (56_000, 54_000, 52_000),
            (30_000, 40_000, 35_000),
        ]
        let expectedRGB: [(UInt16, UInt16, UInt16)] = [
            (0, 0, 0),
            (65_534, 0xFFFF, 0xFFFF),
            (32_768, 32_769, 32_768),
            (41_845, 29_485, 18_228),
            (51_915, 39_508, 28_425),
            (32_429, 29_913, 27_749),
            (24_523, 27_081, 25_939),
            (9_490, 12_077, 10_937),
            (56_437, 53_915, 51_756),
            (27_091, 40_353, 34_658),
        ]
        let alphaCycle: [UInt16] = [0, 1, 0x1234, 0x7FFF, 0x8000, 0xFFFE, 0xFFFF]
        var sourceSamples: [UInt16] = []
        var expectedSamples: [UInt16] = []
        for index in sourceRGB.indices {
            sourceSamples.append(contentsOf: [
                sourceRGB[index].0,
                sourceRGB[index].1,
                sourceRGB[index].2,
                alphaCycle[index % alphaCycle.count],
            ])
            expectedSamples.append(contentsOf: [
                expectedRGB[index].0,
                expectedRGB[index].1,
                expectedRGB[index].2,
                alphaCycle[index % alphaCycle.count],
            ])
        }

        let width = 5
        let height = 2
        let png = try makeRawRGBA16PNG(
            width: width,
            height: height,
            samples: sourceSamples,
            filters: [0, 1],
            splitIDAT: 3,
            includeSRGB: false,
            embeddedICCProfile: profile
        )
        let preserve = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .preserveSource
        )
        let convert = ImageDecodeRequest(target: preserve.target, colorPolicy: .convertToSRGB)
        let decoder = PNGIndependentRGBA16Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)
        let preserved = try decoder.decode(data: png, request: preserve, limits: .coreV1)
        let converted = try decoder.decode(data: png, request: convert, limits: .coreV1)

        XCTAssertEqual(preserved.data, rgba16LittleEndianTestData(sourceSamples))
        XCTAssertEqual(preserved.colorEncoding, .embeddedICC(profile))
        XCTAssertEqual(converted.data, rgba16LittleEndianTestData(expectedSamples))
        XCTAssertEqual(converted.colorEncoding, .sRGB)
        XCTAssertEqual(converted.sourceColorProfile, .embeddedICC)
        XCTAssertNil(converted.sourceSignificantBits)
        XCTAssertNil(converted.hdrStaticMetadata)
        XCTAssertEqual(preserved.transferredByteCharge, width * height * 8 + profile.count)
        XCTAssertEqual(converted.transferredByteCharge, width * height * 8)

        let preserveLedger = try decoder.resourceLedger(data: png, request: preserve, limits: .coreV1)
        let convertLedger = try decoder.resourceLedger(data: png, request: convert, limits: .coreV1)
        XCTAssertEqual(
            convertLedger.bytesUpperBound(for: .operationPeak),
            preserveLedger.bytesUpperBound(for: .operationPeak)
        )
        XCTAssertEqual(
            preserveLedger.bytesUpperBound(for: .transferredOutput),
            width * height * 8 + profile.count
        )
        XCTAssertEqual(convertLedger.bytesUpperBound(for: .transferredOutput), width * height * 8)

        let transparent = (red: UInt16(32_000), green: UInt16(30_000), blue: UInt16(28_000))
        let adam7RGBSamples: [UInt16] = [
            transparent.red, transparent.green, transparent.blue,
            32_001, 30_000, 28_000,
        ]
        let adam7 = try makeRawAdam7PNG(
            width: 2,
            height: 1,
            straightPixels: uint16BigEndianTestData(adam7RGBSamples),
            bytesPerPixel: 6,
            colorType: 2,
            includeSRGB: false,
            bitDepth: 16,
            truecolorTransparency: transparent,
            embeddedICCProfile: profile
        )
        let adam7Request = ImageDecodeRequest(
            target: try TargetPixels(width: 2, height: 1),
            colorPolicy: .convertToSRGB
        )
        let adam7Value = try decoder.decode(data: adam7, request: adam7Request, limits: .coreV1)
        XCTAssertEqual(
            adam7Value.data,
            rgba16LittleEndianTestData([
                32_429, 29_913, 27_749, 0,
                32_430, 29_913, 27_749, 0xFFFF,
            ])
        )
        XCTAssertEqual(adam7Value.colorEncoding, .sRGB)
        XCTAssertEqual(adam7Value.sourceColorProfile, .embeddedICC)

        let outOfGamut = try makeRawRGBA16PNG(
            width: 1,
            height: 1,
            samples: [0xFFFF, 0, 0, 0xFFFF],
            filters: [0],
            splitIDAT: 1,
            includeSRGB: false,
            embeddedICCProfile: profile
        )
        let outOfGamutRequest = ImageDecodeRequest(
            target: try TargetPixels(width: 1, height: 1),
            colorPolicy: .convertToSRGB
        )
        XCTAssertThrowsError(
            try decoder.decode(data: outOfGamut, request: outOfGamutRequest, limits: .coreV1)
        ) { error in
            XCTAssertEqual(error as? PNGIndependentRGBA16Error, .targetColorGamutExceeded)
        }
    }

    func testIndependentPNG16GenericMatrixTRCICCUsesProfileTagsInsteadOfP3Constants() throws {
        let profile = makeDeterministicMatrixTRCICCProfile(
            redXYZ: (28_576, 14_578, 911),
            greenXYZ: (25_238, 46_986, 6_362),
            blueXYZ: (9_376, 3_973, 46_788),
            trc: .type3(gamma: 144_179, a: 65_536, b: 0, c: 0, d: 0)
        )
        let sourceRGB: [(UInt16, UInt16, UInt16)] = [
            (0, 0, 0),
            (0xFFFF, 0xFFFF, 0xFFFF),
            (32_768, 32_768, 32_768),
            (40_000, 30_000, 20_000),
            (50_000, 40_000, 30_000),
            (32_000, 30_000, 28_000),
            (25_000, 27_000, 26_000),
            (10_000, 12_000, 11_000),
            (56_000, 54_000, 52_000),
            (30_000, 40_000, 35_000),
        ]
        let expectedRGB: [(UInt16, UInt16, UInt16)] = [
            (0, 0, 0),
            (65_534, 0xFFFF, 0xFFFF),
            (33_021, 33_022, 33_022),
            (40_368, 30_175, 19_689),
            (50_348, 40_368, 30_175),
            (32_234, 30_175, 28_105),
            (24_976, 27_066, 26_022),
            (8_735, 10_980, 9_862),
            (56_254, 54_293, 52_324),
            (30_175, 40_368, 35_302),
        ]
        var sourceSamples: [UInt16] = []
        var expectedSamples: [UInt16] = []
        for index in sourceRGB.indices {
            let alpha = UInt16((index * 7_919 + 0x1234) & 0xFFFF)
            sourceSamples.append(contentsOf: [
                sourceRGB[index].0, sourceRGB[index].1, sourceRGB[index].2, alpha,
            ])
            expectedSamples.append(contentsOf: [
                expectedRGB[index].0, expectedRGB[index].1, expectedRGB[index].2, alpha,
            ])
        }
        let data = try makeRawRGBA16PNG(
            width: 5,
            height: 2,
            samples: sourceSamples,
            filters: [4, 2],
            splitIDAT: 3,
            includeSRGB: false,
            embeddedICCProfile: profile
        )
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: 5, height: 2),
            colorPolicy: .convertToSRGB
        )
        let decoder = PNGIndependentRGBA16Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)
        let value = try decoder.decode(data: data, request: request, limits: .coreV1)
        XCTAssertEqual(value.data, rgba16LittleEndianTestData(expectedSamples))
        XCTAssertEqual(value.colorEncoding, .sRGB)
        XCTAssertEqual(value.sourceColorProfile, .embeddedICC)
        XCTAssertEqual(value.transferredByteCharge, 5 * 2 * 8)
        XCTAssertGreaterThan(
            try XCTUnwrap(
                try decoder.resourceLedger(data: data, request: request, limits: .coreV1)
                    .bytesUpperBound(for: .operationPeak)
            ),
            value.transferredByteCharge + profile.count
        )

        let mismatchedWhiteProfile = makeDeterministicMatrixTRCICCProfile(
            redXYZ: (28_676, 14_578, 911),
            greenXYZ: (25_238, 46_986, 6_362),
            blueXYZ: (9_376, 3_973, 46_788),
            trc: .type3(gamma: 144_179, a: 65_536, b: 0, c: 0, d: 0)
        )
        let invalid = try makeRawRGBA16PNG(
            width: 1,
            height: 1,
            samples: [20_000, 30_000, 40_000, 0xFFFF],
            filters: [0],
            splitIDAT: 1,
            includeSRGB: false,
            embeddedICCProfile: mismatchedWhiteProfile
        )
        let invalidRequest = ImageDecodeRequest(
            target: try TargetPixels(width: 1, height: 1),
            colorPolicy: .convertToSRGB
        )
        XCTAssertThrowsError(
            try decoder.decode(data: invalid, request: invalidRequest, limits: .coreV1)
        ) { error in
            XCTAssertEqual(error as? PNGIndependentRGBA16Error, .unsupportedSourceSemantics)
        }
    }

    func testIndependentPNG16MatrixTRCICCParametricType0UsesGammaAndMatchesType3Equivalent() throws {
        let redXYZ: (Int32, Int32, Int32) = (28_576, 14_578, 911)
        let greenXYZ: (Int32, Int32, Int32) = (25_238, 46_986, 6_362)
        let blueXYZ: (Int32, Int32, Int32) = (9_376, 3_973, 46_788)
        let sourceSamples: [UInt16] = [
            0, 0, 0, 0,
            32_768, 32_768, 32_768, 0x7FFF,
            40_000, 30_000, 20_000, 0xFFFF,
        ]
        let expectedGamma18: [UInt16] = [
            0, 0, 0, 0,
            37_506, 37_507, 37_507, 0x7FFF,
            44_139, 34_874, 24_784, 0xFFFF,
        ]
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: 3, height: 1),
            colorPolicy: .convertToSRGB
        )
        let decoder = PNGIndependentRGBA16Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)
        func png(for trc: PNGTestICCTransferCurve) throws -> Data {
            let profile = makeDeterministicMatrixTRCICCProfile(
                redXYZ: redXYZ,
                greenXYZ: greenXYZ,
                blueXYZ: blueXYZ,
                trc: trc
            )
            return try makeRawRGBA16PNG(
                width: 3,
                height: 1,
                samples: sourceSamples,
                filters: [4],
                splitIDAT: 2,
                includeSRGB: false,
                embeddedICCProfile: profile
            )
        }

        let gamma18 = try decoder.decode(
            data: png(for: .type0(gamma: 117_965)),
            request: request,
            limits: .coreV1
        )
        XCTAssertEqual(gamma18.data, rgba16LittleEndianTestData(expectedGamma18))
        XCTAssertEqual(gamma18.colorEncoding, .sRGB)
        XCTAssertEqual(gamma18.sourceColorProfile, .embeddedICC)

        let gamma22Type0 = try decoder.decode(
            data: png(for: .type0(gamma: 144_179)),
            request: request,
            limits: .coreV1
        )
        let gamma22Type3 = try decoder.decode(
            data: png(for: .type3(gamma: 144_179, a: 65_536, b: 0, c: 0, d: 0)),
            request: request,
            limits: .coreV1
        )
        XCTAssertEqual(gamma22Type0.data, gamma22Type3.data)

        let zeroGamma = try png(for: .type0(gamma: 0))
        XCTAssertThrowsError(
            try decoder.decode(data: zeroGamma, request: request, limits: .coreV1)
        ) { error in
            XCTAssertEqual(error as? PNGIndependentRGBA16Error, .unsupportedSourceSemantics)
        }
    }

    func testIndependentPNG16MatrixTRCICCParametricTypes1Through4UseQualifiedPiecewiseSemantics() throws {
        let redXYZ: (Int32, Int32, Int32) = (28_576, 14_578, 911)
        let greenXYZ: (Int32, Int32, Int32) = (25_238, 46_986, 6_362)
        let blueXYZ: (Int32, Int32, Int32) = (9_376, 3_973, 46_788)
        let sourceRGB: [(UInt16, UInt16, UInt16)] = [
            (0, 0, 0),
            (0xFFFF, 0xFFFF, 0xFFFF),
            (32_768, 32_768, 32_768),
            (40_000, 30_000, 20_000),
            (50_000, 40_000, 30_000),
            (32_000, 30_000, 28_000),
            (25_000, 27_000, 26_000),
            (10_000, 12_000, 11_000),
            (56_000, 54_000, 52_000),
            (30_000, 40_000, 35_000),
        ]
        let expectedType1: [(UInt16, UInt16, UInt16)] = [
            (0, 0, 0), (65_534, 65_535, 65_535), (35_199, 35_200, 35_200),
            (44_349, 30_751, 1), (53_968, 44_349, 30_751), (34_038, 30_751, 26_950),
            (19_524, 24_775, 22_336), (0, 0, 0), (58_793, 57_245, 55_638),
            (30_750, 44_349, 38_325),
        ]
        let expectedType2: [(UInt16, UInt16, UInt16)] = [
            (48_191, 48_192, 48_192), (65_534, 65_535, 65_535), (48_192, 48_193, 48_192),
            (52_680, 48_192, 48_192), (58_164, 52_680, 48_192), (48_191, 48_192, 48_192),
            (48_191, 48_192, 48_192), (48_191, 48_192, 48_192), (61_150, 60_177, 59_182),
            (48_191, 52_680, 49_634),
        ]
        let expectedType4: [(UInt16, UInt16, UInt16)] = [
            (0, 0, 0), (65_534, 65_535, 65_535), (42_341, 42_342, 42_341),
            (48_746, 40_683, 33_798), (56_117, 48_747, 40_682), (41_889, 40_683, 39_427),
            (37_442, 38_780, 38_119), (24_415, 26_628, 25_551), (59_987, 58_735, 57_446),
            (40_682, 48_747, 44_447),
        ]
        var sourceSamples: [UInt16] = []
        var alphas: [UInt16] = []
        for index in sourceRGB.indices {
            let alpha = UInt16((index * 7_919 + 0x1234) & 0xFFFF)
            alphas.append(alpha)
            sourceSamples.append(contentsOf: [sourceRGB[index].0, sourceRGB[index].1, sourceRGB[index].2, alpha])
        }
        func rgbaSamples(_ rgb: [(UInt16, UInt16, UInt16)]) -> [UInt16] {
            var result: [UInt16] = []
            for index in rgb.indices {
                result.append(contentsOf: [rgb[index].0, rgb[index].1, rgb[index].2, alphas[index]])
            }
            return result
        }
        func profile(_ trc: PNGTestICCTransferCurve) -> Data {
            makeDeterministicMatrixTRCICCProfile(
                redXYZ: redXYZ,
                greenXYZ: greenXYZ,
                blueXYZ: blueXYZ,
                trc: trc
            )
        }
        func png(_ trc: PNGTestICCTransferCurve) throws -> Data {
            try makeRawRGBA16PNG(
                width: 5,
                height: 2,
                samples: sourceSamples,
                filters: [4, 2],
                splitIDAT: 3,
                includeSRGB: false,
                embeddedICCProfile: profile(trc)
            )
        }

        let request = ImageDecodeRequest(
            target: try TargetPixels(width: 5, height: 2),
            colorPolicy: .convertToSRGB
        )
        let decoder = PNGIndependentRGBA16Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)
        let qualified: [(PNGTestICCTransferCurve, [(UInt16, UInt16, UInt16)])] = [
            (.type1(gamma: 65_536, a: 98_304, b: -32_768), expectedType1),
            (.type2(gamma: 65_536, a: 65_536, b: -32_768, c: 32_768), expectedType2),
            (
                .type4(
                    gamma: 65_536, a: 81_920, b: -32_768, c: 49_152,
                    d: 32_768, e: 16_384, f: 0
                ),
                expectedType4
            ),
        ]
        for (trc, expectedRGB) in qualified {
            let value = try decoder.decode(data: png(trc), request: request, limits: .coreV1)
            XCTAssertEqual(value.data, rgba16LittleEndianTestData(rgbaSamples(expectedRGB)))
            XCTAssertEqual(value.colorEncoding, .sRGB)
            XCTAssertEqual(value.sourceColorProfile, .embeddedICC)
        }

        let unqualified: [PNGTestICCTransferCurve] = [
            .type1(gamma: 65_536, a: 32_768, b: 32_768),
            .type2(gamma: 65_536, a: 65_536, b: -32_768, c: 16_384),
            .type4(
                gamma: 65_536, a: 98_304, b: -32_768, c: 49_152,
                d: 32_768, e: 0, f: 0
            ),
        ]
        for trc in unqualified {
            XCTAssertThrowsError(
                try decoder.decode(data: png(trc), request: request, limits: .coreV1)
            ) { error in
                XCTAssertEqual(error as? PNGIndependentRGBA16Error, .unsupportedSourceSemantics)
            }
        }
    }

    func testIndependentPNG16MatrixTRCICCCurveTypeIdentityGammaAndSampledInterpolationAreExact() throws {
        let redXYZ: (Int32, Int32, Int32) = (28_576, 14_578, 911)
        let greenXYZ: (Int32, Int32, Int32) = (25_238, 46_986, 6_362)
        let blueXYZ: (Int32, Int32, Int32) = (9_376, 3_973, 46_788)
        let sourceRGB: [(UInt16, UInt16, UInt16)] = [
            (0, 0, 0), (0xFFFF, 0xFFFF, 0xFFFF), (32_768, 32_768, 32_768),
            (40_000, 30_000, 20_000), (50_000, 40_000, 30_000), (32_000, 30_000, 28_000),
            (25_000, 27_000, 26_000), (10_000, 12_000, 11_000), (56_000, 54_000, 52_000),
            (30_000, 40_000, 35_000),
        ]
        let expectedGamma18: [(UInt16, UInt16, UInt16)] = [
            (0, 0, 0), (65_534, 65_535, 65_535), (37_497, 37_498, 37_497),
            (44_131, 34_864, 24_773), (52_832, 44_132, 34_864), (36_772, 34_864, 32_923),
            (29_945, 31_940, 30_947), (13_265, 15_738, 14_516), (57_841, 56_188, 54_518),
            (34_863, 44_132, 39_581),
        ]
        let expectedGamma22: [(UInt16, UInt16, UInt16)] = [
            (0, 0, 0), (65_534, 65_535, 65_535), (33_029, 33_030, 33_030),
            (40_375, 30_184, 19_698), (50_353, 40_375, 30_184), (32_242, 30_184, 28_114),
            (24_985, 27_074, 26_031), (8_742, 10_988, 9_869), (56_257, 54_296, 52_328),
            (30_183, 40_375, 35_310),
        ]
        let expectedIdentity: [(UInt16, UInt16, UInt16)] = [
            (0, 0, 0), (65_534, 65_535, 65_535), (48_192, 48_193, 48_192),
            (52_680, 46_322, 38_561), (58_164, 52_680, 46_322), (47_682, 46_322, 44_907),
            (42_669, 44_178, 43_432), (27_984, 30_478, 29_264), (61_150, 60_177, 59_182),
            (46_321, 52_680, 49_634),
        ]
        let expectedSampled: [(UInt16, UInt16, UInt16)] = [
            (0, 0, 0), (65_534, 65_535, 65_535), (35_199, 35_200, 35_200),
            (42_995, 33_070, 23_309), (51_699, 42_996, 33_070), (34_625, 33_070, 31_416),
            (28_707, 30_547, 29_645), (14_124, 15_524, 14_842), (57_567, 55_702, 53_749),
            (33_069, 42_996, 37_827),
        ]
        var sourceSamples: [UInt16] = []
        var alphas: [UInt16] = []
        for index in sourceRGB.indices {
            let alpha = UInt16((index * 7_919 + 0x1234) & 0xFFFF)
            alphas.append(alpha)
            sourceSamples.append(contentsOf: [sourceRGB[index].0, sourceRGB[index].1, sourceRGB[index].2, alpha])
        }
        func rgbaSamples(_ rgb: [(UInt16, UInt16, UInt16)]) -> [UInt16] {
            var result: [UInt16] = []
            for index in rgb.indices {
                result.append(contentsOf: [rgb[index].0, rgb[index].1, rgb[index].2, alphas[index]])
            }
            return result
        }
        func profile(_ trc: PNGTestICCTransferCurve) -> Data {
            makeDeterministicMatrixTRCICCProfile(
                redXYZ: redXYZ,
                greenXYZ: greenXYZ,
                blueXYZ: blueXYZ,
                trc: trc
            )
        }
        func png(_ trc: PNGTestICCTransferCurve) throws -> Data {
            try makeRawRGBA16PNG(
                width: 5,
                height: 2,
                samples: sourceSamples,
                filters: [4, 2],
                splitIDAT: 3,
                includeSRGB: false,
                embeddedICCProfile: profile(trc)
            )
        }

        let request = ImageDecodeRequest(
            target: try TargetPixels(width: 5, height: 2),
            colorPolicy: .convertToSRGB
        )
        let decoder = PNGIndependentRGBA16Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)
        for (label, trc, expectedRGB) in [
            ("curveIdentity", PNGTestICCTransferCurve.curveIdentity, expectedIdentity),
            ("curveGamma18", PNGTestICCTransferCurve.curveGamma(raw: 461), expectedGamma18),
            ("curveGamma22", PNGTestICCTransferCurve.curveGamma(raw: 563), expectedGamma22),
            ("curveSampled5", PNGTestICCTransferCurve.curveSamples([0, 4_096, 16_384, 36_863, 65_535]), expectedSampled),
        ] {
            let data = try png(trc)
            let value = try decoder.decode(data: data, request: request, limits: .coreV1)
            XCTAssertEqual(
                Array(value.data),
                Array(rgba16LittleEndianTestData(rgbaSamples(expectedRGB))),
                label
            )
            XCTAssertEqual(value.colorEncoding, .sRGB)
            XCTAssertEqual(value.sourceColorProfile, .embeddedICC)
            XCTAssertEqual(value.transferredByteCharge, 5 * 2 * 8)
            XCTAssertGreaterThan(
                try XCTUnwrap(
                    try decoder.resourceLedger(data: data, request: request, limits: .coreV1)
                        .bytesUpperBound(for: .operationPeak)
                ),
                value.transferredByteCharge + profile(trc).count
            )
        }

        for trc in [
            PNGTestICCTransferCurve.curveGamma(raw: 0),
            .curveSamples([1, 0xFFFF]),
            .curveSamples([0, 40_000, 30_000, 0xFFFF]),
        ] {
            XCTAssertThrowsError(
                try decoder.decode(data: png(trc), request: request, limits: .coreV1)
            ) { error in
                XCTAssertEqual(error as? PNGIndependentRGBA16Error, .unsupportedSourceSemantics)
            }
        }
    }

    func testIndependentPNG16MatrixTRCICCInputClassMatchesDisplayClassAndOutputClassStaysUnqualified() throws {
        let redXYZ: (Int32, Int32, Int32) = (28_576, 14_578, 911)
        let greenXYZ: (Int32, Int32, Int32) = (25_238, 46_986, 6_362)
        let blueXYZ: (Int32, Int32, Int32) = (9_376, 3_973, 46_788)
        let trc = PNGTestICCTransferCurve.type3(gamma: 144_179, a: 65_536, b: 0, c: 0, d: 0)
        func profile(_ profileClass: String) -> Data {
            makeDeterministicMatrixTRCICCProfile(
                redXYZ: redXYZ,
                greenXYZ: greenXYZ,
                blueXYZ: blueXYZ,
                trc: trc,
                profileClass: profileClass
            )
        }
        let monitorProfile = profile("mntr")
        let inputProfile = profile("scnr")
        let outputProfile = profile("prtr")
        XCTAssertEqual(monitorProfile.count, inputProfile.count)
        XCTAssertEqual(monitorProfile.count, outputProfile.count)
        XCTAssertEqual(monitorProfile[..<12], inputProfile[..<12])
        XCTAssertEqual(monitorProfile[16...], inputProfile[16...])
        XCTAssertEqual(Data(inputProfile[12..<16]), Data("scnr".utf8))

        let sourceRGB: [(UInt16, UInt16, UInt16)] = [
            (0, 0, 0),
            (0xFFFF, 0xFFFF, 0xFFFF),
            (32_768, 32_768, 32_768),
            (40_000, 30_000, 20_000),
            (50_000, 40_000, 30_000),
            (32_000, 30_000, 28_000),
            (25_000, 27_000, 26_000),
            (10_000, 12_000, 11_000),
            (56_000, 54_000, 52_000),
            (30_000, 40_000, 35_000),
        ]
        let expectedRGB: [(UInt16, UInt16, UInt16)] = [
            (0, 0, 0),
            (65_534, 65_535, 65_535),
            (33_021, 33_022, 33_022),
            (40_368, 30_175, 19_689),
            (50_348, 40_368, 30_175),
            (32_234, 30_175, 28_105),
            (24_976, 27_066, 26_022),
            (8_735, 10_980, 9_862),
            (56_254, 54_293, 52_324),
            (30_175, 40_368, 35_302),
        ]
        var sourceSamples: [UInt16] = []
        var expectedSamples: [UInt16] = []
        for index in sourceRGB.indices {
            let alpha = UInt16((index * 7_919 + 0x1234) & 0xFFFF)
            sourceSamples.append(contentsOf: [
                sourceRGB[index].0, sourceRGB[index].1, sourceRGB[index].2, alpha,
            ])
            expectedSamples.append(contentsOf: [
                expectedRGB[index].0, expectedRGB[index].1, expectedRGB[index].2, alpha,
            ])
        }
        func png(_ profile: Data) throws -> Data {
            try makeRawRGBA16PNG(
                width: 5,
                height: 2,
                samples: sourceSamples,
                filters: [4, 2],
                splitIDAT: 3,
                includeSRGB: false,
                embeddedICCProfile: profile
            )
        }
        let monitorPNG = try png(monitorProfile)
        let inputPNG = try png(inputProfile)
        let outputPNG = try png(outputProfile)
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: 5, height: 2),
            colorPolicy: .convertToSRGB
        )
        let decoder = PNGIndependentRGBA16Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)
        let monitorValue = try decoder.decode(data: monitorPNG, request: request, limits: .coreV1)
        let inputValue = try decoder.decode(data: inputPNG, request: request, limits: .coreV1)
        let expected = rgba16LittleEndianTestData(expectedSamples)
        XCTAssertEqual(monitorValue.data, expected)
        XCTAssertEqual(inputValue.data, expected)
        XCTAssertEqual(inputValue.data, monitorValue.data)
        XCTAssertEqual(inputValue.colorEncoding, .sRGB)
        XCTAssertEqual(inputValue.sourceColorProfile, .embeddedICC)
        XCTAssertEqual(inputValue.transferredByteCharge, monitorValue.transferredByteCharge)
        XCTAssertEqual(
            try decoder.resourceLedger(data: inputPNG, request: request, limits: .coreV1),
            try decoder.resourceLedger(data: monitorPNG, request: request, limits: .coreV1)
        )

        XCTAssertThrowsError(
            try decoder.decode(data: outputPNG, request: request, limits: .coreV1)
        ) { error in
            XCTAssertEqual(error as? PNGIndependentRGBA16Error, .unsupportedSourceSemantics)
        }
    }

    func testIndependentPNG16MatrixTRCICCInputClassDoesNotRequireMediaWhiteToEqualPCSWhite() throws {
        let redXYZ: (Int32, Int32, Int32) = (28_576, 14_578, 911)
        let greenXYZ: (Int32, Int32, Int32) = (25_238, 46_986, 6_362)
        let blueXYZ: (Int32, Int32, Int32) = (9_376, 3_973, 46_788)
        let trc = PNGTestICCTransferCurve.type3(
            gamma: 144_179,
            a: 65_536,
            b: 0,
            c: 0,
            d: 0
        )
        // Input-device media white describes the captured medium. It is not the PCS illuminant and the
        // device code [1,1,1] is not required to reconstruct it for the relative-colorimetric matrix/TRC
        // transform. Keep the authored matrix/TRC fixed and perturb only wtpt to lock that distinction.
        let capturedMediaWhite: (Int32, Int32, Int32) = (48_180, 50_050, 39_344)
        let baselineInputProfile = makeDeterministicMatrixTRCICCProfile(
            redXYZ: redXYZ,
            greenXYZ: greenXYZ,
            blueXYZ: blueXYZ,
            trc: trc,
            profileClass: "scnr"
        )
        let capturedWhiteInputProfile = makeDeterministicMatrixTRCICCProfile(
            redXYZ: redXYZ,
            greenXYZ: greenXYZ,
            blueXYZ: blueXYZ,
            trc: trc,
            profileClass: "scnr",
            mediaWhiteXYZ: capturedMediaWhite
        )
        let capturedWhiteDisplayProfile = makeDeterministicMatrixTRCICCProfile(
            redXYZ: redXYZ,
            greenXYZ: greenXYZ,
            blueXYZ: blueXYZ,
            trc: trc,
            profileClass: "mntr",
            mediaWhiteXYZ: capturedMediaWhite
        )
        let invalidInputProfile = makeDeterministicMatrixTRCICCProfile(
            redXYZ: redXYZ,
            greenXYZ: greenXYZ,
            blueXYZ: blueXYZ,
            trc: trc,
            profileClass: "scnr",
            mediaWhiteXYZ: (48_180, 0, 39_344)
        )

        let sourceSamples: [UInt16] = [
            32_768, 32_768, 32_768, 0x1234,
            40_000, 30_000, 20_000, 0x7FFF,
            25_000, 27_000, 26_000, 0x8000,
            10_000, 12_000, 11_000, 0xFFFF,
        ]
        func png(_ profile: Data) throws -> Data {
            try makeRawRGBA16PNG(
                width: 2,
                height: 2,
                samples: sourceSamples,
                filters: [4, 2],
                splitIDAT: 2,
                includeSRGB: false,
                embeddedICCProfile: profile
            )
        }
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: 2, height: 2),
            colorPolicy: .convertToSRGB
        )
        let decoder = PNGIndependentRGBA16Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)
        let baseline = try decoder.decode(
            data: png(baselineInputProfile),
            request: request,
            limits: .coreV1
        )
        let capturedWhite = try decoder.decode(
            data: png(capturedWhiteInputProfile),
            request: request,
            limits: .coreV1
        )
        XCTAssertEqual(capturedWhite.data, baseline.data)
        XCTAssertEqual(capturedWhite.colorEncoding, .sRGB)
        XCTAssertEqual(capturedWhite.sourceColorProfile, .embeddedICC)

        for unqualifiedProfile in [capturedWhiteDisplayProfile, invalidInputProfile] {
            XCTAssertThrowsError(
                try decoder.decode(data: png(unqualifiedProfile), request: request, limits: .coreV1)
            ) { error in
                XCTAssertEqual(error as? PNGIndependentRGBA16Error, .unsupportedSourceSemantics)
            }
        }
    }

    func testIndependentPNG16MatrixTRCICCLargeSampledCurveBorrowsProfileBytesWithoutDecodedTableCopy() throws {
        let redXYZ: (Int32, Int32, Int32) = (28_576, 14_578, 911)
        let greenXYZ: (Int32, Int32, Int32) = (25_238, 46_986, 6_362)
        let blueXYZ: (Int32, Int32, Int32) = (9_376, 3_973, 46_788)
        let smallSamples: [UInt16] = [0, 8_192, 24_576, 49_152, 65_535]
        let denominator = 1_024 * 1_024
        let largeSamples: [UInt16] = (0...1_024).map { index in
            let numerator = index * index * 65_535 + denominator / 2
            return UInt16(numerator / denominator)
        }
        XCTAssertEqual(largeSamples.count, 1_025)
        XCTAssertEqual(largeSamples.first, 0)
        XCTAssertEqual(largeSamples.last, UInt16.max)
        XCTAssertTrue(zip(largeSamples, largeSamples.dropFirst()).allSatisfy { $0.0 <= $0.1 })

        func profile(_ samples: [UInt16]) -> Data {
            makeDeterministicMatrixTRCICCProfile(
                redXYZ: redXYZ,
                greenXYZ: greenXYZ,
                blueXYZ: blueXYZ,
                trc: .curveSamples(samples)
            )
        }
        let smallProfile = profile(smallSamples)
        let largeProfile = profile(largeSamples)
        XCTAssertEqual(smallProfile.count, 320)
        XCTAssertEqual(largeProfile.count, 2_360)
        XCTAssertEqual(largeProfile.count - smallProfile.count, 2_040)

        let sourceRGB: [(UInt16, UInt16, UInt16)] = [
            (0, 0, 0),
            (0xFFFF, 0xFFFF, 0xFFFF),
            (32_768, 32_768, 32_768),
            (40_000, 30_000, 20_000),
            (50_000, 40_000, 30_000),
            (32_000, 30_000, 28_000),
            (25_000, 27_000, 26_000),
            (10_000, 12_000, 11_000),
            (56_000, 54_000, 52_000),
            (30_000, 40_000, 35_000),
        ]
        let expectedLargeRGB: [(UInt16, UInt16, UInt16)] = [
            (0, 0, 0),
            (65_534, 65_535, 65_535),
            (35_199, 35_200, 35_200),
            (42_215, 32_448, 22_111),
            (51_579, 42_216, 32_448),
            (34_440, 32_448, 30_433),
            (27_366, 29_418, 28_395),
            (10_828, 13_197, 12_021),
            (57_044, 55_234, 53_412),
            (32_447, 42_216, 37_390),
        ]
        var sourceSamples: [UInt16] = []
        var expectedLargeSamples: [UInt16] = []
        for index in sourceRGB.indices {
            let alpha = UInt16((index * 7_919 + 0x1234) & 0xFFFF)
            sourceSamples.append(contentsOf: [
                sourceRGB[index].0, sourceRGB[index].1, sourceRGB[index].2, alpha,
            ])
            expectedLargeSamples.append(contentsOf: [
                expectedLargeRGB[index].0,
                expectedLargeRGB[index].1,
                expectedLargeRGB[index].2,
                alpha,
            ])
        }

        func png(profile: Data) throws -> Data {
            try makeRawRGBA16PNG(
                width: 5,
                height: 2,
                samples: sourceSamples,
                filters: [4, 2],
                splitIDAT: 3,
                includeSRGB: false,
                embeddedICCProfile: profile
            )
        }
        let smallPNG = try png(profile: smallProfile)
        let largePNG = try png(profile: largeProfile)
        let limits = DecodeLimits(maximumMetadataBytes: 4_096)
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: 5, height: 2),
            colorPolicy: .convertToSRGB
        )
        let decoder = PNGIndependentRGBA16Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)
        XCTAssertThrowsError(
            try decoder.decode(
                data: largePNG,
                request: request,
                limits: DecodeLimits(maximumMetadataBytes: 1_024)
            )
        ) { error in
            XCTAssertEqual(error as? ImageCraftError, .metadataLimitExceeded)
        }
        let smallValue = try decoder.decode(data: smallPNG, request: request, limits: limits)
        let largeValue = try decoder.decode(data: largePNG, request: request, limits: limits)
        XCTAssertEqual(largeValue.data, rgba16LittleEndianTestData(expectedLargeSamples))
        XCTAssertEqual(smallValue.transferredByteCharge, 5 * 2 * 8)
        XCTAssertEqual(largeValue.transferredByteCharge, smallValue.transferredByteCharge)
        XCTAssertEqual(largeValue.colorEncoding, .sRGB)
        XCTAssertEqual(largeValue.sourceColorProfile, .embeddedICC)

        let smallLedger = try decoder.resourceLedger(data: smallPNG, request: request, limits: limits)
        let largeLedger = try decoder.resourceLedger(data: largePNG, request: request, limits: limits)
        let smallOperation = try XCTUnwrap(smallLedger.bytesUpperBound(for: .operationPeak))
        let largeOperation = try XCTUnwrap(largeLedger.bytesUpperBound(for: .operationPeak))
        XCTAssertEqual(largeOperation - smallOperation, largeProfile.count - smallProfile.count)
        XCTAssertEqual(
            largeLedger.bytesUpperBound(for: .transferredOutput),
            smallLedger.bytesUpperBound(for: .transferredOutput)
        )

        var mismatchedCountProfile = largeProfile
        let curveSignature = Data("curv".utf8)
        let curveRange = try XCTUnwrap(mismatchedCountProfile.range(of: curveSignature))
        let countOffset = curveRange.lowerBound + 8
        mismatchedCountProfile.replaceSubrange(
            countOffset..<(countOffset + 4),
            with: pngTestUInt32Bytes(1_026)
        )
        let malformedPNG = try png(profile: mismatchedCountProfile)
        XCTAssertThrowsError(
            try decoder.decode(data: malformedPNG, request: request, limits: limits)
        ) { error in
            XCTAssertEqual(error as? PNGIndependentRGBA16Error, .unsupportedSourceSemantics)
        }
    }

    func testIndependentPNG16MatrixTRCICCPerChannelType0UsesEachChannelCurveAndPreservesResourcePhases() throws {
        let redXYZ = (Int32(28_576), Int32(14_578), Int32(911))
        let greenXYZ = (Int32(25_238), Int32(46_986), Int32(6_362))
        let blueXYZ = (Int32(9_376), Int32(3_973), Int32(46_788))
        let perChannelProfile = makeDeterministicMatrixTRCICCProfile(
            redXYZ: redXYZ,
            greenXYZ: greenXYZ,
            blueXYZ: blueXYZ,
            trc: .type0(gamma: 117_965),
            greenTRC: .type0(gamma: 131_072),
            blueTRC: .type0(gamma: 144_179)
        )
        let sharedProfile = makeDeterministicMatrixTRCICCProfile(
            redXYZ: redXYZ,
            greenXYZ: greenXYZ,
            blueXYZ: blueXYZ,
            trc: .type0(gamma: 117_965)
        )
        XCTAssertEqual(perChannelProfile.count - sharedProfile.count, 32)

        let sourceRGB: [(UInt16, UInt16, UInt16)] = [
            (0, 0, 0),
            (0xFFFF, 0xFFFF, 0xFFFF),
            (32_768, 32_768, 32_768),
            (40_000, 30_000, 20_000),
            (50_000, 40_000, 30_000),
            (32_000, 30_000, 28_000),
            (25_000, 27_000, 26_000),
            (10_000, 12_000, 11_000),
            (56_000, 54_000, 52_000),
            (30_000, 40_000, 35_000),
        ]
        let expectedRGB: [(UInt16, UInt16, UInt16)] = [
            (0, 0, 0),
            (65_534, 65_535, 65_535),
            (37_506, 35_200, 33_022),
            (44_139, 32_448, 19_689),
            (52_837, 42_215, 30_175),
            (36_782, 32_448, 28_105),
            (29_956, 29_418, 26_022),
            (13_275, 13_196, 9_862),
            (57_844, 55_234, 52_324),
            (34_873, 42_215, 35_302),
        ]
        var sourceSamples: [UInt16] = []
        var expectedSamples: [UInt16] = []
        for index in sourceRGB.indices {
            let alpha = UInt16((index * 7_919 + 0x1234) & 0xFFFF)
            sourceSamples.append(contentsOf: [
                sourceRGB[index].0, sourceRGB[index].1, sourceRGB[index].2, alpha,
            ])
            expectedSamples.append(contentsOf: [
                expectedRGB[index].0, expectedRGB[index].1, expectedRGB[index].2, alpha,
            ])
        }

        let width = 5
        let height = 2
        let perChannelPNG = try makeRawRGBA16PNG(
            width: width,
            height: height,
            samples: sourceSamples,
            filters: [4, 2],
            splitIDAT: 3,
            includeSRGB: false,
            embeddedICCProfile: perChannelProfile
        )
        let sharedPNG = try makeRawRGBA16PNG(
            width: width,
            height: height,
            samples: sourceSamples,
            filters: [4, 2],
            splitIDAT: 3,
            includeSRGB: false,
            embeddedICCProfile: sharedProfile
        )
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .convertToSRGB
        )
        let limits = DecodeLimits(maximumMetadataBytes: 512)
        let decoder = PNGIndependentRGBA16Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)
        let perChannelValue = try decoder.decode(
            data: perChannelPNG,
            request: request,
            limits: limits
        )
        let sharedValue = try decoder.decode(data: sharedPNG, request: request, limits: limits)
        XCTAssertEqual(perChannelValue.data, rgba16LittleEndianTestData(expectedSamples))
        XCTAssertEqual(perChannelValue.colorEncoding, .sRGB)
        XCTAssertEqual(perChannelValue.sourceColorProfile, .embeddedICC)
        XCTAssertEqual(perChannelValue.transferredByteCharge, width * height * 8)
        XCTAssertNotEqual(perChannelValue.data, sharedValue.data)

        let perChannelLedger = try decoder.resourceLedger(
            data: perChannelPNG,
            request: request,
            limits: limits
        )
        let sharedLedger = try decoder.resourceLedger(data: sharedPNG, request: request, limits: limits)
        let perChannelOperation = try XCTUnwrap(
            perChannelLedger.bytesUpperBound(for: .operationPeak)
        )
        let sharedOperation = try XCTUnwrap(sharedLedger.bytesUpperBound(for: .operationPeak))
        XCTAssertEqual(
            perChannelOperation - sharedOperation,
            perChannelProfile.count - sharedProfile.count
        )
        XCTAssertEqual(
            perChannelLedger.bytesUpperBound(for: .transferredOutput),
            width * height * 8
        )
        XCTAssertEqual(
            sharedLedger.bytesUpperBound(for: .transferredOutput),
            width * height * 8
        )

        let transparent = (red: UInt16(32_000), green: UInt16(30_000), blue: UInt16(28_000))
        let adam7 = try makeRawAdam7PNG(
            width: 2,
            height: 1,
            straightPixels: uint16BigEndianTestData([
                transparent.red, transparent.green, transparent.blue,
                32_001, 30_000, 28_000,
            ]),
            bytesPerPixel: 6,
            colorType: 2,
            includeSRGB: false,
            bitDepth: 16,
            truecolorTransparency: transparent,
            embeddedICCProfile: perChannelProfile
        )
        let adam7Request = ImageDecodeRequest(
            target: try TargetPixels(width: 2, height: 1),
            colorPolicy: .convertToSRGB
        )
        let adam7Value = try decoder.decode(data: adam7, request: adam7Request, limits: limits)
        XCTAssertEqual(
            adam7Value.data,
            rgba16LittleEndianTestData([
                36_782, 32_448, 28_105, 0,
                36_783, 32_448, 28_105, 0xFFFF,
            ])
        )
    }

    func testIndependentPNG16MatrixTRCICCPerChannelParametricFunctionsComposeIndependently() throws {
        let redXYZ = (Int32(28_576), Int32(14_578), Int32(911))
        let greenXYZ = (Int32(25_238), Int32(46_986), Int32(6_362))
        let blueXYZ = (Int32(9_376), Int32(3_973), Int32(46_788))
        let profile = makeDeterministicMatrixTRCICCProfile(
            redXYZ: redXYZ,
            greenXYZ: greenXYZ,
            blueXYZ: blueXYZ,
            trc: .type1(gamma: 65_536, a: 98_304, b: -32_768),
            greenTRC: .type3(gamma: 144_179, a: 65_536, b: 0, c: 0, d: 0),
            blueTRC: .type4(
                gamma: 65_536,
                a: 81_920,
                b: -32_768,
                c: 49_152,
                d: 32_768,
                e: 16_384,
                f: 0
            )
        )
        let sourceRGB: [(UInt16, UInt16, UInt16)] = [
            (0, 0, 0),
            (0xFFFF, 0xFFFF, 0xFFFF),
            (32_768, 32_768, 32_768),
            (40_000, 30_000, 20_000),
            (50_000, 40_000, 30_000),
            (32_000, 30_000, 28_000),
            (25_000, 27_000, 26_000),
            (10_000, 12_000, 11_000),
            (56_000, 54_000, 52_000),
            (30_000, 40_000, 35_000),
        ]
        let expectedRGB: [(UInt16, UInt16, UInt16)] = [
            (0, 0, 0),
            (65_534, 65_535, 65_535),
            (35_199, 33_022, 42_341),
            (44_348, 30_176, 33_798),
            (53_968, 40_369, 40_682),
            (34_038, 30_176, 39_427),
            (19_524, 27_066, 38_119),
            (0, 10_980, 25_551),
            (58_793, 54_293, 57_446),
            (30_750, 40_369, 44_447),
        ]
        var sourceSamples: [UInt16] = []
        var expectedSamples: [UInt16] = []
        for index in sourceRGB.indices {
            let alpha = UInt16((index * 7_919 + 0x1234) & 0xFFFF)
            sourceSamples.append(contentsOf: [sourceRGB[index].0, sourceRGB[index].1, sourceRGB[index].2, alpha])
            expectedSamples.append(contentsOf: [expectedRGB[index].0, expectedRGB[index].1, expectedRGB[index].2, alpha])
        }
        let data = try makeRawRGBA16PNG(
            width: 5,
            height: 2,
            samples: sourceSamples,
            filters: [4, 2],
            splitIDAT: 3,
            includeSRGB: false,
            embeddedICCProfile: profile
        )
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: 5, height: 2),
            colorPolicy: .convertToSRGB
        )
        let decoder = PNGIndependentRGBA16Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)
        let value = try decoder.decode(data: data, request: request, limits: .coreV1)
        XCTAssertEqual(value.data, rgba16LittleEndianTestData(expectedSamples))
        XCTAssertEqual(value.colorEncoding, .sRGB)
        XCTAssertEqual(value.sourceColorProfile, .embeddedICC)

        let transparent = (red: UInt16(32_000), green: UInt16(30_000), blue: UInt16(28_000))
        let adam7 = try makeRawAdam7PNG(
            width: 2,
            height: 1,
            straightPixels: uint16BigEndianTestData([
                transparent.red, transparent.green, transparent.blue,
                32_001, 30_000, 28_000,
            ]),
            bytesPerPixel: 6,
            colorType: 2,
            includeSRGB: false,
            bitDepth: 16,
            truecolorTransparency: transparent,
            embeddedICCProfile: profile
        )
        let adam7Request = ImageDecodeRequest(
            target: try TargetPixels(width: 2, height: 1),
            colorPolicy: .convertToSRGB
        )
        let adam7Value = try decoder.decode(data: adam7, request: adam7Request, limits: .coreV1)
        XCTAssertEqual(
            adam7Value.data,
            rgba16LittleEndianTestData([
                34_038, 30_176, 39_427, 0,
                34_040, 30_176, 39_427, 0xFFFF,
            ])
        )
    }

    func testIndependentPNG16MatrixTRCICCPerChannelMixedCurveEncodingsComposeIndependently() throws {
        let redXYZ = (Int32(28_576), Int32(14_578), Int32(911))
        let greenXYZ = (Int32(25_238), Int32(46_986), Int32(6_362))
        let blueXYZ = (Int32(9_376), Int32(3_973), Int32(46_788))
        let profile = makeDeterministicMatrixTRCICCProfile(
            redXYZ: redXYZ,
            greenXYZ: greenXYZ,
            blueXYZ: blueXYZ,
            trc: .curveSamples([0, 8_192, 24_576, 49_152, 65_535]),
            greenTRC: .type3(gamma: 144_179, a: 65_536, b: 0, c: 0, d: 0),
            blueTRC: .curveGamma(raw: 461)
        )
        let sourceRGB: [(UInt16, UInt16, UInt16)] = [
            (0, 0, 0),
            (0xFFFF, 0xFFFF, 0xFFFF),
            (32_768, 32_768, 32_768),
            (40_000, 30_000, 20_000),
            (50_000, 40_000, 30_000),
            (32_000, 30_000, 28_000),
            (25_000, 27_000, 26_000),
            (10_000, 12_000, 11_000),
            (56_000, 54_000, 52_000),
            (30_000, 40_000, 35_000),
        ]
        let expectedRGB: [(UInt16, UInt16, UInt16)] = [
            (0, 0, 0),
            (65_534, 65_535, 65_535),
            (42_341, 33_022, 37_497),
            (49_902, 30_176, 24_773),
            (58_164, 40_369, 34_864),
            (41_737, 30_176, 32_923),
            (35_615, 27_066, 30_947),
            (20_060, 10_980, 14_516),
            (61_150, 54_293, 54_518),
            (40_109, 40_368, 39_581),
        ]
        var sourceSamples: [UInt16] = []
        var expectedSamples: [UInt16] = []
        for index in sourceRGB.indices {
            let alpha = UInt16((index * 7_919 + 0x1234) & 0xFFFF)
            sourceSamples.append(contentsOf: [
                sourceRGB[index].0, sourceRGB[index].1, sourceRGB[index].2, alpha,
            ])
            expectedSamples.append(contentsOf: [
                expectedRGB[index].0, expectedRGB[index].1, expectedRGB[index].2, alpha,
            ])
        }

        let width = 5
        let height = 2
        let data = try makeRawRGBA16PNG(
            width: width,
            height: height,
            samples: sourceSamples,
            filters: [4, 2],
            splitIDAT: 3,
            includeSRGB: false,
            embeddedICCProfile: profile
        )
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .convertToSRGB
        )
        let limits = DecodeLimits(maximumMetadataBytes: 512)
        let decoder = PNGIndependentRGBA16Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)
        let value = try decoder.decode(data: data, request: request, limits: limits)
        XCTAssertEqual(value.data, rgba16LittleEndianTestData(expectedSamples))
        XCTAssertEqual(value.colorEncoding, .sRGB)
        XCTAssertEqual(value.sourceColorProfile, .embeddedICC)
        XCTAssertEqual(value.transferredByteCharge, width * height * 8)
        let operation = try XCTUnwrap(
            try decoder.resourceLedger(data: data, request: request, limits: limits)
                .bytesUpperBound(for: .operationPeak)
        )
        XCTAssertGreaterThan(operation, value.transferredByteCharge + profile.count)

        let transparent = (red: UInt16(32_000), green: UInt16(30_000), blue: UInt16(28_000))
        let adam7 = try makeRawAdam7PNG(
            width: 2,
            height: 1,
            straightPixels: uint16BigEndianTestData([
                transparent.red, transparent.green, transparent.blue,
                32_001, 30_000, 28_000,
            ]),
            bytesPerPixel: 6,
            colorType: 2,
            includeSRGB: false,
            bitDepth: 16,
            truecolorTransparency: transparent,
            embeddedICCProfile: profile
        )
        let adam7Request = ImageDecodeRequest(
            target: try TargetPixels(width: 2, height: 1),
            colorPolicy: .convertToSRGB
        )
        let adam7Value = try decoder.decode(data: adam7, request: adam7Request, limits: limits)
        XCTAssertEqual(
            adam7Value.data,
            rgba16LittleEndianTestData([
                41_737, 30_176, 32_923, 0,
                41_738, 30_176, 32_923, 0xFFFF,
            ])
        )

        let invalidProfile = makeDeterministicMatrixTRCICCProfile(
            redXYZ: redXYZ,
            greenXYZ: greenXYZ,
            blueXYZ: blueXYZ,
            trc: .curveSamples([0, 8_192, 24_576, 49_152, 65_535]),
            greenTRC: .type3(gamma: 144_179, a: 65_536, b: 0, c: 0, d: 0),
            blueTRC: .curveGamma(raw: 0)
        )
        let invalid = try makeRawRGBA16PNG(
            width: 1,
            height: 1,
            samples: [20_000, 30_000, 40_000, 0xFFFF],
            filters: [0],
            splitIDAT: 1,
            includeSRGB: false,
            embeddedICCProfile: invalidProfile
        )
        let invalidRequest = ImageDecodeRequest(
            target: try TargetPixels(width: 1, height: 1),
            colorPolicy: .convertToSRGB
        )
        XCTAssertThrowsError(
            try decoder.decode(data: invalid, request: invalidRequest, limits: limits)
        ) { error in
            XCTAssertEqual(error as? PNGIndependentRGBA16Error, .unsupportedSourceSemantics)
        }
    }

    func testIndependentPNG16GrayscaleAndAlphaExpandExactlyWithSourcePrecisionAndRowCharges() throws {
        let width = 7
        let height = 5
        let transparentGray = UInt16(0x91B3)
        var graySamples: [UInt16] = []
        var gaSamples: [UInt16] = []
        let alphaCycle: [UInt16] = [0, 1, 0x0100, 0x7FFF, 0x8000, 0xFFFE, 0xFFFF]
        for index in 0..<(width * height) {
            let gray: UInt16
            if index == 0 {
                gray = transparentGray
            } else if index == 1 {
                gray = transparentGray ^ 0x0001
            } else {
                gray = UInt16((index * 2_053 + 0x1357) & 0xFFFF)
            }
            graySamples.append(gray)
            gaSamples.append(gray)
            gaSamples.append(alphaCycle[index % alphaCycle.count])
        }

        let grayPNG = try makeRawGrayscaleFamily16PNG(
            width: width,
            height: height,
            samples: graySamples,
            colorType: 0,
            filters: [0, 1, 2, 3, 4],
            splitIDAT: 3,
            includeSRGB: true,
            transparentGray: transparentGray,
            significantBits: [12]
        )
        let grayWithoutSBIT = try makeRawGrayscaleFamily16PNG(
            width: width,
            height: height,
            samples: graySamples,
            colorType: 0,
            filters: [0, 1, 2, 3, 4],
            splitIDAT: 3,
            includeSRGB: true,
            transparentGray: transparentGray
        )
        let gaPNG = try makeRawGrayscaleFamily16PNG(
            width: width,
            height: height,
            samples: gaSamples,
            colorType: 4,
            filters: [4, 3, 2, 1, 0],
            splitIDAT: 4,
            includeSRGB: true,
            significantBits: [11, 15]
        )
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .preserveSource
        )
        let decoder = PNGIndependentRGBA16Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)

        let grayValue = try decoder.decode(data: grayPNG, request: request, limits: .coreV1)
        XCTAssertEqual(
            grayValue.data,
            grayscaleFamily16ToRGBA16LittleEndianTestData(
                graySamples,
                colorType: 0,
                transparentGray: transparentGray
            )
        )
        XCTAssertEqual(grayValue.sourceSignificantBits?.channels, .grayscale(gray: 12))
        XCTAssertFalse(try XCTUnwrap(grayValue.sourceSignificantBits).sourceHasStoredAlpha)
        XCTAssertEqual(grayValue.data[6], 0)
        XCTAssertEqual(grayValue.data[7], 0)
        XCTAssertEqual(grayValue.data[14], 0xFF)
        XCTAssertEqual(grayValue.data[15], 0xFF)

        let gaValue = try decoder.decode(data: gaPNG, request: request, limits: .coreV1)
        XCTAssertEqual(
            gaValue.data,
            grayscaleFamily16ToRGBA16LittleEndianTestData(gaSamples, colorType: 4)
        )
        XCTAssertEqual(
            gaValue.sourceSignificantBits?.channels,
            .grayscaleAlpha(gray: 11, alpha: 15)
        )
        XCTAssertTrue(try XCTUnwrap(gaValue.sourceSignificantBits).sourceHasStoredAlpha)

        let grayLedger = try decoder.resourceLedger(data: grayPNG, request: request, limits: .coreV1)
        let grayWithoutSBITLedger = try decoder.resourceLedger(
            data: grayWithoutSBIT,
            request: request,
            limits: .coreV1
        )
        XCTAssertEqual(grayLedger.bound(for: .operationPeak), grayWithoutSBITLedger.bound(for: .operationPeak))
        let grayPeak = try XCTUnwrap(grayLedger.bytesUpperBound(for: .operationPeak))
        let gaPeak = try XCTUnwrap(
            decoder.resourceLedger(data: gaPNG, request: request, limits: .coreV1)
                .bytesUpperBound(for: .operationPeak)
        )
        XCTAssertEqual(gaPeak - grayPeak, width * 4)
        XCTAssertEqual(grayLedger.bytesUpperBound(for: .transferredOutput), width * height * 8)
    }

    func testIndependentPNG16Adam7GrayscaleAndAlphaMatchNoninterlacedValueAndLedger() throws {
        let width = 5
        let height = 3
        let transparentGray = UInt16(0xA1B2)
        var graySamples: [UInt16] = []
        var gaSamples: [UInt16] = []
        for index in 0..<(width * height) {
            let gray = index == 4 ? transparentGray : UInt16((index * 4_093 + 0x2468) & 0xFFFF)
            graySamples.append(gray)
            gaSamples.append(gray)
            gaSamples.append(UInt16((index * 7_919 + 0x1021) & 0xFFFF))
        }
        let grayBigEndian = uint16BigEndianTestData(graySamples)
        let gaBigEndian = uint16BigEndianTestData(gaSamples)
        let adam7Gray = try makeRawAdam7PNG(
            width: width,
            height: height,
            straightPixels: grayBigEndian,
            bytesPerPixel: 2,
            colorType: 0,
            includeSRGB: true,
            bitDepth: 16,
            significantBits: [12],
            grayscaleTransparency: transparentGray
        )
        let adam7GA = try makeRawAdam7PNG(
            width: width,
            height: height,
            straightPixels: gaBigEndian,
            bytesPerPixel: 4,
            colorType: 4,
            includeSRGB: true,
            bitDepth: 16,
            significantBits: [11, 15]
        )
        let linearGray = try makeRawGrayscaleFamily16PNG(
            width: width,
            height: height,
            samples: graySamples,
            colorType: 0,
            filters: [0, 1, 2],
            splitIDAT: 2,
            includeSRGB: true,
            transparentGray: transparentGray,
            significantBits: [12]
        )
        let linearGA = try makeRawGrayscaleFamily16PNG(
            width: width,
            height: height,
            samples: gaSamples,
            colorType: 4,
            filters: [4, 3, 2],
            splitIDAT: 2,
            includeSRGB: true,
            significantBits: [11, 15]
        )
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .preserveSource
        )
        let decoder = PNGIndependentRGBA16Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)

        let grayValue = try decoder.decode(data: adam7Gray, request: request, limits: .coreV1)
        let gaValue = try decoder.decode(data: adam7GA, request: request, limits: .coreV1)
        XCTAssertEqual(
            grayValue.data,
            grayscaleFamily16ToRGBA16LittleEndianTestData(
                graySamples,
                colorType: 0,
                transparentGray: transparentGray
            )
        )
        XCTAssertEqual(
            gaValue.data,
            grayscaleFamily16ToRGBA16LittleEndianTestData(gaSamples, colorType: 4)
        )
        XCTAssertEqual(grayValue.sourceSignificantBits?.channels, .grayscale(gray: 12))
        XCTAssertEqual(
            gaValue.sourceSignificantBits?.channels,
            .grayscaleAlpha(gray: 11, alpha: 15)
        )
        XCTAssertEqual(
            try decoder.resourceLedger(data: adam7Gray, request: request).bound(for: .operationPeak),
            try decoder.resourceLedger(data: linearGray, request: request).bound(for: .operationPeak)
        )
        XCTAssertEqual(
            try decoder.resourceLedger(data: adam7GA, request: request).bound(for: .operationPeak),
            try decoder.resourceLedger(data: linearGA, request: request).bound(for: .operationPeak)
        )
    }

    func testIndependentPNG16Adam7RGBAExactStraightLittleEndianAndResourceLedger() throws {
        let width = 13
        let height = 11
        var samples: [UInt16] = []
        samples.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                samples.append(UInt16((x * 7_919 + y * 1_213 + 0x1357) & 0xFFFF))
                samples.append(UInt16((x * 3_013 + y * 8_887 + 0x2468) & 0xFFFF))
                samples.append(UInt16((x * 5_987 + y * 4_033 + 0xACE1) & 0xFFFF))
                samples.append(UInt16((x * 1_997 + y * 6_013 + 0x0F0F) & 0xFFFF))
            }
        }
        let sourceBigEndian = rgba16BigEndianTestData(samples)
        let interlaced = try makeRawAdam7PNG(
            width: width,
            height: height,
            straightPixels: sourceBigEndian,
            bytesPerPixel: 8,
            colorType: 6,
            includeSRGB: true,
            bitDepth: 16
        )
        let noninterlaced = try makeRawRGBA16PNG(
            width: width,
            height: height,
            samples: samples,
            filters: [0, 1, 2, 3, 4],
            splitIDAT: 3,
            includeSRGB: true
        )
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .preserveSource
        )
        let decoder = PNGIndependentRGBA16Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)
        let value = try decoder.decode(data: interlaced, request: request, limits: .coreV1)
        XCTAssertEqual(value.data, rgba16LittleEndianTestData(samples))
        XCTAssertEqual(value.format, .rgba16StraightLittleEndian)
        XCTAssertNil(value.sourceSignificantBits)

        let interlacedLedger = try decoder.resourceLedger(
            data: interlaced,
            request: request,
            limits: .coreV1
        )
        let noninterlacedLedger = try decoder.resourceLedger(
            data: noninterlaced,
            request: request,
            limits: .coreV1
        )
        XCTAssertEqual(
            interlacedLedger.bound(for: .operationPeak),
            noninterlacedLedger.bound(for: .operationPeak)
        )
        XCTAssertEqual(
            interlacedLedger.bound(for: .transferredOutput),
            noninterlacedLedger.bound(for: .transferredOutput)
        )
        XCTAssertEqual(interlacedLedger.outputLayoutAuthority, .codecOwnedStraightRGBA16LE)
    }

    func testIndependentPNG16Adam7RGBTRNSUsesFullSamplesSixByteRowsAndMalformedPassFailsClosed() throws {
        let width = 9
        let height = 6
        let transparent = (red: UInt16(0x91B3), green: UInt16(0xA850), blue: UInt16(0xEF9A))
        var rgbSamples: [UInt16] = []
        var rgbaSamples: [UInt16] = []
        var rgbBigEndian = Data(capacity: width * height * 6)
        for index in 0..<(width * height) {
            let red: UInt16
            let green: UInt16
            let blue: UInt16
            if index == 0 {
                (red, green, blue) = transparent
            } else if index == 1 {
                // Same high bytes as the tRNS key, but one low bit differs. Interlace must not
                // accidentally reduce the comparison to eight bits.
                red = transparent.red ^ 0x0001
                green = transparent.green
                blue = transparent.blue
            } else {
                red = UInt16((index * 1_021 + 0x1111) & 0xFFFF)
                green = UInt16((index * 2_039 + 0x2222) & 0xFFFF)
                blue = UInt16((index * 3_061 + 0x3333) & 0xFFFF)
            }
            rgbSamples.append(contentsOf: [red, green, blue])
            rgbaSamples.append(contentsOf: [red, green, blue, index == 0 ? 0 : UInt16.max])
            for sample in [red, green, blue] {
                rgbBigEndian.append(UInt8(truncatingIfNeeded: sample >> 8))
                rgbBigEndian.append(UInt8(truncatingIfNeeded: sample))
            }
        }
        let rgbaBigEndian = rgba16BigEndianTestData(rgbaSamples)
        let interlacedRGB = try makeRawAdam7PNG(
            width: width,
            height: height,
            straightPixels: rgbBigEndian,
            bytesPerPixel: 6,
            colorType: 2,
            includeSRGB: true,
            bitDepth: 16,
            truecolorTransparency: transparent
        )
        let noninterlacedRGB = try makeRawRGB16PNG(
            width: width,
            height: height,
            samples: rgbSamples,
            filters: [0, 1, 2, 3, 4],
            splitIDAT: 3,
            includeSRGB: true,
            transparentRGB: transparent
        )
        let interlacedRGBA = try makeRawAdam7PNG(
            width: width,
            height: height,
            straightPixels: rgbaBigEndian,
            bytesPerPixel: 8,
            colorType: 6,
            includeSRGB: true,
            bitDepth: 16
        )
        let malformed = try makeRawAdam7PNG(
            width: width,
            height: height,
            straightPixels: rgbaBigEndian,
            bytesPerPixel: 8,
            colorType: 6,
            includeSRGB: true,
            bitDepth: 16,
            truncateInflatedTailByteCount: 1
        )
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .preserveSource
        )
        let decoder = PNGIndependentRGBA16Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)
        let value = try decoder.decode(data: interlacedRGB, request: request, limits: .coreV1)
        XCTAssertEqual(value.data, rgba16LittleEndianTestData(rgbaSamples))
        XCTAssertEqual(value.data[6], 0)
        XCTAssertEqual(value.data[7], 0)
        XCTAssertEqual(value.data[14], 0xFF)
        XCTAssertEqual(value.data[15], 0xFF)
        XCTAssertNil(value.sourceSignificantBits)

        let interlacedRGBLedger = try decoder.resourceLedger(
            data: interlacedRGB,
            request: request,
            limits: .coreV1
        )
        let noninterlacedRGBLedger = try decoder.resourceLedger(
            data: noninterlacedRGB,
            request: request,
            limits: .coreV1
        )
        XCTAssertEqual(
            interlacedRGBLedger.bound(for: .operationPeak),
            noninterlacedRGBLedger.bound(for: .operationPeak)
        )
        let interlacedRGBPeak = try XCTUnwrap(
            interlacedRGBLedger.bytesUpperBound(for: .operationPeak)
        )
        let interlacedRGBALedger = try decoder.resourceLedger(
            data: interlacedRGBA,
            request: request,
            limits: .coreV1
        )
        let interlacedRGBAPeak = try XCTUnwrap(
            interlacedRGBALedger.bytesUpperBound(for: .operationPeak)
        )
        XCTAssertEqual(interlacedRGBAPeak - interlacedRGBPeak, width * 4)

        XCTAssertThrowsError(try decoder.decode(data: malformed, request: request)) { error in
            XCTAssertEqual(error as? ImageCraftError, .unsupportedOrCorruptImage)
        }
    }

    func testIndependentPNG16CICPPreservesFullRangeSDRAndHDRRawSamplesWithoutResourceWidening() throws {
        let width = 5
        let height = 3
        var samples: [UInt16] = []
        for index in 0..<(width * height) {
            samples.append(UInt16((index * 7_919 + 0x1357) & 0xFFFF))
            samples.append(UInt16((index * 3_013 + 0x2468) & 0xFFFF))
            samples.append(UInt16((index * 5_987 + 0xACE1) & 0xFFFF))
            let alphaCycle: [UInt16] = [0, 1, 0x1234, 0x7FFF, 0x8000, 0xFFFE, 0xFFFF]
            samples.append(alphaCycle[index % alphaCycle.count])
        }
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .preserveSource
        )
        let decoder = PNGIndependentRGBA16Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)
        let srgb = try makeRawRGBA16PNG(
            width: width,
            height: height,
            samples: samples,
            filters: [0, 1, 2, 3, 4],
            splitIDAT: 3,
            includeSRGB: true,
            significantBits: [12, 13, 14, 15]
        )
        let srgbLedger = try decoder.resourceLedger(data: srgb, request: request, limits: .coreV1)
        let expected = rgba16LittleEndianTestData(samples)
        let qualified: [(UInt8, UInt8)] = [(0x0C, 0x0D), (0x09, 0x10), (0x09, 0x12)]

        for (primaries, transfer) in qualified {
            let cicpBytes: [UInt8] = [primaries, transfer, 0, 1]
            let png = try makeRawRGBA16PNG(
                width: width,
                height: height,
                samples: samples,
                filters: [0, 1, 2, 3, 4],
                splitIDAT: 3,
                includeSRGB: false,
                significantBits: [12, 13, 14, 15],
                cicp: cicpBytes
            )
            let value = try decoder.decode(data: png, request: request, limits: .coreV1)
            let cicp = try XCTUnwrap(
                ImagePackedCICPColorEncoding(
                    colorPrimaries: primaries,
                    transferFunction: transfer,
                    matrixCoefficients: 0,
                    videoFullRangeFlag: 1
                )
            )
            XCTAssertEqual(value.data, expected)
            XCTAssertEqual(value.colorEncoding, .cicp(cicp))
            XCTAssertEqual(value.sourceColorProfile, .unknown)
            XCTAssertEqual(
                value.sourceSignificantBits?.channels,
                .rgba(red: 12, green: 13, blue: 14, alpha: 15)
            )
            XCTAssertEqual(value.transferredByteCharge, expected.count)
            let ledger = try decoder.resourceLedger(data: png, request: request, limits: .coreV1)
            XCTAssertEqual(ledger.bound(for: .operationPeak), srgbLedger.bound(for: .operationPeak))
            XCTAssertEqual(ledger.bound(for: .transferredOutput), srgbLedger.bound(for: .transferredOutput))
        }

        // cICP has higher PNG color-authority precedence than iCCP. A lower-priority profile remains
        // container metadata only: it is not inflated, retained, charged in transfer, or allowed to
        // replace the structured cICP authority.
        let displayP3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let lowerPriorityICC = try XCTUnwrap(displayP3.copyICCData()).bridgeToData()
        var precedencePNG = try makeRawRGBA16PNG(
            width: width,
            height: height,
            samples: samples,
            filters: [0, 1, 2, 3, 4],
            splitIDAT: 3,
            includeSRGB: false,
            significantBits: [12, 13, 14, 15],
            cicp: [0x0C, 0x0D, 0, 1]
        )
        let cicpChunk = try XCTUnwrap(try pngTestChunks(precedencePNG).first { $0.type == "cICP" })
        var iccpPayload = Data("Lower Priority RGB".utf8)
        iccpPayload.append(0)
        iccpPayload.append(0)
        iccpPayload.append(try RFC1950Zlib.deflate(lowerPriorityICC))
        precedencePNG.insert(
            contentsOf: try makePNGTestChunk(type: "iCCP", payload: iccpPayload),
            at: cicpChunk.end
        )
        let precedenceValue = try decoder.decode(
            data: precedencePNG,
            request: request,
            limits: .coreV1
        )
        guard case .cicp(let precedenceCICP) = precedenceValue.colorEncoding else {
            return XCTFail("cICP must remain the highest-priority color authority")
        }
        XCTAssertEqual(precedenceCICP.colorPrimaries, 0x0C)
        XCTAssertEqual(precedenceCICP.transferFunction, 0x0D)
        XCTAssertEqual(precedenceValue.data, expected)
        XCTAssertEqual(precedenceValue.transferredByteCharge, expected.count)
        XCTAssertEqual(
            try decoder.resourceLedger(data: precedencePNG, request: request).bound(for: .operationPeak),
            srgbLedger.bound(for: .operationPeak)
        )
    }

    func testIndependentPNG16CICPAdam7RGBTRNSAndSBITPreserveExactSamples() throws {
        let width = 9
        let height = 6
        let transparent = (red: UInt16(0x91B3), green: UInt16(0xA850), blue: UInt16(0xEF9A))
        var rgbSamples: [UInt16] = []
        for index in 0..<(width * height) {
            if index == 0 {
                rgbSamples.append(contentsOf: [transparent.red, transparent.green, transparent.blue])
            } else if index == 1 {
                rgbSamples.append(contentsOf: [transparent.red ^ 0x0001, transparent.green, transparent.blue])
            } else {
                rgbSamples.append(UInt16((index * 1_021 + 0x1111) & 0xFFFF))
                rgbSamples.append(UInt16((index * 2_039 + 0x2222) & 0xFFFF))
                rgbSamples.append(UInt16((index * 3_061 + 0x3333) & 0xFFFF))
            }
        }
        let rgbBigEndian = uint16BigEndianTestData(rgbSamples)
        let expected = rgb16ToRGBA16LittleEndianTestData(rgbSamples, transparentRGB: transparent)
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .preserveSource
        )
        let decoder = PNGIndependentRGBA16Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)
        let srgbAdam7 = try makeRawAdam7PNG(
            width: width,
            height: height,
            straightPixels: rgbBigEndian,
            bytesPerPixel: 6,
            colorType: 2,
            includeSRGB: true,
            bitDepth: 16,
            significantBits: [11, 13, 15],
            truecolorTransparency: transparent
        )
        let srgbLedger = try decoder.resourceLedger(data: srgbAdam7, request: request, limits: .coreV1)

        for (primaries, transfer): (UInt8, UInt8) in [(0x0C, 0x0D), (0x09, 0x10), (0x09, 0x12)] {
            let png = try makeRawAdam7PNG(
                width: width,
                height: height,
                straightPixels: rgbBigEndian,
                bytesPerPixel: 6,
                colorType: 2,
                includeSRGB: false,
                bitDepth: 16,
                significantBits: [11, 13, 15],
                truecolorTransparency: transparent,
                cicp: [primaries, transfer, 0, 1]
            )
            let value = try decoder.decode(data: png, request: request, limits: .coreV1)
            XCTAssertEqual(value.data, expected)
            XCTAssertEqual(value.data[6], 0)
            XCTAssertEqual(value.data[7], 0)
            XCTAssertEqual(value.data[14], 0xFF)
            XCTAssertEqual(value.data[15], 0xFF)
            XCTAssertEqual(value.sourceSignificantBits?.channels, .rgb(red: 11, green: 13, blue: 15))
            guard case .cicp(let cicp) = value.colorEncoding else {
                return XCTFail("expected structured cICP color authority")
            }
            XCTAssertEqual(cicp.colorPrimaries, primaries)
            XCTAssertEqual(cicp.transferFunction, transfer)
            XCTAssertEqual(cicp.matrixCoefficients, 0)
            XCTAssertEqual(cicp.videoFullRangeFlag, 1)
            XCTAssertEqual(
                try decoder.resourceLedger(data: png, request: request).bound(for: .operationPeak),
                srgbLedger.bound(for: .operationPeak)
            )
        }
    }

    func testIndependentPNG16PQHDRStaticMetadataPreservesStoredIntegersAndLedger() throws {
        let width = 5
        let height = 4
        var samples: [UInt16] = []
        for index in 0..<(width * height) {
            samples.append(UInt16((index * 7_919 + 0x1357) & 0xFFFF))
            samples.append(UInt16((index * 3_013 + 0x2468) & 0xFFFF))
            samples.append(UInt16((index * 5_987 + 0xACE1) & 0xFFFF))
            let alphaCycle: [UInt16] = [0, 1, 0x1234, 0x7FFF, 0x8000, 0xFFFE, 0xFFFF]
            samples.append(alphaCycle[index % alphaCycle.count])
        }
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .preserveSource
        )
        let decoder = PNGIndependentRGBA16Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)
        let base = try makeRawRGBA16PNG(
            width: width,
            height: height,
            samples: samples,
            filters: [0, 1, 2, 3],
            splitIDAT: 3,
            includeSRGB: false,
            cicp: [0x09, 0x10, 0, 1]
        )
        let baselineLedger = try decoder.resourceLedger(data: base, request: request, limits: .coreV1)
        let expectedPixels = rgba16LittleEndianTestData(samples)

        var mdcvPayload = uint16BigEndianTestData([
            35_400, 14_600,
            8_500, 39_850,
            6_550, 2_300,
            15_635, 16_450,
        ])
        mdcvPayload.append(contentsOf: pngTestUInt32Bytes(40_000_000))
        mdcvPayload.append(contentsOf: pngTestUInt32Bytes(5))
        var clliPayload = Data()
        clliPayload.append(contentsOf: pngTestUInt32Bytes(10_000_000))
        clliPayload.append(contentsOf: pngTestUInt32Bytes(2_500_000))
        var zeroCLLIPayload = Data()
        zeroCLLIPayload.append(contentsOf: pngTestUInt32Bytes(0))
        zeroCLLIPayload.append(contentsOf: pngTestUInt32Bytes(0))

        let expectedMastering = try XCTUnwrap(
            ImagePackedMasteringDisplayColorVolume(
                redX: 35_400,
                redY: 14_600,
                greenX: 8_500,
                greenY: 39_850,
                blueX: 6_550,
                blueY: 2_300,
                whiteX: 15_635,
                whiteY: 16_450,
                maximumLuminanceScaledBy10000: 40_000_000,
                minimumLuminanceScaledBy10000: 5
            )
        )
        let expectedContent = try XCTUnwrap(
            ImagePackedContentLightLevel(
                maximumContentLightLevelScaledBy10000: 10_000_000,
                maximumFrameAverageLightLevelScaledBy10000: 2_500_000
            )
        )
        let expectedZeroContent = try XCTUnwrap(
            ImagePackedContentLightLevel(
                maximumContentLightLevelScaledBy10000: 0,
                maximumFrameAverageLightLevelScaledBy10000: 0
            )
        )

        func addingHDRMetadata(
            to png: Data,
            mdcv: Data?,
            clli: Data?
        ) throws -> Data {
            var result = png
            let cicpChunk = try XCTUnwrap(try pngTestChunks(result).first { $0.type == "cICP" })
            var chunks = Data()
            if let mdcv {
                chunks.append(try makePNGTestChunk(type: "mDCV", payload: mdcv))
            }
            if let clli {
                chunks.append(try makePNGTestChunk(type: "cLLI", payload: clli))
            }
            result.insert(contentsOf: chunks, at: cicpChunk.end)
            return result
        }

        let variants: [(Data?, Data?, ImagePackedMasteringDisplayColorVolume?, ImagePackedContentLightLevel?)] = [
            (mdcvPayload, nil, expectedMastering, nil),
            (nil, clliPayload, nil, expectedContent),
            (mdcvPayload, clliPayload, expectedMastering, expectedContent),
            (nil, zeroCLLIPayload, nil, expectedZeroContent),
        ]
        for (mdcv, clli, expectedMDCV, expectedCLLI) in variants {
            let png = try addingHDRMetadata(to: base, mdcv: mdcv, clli: clli)
            let value = try decoder.decode(data: png, request: request, limits: .coreV1)
            XCTAssertEqual(value.data, expectedPixels)
            guard case .cicp(let cicp) = value.colorEncoding else {
                return XCTFail("PQ HDR metadata must retain cICP color authority")
            }
            XCTAssertEqual(cicp.colorPrimaries, 9)
            XCTAssertEqual(cicp.transferFunction, 16)
            XCTAssertEqual(value.hdrStaticMetadata?.masteringDisplayColorVolume, expectedMDCV)
            XCTAssertEqual(value.hdrStaticMetadata?.contentLightLevel, expectedCLLI)
            XCTAssertEqual(value.transferredByteCharge, expectedPixels.count)
            let ledger = try decoder.resourceLedger(data: png, request: request, limits: .coreV1)
            XCTAssertEqual(ledger.bound(for: .operationPeak), baselineLedger.bound(for: .operationPeak))
            XCTAssertEqual(ledger.bound(for: .transferredOutput), baselineLedger.bound(for: .transferredOutput))
        }
    }

    func testIndependentPNG16DisplayP3ConvertToSRGBMatchesRegisteredCodesLinearAndAdam7() throws {
        let sourceRGB: [(UInt16, UInt16, UInt16)] = [
            (0, 0, 0),
            (0xFFFF, 0xFFFF, 0xFFFF),
            (32_768, 32_768, 32_768),
            (40_000, 30_000, 20_000),
            (50_000, 40_000, 30_000),
            (32_000, 30_000, 28_000),
            (25_000, 27_000, 26_000),
            (10_000, 12_000, 11_000),
            (56_000, 54_000, 52_000),
            (30_000, 40_000, 35_000),
        ]
        let expectedRGB: [(UInt16, UInt16, UInt16)] = [
            (0, 0, 0),
            (0xFFFF, 0xFFFF, 0xFFFF),
            (32_768, 32_768, 32_768),
            (41_845, 29_483, 18_226),
            (51_915, 39_506, 28_424),
            (32_429, 29_912, 27_749),
            (24_522, 27_080, 25_939),
            (9_490, 12_076, 10_936),
            (56_437, 53_914, 51_755),
            (27_090, 40_353, 34_658),
        ]
        let alphaCycle: [UInt16] = [0, 1, 0x1234, 0x7FFF, 0x8000, 0xFFFE, 0xFFFF]
        var sourceSamples: [UInt16] = []
        var expectedSamples: [UInt16] = []
        for index in sourceRGB.indices {
            sourceSamples.append(contentsOf: [
                sourceRGB[index].0,
                sourceRGB[index].1,
                sourceRGB[index].2,
                alphaCycle[index % alphaCycle.count],
            ])
            expectedSamples.append(contentsOf: [
                expectedRGB[index].0,
                expectedRGB[index].1,
                expectedRGB[index].2,
                alphaCycle[index % alphaCycle.count],
            ])
        }
        let width = 5
        let height = 2
        let preserve = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .preserveSource
        )
        let convert = ImageDecodeRequest(target: preserve.target, colorPolicy: .convertToSRGB)
        let decoder = PNGIndependentRGBA16Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)
        let linear = try makeRawRGBA16PNG(
            width: width,
            height: height,
            samples: sourceSamples,
            filters: [0, 1],
            splitIDAT: 3,
            includeSRGB: false,
            cicp: [0x0C, 0x0D, 0, 1]
        )
        let expected = rgba16LittleEndianTestData(expectedSamples)
        let linearValue = try decoder.decode(data: linear, request: convert, limits: .coreV1)
        XCTAssertEqual(linearValue.data, expected)
        XCTAssertEqual(linearValue.colorEncoding, .sRGB)
        XCTAssertEqual(linearValue.sourceColorProfile, .unknown)
        XCTAssertNil(linearValue.sourceSignificantBits)
        XCTAssertNil(linearValue.hdrStaticMetadata)
        XCTAssertEqual(linearValue.transferredByteCharge, expected.count)
        let preserveLedger = try decoder.resourceLedger(data: linear, request: preserve, limits: .coreV1)
        let convertLedger = try decoder.resourceLedger(data: linear, request: convert, limits: .coreV1)
        XCTAssertEqual(convertLedger.bound(for: .operationPeak), preserveLedger.bound(for: .operationPeak))
        XCTAssertEqual(convertLedger.bound(for: .transferredOutput), preserveLedger.bound(for: .transferredOutput))

        let adam7 = try makeRawAdam7PNG(
            width: width,
            height: height,
            straightPixels: uint16BigEndianTestData(sourceSamples),
            bytesPerPixel: 8,
            colorType: 6,
            includeSRGB: false,
            bitDepth: 16,
            cicp: [0x0C, 0x0D, 0, 1]
        )
        let adam7Value = try decoder.decode(data: adam7, request: convert, limits: .coreV1)
        XCTAssertEqual(adam7Value.data, expected)
        XCTAssertEqual(adam7Value.colorEncoding, .sRGB)
        XCTAssertEqual(
            try decoder.resourceLedger(data: adam7, request: convert).bound(for: .operationPeak),
            convertLedger.bound(for: .operationPeak)
        )
    }

    func testIndependentPNG16DisplayP3ConvertToSRGBComposesWithRGBTRNSBeforeTransform() throws {
        let width = 2
        let height = 1
        let transparent = (red: UInt16(40_000), green: UInt16(30_000), blue: UInt16(20_000))
        let sourceSamples: [UInt16] = [
            transparent.red, transparent.green, transparent.blue,
            40_001, 30_000, 20_000,
        ]
        let png = try makeRawRGB16PNG(
            width: width,
            height: height,
            samples: sourceSamples,
            filters: [0],
            splitIDAT: 2,
            includeSRGB: false,
            transparentRGB: transparent,
            cicp: [0x0C, 0x0D, 0, 1]
        )
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .convertToSRGB
        )
        let value = try PNGIndependentRGBA16Decoder(
            maximumOperationByteCharge: 64 * 1024 * 1024
        ).decode(data: png, request: request, limits: .coreV1)
        XCTAssertEqual(
            value.data,
            rgba16LittleEndianTestData([
                41_845, 29_483, 18_226, 0,
                41_846, 29_483, 18_226, 0xFFFF,
            ])
        )
        XCTAssertEqual(value.colorEncoding, .sRGB)
    }

    func testIndependentPNG16CICPRejectsUnqualifiedRangeTupleSourceAndHDRMetadata() throws {
        let width = 3
        let height = 2
        var samples: [UInt16] = []
        for index in 0..<(width * height) {
            samples.append(contentsOf: [
                UInt16((index * 1_013 + 0x1234) & 0xFFFF),
                UInt16((index * 2_017 + 0x4567) & 0xFFFF),
                UInt16((index * 3_019 + 0x89AB) & 0xFFFF),
                UInt16((index * 4_021 + 0xCDEF) & 0xFFFF),
            ])
        }
        let preserve = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .preserveSource
        )
        let convert = ImageDecodeRequest(target: preserve.target, colorPolicy: .convertToSRGB)
        let decoder = PNGIndependentRGBA16Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)

        let displayP3 = try makeRawRGBA16PNG(
            width: width,
            height: height,
            samples: samples,
            filters: [0, 1],
            splitIDAT: 2,
            includeSRGB: false,
            cicp: [0x0C, 0x0D, 0, 1]
        )
        var outOfGamutSamples: [UInt16] = []
        for _ in 0..<(width * height) {
            outOfGamutSamples.append(contentsOf: [0xFFFF, 0, 0, 0xFFFF])
        }
        let outOfGamutP3 = try makeRawRGBA16PNG(
            width: width,
            height: height,
            samples: outOfGamutSamples,
            filters: [0, 1],
            splitIDAT: 2,
            includeSRGB: false,
            cicp: [0x0C, 0x0D, 0, 1]
        )
        XCTAssertThrowsError(try decoder.decode(data: outOfGamutP3, request: convert, limits: .coreV1)) {
            XCTAssertEqual($0 as? PNGIndependentRGBA16Error, .targetColorGamutExceeded)
        }

        for unqualified: [UInt8] in [
            [0x0C, 0x0D, 0, 0],  // narrow-range Display-P3
            [0x02, 0x02, 0, 1],  // structurally valid but unqualified H.273 tuple
        ] {
            let png = try makeRawRGBA16PNG(
                width: width,
                height: height,
                samples: samples,
                filters: [0, 1],
                splitIDAT: 2,
                includeSRGB: false,
                cicp: unqualified
            )
            XCTAssertThrowsError(try decoder.decode(data: png, request: preserve, limits: .coreV1)) {
                XCTAssertEqual($0 as? PNGIndependentRGBA16Error, .unsupportedSourceSemantics)
            }
        }

        let invalidMatrix = try makeRawRGBA16PNG(
            width: width,
            height: height,
            samples: samples,
            filters: [0, 1],
            splitIDAT: 2,
            includeSRGB: false,
            cicp: [0x0C, 0x0D, 1, 1]
        )
        XCTAssertThrowsError(try decoder.decode(data: invalidMatrix, request: preserve, limits: .coreV1)) {
            XCTAssertEqual($0 as? ImageCraftError, .unsupportedOrCorruptImage)
        }

        let cicpChunk = try XCTUnwrap(try pngTestChunks(displayP3).first { $0.type == "cICP" })
        for hdrChunk in [
            try makePNGTestChunk(type: "mDCV", payload: Data(repeating: 0, count: 24)),
            try makePNGTestChunk(type: "cLLI", payload: Data(repeating: 0, count: 8)),
        ] {
            var withHDRMetadata = displayP3
            withHDRMetadata.insert(contentsOf: hdrChunk, at: cicpChunk.end)
            XCTAssertThrowsError(
                try decoder.decode(data: withHDRMetadata, request: preserve, limits: .coreV1)
            ) {
                XCTAssertEqual($0 as? PNGIndependentRGBA16Error, .unsupportedSourceSemantics)
            }

            let hlg = try makeRawRGBA16PNG(
                width: width,
                height: height,
                samples: samples,
                filters: [0, 1],
                splitIDAT: 2,
                includeSRGB: false,
                cicp: [0x09, 0x12, 0, 1]
            )
            let hlgCICP = try XCTUnwrap(try pngTestChunks(hlg).first { $0.type == "cICP" })
            var hlgWithHDRMetadata = hlg
            hlgWithHDRMetadata.insert(contentsOf: hdrChunk, at: hlgCICP.end)
            XCTAssertThrowsError(
                try decoder.decode(data: hlgWithHDRMetadata, request: preserve, limits: .coreV1)
            ) {
                XCTAssertEqual($0 as? PNGIndependentRGBA16Error, .unsupportedSourceSemantics)
            }
        }

        var invalidMDCV = Data(repeating: 0, count: 24)
        invalidMDCV[16] = 0x80
        var invalidCLLI = Data(repeating: 0, count: 8)
        invalidCLLI[0] = 0x80
        for invalidChunk in [
            try makePNGTestChunk(type: "mDCV", payload: invalidMDCV),
            try makePNGTestChunk(type: "cLLI", payload: invalidCLLI),
        ] {
            var malformed = displayP3
            malformed.insert(contentsOf: invalidChunk, at: cicpChunk.end)
            XCTAssertThrowsError(try decoder.decode(data: malformed, request: preserve, limits: .coreV1)) {
                XCTAssertEqual($0 as? ImageCraftError, .unsupportedOrCorruptImage)
            }
        }

        let srgb = try makeRawRGBA16PNG(
            width: width,
            height: height,
            samples: samples,
            filters: [0, 1],
            splitIDAT: 2,
            includeSRGB: true
        )
        let srgbChunk = try XCTUnwrap(try pngTestChunks(srgb).first { $0.type == "sRGB" })
        var mdcvWithoutCICP = srgb
        mdcvWithoutCICP.insert(
            contentsOf: try makePNGTestChunk(type: "mDCV", payload: Data(repeating: 0, count: 24)),
            at: srgbChunk.end
        )
        XCTAssertThrowsError(
            try decoder.decode(data: mdcvWithoutCICP, request: preserve, limits: .coreV1)
        ) {
            XCTAssertEqual($0 as? ImageCraftError, .unsupportedOrCorruptImage)
        }
    }

    func testIndependentPNG16RGBAExactStraightLittleEndianAndResourceLedger() throws {
        let width = 7
        let height = 5
        var samples: [UInt16] = []
        samples.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                samples.append(UInt16((x * 8_111 + y * 1_237 + 0x1234) & 0xFFFF))
                samples.append(UInt16((x * 2_911 + y * 9_191 + 0xABCD) & 0xFFFF))
                samples.append(UInt16((x * 6_173 + y * 4_021 + 0x00FF) & 0xFFFF))
                let alphaCycle: [UInt16] = [0, 1, 0x0100, 0x7FFF, 0x8000, 0xFFFE, 0xFFFF]
                samples.append(alphaCycle[(x + y * 2) % alphaCycle.count])
            }
        }
        let png = try makeRawRGBA16PNG(
            width: width,
            height: height,
            samples: samples,
            filters: [0, 1, 2, 3, 4],
            splitIDAT: 3,
            includeSRGB: true
        )
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .preserveSource
        )
        let decoder = PNGIndependentRGBA16Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)
        let value = try decoder.decode(data: png, request: request, limits: .coreV1)
        let expected = rgba16LittleEndianTestData(samples)
        XCTAssertEqual(value.data, expected)
        XCTAssertEqual(value.format, .rgba16StraightLittleEndian)
        XCTAssertEqual(value.bytesPerRow, width * 8)
        XCTAssertEqual(value.pixelByteCharge, width * height * 8)
        XCTAssertEqual(value.sourceColorProfile, .standardSRGB)
        XCTAssertEqual(value.colorEncoding, .sRGB)

        // The second pixel has alpha=1. Exact source RGB survives; a premultiplied representation
        // would collapse almost all of these channel values.
        XCTAssertEqual(value.data[8..<16], expected[8..<16])
        XCTAssertNotEqual(value.data[8], 0)

        let ledger = try decoder.resourceLedger(data: png, request: request, limits: .coreV1)
        XCTAssertEqual(ledger.outputLayoutAuthority, .codecOwnedStraightRGBA16LE)
        XCTAssertEqual(
            ledger.bytesUpperBound(for: .transferredOutput),
            width * height * 8
        )
        let operationCharge = try XCTUnwrap(ledger.bytesUpperBound(for: .operationPeak))
        XCTAssertGreaterThan(operationCharge, width * height * 8)
        let tooSmall = PNGIndependentRGBA16Decoder(
            maximumOperationByteCharge: operationCharge - 1
        )
        XCTAssertThrowsError(try tooSmall.decode(data: png, request: request)) { error in
            XCTAssertEqual(error as? PNGIndependentRGBA16Error, .operationBudgetExceeded)
        }
    }

    func testIndependentPNG16RGBTRNSUsesFullSamplesAndSixByteSourceRows() throws {
        let width = 7
        let height = 5
        var rgbSamples = [UInt16](repeating: 0, count: width * height * 3)
        for pixel in 0..<(width * height) {
            rgbSamples[pixel * 3] = UInt16((pixel * 8_111 + 0x1234) & 0xFFFF)
            rgbSamples[pixel * 3 + 1] = UInt16((pixel * 2_911 + 0xABCD) & 0xFFFF)
            rgbSamples[pixel * 3 + 2] = UInt16((pixel * 6_173 + 0x00FF) & 0xFFFF)
        }
        let transparent = (red: UInt16(0x12FF), green: UInt16(0xABCD), blue: UInt16(0x00FE))
        rgbSamples[0] = transparent.red
        rgbSamples[1] = transparent.green
        rgbSamples[2] = transparent.blue
        // Same high bytes as the tRNS key but a different low red byte. A decoder that truncates to
        // 8 bits before comparing transparency would incorrectly clear this pixel's alpha.
        rgbSamples[3] = 0x12FE
        rgbSamples[4] = transparent.green
        rgbSamples[5] = transparent.blue

        let png = try makeRawRGB16PNG(
            width: width,
            height: height,
            samples: rgbSamples,
            filters: [0, 1, 2, 3, 4],
            splitIDAT: 4,
            includeSRGB: true,
            transparentRGB: transparent
        )
        let opaquePNG = try makeRawRGB16PNG(
            width: width,
            height: height,
            samples: rgbSamples,
            filters: [4, 3, 2, 1, 0],
            splitIDAT: 2,
            includeSRGB: true
        )
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .preserveSource
        )
        let decoder = PNGIndependentRGBA16Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)

        let transparentValue = try decoder.decode(data: png, request: request, limits: .coreV1)
        XCTAssertEqual(
            transparentValue.data,
            rgb16ToRGBA16LittleEndianTestData(rgbSamples, transparentRGB: transparent)
        )
        XCTAssertEqual(transparentValue.data[6], 0)
        XCTAssertEqual(transparentValue.data[7], 0)
        XCTAssertEqual(transparentValue.data[14], 0xFF)
        XCTAssertEqual(transparentValue.data[15], 0xFF)

        let opaqueValue = try decoder.decode(data: opaquePNG, request: request, limits: .coreV1)
        XCTAssertEqual(
            opaqueValue.data,
            rgb16ToRGBA16LittleEndianTestData(rgbSamples, transparentRGB: nil)
        )
        for pixel in 0..<(width * height) {
            XCTAssertEqual(opaqueValue.data[pixel * 8 + 6], 0xFF)
            XCTAssertEqual(opaqueValue.data[pixel * 8 + 7], 0xFF)
        }

        let rgbLedger = try decoder.resourceLedger(data: png, request: request, limits: .coreV1)
        var rgbaSamples: [UInt16] = []
        rgbaSamples.reserveCapacity(width * height * 4)
        for pixel in 0..<(width * height) {
            rgbaSamples.append(rgbSamples[pixel * 3])
            rgbaSamples.append(rgbSamples[pixel * 3 + 1])
            rgbaSamples.append(rgbSamples[pixel * 3 + 2])
            rgbaSamples.append(UInt16.max)
        }
        let rgbaPNG = try makeRawRGBA16PNG(
            width: width,
            height: height,
            samples: rgbaSamples,
            filters: [0],
            splitIDAT: 1,
            includeSRGB: true
        )
        let rgbaLedger = try decoder.resourceLedger(data: rgbaPNG, request: request, limits: .coreV1)
        let rgbOperation = try XCTUnwrap(rgbLedger.bytesUpperBound(for: .operationPeak))
        let rgbaOperation = try XCTUnwrap(rgbaLedger.bytesUpperBound(for: .operationPeak))
        XCTAssertEqual(rgbaOperation - rgbOperation, width * 4)
        XCTAssertEqual(
            rgbLedger.bytesUpperBound(for: .transferredOutput),
            rgbaLedger.bytesUpperBound(for: .transferredOutput)
        )
        XCTAssertEqual(rgbLedger.outputLayoutAuthority, .codecOwnedStraightRGBA16LE)
    }

    func testIndependentPNG16SBITPreservesStoredSamplesAndPublishesSourcePrecision() throws {
        let width = 3
        let height = 2
        var rgbaSamples: [UInt16] = [
            0x123F, 0xABCD, 0x00FF, 0x8001,
            0x4567, 0x89AB, 0xCDEF, 0x7FFF,
            0xFFFF, 0x0001, 0x1357, 0x2469,
        ]
        rgbaSamples.append(contentsOf: rgbaSamples)
        let rgbaSignificantBits: [UInt8] = [12, 13, 14, 15]
        let rgbaPNG = try makeRawRGBA16PNG(
            width: width,
            height: height,
            samples: rgbaSamples,
            filters: [4, 2],
            splitIDAT: 3,
            includeSRGB: true,
            significantBits: rgbaSignificantBits
        )
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .preserveSource
        )
        let decoder = PNGIndependentRGBA16Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)
        let rgbaValue = try decoder.decode(data: rgbaPNG, request: request, limits: .coreV1)
        XCTAssertEqual(rgbaValue.data, rgba16LittleEndianTestData(rgbaSamples))
        let rgbaMetadata = try XCTUnwrap(rgbaValue.sourceSignificantBits)
        XCTAssertEqual(rgbaMetadata.sampleBitDepth, 16)
        XCTAssertEqual(rgbaMetadata.red, 12)
        XCTAssertEqual(rgbaMetadata.green, 13)
        XCTAssertEqual(rgbaMetadata.blue, 14)
        XCTAssertEqual(rgbaMetadata.alpha, 15)
        XCTAssertTrue(rgbaMetadata.sourceHasStoredAlpha)
        XCTAssertEqual(rgbaSamples[0] >> 4, 0x0123)
        XCTAssertEqual(rgbaSamples[1] >> 3, 0x1579)
        XCTAssertEqual(rgbaSamples[2] >> 2, 0x003F)
        XCTAssertEqual(rgbaSamples[3] >> 1, 0x4000)
        XCTAssertNotEqual(rgbaSamples[0] & 0x000F, 0)
        XCTAssertNotEqual(rgbaSamples[1] & 0x0007, 0)
        XCTAssertNotEqual(rgbaSamples[2] & 0x0003, 0)
        XCTAssertNotEqual(rgbaSamples[3] & 0x0001, 0)

        var rgbSamples: [UInt16] = [
            0xFEDB, 0x7655, 0x3213,
            0x1111, 0x2222, 0x3333,
            0x4444, 0x5555, 0x6666,
        ]
        rgbSamples.append(contentsOf: rgbSamples)
        let rgbSignificantBits: [UInt8] = [10, 12, 14]
        let rgbPNG = try makeRawRGB16PNG(
            width: width,
            height: height,
            samples: rgbSamples,
            filters: [1, 3],
            splitIDAT: 2,
            includeSRGB: true,
            significantBits: rgbSignificantBits
        )
        let rgbValue = try decoder.decode(data: rgbPNG, request: request, limits: .coreV1)
        XCTAssertEqual(
            rgbValue.data,
            rgb16ToRGBA16LittleEndianTestData(rgbSamples, transparentRGB: nil)
        )
        let rgbMetadata = try XCTUnwrap(rgbValue.sourceSignificantBits)
        XCTAssertEqual(rgbMetadata.sampleBitDepth, 16)
        XCTAssertEqual(rgbMetadata.red, 10)
        XCTAssertEqual(rgbMetadata.green, 12)
        XCTAssertEqual(rgbMetadata.blue, 14)
        XCTAssertNil(rgbMetadata.alpha)
        XCTAssertFalse(rgbMetadata.sourceHasStoredAlpha)
        XCTAssertNotEqual(rgbSamples[0] & 0x003F, 0)
        XCTAssertNotEqual(rgbSamples[1] & 0x000F, 0)
        XCTAssertNotEqual(rgbSamples[2] & 0x0003, 0)
    }

    func testIndependentPNG16Adam7SBITPreservesStoredSamplesAndSourcePrecision() throws {
        let width = 3
        let height = 2
        var rgbaSamples: [UInt16] = [
            0x123F, 0xABCD, 0x00FF, 0x8001,
            0x4567, 0x89AB, 0xCDEF, 0x7FFF,
            0xFFFF, 0x0001, 0x1357, 0x2469,
        ]
        rgbaSamples.append(contentsOf: rgbaSamples)
        let rgbaBigEndian = rgba16BigEndianTestData(rgbaSamples)
        let rgbaSBIT: [UInt8] = [12, 13, 14, 15]
        let rgbaPNG = try makeRawAdam7PNG(
            width: width,
            height: height,
            straightPixels: rgbaBigEndian,
            bytesPerPixel: 8,
            colorType: 6,
            includeSRGB: true,
            bitDepth: 16,
            significantBits: rgbaSBIT
        )
        let rgbaWithoutSBIT = try makeRawAdam7PNG(
            width: width,
            height: height,
            straightPixels: rgbaBigEndian,
            bytesPerPixel: 8,
            colorType: 6,
            includeSRGB: true,
            bitDepth: 16
        )

        var rgbSamples: [UInt16] = [
            0xFEDB, 0x7655, 0x3213,
            0x1111, 0x2222, 0x3333,
            0x4444, 0x5555, 0x6666,
        ]
        rgbSamples.append(contentsOf: rgbSamples)
        let transparent = (red: rgbSamples[0], green: rgbSamples[1], blue: rgbSamples[2])
        var rgbBigEndian = Data(capacity: rgbSamples.count * 2)
        for sample in rgbSamples {
            rgbBigEndian.append(UInt8(truncatingIfNeeded: sample >> 8))
            rgbBigEndian.append(UInt8(truncatingIfNeeded: sample))
        }
        let rgbSBIT: [UInt8] = [10, 12, 14]
        let rgbPNG = try makeRawAdam7PNG(
            width: width,
            height: height,
            straightPixels: rgbBigEndian,
            bytesPerPixel: 6,
            colorType: 2,
            includeSRGB: true,
            bitDepth: 16,
            significantBits: rgbSBIT,
            truecolorTransparency: transparent
        )
        let rgbWithoutSBIT = try makeRawAdam7PNG(
            width: width,
            height: height,
            straightPixels: rgbBigEndian,
            bytesPerPixel: 6,
            colorType: 2,
            includeSRGB: true,
            bitDepth: 16,
            truecolorTransparency: transparent
        )

        let request = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .preserveSource
        )
        let decoder = PNGIndependentRGBA16Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)

        let rgbaValue = try decoder.decode(data: rgbaPNG, request: request, limits: .coreV1)
        XCTAssertEqual(rgbaValue.data, rgba16LittleEndianTestData(rgbaSamples))
        let rgbaMetadata = try XCTUnwrap(rgbaValue.sourceSignificantBits)
        XCTAssertEqual(rgbaMetadata.red, 12)
        XCTAssertEqual(rgbaMetadata.green, 13)
        XCTAssertEqual(rgbaMetadata.blue, 14)
        XCTAssertEqual(rgbaMetadata.alpha, 15)
        XCTAssertTrue(rgbaMetadata.sourceHasStoredAlpha)
        XCTAssertEqual(
            try decoder.resourceLedger(data: rgbaPNG, request: request).bound(for: .operationPeak),
            try decoder.resourceLedger(data: rgbaWithoutSBIT, request: request).bound(for: .operationPeak)
        )

        let rgbValue = try decoder.decode(data: rgbPNG, request: request, limits: .coreV1)
        XCTAssertEqual(
            rgbValue.data,
            rgb16ToRGBA16LittleEndianTestData(rgbSamples, transparentRGB: transparent)
        )
        let rgbMetadata = try XCTUnwrap(rgbValue.sourceSignificantBits)
        XCTAssertEqual(rgbMetadata.red, 10)
        XCTAssertEqual(rgbMetadata.green, 12)
        XCTAssertEqual(rgbMetadata.blue, 14)
        XCTAssertNil(rgbMetadata.alpha)
        XCTAssertFalse(rgbMetadata.sourceHasStoredAlpha)
        XCTAssertEqual(rgbValue.data[6], 0)
        XCTAssertEqual(rgbValue.data[7], 0)
        XCTAssertEqual(
            try decoder.resourceLedger(data: rgbPNG, request: request).bound(for: .operationPeak),
            try decoder.resourceLedger(data: rgbWithoutSBIT, request: request).bound(for: .operationPeak)
        )
    }

    func testIndependentPNG16FailsClosedOutsideQualifiedSlice() throws {
        let width = 3
        let height = 2
        let samples: [UInt16] = (0..<(width * height)).flatMap { index -> [UInt16] in
            [
                UInt16((index * 101 + 0x1111) & 0xFFFF),
                UInt16((index * 211 + 0x2222) & 0xFFFF),
                UInt16((index * 307 + 0x3333) & 0xFFFF),
                UInt16((index * 401 + 0x4444) & 0xFFFF),
            ]
        }
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .preserveSource
        )
        let decoder = PNGIndependentRGBA16Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)

        let untagged = try makeRawRGBA16PNG(
            width: width,
            height: height,
            samples: samples,
            filters: [4, 2],
            splitIDAT: 2,
            includeSRGB: false
        )
        XCTAssertThrowsError(try decoder.decode(data: untagged, request: request)) { error in
            XCTAssertEqual(error as? PNGIndependentRGBA16Error, .unsupportedSourceSemantics)
        }

        // This fixture deliberately flips only IHDR.interlace while leaving the IDAT payload in
        // non-interlaced row order. Now that RGBA16 Adam7 itself is qualified, the safety property is
        // that declaration/payload mismatch fails as corrupt rather than being mistaken for Adam7.
        let malformedAdam7Payload = try makeRawRGBA16PNG(
            width: width,
            height: height,
            samples: samples,
            filters: [0],
            splitIDAT: 1,
            includeSRGB: true,
            interlace: 1
        )
        XCTAssertThrowsError(try decoder.decode(data: malformedAdam7Payload, request: request)) { error in
            XCTAssertEqual(error as? ImageCraftError, .unsupportedOrCorruptImage)
        }

        let truncated = try makeRawRGBA16PNG(
            width: width,
            height: height,
            samples: samples,
            filters: [1, 3],
            splitIDAT: 1,
            includeSRGB: true,
            truncateFilteredTailByteCount: 1
        )
        XCTAssertThrowsError(try decoder.decode(data: truncated, request: request)) { error in
            XCTAssertEqual(error as? ImageCraftError, .unsupportedOrCorruptImage)
        }

        var malformedSignificantBits = try makeRawRGBA16PNG(
            width: width,
            height: height,
            samples: samples,
            filters: [2, 4],
            splitIDAT: 2,
            includeSRGB: true,
            significantBits: [12, 13, 14, 15]
        )
        let sbit = try XCTUnwrap(
            try pngTestChunks(malformedSignificantBits).first(where: { $0.type == "sBIT" })
        )
        malformedSignificantBits[sbit.payloadStart] = 0
        try rewritePNGTestChunkCRC(&malformedSignificantBits, chunk: sbit)
        XCTAssertThrowsError(try decoder.decode(data: malformedSignificantBits, request: request)) { error in
            XCTAssertEqual(error as? ImageCraftError, .unsupportedOrCorruptImage)
        }

        let rgba8 = try makeRawRGBA8PNG(
            width: width,
            height: height,
            straightRGBA: Data(repeating: 127, count: width * height * 4),
            includeSRGB: true
        )
        XCTAssertThrowsError(try decoder.decode(data: rgba8, request: request)) { error in
            XCTAssertEqual(error as? PNGIndependentRGBA16Error, .unsupportedSourceSemantics)
        }
    }

    func testIndependentPNGAdvertisesOnlyBoundedPackedRGBA8Capability() throws {
        let capability = ImageDecodeCapabilityRequest(
            format: .png,
            deliveryMode: .completeFrame,
            trackMode: .primaryFrame,
            requiredMetadata: [.sourceColorProfile],
            dynamicRange: .standard,
            outputRepresentation: .packedRGBA8,
            cancellationMode: .operationBoundary
        )
        XCTAssertTrue(PNGIndependentRGBA8Decoder.codecDescriptor.supports(capability))
        XCTAssertEqual(
            PNGIndependentRGBA8Decoder.codecDescriptor.capabilities.outputRepresentations,
            [.packedRGBA8]
        )
        XCTAssertFalse(ImageIOImageDecoder().codecDescriptor.supports(capability))

        let width = 3
        let height = 2
        let data = try makeRawRGBA8PNG(
            width: width,
            height: height,
            straightRGBA: Data(repeating: 127, count: width * height * 4),
            includeSRGB: true
        )
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .preserveSource
        )
        let decoder = PNGIndependentRGBA8Decoder(maximumOperationByteCharge: 1 << 20)
        let ledger = try decoder.resourceLedger(data: data, request: request, limits: .coreV1)
        XCTAssertEqual(ledger.retainedBetweenCalls, .bounded(0))
        XCTAssertEqual(ledger.outputLayoutAuthority, .codecOwnedRGBA8)
        XCTAssertEqual(ledger.transferredOutput, .bounded(width * height * 4))
        guard case .bounded(let operationPeak) = ledger.operationPeak else {
            return XCTFail("independent PNG packed path must publish a hard operation bound")
        }
        XCTAssertGreaterThanOrEqual(operationPeak, width * height * 4)
    }

    func testIndependentPNGTruecolorSuggestedPaletteDoesNotChangePackedValueOrResourceLedger() throws {
        let width = 11
        let height = 7
        var straightRGB = Data(capacity: width * height * 3)
        var straightRGBA = Data(capacity: width * height * 4)
        for index in 0..<(width * height) {
            let red = UInt8((index * 37 + 11) & 0xFF)
            let green = UInt8((index * 53 + 29) & 0xFF)
            let blue = UInt8((index * 71 + 47) & 0xFF)
            let alpha = UInt8((index * 89 + 17) & 0xFF)
            straightRGB.append(contentsOf: [red, green, blue])
            straightRGBA.append(contentsOf: [red, green, blue, alpha])
        }
        let fixtures = [
            try makeRawRGB8PNG(
                width: width,
                height: height,
                straightRGB: straightRGB,
                includeSRGB: true
            ),
            try makeRawRGBA8PNG(
                width: width,
                height: height,
                straightRGBA: straightRGBA,
                includeSRGB: true
            ),
        ]
        let palettes = [
            Data([0, 0, 0, 255, 255, 255]),
            Data([190, 80, 30, 1, 2, 3, 255, 0, 128]),
        ]
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .preserveSource
        )
        let decoder = PNGIndependentRGBA8Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)

        for base in fixtures {
            let expected = try decoder.decode(data: base, request: request, limits: .coreV1)
            let expectedLedger = try decoder.resourceLedger(
                data: base,
                request: request,
                limits: .coreV1
            )
            for palette in palettes {
                let idat = try XCTUnwrap(try pngTestChunks(base).first { $0.type == "IDAT" })
                var candidate = base
                candidate.insert(
                    contentsOf: try makePNGTestChunk(type: "PLTE", payload: palette),
                    at: idat.start
                )
                let actual = try decoder.decode(
                    data: candidate,
                    request: request,
                    limits: .coreV1
                )
                let actualLedger = try decoder.resourceLedger(
                    data: candidate,
                    request: request,
                    limits: .coreV1
                )
                XCTAssertEqual(actual, expected)
                XCTAssertEqual(actualLedger.operationPeak, expectedLedger.operationPeak)
                XCTAssertEqual(actualLedger.transferredOutput, expectedLedger.transferredOutput)
                XCTAssertEqual(actualLedger.outputLayoutAuthority, expectedLedger.outputLayoutAuthority)

                var histogram = Data()
                for entry in 0..<(palette.count / 3) {
                    histogram.append(contentsOf: [0, UInt8(entry + 1)])
                }
                let candidateIDAT = try XCTUnwrap(
                    try pngTestChunks(candidate).first { $0.type == "IDAT" }
                )
                var withHistogram = candidate
                withHistogram.insert(
                    contentsOf: try makePNGTestChunk(type: "hIST", payload: histogram),
                    at: candidateIDAT.start
                )
                let histogramActual = try decoder.decode(
                    data: withHistogram,
                    request: request,
                    limits: .coreV1
                )
                let histogramLedger = try decoder.resourceLedger(
                    data: withHistogram,
                    request: request,
                    limits: .coreV1
                )
                XCTAssertEqual(histogramActual, expected)
                XCTAssertEqual(histogramLedger.operationPeak, expectedLedger.operationPeak)
                XCTAssertEqual(histogramLedger.transferredOutput, expectedLedger.transferredOutput)
                XCTAssertEqual(
                    histogramLedger.outputLayoutAuthority,
                    expectedLedger.outputLayoutAuthority
                )
            }
        }
    }

    func testIndependentPNGRGB8TRNSMasksHighBitsAndPublishesBinaryAlphaExactly() throws {
        let width = 4
        let height = 2
        let transparent = (red: UInt8(11), green: UInt8(53), blue: UInt8(101))
        var straightRGB = Data()
        for pixel in [
            (transparent.red, transparent.green, transparent.blue),
            (UInt8(9), UInt8(8), UInt8(7)),
            (transparent.red, transparent.green, transparent.blue),
            (UInt8(201), UInt8(17), UInt8(99)),
            (UInt8(1), UInt8(2), UInt8(3)),
            (transparent.red, transparent.green, transparent.blue),
            (UInt8(254), UInt8(128), UInt8(64)),
            (UInt8(0), UInt8(255), UInt8(32)),
        ] {
            straightRGB.append(contentsOf: [pixel.0, pixel.1, pixel.2])
        }
        let base = try makeRawRGB8PNG(
            width: width,
            height: height,
            straightRGB: straightRGB,
            includeSRGB: true
        )
        let idat = try XCTUnwrap(try pngTestChunks(base).first { $0.type == "IDAT" })
        // PNG requires decoders to mask unused high bits when bit depth is below 16. Deliberately
        // set those high bytes non-zero while preserving the low-byte transparent RGB triplet.
        let trnsPayload = Data([0xAB, 11, 0xCD, 53, 0xEF, 101])
        var data = base
        data.insert(
            contentsOf: try makePNGTestChunk(type: "tRNS", payload: trnsPayload),
            at: idat.start
        )

        let request = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .preserveSource
        )
        let decoder = PNGIndependentRGBA8Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)
        let actual = try decoder.decode(data: data, request: request, limits: .coreV1)
        let expected = try ImageIOImageDecoder().decodePackedRGBA8(
            data: data,
            request: request,
            limits: .coreV1
        )
        XCTAssertEqual(actual, expected)

        for index in 0..<(width * height) {
            let sourceOffset = index * 3
            let outputOffset = index * 4
            let matches = straightRGB[sourceOffset] == transparent.red
                && straightRGB[sourceOffset + 1] == transparent.green
                && straightRGB[sourceOffset + 2] == transparent.blue
            if matches {
                XCTAssertEqual(actual.data[outputOffset..<(outputOffset + 4)], Data([0, 0, 0, 0]))
            } else {
                XCTAssertEqual(actual.data[outputOffset], straightRGB[sourceOffset])
                XCTAssertEqual(actual.data[outputOffset + 1], straightRGB[sourceOffset + 1])
                XCTAssertEqual(actual.data[outputOffset + 2], straightRGB[sourceOffset + 2])
                XCTAssertEqual(actual.data[outputOffset + 3], 255)
            }
        }
        XCTAssertEqual(
            try decoder.resourceLedger(data: data, request: request, limits: .coreV1).operationPeak,
            try decoder.resourceLedger(data: base, request: request, limits: .coreV1).operationPeak
        )
    }

    func testIndependentPNGIndexed8BorrowsFullPaletteAndShortAlphaTableWithoutOperationCopyCharge() throws {
        let width = 16
        let height = 16
        var indices = Data(capacity: width * height)
        var palette = Data(capacity: 256 * 3)
        for value in 0..<256 {
            indices.append(UInt8(value))
            palette.append(contentsOf: [
                UInt8(value),
                UInt8(255 - value),
                UInt8((value * 37 + 11) & 0xFF),
            ])
        }
        var alpha = Data(capacity: 64)
        for value in 0..<64 {
            if value % 11 == 0 {
                alpha.append(0)
            } else if value % 7 == 0 {
                alpha.append(255)
            } else {
                alpha.append(UInt8((value * 53 + 17) & 0xFF))
            }
        }
        let data = try makeRawIndexed8PNG(
            width: width,
            height: height,
            indices: indices,
            palette: palette,
            alphaTable: alpha,
            includeSRGB: true
        )
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .preserveSource
        )
        let expectedOperation = width * height * 4 + width * 2
            + RFC1950BoundedInflate.algorithmicWorkspaceByteChargeUpperBound
            + RFC1950BoundedInflate.streamingOutputWorkspaceByteChargeUpperBound
        let decoder = PNGIndependentRGBA8Decoder(
            maximumOperationByteCharge: expectedOperation
        )
        let ledger = try decoder.resourceLedger(data: data, request: request, limits: .coreV1)
        let decoded = try decoder.decode(data: data, request: request, limits: .coreV1)
        XCTAssertEqual(ledger.operationPeak.bytesUpperBound, expectedOperation)
        XCTAssertEqual(ledger.transferredOutput.bytesUpperBound, width * height * 4)
        for index in 0..<(width * height) {
            let paletteIndex = Int(indices[index])
            let paletteOffset = paletteIndex * 3
            let red = UInt16(palette[paletteOffset])
            let green = UInt16(palette[paletteOffset + 1])
            let blue = UInt16(palette[paletteOffset + 2])
            let alphaValue = UInt16(paletteIndex < alpha.count ? alpha[paletteIndex] : 255)
            let outputOffset = index * 4
            let premultiply: (UInt16) -> UInt8 = { component in
                if alphaValue == 0 { return 0 }
                if alphaValue == 255 { return UInt8(component) }
                return UInt8((component * alphaValue + 127) / 255)
            }
            XCTAssertEqual(decoded.data[outputOffset], premultiply(red))
            XCTAssertEqual(decoded.data[outputOffset + 1], premultiply(green))
            XCTAssertEqual(decoded.data[outputOffset + 2], premultiply(blue))
            XCTAssertEqual(decoded.data[outputOffset + 3], UInt8(alphaValue))
        }
    }

    func testIndependentPNGIndexed8AcceptsShortPaletteAndMatchesImageIOExactly() throws {
        let width = 9
        let height = 5
        let palette = Data([
            12, 34, 56,
            180, 90, 20,
            250, 240, 230,
        ])
        let alpha = Data([255, 127, 0])
        var indices = Data(capacity: width * height)
        for index in 0..<(width * height) {
            indices.append(UInt8(index % 3))
        }
        let data = try makeRawIndexed8PNG(
            width: width,
            height: height,
            indices: indices,
            palette: palette,
            alphaTable: alpha,
            includeSRGB: true
        )
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .preserveSource
        )
        let decoder = PNGIndependentRGBA8Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)
        let actual = try decoder.decode(data: data, request: request, limits: .coreV1)
        let expected = try ImageIOImageDecoder().decodePackedRGBA8(
            data: data,
            request: request,
            limits: .coreV1
        )
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(
            try decoder.resourceLedger(data: data, request: request, limits: .coreV1).operationPeak,
            .bounded(
                width * height * 4 + width * 2
                    + RFC1950BoundedInflate.algorithmicWorkspaceByteChargeUpperBound
                    + RFC1950BoundedInflate.streamingOutputWorkspaceByteChargeUpperBound
            )
        )
    }

    func testIndependentPNGIndexedLowBitDepthsUsePackedRowsAndMatchImageIOExactly() throws {
        let width = 13
        let height = 7
        let decoder = PNGIndependentRGBA8Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)

        for bitDepth in [1, 2, 4] {
            let entryCount = 1 << bitDepth
            var palette = Data(capacity: entryCount * 3)
            var alpha = Data(capacity: entryCount)
            for index in 0..<entryCount {
                palette.append(contentsOf: [
                    UInt8((index * 53 + 11) & 0xFF),
                    UInt8((index * 97 + 29) & 0xFF),
                    UInt8((index * 131 + 47) & 0xFF),
                ])
                alpha.append(UInt8((index * 61 + 37) & 0xFF))
            }
            var indices = Data(capacity: width * height)
            for index in 0..<(width * height) {
                indices.append(UInt8((index * 5 + index / width) % entryCount))
            }
            let data = try makeRawIndexed8PNG(
                width: width,
                height: height,
                indices: indices,
                palette: palette,
                alphaTable: alpha,
                includeSRGB: true,
                bitDepth: bitDepth
            )
            let request = ImageDecodeRequest(
                target: try TargetPixels(width: width, height: height),
                colorPolicy: .preserveSource
            )
            let actual = try decoder.decode(data: data, request: request, limits: .coreV1)
            let expected = try ImageIOImageDecoder().decodePackedRGBA8(
                data: data,
                request: request,
                limits: .coreV1
            )
            XCTAssertEqual(actual, expected, "bitDepth=\(bitDepth)")

            let rowBytes = (width * bitDepth + 7) / 8
            let expectedOperation = width * height * 4 + rowBytes * 2
                + RFC1950BoundedInflate.algorithmicWorkspaceByteChargeUpperBound
                + RFC1950BoundedInflate.streamingOutputWorkspaceByteChargeUpperBound
            XCTAssertEqual(
                try decoder.resourceLedger(data: data, request: request, limits: .coreV1)
                    .operationPeak.bytesUpperBound,
                expectedOperation,
                "bitDepth=\(bitDepth)"
            )
            XCTAssertEqual(
                try PNGIndependentRGBA8Decoder(maximumOperationByteCharge: expectedOperation)
                    .decode(data: data, request: request, limits: .coreV1),
                actual,
                "bitDepth=\(bitDepth) exact budget"
            )
        }
    }

    func testIndependentPNGIndexed2ShortPaletteRejectsOutOfRangePackedIndex() throws {
        let width = 13
        let height = 1
        var indices = Data(repeating: 0, count: width)
        indices[width - 1] = 3
        let data = try makeRawIndexed8PNG(
            width: width,
            height: height,
            indices: indices,
            palette: Data([
                12, 34, 56,
                180, 90, 20,
                250, 240, 230,
            ]),
            alphaTable: nil,
            includeSRGB: true,
            bitDepth: 2
        )
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .preserveSource
        )
        XCTAssertThrowsError(
            try PNGIndependentRGBA8Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)
                .decode(data: data, request: request, limits: .coreV1)
        )
    }

    func testIndependentPNGIndexed8ShortPaletteRejectsOutOfRangeIndex() throws {
        let width = 4
        let height = 1
        let data = try makeRawIndexed8PNG(
            width: width,
            height: height,
            indices: Data([0, 1, 2, 3]),
            palette: Data([
                12, 34, 56,
                180, 90, 20,
                250, 240, 230,
            ]),
            alphaTable: nil,
            includeSRGB: true
        )
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .preserveSource
        )
        XCTAssertThrowsError(
            try PNGIndependentRGBA8Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)
                .decode(data: data, request: request, limits: .coreV1)
        )
    }

    func testIndependentPNGGrayscaleAlpha8LedgerChargesTwoByteSourceRowsAndPremultipliesExactly() throws {
        let width = 13
        let height = 8
        var grayAlpha = Data(capacity: width * height * 2)
        for index in 0..<(width * height) {
            let gray = UInt8((index * 43 + 17) & 0xFF)
            let selector = index % 5
            let alpha: UInt8
            if selector == 0 {
                alpha = 0
            } else if selector == 1 {
                alpha = 255
            } else {
                alpha = UInt8((index * 67 + 29) & 0xFF)
            }
            grayAlpha.append(contentsOf: [gray, alpha])
        }
        let data = try makeRawGrayAlpha8PNG(
            width: width,
            height: height,
            straightGrayAlpha: grayAlpha,
            includeSRGB: true
        )
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .preserveSource
        )
        let decoder = PNGIndependentRGBA8Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)
        let ledger = try decoder.resourceLedger(data: data, request: request, limits: .coreV1)
        let decoded = try decoder.decode(data: data, request: request, limits: .coreV1)
        let expectedOperation = width * height * 4 + width * 2 * 2
            + RFC1950BoundedInflate.algorithmicWorkspaceByteChargeUpperBound
            + RFC1950BoundedInflate.streamingOutputWorkspaceByteChargeUpperBound
        XCTAssertEqual(ledger.operationPeak.bytesUpperBound, expectedOperation)
        XCTAssertEqual(ledger.transferredOutput.bytesUpperBound, width * height * 4)
        let exactBudgetDecoder = PNGIndependentRGBA8Decoder(
            maximumOperationByteCharge: expectedOperation
        )
        XCTAssertEqual(
            try exactBudgetDecoder.decode(data: data, request: request, limits: .coreV1),
            decoded
        )
        for index in 0..<(width * height) {
            let sourceOffset = index * 2
            let outputOffset = index * 4
            let gray = UInt16(grayAlpha[sourceOffset])
            let alpha = UInt16(grayAlpha[sourceOffset + 1])
            let premultiplied = alpha == 0
                ? UInt8(0)
                : alpha == 255
                    ? UInt8(gray)
                    : UInt8((gray * alpha + 127) / 255)
            XCTAssertEqual(decoded.data[outputOffset], premultiplied)
            XCTAssertEqual(decoded.data[outputOffset + 1], premultiplied)
            XCTAssertEqual(decoded.data[outputOffset + 2], premultiplied)
            XCTAssertEqual(decoded.data[outputOffset + 3], UInt8(alpha))
        }
    }

    func testIndependentPNGGrayscale8LedgerChargesOneByteSourceRowsAndFourByteOutput() throws {
        let width = 17
        let height = 9
        var gray = Data(capacity: width * height)
        for index in 0..<(width * height) {
            gray.append(UInt8((index * 37 + (index / width) * 19 + 11) & 0xFF))
        }
        let data = try makeRawGray8PNG(
            width: width,
            height: height,
            straightGray: gray,
            includeSRGB: true
        )
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .preserveSource
        )
        let decoder = PNGIndependentRGBA8Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)
        let ledger = try decoder.resourceLedger(data: data, request: request, limits: .coreV1)
        let decoded = try decoder.decode(data: data, request: request, limits: .coreV1)
        let imageIO = try ImageIOImageDecoder().decodePackedRGBA8(
            data: data,
            request: request,
            limits: .coreV1
        )
        let expectedOperation = width * height * 4 + width * 2
            + RFC1950BoundedInflate.algorithmicWorkspaceByteChargeUpperBound
            + RFC1950BoundedInflate.streamingOutputWorkspaceByteChargeUpperBound
        let previousRGBConservativePreflight = width * height * 4 + width * 3 * 2
            + RFC1950BoundedInflate.algorithmicWorkspaceByteChargeUpperBound
            + RFC1950BoundedInflate.streamingOutputWorkspaceByteChargeUpperBound
        XCTAssertLessThan(expectedOperation, previousRGBConservativePreflight)
        let exactBudgetDecoder = PNGIndependentRGBA8Decoder(
            maximumOperationByteCharge: expectedOperation
        )
        XCTAssertEqual(
            try exactBudgetDecoder.resourceLedger(
                data: data,
                request: request,
                limits: .coreV1
            ).operationPeak.bytesUpperBound,
            expectedOperation
        )
        XCTAssertEqual(
            try exactBudgetDecoder.decode(data: data, request: request, limits: .coreV1),
            decoded
        )
        XCTAssertEqual(decoded, imageIO)
        XCTAssertEqual(ledger.operationPeak.bytesUpperBound, expectedOperation)
        XCTAssertEqual(ledger.transferredOutput.bytesUpperBound, width * height * 4)
        for index in 0..<(width * height) {
            let outputOffset = index * 4
            XCTAssertEqual(decoded.data[outputOffset], gray[index])
            XCTAssertEqual(decoded.data[outputOffset + 1], gray[index])
            XCTAssertEqual(decoded.data[outputOffset + 2], gray[index])
            XCTAssertEqual(decoded.data[outputOffset + 3], 255)
        }
    }

    func testIndependentPNGGrayscale8TRNSMasksHighBitsAndPublishesBinaryAlphaExactly() throws {
        let width = 5
        let height = 2
        let transparent = UInt8(13)
        let gray = Data([
            transparent, 7, 29, transparent, 201,
            0, 255, transparent, 128, 64,
        ])
        XCTAssertEqual(gray.count, width * height)
        let base = try makeRawGray8PNG(
            width: width,
            height: height,
            straightGray: gray,
            includeSRGB: true
        )
        let idat = try XCTUnwrap(try pngTestChunks(base).first { $0.type == "IDAT" })
        var data = base
        data.insert(
            contentsOf: try makePNGTestChunk(
                type: "tRNS",
                payload: Data([0xAB, transparent])
            ),
            at: idat.start
        )
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .preserveSource
        )
        let decoder = PNGIndependentRGBA8Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)
        let actual = try decoder.decode(data: data, request: request, limits: .coreV1)
        let imageIO = try ImageIOImageDecoder().decodePackedRGBA8(
            data: data,
            request: request,
            limits: .coreV1
        )
        XCTAssertEqual(actual, imageIO)
        for index in gray.indices {
            let outputOffset = index * 4
            if gray[index] == transparent {
                XCTAssertEqual(actual.data[outputOffset..<(outputOffset + 4)], Data([0, 0, 0, 0]))
            } else {
                XCTAssertEqual(actual.data[outputOffset], gray[index])
                XCTAssertEqual(actual.data[outputOffset + 1], gray[index])
                XCTAssertEqual(actual.data[outputOffset + 2], gray[index])
                XCTAssertEqual(actual.data[outputOffset + 3], 255)
            }
        }
        XCTAssertEqual(
            try decoder.resourceLedger(data: data, request: request, limits: .coreV1).operationPeak,
            try decoder.resourceLedger(data: base, request: request, limits: .coreV1).operationPeak
        )
    }

    func testIndependentPNGGrayscaleLowBitDepthsUsePackedRowsScaleExactlyAndMaskTRNS() throws {
        let width = 13
        let height = 7
        let decoder = PNGIndependentRGBA8Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)

        for bitDepth in [1, 2, 4] {
            let maximumSample = (1 << bitDepth) - 1
            let transparentSample = min(2, maximumSample)
            var gray = Data(capacity: width * height)
            for index in 0..<(width * height) {
                gray.append(UInt8((index * 5 + index / width) % (maximumSample + 1)))
            }
            let base = try makeRawGray8PNG(
                width: width,
                height: height,
                straightGray: gray,
                includeSRGB: true,
                bitDepth: bitDepth
            )
            let idat = try XCTUnwrap(try pngTestChunks(base).first { $0.type == "IDAT" })
            var data = base
            data.insert(
                contentsOf: try makePNGTestChunk(
                    type: "tRNS",
                    payload: Data([0xAB, UInt8(transparentSample)])
                ),
                at: idat.start
            )
            let request = ImageDecodeRequest(
                target: try TargetPixels(width: width, height: height),
                colorPolicy: .preserveSource
            )
            let actual = try decoder.decode(data: data, request: request, limits: .coreV1)
            let imageIO = try ImageIOImageDecoder().decodePackedRGBA8(
                data: data,
                request: request,
                limits: .coreV1
            )
            XCTAssertEqual(actual, imageIO, "bitDepth=\(bitDepth)")

            for index in gray.indices {
                let outputOffset = index * 4
                let sample = Int(gray[index])
                if sample == transparentSample {
                    XCTAssertEqual(
                        actual.data[outputOffset..<(outputOffset + 4)],
                        Data([0, 0, 0, 0]),
                        "bitDepth=\(bitDepth) sample=\(sample)"
                    )
                } else {
                    let scaled = UInt8((sample * 255) / maximumSample)
                    XCTAssertEqual(actual.data[outputOffset], scaled)
                    XCTAssertEqual(actual.data[outputOffset + 1], scaled)
                    XCTAssertEqual(actual.data[outputOffset + 2], scaled)
                    XCTAssertEqual(actual.data[outputOffset + 3], 255)
                }
            }

            let rowBytes = (width * bitDepth + 7) / 8
            let expectedOperation = width * height * 4 + rowBytes * 2
                + RFC1950BoundedInflate.algorithmicWorkspaceByteChargeUpperBound
                + RFC1950BoundedInflate.streamingOutputWorkspaceByteChargeUpperBound
            XCTAssertEqual(
                try decoder.resourceLedger(data: data, request: request, limits: .coreV1)
                    .operationPeak.bytesUpperBound,
                expectedOperation,
                "bitDepth=\(bitDepth)"
            )
            XCTAssertEqual(
                try PNGIndependentRGBA8Decoder(maximumOperationByteCharge: expectedOperation)
                    .decode(data: data, request: request, limits: .coreV1),
                actual,
                "bitDepth=\(bitDepth) exact budget"
            )
        }
    }

    func testIndependentPNGRGB8LedgerChargesThreeByteSourceRowsAndFourByteOutput() throws {
        let width = 13
        let height = 7
        var rgb = Data(capacity: width * height * 3)
        for index in 0..<(width * height) {
            rgb.append(UInt8((index * 11 + 7) & 0xFF))
            rgb.append(UInt8((index * 23 + 19) & 0xFF))
            rgb.append(UInt8((index * 41 + 29) & 0xFF))
        }
        let data = try makeRawRGB8PNG(
            width: width,
            height: height,
            straightRGB: rgb,
            includeSRGB: true
        )
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .preserveSource
        )
        let decoder = PNGIndependentRGBA8Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)
        let ledger = try decoder.resourceLedger(data: data, request: request, limits: .coreV1)
        let decoded = try decoder.decode(data: data, request: request, limits: .coreV1)
        let expectedOperation = width * height * 4 + width * 3 * 2
            + RFC1950BoundedInflate.algorithmicWorkspaceByteChargeUpperBound
            + RFC1950BoundedInflate.streamingOutputWorkspaceByteChargeUpperBound
        let previousRGBAConservativePreflight = width * height * 4 + width * 4 * 2
            + RFC1950BoundedInflate.algorithmicWorkspaceByteChargeUpperBound
            + RFC1950BoundedInflate.streamingOutputWorkspaceByteChargeUpperBound
        XCTAssertLessThan(expectedOperation, previousRGBAConservativePreflight)
        let exactBudgetDecoder = PNGIndependentRGBA8Decoder(
            maximumOperationByteCharge: expectedOperation
        )
        XCTAssertEqual(
            try exactBudgetDecoder.resourceLedger(
                data: data,
                request: request,
                limits: .coreV1
            ).operationPeak.bytesUpperBound,
            expectedOperation
        )
        XCTAssertEqual(
            try exactBudgetDecoder.decode(data: data, request: request, limits: .coreV1).data,
            decoded.data
        )
        XCTAssertEqual(ledger.operationPeak.bytesUpperBound, expectedOperation)
        XCTAssertEqual(ledger.transferredOutput.bytesUpperBound, width * height * 4)
        XCTAssertEqual(decoded.data.count, width * height * 4)
        for index in 0..<(width * height) {
            XCTAssertEqual(decoded.data[index * 4], rgb[index * 3])
            XCTAssertEqual(decoded.data[index * 4 + 1], rgb[index * 3 + 1])
            XCTAssertEqual(decoded.data[index * 4 + 2], rgb[index * 3 + 2])
            XCTAssertEqual(decoded.data[index * 4 + 3], 255)
        }
    }

    func testIndependentPNGUntaggedRequiresExplicitSRGBConversionAndNonRGBICCRejects() throws {
        let width = 3
        let height = 2
        let straight = Data(repeating: 127, count: width * height * 4)
        let preserve = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .preserveSource
        )
        let convert = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .convertToSRGB
        )
        let decoder = PNGIndependentRGBA8Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)

        let untagged = try makeRawRGBA8PNG(
            width: width,
            height: height,
            straightRGBA: straight,
            includeSRGB: false
        )
        let probe = try decoder.probe(data: untagged, limits: .coreV1)
        XCTAssertEqual(probe.sourceColorProfile, .absent)
        XCTAssertThrowsError(
            try decoder.resourceLedger(data: untagged, request: preserve, limits: .coreV1)
        ) {
            XCTAssertEqual($0 as? PNGIndependentRGBA8Error, .unsupportedSourceSemantics)
        }
        XCTAssertThrowsError(
            try decoder.decode(data: untagged, request: preserve, limits: .coreV1)
        ) {
            XCTAssertEqual($0 as? PNGIndependentRGBA8Error, .unsupportedSourceSemantics)
        }
        let convertedLedger = try decoder.resourceLedger(
            data: untagged,
            request: convert,
            limits: .coreV1
        )
        let converted = try decoder.decode(data: untagged, request: convert, limits: .coreV1)
        let imageIOConverted = try ImageIOImageDecoder().decodePackedRGBA8(
            data: untagged,
            request: convert,
            limits: .coreV1
        )
        XCTAssertEqual(converted, imageIOConverted)
        XCTAssertEqual(converted.colorEncoding, .sRGB)
        XCTAssertEqual(converted.sourceColorProfile, .absent)
        XCTAssertEqual(convertedLedger.outputLayoutAuthority, .codecOwnedRGBA8)
        XCTAssertEqual(
            convertedLedger.transferredOutput,
            .bounded(converted.transferredByteCharge)
        )

        for signature in ["GRAY", "CMYK"] {
            var nonRGBProfile = Data(repeating: 0, count: 132)
            nonRGBProfile.replaceSubrange(0..<4, with: pngTestUInt32Bytes(132))
            nonRGBProfile.replaceSubrange(16..<20, with: Data(signature.utf8))
            nonRGBProfile.replaceSubrange(36..<40, with: Data("acsp".utf8))
            let nonRGBICC = try makeRawRGBA8PNG(
                width: width,
                height: height,
                straightRGBA: straight,
                includeSRGB: false,
                embeddedICCProfile: nonRGBProfile
            )
            XCTAssertThrowsError(
                try decoder.resourceLedger(data: nonRGBICC, request: preserve, limits: .coreV1)
            ) {
                XCTAssertEqual($0 as? PNGIndependentRGBA8Error, .unsupportedSourceSemantics)
            }
            XCTAssertThrowsError(
                try decoder.decode(data: nonRGBICC, request: preserve, limits: .coreV1)
            ) {
                XCTAssertEqual($0 as? PNGIndependentRGBA8Error, .unsupportedSourceSemantics)
            }
        }
    }

    func testIndependentPNGRejectsReservedBitsAndUnqualifiedColorAncillaryOrdering() throws {
        let width = 3
        let height = 2
        let straight = Data(repeating: 127, count: width * height * 4)
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .preserveSource
        )
        let decoder = PNGIndependentRGBA8Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)

        let tagged = try makeRawRGBA8PNG(
            width: width,
            height: height,
            straightRGBA: straight,
            includeSRGB: true
        )
        let taggedChunks = try pngTestChunks(tagged)
        let srgb = try XCTUnwrap(taggedChunks.first { $0.type == "sRGB" })

        var reservedBit = tagged
        reservedBit.insert(
            contentsOf: try makePNGTestChunk(type: "aaab", payload: Data()),
            at: srgb.end
        )
        XCTAssertThrowsError(
            try decoder.decode(data: reservedBit, request: request, limits: .coreV1)
        ) {
            XCTAssertEqual($0 as? ImageCraftError, .unsupportedOrCorruptImage)
        }

        let srgbChromaticities = [31_270, 32_900, 64_000, 33_000, 30_000, 60_000, 15_000, 6_000]
            .flatMap { pngTestUInt32Bytes(UInt32($0)) }
        for ancillary in [
            try makePNGTestChunk(type: "gAMA", payload: Data(pngTestUInt32Bytes(45_455))),
            try makePNGTestChunk(type: "cHRM", payload: Data(srgbChromaticities)),
            try makePNGTestChunk(type: "cLLI", payload: Data(repeating: 0, count: 8)),
        ] {
            var candidate = tagged
            candidate.insert(contentsOf: ancillary, at: srgb.end)
            XCTAssertThrowsError(
                try decoder.decode(data: candidate, request: request, limits: .coreV1)
            ) {
                XCTAssertEqual($0 as? PNGIndependentRGBA8Error, .unsupportedSourceSemantics)
            }
        }

        var hdrMetadata = tagged
        var hdrChunks = Data()
        hdrChunks.append(
            try makePNGTestChunk(
                type: "cICP",
                payload: Data([0x01, 0x0D, 0x00, 0x01])
            )
        )
        hdrChunks.append(
            try makePNGTestChunk(type: "mDCV", payload: Data(repeating: 0, count: 24))
        )
        hdrMetadata.insert(contentsOf: hdrChunks, at: srgb.end)
        XCTAssertThrowsError(
            try decoder.decode(data: hdrMetadata, request: request, limits: .coreV1)
        ) {
            XCTAssertEqual($0 as? PNGIndependentRGBA8Error, .unsupportedSourceSemantics)
        }

        var lateSRGB = try makeRawRGBA8PNG(
            width: width,
            height: height,
            straightRGBA: straight,
            includeSRGB: false
        )
        let iend = try XCTUnwrap(try pngTestChunks(lateSRGB).first { $0.type == "IEND" })
        lateSRGB.insert(
            contentsOf: try makePNGTestChunk(type: "sRGB", payload: Data([0])),
            at: iend.start
        )
        XCTAssertThrowsError(
            try decoder.decode(data: lateSRGB, request: request, limits: .coreV1)
        ) {
            XCTAssertEqual($0 as? ImageCraftError, .unsupportedOrCorruptImage)
        }
    }

    func testIndependentPNG8RejectsSBITUntilPackedValueCarriesSourcePrecision() throws {
        let straight = Data([40, 80, 120, 255, 200, 100, 50, 128])
        let data = try makeRawRGBA8PNG(
            width: 2,
            height: 1,
            straightRGBA: straight,
            includeSRGB: true,
            significantBits: [6, 6, 6, 8]
        )
        let decoder = PNGIndependentRGBA8Decoder(maximumOperationByteCharge: 1 << 20)
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: 2, height: 1),
            colorPolicy: .preserveSource
        )

        XCTAssertThrowsError(
            try decoder.decode(data: data, request: request, limits: .coreV1)
        ) {
            XCTAssertEqual($0 as? PNGIndependentRGBA8Error, .unsupportedSourceSemantics)
        }
        XCTAssertThrowsError(
            try decoder.resourceLedger(data: data, request: request, limits: .coreV1)
        ) {
            XCTAssertEqual($0 as? PNGIndependentRGBA8Error, .unsupportedSourceSemantics)
        }
    }

    func testIndependentPNG8QualifiesNarrowDisplayP3CICPWithoutInventingHDRConversion() throws {
        let straight = Data([40, 80, 120, 255, 200, 100, 50, 128])
        let data = try makeRawRGBA8PNG(
            width: 2,
            height: 1,
            straightRGBA: straight,
            includeSRGB: false,
            cicp: [12, 13, 0, 1]
        )
        let decoder = PNGIndependentRGBA8Decoder(maximumOperationByteCharge: 1 << 20)
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: 2, height: 1),
            colorPolicy: .preserveSource
        )
        let expectedCICP = try XCTUnwrap(
            ImagePackedCICPColorEncoding(
                colorPrimaries: 12,
                transferFunction: 13,
                matrixCoefficients: 0,
                videoFullRangeFlag: 1
            )
        )

        let actual = try decoder.decode(data: data, request: request, limits: .coreV1)
        XCTAssertEqual(actual.data, premultipliedRGBA8TestData(straight))
        XCTAssertEqual(actual.colorEncoding, .cicp(expectedCICP))
        XCTAssertEqual(actual.sourceColorProfile, .unknown)
        XCTAssertEqual(actual.pixelByteCharge, 8)
        XCTAssertEqual(actual.transferredByteCharge, 8)

        let ledger = try decoder.resourceLedger(data: data, request: request, limits: .coreV1)
        XCTAssertNotNil(ledger.operationPeak.bytesUpperBound)
        XCTAssertEqual(ledger.outputLayoutAuthority, .codecOwnedRGBA8)
        XCTAssertEqual(ledger.transferredOutput, .bounded(8))

        let displayP3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let lowerPriorityICC = try XCTUnwrap(displayP3.copyICCData()).bridgeToData()
        let withLowerPriorityICC = try makeRawRGBA8PNG(
            width: 2,
            height: 1,
            straightRGBA: straight,
            includeSRGB: false,
            embeddedICCProfile: lowerPriorityICC,
            cicp: [12, 13, 0, 1]
        )
        let precedenceValue = try decoder.decode(
            data: withLowerPriorityICC,
            request: request,
            limits: .coreV1
        )
        XCTAssertEqual(precedenceValue, actual)
        XCTAssertEqual(
            try decoder.resourceLedger(
                data: withLowerPriorityICC,
                request: request,
                limits: .coreV1
            ),
            ledger
        )

        XCTAssertThrowsError(
            try decoder.decode(
                data: data,
                request: ImageDecodeRequest(target: request.target, colorPolicy: .convertToSRGB),
                limits: .coreV1
            )
        ) {
            XCTAssertEqual($0 as? PNGIndependentRGBA8Error, .unsupportedSourceSemantics)
        }

        let pq = try makeRawRGBA8PNG(
            width: 2,
            height: 1,
            straightRGBA: straight,
            includeSRGB: false,
            cicp: [9, 16, 0, 1]
        )
        XCTAssertThrowsError(
            try decoder.decode(data: pq, request: request, limits: .coreV1)
        ) {
            XCTAssertEqual($0 as? PNGIndependentRGBA8Error, .unsupportedSourceSemantics)
        }

        let significantBits = try makeRawRGBA8PNG(
            width: 2,
            height: 1,
            straightRGBA: straight,
            includeSRGB: false,
            significantBits: [6, 6, 6, 8],
            cicp: [12, 13, 0, 1]
        )
        XCTAssertThrowsError(
            try decoder.decode(data: significantBits, request: request, limits: .coreV1)
        ) {
            XCTAssertEqual($0 as? PNGIndependentRGBA8Error, .unsupportedSourceSemantics)
        }
    }

    func testIndependentPNGBackendFailsClosedOutsideQualifiedDomain() throws {
        let data = try makeColorManagedPNG(
            width: 31,
            height: 19,
            colorSpace: try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3)),
            rgba: (190, 80, 30, 137)
        )
        let decoder = PNGIndependentRGBA8Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)
        let fullRequest = ImageDecodeRequest(
            target: try TargetPixels(width: 31, height: 19),
            colorPolicy: .preserveSource
        )

        // ImageIO currently emits eXIf and, for Display P3, cICP in addition to iCCP. Those
        // independent metadata semantics are intentionally not part of this narrow backend yet.
        XCTAssertThrowsError(
            try decoder.decode(data: data, request: fullRequest, limits: .coreV1)
        ) {
            XCTAssertEqual($0 as? PNGIndependentRGBA8Error, .unsupportedSourceSemantics)
        }

        XCTAssertThrowsError(
            try decoder.decode(
                data: data,
                request: ImageDecodeRequest(
                    target: try TargetPixels(width: 15, height: 9),
                    colorPolicy: .preserveSource
                ),
                limits: .coreV1
            )
        ) {
            XCTAssertEqual($0 as? PNGIndependentRGBA8Error, .unsupportedRequest)
        }
        XCTAssertThrowsError(
            try decoder.decode(
                data: data,
                request: ImageDecodeRequest(
                    target: fullRequest.target,
                    colorPolicy: .convertToSRGB
                ),
                limits: .coreV1
            )
        ) {
            XCTAssertEqual($0 as? PNGIndependentRGBA8Error, .unsupportedSourceSemantics)
        }

        var interlaced = data
        let ihdr = try XCTUnwrap(try pngTestChunks(interlaced).first { $0.type == "IHDR" })
        XCTAssertEqual(ihdr.payloadEnd - ihdr.payloadStart, 13)
        interlaced[ihdr.payloadStart + 12] = 1
        try rewritePNGTestChunkCRC(&interlaced, chunk: ihdr)
        XCTAssertThrowsError(
            try decoder.decode(data: interlaced, request: fullRequest, limits: .coreV1)
        ) {
            XCTAssertEqual($0 as? PNGIndependentRGBA8Error, .unsupportedSourceSemantics)
        }

        var apngMarked = data
        let chunks = try pngTestChunks(apngMarked)
        let ihdrEnd = try XCTUnwrap(chunks.first { $0.type == "IHDR" }).end
        let acTL = try makePNGTestChunk(
            type: "acTL",
            payload: Data([0, 0, 0, 1, 0, 0, 0, 0])
        )
        apngMarked.insert(contentsOf: acTL, at: ihdrEnd)
        XCTAssertThrowsError(
            try decoder.decode(data: apngMarked, request: fullRequest, limits: .coreV1)
        ) {
            XCTAssertEqual($0 as? PNGIndependentRGBA8Error, .unsupportedSourceSemantics)
        }

        var malformedChunkType = try makeRawRGBA8PNG(
            width: 31,
            height: 19,
            straightRGBA: Data(repeating: 127, count: 31 * 19 * 4),
            includeSRGB: true
        )
        let srgbChunk = try XCTUnwrap(
            try pngTestChunks(malformedChunkType).first { $0.type == "sRGB" }
        )
        malformedChunkType[srgbChunk.start + 6] = 0x21
        try rewritePNGTestChunkCRC(&malformedChunkType, chunk: srgbChunk)
        XCTAssertThrowsError(
            try decoder.decode(data: malformedChunkType, request: fullRequest, limits: .coreV1)
        ) {
            XCTAssertEqual($0 as? ImageCraftError, .unsupportedOrCorruptImage)
        }

        var noncontiguousKnownAncillary = try makeRawRGBA8PNG(
            width: 31,
            height: 19,
            straightRGBA: Data(repeating: 127, count: 31 * 19 * 4),
            includeSRGB: true
        )
        let idat = try XCTUnwrap(
            try pngTestChunks(noncontiguousKnownAncillary).first { $0.type == "IDAT" }
        )
        let compressed = Data(noncontiguousKnownAncillary[idat.payloadStart..<idat.payloadEnd])
        let split = compressed.count / 2
        var replacement = Data()
        replacement.append(
            try makePNGTestChunk(type: "IDAT", payload: Data(compressed[..<split]))
        )
        replacement.append(
            try makePNGTestChunk(
                type: "gAMA",
                payload: Data(pngTestUInt32Bytes(45_455))
            )
        )
        replacement.append(
            try makePNGTestChunk(type: "IDAT", payload: Data(compressed[split...]))
        )
        noncontiguousKnownAncillary.replaceSubrange(idat.start..<idat.end, with: replacement)
        XCTAssertThrowsError(
            try decoder.decode(
                data: noncontiguousKnownAncillary,
                request: fullRequest,
                limits: .coreV1
            )
        ) {
            XCTAssertEqual($0 as? ImageCraftError, .unsupportedOrCorruptImage)
        }
    }

    func testIndependentPNGResourceLedgerBoundsSRGBOperationAndTransfer() throws {
        var straightRGBA = Data()
        for _ in 0..<(13 * 7) {
            straightRGBA.append(contentsOf: [120, 60, 30, 128])
        }
        let data = try makeRawRGBA8PNG(
            width: 13,
            height: 7,
            straightRGBA: straightRGBA,
            includeSRGB: true
        )
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: 13, height: 7),
            colorPolicy: .preserveSource
        )
        let decoder = PNGIndependentRGBA8Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)
        let ledger = try decoder.resourceLedger(data: data, request: request, limits: .coreV1)
        let result = try decoder.decode(data: data, request: request, limits: .coreV1)

        XCTAssertEqual(ledger.retainedKnownBytes, 0)
        XCTAssertEqual(ledger.retainedBetweenCalls, .bounded(0))
        let rawBytes = 13 * 7 * 4
        guard case .bounded(let operationCharge) = ledger.operationPeak else {
            return XCTFail("pure sRGB PNG path must publish a bounded operation charge")
        }
        XCTAssertEqual(
            operationCharge,
            rawBytes + 13 * 4 * 2
                + RFC1950BoundedInflate.algorithmicWorkspaceByteChargeUpperBound
                + RFC1950BoundedInflate.streamingOutputWorkspaceByteChargeUpperBound
        )
        XCTAssertEqual(ledger.transferredOutput, .bounded(result.transferredByteCharge))
        XCTAssertEqual(ledger.outputLayoutAuthority, .codecOwnedRGBA8)
    }

    func testIndependentPNGStreamingCursorEliminatesInflatedAndCompressedCopies() throws {
        let width = 512
        let height = 512
        let data = try makeRawRGBA8PNG(
            width: width,
            height: height,
            straightRGBA: Data(repeating: 127, count: width * height * 4),
            includeSRGB: true
        )
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .preserveSource
        )
        let limits = DecodeLimits(maximumMetadataBytes: 0)
        let decoder = PNGIndependentRGBA8Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)
        let ledger = try decoder.resourceLedger(data: data, request: request, limits: limits)
        guard case .bounded(let operationCharge) = ledger.operationPeak else {
            return XCTFail("streaming PNG path must publish a bounded operation charge")
        }

        let compressedBytes = try pngTestChunks(data)
            .filter { $0.type == "IDAT" }
            .reduce(0) { $0 + ($1.payloadEnd - $1.payloadStart) }
        XCTAssertGreaterThan(compressedBytes, 0)
        let previousAggregatedStreamingModel = operationCharge + compressedBytes
        XCTAssertEqual(previousAggregatedStreamingModel - operationCharge, compressedBytes)

        let inflatedBytes = (width * 4 + 1) * height
        let previousFullInflatedModel = previousAggregatedStreamingModel
            - RFC1950BoundedInflate.streamingOutputWorkspaceByteChargeUpperBound
            + inflatedBytes
        XCTAssertLessThan(operationCharge, previousFullInflatedModel)
        XCTAssertEqual(
            previousFullInflatedModel - previousAggregatedStreamingModel,
            inflatedBytes - RFC1950BoundedInflate.streamingOutputWorkspaceByteChargeUpperBound
        )
        XCTAssertGreaterThan(
            previousFullInflatedModel - previousAggregatedStreamingModel,
            1_000_000
        )

        let rowBytes = width * 4
        let cursorPreflightCharge = width * height * 4
            + rowBytes * 2
            + RFC1950BoundedInflate.algorithmicWorkspaceByteChargeUpperBound
            + RFC1950BoundedInflate.streamingOutputWorkspaceByteChargeUpperBound
        let previousAggregatedPreflightCharge = cursorPreflightCharge + data.count
        XCTAssertEqual(previousAggregatedPreflightCharge - cursorPreflightCharge, data.count)
        let previousFullInflatedPreflightCharge = previousAggregatedPreflightCharge
            - RFC1950BoundedInflate.streamingOutputWorkspaceByteChargeUpperBound
            + inflatedBytes
        XCTAssertGreaterThan(
            previousFullInflatedPreflightCharge - previousAggregatedPreflightCharge,
            1_000_000
        )

        let constrained = PNGIndependentRGBA8Decoder(
            maximumOperationByteCharge: cursorPreflightCharge
        )
        _ = try constrained.resourceLedger(data: data, request: request, limits: limits)
        let decoded = try constrained.decode(data: data, request: request, limits: limits)
        XCTAssertEqual(decoded.data.count, width * height * 4)
        XCTAssertEqual(decoded.data.prefix(4), Data([63, 63, 63, 127]))
    }

    func testIndependentPNGResourceLedgerBoundsEmbeddedICCSecurityAndPixelPhases() throws {
        let displayP3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let profile = try XCTUnwrap(displayP3.copyICCData()).bridgeToData()
        let data = try makeRawRGBA8PNG(
            width: 13,
            height: 7,
            straightRGBA: Data(repeating: 127, count: 13 * 7 * 4),
            includeSRGB: false,
            embeddedICCProfile: profile
        )
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: 13, height: 7),
            colorPolicy: .preserveSource
        )
        let limits = DecodeLimits(maximumMetadataBytes: 1_024)
        let decoder = PNGIndependentRGBA8Decoder(maximumOperationByteCharge: 64 * 1024 * 1024)
        let ledger = try decoder.resourceLedger(data: data, request: request, limits: limits)
        let result = try decoder.decode(data: data, request: request, limits: limits)

        XCTAssertEqual(ledger.retainedBetweenCalls, .bounded(0))
        guard case .bounded(let operationCharge) = ledger.operationPeak else {
            return XCTFail("pure iCCP + pixel path must publish a bounded operation charge")
        }
        XCTAssertGreaterThanOrEqual(
            operationCharge,
            RFC1950BoundedInflate.maximumModeByteChargeUpperBound(
                maximumOutputByteCount: 1_024
            )
        )
        XCTAssertEqual(ledger.transferredOutput, .bounded(result.transferredByteCharge))
        XCTAssertEqual(ledger.outputLayoutAuthority, .codecOwnedRGBA8)
    }

    func testIndependentPNGICCInflateBorrowsCompressedChunkWithoutOperationCopyCharge() throws {
        let displayP3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let profile = try XCTUnwrap(displayP3.copyICCData()).bridgeToData()
        let data = try makeRawRGBA8PNG(
            width: 1,
            height: 1,
            straightRGBA: Data([190, 80, 30, 137]),
            includeSRGB: false,
            embeddedICCProfile: profile
        )
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: 1, height: 1),
            colorPolicy: .preserveSource
        )
        let metadataLimit = 32 * 1024
        let limits = DecodeLimits(maximumMetadataBytes: metadataLimit)
        let pixelWorstCase = 4 + 8 + metadataLimit
            + RFC1950BoundedInflate.algorithmicWorkspaceByteChargeUpperBound
            + RFC1950BoundedInflate.streamingOutputWorkspaceByteChargeUpperBound
        let borrowedSecurityWorstCase = RFC1950BoundedInflate.maximumModeByteChargeUpperBound(
            maximumOutputByteCount: metadataLimit
        )
        let currentPreflight = max(pixelWorstCase, borrowedSecurityWorstCase)
        let previousCopiedSecurityWorstCase = metadataLimit + borrowedSecurityWorstCase
        XCTAssertGreaterThan(previousCopiedSecurityWorstCase, currentPreflight)

        let decoder = PNGIndependentRGBA8Decoder(maximumOperationByteCharge: currentPreflight)
        let ledger = try decoder.resourceLedger(data: data, request: request, limits: limits)
        let decoded = try decoder.decode(data: data, request: request, limits: limits)
        guard case .bounded(let operationCharge) = ledger.operationPeak else {
            return XCTFail("borrowed iCCP input must retain a bounded operation phase")
        }
        XCTAssertLessThanOrEqual(operationCharge, currentPreflight)
        XCTAssertEqual(decoded.pixelWidth, 1)
        XCTAssertEqual(decoded.pixelHeight, 1)
        XCTAssertEqual(decoded.colorEncoding, .embeddedICC(profile))
    }

    func testIndependentPNGSRGBAdmissionDoesNotReserveUnusedICCMetadataCeiling() throws {
        let data = try makeRawRGBA8PNG(
            width: 1,
            height: 1,
            straightRGBA: Data([210, 130, 50, 191]),
            includeSRGB: true
        )
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: 1, height: 1),
            colorPolicy: .preserveSource
        )
        let limits = DecodeLimits(maximumMetadataBytes: 64 * 1024 * 1024)
        let exactSRGBOperationCharge = 4 + 8
            + RFC1950BoundedInflate.algorithmicWorkspaceByteChargeUpperBound
            + RFC1950BoundedInflate.streamingOutputWorkspaceByteChargeUpperBound
        XCTAssertLessThan(
            exactSRGBOperationCharge,
            RFC1950BoundedInflate.maximumModeByteChargeUpperBound(
                maximumOutputByteCount: limits.maximumMetadataBytes
            )
        )

        let decoder = PNGIndependentRGBA8Decoder(
            maximumOperationByteCharge: exactSRGBOperationCharge
        )
        let ledger = try decoder.resourceLedger(data: data, request: request, limits: limits)
        let decoded = try decoder.decode(data: data, request: request, limits: limits)
        XCTAssertEqual(ledger.operationPeak, .bounded(exactSRGBOperationCharge))
        XCTAssertEqual(decoded.pixelWidth, 1)
        XCTAssertEqual(decoded.pixelHeight, 1)
        XCTAssertEqual(decoded.colorEncoding, .sRGB)
    }

    func testIndependentPNGICCAdmissionPrecedesCorruptProfileInflate() throws {
        let displayP3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let profile = try XCTUnwrap(displayP3.copyICCData()).bridgeToData()
        var data = try makeRawRGBA8PNG(
            width: 1,
            height: 1,
            straightRGBA: Data([160, 90, 40, 211]),
            includeSRGB: false,
            embeddedICCProfile: profile
        )
        let iccp = try XCTUnwrap(try pngTestChunks(data).first { $0.type == "iCCP" })
        var payload = Data(data[iccp.payloadStart..<iccp.payloadEnd])
        guard payload.count >= 6 else { return XCTFail("iCCP payload unexpectedly short") }
        payload[payload.index(before: payload.endIndex)] ^= 0x01
        data.replaceSubrange(
            iccp.start..<iccp.end,
            with: try makePNGTestChunk(type: "iCCP", payload: payload)
        )

        let request = ImageDecodeRequest(
            target: try TargetPixels(width: 1, height: 1),
            colorPolicy: .preserveSource
        )
        let metadataLimit = 32 * 1024
        let limits = DecodeLimits(maximumMetadataBytes: metadataLimit)
        let baselinePixelCharge = 4 + 8
            + RFC1950BoundedInflate.algorithmicWorkspaceByteChargeUpperBound
            + RFC1950BoundedInflate.streamingOutputWorkspaceByteChargeUpperBound
        let iccSecurityCharge = RFC1950BoundedInflate.maximumModeByteChargeUpperBound(
            maximumOutputByteCount: metadataLimit
        )
        XCTAssertGreaterThan(iccSecurityCharge, baselinePixelCharge)

        let constrained = PNGIndependentRGBA8Decoder(
            maximumOperationByteCharge: baselinePixelCharge
        )
        XCTAssertThrowsError(
            try constrained.probe(data: data, limits: limits)
        ) {
            XCTAssertEqual($0 as? PNGIndependentRGBA8Error, .operationBudgetExceeded)
        }
        XCTAssertThrowsError(
            try constrained.decode(data: data, request: request, limits: limits)
        ) {
            XCTAssertEqual($0 as? PNGIndependentRGBA8Error, .operationBudgetExceeded)
        }

        let admitted = PNGIndependentRGBA8Decoder(
            maximumOperationByteCharge: iccSecurityCharge + metadataLimit
        )
        XCTAssertThrowsError(
            try admitted.probe(data: data, limits: limits)
        ) {
            XCTAssertEqual($0 as? ImageCraftError, .unsupportedOrCorruptImage)
        }
        XCTAssertThrowsError(
            try admitted.decode(data: data, request: request, limits: limits)
        ) {
            XCTAssertEqual($0 as? ImageCraftError, .unsupportedOrCorruptImage)
        }
    }

    func testIndependentPNGOperationBudgetRejectsBeforeLargePayloadWork() throws {
        let width = 64
        let height = 64
        let data = try makeRawRGBA8PNG(
            width: width,
            height: height,
            straightRGBA: Data(repeating: 127, count: width * height * 4),
            includeSRGB: true
        )
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: width, height: height),
            colorPolicy: .preserveSource
        )
        let limits = DecodeLimits(maximumMetadataBytes: 0)
        let decoder = PNGIndependentRGBA8Decoder(maximumOperationByteCharge: 32 * 1024)

        XCTAssertThrowsError(
            try decoder.resourceLedger(data: data, request: request, limits: limits)
        ) { XCTAssertEqual($0 as? PNGIndependentRGBA8Error, .operationBudgetExceeded) }
        XCTAssertThrowsError(
            try decoder.decode(data: data, request: request, limits: limits)
        ) { XCTAssertEqual($0 as? PNGIndependentRGBA8Error, .operationBudgetExceeded) }
    }

    func testOwnedRGBAOutputChargesPreservedICCAndDropsItAfterSRGBConversion() throws {
        let adobeRGB = try XCTUnwrap(CGColorSpace(name: CGColorSpace.adobeRGB1998))
        let data = try makeColorManagedJPEG(colorSpace: adobeRGB)
        let decoder = ImageIOImageDecoder(
            qualificationPreparationRetentionMode: .encodedDataOnly,
            outputMaterializationMode: .ownedRGBA8
        )
        let preparation = try decoder.prepare(data: data, limits: .coreV1)
        let preserve = ImageDecodeRequest(
            target: try TargetPixels(width: 16, height: 8),
            colorPolicy: .preserveSource
        )
        let convert = ImageDecodeRequest(
            target: preserve.target,
            colorPolicy: .convertToSRGB
        )
        let pixelCharge = 16 * 8 * 4
        guard case .bounded(let preserveBound) = try XCTUnwrap(
            decoder.preparationResourceLedger(preparation, request: preserve, limits: .coreV1)
        ).transferredOutput else {
            return XCTFail("embedded ICC must have a value-bounded preserve-source transfer charge")
        }
        guard case .bounded(let convertBound) = try XCTUnwrap(
            decoder.preparationResourceLedger(preparation, request: convert, limits: .coreV1)
        ).transferredOutput else {
            return XCTFail("sRGB-owned output must be byte-bounded")
        }
        XCTAssertGreaterThan(preserveBound, pixelCharge)
        XCTAssertEqual(convertBound, pixelCharge)

        let result = try decoder.decode(preparation: preparation, request: preserve, limits: .coreV1)
        XCTAssertEqual(result.colorDescription.outputColorSpaceName, CGColorSpace.adobeRGB1998 as String)
        XCTAssertEqual(result.estimatedByteCost, pixelCharge)
        XCTAssertLessThan(result.estimatedByteCost, preserveBound)
    }

    func testOwnedRGBAOutputBackingSurvivesDecoderAndTokenLifetime() throws {
        let data = try makePNG(width: 31, height: 19)
        let request = ImageDecodeRequest(
            target: try TargetPixels(width: 17, height: 13),
            contentMode: .fill,
            colorPolicy: .convertToSRGB
        )
        let expected = try normalizedRGBABytes(
            ImageIOImageDecoder().decode(data: data, request: request, limits: .coreV1).cgImage
        )
        let image: DecodedImage = try autoreleasepool {
            let decoder = ImageIOImageDecoder(
                qualificationPreparationRetentionMode: .encodedDataOnly,
                outputMaterializationMode: .ownedRGBA8
            )
            let preparation = try decoder.prepare(data: data, limits: .coreV1)
            return try decoder.decode(
                preparation: preparation,
                request: request,
                limits: .coreV1
            )
        }
        XCTAssertEqual(image.estimatedByteCost, image.pixelWidth * image.pixelHeight * 4)
        XCTAssertEqual(try normalizedRGBABytes(image.cgImage), expected)
    }

    func testImageIOCodecDescriptorAdvertisesOnlyCurrentSemantics() {
        let descriptor = ImageIOImageDecoder().codecDescriptor
        XCTAssertEqual(descriptor.identifier.rawValue, "dev.fovea.imageio")
        XCTAssertEqual(descriptor.implementationVersion, 5)
        XCTAssertEqual(descriptor.capabilities.formats, [.png, .jpeg, .gif])
        XCTAssertEqual(
            descriptor.capabilities.deliveryModes,
            [.completeFrame, .progressiveGenerations]
        )
        XCTAssertEqual(descriptor.capabilities.progressiveFormats, [.jpeg])
        XCTAssertEqual(descriptor.capabilities.trackModes, [.primaryFrame])
        XCTAssertEqual(
            descriptor.capabilities.metadata,
            [.orientation, .sourceColorProfile]
        )
        XCTAssertEqual(descriptor.capabilities.dynamicRanges, [.standard])
        XCTAssertEqual(descriptor.capabilities.outputRepresentations, [.coreGraphicsImage])
        XCTAssertEqual(descriptor.capabilities.cancellationMode, .operationBoundary)
    }

}

private func makeJPEGWithMetadataSegment(marker: UInt8, payloadBytes: Int) -> Data {
    var data = Data([0xFF, 0xD8, 0xFF, marker])
    let length = UInt16(payloadBytes + 2).bigEndian
    withUnsafeBytes(of: length) { data.append(contentsOf: $0) }
    data.append(Data(repeating: 0x41, count: payloadBytes))
    data.append(contentsOf: [0xFF, 0xD9])
    return data
}

private func makeJPEGWithPostScanMetadata(payloadBytes: Int) -> Data {
    var data = Data([0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x02])
    data.append(contentsOf: [0x11, 0x22, 0xFF, 0x00, 0x33])
    data.append(makeJPEGWithMetadataSegment(marker: 0xE3, payloadBytes: payloadBytes).dropFirst(2))
    return data
}

private func makeJPEGWithRestartMarkerAndPostScanMetadata(payloadBytes: Int) -> Data {
    var data = Data([0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x02])
    data.append(contentsOf: [0x11, 0xFF, 0xD0, 0x22, 0xFF, 0x00, 0x33])
    data.append(makeJPEGWithMetadataSegment(marker: 0xE3, payloadBytes: payloadBytes).dropFirst(2))
    return data
}

private func makeJPEGWithStructuralScanCount(_ scanCount: Int) -> Data {
    precondition(scanCount >= 0)
    var data = Data([0xFF, 0xD8])
    for _ in 0..<scanCount {
        // This isolates the security scanner's marker-count boundary. ImageIO is not invoked.
        data.append(contentsOf: [0xFF, 0xDA, 0x00, 0x02])
    }
    data.append(contentsOf: [0xFF, 0xD9])
    return data
}

private struct JPEGICCProfileSegment {
    let range: Range<Data.Index>
    let sequenceIndex: Data.Index
    let countIndex: Data.Index
}

private func firstJPEGICCProfileSegment(in data: Data) -> JPEGICCProfileSegment? {
    guard data.starts(with: [0xFF, 0xD8]) else { return nil }
    let signature = Data("ICC_PROFILE\u{0}".utf8)
    var offset = 2
    while offset + 4 <= data.count {
        guard data[offset] == 0xFF else { return nil }
        while offset < data.count, data[offset] == 0xFF { offset += 1 }
        guard offset < data.count else { return nil }
        let marker = data[offset]
        offset += 1
        if marker == 0xD9 { return nil }
        if marker == 0x01 || (0xD0...0xD7).contains(marker) { continue }
        guard offset + 2 <= data.count else { return nil }
        let length = Int(data[offset]) << 8 | Int(data[offset + 1])
        guard length >= 2, offset + length <= data.count else { return nil }
        let range = (offset - 2)..<(offset + length)
        let payloadStart = offset + 2
        if marker == 0xE2,
            payloadStart + signature.count + 2 <= range.upperBound,
            data[payloadStart..<(payloadStart + signature.count)].elementsEqual(signature)
        {
            return JPEGICCProfileSegment(
                range: range,
                sequenceIndex: payloadStart + signature.count,
                countIndex: payloadStart + signature.count + 1
            )
        }
        offset += length
    }
    return nil
}

private func makeColorManagedJPEG(
    width: Int = 32,
    height: Int = 16,
    colorSpace: CGColorSpace
) throws -> Data {
    let bytesPerRow = width * 4
    var bytes = Data(capacity: bytesPerRow * height)
    for index in 0..<(width * height) {
        bytes.append(UInt8((index * 17) & 0xFF))
        bytes.append(UInt8((index * 31) & 0xFF))
        bytes.append(UInt8((index * 47) & 0xFF))
        bytes.append(255)
    }
    guard let provider = CGDataProvider(data: bytes as CFData),
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    else { throw ImageFixtureError.creationFailed }
    let output = NSMutableData()
    guard
        let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        )
    else { throw ImageFixtureError.creationFailed }
    CGImageDestinationAddImage(
        destination,
        image,
        [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else {
        throw ImageFixtureError.creationFailed
    }
    return output as Data
}

private func makeColorManagedPNG(
    width: Int = 16,
    height: Int = 8,
    colorSpace: CGColorSpace,
    rgba: (UInt8, UInt8, UInt8, UInt8) = (180, 90, 40, 255)
) throws -> Data {
    let bytesPerRow = width * 4
    var bytes = Data(capacity: bytesPerRow * height)
    for _ in 0..<(width * height) {
        bytes.append(rgba.0)
        bytes.append(rgba.1)
        bytes.append(rgba.2)
        bytes.append(rgba.3)
    }
    guard let provider = CGDataProvider(data: bytes as CFData),
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    else { throw ImageFixtureError.creationFailed }
    let output = NSMutableData()
    guard
        let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        )
    else { throw ImageFixtureError.creationFailed }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw ImageFixtureError.creationFailed }
    return output as Data
}

private func makeRawIndexed8PNG(
    width: Int,
    height: Int,
    indices: Data,
    palette: Data,
    alphaTable: Data?,
    includeSRGB: Bool,
    bitDepth: Int = 8
) throws -> Data {
    let paletteEntryCount = palette.count / 3
    guard width > 0, height > 0,
        [1, 2, 4, 8].contains(bitDepth),
        indices.count == width * height,
        palette.count >= 3,
        palette.count <= (1 << bitDepth) * 3,
        palette.count.isMultiple(of: 3),
        alphaTable == nil || alphaTable!.count <= paletteEntryCount,
        indices.allSatisfy({ Int($0) < (1 << bitDepth) }),
        let width32 = UInt32(exactly: width),
        let height32 = UInt32(exactly: height)
    else { throw ImageFixtureError.creationFailed }

    let rowBytes = (width * bitDepth + 7) / 8
    var filtered = Data(capacity: (rowBytes + 1) * height)
    for row in 0..<height {
        filtered.append(0)
        var packedRow = Data(repeating: 0, count: rowBytes)
        for column in 0..<width {
            let index = indices[row * width + column]
            if bitDepth == 8 {
                packedRow[column] = index
            } else {
                let bitOffset = column * bitDepth
                let byteOffset = bitOffset / 8
                let shift = 8 - bitDepth - (bitOffset % 8)
                packedRow[byteOffset] |= index << UInt8(shift)
            }
        }
        filtered.append(packedRow)
    }

    var ihdr = Data()
    ihdr.append(contentsOf: pngTestUInt32Bytes(width32))
    ihdr.append(contentsOf: pngTestUInt32Bytes(height32))
    ihdr.append(contentsOf: [UInt8(bitDepth), 3, 0, 0, 0])

    var png = Data([137, 80, 78, 71, 13, 10, 26, 10])
    png.append(try makePNGTestChunk(type: "IHDR", payload: ihdr))
    if includeSRGB {
        png.append(try makePNGTestChunk(type: "sRGB", payload: Data([0])))
    }
    png.append(try makePNGTestChunk(type: "PLTE", payload: palette))
    if let alphaTable {
        png.append(try makePNGTestChunk(type: "tRNS", payload: alphaTable))
    }
    png.append(
        try makePNGTestChunk(
            type: "IDAT",
            payload: RFC1950Zlib.deflate(filtered)
        )
    )
    png.append(try makePNGTestChunk(type: "IEND", payload: Data()))
    return png
}

private func makeRawGrayAlpha8PNG(
    width: Int,
    height: Int,
    straightGrayAlpha: Data,
    includeSRGB: Bool
) throws -> Data {
    guard width > 0, height > 0,
        straightGrayAlpha.count == width * height * 2,
        let width32 = UInt32(exactly: width),
        let height32 = UInt32(exactly: height)
    else { throw ImageFixtureError.creationFailed }

    let rowBytes = width * 2
    var filtered = Data(capacity: (rowBytes + 1) * height)
    for row in 0..<height {
        filtered.append(0)
        let start = row * rowBytes
        filtered.append(straightGrayAlpha[start..<(start + rowBytes)])
    }

    var ihdr = Data()
    ihdr.append(contentsOf: pngTestUInt32Bytes(width32))
    ihdr.append(contentsOf: pngTestUInt32Bytes(height32))
    ihdr.append(contentsOf: [8, 4, 0, 0, 0])

    var png = Data([137, 80, 78, 71, 13, 10, 26, 10])
    png.append(try makePNGTestChunk(type: "IHDR", payload: ihdr))
    if includeSRGB {
        png.append(try makePNGTestChunk(type: "sRGB", payload: Data([0])))
    }
    png.append(
        try makePNGTestChunk(
            type: "IDAT",
            payload: RFC1950Zlib.deflate(filtered)
        )
    )
    png.append(try makePNGTestChunk(type: "IEND", payload: Data()))
    return png
}

private func makeRawGray8PNG(
    width: Int,
    height: Int,
    straightGray: Data,
    includeSRGB: Bool,
    bitDepth: Int = 8
) throws -> Data {
    let maximumSample = (1 << bitDepth) - 1
    guard width > 0, height > 0,
        [1, 2, 4, 8].contains(bitDepth),
        straightGray.count == width * height,
        straightGray.allSatisfy({ Int($0) <= maximumSample }),
        let width32 = UInt32(exactly: width),
        let height32 = UInt32(exactly: height)
    else { throw ImageFixtureError.creationFailed }

    let rowBytes = (width * bitDepth + 7) / 8
    var filtered = Data(capacity: (rowBytes + 1) * height)
    for row in 0..<height {
        filtered.append(0)
        var packedRow = Data(repeating: 0, count: rowBytes)
        for column in 0..<width {
            let sample = straightGray[row * width + column]
            if bitDepth == 8 {
                packedRow[column] = sample
            } else {
                let bitOffset = column * bitDepth
                let byteOffset = bitOffset / 8
                let shift = 8 - bitDepth - (bitOffset % 8)
                packedRow[byteOffset] |= sample << UInt8(shift)
            }
        }
        filtered.append(packedRow)
    }

    var ihdr = Data()
    ihdr.append(contentsOf: pngTestUInt32Bytes(width32))
    ihdr.append(contentsOf: pngTestUInt32Bytes(height32))
    ihdr.append(contentsOf: [UInt8(bitDepth), 0, 0, 0, 0])

    var png = Data([137, 80, 78, 71, 13, 10, 26, 10])
    png.append(try makePNGTestChunk(type: "IHDR", payload: ihdr))
    if includeSRGB {
        png.append(try makePNGTestChunk(type: "sRGB", payload: Data([0])))
    }
    png.append(
        try makePNGTestChunk(
            type: "IDAT",
            payload: RFC1950Zlib.deflate(filtered)
        )
    )
    png.append(try makePNGTestChunk(type: "IEND", payload: Data()))
    return png
}

private func makeRawRGB8PNG(
    width: Int,
    height: Int,
    straightRGB: Data,
    includeSRGB: Bool
) throws -> Data {
    guard width > 0, height > 0,
        straightRGB.count == width * height * 3,
        let width32 = UInt32(exactly: width),
        let height32 = UInt32(exactly: height)
    else { throw ImageFixtureError.creationFailed }

    let rowBytes = width * 3
    var filtered = Data(capacity: (rowBytes + 1) * height)
    for row in 0..<height {
        filtered.append(0)
        let start = row * rowBytes
        filtered.append(straightRGB[start..<(start + rowBytes)])
    }

    var ihdr = Data()
    ihdr.append(contentsOf: pngTestUInt32Bytes(width32))
    ihdr.append(contentsOf: pngTestUInt32Bytes(height32))
    ihdr.append(contentsOf: [8, 2, 0, 0, 0])

    var png = Data([137, 80, 78, 71, 13, 10, 26, 10])
    png.append(try makePNGTestChunk(type: "IHDR", payload: ihdr))
    if includeSRGB {
        png.append(try makePNGTestChunk(type: "sRGB", payload: Data([0])))
    }
    png.append(
        try makePNGTestChunk(
            type: "IDAT",
            payload: RFC1950Zlib.deflate(filtered)
        )
    )
    png.append(try makePNGTestChunk(type: "IEND", payload: Data()))
    return png
}

private func makeRawRGBA8PNG(
    width: Int,
    height: Int,
    straightRGBA: Data,
    includeSRGB: Bool,
    embeddedICCProfile: Data? = nil,
    significantBits: [UInt8]? = nil,
    cicp: [UInt8]? = nil
) throws -> Data {
    guard width > 0, height > 0,
        straightRGBA.count == width * height * 4,
        !(includeSRGB && embeddedICCProfile != nil),
        significantBits == nil
          || (significantBits?.count == 4 && significantBits!.allSatisfy({ (1...8).contains($0) })),
        cicp == nil || cicp?.count == 4,
        let width32 = UInt32(exactly: width),
        let height32 = UInt32(exactly: height)
    else { throw ImageFixtureError.creationFailed }

    let rowBytes = width * 4
    var filtered = Data(capacity: (rowBytes + 1) * height)
    for row in 0..<height {
        filtered.append(0)
        let start = row * rowBytes
        filtered.append(straightRGBA[start..<(start + rowBytes)])
    }

    var ihdr = Data()
    ihdr.append(contentsOf: pngTestUInt32Bytes(width32))
    ihdr.append(contentsOf: pngTestUInt32Bytes(height32))
    ihdr.append(contentsOf: [8, 6, 0, 0, 0])

    var png = Data([137, 80, 78, 71, 13, 10, 26, 10])
    png.append(try makePNGTestChunk(type: "IHDR", payload: ihdr))
    if let cicp {
        png.append(try makePNGTestChunk(type: "cICP", payload: Data(cicp)))
    }
    if includeSRGB {
        png.append(try makePNGTestChunk(type: "sRGB", payload: Data([0])))
    }
    if let embeddedICCProfile {
        var payload = Data("ICC Profile".utf8)
        payload.append(0)
        payload.append(0)
        payload.append(try RFC1950Zlib.deflate(embeddedICCProfile))
        png.append(try makePNGTestChunk(type: "iCCP", payload: payload))
    }
    if let significantBits {
        png.append(try makePNGTestChunk(type: "sBIT", payload: Data(significantBits)))
    }
    png.append(
        try makePNGTestChunk(
            type: "IDAT",
            payload: RFC1950Zlib.deflate(filtered)
        )
    )
    png.append(try makePNGTestChunk(type: "IEND", payload: Data()))
    return png
}

private func makeRawRGB16PNG(
    width: Int,
    height: Int,
    samples: [UInt16],
    filters: [UInt8],
    splitIDAT: Int,
    includeSRGB: Bool,
    transparentRGB: (red: UInt16, green: UInt16, blue: UInt16)? = nil,
    significantBits: [UInt8]? = nil,
    embeddedICCProfile: Data? = nil,
    cicp: [UInt8]? = nil
) throws -> Data {
    guard width > 0, height > 0,
        samples.count == width * height * 3,
        !filters.isEmpty,
        filters.allSatisfy({ $0 <= 4 }),
        splitIDAT > 0,
        !(includeSRGB && embeddedICCProfile != nil),
        !(includeSRGB && cicp != nil),
        !(embeddedICCProfile != nil && cicp != nil),
        cicp == nil || cicp?.count == 4,
        significantBits == nil || (significantBits?.count == 3 && significantBits!.allSatisfy({ (1...16).contains($0) })),
        let width32 = UInt32(exactly: width),
        let height32 = UInt32(exactly: height)
    else { throw ImageFixtureError.creationFailed }

    let rowBytes = width * 6
    var sourceBigEndian = Data(capacity: width * height * 6)
    for sample in samples {
        sourceBigEndian.append(UInt8(truncatingIfNeeded: sample >> 8))
        sourceBigEndian.append(UInt8(truncatingIfNeeded: sample))
    }
    var filtered = Data(capacity: (rowBytes + 1) * height)
    var previous = [UInt8](repeating: 0, count: rowBytes)
    for row in 0..<height {
        let start = row * rowBytes
        let raw = Array(sourceBigEndian[start..<(start + rowBytes)])
        let filter = filters[row % filters.count]
        filtered.append(filter)
        filtered.append(
            contentsOf: pngTestFilteredRow(
                raw,
                previous: previous,
                bytesPerPixel: 6,
                filter: filter
            )
        )
        previous = raw
    }

    var ihdr = Data()
    ihdr.append(contentsOf: pngTestUInt32Bytes(width32))
    ihdr.append(contentsOf: pngTestUInt32Bytes(height32))
    ihdr.append(contentsOf: [16, 2, 0, 0, 0])

    var png = Data([137, 80, 78, 71, 13, 10, 26, 10])
    png.append(try makePNGTestChunk(type: "IHDR", payload: ihdr))
    if includeSRGB {
        png.append(try makePNGTestChunk(type: "sRGB", payload: Data([0])))
    } else if let embeddedICCProfile {
        var payload = Data("HighDepth RGB".utf8)
        payload.append(0)
        payload.append(0)
        payload.append(try RFC1950Zlib.deflate(embeddedICCProfile))
        png.append(try makePNGTestChunk(type: "iCCP", payload: payload))
    } else if let cicp {
        png.append(try makePNGTestChunk(type: "cICP", payload: Data(cicp)))
    }
    if let significantBits {
        png.append(try makePNGTestChunk(type: "sBIT", payload: Data(significantBits)))
    }
    if let transparentRGB {
        var payload = Data()
        for sample in [transparentRGB.red, transparentRGB.green, transparentRGB.blue] {
            payload.append(UInt8(truncatingIfNeeded: sample >> 8))
            payload.append(UInt8(truncatingIfNeeded: sample))
        }
        png.append(try makePNGTestChunk(type: "tRNS", payload: payload))
    }
    let compressed = try RFC1950Zlib.deflate(filtered)
    let pieceCount = min(splitIDAT, max(1, compressed.count))
    for piece in 0..<pieceCount {
        let lower = compressed.count * piece / pieceCount
        let upper = compressed.count * (piece + 1) / pieceCount
        png.append(
            try makePNGTestChunk(
                type: "IDAT",
                payload: Data(compressed[lower..<upper])
            )
        )
    }
    png.append(try makePNGTestChunk(type: "IEND", payload: Data()))
    return png
}

private func makeRawGrayscaleFamily16PNG(
    width: Int,
    height: Int,
    samples: [UInt16],
    colorType: UInt8,
    filters: [UInt8],
    splitIDAT: Int,
    includeSRGB: Bool,
    transparentGray: UInt16? = nil,
    significantBits: [UInt8]? = nil
) throws -> Data {
    let channelCount: Int
    switch colorType {
    case 0: channelCount = 1
    case 4: channelCount = 2
    default: throw ImageFixtureError.creationFailed
    }
    guard width > 0, height > 0,
        samples.count == width * height * channelCount,
        !filters.isEmpty,
        filters.allSatisfy({ $0 <= 4 }),
        splitIDAT > 0,
        transparentGray == nil || colorType == 0,
        significantBits == nil || (
            significantBits?.count == channelCount
            && significantBits!.allSatisfy({ (1...16).contains($0) })
        ),
        let width32 = UInt32(exactly: width),
        let height32 = UInt32(exactly: height)
    else { throw ImageFixtureError.creationFailed }

    let bytesPerPixel = channelCount * 2
    let rowBytes = width * bytesPerPixel
    let sourceBigEndian = uint16BigEndianTestData(samples)
    var filtered = Data(capacity: (rowBytes + 1) * height)
    var previous = [UInt8](repeating: 0, count: rowBytes)
    for row in 0..<height {
        let start = row * rowBytes
        let raw = Array(sourceBigEndian[start..<(start + rowBytes)])
        let filter = filters[row % filters.count]
        filtered.append(filter)
        filtered.append(
            contentsOf: pngTestFilteredRow(
                raw,
                previous: previous,
                bytesPerPixel: bytesPerPixel,
                filter: filter
            )
        )
        previous = raw
    }

    var ihdr = Data()
    ihdr.append(contentsOf: pngTestUInt32Bytes(width32))
    ihdr.append(contentsOf: pngTestUInt32Bytes(height32))
    ihdr.append(contentsOf: [16, colorType, 0, 0, 0])

    var png = Data([137, 80, 78, 71, 13, 10, 26, 10])
    png.append(try makePNGTestChunk(type: "IHDR", payload: ihdr))
    if includeSRGB {
        png.append(try makePNGTestChunk(type: "sRGB", payload: Data([0])))
    }
    if let significantBits {
        png.append(try makePNGTestChunk(type: "sBIT", payload: Data(significantBits)))
    }
    if let transparentGray {
        var payload = Data()
        payload.append(UInt8(truncatingIfNeeded: transparentGray >> 8))
        payload.append(UInt8(truncatingIfNeeded: transparentGray))
        png.append(try makePNGTestChunk(type: "tRNS", payload: payload))
    }
    let compressed = try RFC1950Zlib.deflate(filtered)
    let pieceCount = min(splitIDAT, max(1, compressed.count))
    for piece in 0..<pieceCount {
        let lower = compressed.count * piece / pieceCount
        let upper = compressed.count * (piece + 1) / pieceCount
        png.append(
            try makePNGTestChunk(
                type: "IDAT",
                payload: Data(compressed[lower..<upper])
            )
        )
    }
    png.append(try makePNGTestChunk(type: "IEND", payload: Data()))
    return png
}

private func grayscaleFamily16ToRGBA16LittleEndianTestData(
    _ samples: [UInt16],
    colorType: UInt8,
    transparentGray: UInt16? = nil
) -> Data {
    let channelCount = colorType == 0 ? 1 : 2
    precondition(colorType == 0 || colorType == 4)
    precondition(samples.count.isMultiple(of: channelCount))
    precondition(transparentGray == nil || colorType == 0)
    var result = Data(capacity: samples.count / channelCount * 8)
    var offset = 0
    while offset < samples.count {
        let gray = samples[offset]
        let alpha: UInt16
        if colorType == 0 {
            alpha = gray == transparentGray ? 0 : UInt16.max
        } else {
            alpha = samples[offset + 1]
        }
        for sample in [gray, gray, gray, alpha] {
            result.append(UInt8(truncatingIfNeeded: sample))
            result.append(UInt8(truncatingIfNeeded: sample >> 8))
        }
        offset += channelCount
    }
    return result
}

private func rgb16ToRGBA16LittleEndianTestData(
    _ samples: [UInt16],
    transparentRGB: (red: UInt16, green: UInt16, blue: UInt16)?
) -> Data {
    precondition(samples.count.isMultiple(of: 3))
    var result = Data(capacity: samples.count / 3 * 8)
    var offset = 0
    while offset < samples.count {
        let red = samples[offset]
        let green = samples[offset + 1]
        let blue = samples[offset + 2]
        let transparent = transparentRGB.map {
            red == $0.red && green == $0.green && blue == $0.blue
        } ?? false
        for sample in [red, green, blue, transparent ? UInt16(0) : UInt16.max] {
            result.append(UInt8(truncatingIfNeeded: sample))
            result.append(UInt8(truncatingIfNeeded: sample >> 8))
        }
        offset += 3
    }
    return result
}

private func makeRawRGBA16PNG(
    width: Int,
    height: Int,
    samples: [UInt16],
    filters: [UInt8],
    splitIDAT: Int,
    includeSRGB: Bool,
    interlace: UInt8 = 0,
    truncateFilteredTailByteCount: Int = 0,
    significantBits: [UInt8]? = nil,
    embeddedICCProfile: Data? = nil,
    cicp: [UInt8]? = nil
) throws -> Data {
    guard width > 0, height > 0,
        samples.count == width * height * 4,
        !filters.isEmpty,
        filters.allSatisfy({ $0 <= 4 }),
        splitIDAT > 0,
        !(includeSRGB && embeddedICCProfile != nil),
        !(includeSRGB && cicp != nil),
        !(embeddedICCProfile != nil && cicp != nil),
        cicp == nil || cicp?.count == 4,
        truncateFilteredTailByteCount >= 0,
        significantBits == nil || (significantBits?.count == 4 && significantBits!.allSatisfy({ (1...16).contains($0) })),
        let width32 = UInt32(exactly: width),
        let height32 = UInt32(exactly: height)
    else { throw ImageFixtureError.creationFailed }

    let rowBytes = width * 8
    var sourceBigEndian = Data(capacity: width * height * 8)
    for sample in samples {
        sourceBigEndian.append(UInt8(truncatingIfNeeded: sample >> 8))
        sourceBigEndian.append(UInt8(truncatingIfNeeded: sample))
    }
    var filtered = Data(capacity: (rowBytes + 1) * height)
    var previous = [UInt8](repeating: 0, count: rowBytes)
    for row in 0..<height {
        let start = row * rowBytes
        let raw = Array(sourceBigEndian[start..<(start + rowBytes)])
        let filter = filters[row % filters.count]
        filtered.append(filter)
        filtered.append(
            contentsOf: pngTestFilteredRow(
                raw,
                previous: previous,
                bytesPerPixel: 8,
                filter: filter
            )
        )
        previous = raw
    }
    guard truncateFilteredTailByteCount <= filtered.count else {
        throw ImageFixtureError.creationFailed
    }
    if truncateFilteredTailByteCount > 0 {
        filtered.removeLast(truncateFilteredTailByteCount)
    }

    var ihdr = Data()
    ihdr.append(contentsOf: pngTestUInt32Bytes(width32))
    ihdr.append(contentsOf: pngTestUInt32Bytes(height32))
    ihdr.append(contentsOf: [16, 6, 0, 0, interlace])

    var png = Data([137, 80, 78, 71, 13, 10, 26, 10])
    png.append(try makePNGTestChunk(type: "IHDR", payload: ihdr))
    if includeSRGB {
        png.append(try makePNGTestChunk(type: "sRGB", payload: Data([0])))
    } else if let cicp {
        png.append(try makePNGTestChunk(type: "cICP", payload: Data(cicp)))
    }
    if let significantBits {
        png.append(try makePNGTestChunk(type: "sBIT", payload: Data(significantBits)))
    }
    if let embeddedICCProfile {
        var payload = Data("HighDepth RGB".utf8)
        payload.append(0)
        payload.append(0)
        payload.append(try RFC1950Zlib.deflate(embeddedICCProfile))
        png.append(try makePNGTestChunk(type: "iCCP", payload: payload))
    }
    let compressed = try RFC1950Zlib.deflate(filtered)
    let pieceCount = min(splitIDAT, max(1, compressed.count))
    for piece in 0..<pieceCount {
        let lower = compressed.count * piece / pieceCount
        let upper = compressed.count * (piece + 1) / pieceCount
        png.append(
            try makePNGTestChunk(
                type: "IDAT",
                payload: Data(compressed[lower..<upper])
            )
        )
    }
    png.append(try makePNGTestChunk(type: "IEND", payload: Data()))
    return png
}

private func uint16BigEndianTestData(_ samples: [UInt16]) -> Data {
    var result = Data(capacity: samples.count * 2)
    for sample in samples {
        result.append(UInt8(truncatingIfNeeded: sample >> 8))
        result.append(UInt8(truncatingIfNeeded: sample))
    }
    return result
}

private func rgba16BigEndianTestData(_ samples: [UInt16]) -> Data {
    uint16BigEndianTestData(samples)
}

private func rgba16LittleEndianTestData(_ samples: [UInt16]) -> Data {
    var result = Data(capacity: samples.count * 2)
    for sample in samples {
        result.append(UInt8(truncatingIfNeeded: sample))
        result.append(UInt8(truncatingIfNeeded: sample >> 8))
    }
    return result
}

private enum PNGTestICCTransferCurve {
    case curveIdentity
    case curveGamma(raw: UInt16)
    case curveSamples([UInt16])
    case type0(gamma: Int32)
    case type1(gamma: Int32, a: Int32, b: Int32)
    case type2(gamma: Int32, a: Int32, b: Int32, c: Int32)
    case type3(gamma: Int32, a: Int32, b: Int32, c: Int32, d: Int32)
    case type4(gamma: Int32, a: Int32, b: Int32, c: Int32, d: Int32, e: Int32, f: Int32)
}

private func makeDeterministicMatrixTRCICCProfile(
    redXYZ: (Int32, Int32, Int32),
    greenXYZ: (Int32, Int32, Int32),
    blueXYZ: (Int32, Int32, Int32),
    trc: PNGTestICCTransferCurve,
    greenTRC: PNGTestICCTransferCurve? = nil,
    blueTRC: PNGTestICCTransferCurve? = nil,
    profileClass: String = "mntr",
    mediaWhiteXYZ: (Int32, Int32, Int32)? = nil
) -> Data {
    precondition(profileClass.utf8.count == 4)
    let d50: (Int32, Int32, Int32) = (63_190, 65_536, 54_061)

    func int32Data(_ value: Int32) -> Data {
        Data(pngTestUInt32Bytes(UInt32(bitPattern: value)))
    }

    func xyzPayload(_ value: (Int32, Int32, Int32)) -> Data {
        var payload = Data("XYZ ".utf8)
        payload.append(Data(repeating: 0, count: 4))
        payload.append(int32Data(value.0))
        payload.append(int32Data(value.1))
        payload.append(int32Data(value.2))
        return payload
    }

    func trcPayload(_ value: PNGTestICCTransferCurve) -> Data {
        switch value {
        case .curveIdentity:
            var payload = Data("curv".utf8)
            payload.append(Data(repeating: 0, count: 4))
            payload.append(contentsOf: pngTestUInt32Bytes(0))
            return payload
        case .curveGamma(let raw):
            var payload = Data("curv".utf8)
            payload.append(Data(repeating: 0, count: 4))
            payload.append(contentsOf: pngTestUInt32Bytes(1))
            payload.append(UInt8(raw >> 8))
            payload.append(UInt8(truncatingIfNeeded: raw))
            return payload
        case .curveSamples(let samples):
            var payload = Data("curv".utf8)
            payload.append(Data(repeating: 0, count: 4))
            payload.append(contentsOf: pngTestUInt32Bytes(UInt32(samples.count)))
            for sample in samples {
                payload.append(UInt8(sample >> 8))
                payload.append(UInt8(truncatingIfNeeded: sample))
            }
            return payload
        case .type0(let gamma):
            var payload = Data("para".utf8)
            payload.append(Data(repeating: 0, count: 4))
            payload.append(contentsOf: [0, 0, 0, 0])
            payload.append(int32Data(gamma))
            return payload
        case .type1(let gamma, let a, let b):
            var payload = Data("para".utf8)
            payload.append(Data(repeating: 0, count: 4))
            payload.append(contentsOf: [0, 1, 0, 0])
            payload.append(int32Data(gamma))
            payload.append(int32Data(a))
            payload.append(int32Data(b))
            return payload
        case .type2(let gamma, let a, let b, let c):
            var payload = Data("para".utf8)
            payload.append(Data(repeating: 0, count: 4))
            payload.append(contentsOf: [0, 2, 0, 0])
            payload.append(int32Data(gamma))
            payload.append(int32Data(a))
            payload.append(int32Data(b))
            payload.append(int32Data(c))
            return payload
        case .type3(let gamma, let a, let b, let c, let d):
            var payload = Data("para".utf8)
            payload.append(Data(repeating: 0, count: 4))
            payload.append(contentsOf: [0, 3, 0, 0])
            payload.append(int32Data(gamma))
            payload.append(int32Data(a))
            payload.append(int32Data(b))
            payload.append(int32Data(c))
            payload.append(int32Data(d))
            return payload
        case .type4(let gamma, let a, let b, let c, let d, let e, let f):
            var payload = Data("para".utf8)
            payload.append(Data(repeating: 0, count: 4))
            payload.append(contentsOf: [0, 4, 0, 0])
            payload.append(int32Data(gamma))
            payload.append(int32Data(a))
            payload.append(int32Data(b))
            payload.append(int32Data(c))
            payload.append(int32Data(d))
            payload.append(int32Data(e))
            payload.append(int32Data(f))
            return payload
        }
    }

    let whitePayload = xyzPayload(mediaWhiteXYZ ?? d50)
    let redPayload = xyzPayload(redXYZ)
    let greenPayload = xyzPayload(greenXYZ)
    let bluePayload = xyzPayload(blueXYZ)
    let redTRCPayload = trcPayload(trc)
    let greenTRCPayload = trcPayload(greenTRC ?? trc)
    let blueTRCPayload = trcPayload(blueTRC ?? trc)
    let usesSharedTRCPayload = greenTRC == nil && blueTRC == nil

    func paddedByteCount(_ payload: Data) -> Int {
        (payload.count + 3) & ~3
    }

    let tableEnd = 132 + 7 * 12
    let whiteOffset = tableEnd
    let redOffset = whiteOffset + whitePayload.count
    let greenOffset = redOffset + redPayload.count
    let blueOffset = greenOffset + greenPayload.count
    let redTRCOffset = blueOffset + bluePayload.count
    let greenTRCOffset: Int
    let blueTRCOffset: Int
    let totalByteCount: Int
    if usesSharedTRCPayload {
        greenTRCOffset = redTRCOffset
        blueTRCOffset = redTRCOffset
        totalByteCount = redTRCOffset + paddedByteCount(redTRCPayload)
    } else {
        greenTRCOffset = redTRCOffset + paddedByteCount(redTRCPayload)
        blueTRCOffset = greenTRCOffset + paddedByteCount(greenTRCPayload)
        totalByteCount = blueTRCOffset + paddedByteCount(blueTRCPayload)
    }

    var header = Data(repeating: 0, count: 128)
    header.replaceSubrange(0..<4, with: pngTestUInt32Bytes(UInt32(totalByteCount)))
    header.replaceSubrange(8..<12, with: pngTestUInt32Bytes(0x0210_0000))
    header.replaceSubrange(12..<16, with: Data(profileClass.utf8))
    header.replaceSubrange(16..<20, with: Data("RGB ".utf8))
    header.replaceSubrange(20..<24, with: Data("XYZ ".utf8))
    header.replaceSubrange(36..<40, with: Data("acsp".utf8))
    header.replaceSubrange(64..<68, with: pngTestUInt32Bytes(1))
    header.replaceSubrange(68..<80, with: xyzPayload(d50)[8..<20])
    header.replaceSubrange(80..<84, with: Data("IMGC".utf8))

    var profile = header
    profile.append(contentsOf: pngTestUInt32Bytes(7))
    let entries: [(String, Int, Int)] = [
        ("wtpt", whiteOffset, whitePayload.count),
        ("rXYZ", redOffset, redPayload.count),
        ("gXYZ", greenOffset, greenPayload.count),
        ("bXYZ", blueOffset, bluePayload.count),
        ("rTRC", redTRCOffset, redTRCPayload.count),
        ("gTRC", greenTRCOffset, greenTRCPayload.count),
        ("bTRC", blueTRCOffset, blueTRCPayload.count),
    ]
    for (signature, offset, size) in entries {
        profile.append(Data(signature.utf8))
        profile.append(contentsOf: pngTestUInt32Bytes(UInt32(offset)))
        profile.append(contentsOf: pngTestUInt32Bytes(UInt32(size)))
    }
    profile.append(whitePayload)
    profile.append(redPayload)
    profile.append(greenPayload)
    profile.append(bluePayload)
    profile.append(redTRCPayload)
    profile.append(Data(repeating: 0, count: paddedByteCount(redTRCPayload) - redTRCPayload.count))
    if !usesSharedTRCPayload {
        profile.append(greenTRCPayload)
        profile.append(Data(repeating: 0, count: paddedByteCount(greenTRCPayload) - greenTRCPayload.count))
        profile.append(blueTRCPayload)
        profile.append(Data(repeating: 0, count: paddedByteCount(blueTRCPayload) - blueTRCPayload.count))
    }
    return profile
}

private let adam7TestGeometry: [(xStart: Int, yStart: Int, xStep: Int, yStep: Int)] = [
    (0, 0, 8, 8),
    (4, 0, 8, 8),
    (0, 4, 4, 8),
    (2, 0, 4, 4),
    (0, 2, 2, 4),
    (1, 0, 2, 2),
    (0, 1, 1, 2),
]

private func makeRawAdam7PNG(
    width: Int,
    height: Int,
    straightPixels: Data,
    bytesPerPixel: Int,
    colorType: UInt8,
    includeSRGB: Bool,
    bitDepth: UInt8 = 8,
    significantBits: [UInt8]? = nil,
    grayscaleTransparency: UInt16? = nil,
    truecolorTransparency: (red: UInt16, green: UInt16, blue: UInt16)? = nil,
    embeddedICCProfile: Data? = nil,
    cicp: [UInt8]? = nil,
    truncateInflatedTailByteCount: Int = 0
) throws -> Data {
    let sourceLayoutIsValid =
        (bitDepth == 8 && bytesPerPixel == 3 && colorType == 2)
        || (bitDepth == 8 && bytesPerPixel == 4 && colorType == 6)
        || (bitDepth == 16 && bytesPerPixel == 2 && colorType == 0)
        || (bitDepth == 16 && bytesPerPixel == 4 && colorType == 4)
        || (bitDepth == 16 && bytesPerPixel == 6 && colorType == 2)
        || (bitDepth == 16 && bytesPerPixel == 8 && colorType == 6)
    let expectedSignificantBitCount: Int
    switch colorType {
    case 0: expectedSignificantBitCount = 1
    case 2: expectedSignificantBitCount = 3
    case 4: expectedSignificantBitCount = 2
    case 6: expectedSignificantBitCount = 4
    default: expectedSignificantBitCount = 0
    }
    let significantBitsIsValid = significantBits == nil || (
        significantBits?.count == expectedSignificantBitCount
        && significantBits!.allSatisfy { $0 > 0 && $0 <= bitDepth }
    )
    let transparencyIsValid =
        (grayscaleTransparency == nil || colorType == 0)
        && (truecolorTransparency == nil || colorType == 2)
        && !(grayscaleTransparency != nil && truecolorTransparency != nil)
    guard width > 0, height > 0,
        sourceLayoutIsValid,
        significantBitsIsValid,
        transparencyIsValid,
        !(includeSRGB && embeddedICCProfile != nil),
        !(includeSRGB && cicp != nil),
        !(embeddedICCProfile != nil && cicp != nil),
        cicp == nil || cicp?.count == 4,
        straightPixels.count == width * height * bytesPerPixel,
        truncateInflatedTailByteCount >= 0,
        let width32 = UInt32(exactly: width),
        let height32 = UInt32(exactly: height)
    else { throw ImageFixtureError.creationFailed }

    var filtered = Data()
    for (passIndex, geometry) in adam7TestGeometry.enumerated() {
        let passWidth = adam7TestSampleCount(
            fullCount: width,
            start: geometry.xStart,
            step: geometry.xStep
        )
        let passHeight = adam7TestSampleCount(
            fullCount: height,
            start: geometry.yStart,
            step: geometry.yStep
        )
        if passWidth == 0 || passHeight == 0 { continue }
        var previous = [UInt8](repeating: 0, count: passWidth * bytesPerPixel)
        for passRow in 0..<passHeight {
            let y = geometry.yStart + passRow * geometry.yStep
            var raw = [UInt8](repeating: 0, count: passWidth * bytesPerPixel)
            for passColumn in 0..<passWidth {
                let x = geometry.xStart + passColumn * geometry.xStep
                let sourceOffset = (y * width + x) * bytesPerPixel
                let rowOffset = passColumn * bytesPerPixel
                for channel in 0..<bytesPerPixel {
                    raw[rowOffset + channel] = straightPixels[sourceOffset + channel]
                }
            }
            let filter = UInt8((passIndex + passRow) % 5)
            filtered.append(filter)
            filtered.append(
                contentsOf: pngTestFilteredRow(
                    raw,
                    previous: previous,
                    bytesPerPixel: bytesPerPixel,
                    filter: filter
                )
            )
            previous = raw
        }
    }
    guard truncateInflatedTailByteCount <= filtered.count else {
        throw ImageFixtureError.creationFailed
    }
    if truncateInflatedTailByteCount > 0 {
        filtered.removeLast(truncateInflatedTailByteCount)
    }

    var ihdr = Data()
    ihdr.append(contentsOf: pngTestUInt32Bytes(width32))
    ihdr.append(contentsOf: pngTestUInt32Bytes(height32))
    ihdr.append(contentsOf: [bitDepth, colorType, 0, 0, 1])

    var png = Data([137, 80, 78, 71, 13, 10, 26, 10])
    png.append(try makePNGTestChunk(type: "IHDR", payload: ihdr))
    if includeSRGB {
        png.append(try makePNGTestChunk(type: "sRGB", payload: Data([0])))
    } else if let embeddedICCProfile {
        var payload = Data("HighDepth RGB".utf8)
        payload.append(0)
        payload.append(0)
        payload.append(try RFC1950Zlib.deflate(embeddedICCProfile))
        png.append(try makePNGTestChunk(type: "iCCP", payload: payload))
    } else if let cicp {
        png.append(try makePNGTestChunk(type: "cICP", payload: Data(cicp)))
    }
    if let significantBits {
        png.append(try makePNGTestChunk(type: "sBIT", payload: Data(significantBits)))
    }
    if let grayscaleTransparency {
        var payload = Data()
        payload.append(UInt8(truncatingIfNeeded: grayscaleTransparency >> 8))
        payload.append(UInt8(truncatingIfNeeded: grayscaleTransparency))
        png.append(try makePNGTestChunk(type: "tRNS", payload: payload))
    }
    if let truecolorTransparency {
        var payload = Data()
        for sample in [truecolorTransparency.red, truecolorTransparency.green, truecolorTransparency.blue] {
            payload.append(UInt8(truncatingIfNeeded: sample >> 8))
            payload.append(UInt8(truncatingIfNeeded: sample))
        }
        png.append(try makePNGTestChunk(type: "tRNS", payload: payload))
    }
    png.append(
        try makePNGTestChunk(
            type: "IDAT",
            payload: RFC1950Zlib.deflate(filtered)
        )
    )
    png.append(try makePNGTestChunk(type: "IEND", payload: Data()))
    return png
}

private func adam7TestSampleCount(fullCount: Int, start: Int, step: Int) -> Int {
    guard fullCount > start else { return 0 }
    return (fullCount - start + step - 1) / step
}

private func pngTestFilteredRow(
    _ raw: [UInt8],
    previous: [UInt8],
    bytesPerPixel: Int,
    filter: UInt8
) -> [UInt8] {
    precondition(raw.count == previous.count)
    var encoded = raw
    for index in raw.indices {
        let left = index >= bytesPerPixel ? raw[index - bytesPerPixel] : 0
        let above = previous[index]
        let upperLeft = index >= bytesPerPixel ? previous[index - bytesPerPixel] : 0
        let predictor: UInt8
        switch filter {
        case 0:
            predictor = 0
        case 1:
            predictor = left
        case 2:
            predictor = above
        case 3:
            predictor = UInt8((UInt16(left) + UInt16(above)) >> 1)
        case 4:
            predictor = adam7TestPaeth(left: left, above: above, upperLeft: upperLeft)
        default:
            preconditionFailure("invalid PNG test filter")
        }
        encoded[index] = raw[index] &- predictor
    }
    return encoded
}

private func adam7TestPaeth(left: UInt8, above: UInt8, upperLeft: UInt8) -> UInt8 {
    let a = Int(left)
    let b = Int(above)
    let c = Int(upperLeft)
    let p = a + b - c
    let pa = abs(p - a)
    let pb = abs(p - b)
    let pc = abs(p - c)
    if pa <= pb && pa <= pc { return left }
    if pb <= pc { return above }
    return upperLeft
}

private func premultipliedRGBA8TestData(_ straightRGBA: Data) -> Data {
    var output = straightRGBA
    output.withUnsafeMutableBytes { raw in
        let bytes = raw.bindMemory(to: UInt8.self)
        var offset = 0
        while offset + 3 < bytes.count {
            let alpha = UInt16(bytes[offset + 3])
            if alpha == 0 {
                bytes[offset] = 0
                bytes[offset + 1] = 0
                bytes[offset + 2] = 0
            } else if alpha != 255 {
                bytes[offset] = UInt8((UInt16(bytes[offset]) * alpha + 127) / 255)
                bytes[offset + 1] = UInt8((UInt16(bytes[offset + 1]) * alpha + 127) / 255)
                bytes[offset + 2] = UInt8((UInt16(bytes[offset + 2]) * alpha + 127) / 255)
            }
            offset += 4
        }
    }
    return output
}

private extension CFData {
    func bridgeToData() -> Data { self as Data }
}

private func removingPNGChunks(_ removedTypes: Set<String>, from data: Data) throws -> Data {
    guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
        throw ImageFixtureError.creationFailed
    }
    var result = Data(data.prefix(8))
    var offset = 8
    while offset + 12 <= data.count {
        let length =
            Int(data[offset]) << 24
            | Int(data[offset + 1]) << 16
            | Int(data[offset + 2]) << 8
            | Int(data[offset + 3])
        let end = offset + 12 + length
        guard end <= data.count,
            let type = String(data: data[(offset + 4)..<(offset + 8)], encoding: .ascii)
        else { throw ImageFixtureError.creationFailed }
        if !removedTypes.contains(type) {
            result.append(data[offset..<end])
        }
        offset = end
        if type == "IEND" { break }
    }
    guard offset <= data.count else { throw ImageFixtureError.creationFailed }
    return result
}

private func centerAlpha(of image: CGImage) throws -> Double {
    var pixel = [UInt8](repeating: 0, count: 4)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { throw ImageFixtureError.creationFailed }
    context.setBlendMode(.copy)
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return Double(pixel[3])
}

private func makePNGWithTextMetadata(payloadBytes: Int) throws -> Data {
    var data = try makePNG(width: 10, height: 10)
    let iendSignature = Data([0, 0, 0, 0, 73, 69, 78, 68])
    guard let iend = data.range(of: iendSignature)?.lowerBound else {
        throw ImageFixtureError.creationFailed
    }
    let chunk = try makePNGTestChunk(
        type: "tEXt",
        payload: Data(repeating: 65, count: payloadBytes)
    )
    data.insert(contentsOf: chunk, at: iend)
    return data
}

private struct PNGTestChunk {
    let start: Int
    let payloadStart: Int
    let payloadEnd: Int
    let end: Int
    let type: String
}

private func pngTestChunks(_ data: Data) throws -> [PNGTestChunk] {
    guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
        throw ImageFixtureError.creationFailed
    }
    var chunks: [PNGTestChunk] = []
    var offset = 8
    while offset + 12 <= data.count {
        let length =
            Int(data[offset]) << 24
            | Int(data[offset + 1]) << 16
            | Int(data[offset + 2]) << 8
            | Int(data[offset + 3])
        let payloadStart = offset + 8
        let payloadEnd = payloadStart + length
        let end = payloadEnd + 4
        guard end <= data.count,
            let type = String(data: data[(offset + 4)..<(offset + 8)], encoding: .ascii)
        else { throw ImageFixtureError.creationFailed }
        chunks.append(
            PNGTestChunk(
                start: offset,
                payloadStart: payloadStart,
                payloadEnd: payloadEnd,
                end: end,
                type: type
            )
        )
        offset = end
        if type == "IEND" { break }
    }
    guard offset == data.count else { throw ImageFixtureError.creationFailed }
    return chunks
}

private func makePNGTestChunk(type: String, payload: Data) throws -> Data {
    let typeBytes = Data(type.utf8)
    guard typeBytes.count == 4, payload.count <= Int(UInt32.max) else {
        throw ImageFixtureError.creationFailed
    }
    var chunk = Data()
    let length = UInt32(payload.count)
    chunk.append(contentsOf: pngTestUInt32Bytes(length))
    chunk.append(typeBytes)
    chunk.append(payload)
    let crc = pngTestCRC32(chunk, start: 4, count: typeBytes.count + payload.count)
    chunk.append(contentsOf: pngTestUInt32Bytes(crc))
    return chunk
}

private func rewritePNGTestChunkCRC(_ data: inout Data, chunk: PNGTestChunk) throws {
    guard chunk.start >= 0, chunk.payloadEnd + 4 <= data.count else {
        throw ImageFixtureError.creationFailed
    }
    let crc = pngTestCRC32(
        data,
        start: chunk.start + 4,
        count: chunk.payloadEnd - (chunk.start + 4)
    )
    data.replaceSubrange(
        chunk.payloadEnd..<(chunk.payloadEnd + 4),
        with: pngTestUInt32Bytes(crc)
    )
}

private let pngTestCRCTable: [UInt32] = (0..<256).map { value in
    var crc = UInt32(value)
    for _ in 0..<8 {
        crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0xEDB8_8320
    }
    return crc
}

private func pngTestCRC32(_ data: Data, start: Int, count: Int) -> UInt32 {
    var crc = UInt32.max
    for byte in data[start..<(start + count)] {
        let tableIndex = Int((crc ^ UInt32(byte)) & 0xFF)
        crc = pngTestCRCTable[tableIndex] ^ (crc >> 8)
    }
    return crc ^ UInt32.max
}

private func pngTestUInt32Bytes(_ value: UInt32) -> [UInt8] {
    [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF),
    ]
}

private func makeStaticGIF(width: Int, height: Int) throws -> Data {
    let image = try makeTestCGImage(width: width, height: height)
    let data = NSMutableData()
    guard
        let destination = CGImageDestinationCreateWithData(
            data,
            UTType.gif.identifier as CFString,
            1,
            nil
        )
    else { throw ImageFixtureError.creationFailed }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw ImageFixtureError.creationFailed }
    return data as Data
}

private func makeAnimatedGIF() throws -> Data {
    let image = try makeTestCGImage(width: 4, height: 4)
    let data = NSMutableData()
    guard
        let destination = CGImageDestinationCreateWithData(
            data,
            UTType.gif.identifier as CFString,
            2,
            nil
        )
    else { throw ImageFixtureError.creationFailed }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw ImageFixtureError.creationFailed }
    return data as Data
}

private func makeOrientedJPEG(
    width: Int,
    height: Int,
    orientation: UInt32
) throws -> Data {
    let image = try makeTestCGImage(width: width, height: height)
    let data = NSMutableData()
    guard
        let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        )
    else { throw ImageFixtureError.creationFailed }
    let properties = [kCGImagePropertyOrientation: orientation] as CFDictionary
    CGImageDestinationAddImage(destination, image, properties)
    guard CGImageDestinationFinalize(destination) else { throw ImageFixtureError.creationFailed }
    return data as Data
}

private func makeTestCGImage(width: Int, height: Int) throws -> CGImage {
    let bytesPerRow = width * 4
    let bytes = Data(repeating: 127, count: bytesPerRow * height)
    guard let provider = CGDataProvider(data: bytes as CFData),
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    else { throw ImageFixtureError.creationFailed }
    return image
}

private func normalizedRGBABytes(_ image: CGImage) throws -> Data {
    let bytesPerRow = image.width * 4
    var bytes = Data(repeating: 0, count: bytesPerRow * image.height)
    let drew = bytes.withUnsafeMutableBytes { rawBuffer -> Bool in
        guard let base = rawBuffer.baseAddress,
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: base,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return false }
        context.setBlendMode(.copy)
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        return true
    }
    guard drew else { throw ImageFixtureError.creationFailed }
    return bytes
}

private enum ImageFixtureError: Error {
    case creationFailed
}
