# ImageCraft

ImageCraft 是独立于网络加载、缓存、UI 与持久化系统的 Apple 平台图像编解码工程。

当前仓库提供两个 SwiftPM 库产品，并附带一个证据工具：

- `ImageCraftCore`：版本化 codec 能力、资源、prepared-state、颜色、像素与 fit/fill 解码契约；
- `ImageCraftImageIO`：基于 Apple ImageIO/Core Graphics 的参考实现；
- `ImageCraftEvidence`：package-internal 行为证据与 fixture 工具，不属于库的公共 API。

## 当前边界

当前实现已支持：

- 有界 PNG/JPEG/GIF 探测与静态主帧解码；
- 目标尺寸缩放、方向、ICC/颜色策略、metadata 预算和 prepared source 复用；
- 静态 PNG 无损编码与 JPEG 有损编码；
- 显式质量、色彩策略、方向、alpha preserve/reject/flatten 和写入期输出字节硬上限；
- 解码与编码各自独立的 capability descriptor、稳定失败分类和版本 fingerprint。

它明确不声明渐进代次、动画时间轴、HDR 输出、planar/pixel-buffer 输出、可中断取消、任意 EXIF/XMP 透传或跨 OS 字节确定性。

仓库不依赖 Fovea、HTTP、URLSession、缓存、安全 namespace、UI 或 AxiomRaster。Fovea 中的宿主集成与 DecodeKey/RenderKey 身份测试仍应留在 Fovea。

## SwiftPM 使用

公开开发仓库位于 `https://github.com/YuLeiFuYun/ImageCraft`。项目尚未发布稳定版本；宿主应固定到经过验证的精确提交：

```swift
.package(url: "https://github.com/YuLeiFuYun/ImageCraft.git", revision: "<verified-commit>")
```

目标依赖只选择公开库产品：

```swift
.product(name: "ImageCraftCore", package: "ImageCraft")
.product(name: "ImageCraftImageIO", package: "ImageCraft")
```

`Fixtures/ConsumerSmoke` 是一个独立 SwiftPM 消费者，持续证明这两个产品无需访问 package-internal 实现即可在 macOS 和 iOS 上编译。

## 编码示例

```swift
import ImageCraftCore
import ImageCraftImageIO

let encoder = ImageIOImageEncoder()
let request = try ImageEncodeRequest.jpeg(
    quality: ImageEncodeQuality(rawValue: 0.9),
    colorPolicy: .convertToSRGB,
    alphaPolicy: .flatten(background: .white)
)
let result = try encoder.encode(
    image: cgImage,
    request: request,
    limits: .coreV1
)
```

JPEG 不会静默丢弃 alpha。带 alpha 的源必须显式拒绝或指定 flatten 背景。

## 验证

```sh
swift test
scripts/verify.sh
scripts/verify-ios-simulator.sh
scripts/capture-imageio-evidence.sh
scripts/verify-independent-oracles.sh
scripts/verify-retained-corpus.sh
scripts/verify-retained-corpus-reproducibility.sh
scripts/verify-public-api.sh
scripts/verify-compatibility-contract.sh
scripts/verify-consumer-package.sh
scripts/verify-platform-matrix.sh
scripts/verify-release-readiness.sh
scripts/capture-performance-evidence.sh performance.json 7 3
scripts/verify-performance-baseline.sh \
  Evidence/Performance/macos-27.0-26A5388g-arm64-macbookpro18,3.json
```

`verify.sh` 执行 macOS 测试、Release 构建和 ImageIO 行为证据确定性检查；iOS Simulator 编译门单独运行，避免普通本地迭代每次重建双架构产物。`ImageCraftEvidence` 会记录实际运行时、固定输入输出摘要、JPEG SOF/采样结构和量化表摘要。独立 oracle 门使用 libjpeg-turbo 与 libpng，不进入生产依赖。受版本管理的 retained corpus 固化 PNG/JPEG/GIF 的代表性与边界位流、SHA-256 和稳定失败语义；公共符号图 baseline 阻止内部研究接口泄漏。性能门使用独立进程、Release 构建、3×7 样本和采样 RSS，只作为绑定硬件与系统版本的显式门禁，不进入默认动态验证。兼容性门另外验证根包声明、独立消费者、macOS 12、iOS 15 Simulator 和 iOS 15 device Release 编译。详见 `docs/EVIDENCE.md`、`docs/INDEPENDENT_ORACLES.md`、`docs/RETAINED_CORPUS.md`、`docs/PERFORMANCE.md`、`docs/COMPATIBILITY.md`、`docs/RELEASING.md` 与 `docs/PUBLIC_API.md`。

## 来源与迁移状态

初始代码从 Fovea 当前工作树的 `ImageCraftCore` 与 `ImageCraftImageIO` target 提取。提取不修改 Fovea；待独立仓库稳定后，再让 Fovea 通过 SwiftPM 依赖本仓库，完成物理解绑。

详见 `docs/ARCHITECTURE.md`、`docs/ENCODING_CONTRACT.md`、`docs/EVIDENCE.md`、`docs/INDEPENDENT_ORACLES.md`、`docs/RETAINED_CORPUS.md`、`docs/PERFORMANCE.md`、`docs/COMPATIBILITY.md`、`docs/RELEASING.md`、`docs/PUBLIC_API.md` 与 `ROADMAP.md`。

## 平台边界

包当前面向 iOS 15+ 与 macOS 12+。`ImageCraftCore` 的公开值类型仍包含 `CGImage`，因此当前不是 Linux/Windows 可构建包；跨平台核心需要另行拆出不含 Core Graphics 的纯语义层，不能仅靠条件编译伪装完成。
