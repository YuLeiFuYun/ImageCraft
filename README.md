# ImageCraft

ImageCraft 是独立于网络加载、缓存、UI 与持久化系统的 Apple 平台图像编解码工程。

## 开发工具链

- Xcode 27.0 或更新版本；
- Apple Swift 6.4，SwiftPM tools 6.4；
- 运行基线仍为 iOS 15 / macOS 12，不因编译器迁移而提高；
- `scripts/select-xcode.sh` 与 `scripts/check-swift-toolchain.py` 会拒绝旧工具链。
- GitHub CI 显式使用 `xcode-27` preview runner，不依赖会漂移的 `macos-latest`。


当前仓库提供两个 SwiftPM 库产品，并附带一个证据工具：

- `ImageCraftCore`：版本化 codec 能力、资源、prepared-state、颜色、像素与 fit/fill 解码契约；
- `ImageCraftImageIO`：基于 Apple ImageIO/Core Graphics 的参考实现；
- `ImageCraftEvidence`：package-internal 行为证据与 fixture 工具，不属于库的公共 API。

## 当前边界

当前实现已支持：

- 有界 PNG/JPEG/GIF 探测与静态主帧解码；
- JPEG 渐进扫描的有界增量会话、严格递增的非最终像素代次与取消封锁；
- GIF/APNG 精确时间轴与预分帧 JPEG sequence，支持按需单帧、有界连续帧窗口、loop/disposal/blend 元数据和整体取消；
- 目标尺寸缩放、方向、ICC/颜色策略、metadata 预算和有聚合 retained-byte authority 的 bounded prepared state；
- 静态 PNG 无损编码与 JPEG 有损编码；
- 显式质量、色彩策略、方向、alpha preserve/reject/flatten 和写入期输出字节硬上限；
- 解码与编码各自独立的 capability descriptor、稳定失败分类和版本 fingerprint。

它明确不声明 baseline JPEG、PNG 或 GIF 的渐进代次，也不提供网络 MJPEG multipart 分帧、display-link 播放时钟、UI 帧缓存、掉帧、后台可见性或 Reduce Motion 策略；同时不声明 HDR 输出、planar/pixel-buffer 输出、ImageIO 操作中途可中断取消、任意 EXIF/XMP 透传或跨 OS 字节确定性。渐进会话只产生预览；完整正文仍须经过常规 probe/decode 路径生成最终像素。

两个 Swift 库产品与运行时不依赖 Fovea、HTTP、URLSession、缓存、安全 namespace、UI 或 AxiomRaster。`Tools/Quality/AxiomPackedProbe` 仅是可选的 cross-backend research probe，会读取 pinned sibling AxiomRaster 仓库；它不进入库产品。Fovea 中的宿主集成与 DecodeKey/RenderKey 身份测试仍应留在 Fovea。

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

## 动画解码示例

```swift
let decoder = ImageIOAnimatedImageDecoder()
let asset = try await decoder.prepareAnimation(
    source: .encoded(gifOrAPNGData),
    limits: ImageAnimationDecodeLimits(maximumFrameDecodeWindow: 8)
)
let target = try TargetPixels(width: 512, height: 512)
let frames = try await asset.frames(
    in: 0..<min(8, asset.metadata.frameCount),
    request: ImageDecodeRequest(target: target, colorPolicy: .convertToSRGB)
)
```

`ImageAnimationFrameDuration` 保留容器的精确有理数秒值。公开 duration、loop、frame rect 与 frame descriptor 在 `Codable` 反序列化时重新执行构造器不变量；缺失 loop 字段不会静默变成无限循环。宿主负责播放时钟、窗口预取、掉帧与可见性；ImageCraft 不把这些 UI 策略塞入 codec。动画入口严格执行 `DecodeLimits.allowedFormats`；APNG 在交给 ImageIO 前验证每个 chunk 的 CRC、critical/reserved type、`IDAT` 连续性、控制序列和早期帧数上限；GIF user-input control 与 Plain Text graphic block 因当前播放合同不建模交互或文本渲染而显式拒绝；JPEG sequence 对整条序列累计元数据预算。`maximumTimelineDecodedBytes` 先按逻辑 RGBA 轨道做 admission，再在实际帧 publication 前按 `CGImage.bytesPerRow × height × frameCount` 复核。JPEG 动画当前只接受上层已分帧的完整 JPEG 数组，尚不解析网络 `multipart/x-mixed-replace`。

## 渐进 JPEG 示例

```swift
let decoder = ImageIOImageDecoder()
let session = try decoder.makeProgressiveSession(
    format: .jpeg,
    request: ImageDecodeRequest(target: try TargetPixels(width: 320, height: 240)),
    limits: .coreV1
)
for chunk in networkChunks {
    if let preview = try session.append(chunk) {
        display(preview.image, generation: preview.generation)
    }
}
try session.finish()
```

`finish()` 只封闭并验证增量容器生命周期；最终可缓存像素仍应使用完整、已验证正文调用常规解码接口。

`generation` 只能用于同一 session 内丢弃过时代次，不能当作跨请求质量等级。网络 chunk 的切分方式会影响一次 append 跨过多少 scan，因此同一 JPEG 在不同 transport 下可能产生不同数量和不同像素的预览；`sourceByteCount` 也只是该预览返回时累计接收的字节边界。若完整正文一次到达，会话可以零预览完成。

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
scripts/verify-source-identity.sh
scripts/verify-clean-copy.sh
scripts/verify-integration-contract.sh
scripts/verify-consumer-package.sh
scripts/verify-platform-matrix.sh
scripts/verify-release-readiness.sh
scripts/capture-performance-evidence.sh performance.json 7 3
scripts/verify-performance-baseline.sh \
  Evidence/Performance/macos-27.0-26A5388g-arm64-macbookpro18,3.json
```

`verify.sh` 执行 macOS 测试、Release 构建、ImageIO 行为证据确定性检查与 source identity v2；身份摘要对 schema/identity ID 做域分离，绑定每个文件的可执行位，并区分仅顶层构建排除、任意层级临时文件排除和两个精确声明的 ConsumerSmoke 构建缓存子树。`verify-clean-copy.sh` 从完整身份清单物化无 Git、无构建缓存副本并重放 `verify.sh`。iOS Simulator 编译门单独运行，避免普通本地迭代每次重建双架构产物。`ImageCraftEvidence` 会记录实际运行时、固定输入输出摘要、JPEG SOF/采样结构和量化表摘要。独立 oracle 门使用 libjpeg-turbo 与 libpng，不进入生产依赖。受版本管理的 retained corpus 固化 PNG/JPEG/GIF 的代表性与边界位流、SHA-256 和稳定失败语义；公共符号图 baseline 阻止内部研究接口泄漏。性能门使用独立进程、Release 构建、3×7 样本和采样 RSS，只作为绑定硬件与系统版本的显式门禁，不进入默认动态验证。当前集成门另外验证根包声明、独立消费者、macOS 12、iOS 15 Simulator 和 iOS 15 device Release 编译。详见 `docs/EVIDENCE.md`、`docs/INDEPENDENT_ORACLES.md`、`docs/RETAINED_CORPUS.md`、`docs/PERFORMANCE.md`、`docs/INTEGRATION_CONTRACT.md`、`docs/RELEASING.md` 与 `docs/PUBLIC_API.md`。

## 仓库状态

ImageCraft 已作为独立 SwiftPM 仓库维护。`main` 是 pre-1.0 开发分支，可能发生破坏性变化；可复现集成应固定到已验证的精确提交或不可变开发标签。Fovea 仅通过公开产品与版本化 codec 契约集成，不复制 ImageCraft 生产源码。

详见 `docs/ARCHITECTURE.md`、`docs/ENCODING_CONTRACT.md`、`docs/EVIDENCE.md`、`docs/INDEPENDENT_ORACLES.md`、`docs/RETAINED_CORPUS.md`、`docs/PERFORMANCE.md`、`docs/INTEGRATION_CONTRACT.md`、`docs/RELEASING.md`、`docs/PUBLIC_API.md` 与 `ROADMAP.md`。

## 平台边界

包当前面向 iOS 15+ 与 macOS 12+。`ImageCraftCore` 的公开值类型仍包含 `CGImage`，因此当前不是 Linux/Windows 可构建包；跨平台核心需要另行拆出不含 Core Graphics 的纯语义层，不能仅靠条件编译伪装完成。

## 许可

本项目采用 MIT License。详见 `LICENSE`。
