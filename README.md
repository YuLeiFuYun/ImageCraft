# ImageCraft

ImageCraft 是独立于网络加载、缓存、UI 与持久化系统的 Apple 平台图像编解码工程。

## 开发工具链

- Xcode 27.0 或更新版本；
- Apple Swift 6.4，SwiftPM tools 6.4；
- 运行基线仍为 iOS 15 / macOS 12，不因编译器迁移而提高；
- `scripts/select-xcode.sh` 与 `scripts/check-swift-toolchain.py` 会拒绝旧工具链。
- GitHub CI 显式使用 `xcode-27` preview runner，不依赖会漂移的 `macos-latest`。


当前仓库提供四个 SwiftPM 库产品，并附带一个证据工具：

- `ImageCraftCore`：版本化 codec capability profiles、资源、prepared-state、颜色、像素与 fit/fill 解码契约；
- `ImageCraftImageIO`：基于 Apple ImageIO/Core Graphics 的参考实现；
- `ImageCraftPDF`：基于公开 Core Graphics PDF API 的窄单页文档光栅化参考实现；PDF 不伪装成 `EncodedImageFormat`，当前只资格化未加密单页、零旋转、sRGB 8bpc 输出，多页/加密/非零旋转保持 fail-closed；
- `ImageCraftSVG`：基于公开 Foundation `XMLParser` + Core Graphics 的严格 SVG v1 子集；SVG 同样不伪装成 `EncodedImageFormat`，要求 `viewBox`，当前只接受 fill-only `svg/g/rect/circle/ellipse/path` 与 M/L/H/V/C/S/Q/T/Z path 命令。DTD/entity、处理指令、脚本、CSS/style、文本、外部引用、image/use、字体、stroke、transform、gradient/filter/mask/clip、animation 与 arc 全部 fail-closed；
- `ImageCraftEvidence`：package-internal 行为证据与 fixture 工具，不属于库的公共 API。

## 当前边界

当前实现已支持：

- 有界 PNG/JPEG/GIF/WebP/HEIF 探测与静态主帧解码；当前 ImageIO 运行时若公开 `public.avif`，同一 bounded ISO-BMFF 安全门会额外宣告 AVIF 静态主帧能力。AVIF 已有受控 8-bit alpha 与 10-bit SDR/sRGB `preserveSource` 证据：原尺寸和 ImageIO 小目标回退都保留高位深 Core Graphics 输出；`ImageProbe.sourceBitsPerComponent` 把已知源位深带入工作集估算，未知位深则按保守 32-bit component storage 上界处理。WebP 另外支持经 RIFF `VP8X/ANIM/ANMF` 严格验证的动画时间轴，HEIF/AVIF 序列仍保持未支持；
- JPEG 渐进扫描的有界增量会话、严格递增的非最终像素代次与取消封锁；
- GIF/APNG/WebP 精确时间轴与预分帧 JPEG sequence，支持按需单帧、有界连续帧窗口、loop/disposal/blend 元数据和整体取消；
- 目标尺寸缩放、方向、ICC/颜色策略、metadata 预算和有聚合 retained-byte authority 的 bounded prepared state；
- 静态 PNG 无损编码与 JPEG 有损编码；
- 显式质量、色彩策略、方向、alpha preserve/reject/flatten 和写入期输出字节硬上限；
- 解码与编码各自独立的 capability descriptor、稳定失败分类和版本 fingerprint。
- 解码 capability descriptor 由有限 `ImageDecodeCapabilityProfile` 列表组成：单个 profile 内各轴形成真实可兑现的合取，profile 列表形成有限析取；支持判定不能从不同 profile 借用格式、delivery、track、metadata、dynamic-range 或 output 能力拼出不存在的组合。
- PDF/SVG 使用各自独立的 document/vector rasterization contract；两者的 modeled working set 只覆盖可证明的目标光栅表面，不把 Core Graphics/XML parser 的框架私有 allocation 宣称为 hard RSS bound。
- `ImageCraftImageIO` implementation v12 在 macOS 14 / iOS 17+ 按当前 ImageIO runtime 的实际 source registration 声明窄的 direct-HDR HEIF/HEIC 与 AVIF profile：仅当对应 HEIF/HEIC source type 或 `public.avif` 已注册时，才广告 `completeFrame + primaryFrame + dynamicRange=.high + coreGraphicsImage`。该 profile 只允许 `ImageDecodeRequest(dynamicRange: .high, colorPolicy: .preserveSource)` 的 framework-native `CGImage` 输出；ImageIO 以公开 `kCGImageSourceDecodeToHDR` 请求目标动态范围，发布前仍用公开 Core Graphics HDR/extended-range 判定做双向后置校验，并在 macOS 15 / iOS 18+ 额外检查 `CGImage.contentHeadroom`。默认/旧 `.standard`、`.high + convertToSRGB`、SDR source 的 `.high` 和 packed RGBA8 路径仍失败关闭。10/12-bit source depth 本身也不等于 HDR。
- v12 继续固定 ISO gain-map 的安全/资源边界：Xcode 27 的 `kCGImageAuxiliaryDataTypeISOGainMap` 可能不出现在 `kCGImagePropertyAuxiliaryData` 中，因此 adapter 会用公开 auxiliary API 显式探测、去重并计入 `ImageProbe.auxiliaryAttachmentCount`；未列在主属性字典里的 gain-map description/XMP 也计入 `metadataByteCount`。默认 `DecodeLimits.coreV1(maximumAuxiliaryAttachments: 0)` 会拒绝该输入；调用方显式允许至少 1 个附件后，当前 macOS runtime 能把 retained 16×8 HEIC gain map 以 `.high + preserveSource` 解为 HDR，并按至少 8 B/px 的 high-range working-set 模型计费。当前 iOS 27 simulator 能识别同一 ISO gain map，但 `DecodeToHDR` 仍返回 sRGB/headroom=1，所以 ImageCraft 按 high 后置条件失败关闭；`scripts/verify-hdr-ios-runtime.sh` 固定验证这一平台差异，而不是把 macOS 结果外推到 iOS。

它明确不声明 baseline JPEG、PNG 或 GIF 的渐进代次。MJPEG 只提供一个显式 opt-in、transport-agnostic 的 `multipart/x-mixed-replace` body framer：调用方给出 outer Content-Type 与 header/frame/count 上限，framer 只发布已通过后继 delimiter 验证的 JPEG part，并公开 framing algorithm 的 logical retained-payload 上界；它不实现 HTTP chunked transfer、连接/重试/恢复、URLSession、JPEG 像素解码、display-link 播放时钟、UI 帧缓存、掉帧、后台可见性或 Reduce Motion 策略。除上述窄的 HEIF/AVIF direct-HDR profile 与当前 macOS ISO gain-map 应用切片外，也不声明 gain-map 原始附件交付/选择 API、gain-map JPEG/AVIF、tone mapping、HDR 动画/渐进、planar/pixel-buffer 输出、ImageIO 操作中途可中断取消、任意 EXIF/XMP 透传或跨 OS 字节确定性。渐进会话只产生预览；完整正文仍须经过常规 probe/decode 路径生成最终像素。

四个 Swift 库产品与运行时不依赖 Fovea、HTTP、URLSession、缓存、安全 namespace、UI 或 AxiomRaster。`Tools/Quality/AxiomPackedProbe` 仅是可选的 cross-backend research probe，会读取 pinned sibling AxiomRaster 仓库；它不进入库产品。Fovea 中的宿主集成与 DecodeKey/RenderKey 身份测试仍应留在 Fovea。

SVG 后端 implementation v2 将 S/T 平滑曲线反射生成的控制点纳入同一坐标上限，并让两类反射共享同一受限坐标路径；输入数字合法不再意味着派生控制点可以越界。探测和光栅化复核都在进入 Core Graphics 路径操作前拒绝越界控制点，合法边界及不同曲线类型之间的控制点重置保持原有像素语义。

## SwiftPM 使用

公开开发仓库位于 `https://github.com/YuLeiFuYun/ImageCraft`。项目尚未发布稳定版本；宿主应固定到经过验证的精确提交：

```swift
.package(url: "https://github.com/YuLeiFuYun/ImageCraft.git", revision: "<verified-commit>")
```

目标依赖只选择公开库产品：

```swift
.product(name: "ImageCraftCore", package: "ImageCraft")
.product(name: "ImageCraftImageIO", package: "ImageCraft")
// 文档/矢量能力按需选择：
.product(name: "ImageCraftPDF", package: "ImageCraft")
.product(name: "ImageCraftSVG", package: "ImageCraft")
```

`Fixtures/ConsumerSmoke` 是一个独立 SwiftPM 消费者，持续证明四个公开库产品无需访问 package-internal 实现即可在 macOS 和 iOS 上编译，并实际执行 PDF/SVG 以及窄 public bounded-codec 路径。baseline JPEG 现在有一个显式 opt-in 的 `BoundedBaselineJPEGDecoder`：它只接受完整尺寸 8-bit baseline JFIF color JPEG，公开域是已独立资格化的 4:4:4 / 4:2:2 / 4:2:0 三种 sampling、显式 `.fit + .convertToSRGB + .standard` 请求，返回 tight `ImagePackedRGB8`，并在解码前给出 codec-owned phase ledger；默认 `ImageIOImageDecoder` 路由不变，progressive、grayscale、4:4:0、ICC/Exif/未知 APP、resize 与 HDR 仍不在这条 public slice 中。

`ConformanceKits/ImageCodec/v1` 是 `ImageCodec` v1 合同拥有的可复用资格 kit。它使用固定 SHA-256 fixture、6,144 项有限能力域和版本化 observation schema；默认同时对 `Fixtures/CodecConformance` 的完整 ImageIO descriptor 与 `Fixtures/LimitedCodecConformance` 的故意窄化 PNG/complete-frame descriptor 运行同一 9 条义务，证明 kit 能跨 package 边界并处理合法的缺能力 backend。参考 fixture 精确覆盖 PNG/JPEG/GIF/WebP/HEIF/AVIF，窄化 fixture 复用公开 ImageIO 像素实现，因此不是第二个独立像素 backend。`ConformanceKits/ImagePackedRGB8/v1` 独立验证 baseline-JPEG one-shot RGB8 的完整有限 sampling union：同一 6 条义务逐一覆盖 23×13 JFIF 4:4:4 / 4:2:2 / 4:2:0，三份 source 与 libjpeg-turbo 3.2.0 独立 RGB oracle 都 SHA-256 冻结，transfer 均为 897 B，exact operation 分别是 1,601 / 3,073 / 3,777 B，并固定 caller-owned encoded-source coexistence、request/DecodeLimits 与 charge-1 hard budget。`ConformanceKits/ImagePackedRGBA8/v1` 则验证公开 `ImagePackedRGBA8Decoding` 的有界 PNG profile：6 条义务绑定固定 2×1 sRGB PNG、packed capability、全 phase 有界 ledger、caller-owned encoded-source coexistence、精确 tight premultiplied RGBA8/transfer charge、DecodeLimits 与硬 operation budget。这些小型 contract-owned 报告都固定 `releaseQualified=false`，不能替代 hostile corpus、设备资源、宿主 composition 或发布资格证据。

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
    source: .encoded(gifAPNGOrWebPData),
    limits: ImageAnimationDecodeLimits(maximumFrameDecodeWindow: 8)
)
let target = try TargetPixels(width: 512, height: 512)
let frames = try await asset.frames(
    in: 0..<min(8, asset.metadata.frameCount),
    request: ImageDecodeRequest(target: target, colorPolicy: .convertToSRGB)
)
```

`ImageAnimationFrameDuration` 保留容器的精确有理数秒值。公开 duration、loop、frame rect 与 frame descriptor 在 `Codable` 反序列化时重新执行构造器不变量；缺失 loop 字段不会静默变成无限循环。宿主负责播放时钟、窗口预取、掉帧与可见性；ImageCraft 不把这些 UI 策略塞入 codec。动画入口严格执行 `DecodeLimits.allowedFormats`；APNG 在交给 ImageIO 前验证每个 chunk 的 CRC、critical/reserved type、`IDAT` 连续性、控制序列和早期帧数上限；GIF user-input control 与 Plain Text graphic block 因当前播放合同不建模交互或文本渲染而显式拒绝；WebP 在进入 ImageIO 前验证 RIFF 总长、`VP8X` 动画标志、`ANIM/ANMF` 顺序、保留位、画布/帧矩形、毫秒时长、loop、blend/disposal 和嵌套 VP8/VP8L 帧尺寸，系统后端只负责输出已合成的完整画布索引帧；HEIF/AVIF sequence 仍未进入动画 capability。JPEG sequence 对整条序列累计元数据预算。`maximumTimelineDecodedBytes` 先按逻辑 RGBA 轨道做 admission，再在实际帧 publication 前按 `CGImage.bytesPerRow × height × frameCount` 复核。JPEG 动画当前只接受上层已分帧的完整 JPEG 数组，尚不解析网络 `multipart/x-mixed-replace`。

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
scripts/verify-image-codec-conformance-kit.sh
scripts/verify-image-packed-rgb8-conformance-kit.sh
scripts/verify-image-packed-rgba8-conformance-kit.sh
scripts/verify-clean-copy.sh
scripts/verify-integration-contract.sh
scripts/verify-consumer-package.sh
scripts/verify-platform-matrix.sh
scripts/verify-release-readiness.sh
scripts/capture-performance-evidence.sh performance.json 7 3
scripts/verify-performance-baseline.sh \
  Evidence/Performance/macos-27.0-26A5388g-arm64-macbookpro18,3.json
```

`verify.sh` 执行 macOS 测试、Release 构建、ImageIO 行为证据确定性检查、跨包 `ImageCodec` 与 bounded `ImagePackedRGBA8` conformance，以及 source identity v2；身份摘要对 schema/identity ID 做域分离，绑定每个文件的可执行位，并区分仅顶层构建排除、任意层级临时文件排除和两个精确声明的 ConsumerSmoke 构建缓存子树。`verify-clean-copy.sh` 从完整身份清单物化无 Git、无构建缓存副本并重放 `verify.sh`。iOS Simulator 编译门单独运行，避免普通本地迭代每次重建双架构产物。`ImageCraftEvidence` 会记录实际运行时、固定输入输出摘要、JPEG SOF/采样结构和量化表摘要。独立 oracle 门使用 libjpeg-turbo 与 libpng，不进入生产依赖。受版本管理的 retained corpus 固化 PNG/JPEG/GIF 的代表性与边界位流、SHA-256 和稳定失败语义；公共符号图 baseline 阻止内部研究接口泄漏。性能门使用独立进程、Release 构建、3×7 样本和采样 RSS，只作为绑定硬件与系统版本的显式门禁，不进入默认动态验证。当前集成门另外验证根包声明、独立消费者、macOS 12、iOS 15 Simulator 和 iOS 15 device Release 编译。详见 `docs/EVIDENCE.md`、`docs/INDEPENDENT_ORACLES.md`、`docs/RETAINED_CORPUS.md`、`docs/PERFORMANCE.md`、`docs/INTEGRATION_CONTRACT.md`、`docs/RELEASING.md` 与 `docs/PUBLIC_API.md`。

## 仓库状态

ImageCraft 已作为独立 SwiftPM 仓库维护。`main` 是 pre-1.0 开发分支，可能发生破坏性变化；可复现集成应固定到已验证的精确提交或不可变开发标签。Fovea 仅通过公开产品与版本化 codec 契约集成，不复制 ImageCraft 生产源码。

详见 `docs/ARCHITECTURE.md`、`docs/ENCODING_CONTRACT.md`、`docs/EVIDENCE.md`、`docs/INDEPENDENT_ORACLES.md`、`docs/RETAINED_CORPUS.md`、`docs/PERFORMANCE.md`、`docs/INTEGRATION_CONTRACT.md`、`docs/RELEASING.md`、`docs/PUBLIC_API.md` 与 `ROADMAP.md`。

## 平台边界

包当前面向 iOS 15+ 与 macOS 12+。`ImageCraftCore` 的公开值类型仍包含 `CGImage`，因此当前不是 Linux/Windows 可构建包；跨平台核心需要另行拆出不含 Core Graphics 的纯语义层，不能仅靠条件编译伪装完成。

## 许可

本项目采用 MIT License。详见 `LICENSE`。
