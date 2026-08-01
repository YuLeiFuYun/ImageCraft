# ImageCraft 独立推进路线

## M0：仓库级解绑 — 已完成

- 独立 SwiftPM package；
- `ImageCraftCore` 与 `ImageCraftImageIO` 两个产品；
- 去除 Fovea/Akashic/HTTP 依赖；
- 迁移 codec 契约、解码与安全测试；
- Fovea 宿主身份和 admission 集成测试不越界迁入。

## M1：提取稳定化

- 冻结最小公开 API、职责边界与 symbol-graph gate（已完成）；
- 补齐 DocC；Linux/Windows 不支持边界、独立消费者和 macOS 12 / iOS 15 编译矩阵已机器化；
- 将 conformance fixture 与测试编号机器化；
- 保留少量针对自有 container scanner 的 fuzz 回归；retained boundary corpus v1 已完成；
- 建立 Release 性能与采样峰值 RSS 基线（首个 macOS/MacBookPro18,3 基线已完成）；
- 为 ImageIO 闭源行为记录 OS/build fingerprint。

## M2：ImageIO 编码契约 — M2a 已完成，M2b 待推进

### M2a：首个生产垂直切片 — 已完成

- 独立 `ImageEncoding`、`ImageEncoderDescriptor` 与有限能力集合；
- PNG lossless 与 JPEG lossy 静态编码；
- 有界 quality、orientation、颜色与 metadata policy；
- alpha preserve/reject/显式背景 flatten，JPEG 不静默丢弃透明度；
- 尺寸、像素与最终可接受输出字节限制；
- 输出容器二次自检与独立编码失败分类；
- PNG/JPEG round-trip、P3/sRGB、方向、alpha 和负向契约测试。

### M2b：证据与硬边界 — 待推进

- bounded `CGDataConsumer`，把输出上限升级为写入期硬边界（已完成）；
- libjpeg-turbo/libpng 固定合成 differential oracle（已完成）；retained boundary corpus v1（已完成）；不以大规模真实图像 corpus 阻塞发布；
- 质量/色度采样行为探针与 OS/build/framework fingerprint（首个 macOS 基线已完成）；
- 确定性合成 corpus、retained boundary corpus、macOS 行为 baseline 和首个性能/RSS baseline（已完成）；跨 macOS/iOS matrix、真机能耗与更多硬件基线待推进；
- 任意 metadata transport 之前先定义白名单 schema 和大小预算。

## M3：增量与多帧能力研究 — 非 1.0 阻塞项

- `CGImageSourceCreateIncremental` 的真实 suspension/更新语义；
- preview generation 与 final promotion，不把 API 存在误报为生产能力；
- GIF/APNG/HEIF 多帧时间、disposal、loop 与 frame window；
- 明确 ImageIO 可兑现能力和必须失败关闭的边界。

## M4：HDR、辅助图像与输出表示 — 非 1.0 阻塞项

- gain map、auxiliary image、HEIF/AVIF 系统能力探测；
- ICC/CICP/HDR precedence；
- CGImage、CVPixelBuffer 与 planar buffer 所有权；
- 真机 EDR、内存、能耗和 OS 差异证据。

## M5：Fovea 物理接入

- 公开 remote 与核心 CI 已配置；完成 required-check、clean-clone 和稳定版本治理后发布首个独立版本；
- Fovea 改为 SwiftPM 依赖；
- 双仓 conformance 与 compatibility gate；
- 保留 codec fingerprint 隔离和回滚演练。
