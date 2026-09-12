import CoreGraphics
import Foundation
import ImageCraftCore
import ImageCraftImageIO
import ImageIO
import XCTest

final class HDRFailClosedPublicTests: XCTestCase {
    func testExternalConsumerRejectsDirectHDRBehindStandardCapability_M6_CONSUMER_PT_001()
        throws
    {
        let destinationTypes = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
        guard destinationTypes.contains("public.heic") else {
            throw XCTSkip("current ImageIO runtime does not expose public.heic encoding")
        }

        let data = try makeDirectHDRHEIC()
        let decoder = ImageIOImageDecoder()
        let probe = try decoder.probe(data: data, limits: .coreV1)
        XCTAssertEqual(probe.format, .heif)

        XCTAssertThrowsError(
            try decoder.decode(
                data: data,
                probe: probe,
                request: ImageDecodeRequest(
                    target: try TargetPixels(width: 2, height: 1),
                    colorPolicy: .preserveSource
                ),
                limits: .coreV1
            )
        ) { error in
            XCTAssertEqual(
                error as? ImageCodecContractError,
                .unsupportedCapability(.dynamicRange(.high))
            )
        }
    }

    func testExternalConsumerCanExplicitlyPreserveDirectHDRHEIF_M6_CONSUMER_PT_002() throws {
        let destinationTypes = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
        let sourceTypes = Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])
        guard destinationTypes.contains("public.heic"),
            sourceTypes.contains("public.heic") || sourceTypes.contains("public.heif")
        else {
            throw XCTSkip("current ImageIO runtime does not expose HEIF direct-HDR qualification")
        }

        let data = try makeDirectHDRHEIC()
        let decoder = ImageIOImageDecoder()
        let probe = try decoder.probe(data: data, limits: .coreV1)
        XCTAssertTrue(
            decoder.codecDescriptor.supports(
                ImageDecodeCapabilityRequest(format: .heif, dynamicRange: .high)
            )
        )

        let image = try decoder.decode(
            data: data,
            probe: probe,
            request: ImageDecodeRequest(
                target: try TargetPixels(width: 2, height: 1),
                colorPolicy: .preserveSource,
                dynamicRange: .high
            ),
            limits: .coreV1
        )
        XCTAssertGreaterThan(image.pixelFormat.bitsPerComponent, 8)
        let colorSpace = try XCTUnwrap(image.cgImage.colorSpace)
        XCTAssertTrue(colorSpace.isHDR() || CGColorSpaceUsesExtendedRange(colorSpace))
        if #available(macOS 15.0, iOS 18.0, *) {
            XCTAssertGreaterThan(image.cgImage.contentHeadroom, 1)
        }

        XCTAssertThrowsError(
            try decoder.decode(
                data: data,
                probe: probe,
                request: ImageDecodeRequest(
                    target: try TargetPixels(width: 2, height: 1),
                    colorPolicy: .convertToSRGB,
                    dynamicRange: .high
                ),
                limits: .coreV1
            )
        ) { error in
            XCTAssertEqual(
                error as? ImageCodecContractError,
                .unsupportedCapability(.dynamicRange(.high))
            )
        }
    }
}

private func makeDirectHDRHEIC() throws -> Data {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.itur_2100_PQ) else {
        throw HDRFixtureError.creationFailed
    }
    guard
        let context = CGContext(
            data: nil,
            width: 2,
            height: 1,
            bitsPerComponent: 16,
            bytesPerRow: 16,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue
        )
    else { throw HDRFixtureError.creationFailed }
    context.setFillColor(red: 0.8, green: 0.5, blue: 0.2, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 2, height: 1))
    guard let image = context.makeImage(), image.colorSpace?.isHDR() == true else {
        throw HDRFixtureError.creationFailed
    }

    let output = NSMutableData()
    guard
        let destination = CGImageDestinationCreateWithData(
            output,
            "public.heic" as CFString,
            1,
            nil
        )
    else { throw HDRFixtureError.creationFailed }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw HDRFixtureError.creationFailed
    }
    return output as Data
}

private enum HDRFixtureError: Error {
    case creationFailed
}
