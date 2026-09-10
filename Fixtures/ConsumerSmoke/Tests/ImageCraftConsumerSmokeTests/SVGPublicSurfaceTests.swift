import Foundation
import ImageCraftConsumerSmoke
import ImageCraftCore
import XCTest

final class SVGPublicSurfaceTests: XCTestCase {

    func testExternalConsumerRejectsReflectedControlOverflow_M5_SVG_CONSUMER_PT_002() throws {
        let overflowingSource = Data(
            """
            <svg viewBox="0 0 20 10">
              <path d="M0 0 Q-1000000 0 1000000 0 T0 0"/>
            </svg>
            """.utf8
        )
        XCTAssertThrowsError(try ImageCraftConsumerSmoke().rasterizeSVG(overflowingSource)) {
            XCTAssertEqual($0 as? SVGRasterizationError, .coordinateLimitExceeded)
        }
    }

    func testExternalConsumerExecutesPublicSVGRasterizer_M5_SVG_CONSUMER_PT_001() throws {
        let source = Data(
            """
            <svg viewBox="0 0 20 10">
              <rect width="20" height="10" fill="#336699"/>
            </svg>
            """.utf8
        )
        let image = try ImageCraftConsumerSmoke().rasterizeSVG(source)
        XCTAssertEqual(image.pixelWidth, 512)
        XCTAssertEqual(image.pixelHeight, 256)
        XCTAssertEqual(image.pixelFormat.bitsPerComponent, 8)
        XCTAssertEqual(image.pixelFormat.bitsPerPixel, 32)
    }
}
