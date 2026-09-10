import CoreGraphics
import Foundation
import ImageCraftCore
import ImageCraftSVG
import XCTest

final class SVGSmoothControlBoundaryTests: XCTestCase {
    func testReflectedControlsRejectBothAxesAndSigns_M5_SVG_PT_006() throws {
        let paths = [
            "M0 0 C0 0 -100 0 100 0 S0 0 0 0",
            "M0 0 C0 0 100 0 -100 0 s0 0 0 0",
            "M0 0 C0 0 0 -100 0 100 S0 0 0 0",
            "M0 0 C0 0 0 100 0 -100 s0 0 0 0",
            "M0 0 Q-100 0 100 0 T0 0",
            "M0 0 Q100 0 -100 0 t0 0",
            "M0 0 Q0 -100 0 100 T0 0",
            "M0 0 Q0 100 0 -100 t0 0",
            "M0 0 Q-100 0 0 0 T-100 0 T0 0",
        ]
        let rasterizer = CoreGraphicsSVGRasterizer()
        let boundaryLimits = SVGRasterizationLimits(maximumCoordinateMagnitude: 100)
        let request = SVGRasterizationRequest(target: try TargetPixels(width: 16, height: 16))
        for path in paths {
            let data = document(path)
            // A probe made with a larger budget cannot bypass stricter raster admission.
            let permissiveProbe = try rasterizer.probe(data: data, limits: .coreV1)
            XCTAssertThrowsError(try rasterizer.probe(data: data, limits: boundaryLimits), path) {
                XCTAssertEqual($0 as? SVGRasterizationError, .coordinateLimitExceeded)
            }
            XCTAssertThrowsError(
                try rasterizer.rasterize(
                    data: data, probe: permissiveProbe, request: request, limits: boundaryLimits
                ), path
            ) {
                XCTAssertEqual($0 as? SVGRasterizationError, .coordinateLimitExceeded)
            }
        }
    }

    func testBoundaryAndResetControlsMatchExplicitCurves_M5_SVG_PT_007() throws {
        let pairs = [
            ("M0 0 C0 0 0 0 50 50 S50 50 0 0 Z", "M0 0 C0 0 0 0 50 50 C100 100 50 50 0 0 Z"),
            ("M0 0 Q0 0 50 50 T0 0 Z", "M0 0 Q0 0 50 50 Q100 100 0 0 Z"),
            ("M0 0 Q0 0 50 50 S50 50 0 0 Z", "M0 0 Q0 0 50 50 C50 50 50 50 0 0 Z"),
            ("M0 0 C0 0 0 0 50 50 T0 0 Z", "M0 0 C0 0 0 0 50 50 Q50 50 0 0 Z"),
        ]
        for (smooth, explicit) in pairs {
            XCTAssertEqual(try pixels(smooth), try pixels(explicit), smooth)
        }
    }

    private func document(_ path: String) -> Data {
        Data("<svg viewBox=\"0 0 100 100\"><path d=\"\(path)\" fill=\"red\"/></svg>".utf8)
    }

    private func pixels(_ path: String) throws -> Data {
        let rasterizer = CoreGraphicsSVGRasterizer()
        let boundaryLimits = SVGRasterizationLimits(maximumCoordinateMagnitude: 100)
        let data = document(path)
        let probe = try rasterizer.probe(data: data, limits: boundaryLimits)
        let image = try rasterizer.rasterize(
            data: data, probe: probe,
            request: SVGRasterizationRequest(target: try TargetPixels(width: 64, height: 64)),
            limits: boundaryLimits
        )
        return try XCTUnwrap(image.cgImage.dataProvider?.data) as Data
    }
}
