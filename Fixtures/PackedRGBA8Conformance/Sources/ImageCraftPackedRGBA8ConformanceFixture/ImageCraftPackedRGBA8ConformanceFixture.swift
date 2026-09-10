import ImageCraftCore
import ImageCraftImageIO

public enum ImageCraftPackedRGBA8ConformanceFixture {
    public static func make(
        maximumOperationByteCharge: Int
    ) throws -> any ImagePackedRGBA8Decoding {
        try BoundedPNGDecoder(maximumOperationByteCharge: maximumOperationByteCharge)
    }
}
