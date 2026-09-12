import ImageCraftCore
import ImageCraftPackedRGBA16ConformanceFixture

enum PackedDecoderUnderTest {
    static func make(
        maximumOperationByteCharge: Int
    ) throws -> any ImagePackedRGBA16Decoding {
        try ImageCraftPackedRGBA16ConformanceFixture.make(
            maximumOperationByteCharge: maximumOperationByteCharge
        )
    }
}
