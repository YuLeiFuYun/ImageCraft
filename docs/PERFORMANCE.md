# 性能与峰值内存证据

## 目标

性能证据用于回答固定 ImageIO 路径在特定硬件、OS build、系统框架和 Swift 工具链上的实际成本。它不是跨设备性能承诺，也不把一次测量误当作算法复杂度证明。

首份基线位于：

```text
Evidence/Performance/macos-27.0-26A5388g-arm64-macbookpro18,3.json
```

该文件绑定：

- MacBookPro18,3，8 个活动处理器，16 GiB 物理内存；
- macOS 27.0 build 26A5388g，arm64；
- ImageIO 2847 / 3.3.0，Core Graphics 2047；
- Swift 6.4；
- decoder fingerprint `dev.fovea.imageio#impl=1#contract=1`；
- encoder fingerprint `dev.imagecraft.imageio.encoder#impl=2#contract=1`；
- Release 构建和 `imagecraft-performance-v1` 场景定义。

## 场景

固定输入由 `imagecraft-pattern-v1` 生成。JPEG 解码输入为 3072×2048、quality 0.82 的确定性 JPEG；编码输入为确定性 sRGB RGB8 `CGImage`。

| 场景 | 语义 |
|---|---|
| `decode-jpeg-full` | JPEG 解码到 3072×2048 |
| `decode-jpeg-fit-512` | fit 到 512×512，输出 512×341 |
| `decode-jpeg-fit-1024` | fit 到 1024×1024，输出 1024×683 |
| `decode-jpeg-fill-1024` | fill 到 1024×1024并居中裁切 |
| `probe-then-decode-jpeg-fit-512` | 先独立 probe，再通过 supplied-probe 路径解码；当前实现会重新 inspection |
| `prepare-then-decode-jpeg-fit-512` | prepare 后复用同一个 `CGImageSource` 解码 |
| `encode-png` | 1600×1200 无损 PNG 编码 |
| `encode-jpeg-q75` | 3072×2048 JPEG quality 0.75 编码 |

## 测量边界

每个场景在独立进程中执行，避免其他场景的 ImageIO 缓存、allocator 高水位和 resident peak 污染。默认进行 3 次进程重复。每个进程先执行独立的单操作内存阶段；随后执行 2 次 warmup，再在关闭 RSS sampler 的情况下记录 7 次 Release 操作。因此每个场景的耗时统计包含 21 个样本，内存统计包含 3 个独立进程峰值。

计时区间包含：

- ImageCraft admission、container inspection 和 ImageIO 调用；
- 颜色解释、fit/fill 后处理和编码输出 container 自检；
- 对输出尺寸或字节数的轻量一致性检查。

计时区间不包含：

- 确定性 fixture 构造；
- 解码输入 JPEG 的准备编码；
- reference 输出的 SHA-256；
- JSON 序列化和文件写入；
- Release 构建时间。

耗时报告 minimum、median、p90、maximum 和 mean。预算使用 median 与 p90，不使用单次最小值。

## RSS 采样

每个进程在 fixture 构造和 reference 操作完成后调用 `malloc_zone_pressure_relief` 释放可回收 malloc 页，再记录 resident baseline。独立内存阶段由采样线程每 500 微秒读取一次 `mach_task_basic_info.resident_size`，同时只执行一次被测操作。采样结束后才进入 warmup 与计时阶段，避免 sampler 和 allocator 高水位污染耗时或 RSS 结果。报告：

- 每个进程的 baseline resident bytes；
- 每个进程的 sampled peak resident bytes；
- peak 相对 baseline 的增量；
- 三个进程 peak 增量的中位数和最大值。

这是采样峰值，不是内核提供的精确逐分配峰值；持续时间短于采样间隔的瞬时分配可能遗漏。resident bytes 也包含 ImageIO/Core Graphics、allocator page、系统框架缓存和其他进程内常驻页，因此不能与 `ImageDecodeResourceEstimate` 直接视为同一量。

`ImageDecodeResourceEstimate` 只描述当前模型中的像素表面保守估计；它明确不覆盖系统框架内部固定开销、编码数据和 allocator 行为。性能报告同时记录两者，用于发现数量级偏差，但不会要求逐字节相等。

## 首份观测

首份 3×7 基线的核心观测约为：

| 场景 | median | p90 | RSS 增量中位数 | RSS 增量最大值 | decode estimate |
|---|---:|---:|---:|---:|---:|
| decode fill 1024 | 23.2 ms | 24.4 ms | 16.3 MiB | 17.4 MiB | 16.0 MiB |
| decode fit 1024 | 30.3 ms | 38.6 ms | 12.9 MiB | 14.9 MiB | 8.0 MiB |
| decode fit 512 | 38.3 ms | 39.7 ms | 2.8 MiB | 2.9 MiB | 2.0 MiB |
| decode full | 38.7 ms | 42.8 ms | 66.6 MiB | 69.8 MiB | 72.0 MiB |
| encode JPEG q75 | 75.9 ms | 83.7 ms | 53.4 MiB | 58.6 MiB | — |
| encode PNG | 64.4 ms | 89.9 ms | 12.6 MiB | 14.8 MiB | — |
| prepare + decode fit 512 | 38.4 ms | 39.8 ms | 2.8 MiB | 3.0 MiB | 2.0 MiB |
| probe + decode fit 512 | 41.8 ms | 43.2 ms | 2.9 MiB | 3.1 MiB | 2.0 MiB |

目标尺寸与耗时不是单调关系。该环境中 fit-1024 比 fit-512 更快，fill-1024 又更快；这可能来自 JPEG 原生 IDCT 缩放档位、ImageIO 重采样策略和裁切路径组合。该现象只能作为固定输入和固定系统框架上的观测，不能推广为一般规律。

prepare 路径的主要意义是避免宿主已经需要 probe 时再做一次完整 inspection。它与直接便利解码接近，并比当前 probe-then-supplied-probe 路径节省约 3–4 ms；不应据此宣称所有输入都获得同一比例收益。

## 预算

基线保存 observed 值和独立 budget：

- median：`max(observed × 1.5, observed + 10 ms)`；
- p90：`max(observed × 1.75, observed + 15 ms)`；
- 三进程 RSS 增量中位数：`max(observed × 1.5, observed + 16 MiB)`；
- 单进程 RSS 增量最大值：`max(observed × 1.5, observed + 32 MiB)`。

预算故意宽于微基准噪声，只用于发现显著回归。环境 identity、场景输入、输出语义、进程重复数和迭代数必须精确匹配；低功耗模式或 serious/critical thermal state 会使报告无效。

性能验证不进入默认 `scripts/verify.sh` 的动态门禁，因为共享 CI、前台负载和温控状态会导致误报。默认门只静态验证 baseline schema 和预算自洽性。

## 命令

捕获原始聚合报告：

```sh
scripts/capture-performance-evidence.sh output.json 7 3
```

创建或有意更新 baseline：

```sh
scripts/create-performance-baseline.sh \
  Evidence/Performance/macos-27.0-26A5388g-arm64-macbookpro18,3.json \
  7 \
  3
```

验证当前实现：

```sh
scripts/verify-performance-baseline.sh \
  Evidence/Performance/macos-27.0-26A5388g-arm64-macbookpro18,3.json
```

baseline 更新必须伴随原因说明。代码变快并不自动要求收紧预算；应先确认变化来自实现而不是系统负载、工具链或框架缓存行为。


## 渐进 JPEG 独立基准

渐进会话不并入既有八场景稳定 baseline，因为它使用 progressive JPEG、多个预览输出和不同的完成边界。`scripts/capture-progressive-performance-evidence.sh` 单独测量同一 3072×2048 progressive JPEG、512×512 fit 目标与两种预分片大小：1 KiB 和 32 KiB。fixture 构造与分片数组创建位于计时区间之外；计时包含会话创建、全部 append、预览光栅化、尺寸与 generation-count 校验以及 finish。

2026-08-04 的历史 before/after 聚合均来自 MacBookPro18,3、macOS 27.0 build 26A5388g、ImageIO 2847 与 Swift 6.4，每个场景使用 3 个独立进程、每进程 7 次计时。优化把“每个已完成 scan 都尝试预览”改为只在 1/2/4/8 scan 几何阈值光栅化。随后又在精确 clean 提交 `4460ca8aee1196cefad2f9f5076e601b7ef30f94` 上独立重放 after 路径：

| 分片 | 旧 median | 历史 after median | clean after median | 旧→clean median | 旧 p90→clean p90 | RSS 中位数旧→clean |
|---|---:|---:|---:|---:|---:|---:|
| 1 KiB | 433.5 ms | 144.6 ms | 145.2 ms | 2.99× | 454.1→147.0 ms（3.09×） | 10.58→4.22 MiB（2.51×） |
| 32 KiB | 371.2 ms | 145.2 ms | 146.7 ms | 2.53× | 383.8→163.2 ms（2.35×） | 12.31→3.88 MiB（3.18×） |

clean after 的 median 与首次 after 相差约 0.4% 和 1.1%，p90 比率分别为 0.94 和 1.02。RSS 对 allocator 与系统框架高水位更敏感：clean after 高于首次 after，但相对旧实现的 RSS 中位数和单进程最大值仍全部改善至少 2×。因此机器判定只使用保守的 2×相对改善门，不承诺固定 MiB。

这不是预注册或配对统计实验。历史 before/after 是独立聚合，而且历史两侧没有完整源码身份；2×门槛是在历史结果已知后声明的保守证据验收线。可支持的结论仅是：在绑定环境和固定输入上，clean 实现重现了明显的工作放大下降。不能从该记录推导显著性 p 值、跨设备比例、所有渐进 JPEG 的统一收益、能耗收益或应用级首屏体验改善。

同轮普通完整 JPEG fit-512 解码约为 33–34 ms。渐进路径仍约等于四次目标尺寸光栅化的总成本，因此该结果不表示渐进会话快于单次最终解码。后续比较必须分别报告首预览延迟、完整会话成本、预览数量、最终解码成本和用户实际显示结果。

版本化实验记录位于：

```text
Evidence/Experiments/progressive-jpeg-bounded-preview-ab-2026-08-04.json
Evidence/Experiments/ProgressiveJPEGBoundedPreview/
```

静态验证会重算原始报告哈希、样本统计、环境与输出身份、source identity、Git commit tree 绑定以及所有改善比率：

```sh
python3 Tools/Performance/validate_progressive_experiment.py \
  Evidence/Experiments/progressive-jpeg-bounded-preview-ab-2026-08-04.json
```

重新捕获当前实现：

```sh
scripts/capture-progressive-performance-evidence.sh output.json 7 3
```

该实验记录不是跨机器回归预算。正式百分比主张仍需两个不可变可执行文件的交替配对进程实验；iOS 真机、低性能设备和能耗证据仍未完成。首预览的独立本地时间线见下一节。

## 渐进 JPEG 首预览时间线

总会话成本下降并不自动证明用户能更早看到图像；1/2/4/8 阈值也可能在减少光栅化次数的同时推迟首个预览。为单独检验这一机制，`imagecraft-progressive-timeline-v1` 从 progressive session 创建前开始计时，记录每个 generation 返回时的累计本地耗时和 `sourceByteCount`。fixture 编码和 chunk 数组构造位于计时区间之外，所有 chunk 已在内存中，因此该实验测量的是本地解析与光栅化时间线，不包含网络到达、主线程交付或 UI 显示。

基础设施提交 `ffaef9fb45c633e26c4872805cfc18c7ecbb8f05` 在 clean 工作树上执行两轮独立 campaign。每轮对 1 KiB 与 32 KiB 两种 chunk schedule 各运行 3 个独立进程、每进程 7 次计时；每个场景合计 42 个正式样本。固定输入、目标尺寸、运行时和 decoder fingerprint 与前述渐进总成本实验一致。

| 分片 | 首预览字节 | 流占比 | 首预览 pooled median | 首预览 pooled p90 | finish pooled median |
|---|---:|---:|---:|---:|---:|
| 1 KiB | 185,344 | 3.4022% | 6.759 ms | 7.038 ms | 145.738 ms |
| 32 KiB | 196,608 | 3.6090% | 6.924 ms | 7.191 ms | 145.218 ms |

两轮之间，首预览 median 比率为 0.995 和 1.005，p90 比率为 0.987 和 1.049；finish median 比率为 0.991 和 1.003。首预览本地 median 只占完整会话 median 的约 4.64%–4.77%。32 KiB 第一轮的 finish p90 被单个约 236 ms 的主机尾部样本拉高，第二轮未复现，因此 finish p90 仅报告，不进入稳定性资格判定。

四个 generation 的 pooled median 时间线为：

| 分片 | G1 | G2 | G3 | G4 |
|---|---:|---:|---:|---:|
| 1 KiB | 3.40% / 6.76 ms | 11.47% / 19.35 ms | 35.66% / 52.85 ms | 77.73% / 138.55 ms |
| 32 KiB | 3.61% / 6.92 ms | 12.03% / 19.91 ms | 36.09% / 53.49 ms | 78.20% / 139.65 ms |

每个百分比是 generation 返回时已接收字节占完整流的比例。两种 chunk schedule 的首预览边界区间相交后，可将该固定 JPEG 的首个完整 scan 结束位置约束为 **(184,320, 185,344] 字节**。这是从 chunk 量化边界得到的固定输入推断，不是任意 progressive JPEG 的格式常数。

这组数据支持的结论是：对该绑定输入与实现，几何阈值策略没有把首预览推向流尾；首个 generation 在约 3.4%–3.6% 字节处产生，后续只保留四次有界光栅化。它不支持旧策略与新策略的首预览速度百分比比较，因为历史 per-scan 实现没有不可变可执行文件；也不支持网络 time-to-first-preview、实际 UI 呈现时间、感知质量、跨设备保证或能耗结论。

版本化原始 campaign、source identity 和机器可读结论位于：

```text
Evidence/Experiments/progressive-jpeg-first-preview-timeline-2026-08-04.json
Evidence/Experiments/ProgressiveJPEGFirstPreview/
```

验证与重新捕获命令：

```sh
python3 Tools/Performance/validate_progressive_timeline_experiment.py \
  Evidence/Experiments/progressive-jpeg-first-preview-timeline-2026-08-04.json

scripts/capture-progressive-timeline-evidence.sh output.json 7 3
```

资格门是在观测后声明的描述性证据规则，不是预注册假设检验：pooled 首预览不得晚于 10 ms、不得晚于 5% 编码字节，两轮首预览 median/p90 与 finish median 的比率必须落在 0.8–1.2。下一步仍需网络节奏回放、generation 到 UI presentation 的链路追踪、held-out scan 结构和 iOS 真机。

## 渐进 JPEG generation 质量

首预览时间线只证明像素产生得早，不证明早期像素已经接近最终图，更不能直接称为“可用”。`imagecraft-progressive-quality-v1` 因此把每个 generation 的 `CGImage` 转换为确定性 sRGB RGB8 字节，与同一 lossy progressive JPEG 的独立完整解码结果比较。完整解码是收敛参考，不是原始未压缩图像的质量真值。

质量工具提交 `085ba9b6a53f56c6fb5f41df9048401a43dc5b48` 在 clean 工作树上捕获。1 KiB 和 32 KiB 两个 chunk schedule 各执行两次，完整 JSON 逐字节一致。指标包括像素 SHA-256、逐通道绝对误差与平方误差、最大误差、固定点 MAE/MSE、PSNR，以及绝对误差不超过 8/16/32/64 的通道覆盖率。

| Generation | 字节占比范围 | PSNR 范围 | MAE 范围 | ≤16 覆盖率 | 最大误差 | 结论边界 |
|---|---:|---:|---:|---:|---:|---|
| G1 | 3.40%–3.61% | 18.81–18.82 dB | 23.06–23.10 | 44.13%–44.23% | 126 | 早，但相对最终解码仍粗糙 |
| G2 | 11.47%–12.03% | 19.24–19.33 dB | 21.06–21.51 | 48.69%–50.04% | 127 | 有限改善，仍明显偏离最终解码 |
| G3 | 35.66%–36.09% | 46.275 dB | 0.916 | 100% | 6 | 在声明的像素阈值下接近最终解码 |
| G4 | 77.73%–78.20% | 48.44–48.74 dB | 0.569–0.601 | 100% | 6 | 进一步细化 |

G3 在两个 chunk schedule 下得到完全相同的 RGB SHA-256；所有 generation 的跨 schedule PSNR 差异均低于 0.31 dB，MAE 差异低于 0.45。由此可见，该固定输入的质量演化不是平滑线性改善，而是在 G3、约 36% 编码字节处发生明显跃迁。G1/G2 可以作为“早期低保真像素”描述，但当前证据不支持“足够清晰”“可识别”或“用户可用”等产品措辞。

机器判定使用观测后声明的描述性分类，而非预注册感知阈值：G1/G2 必须同时满足 PSNR < 25 dB、MAE > 10、误差 ≤16 的通道覆盖率 < 60%；G3/G4 必须同时满足 PSNR ≥ 40 dB、MAE ≤ 2、最大误差 ≤8 且全部通道误差 ≤8。该分类只用于防止文档把早期像素错误包装成近最终质量，不声称这些阈值对应人类视觉效用。

版本化证据与验证命令：

```text
Evidence/Experiments/progressive-jpeg-generation-quality-2026-08-04.json
Evidence/Experiments/ProgressiveJPEGQuality/
```

```sh
python3 Tools/Performance/validate_progressive_quality_experiment.py \
  Evidence/Experiments/progressive-jpeg-generation-quality-2026-08-04.json

scripts/capture-progressive-quality-evidence.sh output.json
```

仍缺少 SSIM 或经过验证的感知指标、识别任务/用户研究、iOS 真机以及网络到 UI 的完整链路。尤其不能把 PSNR 当作主观质量的充分统计量。真实照片与独立 scan script 的第一版矩阵见下一节。

## 渐进 JPEG 真实照片与 scan script 矩阵

单个程序化图案无法区分内容、JPEG 扫描顺序和 transport chunk 的影响。`progressive-real-photo-v1` 因此固定四张美国联邦政府公共领域照片，覆盖室内人物、自然景观、雪景建筑和逆光动物；每张照片在相同 quality 75、4:2:0 与 optimized Huffman 设置下由 libjpeg-turbo 3.2.0 编成三种 progressive scan script：默认 successive approximation、七 scan spectral selection，以及“全部亮度 AC 先于色度 AC”的实验脚本。三种脚本对同一来源经 `djpeg` 得到完全相同的最终 PPM 字节。

基础设施提交 `75acd9279304077ba4ba44fe42af1b03aa8009fe` 在 clean 工作树上对 4 × 3 × 2 个 source/script/chunk case 各执行两次，48 份原始 JSON 成对逐字节一致。矩阵不测时间；它记录实际产生的 generation、返回时的字节比例，以及相对同一编码 JPEG 最终 ImageIO 解码的固定点像素误差。

| Scan script | 最后一个预览的字节占比范围 | PSNR 范围 | MAE 范围 | 最大局部误差范围 |
|---|---:|---:|---:|---:|
| default successive | 43.15%–63.05% | 36.79–48.60 dB | 0.59–2.14 | 4–48 |
| spectral balanced | 31.46%–42.68% | 31.82–45.61 dB | 0.60–4.15 | 33–126 |
| luma front-loaded | 50.60%–98.20% | 28.70–43.30 dB | 0.65–4.23 | 36–130 |

该矩阵否定了三个容易产生的假设：

1. generation 序号没有跨会话质量含义。同一 source/script 的相同序号会因 chunk overshoot 落在不同 scan 边界之后；Coconino 景观的 default G4 在 1 KiB chunk 下为 36.79 dB，在 32 KiB 下为 48.11 dB，相差 11.32 dB。
2. chunk schedule 还会改变 generation 数量。牛只照片的 default successive 在 1 KiB 下产生四代，在 32 KiB 下只产生三代；达到阈值不保证 ImageIO 当时可光栅化，而一次 append 也最多返回一代。
3. “亮度优先”不是普遍更好的 progressive 策略。Coconino 景观的 luma-frontloaded G4 已收到 93.85% 字节，仍只有 28.70 dB、MAE 4.23、最大通道误差 130。

因此 `generation` 只能保持当前契约中的单会话严格顺序含义，不能被宿主解释为固定质量等级。当前数据也不足以选出普遍最优 scan script；default successive 在这个小矩阵中的尾部行为更稳健，但四张照片不是生产分布，PSNR 也不是感知效用。

版本化 corpus、48 份原始报告、聚合、source identity 和机器可读结论位于：

```text
Evidence/Fixtures/ProgressiveJPEGRealPhoto/v1/
Evidence/Experiments/progressive-jpeg-real-photo-scan-matrix-2026-08-04.json
Evidence/Experiments/ProgressiveJPEGRealPhotoMatrix/
```

验证与重新捕获：

```sh
python3 Tools/Performance/validate_progressive_photo_matrix_experiment.py \
  Evidence/Experiments/progressive-jpeg-real-photo-scan-matrix-2026-08-04.json

scripts/capture-progressive-photo-matrix.sh aggregate.json raw-reports
```

完整 corpus 生成谱系、公共领域来源和限制见 `docs/PROGRESSIVE_PHOTO_CORPUS.md`。下一步应比较 threshold retry、byte-fraction/time gating 和宿主抑制策略，并用更大分层 corpus、感知指标、任务实验及网络到 UI 链路验证；不能直接按本矩阵修改生产 scan 策略。

## JPEG 熵区 marker 扫描实验

`Evidence/Experiments/jpeg-marker-scan-ab-2026-07-31.json` 记录了一次独立的实现 A/B，比较逐字节 Swift 扫描与 `Darwin.memchr` 搜索 JPEG entropy 区下一个 `0xFF` marker。两侧使用预构建 Release 可执行文件，按 A/B、B/A 顺序交替运行；共覆盖 6 条 JPEG 路径、每条 7 对独立进程、每进程 7 个计时样本，总计 588 个样本。

在该固定 MacBookPro18,3、macOS 27.0 build 26A5388g、ImageIO 2847 环境中，六条路径的进程中位数配对变化均为改善：约 8.9% 至 16.9%。其中五条路径 7/7 配对获胜，full decode 为 6/7。该实验同时绑定完整测试、retained corpus、consumer 平台矩阵和独立 oracle 通过状态。

该结果证明的是内部容器扫描实现的固定环境收益，不证明跨设备比例、ImageIO 光栅化算法优势、能耗改善或所有 JPEG 输入获得相同比例收益。稳定性能 baseline 与预算仍由 `Evidence/Performance` 管理，不因一次优化实验自动收紧。
