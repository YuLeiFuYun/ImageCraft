import Foundation
import ImageCraftImageIO
import XCTest

final class ImageIORuntimeFingerprintTests: XCTestCase {
  func testRuntimeFingerprintCapturesSystemAndFrameworkIdentity() throws {
    let fingerprint = ImageIORuntimeFingerprint.capture()

    XCTAssertEqual(fingerprint.schemaVersion, ImageIORuntimeFingerprint.currentSchemaVersion)
    XCTAssertNotEqual(fingerprint.platform, "unknown")
    XCTAssertGreaterThan(fingerprint.operatingSystemVersion.majorVersion, 0)
    XCTAssertNotEqual(fingerprint.operatingSystemBuild, "unknown")
    XCTAssertNotEqual(fingerprint.architecture, "unknown")
    XCTAssertNotEqual(fingerprint.imageIOBundleVersion, "unknown")
    XCTAssertNotEqual(fingerprint.coreGraphicsBundleVersion, "unknown")

    let encoded = try JSONEncoder().encode(fingerprint)
    XCTAssertEqual(
      try JSONDecoder().decode(ImageIORuntimeFingerprint.self, from: encoded), fingerprint)
  }
}
