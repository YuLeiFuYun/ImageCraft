import ImageCraftCore
import ImageCraftPackedRGB8ConformanceFixture

enum PackedDecoderUnderTest {
    static func make(
        maximumOperationByteCharge: Int
    ) throws -> any ImagePackedRGB8Decoding {
        try ImageCraftPackedRGB8ConformanceFixture.make(
            maximumOperationByteCharge: maximumOperationByteCharge
        )
    }
}
