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

该实验记录不是跨机器回归预算。正式百分比主张仍需两个不可变可执行文件的交替配对进程实验；iOS 真机、低性能设备、首预览和能耗证据仍未完成。

## JPEG 熵区 marker 扫描实验

`Evidence/Experiments/jpeg-marker-scan-ab-2026-07-31.json` 记录了一次独立的实现 A/B，比较逐字节 Swift 扫描与 `Darwin.memchr` 搜索 JPEG entropy 区下一个 `0xFF` marker。两侧使用预构建 Release 可执行文件，按 A/B、B/A 顺序交替运行；共覆盖 6 条 JPEG 路径、每条 7 对独立进程、每进程 7 个计时样本，总计 588 个样本。

在该固定 MacBookPro18,3、macOS 27.0 build 26A5388g、ImageIO 2847 环境中，六条路径的进程中位数配对变化均为改善：约 8.9% 至 16.9%。其中五条路径 7/7 配对获胜，full decode 为 6/7。该实验同时绑定完整测试、retained corpus、consumer 平台矩阵和独立 oracle 通过状态。

该结果证明的是内部容器扫描实现的固定环境收益，不证明跨设备比例、ImageIO 光栅化算法优势、能耗改善或所有 JPEG 输入获得相同比例收益。稳定性能 baseline 与预算仍由 `Evidence/Performance` 管理，不因一次优化实验自动收紧。
