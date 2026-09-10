import ImageCraftCore
import ImageCraftImageIO

public enum ImageCraftCodecConformanceFixture {
    public static func make() -> any ImageCodec {
        ImageIOImageDecoder()
    }
}
