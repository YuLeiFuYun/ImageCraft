//
//  AnimatedImageViewModel.swift
//  ImageCraft
//
//  Created by 玉垒浮云 on 2024/4/30.
//

import UIKit

final class AnimatedImageViewModel {
    public struct AnimatedImageViewConfiguration {
        public var maxByteCount: Int64
        public var maxSize: CGSize
    }
    
    init(data: Data, identifier: String, configuration: AnimatedImageViewConfiguration) {
        
    }
    
    var indices: [Int] = []
    
    var delayTime: Double = 0.1
    
    /// Based on https://github.com/kirualex/SwiftyGif
    /// See also UIImage+SwiftyGif.swift
    private func decimateFrames(
        delays: [Double],
        levelOfIntegrity: Double
    ) -> (displayIndices: [Int], delay: Double) {
        // 保证显示帧的完整性比例在0到1之间
        let levelOfIntegrity = max(0.0, min(1.0, levelOfIntegrity))

        // 计算每一帧的累积显示时间戳
        let timestamps = delays.reduce(into: []) { $0.append(($0.last ?? 0) + $1) }

        // 设定一系列可能的帧间隔时间，对应不同的显示帧率
        let vsyncInterval: [Double] = [
            1.0 / 1.0,
            1.0 / 2.0,
            1.0 / 3.0,
            1.0 / 4.0,
            1.0 / 5.0,
            1.0 / 6.0,
            1.0 / 10.0,
            1.0 / 12.0,
            1.0 / 15.0,
            1.0 / 20.0,
            1.0 / 30.0,
            1.0 / 60.0,
        ]

        // 默认延迟时间为0.1秒
        var resultDelayTime: Double = 0.1
        // 默认所有帧都显示
        var displayIndices: [Int] = (0..<delays.count).map({ $0 })

        // 如果帧数少于等于2或完整性级别设为1，则显示所有帧
        if delays.count <= 2 || levelOfIntegrity == 1 {
            return (displayIndices, delays.first ?? resultDelayTime)
        }

        // 遍历每个可能的帧间隔时间，寻找最优解
        for delayTime in vsyncInterval {
            // 计算每个时间戳对应的vsync索引
            let vsyncIndices = timestamps.map { Int($0 / delayTime) }
            let uniqueVsyncIndices = Set(vsyncIndices).map({ $0 })
            // 计算需要显示的最小帧数
            let needsDisplayFrameCount = Int(
                Double(vsyncIndices.count) * levelOfIntegrity
            )
            let displayFrameCount = uniqueVsyncIndices.count
            // 检查当前帧间隔是否满足完整性需求
            let isEnoughFrameCount = displayFrameCount >= needsDisplayFrameCount
            
            if isEnoughFrameCount {
                let imageCount = uniqueVsyncIndices.count
                
                var oldIndex = 0
                var newIndex = 0
                displayIndices = []
                
                // 确定需要显示的帧索引
                while newIndex <= imageCount && oldIndex < vsyncIndices.count {
                    if newIndex <= vsyncIndices[oldIndex] {
                        displayIndices.append(oldIndex)
                        newIndex += 1
                    } else {
                        oldIndex += 1
                    }
                }
                resultDelayTime = delayTime
                break
            }
        }

        return (displayIndices, resultDelayTime)
    }
}
