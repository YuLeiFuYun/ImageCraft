# 公共 API 与职责边界

## 目标

ImageCraft 的公开接口只描述宿主确实需要依赖、并且当前实现能够兑现的编解码语义。研究工具、证据采集、UI 布局、缓存准入和未来 codec 设想不得因“以后可能有用”而进入公共 API。

当前仓库尚未发布 1.0；本次收敛建立首个最小 contract v1。从本里程碑起，公共符号由 `API/PublicAPI.json` 固定。任何新增、删除或签名变化都必须通过显式 baseline 更新接受，不能作为普通内部重构的副作用发生。

## 两个公共库产品

### ImageCraftCore

公开：

- 编码格式、目标像素、fit/fill、颜色策略；
- 解码和编码资源限制；
- probe、decoded/encoded result 和稳定错误分类；
- 基础 decoder/encoder 协议；
- prepared decode 一次性状态；
- JPEG 渐进会话、非最终像素代次和接收字节计数；
- codec/encoder 身份、版本和有限能力 descriptor；
- 保守资源估计结果。

不公开：

- UI 点尺寸、display scale、尺寸分桶和迟滞；
- render-cache admission；
- 图像变换管线；
- 动画 frame timing 值模型；
- 证据采集时长、性能/RSS 采样和运行时 framework fingerprint；
- Fovea 的 ContentID、DecodeKey、RenderKey、namespace 或缓存策略。

能力 descriptor 以 `progressiveFormats` 显式限定 delivery mode 与容器格式的组合；当前只有 JPEG 可声明渐进交付。动画、HDR 与 pixel buffer 等词汇仍用于明确报告“不支持”，不代表已有对应交付模型。

### ImageCraftImageIO

公开面仅包括：

- `ImageIOImageDecoder`；
- `ImageIOImageEncoder`；
- 两者公开协议所要求的操作和 descriptor；
- `ImageIOImageDecoder.makeProgressiveSession` 的 JPEG 增量适配。

运行时 fingerprint、诊断计时、container inspection 结果、bounded consumer 和 evidence 辅助接口均为 package-only。

## ImageCraft 与 ImageIO 的职责分工

### ImageCraft 保证

- 在进入 ImageIO 前检查编码字节上限和允许格式；
- 对 PNG/JPEG/GIF 执行满足 admission 所需的最小容器结构扫描；
- 统计有限 metadata 字节，检查完整终止和尾随数据；
- 检查 frame、dimension、pixel 和 auxiliary attachment 上限；
- 将 EXIF orientation 纳入 probe 和目标几何；
- 执行明确的 preserve-source 或 convert-to-sRGB 策略；
- 对 prepared state 执行同实例、同 limits、一次性消费约束；
- 渐进会话按增量游标解析 JPEG marker，保留字节不超过 `maximumEncodedBytes`，只在完整 scan 边界尝试预览；当前 ImageIO adapter 使用 1/2/4/8 scan 几何阈值，将预览光栅化限制为最多四次；
- 代次严格递增，取消后 append/finish 均稳定失败，旧 descriptor 缺失 `progressiveFormats` 时保守解码为空集合；
- 为公开失败提供稳定的 ImageCraft 错误分类；
- 编码时对输出 consumer 强制字节硬上限，并在返回前自检容器。

### ImageIO/Core Graphics 负责

- JPEG entropy/Huffman 解码、IDCT 和色度上采样；
- PNG filter、Adam7 interlace、palette、bit depth 和像素展开；
- GIF 图像数据解码；
- 实际光栅分配、缩略图生成和颜色转换执行；
- JPEG/PNG 编码算法及系统框架内部工作内存；
- 对 codec 语义合法性的最终判断。

ImageCraft 的 container scanner 不是第二套 JPEG/PNG/GIF codec，也不验证完整 Huffman、quantization、filter 或压缩流语义。

## 明确不保证

当前版本不保证：

- 任意损坏文件在所有 Apple OS build 上得到完全相同的 ImageIO 接受/拒绝结果；
- 不同 OS build 的编码字节或解码像素逐字节相同；
- ImageIO 正在执行的单次预览生成可被中途打断；
- baseline JPEG、PNG 或 GIF 的 progressive preview；
- 渐进代次是感知质量分数，或最后一个预览等同最终像素；
- 动画时间轴、disposal 和 loop；
- HDR/gain map/auxiliary image 交付；
- 任意 EXIF/XMP/IPTC metadata 透传；
- ImageIO 私有工作集受 `maximumEncodedBytes` 或 `maximumMetadataBytes` 约束；
- ImageCraft 对完整 PNG/JPEG/GIF 标准进行 conformance validation。

## 版本规则

- 公共 Swift 符号变化：直接更新当前实现与 `API/PublicAPI.json`；删除旧符号，不保留 deprecated shim；
- 像素、颜色解释、错误分类或资源语义变化：递增对应 codec/encoder `implementationVersion`；
- descriptor/request 的持久化契约变化：递增 `contractVersion`；
- 仅证据、测试、package-only 诊断或内部实现变化：不要求公共 API 版本变化；
- 当前尚无外部用户，仓库只维护最新 API；稳定兼容政策在首次真实采用前另行决策。

验证：

```sh
scripts/verify-public-api.sh
```

有意修改公共 API 后：

```sh
scripts/update-public-api-baseline.sh
```


## 外部消费验证

`scripts/verify-consumer-package.sh` 构建 `Fixtures/ConsumerSmoke`。该 fixture 是独立 package，因此 Swift 的 `package` 访问级别不会跨越 package boundary；它同时导入两个公开库产品，并在 macOS、iOS Simulator 和 iOS device 上编译。
