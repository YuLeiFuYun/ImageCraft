# 提取来源证明

- 提取时间：2026-07-28
- 来源仓库：the local Fovea source tree recorded by the source commit and file digests below
- 来源 HEAD：`7768ed083eee9c54ad86b7124a96f73a202d4c65`
- 来源状态：ImageCraft 相关文件在来源工作树中含未提交修改；因此 HEAD 不能单独复原本次提取。
- 提取策略：逐字节复制 `Sources/ImageCraftCore` 与 `Sources/ImageCraftImageIO`；提取后 `diff -qr` 无差异。

## 源文件 SHA-256

```text
479e8a540aa42305f6ab91e451402f09862cc5c92e67811c79b89142401475f8  Sources/ImageCraftCore/ImageCodecContract.swift
1e3c8d9c62e6ac315a6c88a369bd5fb3f2289261724099a081ce16c04debc9f6  Sources/ImageCraftCore/ImageDecodeWorkingSetEstimator.swift
9b3c0ad630367234e43a00a4c05b8fff0d9efc0df5b895662540b5acd74dae60  Sources/ImageCraftCore/ImageTransforming.swift
ef08aac96da1b3d1b0e176edbdf99704a76067680713d08570cfcc2372116753  Sources/ImageCraftCore/ImageTypes.swift
3acb6b038a6c0313f648e08940c4d91837ed11420c3937c06f137c1989b67a50  Sources/ImageCraftCore/TargetGeometry.swift
c8649dc00f9b197475ef7d6faf023417c7e8f8b615dd0e4669f894d8b607e50e  Sources/ImageCraftImageIO/EncodedImageSecurityInspector.swift
7831c4b4a826c2bd83faca657621c020a8865f9c6b9e7d655ac66ebd3a5a3493  Sources/ImageCraftImageIO/ImageIOImageDecoder.swift
```

## 测试迁移边界

迁入独立仓库：codec capability、resource estimate、ImageIO probe/decode、颜色、ICC、orientation、metadata budget、prepared-state 与 malformed-input 测试。

留在 Fovea：`ContentID`、`DecodeKey`、`RenderKey`、`DecodeStage`、pipeline admission、namespace、cache 与 rollout 测试。它们验证宿主集成，不属于 ImageCraft 自身。


## 提取后的收敛

上述哈希只证明初始提取字节来源，不要求独立仓库永久保留所有迁入抽象。后续 API 收敛已删除属于 Fovea/UI 宿主的 target geometry bucket、render-cache admission、transformer，以及没有当前生产交付模型的 progressive generation 和 frame timing 值类型。
