# ImagePackedRGBA8 Conformance v1

该 kit 是 ImageCraft 对公开 `ImagePackedRGBA8Decoding` 的可复用独立消费者资格门，当前 v1 profile 精确限定为“有硬 operation-byte budget 的 PNG → codec-owned packed RGBA8”能力。它与 `ImageCodec` v1 kit 分开，因为 `ImagePackedRGBA8Decoding` 不是 `ImageCodec` 的子协议，不能用完整帧 `DecodedImage` 资格替代 packed-value/resource 资格。

backend 仓库提供 factory source：

```swift
import ImageCraftCore
import YourPackedBackendProduct

enum PackedDecoderUnderTest {
    static func make(maximumOperationByteCharge: Int) throws -> any ImagePackedRGBA8Decoding {
        try YourPackedDecoder(maximumOperationByteCharge: maximumOperationByteCharge)
    }
}
```

运行：

```sh
python3 ConformanceKits/ImagePackedRGBA8/v1/run.py \
  --backend-package-path /path/to/backend \
  --backend-product PackedBackendProduct \
  --factory-source /path/to/PackedDecoderUnderTest.swift
```

v1 使用 SHA-256 固定的 2×1 sRGB PNG，验证 descriptor/能力、确定性 probe、全 phase 有界资源 ledger、caller-owned encoded-source coexistence、精确 tight premultiplied RGBA8 像素、transfer charge、DecodeLimits 失败关闭，以及小于最小输出成本的 operation budget 不能成功准入。它只证明这个窄 profile；不证明广泛 PNG 语义、hostile corpus、fuzz/sanitizer、物理 RSS、设备资源、宿主 composition 或发布资格。报告固定 `releaseQualified=false`。
