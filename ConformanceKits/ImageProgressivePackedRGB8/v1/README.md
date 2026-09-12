# ImageProgressivePackedRGB8 Conformance v1

该 kit 是 ImageCraft 对公开 `ProgressiveImagePackedRGB8FinalizingSession` / `ImagePackedRGB8` final-only seam 的可复用独立消费者资格门。v1 profile 精确限定为“有硬 codec-owned byte budget 的 progressive 8-bit three-component JFIF 4:2:0 → exact tight sRGB RGB8 finalization”，不把独立 JPEG kernel 的研究 snapshot、preview cadence、Core Graphics materialization 或更广 JPEG 语义一起提升为公共契约。

backend 仓库提供 factory source：

```swift
import ImageCraftCore
import YourPackedSessionProduct

enum PackedSessionUnderTest {
    static func make(
        maximumCodecOwnedByteCharge: Int,
        limits: DecodeLimits
    ) throws -> any ProgressiveImagePackedRGB8FinalizingSession {
        try YourSession(maximumCodecOwnedByteCharge: maximumCodecOwnedByteCharge, limits: limits)
    }
}
```

运行：

```sh
python3 ConformanceKits/ImageProgressivePackedRGB8/v1/run.py \
  --backend-package-path /path/to/backend \
  --backend-product PackedSessionProduct \
  --factory-source /path/to/PackedSessionUnderTest.swift
```

v1 冻结一个 787-byte、23×13 progressive JFIF 4:2:0 source 与一个额外 ICC APP2 hostile derivative。八项义务覆盖：公开 tight RGB8 value 不变量、arbitrary-chunk/final-only lifecycle、非消费式 finalization preflight、exact bounded ledger（retained 897 B / operation peak 6590 B / transfer 897 B）、caller-owned encoded-source coexistence、冻结的 897-byte RGB SHA、chunk-partition invariance、DecodeLimits/ICC fail-closed、cancel/terminal fencing 和 hard codec-owned budget。`sourceByteCount` 仍是 transport-binding 值，宿主必须与其独立确认的完整正文长度核对。

该 kit 不证明 broad JPEG support、preview usefulness、Core Graphics allocation bound、physical RSS/device performance、quality superiority、host cache composition 或 release qualification；报告固定 `releaseQualified=false`。`DecodedImage` materialization 继续通过另一条 resource-aware capability 保留 `frameworkPrivateOperationAllocation` unknown，而不是被 packed-value gate 吞掉。
