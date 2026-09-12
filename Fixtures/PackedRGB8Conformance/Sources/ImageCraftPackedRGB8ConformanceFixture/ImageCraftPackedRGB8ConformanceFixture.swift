import ImageCraftCore
import ImageCraftImageIO

public enum ImageCraftPackedRGB8ConformanceFixture {
    public static func make(
        maximumOperationByteCharge: Int
    ) throws -> any ImagePackedRGB8Decoding {
        try BoundedBaselineJPEGDecoder(
            maximumOperationByteCharge: maximumOperationByteCharge
        )
    }
}
