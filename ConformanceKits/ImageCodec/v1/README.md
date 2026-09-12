# ImageCodec Conformance v1

该 kit 是 ImageCraft 对 `ImageCodec` v1 合同的可复用独立消费者资格门。运行器会在临时 SwiftPM 测试包中装配被测 backend，不导入 backend 私有测试支持；参考 PNG/JPEG/GIF 输入是 kit 自带的固定字节 fixture，并由 `Fixtures/manifest.json` 的 SHA-256 绑定。

backend 仓库提供 factory source：

```swift
import ImageCraftCore
import YourCodecProduct

enum CodecUnderTest {
    static func make() -> any ImageCodec {
        YourCodec()
    }
}
```

运行：

```sh
python3 ConformanceKits/ImageCodec/v1/run.py \
  --codec-package-path /path/to/codec \
  --codec-product CodecProduct \
  --factory-source /path/to/CodecUnderTest.swift
```

v1 验证 finite-profile descriptor、5,120 项有限能力域、跨 profile 不得拼接的同-profile 判定、声明格式的 probe/完整帧 decode、资源估计组合和硬限制失败关闭；当 backend 暴露 prepared/progressive 可选能力时，还验证一次性 preparation create/consume/discard、prepared resource authority 生命周期，以及取消后的 progressive pixel fencing。输出遵循 `observation-schema.json`，并绑定当前 ImageCraft kit tree、backend source、factory、fixture manifest、harness、工具链和日志。

该 kit 是合同/有限 fixture 资格，不是发布资格。它不替代 hostile corpus、sanitizer、fuzz、真机资源、宿主 composition、shadow/canary 或 ImageIO fallback 证据；报告固定 `releaseQualified=false`。
