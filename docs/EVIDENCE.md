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


## 动画容器与按帧证据

动画合同目前以 `IMG_ANIM_PT_001`–`IMG_ANIM_PT_056` 连续且唯一编号；`scripts/check-animation-test-ids.py` 在 `scripts/verify.sh` 中同时检查重复和缺号。19 项 ImageIO 测试使用确定性 GIF、手工构造且 CRC 正确的 APNG，以及完整 JPEG 帧序列，验证精确有理数 timing、有限/无限 loop、frame rect、disposal、blend、ImageIO 最终 canvas 像素、按需帧、有界 decode window、颜色/尺寸一致性和取消；另固定三类 source 的格式 allowlist、JPEG sequence 累计 metadata 预算、APNG 默认图像不属于动画、chunk CRC、critical/reserved type、sequence gap、非连续 `IDAT`、首帧非法 `fdAT`、声明帧数早期 admission、越界 rect，以及 GIF disposal/GCE 保留位、user-input flag、Plain Text graphic block、尾随未消费 GCE 和 LZW 最小码宽。7 项 Core 测试固定 duration/loop/rect/descriptor 的严格 Codable、规范化和 metadata 连续性。实际 timeline publication 还以 `DecodedImage.estimatedByteCost × frameCount` 复核行跨度与 overflow。静态容器误入动画入口、总时间轴字节上限和越界帧索引继续失败关闭。

`IMG_ANIM_PT_027`–`IMG_ANIM_PT_056` 进一步覆盖压缩 checkpoint、RFC1950 互操作、owned raw-subrect APNG、separate-default、随机访问、批量共享 canvas、公开 decoder backing/资源诊断以及 semantic replay。semantic replay 只接受能够持续重建后续 pre-frame canvas 的锚点：full-canvas `source` 且 disposal 不是 `previous` 可从当前帧开始；full-canvas `background` disposal 后下一帧可从透明 canvas 开始。`IMG_ANIM_PT_054` 验证 10 帧 full-background 控制在最大 replay=2 时不再保留 checkpoint，随机与批量像素仍一致；`IMG_ANIM_PT_055` 保留 full-source + previous 反例，证明该语义不会被错误提升为持续锚点；`IMG_ANIM_PT_056` 从公开 instrumented decoder 看到 semantic reset、checkpoint 数和实际最大 replay。该机制已包含在不可变开发标签 `0.1.0-alpha.7`（`3b7f7ef212acfa42a022d7cd0bfad73c0cd2d252`）中；发布身份不等于宿主动画接入或物理设备资格，仍不代表物理内存、能耗或跨库优势。

`ImageCraftEvidence --animation-performance` 对同一输入分别记录 ImageCraft 精确准备、直接 ImageIO 准备下界、冷单帧、保留 source 单帧、8 帧窗口顺序解码和完整直接顺序下界，并保存全部样本与像素 SHA-256。动画 hostile-path 测试另行固定格式 allowlist、APNG CRC/顺序、早期帧 admission、GIF 保留位和 JPEG sequence 累计元数据边界。当前 `.artifacts/performance/animation-initial` 仅是脏工作树、本机、256×256 单 fixture 方向性证据；它不进入稳定 baseline，也不支持竞品或跨设备优越性声明。

## 性能与峰值内存证据

### T101 phase-aware resource ledger

T101 首轮把资源资格从单个 working-set 数字拆成 `retainedBetweenCalls`、`operationPeak` 与 `transferredOutput` 三个 ownership phase，并为无法证明的 phase 保留结构化 unknown reason。`ImageDecodeResourceLedgerTests` 固定 phase 分离、unknown 传播、branch coexistence 饱和加法和 terminal reclaim；`DecodeSessionQualificationTests` 证明 progressive JPEG 在调用间只保留有界 `Data`，但不把 ImageIO 执行期私有分配或 Core Graphics 输出 layout 误报为硬上界。该 session 的失败生命周期现在也成为硬门：尚未吸收字节的 `maximumEncodedBytes` admission failure 保持可重试；一旦已吸收输入后出现 SOI/marker fatal、baseline capability mismatch、EOI 后 trailing bytes、final container/metadata validation failure，或 prepared-store downstream admission failure，会话立即转为 terminal、释放 retained encoded input 并拒绝后续 append/finish。JPEG 另加入 package-internal 500-scan CPU-amplification safety gate：完整 container scanner 与 progressive incremental marker state 共用同一上限，501st SOS 在进入新的 ImageIO preview/final work 前 fail-closed；该数值对齐 libjpeg-turbo 历史 `TJFLAG_LIMITSCANS` 防护量级，而不是 JPEG 格式宣称。`Tools/Quality/audit_jpeg_scan_count.py` 对 retained test corpus + versioned Evidence fixtures 的23个 JPEG candidate分账，22个完整结构样本最大仅10 scans、1个预期 missing-EOI hostile，因此当前版本化输入对500上限至少有50× scan-count余量；这不等价于对所有合法 JPEG 的生态分布调查。此前 preparation budget failure 已被反例直接观测为“session 实际 finished、snapshot 却停在 finalReady/nonterminal”，现已修复并由 deterministic tests 固定。动画 qualification 同样区分 owned GIF/APNG 的有界 retained admission charge 与 ImageIO fallback 的 opaque retained state，而完整 operation/output 仍保持 unknown。

T101 第二轮将 static prepared ImageIO 的 opaque retained state 变成可证伪机制。package-only retained-source 对照继续证明跨调用 `CGImageSource` 必须把 retained phase 标为 unknown；新的默认路径只保留 encoded `Data`、probe/limits 与纯值 container-security facts，decode 重建短生命周期 ImageIO source，并在 ICC 被单独重组时把额外 profile bytes 纳入 retained charge。`ImageDecodePreparationLimits` 为 decoder 实例提供独立的 entry-count 与 aggregate retained-byte authority，预算耗尽稳定失败为 `preparedStateBudgetExceeded`，consume/discard 归还 charge。静态 PNG/JPEG/GIF、ICC、caller-mutation snapshot 与 progressive-finalization conformance 都要求规范化像素等价且不重复 container scan。

方向性 AB/BA 工件 `.artifacts/performance/prepared-state-retention-facts-directional` 绑定 284-file source identity `6ded86f48953112b734b8f862981b10728c305b33b1e9f0d16074738be7d3709`。四对进程、每进程 64 个同时 preparation 与 7 个 timing sample 中，pure-value data-only 相对 retained-source 的 paired total-duration ratio 中位为 1.0014×，范围约 0.982×–1.008×；重复 framework inspection 约 0.100 ms process-median，64-token prepared RSS delta 的 paired 差约 1.16 MiB。该 campaign 在高负载主机完成，且相同 `Data` 可共享 COW backing，因此只支持机制方向，不是稳定设备性能或物理内存结论；正式结论仍需稳定 simulator/真机和 distinct-body 控制。

这里的关键负面结论是：`pixelCount × 4` 只能作为 tight-RGBA 模型，不能替代 `CGImage.bytesPerRow × height` 的实际返回表面成本，更不能覆盖 ImageIO 私有分配。完整语义与下一组可证伪缺口见 `docs/RESOURCE_MODEL.md`。phase-aware resource vocabulary 与部分非消费式 preflight capability 现在已提升为 public Core contract，但 `.unknown` 仍是必须保留的公开事实；这不构成物理 RSS 上界、能耗或跨 backend 优越性声明，也不会把 ImageIO 私有 allocation 自动变成 bounded。

### T101 packed value 与真实第二 backend pressure

`ImagePackedRGBA8` 把 qualification output 固定为 tight RGBA8、premultiplied alpha、top-to-bottom
row order 与显式 value color encoding。一个非对称 2×2 byte oracle 曾直接抓出 materializer
垂直翻转，而旧 CGImage→CGImage 自比较没有发现该错误；因此 value contract 现在要求独立
byte-level 检查。`ImageCraftEvidence --packed-rgba-export` 可把同一合同输出为 raw bytes + JSON
observation，供语言无关 comparator 使用。

progressive independent JPEG 现在也不再把最终 raw RGB8 锁在 JPEG-specific result struct里。package-only `ProgressiveImagePackedRGB8FinalizingSession` 从任意 `ImageProgressiveDecodeSession` value可动态发现，并返回 `ImageProgressivePackedRGB8Finalization(image: ImagePackedRGB8, sourceByteCount:)`。JFIF无 ICC 的二元颜色语义被明确拆开：**output encoding = sRGB fallback，source profile = absent**，不能把“输出按sRGB解释”误写成“源声明standardSRGB”。`Evidence/Experiments/IndependentProgressiveJPEG420PackedFinalization/v1/profile.json` 到 `v8/profile.json` + `Tools/Quality/validate_independent_progressive_jpeg_420_packed_finalization.py` 形成只增不改的representation/resource历史。v1绑定787-byte source、47个17-byte arbitrary chunks与897-byte tight RGB8；prefinish ledger的 `transferredOutput=897 / codecOwnedRGB8` 必须与 packed transfer charge一致，`maximumTightRGBABytes`保持0，finalization sourceByteCount必须等于完整encoded body，terminal ledger全0。纯 wrapper还用同一时刻的 `Data` base-address falsifier证明 `JPEGIndependentProgressive420Image.rgb -> ImagePackedRGB8` 没有生成第二份 pixel backing。v2再把同一 packed value显式 materialize成24-bit `DecodedImage`：一份malloc-owned 897 B tight RGB provider payload、69 B row、8-bit component、24 bpp、alpha none、sRGB CG color space，provider bytes必须与packed hash逐字节一致且source profile继续为absent。这个版本**故意不把“能造CGImage”升级成“资源已闭合”**：materializer ledger的 transfer仍精确897 B，但`operationPeak`必须是 `unknown(frameworkPrivateOperationAllocation)`；同时记录已知 pixel-payload coexistence **897 packed + 897 provider copy = 1,794 B**。v3随后证明这份已知第二payload并非CGDataProvider的必需条件：`CGDataProvider(data: packed.data as CFData)` 在qualified runtime上保留标准packed Data的同一byte backing，provider/packed pointer一致；独立生命周期门让packed value与progressive session离开作用域后只保留`DecodedImage`，provider bytes仍稳定。v3因此要求 `providerBackingWasShared=true`、`copiedPixelPayloadByteCount=0`，known pixel-payload coexistence从v2 **1,794→897 B**；provider count/hash、24-bit CG geometry、source profile与transfer ledger完全不变。重要的是 `operationPeak` **仍**必须是 `unknown(frameworkPrivateOperationAllocation)`：去掉已知pixel copy不等于取得CGDataProvider/CGImage wrapper allocator authority。v4把这个unknown放进backend-neutral `DecodedImage + sourceByteCount + materializationResourceLedger` finalization capability，而不是塞进旧的value-only finalizer；同一个base session可动态发现resource-aware capability，但独立JPEG仍不广告 `ProgressiveImageFinalizingSession`。v5补齐exact `ImageProbe`：23×13、frameCount=1、orientation=1、JPEG、metadata=14 B、auxiliary=0、source profile absent；EXIF/XMP/MPF/ICC authority在当前窄support domain内必须先fail-closed，metadata计数与shared security inspector逐marker同口径。v6把resource ledger vocabulary与resource-aware finalization contract提升成公开 `ImageCraftCore` API；normal-import CoreTests与独立SwiftPM consumer负责外部可见性门，而independent JPEG实现本身继续package-only。v7再补上真正的**事前准入authority**：`decodedImageFinalizationResourceLedger()` 在source未final-ready时返回nil，在finalReady时非消费地返回 materializer将使用的ledger；source-bound evidence要求preflight前后qualification snapshot逐值不变，且preflight ledger与最终消费式materialization ledger完全相等。当前retained source的preflight明确是 `operationPeak=unknown(frameworkPrivateOperationAllocation) / transferredOutput=897 / codecOwnedRGB8`，所以hard-bounded host现在可以在Core Graphics materialization发生前拒绝，而不必先执行未知操作再发现资源缺口。`Fixtures/ConsumerSmoke/Tests/ImageCraftConsumerSmokeTests/ProgressiveFinalizationAdmissionTests.swift` 进一步把**外部host选择顺序**做成独立SwiftPM发布门：fake session同时实现resource-aware与legacy finalizer时，resource-aware永远先于legacy；hard-bounded模式看到unknown或preflight尚未ready时，两个consuming finalizer调用计数都必须保持0；显式允许unknown时仍返回原ledger而不抹掉reason；只有完全缺少resource-aware capability时才暴露legacy value-only分支。`scripts/verify-consumer-package.sh` 现在会实际运行10个macOS consumer tests，再继续release与iOS simulator/device编译，因此该host policy不是包内@testable假象，也没有把codec rollout/selection塞回ImageCraftCore。真实 `ImageIOImageDecoder` progressive session的final-image preflight在787-byte retained source完成后暴露 `retained=787 / operationPeak=unknown(frameworkPrivateOperationAllocation) / transferredOutput=unknown(frameworkChosenOutputLayout) / frameworkChosen`，bounded host可事前拒绝；prepared-token消费边界则由公开 `PreparedImageResourceInspecting` 证明重复读取不消费、decode/discard后ledger消失。preparation **creation** 现在也不再混在这两个阶段里：`ImageProgressivePreparationCreationResourceAuthority` / `ProgressiveImagePreparationCreationResourceInspectingSession` 将creation operation与resulting decoder-retained state分开，且generic alias `ImageDecodePreparationCreationResourceAuthority` 被新的public `PreparedImageCreationResourceInspecting` 复用于静态 `prepare(data:limits:)`。progressive source-bound v1绑定787-byte/47×17-byte source，要求call-boundary retained=787、operationPeak仍是framework-private unknown、transfer=0/layout=none；resulting preparation retained=787，并与成功token ledger逐字段对齐。aggregate store admission已前移到任何final `CGImageSource`/security/metadata framework work之前，因此store-full保持finalReady可重试。静态 `Evidence/Experiments/StaticPreparationCreation/v1/profile.json` + `Tools/Quality/validate_static_preparation_creation.py` 则要求 caller-owned input 在preflight call boundary **retained=0**、operationPeak仍unknown、transfer=0/layout=none；无ICC control的resulting data-only preparation精确787 B，与实际token ledger一致，且preflight前后prepared-store snapshot不变。JPEG APP2 ICC还能在不materialize profile时由chunk payload直接发布exact profile byte count，所以static/progressive data-only resulting charge都可精确为 `encoded bytes + assembled ICC bytes`；缺失ICC chunk在EOI fail-closed。相反，当前runtime的纯JPEG probe替代路线被明确反证：同一retained JFIF的container APP/COM metadata只有**14 B**，但ImageIO `ImageProbe.metadataByteCount`为**240 B**，符合公开合同 `max(container payload, serialized ImageIO property estimate)`；因此不能为了得到bounded creation偷偷把probe改写成14 B。这个240值是当前runtime机会哨兵，不是跨OS常数：若将来property-derived charge不再大于container metadata，validator/test会提示重新评估pure-value fast path。以上变化仍**没有**把ImageIO creation operation变成bounded；它只把未知operation与可证resulting state分开。v8 representation证据继续要求whole-finalization packed authority，不因preparation contract变化而重解释历史。

`Evidence/Experiments/CrossBackendJPEG/v1/profile.json` 与
`Tools/Quality/capture_cross_backend_packed_jpeg.py` 使用 clean/pinned
`AxiomRasterCodecJPEG.NativeScalar`、AxiomRaster core/API 和 libjpeg-turbo 作为只读研究输入。
它硬检查 geometry、tight stride、RGBA/opaque-alpha、row/channel spatial sanity 与 source identity，
但把 lossy JPEG 的 pairwise pixel delta、对 libjpeg-turbo 的差异和对确定性生成源的 PSNR/MAE
分开记录。T68 已冻结的 max-channel≤2 / mean-absolute≤1 gate 被原样重算，capture 无权从本次
观察放宽它。当前 `.artifacts/quality/cross-backend-packed-jpeg-v1/functional-smoke.json` 只是
显式提供预构建 binaries 的功能 smoke：5/5 representation checks 通过、旧 pixel gate 2/5
通过，报告自身标记 `formalSourceBoundExecution=false` 和 `productionSecondBackendQualified=false`。
正式 source-bound evidence 仍要求 capture 在同一次运行内重建两个 comparator binaries。

### T101 独立 PNG 与 bounded operationPeak

package-only `PNGIndependentRGBA8Decoder` 为 packed-value seam 增加了真正不依赖 ImageIO
rasterization 的静态 PNG 第二实现。当前实现域包括 full-resolution 的 non-interlaced
`grayscale1/2/4/8`、`grayscale+alpha8`、`RGB8`、`RGBA8` 与 indexed 1/2/4/8-bit，以及单独收窄的
Adam7 `RGBA8 + explicit sRGB` slice；indexed PLTE/tRNS、grayscale/RGB tRNS 与 truecolor suggested
PLTE 也在各自结构约束内实现。成功 formal 资格要求显式 sRGB；实现还支持 non-interlaced
preserve-source 的 structurally-valid RGB ICC，但 embedded ICC 尚未升级为 libpng simplified-API
pixel-oracle 域。untagged、非 RGB ICC、`cICP`、`gAMA`/`cHRM`、HDR `mDCV`/`cLLI`、eXIf、
Adam7 的其它 source/color-authority 组合与 animation 等未实现语义 fail closed。16-bit 不会被该
RGBA8 backend降精度后冒充支持，而是由下面独立的 high-depth value/backend seam资格化。shared security
scanner按 PNG color-authority precedence 处理 `cICP > iCCP > sRGB > cHRM/gAMA`：若 cICP 存在，
当前 `SourceColorProfile` 只能诚实发布为 `.unknown`，不会错误继承低优先级 iCCP/sRGB；未成为有效
authority 的 iCCP 也不会被无谓解压或跨调用保留。

纯 Swift RFC1950/RFC1951 decoder 覆盖 stored/fixed/dynamic Huffman、32 KiB back-reference、
Adler-32、exact/maximum-output 边界和严格 incomplete-tree 规则；pixel path 使用一个36 KiB循环
logical-output window：32 KiB历史lookback与4 KiB pending delivery共享同一payload，不再每次flush
把staging复制进第二份history。它直接驱动两行 PNG unfilter，并把最终值写入 tight premultiplied
RGBA8。IDAT 不再先拼接成第二份 `Data`：decoder 消费 shared security validation 产出的 immutable
`PNGValidatedContainerFacts`，用 caller-owned PNG 上的 bounded cursor 跨连续 IDAT chunk读取同一
zlib字节流。完整 inflated scanline surface、concatenated compressed-body surface以及第二次
whole-container interpretation 都不再进入该路径。

`Tools/Quality/capture_independent_png_conformance.py` 在 source freeze 内先用隔离 SwiftPM scratch
运行完整 Swift 测试，再直接以当前 Core/ImageIO 源码编译研究 probe，同时编译 libpng C probe，
生成确定性 corpus，并要求 source before/after 完全一致。当前 profile 有 26 个成功样例，覆盖
non-interlaced RGBA8/RGB8、grayscale 1/2/4/8-bit、grayscale+alpha8 与 indexed 1/2/4/8-bit，另有
3 个 Adam7 RGBA8 success cases；filters 0–4、mixed filters、contiguous split-IDAT、RGB/grayscale
tRNS、truecolor suggested PLTE、2/3/11/256-entry indexed PLTE 与不同长度 indexed tRNS 都进入
external oracle。Adam7 corpus 由独立 Python generator 按七个 pass 重排 source samples，并在每个
pass 内独立应用 filter history；13×11 覆盖完整 pass/filter/split-IDAT，1×1 与5×3覆盖 empty-pass
几何。sub-byte grayscale/indexed rows先按
PNG规定以packed byte rows、`bpp=1`过滤，再MSB-first解包；13-pixel宽度样例故意跨非整字节尾部。
低bit-depth grayscale在原始sample域完成tRNS比较，再精确扩展到8-bit；非零unused-high-bit masking
另由package/ImageIO differential锁定，避免把libpng 1.6.58的warning行为误当成格式语义。每个成功样例
同时要求 ImageCraft 发布 `packedColorEncoding=sRGB`、无 embedded ICC transfer，libpng报告
`colorspaceNotSRGB=false`、`associatedAlpha=false` 且无 warning/error；随后 ImageCraft packed
bytes 必须与“确定性 straight source → libpng straight RGBA → 独立 premultiply”逐字节一致。

23 个 hostile 样例固定 CRC/trailing、8-bit与2-bit palette越界index、Adam7 truncated pass stream、
noncontiguous IDAT、gamma-only、unknown critical、operation-budget、cICP、known-ancillary IDAT split、
untagged、GRAY/CMYK ICC、current-version reserved bit、sRGB旁带 gAMA/cHRM、late sRGB、cICP+mDCV、
cLLI、malformed chunk type与hIST结构错误。通用 PNG security层另锁定 IHDR/IDAT/IEND、已知chunk
长度/重复/ordering、PLTE/tRNS和颜色/HDR结构规则；独立backend再在结构合法输入上执行更窄的
语义资格。机器可读结果位于 `.artifacts/quality/independent-png-v1/formal-report.json`；formal
capture要求source before/after稳定、26/26 success exact 与23/23 hostile fail-closed，并始终保持
`productionBackendQualified=false`。报告对 indexed/grayscale sub-byte success 显式记录
`indexedBitDepth` / `grayscaleBitDepth` 与 PLTE/tRNS facts，而不是靠case ID推断位深。报告自身记录精确source identity、probe/oracle
binary identity与运行时。文档刻意不回填“当前source SHA/report SHA”，因为文档本身属于source
identity；把capture产生的哈希再次写回文档会改变被哈希对象，形成无意义的自引用循环。
RGBA8 embedded ICC implementation support目前仍由unit/resource oracles覆盖，不借用libpng simplified API
伪装成任意ICC raw-sample authority；下面的PNG16 slice则只资格化 preserve-source profile byte retention，
并用 libpng `png_get_iCCP` 做独立 profile oracle，不宣称 CMS conversion。

### T101 high-depth packed value 与 PNG16

16-bit 没有通过把 `ImagePackedRGBA8` 扩成模糊的“RGBA”类型来接入。package-only
`ImagePackedPixelFormat` 把 sample storage、channel layout、alpha association 与 multibyte byte order
分成独立契约维度；现有 `ImagePackedRGBA8` 仍精确发布 `uint8 / RGBA / premultiplied / no-byte-order`。
新的 `ImagePackedRGBA16Straight` 则固定为 tight、top-to-bottom、`uint16 / RGBA / straight /
little-endian`，每像素8 bytes。选择 straight alpha 是精度边界而非便利偏好：partial alpha 下先做
integer premultiply 会不可逆地丢失原始 RGB sample，不能再作为 exact high-depth value。可选的
`ImagePackedSourceSignificantBits` 与 storage format 分离：它显式区分 source 的 `.grayscale`、
`.grayscaleAlpha`、`.rgb` 与 `.rgba` channel model，并记录各自真实 significant depth；gray/RGB+tRNS
归一化后得到的 alpha 因而不会被误标为 source-stored sBIT alpha。

`PNGIndependentRGBA16Decoder` 现在覆盖 PNG 的四种标准 non-indexed 16-bit source channel model：
grayscale、grayscale+alpha、RGB、RGBA；explicit sRGB、full-resolution，non-interlaced 与 Adam7 共用
同一 stored-sample contract。PNG filter 始终在 source big-endian bytes 上执行，source `bpp` 分别为
2/4/6/8。gray/GA 只在最终写出时把 gray 复制到 R/G/B；GA/RGBA 保留 source-stored straight alpha。
gray/RGB `tRNS` 在两种 scan order 下都在完整 UInt16 stored-sample 域比较，精确命中才写 alpha=0，
其余写 alpha=65535。Adam7 共用 checked pass geometry，在每个 pass 边界清空 previous-row filter
history，并直接 scatter/expand 到最终 RGBA16LE，不创建 pass surface。这样透明像素的 source gray/RGB
不会因 premultiply 或先降成8-bit丢失。operation payload charge 是 final 8-Bpp value + 两条 exact
source rows（gray/GA/RGB/RGBA 分别2/4/6/8-Bpp）+ fixed streaming/Huffman workspace；没有 full inflated
surface、第二份compressed body、CGImage或 premultiplied high-depth副本。ledger继续使用独立
`codecOwnedStraightRGBA16LE` authority。RGB/RGBA16 的 `.preserveSource` 另允许 validated RGB iCCP：
先在 profile inflate 前按 metadata ceiling 与 RFC1950 maximum-output security phase 做 admission，随后
只保留实际 profile bytes；`.preserveSource`把它作为 `ImagePackedPixelColorEncoding.embeddedICC` 并计入
transferred-output 与 pixel-phase charge，`.convertToSRGB`则只对严格资格化的 forward-device
RGB/XYZ matrix/TRC profile执行16-bit转换，profile class仅允许 monitor `mntr` 或 input `scnr`：source matrix/TRC逐tag解析且矩阵必须非退化；`mntr`继续要求 `wtpt` 在 s15Fixed16 量化容差内等于 D50 且三条 colorant 重建同一 white，`scnr`则按 input-device relative-colorimetric 语义保留 captured-medium `wtpt`，只要求 X/Z 非负且 Y>0，不再把介质白点误当成 PCS D50 或要求 device code `[1,1,1]` 重建它。TRC资格允许三条共享同一raw encoding/参数，也允许 R/G/B 各自独立通过现有 `curveType` 或 parametric type-0...type-4 资格，且三通道可混合已资格化的 encoding/function/参数。TRC 当前有两类资格域：parametric type-0...type-4，要求 source transfer 在 `[0,1]` 有限、弱单调、归一化且无需额外 clipping；以及 `curveType` 的三种规范形式：count=0 identity，count=1 positive u8Fixed8 gamma（forward `Y=X^gamma`），以及 count>1 normalized weakly-nondecreasing UInt16 sampled curve。sampled 输入节点按 ICC 定义均匀覆盖 `[0,1]`，节点间直接线性插值；table 从已保留的 ICC profile bytes 原位读取，不复制成第二份 `[Double]` 或 frame-sized staging。type-0要求 gamma>0；type-1/type-2要求 gamma>0、a>0、`-b/a` 落在 source domain且高端回到1；type-2同时约束 c；type-3/type-4要求有效 breakpoint/power base、非负 lower slope、两段近连续并保持0→1端点，type-4显式保留 e/f offsets。profile只在 operation phase存活而不进入 transferred representation。
该域含 Display-P3+sRGB-like type-3、非P3的 sRGB-D50 primaries+gamma2.2 type-3、同一primaries下的 type-0 gamma1.8/gamma2.2、独立的 type-1/type-2/type-4 piecewise profiles、`curveType` identity/gamma1.8/gamma2.2/5-point nonlinear sampled curve，以及 R/G/B 分别采用约1.8/2.0/2.2 gamma 的 per-channel type-0 profile；这些组共同固定输出由输入 matrix/TRC tags、每通道TRC encoding/function/raw参数/采样表驱动而不是 profile名、P3常量或单一 shared-curve 假设。compressed iCCP body始终借用 caller-owned chunk range。grayscale/GA
的 RGB ICC、RGB/RGBA 的非RGB ICC、LUT/MPE、per-channel TRC 中任一 channel 自身不满足既有 curveType/parametric type-0...type-4 资格的组合、非D50/white-mismatch monitor、implausible input media white、degenerate matrix、
ICC+sBIT/HDR以及 out-of-sRGB-gamut ICC conversion仍 fail-closed；显式 sRGB path不会无条件预留 ICC
metadata ceiling。RGB/RGBA16 的 `.preserveSource`
现在还可保留三组 full-range cICP raw authority：Display-P3 SDR `0C 0D 00 01`、BT.2100 PQ
`09 10 00 01`、BT.2100 HLG `09 12 00 01`。`ImagePackedPixelColorEncoding.cicp` 保存四个原始字段且
fixed metadata不增加 payload charge；packed `SourceColorProfile`继续是 `.unknown`，避免把 P3/PQ/HLG
错误标成sRGB。`.preserveSource` cICP资格化 raw code-value + signaling preservation；另外只有 full-range
Display-P3 SDR `0C 0D 00 01` 的 RGB/RGBA16、无 sBIT/HDR、且逐像素转换仍落在 sRGB gamut 内时，
`.convertToSRGB` 才执行16-bit linear-light P3→sRGB conversion。该切片不做 gamut mapping；任一像素
越出目标 gamut 即整次 fail-closed。PQ/HLG conversion、tone-map 与 raw cICP 的 CoreGraphics
rasterization仍未资格化；packed→CG materializer对 preserve-source cICP 显式 `rasterizationUnavailable`。full-range
BT.2100 PQ还可携带 typed mDCV/cLLI static HDR metadata：mDCV保留8个0.00002-unit UInt16色度坐标与
2个0.0001-nit UInt32亮度整数，cLLI保留MaxCLL/MaxFALL两个0.0001-nit UInt32整数；两类 metadata都
与 colorEncoding 正交、不会改写 pixel bytes或扩大 transfer/operation charge，zero cLLI也原样保留为
“未知”编码值而不代替调用方解释。scanner在发布facts前执行31-bit四字节整数上限，并继续要求 mDCV
伴随 cICP。P3/HLG+HDR metadata、narrow-range、未知tuple、gray/GA cICP、PQ/HLG `.convertToSRGB`
以及 out-of-sRGB-gamut P3 conversion仍 fail-closed。shared scanner遵守 `cICP > iCCP > sRGB > cHRM/gAMA`；较低优先级 iCCP 可留在容器facts中，
但 cICP path不会inflate、retain或transfer它。

`Tools/Quality/capture_independent_png16_conformance.py` 通过 deterministic stored-source generator 与
classic libpng read API建立多层独立16-bit oracle。C probe不调用 strip-16 或 byte-swap，并根据 source
IHDR channel model独立使用 `png_set_gray_to_rgb`、`png_set_tRNS_to_alpha` 或 opaque-alpha filler，最终
产出 straight RGBA16BE；capture自己从 generator 的2/4/6/8-Bpp stored source构造 expected RGBA16BE，
再独立逐sample做 BE→LE，要求 external libpng expansion 与 ImageCraft canonical value各自逐字节相等。
Adam7 success 由 generator 真正按七个 pass 抽取 stored source、在每个 pass 内独立 filter 后压缩；C
probe在 `png_read_update_info` 前调用 libpng interlace handling，要求 source interlace=1、7 passes，并由
libpng重建/扩展 full-resolution RGBA16BE 后再与 generator oracle逐字节比较。ICC preserve-source case由
generator构造 deterministic RGB monitor profile；C probe在任何 pixel transform前用 `png_get_iCCP` 提取
profile，capture要求 generator profile、libpng profile 与 ImageCraft retained profile逐字节一致，同时 pixel
oracle仍保持 stored-source exact。ICC conversion case由 generator透明构造312/320/324/328/336-byte以及2360-byte large-sampled forward-device
RGB/XYZ matrix/TRC profile；既有 matrix/TRC fixtures保持 `mntr`，另有三组只改 header class bytes 的 `scnr` input-class paired cases。real-input positive 另保留一个724-byte `scnr/RGB/XYZ` gamma+matrix profile：它由 ColorReference 的 Epson Perfection 3170 48-bit/no-color-correction 实际扫描与288个 individually measured IT8 patches 经 ArgyllCMS 3.5.0 `scanin` + `colprof -ag -nc` 派生，明确不是 Epson/ColorReference/Argyll vendor profile；fixture、原始 archive/file SHA-256、工具 binary SHA-256 与 derivation 都在 `fixtures/provenance.json`。该 profile 的 non-D50 captured-medium `wtpt` 与 authored colorant matrix 不满足 display-white reconstruction，因而直接固定 input 与 display white semantics 不能共用同一门。capture独立解析每个 profile 自己的 s15Fixed16 colorants 与三条 channel TRC encoding，并把 profile class 限定为 `mntr|scnr`。shared profile覆盖完整资格域；不同channel现在允许三条各自独立通过现有 curveType 或 parametric type-0...type-4 资格后任意组合，不再要求三条使用同一种 TRC encoding。parametric type-0...type-4按对应 ICC 函数公式解码（包括 type-1/type-2 的 `-b/a` threshold 与 type-4 的 e/f offsets），并独立拒绝需要 source-domain clipping、非归一化或负向 discontinuity 的 profile；`curveType` count=0按 identity、count=1读取 stored u8Fixed8 gamma并按 forward `Y=X^gamma`、count>1则要求首尾0/65535且弱单调，按 `x*(n-1)` 定位相邻 UInt16节点并做线性插值。随后统一转换到 ICC 官方 reference sRGB D50 matrix并做 nearest UInt16量化，要求 ImageCraft exact命中。同时独立
LittleCMS 2.x 以 relative-colorimetric、16-bit、NOOPTIMIZE执行同一 profile→sRGB transform并要求 alpha逐值不变。既有 shared/per-channel-type0 与历史5-node sampled retained cases继续保留≤1 final-code regression gate；mixed per-channel parametric、mixed-encoding、1025-node large-sampled 与 real-measurement-derived input-profile cases只要求 CMS transform成功并记录 observed delta，不把选定样本或 CMS内部16-bit离散化差提升成规范 tolerance。当前 mixed-encoding retained fixture 的 LittleCMS 2.19 最大 RGB 差为3 codes、1025-node fixture为1 code，而 real Epson-derived per-channel curveGamma fixture在保留的 measured in-gamut samples上最大为16 codes，alpha均 exact。real-input capture现在还记录 `cmsCreate_sRGBProfile()` 实际发布的 target RGB→D50 XYZ colorants，并在 source profile/TRC/source pixels 全部不变时仅把独立 oracle 的 target matrix 换成该 observed matrix；两个 retained real-input case 的差异随即收敛到≤1 code。独立 source-bound 机制实验 `Tools/Quality/analyze_real_input_lcms_target_matrix.py` 再对17×17×17 device-RGB coarse grid筛出540个仍落在目标 gamut 的点：ICC-reference target 下 LittleCMS 最大差39 codes，而仅替换为 LittleCMS 自己的 target matrix 后最大差1 code。这个 counterfactual 只用于定位实现差异，不能反过来把 LittleCMS virtual sRGB matrix 升级为规范；ImageCraft 仍以 ICC reference sRGB D50 matrix 的 deterministic tag-math exact 为硬门。formal保留 P3+sRGB-like type-3、
sRGB-D50 primaries+gamma2.2 type-3、type-0 gamma1.8/gamma2.2、能实际跨越piecewise分支的 type-1/type-2/type-4、`curveType` identity/gamma1.8/gamma2.2/nonlinear 5-point sampled 与 deterministic 1025-node quadratic sampled profiles；1025-node cases显式声明 `maximumMetadataBytes=4096`；formal probe的历史默认 metadata budget仍是1024并会在 ICC inflate/transform前拒绝同一2360-byte profile，而产品 `DecodeLimits.coreV1` 的4MiB默认值没有被这项证据改写，以及同一profile内 R/G/B 分别使用 type-1/type-3/type-4 的 mixed-parametric case与 sampled-curveType/type-3/single-gamma-curveType 的 mixed-encoding case，避免 profile-name/hash、P3常量、shared-curve假设、统一TRC encoding假设、单一TRC function或“只解析不执行分段/插值”的自证。cICP case在任何
pixel transform前用 libpng
`png_get_cICP` 读取四字段，要求与
generator manifest及 ImageCraft source authority逐字段相等；libpng pixel oracle仍独立重建同一 raw16 value。
Display-P3 `.convertToSRGB` case在这条 raw oracle之外再走一条独立数值链：capture按 W3C CSS Color 4
公开的 exact-rational P3→XYZ 与 XYZ→linear-sRGB 两段矩阵分别乘法，而不是复用 ImageCraft 合并后的
difference-form系数；随后独立执行同一规范的 transfer curve 与 nearest UInt16 code量化，并要求 alpha
逐值不变。PQ HDR static-metadata case另用 `png_get_mDCV_fixed` / `png_get_cLLI_fixed` 建立整数 external oracle：mDCV
色度 fixed value必须等于 stored UInt16×2，max/min luminance与 cLLI light-level必须逐值等于 stored
0.0001-nit UInt32；ImageCraft `hdrStaticMetadata` 再独立与 manifest逐字段相等。v1 profile扩展到94个
success：既有47个 preserve-source sRGB/ICC/cICP/HDR case之外，加入3个 cICP P3→sRGB、3个 P3
type-3 matrix/TRC ICC→sRGB、3个非P3 gamma2.2 type-3、3个 type-0 gamma1.8/gamma2.2、type-1/type-2/type-4 各3个，`curveType` single-gamma、identity、nonlinear 5-node sampled 各3个，另加 deterministic 1025-node sampled 3个，per-channel type-0 3个、per-channel mixed type-1/type-3/type-4 3个，以及 per-channel sampled-curveType/type-3/single-gamma-curveType mixed-encoding 3个
matrix/TRC ICC→sRGB case，再加入3个与既有 gamma2.2 type-3 `mntr` case逐项配对、仅把 profile class 改为 `scnr` 的 synthetic input-class case，以及2个共用同一 real Epson-derived `scnr` gamma+matrix profile、分别覆盖 linear/Adam7 RGBA16 的 real-input case；real source pattern直接取自实际 scanin 输出的10个 measured device-RGB patch值中已独立验证落在目标sRGB gamut的样本，而不是重新生成“像真实”的颜色。每个 synthetic TRC slice仍覆盖 linear RGBA16、Adam7 RGBA16 与 Adam7 RGB16+tRNS/high-byte-near-miss，
因此 scan order、source-domain transparency、piecewise/gamma semantics、TRC encoding kind与 profile-tag transform不是分离自测。并继续与 RGB+tRNS high-byte near-miss、sBIT、partial stored alpha交叉。仍覆盖 filters 0–4
与 split-IDAT 1–5；PQ/HLG preserve-source仍只证明
raw code value + signaling/HDR metadata preservation，不宣称 tone-map 或 rendered appearance conformance。

sBIT formal 不把 metadata presence 当作充分证据。generator 为每个 sBIT case 另外写一份 reference
sample U16BE oracle，并要求每个低于16-bit的 source channel 实际出现非零 low-order fill；capture独立
验证 `stored >> (16 - S)` 逐sample恢复 reference oracle，同时要求 libpng `png_get_sBIT` 与 ImageCraft
`sourceSignificantBits` 精确发布同一个真实 source channel model。classic libpng 的 `png_color_8` 即使
source没有 alpha 也保留 alpha 字段且 raw field 可被填成16；probe因此以 IHDR判断 source alpha，把
semantic alpha significance与 `libpngSBITAlphaFieldRaw` 分开观测，避免把 struct shape 或 transform后
信息误当 provenance。gray/RGB+tRNS 的 output alpha始终是derived，GA/RGBA才携带 source alpha
significance。stored RGBA16LE像素本身保持不变，这套metadata contract在Adam7下也不改变像素或
operation charge。profile现在有42个hostile：在 parametric type-0 gamma=0、type-1 `a<=0`、type-2 高端非归一化、type-4 负向 discontinuity与 white-mismatch 等既有反例之外，`curveType` 继续保留 zero-gamma，并把旧 identity/sampled 拒绝样本替换为 sampled non-normalized（首值非0）与 non-monotone 两个结构合法 profile，固定“支持 sampled”不等于放弃 source-domain normalization/monotonicity；H37 固定 per-channel 中单个 parametric curve 自身非法（type-1 `a=0`），H38 固定 mixed-encoding profile 中单个 curveType gamma=0，H39把1025-node `curveType` 声明 count改成1026但保持实际 payload不变，要求 exact tag-size/count mismatch fail-closed；H40保留同一已资格化 matrix/TRC payload但把 profile class 改成 output `prtr`，要求精确落到 `unsupportedSourceSemantics`，证明 input-class widening没有泛化成任意 ICC class；H41/H42原样保留 ICC Profile Library 的 `linear_RIMM-RGB_v4.icc` 与 `ISO22028-3_RIMM-RGB-exCR.icc`，两者都是真实 `scnr/RGB/XYZ` scene-referred profile，但 forward transform 是 `mAB`/A2B LUT；formal 显式把 metadata ceiling 提高到大于各 profile 实际字节数后仍要求 `unsupportedSourceSemantics`，固定“真实 input class”不能绕过 LUT/MPE semantic gate。fixture SHA-256、字节数、source URL 与分发条款记录在 `Evidence/Experiments/IndependentPNG16/v1/fixtures/provenance.json`；这些反例共同证明跨函数号/跨 encoding/扩大 sampled cardinality/profile class都不绕过每条 curve、payload shape 与 forward-device class 的独立资格；真实 P3 matrix/TRC ICC + pure-red
out-of-sRGB-gamut conversion继续固定 gamut gate，只有保存语义、没有资格化 matrix/TRC transform的旧 RGB ICC
仍固定为 unsupported。原有 P3+mDCV/cLLI hostile继续固定“只 PQ 接受 static HDR metadata”的 semantic
boundary。这些反例区分 container-corrupt（长度/31-bit/accompaniment）与 structurally-valid-but-unqualified
（zero/nonpositive gamma、nonpositive affine scale、non-normalized endpoint、negative discontinuity、curveType sampled non-normalized/non-monotone、white mismatch/degenerate or unsupported ICC semantics、P3/HLG static-metadata、PQ/HLG conversion、
out-of-gamut conversion）两类失败。机器结果写入
`.artifacts/quality/independent-png16-v1/formal-report.json`；正式capture要求source before/after稳定、
94/94 external/container oracle与 canonical/converted value exact、preserve ICC三方字节一致、generic ICC
profile-tag/TRC-kind/function deterministic oracle exact；profile-class gate要求3个 synthetic `scnr` success、3组 `mntr`/`scnr` parity pair逐组满足 same stored source / canonical pixels / operation bound / transfer bound，synthetic `scnr` LittleCMS observation继续满足既有≤1-code gate，并要求唯一 output-class hostile精确 fail-closed；real-input positive gate要求2个 Epson-derived `scnr` success、同一724-byte profile SHA/provenance、linear+Adam7覆盖、三条 independently parsed `curveGamma` TRC、deterministic tag-math exact、LittleCMS observation available/alpha exact，并记录当前最大16-code RGB delta而不把它升级成容差；同一 gate 还要求 probe 发布 LittleCMS target sRGB matrix，且 source/TRC 不变、仅换用该 matrix 的 counterfactual 差异≤1 code，以机器方式固定当前较大 delta 来自 target-space realization 而不是 real input-profile 解析；real-profile negative gate另要求2个 ICC Profile Library `scnr` LUT fixture 的 source SHA/byte-count provenance存在、resolved metadata budget大于profile本体且两者都精确以 `unsupportedSourceSemantics` fail-closed；machine-readable `iccParametricFunctionType` success集合必须精确为 `[0,1,2,3,4]`，`iccTransferCurveKindsQualified`必须精确包含 `parametric`、`curveGamma`、`curveIdentity` 与 `curveSampled`，要求 single-gamma、identity 各恰好3个 success、sampled curveType共6个，其中 `iccLargeSampledCardinalitySuccessCases=3` 且 nodeCount=1025/profileByteCount=2360/resolvedMaximumMetadataBytes=4096；`iccPerChannelType0SuccessCases=3`、`iccPerChannelMixedParametricSuccessCases=3`、functions `[1,3,4]`，并要求 `iccPerChannelMixedEncodingSuccessCases=3`、channel kinds `[curveSampled,parametric,curveGamma]` 与 exact deterministic gate。LittleCMS 对旧 retained slices继续≤1 regression gate；mixed-parametric、mixed-encoding与large-sampled只要求 observation available/alpha exact并记录 delta；cICP source/output字段一致、cICP P3→sRGB
W3C独立数值oracle、HDR static metadata整数oracle、Adam7 reconstruction、reference recovery、source-channel
sBIT metadata全部通过、42/42 hostile fail-closed，
并始终保持 `productionBackendQualified=false`。

资源回归另用 512×512 fixture 固定两次独立 ownership 改善：streaming history 相对旧
full-inflated 模型单独减少超过 1,000,000 bytes 的 admission charge；随后 IDAT cursor 又按
实际 compressed payload 大小精确移除 concatenated-body charge。当前首道与最终 admission都按
真实 `sourceBitsPerPixel` 推导 source row charge：byte-aligned源按其真实Bpp，grayscale/indexed
1/2/4-bit则按 `ceil(width * bitDepth / 8)`，而输出始终是4-Bpp packed RGBA。iCCP compressed slice直接
借用 caller-owned chunk range，两阶段 admission先根据 validated facts确定真实authority与
operation envelope，再决定是否inflate ICC。测试在只覆盖当前 codec-owned payload 的预算点完成
实际decode；旧聚合/全量-inflate/按1-byte-per-index无条件过收费/无条件ICC-ceiling模型在对应
对照预算下会超限。

这证明的是 ImageCraft-owned payload ownership 的结构变化，不是物理 RSS、设备能耗或全 PNG
格式资格。caller-owned encoded source若需要进入宿主总live-set预算，应在phase composition层
单独加入。security/decode复用同一 immutable chunk/range plan已经完成；下一资源证据缺口转为
稳定设备上的 bounded-path runtime、宿主 total-live-set composition，以及仍由 ImageIO 私有
allocator/workspace决定的 framework `operationPeak`，而不是再重复扫描已验证PNG容器。

同一代码树还维护两份方向性 host performance formal。RFC1950机器报告位于
`.artifacts/performance/rfc1950-inflate-comparison-v1/formal-report.json`，覆盖 repetitive、
literal-heavy `png-scanline-v1` 与 incompressible 三类1 MiB流，并分别记录 exact pure、streaming
pure 与 Apple Compression。当前 decoder保留9-bit fast table与56-bit reservoir，fast-literal
hot loop可在同一次refill后连续消费最多3个literal；扩大主表、32-bit refill、SIMD Adler、逐字节
short-match copy等未形成稳定收益的实验均已回退。whole-PNG机器报告位于
`.artifacts/performance/independent-png-decode-comparison-v1/formal-report.json`；RGB8在当前host
方向性已明显快于ImageIO，而RGBA8仍有可测差距。对同一formal RGBA fixture直接抽取IDAT后可见，
差距主要位于其特定高熵DEFLATE流，而不是PNG row/premultiply框架的通用固定成本；因此synthetic
`png-scanline-v1`不能替代actual-IDAT分解。两份capture都先跑完整package测试、使用隔离SwiftPM
scratch、锁定Release binary SHA并要求source before/after不变；精确source identity、报告SHA、原始
samples与当前ratio以机器报告为准，避免文档哈希自引用。这些结果只描述当前MacBookPro18,3/
macOS 27 host，不是跨设备速度、能耗或production资格主张。

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

## 独立渐进 JPEG suspension / persistent-state 机制证据

`Evidence/Experiments/IndependentProgressiveJPEG/v1/profile.json` 与 `Tools/Quality/capture_libjpeg_progressive_suspension.py` 使用 pinned Homebrew libjpeg-turbo 3.2.0 classic API 建立 package-only research seam，而不把 libjpeg-turbo 加入 ImageCraft package dependency。自定义 source manager 遵守 libjpeg 的 rollback contract：`fill_input_buffer()` 在当前 transport prefix 耗尽时返回 suspension 且不改写 library 公布的 restart pointer/count，只有 library 真正返回 `JPEG_SUSPENDED` 后，外层才把 rollback tail 搬到一个 128 KiB work buffer 起点并追加新到达字节。首版“直接暴露越来越长的原始 prefix”反例曾在 512-byte 分片下产生不同 final RGB、在更小分片下触发 bogus Huffman/extraneous-byte diagnostics，因此已被否决；当前状态机是由该 falsifier 与 libjpeg marker rollback 源码共同收敛出来的。

source-bound capture 覆盖 5 个 progressive JPEG、21 个 chunk schedule：一个 23×13 retained fixture 用 1/17/128/512/full feed，四张 1920-wide 公共领域真实照片覆盖 7/9/10-scan script 并用 1 KiB/16 KiB/32 KiB/full feed。每个 case 要求所有 schedule 的 scan-completed 序列与 implementation-observed consumed offsets完全一致、warning=0、final raw RGB逐字节一致，并再与同一 pinned installation 的 one-shot `djpeg -rgb` 逐字节相等。独立 Python marker parser只负责结构 SOS count；libjpeg 的 consumed offset保留为 implementation observation，不提升为 JPEG 规范 offset。机器结果位于 `.artifacts/program/T101/libjpeg-progressive-suspension-v1.json`，当前 5/5 cases、21/21 schedules 全部通过，且 source before/after 稳定。

该 probe 同时把“有 persistent state”从模糊内存主张收紧为 allocator 生命周期观察。8-bit `JCOEF`/`JBLOCK` geometry先独立计算 padded coefficient-array payload；对严格锁定的 libjpeg-turbo 3.2.0 private `jmemmgr` layout，probe再读取 `total_space_allocated` 于 create/header/start-decompress/EOI/final-render/finish 六个 checkpoint，并在 `realize_virt_arrays` 真正分配 backing 之前直接读取 virtual-barray control block 的 `rows_in_array` / `blocksperrow` / `maxaccess`。capture会验证这些 private allocator dimensions 与 JPEG component geometry一一对应、normal RGB path没有额外 virtual-sarray、chunk partition下 resource geometry不变、pre-finish pool单调以及 `EOI pool + source-manager state` / `final-render pool + source-manager state + final RGB` 的组成关系。最大 case 1920×1285 4:2:0：coefficient arrays 7,464,960 B，EOI libjpeg pool 7,549,477 B，source-manager state 131,200 B，因此 observed retained decoder live bytes 为 7,680,677 B；final RGB 7,401,600 B 共存时 observed modeled final-render live bytes 为 15,082,277 B。该 private-ABI observation只对 pinned 3.2.0有效，不是公开 libjpeg API、跨版本上界或物理 RSS。

同一 capture 现在还把 no-backing-store virtual-array admission 做成 1-byte boundary falsifier。四个 1920-wide case 都需要多于一个 allocator minheight；最大 1920×1285 case 在 virtual-array realization 前 pool 为 84,009 B，full coefficient maximum space为 7,464,960 B，因此 exact availability hinge 为 7,548,969 B：配置 7,548,968 B 时以 `Memory limit exceeded` 退出，error checkpoint仍是84,009 B且没有发布输出；配置7,548,969 B则最终 RGB仍与 one-shot `djpeg`逐字节一致。成功后的 pool 已是7,549,134 B，即超过配置值165 B，直接反证把 `max_memory_to_use` 当成总 pool cap。23×13 反例则更强：三个 coefficient arrays 都只需 allocator强制保留的一个 minheight，因此 `max_memory_to_use=1` 仍能逐字节完成，start-decompress pool 为23,246 B；capture明确把它分类为“无 sharp threshold”，而不是强行套用 threshold-1 规则。另一个既有负面结论仍成立：同尺寸控制重编码中，grayscale/4:4:4/4:2:2/4:2:0 的 `EOI pool - coefficient payload` 分别约33.7/65.2/53.8/84.5 KiB。

新的 `jpeg_memory_mgr` pre-realize allocation trace 已把上述 sampling-dependent overhead 拆成可计算机制。1920×1285 4:2:0 从 header pool 18,454 B 到 virtual-array realization 前 84,009 B 的 65,555 B 增量，逐事件完全由五个 `alloc_sarray` 承担：两个 1920×2 upsampler buffers 与 1920×20、960×10、960×10 main-controller buffers；其余 controller、IDCT、progressive entropy 与 virtual-array control small allocations都复用 header 后既有 small-pool slack，没有增加 `total_space_allocated`。同源 grayscale/4:4:4/4:2:2/4:2:0 对照的 geometry-derived logical row workspace 分别为 15,360 / 46,080 / 34,560 / 65,280 B，对应 pre-realize pool growth 15,415 / 46,245 / 34,835 / 65,555 B。尤其 4:2:2→4:2:0 的 `alloc_sarray` 数量同为五个，而 pool growth精确增加30,720 B；这正是 fancy h2v2 令 main controller从8个 row groups扩为10个后的垂直 context-row 成本。

`Evidence/Experiments/IndependentProgressiveJPEGAllocationGeometry/v1/profile.json` 与 `Tools/Quality/capture_libjpeg_progressive_allocation_geometry.py` 将该模型扩到 12 个宽度边界 × 4 个 sampling模式 = 48 个 source-generated progressive JPEG。1/4/5 命中 h2v2 `downsampled_width > 2` 分支，63/64/65 命中 `alloc_sarray` 的 64-byte row-alignment 边界，1919/1920/1921 与8191/8192/8193覆盖常见和更宽媒体。48/48 case 的 model-derived `alloc_sarray` request shape逐项等于 probe；按 pinned `jmemmgr.c` 的32-byte SIMD alignment、`2*ALIGN_SIZE` sample-row alignment、large-pool header/alignment overhead与 `max_alloc_chunk` chunking重建后，pre-realize pool growth 48/48 精确相等，且所有 non-`alloc_sarray` pre-realize pool growth均为0。再把同一 allocator-source model应用到 full coefficient `JBLOCK` arrays，`post-header pool + row-array growth + coefficient-array growth` 对 `jpeg_start_decompress` 返回后的 `total_space_allocated` 也是48/48逐字节相等。width=4 的4:2:0不需要 context rows，而 width=5开始需要，该离散边界由实验直接命中。

`Tools/Quality/validate_libjpeg_progressive_allocation_heldout.py` 再将同一公式应用于原有 5 个 retained suspension cases，而不使用 geometry matrix 输入做参数拟合。23×13 fixture 与四张 1920-wide 真实照片的 `alloc_sarray` shape、row/coefficient allocator growth以及 start-decompress pool 5/5 全部精确。因此旧的“尚无 geometry-derived estimator”结论已经失效：对 pinned 3.2.0、当前 arm64 SIMD、8-bit full-scale grayscale/4:4:4/4:2:2/4:2:0 研究域，geometry-dependent variable allocation term 已有 source-derived、edge-matrix 与 held-out 三层证据。随后 ImageCraft 自己的 narrow progressive JFIF 4:2:0 backend 已经把这条路线推进到 package-owned authority：不再复制 private `jmemmgr` pool，而是用 source-derived `JPEGIndependentProgressive420StatePlan` 直接拥有 coefficient/control/reconstruction arena。`max_memory_to_use` 仍不能冒充总内存限制，但“ImageCraft 尚无自有 allocator/control-state 边界”这一旧结论对该窄域已经失效。

## 独立渐进 JPEG 4:2:0 incremental-session 机制证据

`Evidence/Experiments/IndependentProgressiveJPEG420Session/v1/profile.json` 到 `v17/profile.json` 形成只增不改的机制历史：v1 是最初 fixed arena，v2 拆 pre-frame / rollback 生命周期，v3 保留 whole-marker syntax-bound 阶段，v4 改为 semantic-unit streaming，v5 将 `.finalOnly` 的整张 RGB 从 scan 间常驻状态移出，v6 将 row strips / IDCT workspace / smoothing block 拆成短生命周期 `RenderArena`，v7 把 raw DQT source slots 从 persistent `StateArena` 中移出并在第一 SOS 后释放，v8 将 MCU syntax padding 与 persistent coefficient ownership 分开，v9 再把“未来最多8张 Huffman表的 admission authority”与“当前实际存在的 DHT payload”分离，v10 把 validated EOI 之后的 `.complete` 收窄成只持有 transferable RGB 的 final-ready value state，v11 把 SOF2 前 DQT/DHT 从 fixed table arena 改成按 present slot 拥有，v12 再让 pre-SOF DQT payload 在 SOF2 **转移所有权**到 dynamic frame-q store，而不是复制进新的 fixed four-slot arena；v13 则把三张已经绑定到 component 的 quantization table 从跨 scan 的 UInt16 表示收窄为 UInt8，只在 render 时用一张 128 B UInt16 scratch 临时宽化给现有 IDCT；v14 进一步把 progression 从192个 Int8 entry收窄为 **96 B four-bit state**：qualified domain只有 unseen 与 successive-low 0…13 共15态，0xE保留为非法、0xF表示 unseen；v15 再消除 fancy H2V2 跨 iMCU boundary 的 **deferred Y row copy**：先渲染下一 strip chroma，用仍存活的上一 strip `yStrip[15]` + previous Cb/Cr row7 + current chroma row0重建 boundary，再允许新 Y 覆盖 yStrip，因此只保留真正同时存活的 previous chroma；v16 继续删除两条 full-width reconstructed Cb/Cr staging row，把 centered H2V2/box reconstruction 值直接送入既有 integer YCbCr→RGB conversion，同时将 progression authority 收紧为 canonical monotone：`Ah=0` 只能首次触碰 unseen coefficient，已经达到 progression=0 的 entry 不得被第二个 first scan 重新打开；v17 再拆 final-only EOI phase：完整 progression/EOI/trailing-byte 验证后先释放 transport backing，用 live coefficients + **tight Y/Cb/Cr sample payload + 384 B IDCT/quant scratch** materialize最终空间样本，helper返回前释放 coefficient/Huffman/control state，随后才分配 RGB并从 sample planes做 fused reconstruction，最终 sample payload也释放，因此 final-ready仍只持有RGB。报告从不原地覆盖历史。`Sources/ImageCraftEvidence/IndependentProgressive420SessionEvidence.swift` 当前发布 schema 17，`Tools/Quality/validate_independent_progressive_jpeg_420_session.py` 同时理解 schema 1…17；当前 **v1–v17 每版均 3/3** source-bound case通过。pre-frame maximum authority现在是 **2,432 B = 4×64 B DQT + 8×272 B DHT**，constructor maximum initial authority为 **2,846 B = 414+2,432**，但实际空 session retained只有 **414 B transport**。三条 retained source 在 SOF2 前都只拥有DQT0/DQT1，因此 pre-frame high-water只有 **128 B**。SOF2 后 frame-q maximum authority是 **256 B = 4×64**，同三条 source的实际 high-water仍只有128 B；DQT可以在 SOF2→first SOS之间继续重定义，第一 SOS把 frame selectors选中的值展开到三张 component dequant table后立即释放全部 frame-q ownership，后续 DQT继续 fail closed。v9 的 dynamic Huffman规则保持不变：当前 slot只保留 **16 code-length counts + 当前 N symbols**，而8×(16+256)=**2,176 B** 只作为未来最坏 admission authority。6-block / **768 B** rollback coefficients仍只在一个 MCU transaction内暂存。

entropy transaction 的 authority 也经过一次主动反证。v3 草案曾写成412 B，因为把每个 AC symbol都按“最长16-bit Huffman + 最多10 magnitude bits”计费；审计发现 terminal EOBRUN 可以再带最多14个 run bits。当前上界逐 scan mode显式组成：interleaved DC-first = `6*(16+11)` = **162 bit**；AC-refine 保守取 `63*16 + 63 + 14` = **1,085 bit**；AC-first 的 bit-maximizing terminal form是62个新非零系数各 `16+10` bit，再加一个 EOBRUN `16+14` bit，共 **1,642 bit**，比填满63个系数还多4 bit。向上取整到 entropy bytes、最坏每个 byte 都 `FF 00` stuffing翻倍、再加2-byte restart marker，得到 **414 B**。因此 v4 之后 transport 是 `max(273,414)=414 B`。v11 起 pre-frame maximum table authority 是2,432 B，所以 constructor 的 maximum initial authority 是 **2,846 B = 414+2,432**；但 actual empty-session retained 只有 **414 B transport**。这一区别很重要：576×576 retained source 确实观察到414 B occupancy，但 corpus命中只是回归 witness，域上界来自语法/decoder guard，而不是反过来用样本拟合常数。

真正的 suspension falsifier仍在 MCU transaction。每次 MCU 开始前，session 保存 entropy current-byte/bit count、DC predictors、EOBRUN、restart index 与最多6个**实际图像** coefficient blocks；Huffman code、`FF 00` stuffed byte、restart marker 或 AC refinement 在 chunk末尾中断时，整个 MCU回滚，只有完整 MCU提交后才回收 raw prefix。v8 明确反证了“4:2:0 interleaved MCU padding 也必须跨 scans 常驻”：23×13 source 的 Y 图像只有 **3×2 actual blocks**，但 MCU syntax 是 **4×2 padded blocks**。single-component AC scans、renderer 与 smoothing 从来只访问 actual geometry；interleaved DC-first 的 dummy Y blocks仍完整 Huffman decode并更新 Y predictor，而 DC-refine dummy block无条件只消费1 bit，因此这些 dummy coefficients没有跨 scan语义。streaming在边缘 MCU只 snapshot真实 blocks，并复用现有6-block rollback arena未占用的尾部作为一个 **128 B** dummy block；one-shot decode用同尺寸 temporary block，均不扩大768 B operation scratch。当前三条 source-bound case仍是：23×13 fixture 用 **787个 single-byte append** 穿过全部边界并逐 scan产生1…10；576×576 q95 source 最大 scan **132,270 B**，最大 observed transport **414 B**；64×64 q90 restart source 含 **342个 RST marker**，每个都切在 `0xFF | Dn` 之间。三例 final RGB SHA继续与 complete-input decoder逐字节相等。额外 hostile gates证明：普通/restart marker 前超过两个最大 marker segment 的合法 `0xFF` fill仍可持续回收；65,537 B maximum COM 不再整段驻留；近最大单 DQT/DHT segment分别按65 B/≤273 B semantic unit流式提交；metadata ceiling-1 可仅凭大 COM 的 marker/length header在 payload进入 window前拒绝，而 exact boundary保持同像素。非标准 `FF FF ... 00` entropy stuffing则 complete/incremental都 fail closed。成对 DQT gate继续锁住**第一 SOS**这一语义释放边界；v12额外用byte-prefix177直接命中 SOF2 后、首个DHT/SOS前的状态，证明 retained恰好是 **2,398 B = 414 transport + 1,856 persistent base + 128 transferred DQT payload**，pre-frame current已经归零，frame-q current/high-water都是128 B。

preview/coexistence falsifier继续保留。早期 `Data` COW实现让10次 preview出现5个 backing地址；当前所有 preview原位复用一个 session-owned RGB backing。v5证明 `.finalOnly` 不应让整张 RGB 跨 scans 常驻；v6又证明 renderer rows + 256 B IDCT workspace + 128 B smoothing block不应常驻，而应只进入 render phase。v8 已将 tiny 的 Y coefficient plane 从 padded 8 blocks / 1,024 B 收窄为 actual 6 blocks / **768 B**。v9 又反证了 fixed Huffman capacity：最大 persistent authority另加 **2,176 B** Huffman上界，但 decoder-active `retainedBetweenCalls` 只收费当前 DHT payload。v13 再把 post-latch quantization 从384 B UInt16收窄为 **192 B component quantization UInt8**；DQT precision=0 的支持域保证 bound quantizer 始终在1…255，entropy阶段完全不读取这些表，因此 UInt16 只属于 render representation。`RenderArena` 增加一张 **128 B UInt16[64]** widening scratch，shared IDCT primitive保持原类型合同不变；v13 因而 persistent -192 B、render scratch +128 B，render-dominated operation peak净降64 B。v14 再审 progression authority：scan guard将 successive-low/high限制在0…13，所以每个 coefficient 的跨-scan progression只有 unseen + 0…13 共15态；StateArena现在用两个4-bit entry/byte，**192 B Int8 progression→96 B packed progression**，并由 package-only codec gate逐态 round-trip unseen/0…13、拒绝14、reserved nibble 0xE和越界 nibble。于是当前 post-latch base fixed state进一步收窄为 **288 B = 192 B quantization + 96 B progression**，render scratch不变。v10 再把时间边界推进到 EOI：EOI 先在 live decoder state 上被消费，progression authority先被完整验证；只有当前 transport window 已确认无尾随 byte 后，final-ready compaction 才执行。every-scan cadence 直接保留第10次 preview 的现有 backing；final-only cadence 在这里做唯一一次 final raster，但故意不设置 preview generation，因此 `withCurrentPreview` 仍 fail closed。随后 transport、coefficients、frame、DQT/DHT/control state全部释放，`finish()` 只转交已经存在的 RGB 并 terminalize。为了防止“释放=历史证据消失”，compaction 前还捕获 final DHT payload，并保留 DHT high-water：tiny final/high-water **90/95 B**、noise **98/169 B**、restart **89/135 B**，而 final-ready current DHT统一为0。于是 v15 final-ready retained仍与 RGB byte count精确相等：tiny **897 B**、576×576 **995,328 B**、restart64 **12,288 B**；maximum retained authority仍分别为 **5,055 / 998,206 / 15,166 B**，因为 v15 没有改变任何跨调用持有状态；operation peak则分别降为 **7,871 / 2,010,174 / 30,270 B**。v11/v12只消除了早期 max-capacity假常驻和SOF2 DQT duplicate coexistence；schema12 validator显式改变的是SOF transition公式——v7…v11历史仍额外加frame-q项，v12起由于pointer ownership transfer只取 `initial maximum authority + persistent maximum state`。v13通过缩窄 bound quantization 的 persistent representation降低 decoder-active authority，并因 render-time widening只回补128 B让三个 render-dominated peak净降64 B；v14 的 progression packing不新增任何 scratch，因此 maximum retained 与三个 operation peak都在 v13 基础上再精确下降 **96 B**。v15 只重排 render 顺序：row state 必须精确满足 **18×yRowStride + 18×chromaRowStride**，不再有第19个 Y row；因此 tiny/restart render peak再各降64 B，576×576按其576-byte Y stride再降576 B。v16 进一步证明两条 full-width reconstructed Cb/Cr row只是 staging：centered H2V2/box reconstruction 的每个 chroma sample现在在同一 column直接进入既有 integer YCbCr→RGB conversion，unit test将 fused path 与历史 `reconstruct row + writePlanarRGBRow` 逐字节对照。row state 因而收窄为 **16×yRowStride + 18×chromaRowStride**，相对v15精确再释放 `2×yRowStride`：tiny/restart各128 B、576×576为1,152 B；maximum retained authority不变，operation peak分别变为 **7,743 / 2,009,022 / 30,142 B**。多 iMCU noise fixture继续用 v14 固定 RGB SHA256 `5b1738e18c84104586fbe59f37348d8bf1fd9af2cd7036874f156625549bafbb` 作跨版本 oracle，避免 complete/incremental共用 renderer 时出现“同错同过”；schema16 validator还直接读取对应v15 report，要求 persistent/max-retained不变、render scratch差额恰好等于两条Y-width row且 final RGB SHA一致。v17 不再继续缩 preview RenderArena，而是改变 `.finalOnly` 最终阶段的真实 coexistence：tight sample payload按 `width*height + 2*chromaWidth*chromaHeight` 组成，materialization scratch精确 **384 B = 64×Int32 IDCT + 64×UInt16 quant widening**，transport在该分配前已释放，RGB只在 materialize helper返回并释放全部 decoder state后分配。于是 final-only operation peak取 `max(transition, entropy rollback, Huffman mutation, persistent+samples+384, samples+RGB)`；576×576 samples为 **497,664 B**，peak从v16 **2,009,022→1,495,840 B**，restart64 samples为 **6,144 B**，peak **30,142→21,280 B**，而 tiny every-scan control仍为 **7,743 B**。schema17直接读取v16 report，要求 persistent/max-retained/final RGB不变、final-only peak严格下降而 every-scan peak不变。trailing-byte gate仍保持：同一 transport window内的尾随 byte在compaction前失败；尚未复制进window的已接受 suffix会在append外层下一轮看到 `.complete` 后 terminalize并回收已经生成的 RGB。

source semantics 同样从弱提示升级成 authority。progressive JFIF 4:2:0 原先只匹配五字节 `JFIF\0`，并默认忽略 APP14/Adobe；实测 truncated APP0、晚于DQT出现的完整 JFIF、Adobe transform=0(RGB)/2(YCCK)都曾被错误接受。现在共享 `JPEGIndependentJFIFColorAuthority` 按 JFIF固定字段验证 version/units/nonzero density/thumbnail extent，并要求 JFIF APP0是SOI后的第一个 marker；Adobe APP14只在 transform=1 与 JFIF YCbCr一致时接受。embedded ICC、malformed/late JFIF、Adobe RGB/YCCK均在 raster前 fail closed。v16又把 progressive scan progression 从“值域合法”提升成 canonical monotone authority：`Ah=0` 只允许首次建立 unseen coefficient；已经见过的 entry 必须通过 refinement继续收窄，而且 progression=0 是不可重开的 terminal precision。一个由 pinned cjpeg 3.2.0 生成的4-scan Ah=0/Al=0 control会正常完成；复制第一张完整DC scan后，libjpeg-turbo出于兼容仍可产生同像素，但ImageCraft one-shot/incremental都在 progression admission fail closed。这些门已复用于 baseline JFIF 4:2:0/4:4:4 parser；baseline 4:2:0也有 end-to-end JFIF/Adobe回归。资源/lifecycle失败路径仍独立约束：pre-acceptance encoded-limit拒绝保持 retryable；frame admission少1 B、cancel、incomplete `finish()`、EOI trailing byte等 post-acceptance失败都 terminalize并清零 ledger。`JPEGIndependentProgressive420SessionQualificationTests` 当前 **5/5** 通过。该证据仍只支持8-bit progressive JFIF 4:2:0 raw RGB8 package authority，不支持 embedded ICC、其他 sampling、public `DecodedImage` 表示、跨 allocator物理 RSS或感知质量主张。

## 渐进 JPEG 跨 backend sampling / reconstruction 压力

`Evidence/Experiments/ProgressiveJPEGCrossBackendSampling/v1/profile.json` 与 `Tools/Quality/capture_progressive_jpeg_cross_backend_sampling.py` 先用 pinned libjpeg-turbo 将一张 retained 1920×1285 真实 progressive JPEG 解为确定的 8-bit RGB，再以相同 quality=75、optimized Huffman、progressive mode分别重编码 grayscale、4:4:4、4:2:2、4:2:0；capture独立解析 SOF sampling factors 与 scan count，构建当前 source 的 Release `ImageCraftEvidence`，并把 full-size tight opaque sRGB RGBA 与 one-shot libjpeg raw RGB逐通道比较。该实验不设置事后 pixel tolerance，只记录 max code、MAE、RMSE/PSNR、exact-pixel fraction 与差异直方图。

当前 source-bound结果呈严格 sampling pressure顺序：grayscale max/MAE = 1/0.062 codes，4:4:4 = 3/0.110，4:2:2 = 5/0.340，而4:2:0跳到51/0.556；对应 PSNR约60.20/57.03/51.09/44.52 dB。另一个同源 API 正交实验显示关闭 fancy upsampling会把真实4:2:0 MAE从约0.56恶化到1.22，而切换 accurate/float IDCT只产生约0.002-code MAE量级变化且不消除大尾部。因而当前 sparse large delta主要被定位到 h2v2、尤其新增的垂直2× chroma reconstruction，而不是泛化的 IDCT 精度问题。该定位不裁定 ImageIO 或 libjpeg 哪一方感知质量更优，也不把51/55 code尾部升级成产品容差；下一步应以独立 YCbCr/chroma-siting/filter oracle 或原始图像质量参考继续区分 reconstruction policy。

该 reconstruction gap 现在已经进一步收窄到 **iMCU 边界的垂直 context topology**，而不是泛化的“Apple filter 不同”。`JPEGFrameSamplingGeometry` 由 ImageCraft 自己从 SOF0/SOF2 提取 baseline/progressive、component sampling、最大采样因子、output-iMCU row height 与内部 iMCU 边界数；它不把 component ID 或 sampling 猜成颜色空间。1920×1285 的三 component 4:2:0/4:4:0 都有16-row output iMCU、81个 iMCU row、80个内部边界，也就是160个 boundary-adjacent output rows。progressive resource estimator 已改为消费同一 immutable frame geometry，再叠加 full-buffer coefficient/workspace 语义，而不是再次解析一套 sampling facts。

`Evidence/Experiments/JPEGIMCUChromaContext/v1/profile.json` 与 `Tools/Quality/capture_jpeg_imcu_chroma_context.py` 用 raw-component system-identification 把 context topology 与颜色 rounding 正交分离。生成器通过 libjpeg `raw_data_in` 直接建立64×64 4:4:0/4:2:0 JPEG：Y恒128、Cr恒128、Cb只按低分辨率行变化；baseline/progressive分别生成，因此绕过 RGB→YCbCr 和 encoder downsampling。随后 `raw_data_out` 重新观测真正 post-IDCT Cb，模型只从该 plane 出发。两个候选共享同一 3/4-current + 1/4-adjacent 垂直核：global-context允许跨16-output-row iMCU 边界访问相邻 chroma row，iMCU-clamped则仅在 phase15/0 把相邻行钳回当前 iMCU。每个 backend各自在**非边界行**拟合一次 blue-versus-reconstructed-Cb affine mapping；这些行上两个 context 模型完全相同，因此 color conversion/rounding不会参与模型选择。冻结该 mapping 后只在未参与拟合的 phase0/15 行判别：pinned libjpeg 必须偏好 global-context，ImageCraft/ImageIO 必须偏好 iMCU-clamped；四个 baseline/progressive × 4:4:0/4:2:0 cell 任一反向都使 capture失败。该声明是 output-equivalence mechanism，不声称知道 Apple 内部实现。

同一机制在 retained 1920×1285 progressive 4:2:0 真实照片上有独立 phase-localization：ImageIO↔libjpeg 总体 MAE约0.556 code，但 `y mod 16` 为0/15的边界行 MAE约1.70，内部约0.39；>4-code pixel fraction约23.3% vs 2.86%，>8-code约11.1% vs 0.079%，top-200最大 residual 中约149个落在 phase0/15。最差55-code residual 位于 phase15。该真实照片检查不拟合任何 filter，只检验 source-generated mechanism预言的相位集中性，因此不能反向把这些数值写成生产容差。

后续 source-truth 反例已经否决“global/libjpeg 在 chroma reconstruction 上普遍更高质量”。`Evidence/Experiments/JPEGChromaGroundTruthPolicy/v2/profile.json` 保留原12个连续 ramp/zigzag control，又新增4个 `step-imcu` cell：full-resolution Cb 在 output row 32 从80跳到176，2:1 box subsample 仍精确得到连续的80/176低分辨率平台。12个 smooth cell 继续要求 global centered model / libjpeg backend 胜；4个 step cell 则预注册要求 iMCU-clamped model / ImageCraft-ImageIO 胜。16/16 source-bound capture 全过。以 progressive 4:2:0 为例，smooth cell 中 libjpeg boundary RMSE约0.30、ImageIO约1.8，而 step cell 反转为 libjpeg约24.25、ImageIO约0。该 winner reversal 的含义是 reconstruction policy 依赖 source structure，不是“Apple 总是更好”或“libjpeg 总是更好”。

`Evidence/Experiments/JPEGChromaAdaptivePolicy/v3/profile.json` 随后把一个固定、事前注册的 1-D rule 放到24个 held-out real-JPEG cell：仅当低分辨率 interval gradient 严格大于两侧 immediate gradient 最大值的2倍时用 nearest/current，否则保留3/4–1/4 centered interpolation。quadratic/kink control 必须逐row等同 global；off-iMCU step、8-code small step 与 ramp+step 必须改善 all-row source-truth error；single-row impulse 只允许不退化。真实 quality-100 JPEG encode→libjpeg raw post-IDCT Cb→三种 reconstruction 的24/24 cell 全过，且 package-only `JPEGAdaptiveChromaReconstruction.writeH1V2` 已逐row复现 pinned v3 Python oracle；production JPEG path 没有接入该 helper。

v3 通过并不意味着该 rule 可生产化。后续主动 falsification 构造了 phase-shifted two-row stripe：full-resolution truth 仅两行从80升到176，但精确2:1 box subsample 与另一份真实128平台 source 都得到同一 `[80,128,128,80]` low-resolution chroma。对于 thin stripe，centered reconstruction 的 RMSE 低于 nearest；对于 true plateau，nearest 则精确而 centered 有误差。同一 subsampled chroma 对应相反的 source-truth 最优策略，因而**任何仅观察 subsampled chroma 的确定性规则都不可能对任意 full-resolution source truth 保证普遍不退化**。这也是 `JPEGAdaptiveChromaReconstructionTests.testPhaseShiftedTwoRowStripeFalsifiesV3Rule` 被保留为负面门的原因。更大的2-D搜索进一步确认：naive separable、2-line、3-line与5-line axis-only coherence 都能找到 curved/thin-feature counterexample；最新5-line + two-level normal-persistence候选在300-case design set曾达到0 RMSE/max退化，但在独立832-case held-out corpus仍出现1个RMSE和5个max-error退化，因此没有进入真实JPEG 2-D capture或production kernel。下一质量 frontier 必须明确引入额外信息/先验（例如 full-resolution luma guidance 或 perceptual/natural-image objective），而不能继续把更大的 chroma-only neighborhood 包装成 universal source-fidelity guarantee。

`Evidence/Experiments/JPEGImageIOAPIPath/v1/profile.json` 与 `Tools/Quality/capture_jpeg_imageio_api_path.py` 另做一个 fail-closed negative-result：同一 raw-component 4:2:0 signal 分别生成 baseline/progressive JPEG，再比较 `CGImageSourceCreateImageAtIndex`、full-size `CGImageSourceCreateThumbnailAtIndex`，以及两者的 `kCGImageSourceShouldAllowFloat` false/true；四条路径统一渲染成 top-to-bottom sRGB RGBA8，正式判据是每个 coding mode 内 **逐字节相同**，不是相似度。如果该 evidence继续成立，就排除“换 direct/thumbnail 或打开 allow-float 即可修复 iMCU boundary reconstruction”的短路方案，但不外推到其他 OS、decode scale或未测 ImageIO option。

jpegli source audit 提供了一个有用的反事实边界而非现成结论。锁定的 `google/jpegli` source把2× upsample保留为3/4–1/4 triangle，但 dequantization→IDCT→upsample→BT.601 conversion在 float 域继续，最终输出才量化。把**已经量化的 libjpeg raw post-IDCT planes**仅改成 float triangle/float color、延迟到最终一次量化，反而使该 retained case 到 ImageIO 的 MAE从约0.557增至约0.648；因此“只去掉 post-IDCT reconstruction 的整数 rounding”已被否决。更上游的 float chroma IDCT原型也显示：round/clamp回8-bit时与 libjpeg raw chroma最大只差1 code，而保留 IDCT overshoot 会制造另一类大尾部；这说明未来 independent JPEG quality seam必须把 IDCT sample-domain clipping/precision 与跨-iMCU chroma context分开建模，不能用一个笼统的‘float pipeline更好’替代机制证据。

## 渐进 JPEG pipeline profile 与模拟证据

`Evidence/Experiments/progressive-jpeg-pipeline-simulation-2026-08-04.json` 绑定 clean 提交 `04c8ad2984ef94ad31d4bd386e2d06bdddf58304`、Git tree、239 文件 source identity、两份 7-iteration Release profile 与可从 profile 逐字重建的 8-case 离散事件模拟。

`Tools/Performance/validate_progressive_pipeline_experiment.py` 会重算 profile 的每 chunk 统计与 generation 边界，验证最终像素一致性，从 profile 重建完整 simulation，并在 Git 历史可用时逐文件绑定 measured commit。`Tools/Performance/test_progressive_pipeline_simulation.py` 另用合成输入固定精确到达、帧内 latest-wins、network-dominant 无排队和 in-flight 取消语义。

该证据把实测 ImageIO/MainActor 成本与模拟网络/帧时钟严格分开。它支持：decode-pressure 和 network-dominant 需要不同宿主策略；取消发布栅栏应先于等待 `session.cancel()`；presentation policy 属于宿主。它不支持 URLSession、Core Animation、GPU 呈现、真机能耗或固定 60 Hz 策略的生产最优性。

## ImageIO direct path 与 ImageCraft raster path 对照

`scripts/capture-raster-comparison-evidence.sh` 对同一渐进 JPEG、同一 512×512 fit 目标和同一 preserve-source 色彩策略执行两条公开语义路径：直接使用增量 `CGImageSource` 创建最终 thumbnail，以及通过 `ImageIOImageDecoder` 的 progressive preparation 再完成 ImageCraft 解码。测量只覆盖最后一个网络分块到最终 raster 可用之间的本地工作，不包含文件读取、网络、缓存、UI 提交或显示。

每次捕获先执行 3 次 warmup，再在 Apple-first 与 ImageCraft-first 之间交替 25 次，报告保存全部原始样本、运行时指纹、输入字节数/SHA-256、输出尺寸与规范化 sRGB RGB 像素摘要。`Tools/Performance/validate_raster_comparison_evidence.py` 会从原始样本重算 median/p95，验证顺序平衡、输入身份、样本数量、尺寸稳定性和两条路径的逐像素等价。

该工具是证据采集入口，不是稳定性能 baseline。只有在 clean source identity、固定环境和独立重复捕获绑定后，结果才可进入版本化实验记录；单次工作树运行不得升级为跨 OS、跨设备或全局性能声明。

```sh
scripts/capture-raster-comparison-evidence.sh \
  .artifacts/performance/raster-path-comparison/report.json 25
```


## 目标特定派生光栅原型

`ImageCraftEvidence --derived-raster-prototype INPUT --iterations N` 是普通图片机制探针。它对固定 W2 目标先以 `fit` 和 sRGB 转换解码原 JPEG，再生成三种精确像素候选：

- 通过公开 ImageCraft ImageIO encoder 生成 PNG；
- 将规范化 RGB 直接用 LZFSE 压缩；
- 对规范化 RGB 逐行选择可逆 `None`/`Sub`/`Up` 预测器，再用 LZFSE 压缩。

每种候选都会恢复成 `CGImage`，并通过规范化 RGB SHA-256 与直接原图解码比较。Schema 5 报告保留全部时延样本、字节数、格式摘要、创建成本、精确像素结果，以及对已缓存 `CGImage` 执行与 ComparativeLab 相同 RGBA 绘制的 `cachedImageMaterialization` 样本。`Tools/Performance/validate_derived_raster_prototype.py` 会重算统计、字节总量、输入身份、固定目标、输出边界、RGB 字节数和逐像素等价；`scripts/capture-derived-raster-prototype.sh` 默认捕获四张保留真实照片，也接受额外 JPEG。

当前本地七图探索只支持机制结论：目标特定无损工件能够保持精确像素，并可能显著减少重复原图解码。它同时否定单一全局格式：raw LZFSE 最快，但真实照片上可能明显更大；PNG 更小但更慢；自适应过滤 LZFSE 通常非劣，但当前 Swift 原型创建成本高。报告不建立公共文件格式、生产缓存策略、跨设备性能或 Fovea 默认路径。

确定性最近整数 aspect-fit 候选另以 42 个独立进程报告进行 A/B：7 张图、3 个目标、每侧每图 3 个 block、每报告每目标 15 个样本。候选使 6/21 个输出尺寸发生一像素变化，但冷态解码中位比基线慢约 1.4%，缓存图像 materialization 中位慢约 2.1%；9 个目标退化超过 5%，仅 6 个改善超过 5%，方向对图片和目标不稳定。该候选已撤销，ImageIO codec implementation version 保持 4；Schema 5 的 materialization 测量保留。聚合工件为 `.artifacts/performance/geometry-v4-v5-ab/aggregate.json`，SHA-256 为 `14a90aa9a21a7dcd4c8e460e68cfb7eeac67736ddb3475070b28bbd2c2ed6e8f`，仅属于脏工作树方向性证据。
