# ImageIO 行为证据

## 为什么必须记录运行时

ImageIO 和 Core Graphics 是系统框架。ImageCraft 的源码与 encoder fingerprint 不变，并不意味着不同 macOS/iOS build 会产生相同 JPEG 量化表、色度采样、容器字节或解码行为。因此任何关于 ImageIO 的实测结论都必须绑定：

- 平台和 OS 版本；
- OS build；
- CPU 架构；
- ImageIO bundle version；
- Core Graphics bundle version；
- ImageCraft encoder fingerprint；
- 固定输入生成器版本。

`ImageIORuntimeFingerprint.capture()` 提供上述运行时身份。它记录实际运行环境，不把编译 SDK 版本误当作系统框架版本。

## 行为探针

`ImageCraftEvidence` 使用确定性的 `imagecraft-pattern-v1` 生成一张 96×64 sRGB 无 alpha 图像，并输出：

- PNG lossless 的字节数和 SHA-256；
- JPEG quality 0.25、0.50、0.75、0.90 的字节数和 SHA-256；
- JPEG SOF 类型、尺寸、位深和分量采样因子；
- DQT payload 的 SHA-256。

运行：

```sh
scripts/capture-imageio-evidence.sh
scripts/verify-imageio-evidence.sh
```

第二个脚本会在同一进程环境配置下连续生成两份报告，要求逐字节一致，并验证 schema 和关键结构不变量。传入 baseline 路径时还会执行精确基线比较：

```sh
scripts/verify-imageio-evidence.sh Evidence/Baselines/macos-27.0-26A5388g-arm64.json
```

## 首份基线

`Evidence/Baselines/macos-27.0-26A5388g-arm64.json` 记录：

- macOS 27.0 build 26A5388g；
- arm64；
- ImageIO bundle 2847 / short version 3.3.0；
- Core Graphics bundle 2047；
- encoder fingerprint `dev.imagecraft.imageio.encoder#impl=2#contract=1`。

该环境下四个 JPEG quality 档位均产生 baseline SOF0，Y 分量采样为 2×2，Cb/Cr 为 1×1，即观测到 4:2:0。quality 改变时，DQT payload 摘要和最终字节数均发生变化。

这只是该 OS build 上固定输入的观测，不是 ImageIO 跨系统版本承诺。后续基线若发生差异，应先分类为框架行为变化、输入/契约变化或工具缺陷，不能直接覆盖旧证据。

## 当前没有证明的事项

该探针不证明：

- 其他图片或所有 quality 都使用相同色度采样；
- 输出大小随 quality 对任意输入严格单调；
- macOS 与 iOS 输出相同；
- ImageIO 与 libjpeg-turbo/libjpeg 的像素或量化策略等价；
- 完整编码工作集受 `maximumEncodedBytes` 约束。

独立 oracle、retained corpus 和首个 macOS 性能/RSS baseline 已建立；iOS 真机、跨 OS matrix 和能耗证据仍需继续建设。

## 独立实现交叉验证

系统框架指纹和自重复性仍可能共同遗漏 ImageIO 内部的系统性错误。`scripts/verify-independent-oracles.sh` 进一步使用 libjpeg-turbo 和 libpng 建立跨实现矩阵，机器可读基线位于 `Evidence/Oracles`。具体误差模型、阈值和限制见 `docs/INDEPENDENT_ORACLES.md`。

## Retained 输入证据

行为 baseline 记录“当前实现对固定生成输入产生什么输出”；retained corpus 则固定“未来实现必须如何处理已经存在的输入位流”。两者不能互相替代。PNG/JPEG/GIF v1 corpus、哈希、测试编号和生成谱系见 `docs/RETAINED_CORPUS.md`。


## 性能与峰值内存证据

`ImageCraftEvidence --benchmark-case` 在 Release 构建中执行固定 decode/encode 场景。`scripts/capture-performance-evidence.sh` 为每个场景启动独立进程，默认聚合 3 个进程。每个进程先在 malloc pressure relief 后单独采样一次操作的 RSS，再关闭 sampler，执行 2 次 warmup 和 7 次计时。RSS 通过 500 微秒轮询 `mach_task_basic_info.resident_size` 采样。机器可读 baseline 位于 `Evidence/Performance`。

性能数值绑定硬件型号、OS build、ImageIO/Core Graphics、Swift 工具链以及 codec fingerprint。默认 `scripts/verify.sh` 只校验 baseline schema 与预算自洽性，不在共享或高负载环境中动态运行微基准。完整场景、计时边界、预算公式与限制见 `docs/PERFORMANCE.md`。
