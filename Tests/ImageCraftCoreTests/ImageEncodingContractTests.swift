import Foundation
import ImageCraftCore
import XCTest

final class ImageEncodingContractTests: XCTestCase {
  func testQualityAndOrientationRejectValuesOutsideClosedDomains() throws {
    XCTAssertThrowsError(try ImageEncodeQuality(rawValue: -0.01)) {
      XCTAssertEqual($0 as? ImageEncodingError, .invalidQuality)
    }
    XCTAssertThrowsError(try ImageEncodeQuality(rawValue: 1.01)) {
      XCTAssertEqual($0 as? ImageEncodingError, .invalidQuality)
    }
    XCTAssertThrowsError(try ImageEncodeQuality(rawValue: .infinity)) {
      XCTAssertEqual($0 as? ImageEncodingError, .invalidQuality)
    }
    XCTAssertEqual(try ImageEncodeQuality(rawValue: 0).rawValue, 0)
    XCTAssertEqual(try ImageEncodeQuality(rawValue: 1).rawValue, 1)

    XCTAssertThrowsError(try ImageEncodeOrientation(rawValue: 0)) {
      XCTAssertEqual($0 as? ImageEncodingError, .invalidOrientation)
    }
    XCTAssertThrowsError(try ImageEncodeOrientation(rawValue: 9)) {
      XCTAssertEqual($0 as? ImageEncodingError, .invalidOrientation)
    }
    XCTAssertEqual(try ImageEncodeOrientation(rawValue: 8).rawValue, 8)
  }

  func testOrientationCannotSurviveDiscardMetadataPolicy() throws {
    XCTAssertThrowsError(
      try ImageEncodeRequest.png(
        metadataPolicy: .discard,
        orientation: ImageEncodeOrientation(rawValue: 6)
      )
    ) {
      XCTAssertEqual(
        $0 as? ImageEncodingError,
        .orientationRequiresMetadataPreservation
      )
    }
  }

  func testRequestCodableRevalidatesOrientationPolicyInvariant() throws {
    let request = try ImageEncodeRequest.jpeg(
      metadataPolicy: .preserveRecognized,
      orientation: ImageEncodeOrientation(rawValue: 6),
      alphaPolicy: .flatten(background: .white)
    )
    let encoded = try JSONEncoder().encode(request)
    XCTAssertEqual(try JSONDecoder().decode(ImageEncodeRequest.self, from: encoded), request)

    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    var malformed = object
    malformed["metadataPolicy"] = "discard"
    let malformedData = try JSONSerialization.data(withJSONObject: malformed)
    XCTAssertThrowsError(
      try JSONDecoder().decode(ImageEncodeRequest.self, from: malformedData)
    )
  }

  func testDescriptorClassifiesCompressionAndAlphaCapabilities() throws {
    let descriptor = ImageEncoderDescriptor(
      identifier: ImageEncoderIdentifier(rawValue: "test.encoder"),
      implementationVersion: 1,
      capabilities: ImageEncoderCapabilities(
        formats: [.png, .jpeg],
        losslessFormats: [.png],
        lossyFormats: [.jpeg],
        alphaPreservingFormats: [.png],
        alphaFlatteningFormats: [.png, .jpeg],
        colorPolicies: Set(ImageEncodeColorPolicy.allCases),
        metadataPolicies: Set(ImageEncodeMetadataPolicy.allCases)
      )
    )

    let png = try ImageEncodeRequest.png()
    XCTAssertNil(descriptor.supportFailure(for: png, sourceHasAlpha: true))

    let jpegPreserve = try ImageEncodeRequest.jpeg(alphaPolicy: .preserve)
    XCTAssertEqual(
      descriptor.supportFailure(for: jpegPreserve, sourceHasAlpha: true),
      .alphaPreservation(format: .jpeg)
    )
    XCTAssertNil(descriptor.supportFailure(for: jpegPreserve, sourceHasAlpha: false))

    let lossyPNG = try ImageEncodeRequest(
      format: .png,
      compression: .lossy(ImageEncodeQuality(rawValue: 0.5))
    )
    XCTAssertEqual(
      descriptor.supportFailure(for: lossyPNG, sourceHasAlpha: false),
      .compression(format: .png, compression: lossyPNG.compression)
    )
  }

  func testEncoderFingerprintSeparatesIdentityVersionAndContract() {
    let capabilities = ImageEncoderCapabilities(
      formats: [.png],
      losslessFormats: [.png],
      lossyFormats: [],
      alphaPreservingFormats: [.png],
      alphaFlatteningFormats: [.png],
      colorPolicies: [.preserveSource],
      metadataPolicies: [.discard]
    )
    let values = [
      ImageEncoderDescriptor(
        identifier: ImageEncoderIdentifier(rawValue: "a"),
        implementationVersion: 1,
        contractVersion: 1,
        capabilities: capabilities
      ),
      ImageEncoderDescriptor(
        identifier: ImageEncoderIdentifier(rawValue: "b"),
        implementationVersion: 1,
        contractVersion: 1,
        capabilities: capabilities
      ),
      ImageEncoderDescriptor(
        identifier: ImageEncoderIdentifier(rawValue: "a"),
        implementationVersion: 2,
        contractVersion: 1,
        capabilities: capabilities
      ),
      ImageEncoderDescriptor(
        identifier: ImageEncoderIdentifier(rawValue: "a"),
        implementationVersion: 1,
        contractVersion: 2,
        capabilities: capabilities
      ),
    ]
    XCTAssertEqual(Set(values.map(\.cacheFingerprint)).count, values.count)
  }
}
