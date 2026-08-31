import Foundation
import ImageCraftCore
import XCTest

final class ImagePackedPixelBufferTests: XCTestCase {
    func testPackedPixelFormatSeparatesPrecisionAlphaAndByteOrder() throws {
        XCTAssertNil(
            ImagePackedPixelFormat(
                sampleStorage: .uint8,
                channelLayout: .rgb,
                alphaAssociation: .premultiplied,
                multibyteByteOrder: nil
            )
        )
        XCTAssertNil(
            ImagePackedPixelFormat(
                sampleStorage: .uint8,
                channelLayout: .rgba,
                alphaAssociation: .none,
                multibyteByteOrder: nil
            )
        )
        XCTAssertNil(
            ImagePackedPixelFormat(
                sampleStorage: .uint8,
                channelLayout: .rgba,
                alphaAssociation: .premultiplied,
                multibyteByteOrder: .littleEndian
            )
        )
        XCTAssertNil(
            ImagePackedPixelFormat(
                sampleStorage: .uint16,
                channelLayout: .rgba,
                alphaAssociation: .straight,
                multibyteByteOrder: nil
            )
        )

        XCTAssertEqual(ImagePackedPixelFormat.rgb8.bytesPerPixel, 3)
        XCTAssertEqual(ImagePackedPixelFormat.rgb8.sampleStorage, .uint8)
        XCTAssertEqual(ImagePackedPixelFormat.rgb8.channelLayout, .rgb)
        XCTAssertEqual(ImagePackedPixelFormat.rgb8.alphaAssociation, .none)
        XCTAssertNil(ImagePackedPixelFormat.rgb8.multibyteByteOrder)

        XCTAssertEqual(ImagePackedPixelFormat.rgba8Premultiplied.bytesPerPixel, 4)
        XCTAssertEqual(ImagePackedPixelFormat.rgba8Premultiplied.sampleStorage, .uint8)
        XCTAssertEqual(ImagePackedPixelFormat.rgba8Premultiplied.alphaAssociation, .premultiplied)
        XCTAssertNil(ImagePackedPixelFormat.rgba8Premultiplied.multibyteByteOrder)

        XCTAssertEqual(ImagePackedPixelFormat.rgba16StraightLittleEndian.bytesPerPixel, 8)
        XCTAssertEqual(ImagePackedPixelFormat.rgba16StraightLittleEndian.sampleStorage, .uint16)
        XCTAssertEqual(ImagePackedPixelFormat.rgba16StraightLittleEndian.alphaAssociation, .straight)
        XCTAssertEqual(
            ImagePackedPixelFormat.rgba16StraightLittleEndian.multibyteByteOrder,
            .littleEndian
        )
    }

    func testPackedPixelFormatCodableRevalidatesInvariants() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let roundTrip = try decoder.decode(
            ImagePackedPixelFormat.self,
            from: encoder.encode(ImagePackedPixelFormat.rgba16StraightLittleEndian)
        )
        XCTAssertEqual(roundTrip, .rgba16StraightLittleEndian)

        let invalidUInt8 = Data(
            #"{"sampleStorage":"uint8","channelLayout":"rgba","alphaAssociation":"premultiplied","multibyteByteOrder":"littleEndian"}"#.utf8
        )
        XCTAssertThrowsError(try decoder.decode(ImagePackedPixelFormat.self, from: invalidUInt8))

        let invalidUInt16 = Data(
            #"{"sampleStorage":"uint16","channelLayout":"rgba","alphaAssociation":"straight"}"#.utf8
        )
        XCTAssertThrowsError(try decoder.decode(ImagePackedPixelFormat.self, from: invalidUInt16))

        let invalidRGBAlpha = Data(
            #"{"sampleStorage":"uint8","channelLayout":"rgb","alphaAssociation":"straight"}"#.utf8
        )
        XCTAssertThrowsError(try decoder.decode(ImagePackedPixelFormat.self, from: invalidRGBAlpha))

        let rgbRoundTrip = try decoder.decode(
            ImagePackedPixelFormat.self,
            from: encoder.encode(ImagePackedPixelFormat.rgb8)
        )
        XCTAssertEqual(rgbRoundTrip, .rgb8)
    }

    func testRGB8ValueDoesNotSynthesizeAlphaAndKeepsColorOrthogonal() throws {
        let bytes = Data([10, 20, 30, 40, 50, 60])
        let value = try XCTUnwrap(
            ImagePackedRGB8(
                data: bytes,
                pixelWidth: 2,
                pixelHeight: 1,
                colorEncoding: .sRGB,
                sourceColorProfile: .absent
            )
        )
        XCTAssertEqual(value.format, .rgb8)
        XCTAssertEqual(value.format.channelLayout, .rgb)
        XCTAssertEqual(value.format.alphaAssociation, .none)
        XCTAssertEqual(value.bytesPerRow, 6)
        XCTAssertEqual(value.pixelByteCharge, 6)
        XCTAssertEqual(value.transferredByteCharge, 6)
        XCTAssertEqual(value.colorEncoding, .sRGB)
        XCTAssertEqual(value.sourceColorProfile, .absent)
        XCTAssertEqual(value.data, bytes)
        XCTAssertNil(
            ImagePackedRGB8(
                data: Data([10, 20, 30, 40]),
                pixelWidth: 1,
                pixelHeight: 1,
                colorEncoding: .sRGB,
                sourceColorProfile: .absent
            )
        )
    }

    func testExistingRGBA8ValuePublishesItsExistingFormatWithoutChangingLayout() throws {
        let bytes = Data([10, 20, 30, 40, 50, 60, 70, 80])
        let value = try XCTUnwrap(
            ImagePackedRGBA8(
                data: bytes,
                pixelWidth: 2,
                pixelHeight: 1,
                colorEncoding: .sRGB,
                sourceColorProfile: .standardSRGB
            )
        )

        XCTAssertEqual(value.format, .rgba8Premultiplied)
        XCTAssertEqual(value.bytesPerRow, 8)
        XCTAssertEqual(value.pixelByteCharge, 8)
        XCTAssertEqual(value.transferredByteCharge, 8)
        XCTAssertEqual(value.data, bytes)
    }

    func testRGBA16SourceSignificantBitsValidateActualSourceChannelProvenance() throws {
        XCTAssertNil(
            ImagePackedSourceSignificantBits(
                sampleBitDepth: 16,
                channels: .rgb(red: 0, green: 16, blue: 16)
            )
        )
        XCTAssertNil(
            ImagePackedSourceSignificantBits(
                sampleBitDepth: 16,
                channels: .grayscale(gray: 17)
            )
        )

        let rgb = try XCTUnwrap(
            ImagePackedSourceSignificantBits(
                sampleBitDepth: 16,
                channels: .rgb(red: 10, green: 12, blue: 14)
            )
        )
        XCTAssertFalse(rgb.sourceHasStoredAlpha)
        XCTAssertEqual(rgb.red, 10)
        XCTAssertNil(rgb.gray)

        let rgba = try XCTUnwrap(
            ImagePackedSourceSignificantBits(
                sampleBitDepth: 16,
                channels: .rgba(red: 12, green: 13, blue: 14, alpha: 15)
            )
        )
        XCTAssertTrue(rgba.sourceHasStoredAlpha)
        XCTAssertEqual(rgba.alpha, 15)

        let grayscale = try XCTUnwrap(
            ImagePackedSourceSignificantBits(
                sampleBitDepth: 16,
                channels: .grayscale(gray: 11)
            )
        )
        XCTAssertFalse(grayscale.sourceHasStoredAlpha)
        XCTAssertEqual(grayscale.gray, 11)
        XCTAssertNil(grayscale.red)

        let grayscaleAlpha = try XCTUnwrap(
            ImagePackedSourceSignificantBits(
                sampleBitDepth: 16,
                channels: .grayscaleAlpha(gray: 12, alpha: 14)
            )
        )
        XCTAssertTrue(grayscaleAlpha.sourceHasStoredAlpha)
        XCTAssertEqual(grayscaleAlpha.gray, 12)
        XCTAssertEqual(grayscaleAlpha.alpha, 14)

        let bytes = Data(repeating: 0xA5, count: 8)
        let value = try XCTUnwrap(
            ImagePackedRGBA16Straight(
                data: bytes,
                pixelWidth: 1,
                pixelHeight: 1,
                colorEncoding: .sRGB,
                sourceColorProfile: .standardSRGB,
                sourceSignificantBits: grayscale
            )
        )
        XCTAssertEqual(value.sourceSignificantBits, grayscale)
        XCTAssertEqual(value.data, bytes)
        XCTAssertEqual(value.transferredByteCharge, bytes.count)

        let wrongDepth = try XCTUnwrap(
            ImagePackedSourceSignificantBits(
                sampleBitDepth: 8,
                channels: .rgba(red: 8, green: 8, blue: 8, alpha: 8)
            )
        )
        XCTAssertNil(
            ImagePackedRGBA16Straight(
                data: bytes,
                pixelWidth: 1,
                pixelHeight: 1,
                colorEncoding: .sRGB,
                sourceColorProfile: .standardSRGB,
                sourceSignificantBits: wrongDepth
            )
        )
    }

    func testCICPColorEncodingPreservesRawAuthorityWithoutPayloadCharge() throws {
        XCTAssertNil(
            ImagePackedCICPColorEncoding(
                colorPrimaries: 12,
                transferFunction: 13,
                matrixCoefficients: 1,
                videoFullRangeFlag: 1
            )
        )
        XCTAssertNil(
            ImagePackedCICPColorEncoding(
                colorPrimaries: 12,
                transferFunction: 13,
                matrixCoefficients: 0,
                videoFullRangeFlag: 2
            )
        )

        for tuple: (UInt8, UInt8) in [(12, 13), (9, 16), (9, 18)] {
            let cicp = try XCTUnwrap(
                ImagePackedCICPColorEncoding(
                    colorPrimaries: tuple.0,
                    transferFunction: tuple.1,
                    matrixCoefficients: 0,
                    videoFullRangeFlag: 1
                )
            )
            XCTAssertTrue(cicp.isFullRange)
            XCTAssertEqual(ImagePackedPixelColorEncoding.cicp(cicp).retainedByteCharge, 0)
            let bytes = Data(repeating: 0x5A, count: 8)
            let value = try XCTUnwrap(
                ImagePackedRGBA16Straight(
                    data: bytes,
                    pixelWidth: 1,
                    pixelHeight: 1,
                    colorEncoding: .cicp(cicp),
                    sourceColorProfile: .unknown
                )
            )
            XCTAssertEqual(value.data, bytes)
            XCTAssertEqual(value.transferredByteCharge, bytes.count)
            XCTAssertEqual(value.sourceColorProfile, .unknown)
        }
    }

    func testHDRStaticMetadataPreservesStoredIntegerUnitsWithoutPayloadCharge() throws {
        XCTAssertNil(
            ImagePackedMasteringDisplayColorVolume(
                redX: 35_400,
                redY: 14_600,
                greenX: 8_500,
                greenY: 39_850,
                blueX: 6_550,
                blueY: 2_300,
                whiteX: 15_635,
                whiteY: 16_450,
                maximumLuminanceScaledBy10000: 0x8000_0000,
                minimumLuminanceScaledBy10000: 5
            )
        )
        XCTAssertNil(
            ImagePackedContentLightLevel(
                maximumContentLightLevelScaledBy10000: 0,
                maximumFrameAverageLightLevelScaledBy10000: 0x8000_0000
            )
        )
        XCTAssertNil(
            ImagePackedHDRStaticMetadata(
                masteringDisplayColorVolume: nil,
                contentLightLevel: nil
            )
        )

        let mastering = try XCTUnwrap(
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
        let content = try XCTUnwrap(
            ImagePackedContentLightLevel(
                maximumContentLightLevelScaledBy10000: 10_000_000,
                maximumFrameAverageLightLevelScaledBy10000: 2_500_000
            )
        )
        let metadata = try XCTUnwrap(
            ImagePackedHDRStaticMetadata(
                masteringDisplayColorVolume: mastering,
                contentLightLevel: content
            )
        )
        let pq = try XCTUnwrap(
            ImagePackedCICPColorEncoding(
                colorPrimaries: 9,
                transferFunction: 16,
                matrixCoefficients: 0,
                videoFullRangeFlag: 1
            )
        )
        let bytes = Data(repeating: 0x6B, count: 8)
        let value = try XCTUnwrap(
            ImagePackedRGBA16Straight(
                data: bytes,
                pixelWidth: 1,
                pixelHeight: 1,
                colorEncoding: .cicp(pq),
                sourceColorProfile: .unknown,
                hdrStaticMetadata: metadata
            )
        )
        XCTAssertEqual(value.hdrStaticMetadata, metadata)
        XCTAssertEqual(value.transferredByteCharge, bytes.count)
        XCTAssertEqual(mastering.maximumLuminanceScaledBy10000, 40_000_000)
        XCTAssertEqual(content.maximumContentLightLevelScaledBy10000, 10_000_000)
    }

    func testRGBA16StraightValueIsExactLittleEndianAndValueBounded() throws {
        // R=0x1234, G=0xABCD, B=0x00FF, A=0x8000 followed by an opaque asymmetric pixel.
        let bytes = Data([
            0x34, 0x12, 0xCD, 0xAB, 0xFF, 0x00, 0x00, 0x80,
            0x01, 0x00, 0x00, 0x01, 0x02, 0x10, 0xFF, 0xFF,
        ])
        let icc = Data([1, 3, 5, 7, 9])
        let value = try XCTUnwrap(
            ImagePackedRGBA16Straight(
                data: bytes,
                pixelWidth: 2,
                pixelHeight: 1,
                colorEncoding: .embeddedICC(icc),
                sourceColorProfile: .embeddedICC
            )
        )

        XCTAssertEqual(value.format, .rgba16StraightLittleEndian)
        XCTAssertEqual(value.bytesPerRow, 16)
        XCTAssertEqual(value.pixelByteCharge, 16)
        XCTAssertEqual(value.transferredByteCharge, 21)
        XCTAssertEqual(value.data, bytes)
        XCTAssertEqual(value.data[0..<8], Data([0x34, 0x12, 0xCD, 0xAB, 0xFF, 0x00, 0x00, 0x80]))
    }

    func testRGBA16StraightRejectsAmbiguousOrOverflowingLayout() {
        XCTAssertNil(
            ImagePackedRGBA16Straight(
                data: Data(repeating: 0, count: 7),
                pixelWidth: 1,
                pixelHeight: 1,
                colorEncoding: .sRGB,
                sourceColorProfile: .standardSRGB
            )
        )
        XCTAssertNil(
            ImagePackedRGBA16Straight(
                data: Data(),
                pixelWidth: Int.max,
                pixelHeight: 2,
                colorEncoding: .sRGB,
                sourceColorProfile: .standardSRGB
            )
        )
        XCTAssertNil(
            ImagePackedRGBA16Straight(
                data: Data(),
                pixelWidth: 1,
                pixelHeight: 0,
                colorEncoding: .sRGB,
                sourceColorProfile: .standardSRGB
            )
        )
    }
}
