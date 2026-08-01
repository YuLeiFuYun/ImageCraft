# 独立编解码 Oracle

## 目标

ImageIO 自身的 round-trip 只能证明同一框架内部自洽，不能证明生成的容器能被独立实现接受，也不能发现 ImageIO 解码和编码共享的系统性偏差。本门禁引入两个不参与 ImageCraft 生产实现的外部 oracle：

- libjpeg-turbo 的 `cjpeg` 与 `djpeg`；
- libpng simplified API。

这些依赖只存在于验证脚本和工具目录，不进入 `ImageCraftCore`、`ImageCraftImageIO` 或任何发布产品的链接依赖。

## 差分矩阵

固定输入仍为 `imagecraft-pattern-v1`：96×64、sRGB、无 alpha。

PNG 路径：

```text
source PPM
  -> ImageIO PNG encoder
  -> ImageIO decoder -> PPM
  -> libpng decoder  -> PPM
```

两个输出都必须与源 RGB 字节完全相同。

JPEG 路径对 quality 25、50、75、90 分别执行：

```text
source PPM
  -> ImageIO encoder ------> ImageIO decoder
  |                         libjpeg-turbo decoder
  |
  -> libjpeg-turbo encoder -> ImageIO decoder
                            libjpeg-turbo decoder
```

因此既验证 ImageIO 输出能否被独立 decoder 接受，也验证 ImageIO decoder 能否消费独立 encoder 的输出。

## 为什么不比较逐字节相等

JPEG quality 不是跨实现统一的量化表身份。即使 quality 数值相同，ImageIO 和 libjpeg-turbo 也可以合法选择不同量化表、Huffman 表或其他编码决策。字节完全相同既不现实，也不是互操作正确性的必要条件。

同一 JPEG 经 ImageIO 与 libjpeg-turbo 解码后也不保证逐像素相同。当前 4:2:0 corpus 中观察到最大单通道差约为 100，主要与色度上采样和 IDCT 舍入路径有关。因此门禁采用：

- 尺寸完全一致；
- PNG 精确像素一致；
- JPEG 两种 decoder 都能成功；
- 每种 decoder 相对源图的 PSNR 下界为 14 dB；
- 两种 decoder 对同一 JPEG 的交叉 PSNR 下界为 27 dB；
- quality 增加时 PSNR 不下降；
- q90 相对 q25 至少提升 2.5 dB；
- quality 增加时当前固定 corpus 的编码字节数严格增加。

这些阈值是固定 corpus 的回归约束，不是通用图像质量标准。

## 运行

需要 Homebrew 安装的 libjpeg-turbo 与 libpng：

```sh
brew install jpeg-turbo libpng
scripts/verify-independent-oracles.sh
```

与已保存基线精确比较：

```sh
scripts/verify-independent-oracles.sh \
  Evidence/Oracles/macos-27.0-26A5388g-arm64-imageio2847-jpegturbo3.2.0-libpng1.6.58.json
```

脚本会临时编译 `Tools/Oracle/png_decode.c`，调用 Release 版 `ImageCraftEvidence` 生成 ImageIO 产物和执行 ImageIO 解码，再由 `Tools/Oracle/analyze_oracle.py` 计算机器可读差分报告。

## 首份基线

当前基线绑定：

- macOS 27.0 build 26A5388g；
- arm64；
- ImageIO 2847 / 3.3.0；
- Core Graphics 2047；
- ImageCraft encoder `dev.imagecraft.imageio.encoder#impl=2#contract=1`；
- libjpeg-turbo 3.2.0 build 20260630；
- libpng 1.6.58；
- Python 3.14.6 分析器运行时。

PNG 经两个 decoder 均精确恢复。JPEG 两个 encoder 的四个 quality 档位均通过完整交叉矩阵。

## 未证明事项

当前 oracle 仍不证明：

- 任意真实照片、极端尺寸、灰度、CMYK、ICC、HDR 或 alpha corpus；
- ImageIO quality 与 libjpeg-turbo quality 数值具有相同视觉含义；
- macOS 与 iOS 的输出或解码像素相同；
- PSNR 足以描述感知质量；
- JPEG 最大局部误差受当前阈值约束；
- 外部工具未来版本不会改变结果。

后续应增加真实 corpus、边界 corpus、ICC/方向样本、SSIM 或其他感知指标，以及 iOS 真机矩阵。
