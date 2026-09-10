import CoreGraphics
import Foundation
import ImageCraftCore
import ImageCraftPDF
import XCTest

final class PDFRasterizerTests: XCTestCase {
    func testSinglePageProbeFitRenderAndResourceEstimate_M5_PDF_PT_001() throws {
        let data = try makePDF(width: 200, height: 100, pageCount: 1)
        let rasterizer = CoreGraphicsPDFRasterizer()
        let probe = try rasterizer.probe(data: data, limits: .coreV1)

        XCTAssertEqual(rasterizer.rasterizerDescriptor.contractVersion, 1)
        XCTAssertEqual(rasterizer.rasterizerDescriptor.implementationVersion, 1)
        XCTAssertEqual(probe.encodedByteCount, data.count)
        XCTAssertEqual(probe.pageBounds.minX, 0, accuracy: 0.001)
        XCTAssertEqual(probe.pageBounds.minY, 0, accuracy: 0.001)
        XCTAssertEqual(probe.pageBounds.width, 200, accuracy: 0.001)
        XCTAssertEqual(probe.pageBounds.height, 100, accuracy: 0.001)

        let request = PDFRasterizationRequest(
            target: try TargetPixels(width: 320, height: 320),
            contentMode: .fit
        )
        let estimate = try rasterizer.resourceEstimate(
            probe: probe,
            request: request,
            limits: .coreV1
        )
        XCTAssertEqual(estimate.workingSetBytes, 320 * 160 * 4 * 3)

        let image = try rasterizer.rasterize(
            data: data,
            probe: probe,
            request: request,
            limits: .coreV1
        )
        XCTAssertEqual(image.pixelWidth, 320)
        XCTAssertEqual(image.pixelHeight, 160)
        XCTAssertEqual(image.pixelFormat.bitsPerComponent, 8)
        XCTAssertEqual(image.pixelFormat.bitsPerPixel, 32)
        XCTAssertEqual(image.pixelFormat.bytesPerRow, 320 * 4)
        XCTAssertEqual(image.colorDescription.outputColorSpaceName, CGColorSpace.sRGB as String)
        XCTAssertEqual(image.alphaMode, .premultipliedLast)
        XCTAssertLessThanOrEqual(image.estimatedByteCost, estimate.workingSetBytes)

        let bytes = try rgbaBytes(image.cgImage)
        XCTAssertEqual(pixel(bytes, rowBytes: image.pixelFormat.bytesPerRow, x: 40, y: 80).a, 255)
        XCTAssertEqual(pixel(bytes, rowBytes: image.pixelFormat.bytesPerRow, x: 280, y: 80).a, 255)
    }

    func testFillRendersExactTargetAndCenterCropsPage_M5_PDF_PT_002() throws {
        let data = try makePDF(width: 200, height: 100, pageCount: 1)
        let rasterizer = CoreGraphicsPDFRasterizer()
        let probe = try rasterizer.probe(data: data, limits: .coreV1)
        let request = PDFRasterizationRequest(
            target: try TargetPixels(width: 100, height: 100),
            contentMode: .fill
        )

        let image = try rasterizer.rasterize(
            data: data,
            probe: probe,
            request: request,
            limits: .coreV1
        )
        XCTAssertEqual(image.pixelWidth, 100)
        XCTAssertEqual(image.pixelHeight, 100)

        let bytes = try rgbaBytes(image.cgImage)
        let left = pixel(bytes, rowBytes: image.pixelFormat.bytesPerRow, x: 10, y: 50)
        let right = pixel(bytes, rowBytes: image.pixelFormat.bytesPerRow, x: 90, y: 50)
        XCTAssertGreaterThan(left.r, left.b)
        XCTAssertGreaterThan(right.b, right.r)
        XCTAssertEqual(left.a, 255)
        XCTAssertEqual(right.a, 255)
    }

    func testEncryptedAndMultiplePagePDFsFailClosed_M5_PDF_PT_003() throws {
        let rasterizer = CoreGraphicsPDFRasterizer()

        let multiple = try makePDF(width: 200, height: 100, pageCount: 2)
        XCTAssertThrowsError(try rasterizer.probe(data: multiple, limits: .coreV1)) { error in
            XCTAssertEqual(error as? PDFRasterizationError, .multiplePagesUnsupported)
        }

        let encrypted = try makePDF(width: 200, height: 100, pageCount: 1, encrypted: true)
        XCTAssertThrowsError(try rasterizer.probe(data: encrypted, limits: .coreV1)) { error in
            XCTAssertEqual(error as? PDFRasterizationError, .encryptedDocumentUnsupported)
        }
    }

    func testLimitsProbeMismatchAndCorruptInputFailClosed_M5_PDF_PT_004() throws {
        let rasterizer = CoreGraphicsPDFRasterizer()
        let data = try makePDF(width: 200, height: 100, pageCount: 1)

        let encodedLimit = PDFRasterizationLimits(maximumEncodedBytes: data.count - 1)
        XCTAssertThrowsError(try rasterizer.probe(data: data, limits: encodedLimit)) { error in
            XCTAssertEqual(error as? PDFRasterizationError, .encodedBytesExceeded)
        }

        XCTAssertThrowsError(
            try rasterizer.probe(data: Data("%PDF-not-a-document".utf8), limits: .coreV1)
        ) { error in
            XCTAssertEqual(error as? PDFRasterizationError, .unsupportedOrCorruptDocument)
        }

        let probe = try rasterizer.probe(data: data, limits: .coreV1)
        let constrained = PDFRasterizationLimits(
            maximumTargetDimension: 64,
            maximumTargetPixelCount: 4_096
        )
        let oversizedRequest = PDFRasterizationRequest(
            target: try TargetPixels(width: 65, height: 32)
        )
        XCTAssertThrowsError(
            try rasterizer.resourceEstimate(
                probe: probe,
                request: oversizedRequest,
                limits: constrained
            )
        ) { error in
            XCTAssertEqual(error as? PDFRasterizationError, .targetDimensionExceeded)
        }

        let differentData = try makePDF(width: 100, height: 100, pageCount: 1)
        XCTAssertThrowsError(
            try rasterizer.rasterize(
                data: differentData,
                probe: probe,
                request: PDFRasterizationRequest(
                    target: try TargetPixels(width: 32, height: 32)
                ),
                limits: .coreV1
            )
        ) { error in
            XCTAssertEqual(error as? PDFRasterizationError, .probeMismatch)
        }
    }

    private func makePDF(
        width: CGFloat,
        height: CGFloat,
        pageCount: Int,
        encrypted: Bool = false
    ) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            XCTFail("CGDataConsumer creation failed")
            return Data()
        }
        var mediaBox = CGRect(x: 0, y: 0, width: width, height: height)
        var info: [CFString: Any] = [:]
        if encrypted {
            info[kCGPDFContextUserPassword] = "user"
            info[kCGPDFContextOwnerPassword] = "owner"
        }
        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &mediaBox,
            info as CFDictionary
        ) else {
            XCTFail("PDF context creation failed")
            return Data()
        }

        for _ in 0..<pageCount {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(
                CGRect(x: width / 2, y: 0, width: width - width / 2, height: height)
            )
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private func rgbaBytes(_ image: CGImage) throws -> [UInt8] {
        guard let data = image.dataProvider?.data else {
            throw PDFRasterizationError.renderFailed
        }
        return [UInt8](data as Data)
    }

    private func pixel(
        _ bytes: [UInt8],
        rowBytes: Int,
        x: Int,
        y: Int
    ) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let offset = y * rowBytes + x * 4
        return (
            bytes[offset],
            bytes[offset + 1],
            bytes[offset + 2],
            bytes[offset + 3]
        )
    }
}
