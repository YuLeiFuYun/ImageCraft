//
//  UIImageView+Ex.swift
//  ImageCraft
//
//  Created by 玉垒浮云 on 2024/4/29.
//

import UIKit

fileprivate extension UIImageView {
    static let key = malloc(1)!
    
    var displayLink: CADisplayLink? {
        get {
            return objc_getAssociatedObject(self, UIImageView.key) as? CADisplayLink
        }
        set {
            if let newValue {
                objc_setAssociatedObject(self, UIImageView.key, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            } else {
                objc_setAssociatedObject(self, UIImageView.key, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
        }
    }
    
    // 处理displayLink的更新
    @objc func handleDisplayLink(_ displayLink: CADisplayLink) {
        print("handleDisplayLink")
    }
}

extension ImageCraftWrapper where Base == UIImageView {
    func startAnimating() {
        stopAnimating()
        
        let displayLink = CADisplayLink(target: self, selector: #selector(base.handleDisplayLink))
        if #available(iOS 15, *) {
            displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 1, maximum: 60)
        }
        displayLink.add(to: .main, forMode: .common)
        base.displayLink = displayLink
    }
    
    func stopAnimating() {
        base.displayLink?.invalidate()
        base.displayLink = nil
    }
}

extension ImageCraftWrapper where Base == UIImageView {
    func setImage(
        _ image: UIImage,
        cornerRadius: ImageCraft.Radius,
        roundingCorners corners: UIRectCorner = .allCorners,
        backgroundColor: UIColor? = nil,
        borderWidth: CGFloat = 0,
        borderColor: UIColor = .white
    ) {
        var contentMode: ImageCraft.ContentMode = .none
        if base.contentMode == .scaleAspectFit {
            contentMode = .scaleAspectFit
        } else if base.contentMode == .scaleAspectFill {
            contentMode = .scaleAspectFill
        }
        
        base.image = image.ic.roundedImage(
            withRadius: cornerRadius,
            roundingCorners: corners,
            backgroundColor: backgroundColor,
            borderWidth: borderWidth,
            borderColor: borderColor,
            containerViewSize: base.bounds.size,
            containerViewContentMode: contentMode
        )
    }
}
