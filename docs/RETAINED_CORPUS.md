# Retained Corpus v1

## 目的

运行时临时生成的 fixture 只能证明测试代码与当前框架同时工作，不能证明同一输入在未来仍得到相同分类。Retained corpus 将输入位流本身纳入版本控制，并为每个样本记录：

- 稳定 case ID；
- 文件名、字节数和 SHA-256；
- 生成器及独立工具版本；
- 预期格式、方向归一化尺寸、帧数和颜色配置分类；
- 预期成功、资源边界失败或结构损坏失败；
- JPEG SOF 类型和分量数等容器结构。

样本位于：

```text
Tests/ImageCraftImageIOTests/Resources/Corpus/v1
```

SwiftPM 仅把这些文件复制到测试 bundle。生产 library 和 executable 不携带 corpus。

## v1 样本

v1 包含 14 个小型确定性样本：

- PNG：带透明度的显式 sRGB、无标签灰度、128 字节 tEXt 边界、截断 IEND；
- JPEG：baseline 4:2:0、progressive 4:2:0、EXIF orientation 6、灰度、四分量 CMYK、128 字节 APP3 边界、缺失 EOI；
- GIF：静态单帧、双帧、缺失 trailer。

所有像素均由仓库内生成器产生，不含第三方摄影作品或外部媒体版权。JPEG 位流由 libjpeg-turbo 3.2.0 生成；CMYK 样本通过同一库的 C API 生成；PNG 和 GIF 由仓库内确定性构造器生成。

## 门禁

日常门禁：

```sh
scripts/verify-retained-corpus.sh
```

它验证 manifest、文件集合、字节数和 SHA-256，然后运行 `RetainedCorpusTests`。测试编号固定为：

```text
CORPUS_V1_001  manifest、文件集合与哈希
CORPUS_V1_002  有效样本 probe/decode
CORPUS_V1_003  截断样本稳定失败
CORPUS_V1_004  metadata 精确观察边界
CORPUS_V1_005  双帧 GIF 的策略边界
CORPUS_V1_006  JPEG SOF 与分量结构
```

生成可复现性门禁：

```sh
scripts/verify-retained-corpus-reproducibility.sh
```

该脚本使用当前 Homebrew `jpeg-turbo` 在临时目录完整重建 corpus，并要求与提交版本逐文件一致。工具升级导致差异时必须生成新 corpus 版本或明确审查后更新，不能静默覆盖 v1。

## Metadata 边界语义

PNG tEXt 和 JPEG APP3 的容器 payload 都精确为 128 字节。但 `ImageProbe.metadataByteCount` 取容器扫描值与 ImageIO 属性序列化估计值的较大者；后者可能随 OS build 改变。因此测试采用：

1. 在宽松预算下获得当前完整 probe；
2. 以观察到的 `metadataByteCount` 作为精确预算，要求成功；
3. 将预算减少 1，要求稳定返回 `metadataLimitExceeded`。

这既保留容器层 128 字节事实，也避免把 ImageIO 私有属性表示大小伪装成跨 OS 常量。

## 当前边界

v1 是受版本管理的结构与边界 corpus，不是完整真实世界图像集合。尚未覆盖：

- 可合法再分发的摄影、扫描和图形设计样本；
- 嵌入式 RGB ICC、分块 JPEG ICC 和冲突色彩声明；
- 作为长期回归资产保留的 16-bit PNG 与 interlaced PNG（T101 已有生成式/正式 conformance corpus，但尚未提升为 v1 retained fixtures）；
- restart marker、算术 JPEG、异常 Huffman/quantization 表；
- 大尺寸、压缩炸弹和 fuzz 最小化样本；
- APNG、复杂 GIF disposal 和 HEIF/AVIF。

这些必须进入后续 corpus 版本，而不是修改 v1 的既有位流与含义。
