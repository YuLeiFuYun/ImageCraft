//
//  UIImage+Ex.swift
//  ImageCraft
//
//  Created by 玉垒浮云 on 2024/4/29.
//

import UIKit

extension ImageCraftWrapper where Base == UIImage {
    var decoded: UIImage {
        if #available(iOS 15, *) {
            if let decodedImage = base.preparingForDisplay() {
                return decodedImage
            }
        }
        
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = base.scale
        let imageRenderer = UIGraphicsImageRenderer(size: base.size, format: format)
        return imageRenderer.image { context in
            base.draw(in: CGRect(origin: .zero, size: base.size))
        }
    }
    
    func roundedImage(
        withRadius radius: ImageCraft.Radius,
        roundingCorners corners: UIRectCorner = .allCorners,
        backgroundColor: UIColor? = nil,
        borderWidth: CGFloat = 0,
        borderColor: UIColor = .white
    ) -> UIImage {
        roundedImage(
            withRadius: radius,
            roundingCorners: corners,
            backgroundColor: backgroundColor,
            borderWidth: borderWidth,
            borderColor: borderColor,
            containerViewSize: base.size,
            containerViewContentMode: .none
        )
    }
    
    func roundedImage(
        withRadius radius: ImageCraft.Radius,
        roundingCorners corners: UIRectCorner = .allCorners,
        backgroundColor: UIColor? = nil,
        borderWidth: CGFloat = 0,
        borderColor: UIColor = .white,
        containerViewSize size: CGSize,
        containerViewContentMode contentMode: ImageCraft.ContentMode
    ) -> UIImage {
        // 确保图像基于 CGImage
        guard base.cgImage != nil else {
            assertionFailure("Round corner image only works for CG-based image.")
            return base
        }
        
        // 初始化偏移和缩放因子
        var xOffset: CGFloat = 0, yOffset: CGFloat = 0, scalingFactor: CGFloat = 1
        
        // 根据容器尺寸和内容模式调整图像尺寸和位置
        if size.ic.aspectRatio > base.size.ic.aspectRatio {
            if contentMode == .scaleAspectFill {
                yOffset = (base.size.height - base.size.width / size.ic.aspectRatio) / 2
                scalingFactor = base.size.width / size.width
            } else if contentMode == .scaleAspectFit {
                scalingFactor = base.size.height / size.height
            }
        } else {
            if contentMode == .scaleAspectFill {
                xOffset = (base.size.width - base.size.height * size.ic.aspectRatio) / 2
                scalingFactor = base.size.height / size.height
            } else if contentMode == .scaleAspectFit {
                scalingFactor = base.size.width / size.width
            }
        }
        
        // 计算实际的圆角大小
        let actualCornerRadius = radius.compute(with: base.size) * scalingFactor
        let drawSize = CGSize(width: base.size.width - 2 * xOffset, height: base.size.height - 2 * yOffset)
        
        // 创建一个图像渲染器格式，优先使用设备推荐的格式设置。
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = base.scale
        let imageRenderer = UIGraphicsImageRenderer(size: drawSize, format: format)
        
        return imageRenderer.image { context in
            // 如果指定了背景颜色，则先填充背景
            if let backgroundColor = backgroundColor {
                let rectPath = UIBezierPath(rect: CGRect(origin: .zero, size: drawSize))
                backgroundColor.setFill()
                rectPath.fill()
            }
            
            // 创建用于圆角的路径
            let path = UIBezierPath(
                roundedRect: CGRect(origin: .zero, size: drawSize),
                byRoundingCorners: corners,
                cornerRadii: CGSize(width: actualCornerRadius, height: actualCornerRadius)
            )
            path.close()
            path.addClip()
            
            // 绘制图片
            base.draw(in: CGRect(x: -xOffset, y: -yOffset, width: base.size.width, height: base.size.height))
            
            // 添加边框
            path.lineWidth = borderWidth * scalingFactor * 2
            borderColor.setStroke()
            path.stroke()
        }
    }
    
    func resize(to desiredSize: CGSize, interpolationQuality: CGInterpolationQuality = .default, for contentMode: ImageCraft.ContentMode = .scaleAspectFit) -> UIImage {
        let targetSize = base.size.ic.resize(to: desiredSize, for: contentMode)
        
        if #available(iOS 15, *), contentMode != .none {
            if let image = base.preparingThumbnail(of: targetSize) {
                return image
            }
        }
        
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = base.scale
        let imageRenderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        
        return imageRenderer.image { context in
            context.cgContext.interpolationQuality = interpolationQuality
            base.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
    
    // 定义一个裁剪方法，接受目标尺寸和一个可选的锚点参数，默认锚点在图像中心。
    func crop(to size: CGSize, anchorOn anchor: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> UIImage {
        // 确保 UIImage 基于 CGImage，因为裁剪操作是基于 Core Graphics 的 CGImage 进行的。
        guard let cgImage = base.cgImage else {
            assertionFailure("Crop only works for CG-based image.")
            return base
        }
        
        // 计算裁剪矩形。这一步涉及到根据指定的锚点和目标尺寸，计算出一个 CGRect 作为裁剪区域。
        let rect = base.size.ic.constrainedRect(for: size, anchor: anchor)
        
        // 使用 Core Graphics 的 cropping 方法进行裁剪。
        guard let image = cgImage.cropping(to: rect.ic.scaled(base.scale)) else {
            assertionFailure("Cropping image failed.")
            return base // 如果裁剪失败，返回原图像。
        }
        
        // 使用裁剪后的 CGImage 创建一个新的 UIImage 对象，保持原图像的 scale 和 orientation 不变。
        return UIImage(cgImage: image, scale: base.scale, orientation: base.imageOrientation)
    }
    
    static func downsample(data: Data, to pointSize: CGSize) -> UIImage? {
        // 设置图像源选项，指定不应在创建时缓存图像数据。
        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        
        // 获取屏幕的缩放比例。
        let scale = if #available(iOS 13, *) { UITraitCollection.current.displayScale } else { UIScreen.main.scale }
        
        // 计算目标尺寸的最大维度（以像素为单位），乘以屏幕的缩放比例。
        let maxDimensionInPixels = max(pointSize.width, pointSize.height) * scale
        
        // 设置降采样选项。
        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,         // 生成缩略图
            kCGImageSourceShouldCacheImmediately: true,                 // 是否在创建图片时就进行解码
            kCGImageSourceCreateThumbnailWithTransform: true,           // 根据完整图像的方向和像素纵横比旋转和缩放缩略图
            kCGImageSourceThumbnailMaxPixelSize: maxDimensionInPixels   // 指定缩略图的最大维度
        ] as CFDictionary
        
        // 尝试创建图像源，使用提供的图像数据和图像源选项。
        guard
            let imageSource = CGImageSourceCreateWithData(data as CFData, imageSourceOptions),
            // 尝试创建降采样图像，指定索引为0（通常图像数据只包含一个图像）和下采样选项。
            let downsampledImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions)
        else { return nil } // 如果创建失败，返回nil。
        
        // 使用下采样后的CGImage创建并返回UIImage对象。
        return UIImage(cgImage: downsampledImage)
    }

    static func downsample(imageAt imageURL: URL, to pointSize: CGSize) -> UIImage? {
        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        let scale = if #available(iOS 13, *) { UITraitCollection.current.displayScale } else { UIScreen.main.scale }
        let maxDimensionInPixels = max(pointSize.width, pointSize.height) * scale
        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimensionInPixels
        ] as CFDictionary
        
        guard
            let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, imageSourceOptions),
            let downsampledImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions)
        else { return nil }
        
        return UIImage(cgImage: downsampledImage)
    }
}
