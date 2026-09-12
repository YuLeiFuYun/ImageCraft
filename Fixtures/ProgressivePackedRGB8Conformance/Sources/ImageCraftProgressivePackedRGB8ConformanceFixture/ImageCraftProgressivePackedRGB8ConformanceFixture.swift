import ImageCraftCore
import ImageCraftImageIO

public enum ImageCraftProgressivePackedRGB8ConformanceFixture {
    public static func make(
        maximumCodecOwnedByteCharge: Int,
        limits: DecodeLimits
    ) throws -> any ProgressiveImagePackedRGB8FinalizingSession {
        try BoundedProgressiveJPEG420Session(
            maximumCodecOwnedByteCharge: maximumCodecOwnedByteCharge,
            limits: limits
        )
    }
}
