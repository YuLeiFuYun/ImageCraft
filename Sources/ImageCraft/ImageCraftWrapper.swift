//
//  ImageCraftWrapper.swift
//  ImageCraft
//
//  Created by 玉垒浮云 on 2024/4/29.
//

import UIKit

// 定义一个泛型结构体 ImageCraftWrapper，它将作为一个通用包装器，能够包装任何类型。
public struct ImageCraftWrapper<Base> {
    let base: Base // 保存被包装的原始值
    init(_ base: Base) {
        self.base = base // 初始化时将原始值保存到属性中
    }
}

// 定义一个空的协议 ImageCraftCompatible，用于标记类类型（引用类型）的对象可以使用 ImageCraftWrapper 进行扩展。
public protocol ImageCraftCompatible: AnyObject { }

// 定义一个空的协议 ImageCraftCompatibleValue，用于标记值类型的对象可以使用 ImageCraftWrapper 进行扩展。
public protocol ImageCraftCompatibleValue { }

// 为 ImageCraftCompatible 协议扩展一个计算属性 ic，这使得任何遵循 ImageCraftCompatible 的类型（即类）都能通过 .ic 访问其包装器 ImageCraftWrapper 实例。
extension ImageCraftCompatible {
    public var ic: ImageCraftWrapper<Self> {
        ImageCraftWrapper(self)
    }
    
    // 提供一个静态属性 ic，允许通过类型本身访问 ImageCraftWrapper，而不是类型的实例。
    public static var ic: ImageCraftWrapper<Self>.Type {
        ImageCraftWrapper<Self>.self
    }
}

// 为 ImageCraftCompatibleValue 协议扩展一个计算属性 ic，这使得任何遵循 ImageCraftCompatibleValue 的类型（即值类型）也能通过 .ic 访问其包装器 ImageCraftWrapper 实例。
extension ImageCraftCompatibleValue {
    public var ic: ImageCraftWrapper<Self> {
        ImageCraftWrapper(self)
    }
}

extension UIImage: ImageCraftCompatible { }

extension UIImageView: ImageCraftCompatible { }

extension Data: ImageCraftCompatibleValue { }

extension CGSize: ImageCraftCompatibleValue { }

extension CGRect: ImageCraftCompatibleValue { }
