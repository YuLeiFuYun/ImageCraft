import ImageCraftCodecConformanceFixture
import ImageCraftCore

enum CodecUnderTest {
    static func make() -> any ImageCodec {
        ImageCraftCodecConformanceFixture.make()
    }
}
