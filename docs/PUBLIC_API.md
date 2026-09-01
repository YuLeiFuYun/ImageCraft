# 公共 API 与职责边界

## 目标

ImageCraft 的公开接口只描述宿主确实需要依赖、并且当前实现能够兑现的编解码语义。研究工具、证据采集、UI 布局、缓存准入和未来 codec 设想不得因“以后可能有用”而进入公共 API。

当前仓库尚未发布 1.0；本次收敛建立首个最小 contract v1。从本里程碑起，公共符号由 `API/PublicAPI.json` 固定。任何新增、删除或签名变化都必须通过显式 baseline 更新接受，不能作为普通内部重构的副作用发生。

## 两个公共库产品

### ImageCraftCore

公开：

- 编码格式、目标像素、fit/fill、颜色策略；
- 解码、prepared-state 聚合和编码资源限制；
- probe、decoded/encoded result 和稳定错误分类；
- 基础 decoder/encoder 协议；
- prepared decode 一次性状态；
- 对**已经创建且仍由 decoder 持有**的 preparation token，可选 `PreparedImageResourceInspecting` 在消费前公开 phase-aware resource ledger；该 ledger 覆盖 token retained state、下一次 decode operation 与 output transfer，但**不**描述或承诺更早的 `prepare(...)` / progressive preparation-creation 操作成本；
- JPEG 渐进会话、非最终像素代次和接收字节计数；
- phase-aware `ImageDecodeResourceLedgerSnapshot`、bounded/unknown resource authority，以及可在消费式 `DecodedImage` finalization 之前非消费读取 resource ledger 的 `ProgressiveImageDecodedImageResourceFinalizingSession`；unknown reason 是合同状态，宿主不得把 tight-pixel estimate 或 RSS 样本替代成缺失的 byte upper bound；
- backend-neutral `ImagePackedRGBA8` 值合同：top-to-bottom tight `bytesPerRow = width * 4`、8-bit RGBA、premultiplied alpha、独立的 sRGB / embedded ICC / RGB cICP output color authority、source-profile provenance，以及 pixel/transfer byte charge。这个公开值类型不等于公开任何 independent decoder，也不改变默认 ImageIO rollout；producer capability 与其 operation resource authority必须另行资格化；
- GIF/APNG 与预分帧 JPEG 序列的动画容器、精确有理数时长、loop、frame rect、disposal、blend、资源限制、按需帧、有界 frame-window，以及可证明时的 whole-track 与单-window decoded/provider-retained/predecode-peak 成本上界；
- codec/encoder 身份、版本和有限能力 descriptor；
- 保守资源估计结果。

不公开：

- UI 点尺寸、display scale、尺寸分桶和迟滞；
- render-cache admission；
- 图像变换管线；
- 播放时钟、display-link、可见性、Reduce Motion、掉帧与 UI frame-cache 策略；
- 证据采集时长、性能/RSS 采样和运行时 framework fingerprint；
- Fovea 的 ContentID、DecodeKey、RenderKey、namespace 或缓存策略。

能力 descriptor 以 `progressiveFormats` 显式限定渐进 delivery mode 与容器格式的组合；当前只有 JPEG 可声明渐进交付。动画由独立 `ImageAnimationDecoding` 契约承载，`ImageIOAnimatedImageDecoder` 只声明 GIF、APNG 与预分帧 JPEG sequence 的 `animatedSequence` 能力；静态 `ImageIOImageDecoder` 不因此改变单图语义。动画入口执行与静态解码一致的格式 allowlist，APNG 控制元数据在 ImageIO 前验证 chunk CRC、critical/reserved type、序列和 `IDAT` 连续性，JPEG sequence 的元数据预算按整条序列累计。GIF user-input control 与 Plain Text graphic block 不进入当前无交互、纯像素动画合同，遇到时失败关闭。公开动画值类型的 `Codable` 解码重新执行构造器不变量；无限 loop 必须由显式 `null` 表示。HDR 与 pixel buffer 等词汇仍只用于明确报告“不支持”。

### ImageCraftImageIO

公开面仅包括：

- `ImageIOImageDecoder`；
- `ImageIOImageDecoder(preparationLimits:)` 的实例级 prepared-store authority；
- `ImageIOImageEncoder`；
- `ImageIOAnimatedImageDecoder`；
- 两者公开协议所要求的操作和 descriptor；
- `ImageIOImageDecoder.makeProgressiveSession` 的 JPEG 增量适配；
- GIF/APNG 单容器与预分帧 JPEG sequence 的异步准备、按需单帧、有界连续帧窗口和整体取消。

运行时 fingerprint、诊断计时、container inspection 结果、bounded consumer 和 evidence 辅助接口均为 package-only。

## ImageCraft 与 ImageIO 的职责分工

### ImageCraft 保证

- 在进入 ImageIO 前检查编码字节上限和允许格式；
- 对 PNG/JPEG/GIF 执行满足 admission 所需的最小容器结构扫描；
- 统计有限 metadata 字节，检查完整终止和尾随数据；
- 检查 frame、dimension、pixel 和 auxiliary attachment 上限；
- 将 EXIF orientation 纳入 probe 和目标几何；
- 执行明确的 preserve-source 或 convert-to-sRGB 策略；
- 对 prepared state 执行同实例、同 limits、一次性消费约束；静态 ImageIO 默认只跨调用保留 encoded `Data` 与纯值安全事实，不保留 `CGImageSource`，并以 `ImageDecodePreparationLimits` 同时约束 live token 数和 aggregate retained byte charge；超限稳定失败为 `preparedStateBudgetExceeded`；
- `ImageIOImageDecoder` 同时公开 `PreparedImageResourceInspecting`：默认 data-only preparation 在消费前可报告已知 retained encoded/value bytes，而 framework-private decode operation 与 framework-chosen output layout 继续显式保持 `.unknown`；重复读取不消费 token，decode/discard 后返回 `nil`。hard-bounded host 必须在 `decode(preparation:...)` 前处理这些 unknown；该能力不能反推 `prepare(...)` 本身已经 bounded；
- 在 ImageIO 帧解码前独立验证 APNG chunk CRC、critical/reserved type、`acTL`/`fcTL`/`fdAT` 顺序、帧数、rect、delay、disposal、blend，以及 GIF GCE、Netscape loop、image descriptor、user-input/Plain Text 拒绝和 sub-block 边界；
- 将动画时长保留为规范化有理数，并以 `maximumTimelineDecodedBytes` 与 `maximumFrameDecodeWindow` 限制总轨道和单次窗口工作；timeline byte limit 先执行逻辑 RGBA admission，再以实际 `bytesPerRow × height × frameCount` 作为 publication postcondition；owned APNG/GIF 后端可额外发布 whole-track 成本证明：`residentDecodedByteCostUpperBound` 约束已解码输出轨道，`providerRetainedByteCostUpperBound` 约束 prepared provider 生命周期内保留的压缩 payload/palette/checkpoint 状态，`predecodePeakByteCostUpperBound` 覆盖二者稳态和有界预解码瞬态；三者都是保守 byte-cost 模型，不是 RSS 或能耗测量；
- JPEG 动画入口只接受上层已经完成分帧的完整 JPEG 数组，并要求所有帧尺寸、方向和颜色配置一致；
- 渐进会话按增量游标解析 JPEG marker，保留字节不超过 `maximumEncodedBytes`，只在完整 scan 边界尝试预览；当前 ImageIO adapter 使用 1/2/4/8 scan 几何阈值，将预览光栅化限制为最多四次；完整 JPEG scanner 与 progressive parser 还共享 package-internal 500-scan CPU-amplification ceiling，超过后在进入后续 ImageIO work 前 fail-closed；该 ceiling 不是公开 `DecodeLimits` 维度或 JPEG 格式上限；
- 代次严格递增，取消后 append/finish 均稳定失败，旧 descriptor 缺失 `progressiveFormats` 时保守解码为空集合；
- 对暴露 `ProgressiveImageDecodedImageResourceFinalizingSession` 的会话，宿主可先调用 `decodedImageFinalizationResourceLedger()`：正文尚未 final-ready 时返回 `nil` 且不得消费会话；非空 ledger 是**整个下一次 finalization operation** 的 resource authority，必须包含调用边界仍由 session 持有的 codec-owned state，而不是只描述内部 materializer helper。消费式 finalization 返回的 ledger 必须与该 preflight authority 一致。要求 hard bounded operation 的宿主必须在调用 finalizer 前处理 `.unknown`，不能通过回退到 value-only finalizer 隐藏未知 framework allocation；
- 对暴露 `ProgressiveImagePreparationCreationResourceInspectingSession` 的会话，`preparationCreationResourceAuthority()` 将 **creation operation** 与 **成功后由 decoder 保留的 preparation state** 分开发布：前者继续使用 phase ledger 表达调用边界 live state/operation unknown/零 caller transfer，后者单独给出 resulting retained known bytes 与 retained bound，不能把 decoder-retained token 偷塞进 `transferredOutput`。ImageIO progressive implementation 在任何 final `CGImageSource` 创建、安全复查或 metadata ImageIO work 前先原子 reserve prepared-store aggregate budget；store-full 因此是 final-ready 可重试 admission failure，释放另一个 token 后同一 session 可以重试。成功后 `PreparedImageResourceInspecting` 的 retained authority 必须与 creation preflight 的 resulting state 一致；
- 静态 `prepare(data:limits:)` 可选地通过 `PreparedImageCreationResourceInspecting` 复用同一 state-transition vocabulary（generic alias 为 `ImageDecodePreparationCreationResourceAuthority`）：调用前 encoded `Data` 仍归 caller，因此 ImageIO preflight 的 call-boundary retained charge 为0、transfer为0、layout为none，而 `operationPeak` 继续显式 `.unknown(.frameworkPrivateOperationAllocation)`。data-only/no-ICC 输入的 resulting retained state 可精确等于encoded bytes；JPEG APP2 ICC在不materialize profile的情况下即可由chunk payload精确计数，因此 resulting retained也可精确为encoded+ICC；PNG iCCP若禁用inflate则只发布metadata-ceiling bound。preflight只运行pure-value security scanner，不创建ImageIO source或prepared-store entry，实际 `prepare` 成功后的token retained authority必须落在/等于该result authority；
- 为公开失败提供稳定的 ImageCraft 错误分类；
- 编码时对输出 consumer 强制字节硬上限，并在返回前自检容器。

### ImageIO/Core Graphics 负责

- JPEG entropy/Huffman 解码、IDCT 和色度上采样；
- PNG filter、Adam7 interlace、palette、bit depth 和像素展开；
- 对未进入 ImageCraft owned APNG/GIF 子集的输入，执行 GIF/APNG 索引帧的最终 canvas 合成与图像数据解码；owned 子集的压缩流/合成由 ImageCraft 自有有界后端完成，最终 `CGImage` 构造、缩放与颜色转换仍由 Core Graphics 路径完成；
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
- 网络 `multipart/x-mixed-replace` 的 MJPEG 分帧、恢复或传输语义；
- 播放时钟、帧缓存、预取、掉帧、后台暂停、可见性和 Reduce Motion 策略；
- animated WebP/HEIF/AVIF、音视频同步或跨容器统一播放行为；
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
