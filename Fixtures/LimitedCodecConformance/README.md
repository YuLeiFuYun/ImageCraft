# Limited Codec Conformance Fixture

该外部 SwiftPM fixture 故意只声明一个窄能力集合：PNG、complete-frame、primary-frame、SDR、CoreGraphics，以及 orientation/source-color metadata。

像素实现复用公开的 `ImageIOImageDecoder`，因此它不是第二个独立像素 backend。它的用途是让同一 `ImageCodec` v1 kit 在“合法但缺能力”的 descriptor 上运行，证明有限能力代数、unsupported request、空 progressive capability 与无 prepared/progressive 可选能力都不会被完整 ImageIO descriptor 特化。

fixture 的 `probe` 会主动拒绝非 PNG，即使底层 ImageIO 能处理更多格式；descriptor 因此仍是唯一受支持能力边界。通过本 fixture 不构成新 codec 的发布或性能资格。
