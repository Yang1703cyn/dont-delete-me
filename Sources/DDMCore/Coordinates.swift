// DDMCore · 坐标约定与显示器布局
//
// 【全局坐标】全工程唯一的"通用语"：
//   - 原点：主屏（带菜单栏的那块屏）的左上角；
//   - x 向右、y 向下；
//   - 单位：点（不是像素）；
//   - 多显示器：其它屏按排列关系落在同一平面上，坐标可以为负（例如主屏左侧的外接屏 x < 0）。
// 它与访达的 desktop position、CGDisplayBounds、CGWindowList 的窗口边界、CGEvent.location
// 是同一套坐标，这些来源的数值可以直接使用，不必换算。
//
// 【AppKit 坐标】NSScreen.frame、NSWindow.frame、NSEvent.mouseLocation 用的那套：
//   原点在主屏左下角，y 向上。只有和 AppKit 打交道的那一小段代码才需要它，
//   用本文件的函数互转，不要手写"屏高减 y"。

import CoreGraphics
import Foundation

/// 显示器编号，等同于 CGDirectDisplayID。只在本次开机期间稳定。
public struct DisplayID: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

/// 一块显示器。
public struct DisplayInfo: Sendable, Equatable, Identifiable {
    public var id: DisplayID
    /// 这块屏在全局坐标里的矩形（点）。主屏的原点恒为 (0, 0)。
    public var frame: CGRect
    /// 1 点等于几个像素（内屏 Retina 为 2，普通外接屏为 1）。
    public var scale: CGFloat

    public init(id: DisplayID, frame: CGRect, scale: CGFloat) {
        self.id = id
        self.frame = frame
        self.scale = scale
    }

    /// 是否主屏（全局坐标原点所在的屏）。
    public var isPrimary: Bool { frame.origin == .zero }

    // 屏内坐标：以这块屏的左上角为原点、y 向下、单位点。叠加层在每块屏的窗口里定位用。

    public func localPoint(fromGlobal point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
    }

    public func globalPoint(fromLocal point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + frame.minX, y: point.y + frame.minY)
    }

    public func localRect(fromGlobal rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
    }

    public func globalRect(fromLocal rect: CGRect) -> CGRect {
        rect.offsetBy(dx: frame.minX, dy: frame.minY)
    }
}

/// 全局坐标与 AppKit 坐标互转的纯函数。
///
/// 两套坐标都是"全局"的，区别只在 y 轴：以主屏高度为轴上下翻转。
/// 所以换算只需要主屏高度，对任何一块屏上的点都成立。
public enum CoordinateConversion {
    public static func appKitPoint(fromGlobal point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    public static func globalPoint(fromAppKit point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// 矩形换算：AppKit 矩形的原点是左下角，所以要用全局矩形的下边缘去翻转。
    public static func appKitRect(fromGlobal rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func globalRect(fromAppKit rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// 当前所有显示器的排列。值类型、可随意跨线程传递。
///
/// 取当前布局用 `DisplayLayout.current()`（见 Coordinates+System.swift）；
/// 测试里直接用 `init(displays:)` 造假的布局。
public struct DisplayLayout: Sendable, Equatable {
    /// 所有显示器，主屏排在第一个。
    public private(set) var displays: [DisplayInfo]

    public init(displays: [DisplayInfo]) {
        // 主屏放最前，其余保持传入顺序。
        self.displays = displays.filter(\.isPrimary) + displays.filter { !$0.isPrimary }
    }

    /// 主屏。没有任何显示器（或没有原点在 (0,0) 的屏）时为 nil。
    public var primary: DisplayInfo? { displays.first(where: \.isPrimary) }

    /// 主屏高度（点）。全局 ↔ AppKit 换算的唯一参数；没有主屏时为 0。
    public var primaryHeight: CGFloat { primary?.frame.height ?? 0 }

    /// 包住所有显示器的最小矩形（全局坐标）；没有显示器时为 .null。
    public var bounds: CGRect {
        displays.reduce(CGRect.null) { $0.union($1.frame) }
    }

    public func display(withID id: DisplayID) -> DisplayInfo? {
        displays.first { $0.id == id }
    }

    /// 包含该点的显示器（全局坐标）；点不在任何屏上时为 nil。
    public func display(containing point: CGPoint) -> DisplayInfo? {
        displays.first { $0.frame.contains(point) }
    }

    /// 离该点最近的显示器；点在某块屏内时就是那块屏。没有显示器时为 nil。
    public func display(nearestTo point: CGPoint) -> DisplayInfo? {
        displays.min { $0.frame.distance(to: point) < $1.frame.distance(to: point) }
    }

    /// 一个矩形"算在哪块屏上"：取相交面积最大的那块；与所有屏都不相交时取离矩形中心最近的。
    public func display(bestFor rect: CGRect) -> DisplayInfo? {
        func overlap(_ display: DisplayInfo) -> CGFloat {
            let intersection = display.frame.intersection(rect)
            return intersection.isNull ? 0 : intersection.width * intersection.height
        }
        if let best = displays.max(by: { overlap($0) < overlap($1) }), overlap(best) > 0 {
            return best
        }
        return display(nearestTo: rect.center)
    }

    // 全局 ↔ AppKit。对任何一块屏上的点、矩形都适用。

    public func appKitPoint(fromGlobal point: CGPoint) -> CGPoint {
        CoordinateConversion.appKitPoint(fromGlobal: point, primaryHeight: primaryHeight)
    }

    public func globalPoint(fromAppKit point: CGPoint) -> CGPoint {
        CoordinateConversion.globalPoint(fromAppKit: point, primaryHeight: primaryHeight)
    }

    public func appKitRect(fromGlobal rect: CGRect) -> CGRect {
        CoordinateConversion.appKitRect(fromGlobal: rect, primaryHeight: primaryHeight)
    }

    public func globalRect(fromAppKit rect: CGRect) -> CGRect {
        CoordinateConversion.globalRect(fromAppKit: rect, primaryHeight: primaryHeight)
    }
}
