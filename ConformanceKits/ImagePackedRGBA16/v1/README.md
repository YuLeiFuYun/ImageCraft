# ImagePackedRGBA16 Conformance v1

该 kit 是 ImageCraft 对公开 `ImagePackedRGBA16Decoding` 与 `ImagePackedRGBA16Straight` 的可复用独立消费者资格门。v1 profile 精确限定为“有硬 operation-byte budget 的 explicit-sRGB、16-bit、static PNG → codec-owned straight RGBA16LE”，不把 package-only 的 sBIT、ICC、cICP/HDR、色彩转换或其他高深度语义一起提升为公共契约。

backend 仓库提供 factory source：

```swift
import ImageCraftCore
import YourPacked16BackendProduct

enum PackedDecoderUnderTest {
    static func make(maximumOperationByteCharge: Int) throws -> any ImagePackedRGBA16Decoding {
        try YourPacked16Decoder(maximumOperationByteCharge: maximumOperationByteCharge)
    }
}
```

运行：

```sh
python3 ConformanceKits/ImagePackedRGBA16/v1/run.py \
  --backend-package-path /path/to/backend \
  --backend-product Packed16BackendProduct \
  --factory-source /path/to/PackedDecoderUnderTest.swift
```

v1 使用 SHA-256 固定的 2×1 explicit-sRGB RGBA16 PNG，并冻结 untagged 与 sBIT 两个 profile-negative fixture。八项义务覆盖：公共 straight-RGBA16LE value 不变量、16-bit probe、全 phase 有界资源 ledger、caller-owned encoded-source coexistence、精确 tight little-endian straight RGBA16 像素、DecodeLimits、request/source fail-closed 边界和 factory-enforced operation-byte budget。该 kit 只证明这个窄 profile；不证明广泛 PNG16、package-only ICC/cICP/HDR/sBIT 语义、hostile corpus、fuzz/sanitizer、物理 RSS、设备资源、宿主 composition 或发布资格。报告固定 `releaseQualified=false`。
