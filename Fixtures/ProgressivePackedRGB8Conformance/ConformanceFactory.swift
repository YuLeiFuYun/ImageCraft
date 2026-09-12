import ImageCraftCore
import ImageCraftProgressivePackedRGB8ConformanceFixture

enum PackedSessionUnderTest {
    static func make(
        maximumCodecOwnedByteCharge: Int,
        limits: DecodeLimits
    ) throws -> any ProgressiveImagePackedRGB8FinalizingSession {
        try ImageCraftProgressivePackedRGB8ConformanceFixture.make(
            maximumCodecOwnedByteCharge: maximumCodecOwnedByteCharge,
            limits: limits
        )
    }
}
