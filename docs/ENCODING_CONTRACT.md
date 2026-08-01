# ImageIO 静态编码契约

## 核心问题

编码接口必须回答的不是“能否把 `CGImage` 写成某个 UTI”，而是：

> 在给定格式、压缩、颜色、方向、alpha 和资源限制后，输出字节是否兑现同一组可观察语义，并在无法兑现时稳定失败，而不是静默降级？

## v1 支持域

`ImageIOImageEncoder` 当前声明：

| 轴 | PNG | JPEG |
|---|---|---|
| 压缩 | lossless | lossy，质量 `0...1` |
| alpha preserve | 支持 | 不支持 |
| alpha flatten | 支持 | 支持 |
| color preserve | 支持可表达的源色彩空间 | 支持可表达的源色彩空间 |
| convert to sRGB | 支持 | 支持 |
| orientation | `1...8`，仅 `preserveRecognized` | `1...8`，仅 `preserveRecognized` |
| 多帧 | 不支持 | 不支持 |
| 任意 EXIF/XMP | 不支持 | 不支持 |

GIF 仍可由解码器探测，但当前编码 descriptor 不声明 GIF。

## 请求正规形

一次请求必须显式给出：

```text
format
compression
color policy
metadata policy
optional orientation
alpha policy
```

PNG 只接受 `.lossless`；JPEG 只接受 `.lossy(quality)`。这些规则在编码前由 `ImageEncoderDescriptor` 判定，不能交给 ImageIO 隐式猜测。后端能力缺口与宿主 `EncodeLimits.allowedFormats` 是两层不同失败：前者返回 `unsupportedCapability`，后者返回 `formatNotAllowed`。

## Alpha 规则

`CGImage.alphaInfo` 是权威的像素格式声明。即使当前所有样本值都是 255，只要格式声明存在 alpha 通道，源仍被视为含 alpha。

- `.preserve`：目标格式必须声明 alpha-preserving；
- `.reject`：源有 alpha 时返回 `alphaRejected`；
- `.flatten(background:)`：在目标编码色彩空间中先合成到不透明背景。

JPEG 不得隐式抛弃 alpha。调用方必须提供不含 alpha 的源，或显式选择 flatten。

## 颜色规则

- `.preserveSource`：直接保留可表达的源色彩空间；缺失或无法用于 RGB 合成时回退 sRGB；
- `.convertToSRGB`：编码前通过 Core Graphics 光栅化到 sRGB；
- flatten 与颜色转换只生成 8-bit packed RGB/RGBA 中间表面；当前不声明 HDR、浮点或扩展动态范围保持。

颜色配置属于像素解释语义，不被 `metadataPolicy.discard` 当作可随意删除的附属字段。

## Metadata 规则

v1 只建模方向：

- `.discard` 要求 `orientation == nil`；
- `.preserveRecognized` 可写入 `ImageEncodeOrientation(1...8)`；
- 未提供任意 EXIF、XMP、GPS、日期或 maker-note 入口。

这样避免把未验证字典直接转交给 ImageIO，也避免“preserve all”产生无法描述的隐式行为。

## 资源边界

`EncodeLimits` 在编码前限制：

- 最大宽/高；
- 最大像素数；
- 允许格式。

`maximumEncodedBytes` 由 bounded `CGDataConsumer` 在写入期强制执行。任何一次回调若会越过预算，将完整返回 0 且不追加部分数据；已接受的输出缓冲区因此始终不超过上限。回归测试同时覆盖精确等于上限可成功、少 1 字节稳定失败。

该边界只约束 consumer 已接受的容器字节，不证明 ImageIO 内部编码状态、输入 `CGImage`、颜色转换表面或框架私有缓冲区的总峰值。

## 输出自检

ImageIO finalize 成功后，编码器仍使用仓库自身的有界容器检查器验证：

- 输出确实是请求格式；
- PNG 精确终止于 IEND；
- JPEG 精确终止于 EOI；
- 结构可由当前安全检查器接受。

容器自检失败统一映射为 `ImageEncodingError.encodeFailed`，不得泄漏解码层错误分类。

## 不宣称的性质

当前测试证明同一环境中的行为契约，不证明：

- 跨 macOS/iOS 版本字节完全确定；
- JPEG 与其他编码器逐字节相同；
- `maximumEncodedBytes` 是 ImageIO 全部内部工作集的硬上限；
- 任意 ICC、灰度、CMYK、HDR 或浮点输入都保持原语义；
- 编码质量数值在不同 OS 上对应完全相同的量化表。

这些事项必须通过 OS/build fingerprint、独立 oracle 和保留 corpus 单独验证。
