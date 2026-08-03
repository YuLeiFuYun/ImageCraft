# 发布流程

## 当前状态

ImageCraft 已具备公开 Git remote、核心 CI workflow、本地 release-readiness gate 与不可变 pre-1.0 开发标签。尚未发布稳定版本；以下流程不会自动创建 tag 或发布二进制。

## 发布前门禁

从干净工作树执行：

```sh
scripts/verify-release-readiness.sh
```

该入口依次运行：

1. 机器可读兼容性契约；
2. 默认测试、Release 构建、公共 API 和行为 evidence；
3. 独立 SwiftPM 消费者；
4. macOS 12 / iOS 15 Simulator / iOS 15 device 编译矩阵；
5. libjpeg-turbo/libpng 独立 oracle；
6. retained corpus 逐字节重建。

在与性能 baseline 完全匹配的硬件和 OS 上，可额外执行：

```sh
IMAGECRAFT_VERIFY_PERFORMANCE=1 scripts/verify-release-readiness.sh
```

性能门不是共享 runner 的默认要求，因为温控、后台负载和硬件不匹配会产生无意义失败。

## 版本检查

发布提交必须明确回答：

- `API/PublicAPI.json` 是否变化；
- decoder 或 encoder 的像素、颜色、错误、资源语义是否变化；
- `implementationVersion` 或 `contractVersion` 是否需要递增；
- retained corpus、行为 baseline、oracle baseline 是否需要新增版本，而不是覆盖旧证据；
- 最低平台或 Swift tools version 是否变化。

1.0 之前可发布 `0.x` 版本，但破坏性公共 API 变化仍必须在 release note 中逐项列出。1.0 之后遵循 `docs/PUBLIC_API.md` 中的 major-version 规则。

## 稳定版本前的步骤

首次稳定版本发布前执行：

1. 确认主分支保护与 required checks 持续生效；
2. 完成稳定设备上的平台、资源与能耗证据；
3. 审核公共 API、codec identity 与 contract/version 变更；
4. 创建带说明的 annotated tag；
5. 从新 clone 而非现有工作树复跑 consumer smoke；
6. 让 Fovea 固定到明确 tag 或 commit，再运行双仓 current-integration gate。

远端固定为 `YuLeiFuYun/ImageCraft`；tag 名和发布时点仍由独立发布决策确定。
