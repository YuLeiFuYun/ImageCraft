//
//  SVGCodec.swift
//  ImageCraft
//
//  Created by 玉垒浮云 on 2024/4/29.
//

import UIKit

extension String {
    var base64Decoded: String? {
        if let data = Data(base64Encoded: self) {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }
}

struct SVGCodec {
    private typealias CGSVGDocumentRef = UnsafeMutableRawPointer
    
    // Define or confirm the constant
    private let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2) // Usually corresponds to RTLD_DEFAULT
    
    private var CGSVGDocumentRelease: ((CGSVGDocumentRef) -> Void)?
    private var CGSVGDocumentCreateFromData: ((CFData, CFDictionary?) -> CGSVGDocumentRef)?
    private  var CGSVGDocumentWriteToData: ((CGSVGDocumentRef, CFMutableData, CFDictionary?) -> Void)?
    private var CGContextDrawSVGDocument: ((CGContext, CGSVGDocumentRef) -> Void)?
    private var CGSVGDocumentGetCanvasSize: ((CGSVGDocumentRef) -> CGSize)?
    
    private var ImageWithCGSVGDocumentSEL = NSSelectorFromString("X2ltYWdlV2l0aENHU1ZHRG9jdW1lbnQ6".base64Decoded!)
    private var CGSVGDocumentSEL = NSSelectorFromString("X0NHU1ZHRG9jdW1lbnQ=".base64Decoded!)
    private var supportsVectorSVG: Bool { UIImage.responds(to: ImageWithCGSVGDocumentSEL) }
    
    private let size: CGSize?
    private let preserveAspectRatio: Bool
    
    init(size: CGSize? = nil, preserveAspectRatio: Bool = true) {
        self.size = size
        self.preserveAspectRatio = preserveAspectRatio
        
        if let symbolRelease = dlsym(rtldDefault, "Q0dTVkdEb2N1bWVudFJlbGVhc2U=".base64Decoded) {
            CGSVGDocumentRelease = unsafeBitCast(
                symbolRelease,
                to: Optional<@convention(c) (CGSVGDocumentRef) -> Void>.self
            )
        }
        
        if let symbolCreateFromData = dlsym(rtldDefault, "Q0dTVkdEb2N1bWVudENyZWF0ZUZyb21EYXRh".base64Decoded) {
            CGSVGDocumentCreateFromData = unsafeBitCast(
                symbolCreateFromData,
                to: Optional<@convention(c) (CFData, CFDictionary?) -> CGSVGDocumentRef>.self
            )
        }

        if let symbolWriteToData = dlsym(rtldDefault, "Q0dTVkdEb2N1bWVudFdyaXRlVG9EYXRh".base64Decoded) {
            CGSVGDocumentWriteToData = unsafeBitCast(
                symbolWriteToData,
                to: Optional<@convention(c) (CGSVGDocumentRef, CFMutableData, CFDictionary?) -> Void>.self
            )
        }

        if let symbolDrawDocument = dlsym(rtldDefault, "Q0dDb250ZXh0RHJhd1NWR0RvY3VtZW50".base64Decoded) {
            CGContextDrawSVGDocument = unsafeBitCast(
                symbolDrawDocument,
                to: Optional<@convention(c) (CGContext, CGSVGDocumentRef) -> Void>.self
            )
        }

        if let symbolGetCanvasSize = dlsym(rtldDefault, "Q0dTVkdEb2N1bWVudEdldENhbnZhc1NpemU=".base64Decoded) {
            CGSVGDocumentGetCanvasSize = unsafeBitCast(
                symbolGetCanvasSize,
                to: Optional<@convention(c) (CGSVGDocumentRef) -> CGSize>.self
            )
        }
    }
    
    public func serialize(_ image: UIImage) throws -> Data? {
        guard
            let CGSVGDocument = unsafeBitCast(
                image.method(for: CGSVGDocumentSEL),
                to: Optional<@convention(c) (UIImage, Selector) -> CGSVGDocumentRef>.self
            )
        else { return nil }
        
        let document = CGSVGDocument(image, CGSVGDocumentSEL)
        let data = NSMutableData()
        CGSVGDocumentWriteToData?(document, data, nil)
        
        return data as Data
    }
    
    public func deserialize(_ data: Data) throws -> UIImage? {
        var image: UIImage? = nil
        if let size {
            image = createBitmapSVG(with: data, targetSize: size, preserveAspectRatio: preserveAspectRatio)
        } else if supportsVectorSVG {
            image = createVectorSVG(with: data)
        }
        
        return image
    }
    
    func createVectorSVG(with data: Data) -> UIImage? {
        guard
            let document = CGSVGDocumentCreateFromData?(data as CFData, nil),
            UIImage.responds(to: ImageWithCGSVGDocumentSEL)
        else { return nil }
        
        var image: UIImage?
        let ImageWithCGSVGDocument = unsafeBitCast(
            UIImage.method(for: ImageWithCGSVGDocumentSEL),
            to: Optional<@convention(c) (AnyObject, Selector, CGSVGDocumentRef) -> UIImage>.self
        )
        image = ImageWithCGSVGDocument?(UIImage.self, ImageWithCGSVGDocumentSEL, document)
        CGSVGDocumentRelease?(document)
        
        let size = CGSize(width: 1, height: 1)
        let renderer = UIGraphicsImageRenderer(size: size)
        renderer.image { context in
            image?.draw(in: CGRect(origin: .zero, size: size))
        }
        return image
    }
    
    func createBitmapSVG(with data: Data, targetSize: CGSize, preserveAspectRatio: Bool = true) -> UIImage? {
        guard let document = CGSVGDocumentCreateFromData?(data as CFData, nil) else {
            return nil
        }
        
        let size = CGSVGDocumentGetCanvasSize?(document) ?? .zero
        if size.width == 0 || size.height == 0 { return nil }

        // 计算目标尺寸
        var targetSize = targetSize
        let xScale: CGFloat
        let yScale: CGFloat
        if targetSize.width <= 0 && targetSize.height <= 0 {
            targetSize.width = size.width
            targetSize.height = size.height
            xScale = 1
            yScale = 1
        } else {
            let xRatio = targetSize.width / size.width
            let yRatio = targetSize.height / size.height
            if preserveAspectRatio {
                if targetSize.width <= 0 {
                    yScale = yRatio
                    xScale = yRatio
                    targetSize.width = size.width * xScale
                } else if targetSize.height <= 0 {
                    xScale = xRatio
                    yScale = xRatio
                    targetSize.height = size.height * yScale
                } else {
                    xScale = min(xRatio, yRatio)
                    yScale = min(xRatio, yRatio)
                    targetSize.width = size.width * xScale
                    targetSize.height = size.height * yScale
                }
            } else {
                if targetSize.width <= 0 {
                    targetSize.width = size.width
                    yScale = yRatio
                    xScale = 1
                } else if targetSize.height <= 0 {
                    xScale = xRatio
                    yScale = 1
                    targetSize.height = size.height
                } else {
                    xScale = xRatio
                    yScale = yRatio
                }
            }
        }
        let rect = CGRect(origin: .zero, size: size)
        let targetRect = CGRect(origin: .zero, size: targetSize)

        let scaleTransform = CGAffineTransform(scaleX: xScale, y: yScale)
        var transform = CGAffineTransform.identity
        if preserveAspectRatio {
            transform = CGAffineTransform(
                translationX: (targetRect.width / xScale - rect.width) / 2,
                y: (targetRect.height / yScale - rect.height) / 2
            )
        }

        // 绘制位图
        let renderer = UIGraphicsImageRenderer(size: targetRect.size)
        let image = renderer.image { context in
            context.cgContext.translateBy(x: 0, y: targetRect.height)
            context.cgContext.scaleBy(x: 1, y: -1)
            context.cgContext.concatenate(scaleTransform)
            context.cgContext.concatenate(transform)
            CGContextDrawSVGDocument?(context.cgContext, document)
        }
        CGSVGDocumentRelease?(document)
        
        return image
    }
    
    static func isSVGFormat(for data: Data) -> Bool {
        guard let range = data.range(of: Data("</svg>".utf8), options: .backwards) else {
            return false
        }
        return range.lowerBound < data.count
    }
}
