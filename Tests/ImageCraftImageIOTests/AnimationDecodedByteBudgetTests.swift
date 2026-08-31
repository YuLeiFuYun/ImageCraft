import CoreGraphics
import ImageCraftCore
import XCTest

@testable import ImageCraftImageIO

final class AnimationDecodedByteBudgetTests: XCTestCase {
  func testActualRowStrideRevalidatesTimelineBudget_IMG_ANIM_PT_021() throws {
    let image = try decodedImage(width: 3, height: 2, bytesPerRow: 16)
    XCTAssertEqual(image.estimatedByteCost, 32)

    XCTAssertNoThrow(
      try AnimationDecodedByteBudget.validate(
        image,
        trackFrameCount: 3,
        maximumTimelineDecodedBytes: 96
      )
    )
    XCTAssertThrowsError(
      try AnimationDecodedByteBudget.validate(
        image,
        trackFrameCount: 3,
        maximumTimelineDecodedBytes: 95
      )
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .animationTimelineInvalid)
    }
    XCTAssertThrowsError(
      try AnimationDecodedByteBudget.validate(
        image,
        trackFrameCount: Int.max,
        maximumTimelineDecodedBytes: Int.max
      )
    ) { error in
      XCTAssertEqual(error as? ImageCraftError, .animationTimelineInvalid)
    }
  }

  private func decodedImage(
    width: Int,
    height: Int,
    bytesPerRow: Int
  ) throws -> DecodedImage {
    let bytes = Data(repeating: 0xFF, count: bytesPerRow * height)
    guard let provider = CGDataProvider(data: bytes as CFData),
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let image = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
          CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        ),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
      )
    else {
      throw ImageCraftError.decodeFailed
    }
    return DecodedImage(cgImage: image, sourceColorProfile: .standardSRGB)
  }
}
