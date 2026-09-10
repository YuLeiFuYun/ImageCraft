import CoreGraphics
import Foundation
import ImageCraftCore
import ImageCraftSVG
import XCTest

final class SVGRasterizerTests: XCTestCase {
    func testStrictSubsetProbeFitRenderAndResourceEstimate_M5_SVG_PT_001() throws {
        let data = Data(
            """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 10" width="20" height="10">
              <rect x="0" y="0" width="10" height="10" fill="#ff0000"/>
              <path d="M10 0 L20 0 L20 10 L10 10 Z" fill="#0000ff"/>
            </svg>
            """.utf8
        )
        let rasterizer = CoreGraphicsSVGRasterizer()
        let probe = try rasterizer.probe(data: data, limits: .coreV1)
        XCTAssertEqual(rasterizer.rasterizerDescriptor.contractVersion, 1)
        XCTAssertEqual(rasterizer.rasterizerDescriptor.implementationVersion, 2)
        XCTAssertEqual(probe.viewBox.width, 20, accuracy: 0.001)
        XCTAssertEqual(probe.viewBox.height, 10, accuracy: 0.001)
        XCTAssertEqual(probe.elementCount, 3)
        XCTAssertEqual(probe.pathCommandCount, 5)

        let request = SVGRasterizationRequest(
            target: try TargetPixels(width: 40, height: 40),
            contentMode: .fit
        )
        let estimate = try rasterizer.resourceEstimate(
            probe: probe,
            request: request,
            limits: .coreV1
        )
        XCTAssertEqual(estimate.workingSetBytes, 40 * 20 * 4 * 3)

        let image = try rasterizer.rasterize(
            data: data,
            probe: probe,
            request: request,
            limits: .coreV1
        )
        XCTAssertEqual(image.pixelWidth, 40)
        XCTAssertEqual(image.pixelHeight, 20)
        XCTAssertEqual(image.pixelFormat.bitsPerComponent, 8)
        XCTAssertEqual(image.pixelFormat.bitsPerPixel, 32)
        XCTAssertLessThanOrEqual(image.estimatedByteCost, estimate.workingSetBytes)

        let bytes = try rgbaBytes(image.cgImage)
        let left = pixel(bytes, rowBytes: image.pixelFormat.bytesPerRow, x: 8, y: 10)
        let right = pixel(bytes, rowBytes: image.pixelFormat.bytesPerRow, x: 32, y: 10)
        XCTAssertGreaterThan(left.r, 240)
        XCTAssertLessThan(left.b, 16)
        XCTAssertEqual(left.a, 255)
        XCTAssertGreaterThan(right.b, 240)
        XCTAssertLessThan(right.r, 16)
        XCTAssertEqual(right.a, 255)
    }

    func testGroupFillRelativePathAndFillTarget_M5_SVG_PT_002() throws {
        let data = Data(
            """
            <svg viewBox="0 0 20 10" fill="#00ff00">
              <g fill-opacity="0.5">
                <path d="m0 0 h20 v10 h-20 z"/>
              </g>
            </svg>
            """.utf8
        )
        let rasterizer = CoreGraphicsSVGRasterizer()
        let probe = try rasterizer.probe(data: data, limits: .coreV1)
        XCTAssertEqual(probe.elementCount, 3)
        XCTAssertEqual(probe.pathCommandCount, 5)
        let request = SVGRasterizationRequest(
            target: try TargetPixels(width: 20, height: 20),
            contentMode: .fill
        )
        let image = try rasterizer.rasterize(
            data: data,
            probe: probe,
            request: request,
            limits: .coreV1
        )
        XCTAssertEqual(image.pixelWidth, 20)
        XCTAssertEqual(image.pixelHeight, 20)
        let bytes = try rgbaBytes(image.cgImage)
        let center = pixel(bytes, rowBytes: image.pixelFormat.bytesPerRow, x: 10, y: 10)
        XCTAssertLessThan(center.r, 4)
        XCTAssertGreaterThan(center.g, 120)
        XCTAssertLessThan(center.b, 4)
        XCTAssertTrue((126...129).contains(Int(center.a)))
    }

    func testUnsafeAndUnsupportedSVGFailClosed_M5_SVG_PT_003() throws {
        let rasterizer = CoreGraphicsSVGRasterizer()
        let unsafe = Data(
            "<!DOCTYPE svg [<!ENTITY xxe SYSTEM \"file:///etc/passwd\">]><svg viewBox=\"0 0 1 1\">&xxe;</svg>".utf8
        )
        XCTAssertThrowsError(try rasterizer.probe(data: unsafe, limits: .coreV1)) { error in
            XCTAssertEqual(error as? SVGRasterizationError, .unsafeMarkup)
        }
        let processingInstruction = Data(
            "<?xml-stylesheet href=\"https://example.invalid/style.css\"?><svg viewBox=\"0 0 1 1\"/>".utf8
        )
        XCTAssertThrowsError(
            try rasterizer.probe(data: processingInstruction, limits: .coreV1)
        ) { error in
            XCTAssertEqual(error as? SVGRasterizationError, .unsafeMarkup)
        }

        for source in [
            "<svg viewBox=\"0 0 1 1\"><script/></svg>",
            "<svg viewBox=\"0 0 1 1\"><rect width=\"1\" height=\"1\" style=\"fill:red\"/></svg>",
            "<svg viewBox=\"0 0 1 1\"><rect width=\"1\" height=\"1\" transform=\"scale(2)\"/></svg>",
            "<svg viewBox=\"0 0 1 1\"><rect width=\"1\" height=\"1\" stroke=\"red\"/></svg>",
            "<svg viewBox=\"0 0 1 1\"><rect width=\"1\" height=\"1\" fill=\"url(#paint)\"/></svg>",
            "<svg viewBox=\"0 0 1 1\"><use href=\"#shape\"/></svg>",
            "<svg viewBox=\"0 0 1 1\"><image href=\"https://example.invalid/a.png\"/></svg>",
            "<svg viewBox=\"0 0 1 1\"><text>secret</text></svg>",
            "<svg viewBox=\"0 0 1 1\"><path d=\"M0 0 A1 1 0 0 0 1 1\"/></svg>",
        ] {
            XCTAssertThrowsError(
                try rasterizer.probe(data: Data(source.utf8), limits: .coreV1)
            ) { error in
                XCTAssertEqual(error as? SVGRasterizationError, .unsupportedDocumentSemantics)
            }
        }
    }

    func testStructuralAndCoordinateLimitsFailBeforePublication_M5_SVG_PT_004() throws {
        let rasterizer = CoreGraphicsSVGRasterizer()
        let base = Data("<svg viewBox=\"0 0 10 10\"><rect width=\"10\" height=\"10\"/></svg>".utf8)
        XCTAssertThrowsError(
            try rasterizer.probe(
                data: base,
                limits: SVGRasterizationLimits(maximumEncodedBytes: base.count - 1)
            )
        ) { error in
            XCTAssertEqual(error as? SVGRasterizationError, .encodedBytesExceeded)
        }
        XCTAssertThrowsError(
            try rasterizer.probe(
                data: base,
                limits: SVGRasterizationLimits(maximumElements: 1)
            )
        ) { error in
            XCTAssertEqual(error as? SVGRasterizationError, .elementLimitExceeded)
        }
        let nested = Data("<svg viewBox=\"0 0 10 10\"><g><rect width=\"1\" height=\"1\"/></g></svg>".utf8)
        XCTAssertThrowsError(
            try rasterizer.probe(
                data: nested,
                limits: SVGRasterizationLimits(maximumNestingDepth: 2)
            )
        ) { error in
            XCTAssertEqual(error as? SVGRasterizationError, .nestingDepthExceeded)
        }
        let path = Data("<svg viewBox=\"0 0 10 10\"><path d=\"M0 0 L1 1 L2 2\"/></svg>".utf8)
        XCTAssertThrowsError(
            try rasterizer.probe(
                data: path,
                limits: SVGRasterizationLimits(maximumPathCommands: 2)
            )
        ) { error in
            XCTAssertEqual(error as? SVGRasterizationError, .pathCommandLimitExceeded)
        }
        let oversizedCoordinate = Data("<svg viewBox=\"0 0 10 10\"><rect x=\"101\" width=\"1\" height=\"1\"/></svg>".utf8)
        XCTAssertThrowsError(
            try rasterizer.probe(
                data: oversizedCoordinate,
                limits: SVGRasterizationLimits(maximumCoordinateMagnitude: 100)
            )
        ) { error in
            XCTAssertEqual(error as? SVGRasterizationError, .coordinateLimitExceeded)
        }
    }

    func testTargetLimitsAndProbeMismatchFailClosed_M5_SVG_PT_005() throws {
        let rasterizer = CoreGraphicsSVGRasterizer()
        let data = Data("<svg viewBox=\"0 0 10 10\"><rect width=\"10\" height=\"10\"/></svg>".utf8)
        let probe = try rasterizer.probe(data: data, limits: .coreV1)
        let constrained = SVGRasterizationLimits(
            maximumTargetDimension: 16,
            maximumTargetPixelCount: 256
        )
        XCTAssertThrowsError(
            try rasterizer.resourceEstimate(
                probe: probe,
                request: SVGRasterizationRequest(target: try TargetPixels(width: 17, height: 8)),
                limits: constrained
            )
        ) { error in
            XCTAssertEqual(error as? SVGRasterizationError, .targetDimensionExceeded)
        }

        let changed = Data("<svg viewBox=\"0 0 20 10\"><rect width=\"20\" height=\"10\"/></svg>".utf8)
        XCTAssertThrowsError(
            try rasterizer.rasterize(
                data: changed,
                probe: probe,
                request: SVGRasterizationRequest(target: try TargetPixels(width: 16, height: 16)),
                limits: .coreV1
            )
        ) { error in
            XCTAssertEqual(error as? SVGRasterizationError, .probeMismatch)
        }
    }

    private func rgbaBytes(_ image: CGImage) throws -> [UInt8] {
        guard let data = image.dataProvider?.data else {
            throw SVGRasterizationError.renderFailed
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
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
    }
}
