// InputSense · 鼠标和废纸篓的关系（纯逻辑）
//
// 输入：估算出的废纸篓区域 + 鼠标位置和速度。输出：距离、靠近速度、"是否正朝它移动"（防抖）、是否已在上方。

import CoreGraphics
import DDMCore
import Foundation

struct TrashApproach: Sendable, Equatable {
    struct Tuning: Sendable, Equatable {
        /// 靠近速度至少这么快（点/秒）才开始算"正朝它移动"。
        var enterSpeed: CGFloat = 60
        /// 而且靠近速度要占到总速率的这么多（0.5 ≈ 行进方向与"指向废纸篓"的夹角在 60° 以内）。
        var enterRatio: CGFloat = 0.5
        /// 靠近速度掉到这以下，或者……
        var exitSpeed: CGFloat = 20
        /// ……占比掉到这以下，开始算"不再朝它移动"。
        var exitRatio: CGFloat = 0.3
        /// 条件要连续成立这么久才改口（秒）。进入快、退出慢：朝废纸篓去的路上手难免一顿一顿。
        var enterDwell: TimeInterval = 0.08
        var exitDwell: TimeInterval = 0.3
    }

    var tuning = Tuning()

    /// 防抖之后的"是否正朝废纸篓移动"。
    private(set) var isApproaching = false
    /// 与当前结论相反的条件从什么时候开始连续成立。
    private var contrarySince: TimeInterval?

    /// 算出这一帧的 `TrashInfo`。
    mutating func update(estimate: TrashEstimate, position: CGPoint, velocity: CGVector, at time: TimeInterval) -> TrashInfo {
        let rect = estimate.rect
        let distance = rect.distance(to: position)
        let isOver = distance == 0

        // 靠近速度 = 距离的减小速度 = 速度在"指向区域上最近一点"方向上的分量。已在区域内时为 0。
        var closingSpeed: CGFloat = 0
        if distance > 0 {
            let nearest = CGPoint(
                x: min(max(position.x, rect.minX), rect.maxX),
                y: min(max(position.y, rect.minY), rect.maxY)
            )
            let toward = nearest.offset(from: position)
            closingSpeed = (velocity.dx * toward.dx + velocity.dy * toward.dy) / distance
        }

        let speed = velocity.length
        let towardNow = closingSpeed >= tuning.enterSpeed && closingSpeed >= tuning.enterRatio * speed
        let awayNow = closingSpeed < tuning.exitSpeed || closingSpeed < tuning.exitRatio * speed
        let contrary = isApproaching ? awayNow : towardNow
        if contrary {
            let since = contrarySince ?? time
            contrarySince = since
            if time - since >= (isApproaching ? tuning.exitDwell : tuning.enterDwell) {
                isApproaching.toggle()
                contrarySince = nil
            }
        } else {
            contrarySince = nil
        }

        return TrashInfo(
            estimatedRect: rect,
            confidence: estimate.confidence,
            distance: distance,
            closingSpeed: closingSpeed,
            isApproaching: isApproaching,
            isOver: isOver
        )
    }
}
