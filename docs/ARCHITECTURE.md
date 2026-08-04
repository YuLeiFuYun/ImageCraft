# 架构边界

## 核心临界问题

ImageCraft 必须回答的不是“ImageIO 能否打开某种文件”，而是：在明确的输入、资源、颜色、帧和输出契约下，后端能否保守地探测、解码或编码，并给出稳定失败分类与可复用身份。

## 依赖方向

```text
ImageCraftCore
  Foundation + CoreGraphics value contracts
        ↑
ImageCraftImageIO
  ImageIO adapter, validation, decode/encode implementation
        ↑
Host application (optional)
  network/cache/UI/identity/persistence
```

`ImageCraftCore` 不得导入 ImageIO。`ImageCraftImageIO` 不得导入任何宿主模块。

## 所有权

ImageCraft 拥有：

- 容器探测与格式限制；
- 解码/编码请求与能力描述；
- 像素、颜色、方向和 metadata 解释；
- prepared-state 与渐进会话生命周期；
- codec 内部资源估计与失败分类。

宿主拥有：

- URL、HTTP、认证和下载恢复；
- ContentID、DecodeKey、RenderKey 与 namespace；
- 缓存、调度、UI 和持久发布；
- 多 codec 选择与 rollout policy。

## 兼容身份

解码器当前保留 codec identifier `dev.fovea.imageio`，因为该值参与宿主派生缓存身份。迁移到新的标识符必须作为显式破坏性变更处理，并要求宿主建立新缓存代际。

## 编码数据流

```text
CGImage + ImageEncodeRequest + EncodeLimits
  -> finite capability negotiation
  -> dimension/pixel admission
  -> explicit color conversion and/or alpha flatten
  -> CGImageDestination PNG/JPEG encode
  -> bounded CGDataConsumer write-time hard limit
  -> independent bounded container self-inspection
  -> EncodedImage
```

静态能力缺口先于源相关策略失败判定。例如 lossy PNG 必须稳定报告 compression capability 缺口，不能因为源同时带 alpha 而随机改报另一原因。

输出字节限制由 bounded `CGDataConsumer` 在写入期强制执行；拒绝越界写入后，已接受缓冲区不会超过预算。该约束只证明输出 consumer 缓冲区，不证明 ImageIO 内部编码工作集或 Core Graphics 像素表面的总峰值。

## 编码与解码身份

解码器使用 `dev.fovea.imageio`，以保持既有宿主派生缓存身份。新编码器没有历史缓存兼容义务，使用独立身份 `dev.imagecraft.imageio.encoder`。两者 contract/version fingerprint 分开演进，不能用一个版本号推断另一方向的语义。


## 系统框架证据边界

ImageIO 的行为版本不等于 ImageCraft 源码版本。`ImageIORuntimeFingerprint` 把 OS build、架构、ImageIO/Core Graphics bundle version 与 encoder fingerprint 绑定。`ImageCraftEvidence` 使用版本化固定输入生成机器可读报告，并记录 PNG/JPEG 字节摘要、JPEG frame marker、采样因子和量化表摘要。

报告只描述被测环境和被测输入，不自动升级为跨 OS 能力声明。新的系统 build 必须生成新 baseline；差异必须分类，不能静默覆盖。

## 独立 Oracle 边界

libjpeg-turbo 与 libpng 只由 `scripts/verify-independent-oracles.sh` 和 `Tools/Oracle` 使用，不作为 SwiftPM target 依赖。验证矩阵同时覆盖 ImageIO 编码结果被独立 decoder 消费，以及 ImageIO decoder 消费独立 encoder 结果。JPEG 不要求逐字节或逐像素相等，而使用容器可接受性、尺寸、PSNR 下界和质量趋势作为固定 corpus 的回归证据。

## Retained Corpus 边界

`Tests/ImageCraftImageIOTests/Resources/Corpus/v1` 是测试证据，不是运行时产品资源。manifest 将输入字节身份、生成谱系、期望 probe/decode 结果和稳定失败分类绑定；SHA-256 防止 fixture 被测试辅助代码无意重写。metadata 精确边界使用当前 probe 的完整观察值，不把 ImageIO 属性序列化大小假定为跨 OS 常量。

corpus 版本只追加、不原地改变语义。工具升级、位流变化或期望行为变化必须新建版本，或通过显式审查更新并记录原因。


## 公共 API 收敛

ImageCraft 公开 codec 请求、限制、结果、descriptor、JPEG 渐进会话和 ImageIO adapter；UI 几何分桶、render-cache admission、transform pipeline、预览替换策略与 frame timing 值模型属于宿主或未来模块，不进入当前公共面。运行时 fingerprint 和详细诊断只服务本仓库证据，保持 package-only。

渐进 JPEG parser 只增量消费新增 marker/entropy 字节；累计字节传给 ImageIO 是系统增量源 API 的要求，但只在预览尝试或 finish 时更新，而不是每个网络分片更新。ImageIO adapter 仅在第 1、2、4、8 个已完成 scan 达到时尝试预览，将昂贵光栅化限制为常数上界；一次 append 最多返回一个代次，并可合并同一 chunk 跨过的多个阈值。真实照片矩阵已证明 chunk overshoot 会改变代次数量与同序号像素，因此 generation 只有单会话顺序语义，`sourceByteCount` 只有累计 append 边界语义。完整正文若一次到达可以零预览完成。该会话不承担完整正文真实性、尾随数据、最终颜色或最终缓存发布，宿主必须让完整正文重新进入常规安全解码路径。

宿主在取消、view identity 变化或请求替换时，必须先关闭该请求的像素发布权限，再调用并等待 `session.cancel()`；ImageIO 操作本身不能中途抢占，取消可能阻塞在当前 append 的会话锁之后。frame cadence 合并、latest-wins、MainActor 调度和最终像素替换同样属于宿主/UI 边界，不得反向进入 codec generation 语义。

容器 scanner 的目标是为资源 admission 提供最小结构事实，而不是复制 ImageIO codec。JPEG entropy/Huffman/IDCT、PNG filter/interlace/palette 和最终压缩流合法性继续委托给系统框架。完整边界见 `docs/PUBLIC_API.md`。


## 性能证据边界

性能工具位于 `ImageCraftEvidence`、`Tools/Performance` 和 `scripts`，不进入两个库产品的公共 API。fixture 构造、reference SHA-256、RSS sampler 与 JSON 输出不计入操作耗时；ImageCraft admission、ImageIO 调用、颜色/几何后处理和输出 container 自检计入。RSS 在独立单操作阶段采样。

`ImageDecodeResourceEstimate` 是像素表面模型，不是进程 RSS 上界。性能报告并列记录估计值和采样 resident delta，但不要求二者相等。动态性能门必须绑定同一硬件、系统框架和工具链；默认验证只做静态 baseline 检查。


## 外部消费者边界

`Fixtures/ConsumerSmoke` 是独立 SwiftPM package，而不是根包的 test target。它只能导入 `ImageCraftCore` 和 `ImageCraftImageIO` 的 public API；任何误把 package-only 类型写进公开示例或必要集成路径的改动都会在消费者编译时失败。

平台矩阵只验证源码能够以声明的最低部署目标编译：macOS 12、iOS 15 Simulator、iOS 15 device。它不把 Simulator 编译成功解释为真机运行时、能耗、EDR 或跨 OS ImageIO 行为证据。
