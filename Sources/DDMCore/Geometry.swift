// DDMCore · 几何小工具
//
// 全工程的点、矩形、向量直接使用 CoreGraphics 的 CGPoint / CGRect / CGVector，
// 约定它们（除非名字里写明 appKit / local）一律处于「全局坐标」——见 Coordinates.swift。

import CoreGraphics
import Foundation

/// 矩形向四周外扩的距离，单位：点。
///
/// 方向按全局坐标（y 向下）理解：`top` 朝屏幕上方（y 减小），`bottom` 朝屏幕下方。
/// 用途：表情会画到图标图像矩形外面多远（眼泪往下、幽灵往上飘……），
/// 以及叠加层要为每张脸多留多大的画布。
public struct EdgeOutsets: Sendable, Equatable {
    public var top: CGFloat
    public var left: CGFloat
    public var bottom: CGFloat
    public var right: CGFloat

    public init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    /// 四边相同。
    public init(all value: CGFloat) {
        self.init(top: value, left: value, bottom: value, right: value)
    }

    public static let zero = EdgeOutsets()

    /// 逐边取较大值：能同时容纳两者的最小外扩。
    public func union(_ other: EdgeOutsets) -> EdgeOutsets {
        EdgeOutsets(
            top: max(top, other.top),
            left: max(left, other.left),
            bottom: max(bottom, other.bottom),
            right: max(right, other.right)
        )
    }
}

extension CGRect {
    /// 矩形中心。
    public var center: CGPoint { CGPoint(x: midX, y: midY) }

    /// 向四周外扩（y 向下的坐标系：top 使 minY 减小）。
    public func expanded(by outsets: EdgeOutsets) -> CGRect {
        CGRect(
            x: minX - outsets.left,
            y: minY - outsets.top,
            width: width + outsets.left + outsets.right,
            height: height + outsets.top + outsets.bottom
        )
    }

    /// 点到矩形的最短距离；点在矩形内（含边界）时为 0。
    public func distance(to point: CGPoint) -> CGFloat {
        let dx = max(minX - point.x, 0, point.x - maxX)
        let dy = max(minY - point.y, 0, point.y - maxY)
        return hypot(dx, dy)
    }
}

extension CGPoint {
    /// 两点间距离。
    public func distance(to other: CGPoint) -> CGFloat {
        hypot(other.x - x, other.y - y)
    }

    /// 从 `origin` 指向自己的位移。
    public func offset(from origin: CGPoint) -> CGVector {
        CGVector(dx: x - origin.x, dy: y - origin.y)
    }

    /// 平移。
    public func moved(by vector: CGVector) -> CGPoint {
        CGPoint(x: x + vector.dx, y: y + vector.dy)
    }
}

extension CGVector {
    /// 向量长度。
    public var length: CGFloat { hypot(dx, dy) }

    /// 反向。
    public var negated: CGVector { CGVector(dx: -dx, dy: -dy) }
}
