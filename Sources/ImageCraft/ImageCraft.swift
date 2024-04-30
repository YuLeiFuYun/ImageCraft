//
//  ImageCraft.swift
//  ImageCraft
//
//  Created by 玉垒浮云 on 2024/4/29.
//

import Foundation

enum ImageCraft {
    enum Radius: Identifiable {
        case widthFraction(CGFloat)
        case heightFraction(CGFloat)
        case point(CGFloat)
        
        var id: String {
            switch self {
            case .widthFraction(let value):
                return "widthFraction(\(value))"
            case .heightFraction(let value):
                return "heightFraction(\(value))"
            case .point(let value):
                return "point(\(value))"
            }
        }

        func compute(with size: CGSize) -> CGFloat {
            // 根据枚举值计算实际的圆角大小
            switch self {
            case .point(let point):
                // 直接指定圆角大小
                return point
            case .widthFraction(let widthFraction):
                // 根据容器宽度的百分比计算圆角
                return size.width * widthFraction
            case .heightFraction(let heightFraction):
                // 根据容器高度的百分比计算圆角
                return size.height * heightFraction
            }
        }
    }

    enum ContentMode: String, Identifiable {
        case none // 不进行调整
        case scaleAspectFit // 保持纵横比缩放内容以适应容器大小，内容完整显示
        case scaleAspectFill // 保持纵横比缩放内容填满容器，可能会裁剪内容
        
        var id: String { rawValue }
    }
}
