# 当前平台与 SwiftPM 集成契约

## 当前支持契约

机器可读契约位于 `Integration/PlatformSupport.json`。当前声明：

- Swift tools 6.4；
- macOS 12.0 及以上；
- iOS 15.0 及以上；
- 两个公开库产品：`ImageCraftCore`、`ImageCraftImageIO`；
- `ImageCraftEvidence` 是证据可执行产品，不属于宿主运行时依赖；
- 根包没有第三方依赖。

`scripts/verify-integration-contract.sh` 使用 `swift package describe --type json` 同时读取根包和外部消费者包，阻止 Package.swift、文档和集成 fixture 静默漂移。

## 平台编译矩阵

`scripts/verify-platform-matrix.sh` 以 Release 配置构建 `ImageCraftImageIO` 及其 `ImageCraftCore` 依赖：

| 构建目标 | 最低部署目标 | 架构含义 |
|---|---:|---|
| generic macOS | macOS 12.0 | arm64 + x86_64 universal |
| generic iOS Simulator | iOS 15.0 | 当前 Xcode 支持的 simulator 架构 |
| generic iOS device | iOS 15.0 | arm64，关闭代码签名 |

脚本会检查编译日志中的 target triple，并用 `lipo` 校验最终 object 的实际架构，不能只依赖 Package.swift 的声明文本。

这些是**编译证据**，不是以下事项的证明：

- iOS 真机功能、峰值内存或能耗；
- 所有 macOS 12 / iOS 15 小版本上的 ImageIO 行为一致；
- Catalyst、tvOS、watchOS 或 visionOS 支持；
- Linux 或 Windows 支持。

`ImageCraftCore` 当前公开 `CGImage`，所以 Linux/Windows 不在支持范围内。

## 外部消费者

`Fixtures/ConsumerSmoke` 是独立 SwiftPM package，通过本地 path dependency 消费 ImageCraft。它只依赖：

- `ImageCraftCore`；
- `ImageCraftImageIO`。

fixture 会实例化公开 descriptor、解码请求、限制、PNG 编码请求和结果类型。因为它不属于根 package，不能访问 package-internal runtime fingerprint、diagnostics、container inspection 或 evidence API。

验证：

```sh
scripts/verify-consumer-package.sh
```

该命令执行：

- macOS host Release SwiftPM build；
- iOS 15 Simulator Release build；
- iOS 15 device Release build，关闭签名。

## 尚未配置的分发设施

公开 Git remote 与 GitHub Hosted `xcode-27` 核心 CI workflow 已配置，并由仓库内工具链门验证 Xcode 27 / Swift 6.4 身份；`main` 当前启用严格 required `core` check。项目仍未发布稳定版本 tag；管理员强制约束、runner 容量、真机和能耗资格必须与普通构建通过分开报告。
