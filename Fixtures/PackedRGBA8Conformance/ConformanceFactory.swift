import ImageCraftCore
import ImageCraftPackedRGBA8ConformanceFixture

enum PackedDecoderUnderTest {
    static func make(
        maximumOperationByteCharge: Int
    ) throws -> any ImagePackedRGBA8Decoding {
        try ImageCraftPackedRGBA8ConformanceFixture.make(
            maximumOperationByteCharge: maximumOperationByteCharge
        )
    }
}
