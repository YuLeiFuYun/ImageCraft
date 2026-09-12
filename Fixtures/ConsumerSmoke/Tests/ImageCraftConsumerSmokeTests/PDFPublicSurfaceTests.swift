import CoreGraphics
import Foundation
@testable import ImageCraftConsumerSmoke
import XCTest

final class PDFPublicSurfaceTests: XCTestCase {
  func testExternalConsumerExecutesPublicPDFRasterizer_M5_PDF_CONSUMER_PT_001() throws {
    let pdf = try makeSinglePagePDF(width: 200, height: 100)
    let consumer = ImageCraftConsumerSmoke()

    XCTAssertFalse(consumer.pdfRasterizerFingerprint.isEmpty)
    let image = try consumer.rasterizeSinglePagePDF(pdf)
    XCTAssertEqual(image.pixelWidth, 512)
    XCTAssertEqual(image.pixelHeight, 256)
    XCTAssertEqual(image.pixelFormat.bitsPerComponent, 8)
    XCTAssertEqual(image.pixelFormat.bitsPerPixel, 32)
  }

  private func makeSinglePagePDF(width: CGFloat, height: CGFloat) throws -> Data {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
      XCTFail("CGDataConsumer creation failed")
      return Data()
    }
    var mediaBox = CGRect(x: 0, y: 0, width: width, height: height)
    guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
      XCTFail("PDF context creation failed")
      return Data()
    }
    context.beginPDFPage(nil)
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.endPDFPage()
    context.closePDF()
    return data as Data
  }
}
