import ImageCraftCore
import ImageCraftImageIO

enum CodecUnderTest {
    static func make() -> any ImageCodec {
        ImageIOImageDecoder()
    }
}
