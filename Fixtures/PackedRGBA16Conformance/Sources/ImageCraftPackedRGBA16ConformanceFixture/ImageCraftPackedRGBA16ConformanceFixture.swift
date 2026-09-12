import ImageCraftCore
import ImageCraftImageIO

public enum ImageCraftPackedRGBA16ConformanceFixture {
    public static func make(
        maximumOperationByteCharge: Int
    ) throws -> any ImagePackedRGBA16Decoding {
        try BoundedPNG16Decoder(maximumOperationByteCharge: maximumOperationByteCharge)
    }
}
