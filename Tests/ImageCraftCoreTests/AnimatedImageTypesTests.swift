import Foundation
import ImageCraftCore
import XCTest

final class AnimatedImageTypesTests: XCTestCase {
  func testDurationCanonicalizesEquivalentRationalsAndRoundsUp_IMG_ANIM_PT_005() throws {
    let first = try ImageAnimationFrameDuration(numerator: 10, denominator: 100)
    let second = try ImageAnimationFrameDuration(numerator: 1, denominator: 10)
    XCTAssertEqual(first, second)
    XCTAssertEqual(first.numerator, 1)
    XCTAssertEqual(first.denominator, 10)
    XCTAssertEqual(first.roundedUpNanoseconds, 100_000_000)

    let subNanosecond = try ImageAnimationFrameDuration(
      numerator: 1,
      denominator: UInt32.max
    )
    XCTAssertEqual(subNanosecond.roundedUpNanoseconds, 1)
    XCTAssertThrowsError(
      try ImageAnimationFrameDuration(numerator: 1, denominator: 0)
    )
  }

  func testDurationCodableRevalidatesAndCanonicalizes_IMG_ANIM_PT_016() throws {
    let decoder = JSONDecoder()
    let canonical = try decoder.decode(
      ImageAnimationFrameDuration.self,
      from: Data(#"{"numerator":2,"denominator":4}"#.utf8)
    )
    XCTAssertEqual(canonical.numerator, 1)
    XCTAssertEqual(canonical.denominator, 2)
    XCTAssertThrowsError(
      try decoder.decode(
        ImageAnimationFrameDuration.self,
        from: Data(#"{"numerator":1,"denominator":0}"#.utf8)
      )
    ) { error in
      XCTAssertTrue(error is DecodingError)
    }
  }

  func testLoopCountCodableRequiresExplicitFiniteOrNull_IMG_ANIM_PT_017() throws {
    let decoder = JSONDecoder()
    XCTAssertThrowsError(
      try decoder.decode(ImageAnimationLoopCount.self, from: Data(#"{}"#.utf8))
    ) { error in
      XCTAssertTrue(error is DecodingError)
    }

    let encoder = JSONEncoder()
    let infinite = try decoder.decode(
      ImageAnimationLoopCount.self,
      from: Data(#"{"additionalRepeatCount":null}"#.utf8)
    )
    XCTAssertTrue(infinite.isInfinite)
    let encodedInfinite = try encoder.encode(infinite)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encodedInfinite) as? [String: Any]
    )
    XCTAssertTrue(object.keys.contains("additionalRepeatCount"))
    XCTAssertTrue(object["additionalRepeatCount"] is NSNull)

    let finite = ImageAnimationLoopCount(additionalRepeatCount: 3)
    XCTAssertEqual(
      try decoder.decode(ImageAnimationLoopCount.self, from: encoder.encode(finite)),
      finite
    )
  }

  func testFrameRectCodableRejectsInvalidGeometry_IMG_ANIM_PT_018() throws {
    let decoder = JSONDecoder()
    for json in [
      #"{"x":-1,"y":0,"width":1,"height":1}"#,
      #"{"x":0,"y":-1,"width":1,"height":1}"#,
      #"{"x":0,"y":0,"width":0,"height":1}"#,
      #"{"x":0,"y":0,"width":1,"height":0}"#,
    ] {
      XCTAssertThrowsError(
        try decoder.decode(
          ImageAnimationFrameRect.self,
          from: Data(json.utf8)
        )
      ) { error in
        XCTAssertTrue(error is DecodingError)
      }
    }
  }

  func testFrameDescriptorCodableRejectsNegativeIndex_IMG_ANIM_PT_019() throws {
    let decoder = JSONDecoder()
    let json =
      #"{"index":-1,"duration":{"numerator":1,"denominator":10},"rect":{"x":0,"y":0,"width":1,"height":1},"disposal":"none","blend":"source"}"#
    XCTAssertThrowsError(
      try decoder.decode(
        ImageAnimationFrameDescriptor.self,
        from: Data(json.utf8)
      )
    ) { error in
      XCTAssertTrue(error is DecodingError)
    }
  }

  func testAnimationValueCodableRoundTripsValidatedValues_IMG_ANIM_PT_024() throws {
    let duration = try ImageAnimationFrameDuration(numerator: 2, denominator: 8)
    let rect = try ImageAnimationFrameRect(x: 1, y: 2, width: 3, height: 4)
    let descriptor = try ImageAnimationFrameDescriptor(
      index: 5,
      duration: duration,
      rect: rect,
      disposal: .previous,
      blend: .over
    )
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    XCTAssertEqual(
      try decoder.decode(
        ImageAnimationFrameDuration.self,
        from: encoder.encode(duration)
      ),
      duration
    )
    XCTAssertEqual(
      try decoder.decode(ImageAnimationFrameRect.self, from: encoder.encode(rect)),
      rect
    )
    XCTAssertEqual(
      try decoder.decode(
        ImageAnimationFrameDescriptor.self,
        from: encoder.encode(descriptor)
      ),
      descriptor
    )
  }

  func testMetadataRejectsNoncontiguousOrOutOfCanvasFrames_IMG_ANIM_PT_006() throws {
    let duration = try ImageAnimationFrameDuration(numerator: 1, denominator: 10)
    let full = try ImageAnimationFrameRect(x: 0, y: 0, width: 10, height: 10)
    let wrongIndex = try ImageAnimationFrameDescriptor(
      index: 1,
      duration: duration,
      rect: full,
      disposal: .none,
      blend: .source
    )
    XCTAssertThrowsError(
      try ImageAnimationMetadata(
        container: .gif,
        canvasWidth: 10,
        canvasHeight: 10,
        loopCount: .playOnce,
        frames: [wrongIndex],
        encodedByteCount: 10,
        codecFingerprint: "test#impl=1"
      )
    )

    let outside = try ImageAnimationFrameDescriptor(
      index: 0,
      duration: duration,
      rect: ImageAnimationFrameRect(x: 9, y: 9, width: 2, height: 2),
      disposal: .none,
      blend: .source
    )
    XCTAssertThrowsError(
      try ImageAnimationMetadata(
        container: .apng,
        canvasWidth: 10,
        canvasHeight: 10,
        loopCount: .infinite,
        frames: [outside],
        encodedByteCount: 10,
        codecFingerprint: "test#impl=1"
      )
    )
  }
}
