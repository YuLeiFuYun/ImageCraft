import Foundation

/// 控制目标像素框采用完整显示还是裁切填充。
public enum ImageContentMode: String, Codable, Hashable, Sendable {
    /// 将完整图像缩放到目标框内部。
    case fit
    /// 填满目标框，并允许居中裁切。
    case fill
}
