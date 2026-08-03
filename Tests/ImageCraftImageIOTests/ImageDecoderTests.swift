import CoreGraphics
import Foundation
import ImageCraftCore
import ImageCraftImageIO
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class ImageDecoderTests: XCTestCase {
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
        let data = try removingPNGChunks(["iCCP", "sRGB", "gAMA", "cHRM"], from: tagged)
        let decoder = ImageIOImageDecoder()
        let target = try TargetPixels(width: 16, height: 8)
        let first = try decoder.decode(data: data, target: target)
        let second = try decoder.decode(data: data, target: target)

        XCTAssertEqual(first.colorDescription.sourceProfile, .absent)
        XCTAssertEqual(first.colorDescription.outputColorSpaceName, CGColorSpace.sRGB as String)
        XCTAssertEqual(second.colorDescription, first.colorDescription)
    }

    func testDownsamplePreservesEmbeddedP3Description_IMG_PT_006() throws {
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

        XCTAssertEqual(probe.sourceColorProfile, .embeddedICC)
        XCTAssertEqual(decoded.colorDescription.sourceProfile, .embeddedICC)
        XCTAssertEqual(
            decoded.colorDescription.outputColorSpaceName,
            CGColorSpace.displayP3 as String
        )
        XCTAssertEqual(decoded.pixelWidth, 16)
        XCTAssertEqual(decoded.pixelHeight, 8)
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
        XCTAssertEqual(result.diagnostics.sourceCreationNanoseconds, 0)
        XCTAssertEqual(result.diagnostics.sourceTypeNanoseconds, 0)
        XCTAssertEqual(result.diagnostics.frameCountNanoseconds, 0)
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

    func testImageIOCodecDescriptorAdvertisesOnlyCurrentSemantics() {
        let descriptor = ImageIOImageDecoder().codecDescriptor
        XCTAssertEqual(descriptor.identifier.rawValue, "dev.fovea.imageio")
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
    var chunk = Data()
    let length = UInt32(payloadBytes).bigEndian
    withUnsafeBytes(of: length) { chunk.append(contentsOf: $0) }
    chunk.append(contentsOf: Data("tEXt".utf8))
    chunk.append(Data(repeating: 65, count: payloadBytes))
    chunk.append(Data(repeating: 0, count: 4))
    data.insert(contentsOf: chunk, at: iend)
    return data
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

private enum ImageFixtureError: Error {
    case creationFailed
}
