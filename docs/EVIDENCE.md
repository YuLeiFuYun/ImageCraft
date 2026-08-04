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


## 源码身份证据

`Tools/Identity/capture_source_identity.py` 使用 source identity v2：显式列出必须完整覆盖的顶层根、仅限仓库顶层的构建/版本控制排除项、任意层级临时文件排除项，以及 `Fixtures/ConsumerSmoke/.build` 和 `.swiftpm` 两个精确构建缓存子树。它对当前发布候选中的 Package、源码、测试、工具、文档、证据与 CI 治理文件生成逐文件 SHA-256 清单，并把 schema、identity ID、覆盖契约、逐文件可执行位与文件清单共同纳入总摘要。捕获会拒绝符号链接、未知顶层内容、未声明的嵌套构建目录和遗漏的覆盖根。`scripts/verify-source-identity.sh` 连续捕获两次，要求报告逐字节一致，再把结果写入 `.build/source-identity.json`。

`scripts/verify-clean-copy.sh` 由独立 materializer 重新枚举来源树、复算大小、摘要和可执行位、拒绝 missing/extra 条目，然后直接从已校验字节物化无 Git、无构建缓存副本并重放完整 `verify.sh`。该身份用于把 Fovea 的 Git-free 候选组合测试绑定到实际 ImageCraft 内容，而不是绑定工作区路径或可变分支名。它不等于公开 Git revision、不可变 tag、受保护 CI、代码签名或供应链证明。

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

## 渐进 JPEG 工作放大实验

`Evidence/Experiments/progressive-jpeg-bounded-preview-ab-2026-08-04.json` 固化了渐进 JPEG 预览策略的历史 before、历史 after 和精确 clean after 重放。三份原始聚合报告均保留完整计时样本、RSS 样本、运行时、硬件、工具链、输入 SHA-256 和输出身份；clean after 另绑定提交 `4460ca8aee1196cefad2f9f5076e601b7ef30f94`、其 Git tree 以及 source identity v2 的 96 个文件条目。

`Tools/Performance/validate_progressive_experiment.py` 会：

- 重算三个原始报告和 source identity 文件的 SHA-256；
- 从原始样本重算 median、p90、mean 和 RSS 聚合；
- 拒绝环境、位流、输出尺寸、generation count 契约或样本结构漂移；
- 在 Git 历史可用时逐文件验证 source identity 的内容、大小、可执行位和覆盖集合与记录提交一致；
- 验证两种分片在 duration 与 RSS 上相对旧实现均达到声明的 2×保守门；
- 验证 clean after 的 duration 在首次 after 的 0.8×–1.2×范围内重现。

该 2×规则是历史结果已知后建立的证据资格线，不是预注册假设检验。历史 before/after 也不是交替配对实验，因此记录明确禁止统计显著性、跨设备速度保证、固定 RSS、能耗或用户可感知延迟主张。完整数值和后续缺口见 `docs/PERFORMANCE.md`。

## 渐进 JPEG 首预览时间线证据

`Evidence/Experiments/progressive-jpeg-first-preview-timeline-2026-08-04.json` 将首预览从总会话成本中分离。两轮 clean campaign 均绑定提交 `ffaef9fb45c633e26c4872805cfc18c7ecbb8f05`、对应 Git tree 和 source identity v2；原始文件保留 42 个样本/场景的每代累计耗时、source byte count、运行时、硬件和输入/输出身份。

`Tools/Performance/validate_progressive_timeline_experiment.py` 会从原始样本重算两轮与 pooled 统计，逐文件核验 measured commit，验证 generation 序列和 byte boundary，重算两种 chunk schedule 的首个完整 scan 区间交集，并检查观测后声明的首预览资格线。当前固定输入的首预览在约 3.4%–3.6% 字节、6.76–6.92 ms pooled median 处产生；该结果只描述预构造 chunk 的本地会话时间线，不等于网络或 UI time-to-first-preview，也不提供相对历史实现的首预览加速百分比。

## 渐进 JPEG generation 质量证据

`Evidence/Experiments/progressive-jpeg-generation-quality-2026-08-04.json` 量化四个 bounded generation 相对同一 JPEG 最终完整解码的像素误差。证据绑定 clean 提交 `085ba9b6a53f56c6fb5f41df9048401a43dc5b48`、Git tree、source identity v2，以及每个 chunk schedule 两份逐字节相同的原始报告。

`Tools/Performance/validate_progressive_quality_experiment.py` 会重算原始报告、固定点 MAE/MSE 与 PSNR，验证像素 SHA-256、环境和源码身份，并检查观测后声明的分类边界。固定输入中 G1/G2 低于 20 dB PSNR，G3 在约 36% 字节处跃升至 46.275 dB 且全部通道误差不超过 8。该证据描述的是相对最终解码的像素收敛，不是原始图像质量、感知效用或用户可用性证明。
## 渐进 JPEG 真实照片矩阵证据

`Evidence/Experiments/progressive-jpeg-real-photo-scan-matrix-2026-08-04.json` 将内容、scan script 与 chunk schedule 拆成 4 × 3 × 2 的正交矩阵。证据绑定 clean 提交 `75acd9279304077ba4ba44fe42af1b03aa8009fe`、Git tree、149 文件 source identity、48 份成对原始报告和可逐字节再生的公共领域照片 corpus。

`Tools/Performance/validate_progressive_photo_matrix_experiment.py` 会验证 manifest 与每份原始报告哈希、成对确定性、固定点 MAE/MSE 与 PSNR、自原始报告重建聚合、最终像素跨 scan script 一致性，以及 measured commit 的逐文件内容与可执行位。矩阵表明 generation 数量和同序号质量会随 chunk schedule 改变，且 luma-frontloaded 脚本可在接近流尾时仍明显偏离最终解码。因此 generation 只能表示单会话顺序；该记录不授予跨会话质量等级，也不把 PSNR 当作感知可用性证明。

## 渐进 JPEG scan checkpoint 与策略证据

`Evidence/Experiments/progressive-jpeg-scan-checkpoint-policy-2026-08-04.json` 绑定 clean 提交 `8cbf3886ee69c03d813f97289a3b17a5b1c90aa7`、Git tree、204 文件 source identity、24 份成对原始报告、checkpoint 聚合和完整 56 策略枚举。

`Tools/Performance/validate_progressive_scan_checkpoint_experiment.py` 会重算每个 checkpoint 的固定点误差与 PSNR、验证 scan/marker/prefix 边界、成对确定性、fresh/sequential 像素一致性、自原始报告重建聚合与策略分析，并在 Git 历史可用时逐文件绑定 measured commit。

该记录支持：固定环境与 corpus 中，完整 entropy prefix 在终止 marker 前已可光栅化；ImageIO status raw value 不是充分的预览可用性判据；当前 `[1,2,4,8]` 在限定五指标/56 候选中非支配。它不支持跨 OS 的 ImageIO 行为承诺、感知可用性、网络到屏幕收益或全局最优阈值。生产阈值因此保持不变。

## 渐进 JPEG pipeline profile 与模拟证据

`Evidence/Experiments/progressive-jpeg-pipeline-simulation-2026-08-04.json` 绑定 clean 提交 `04c8ad2984ef94ad31d4bd386e2d06bdddf58304`、Git tree、239 文件 source identity、两份 7-iteration Release profile 与可从 profile 逐字重建的 8-case 离散事件模拟。

`Tools/Performance/validate_progressive_pipeline_experiment.py` 会重算 profile 的每 chunk 统计与 generation 边界，验证最终像素一致性，从 profile 重建完整 simulation，并在 Git 历史可用时逐文件绑定 measured commit。`Tools/Performance/test_progressive_pipeline_simulation.py` 另用合成输入固定精确到达、帧内 latest-wins、network-dominant 无排队和 in-flight 取消语义。

该证据把实测 ImageIO/MainActor 成本与模拟网络/帧时钟严格分开。它支持：decode-pressure 和 network-dominant 需要不同宿主策略；取消发布栅栏应先于等待 `session.cancel()`；presentation policy 属于宿主。它不支持 URLSession、Core Animation、GPU 呈现、真机能耗或固定 60 Hz 策略的生产最优性。
