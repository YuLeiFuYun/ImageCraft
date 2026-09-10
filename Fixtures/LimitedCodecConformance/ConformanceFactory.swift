import ImageCraftCore
import LimitedCodecConformanceFixture

enum CodecUnderTest {
    static func make() -> any ImageCodec {
        LimitedPNGImageCodec()
    }
}
