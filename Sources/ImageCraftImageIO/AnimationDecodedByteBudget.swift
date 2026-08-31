import ImageCraftCore

enum AnimationDecodedByteBudget {
  static func validate(
    _ image: DecodedImage,
    trackFrameCount: Int,
    maximumTimelineDecodedBytes: Int
  ) throws {
    guard trackFrameCount > 0, maximumTimelineDecodedBytes > 0 else {
      throw ImageCraftError.animationTimelineInvalid
    }
    let total = image.estimatedByteCost.multipliedReportingOverflow(by: trackFrameCount)
    guard !total.overflow, total.partialValue <= maximumTimelineDecodedBytes else {
      throw ImageCraftError.animationTimelineInvalid
    }
  }
}
