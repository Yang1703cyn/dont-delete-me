// Overlay · 坐标换算（纯逻辑）
//
// 调用方只说全局坐标（主屏左上角为原点、y 向下、单位点）。这里把一块画布换算到某一块屏上：
// 位图有多少像素、放在屏里的哪个像素位置、交给调用方的画布该怎么摆坐标系。
//
// 清晰的关键是"对齐像素"：位图的四条边都落在这块屏的像素格上，图层按 1:1 贴上去，
// 这样内屏（2x）和外接屏（1x）都不会因为半个像素的偏移而发虚。

import CoreGraphics
import DDMCore
import Foundation

/// 一块屏里的像素矩形：以这块屏的左上角为原点、y 向下、单位像素。
struct PixelRect: Equatable, Sendable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
}

/// 一块画布在某一块屏上的落位。
struct CanvasPlacement: Equatable, Sendable {
    /// 位图在这块屏里占的像素矩形。
    var pixelFrame: PixelRect
    /// 这块屏 1 点等于几个像素。
    var scale: CGFloat

    /// 位图在这块屏里的位置，屏内坐标（点、y 向下）。
    var localFrame: CGRect {
        CGRect(
            x: CGFloat(pixelFrame.x) / scale,
            y: CGFloat(pixelFrame.y) / scale,
            width: CGFloat(pixelFrame.width) / scale,
            height: CGFloat(pixelFrame.height) / scale
        )
    }

    /// 位图覆盖的全局矩形。它是画布矩形向外取整到像素格之后的结果，所以总是包住画布矩形。
    func globalFrame(on display: DisplayInfo) -> CGRect {
        display.globalRect(fromLocal: localFrame)
    }

    /// 图层在窗口里的位置。窗口与屏幕等大，图层坐标的原点在窗口**左下角**、y 向上（AppKit 的习惯），
    /// 所以这里要用下边缘去翻转。
    func layerFrame(inWindowOfHeight windowHeight: CGFloat) -> CGRect {
        let local = localFrame
        return CGRect(x: local.minX, y: windowHeight - local.maxY, width: local.width, height: local.height)
    }

    /// 只挪位置、不重画：按"挪了多少点"换算成整数个像素，位图仍然对齐像素格。
    /// 与精确位置最多差半个像素（内屏 0.25 点、外接屏 0.5 点），肉眼不可见，换来的是不必重画。
    func moved(by delta: CGVector) -> CanvasPlacement {
        var moved = self
        moved.pixelFrame.x += Int((delta.dx * scale).rounded())
        moved.pixelFrame.y += Int((delta.dy * scale).rounded())
        return moved
    }
}

enum CanvasGeometry {
    /// 单块画布每边最多这么多像素。脸的画布只有一两百像素；超过这个数只可能是调用方传错了矩形，
    /// 这时宁可不画，也不去分配一块巨大的位图。
    static let maxPixelsPerSide = 4096

    /// 画布矩形在这块屏上的落位；与这块屏不相交、矩形不合法或大得离谱时为 nil（不画）。
    ///
    /// 位图向外取整到像素格：左、上边缘向下取整，右、下边缘向上取整。
    /// 画布跨两块屏时，对每块屏各调用一次——每块屏按自己的缩放各有一块位图，窗口会裁掉屏外的部分。
    static func placement(for canvasRect: CGRect, on display: DisplayInfo) -> CanvasPlacement? {
        guard isDrawable(canvasRect), display.scale > 0, display.frame.intersects(canvasRect) else { return nil }
        let scale = display.scale
        let local = display.localRect(fromGlobal: canvasRect)
        let minX = (local.minX * scale).rounded(.down)
        let minY = (local.minY * scale).rounded(.down)
        let maxX = (local.maxX * scale).rounded(.up)
        let maxY = (local.maxY * scale).rounded(.up)
        let width = Int(maxX - minX)
        let height = Int(maxY - minY)
        guard width > 0, height > 0, width <= maxPixelsPerSide, height <= maxPixelsPerSide else { return nil }
        return CanvasPlacement(
            pixelFrame: PixelRect(x: Int(minX), y: Int(minY), width: width, height: height),
            scale: scale
        )
    }

    /// 坐标的绝对值超过这个数（点）的矩形不画。真实的屏幕坐标不过几万；这道关挡住的是传错的值，
    /// 也保证后面换算成整数像素时不会溢出。
    static let maxCoordinate: CGFloat = 1_000_000

    /// 矩形是否能画：四个数都是有限数、大小在合理范围内，而且有面积。
    static func isDrawable(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
            && abs(rect.minX) <= maxCoordinate && abs(rect.minY) <= maxCoordinate
            && rect.width <= maxCoordinate && rect.height <= maxCoordinate
    }

    /// 这块画布会出现在哪几块屏上（按布局里的顺序，主屏在前）。
    static func displays(showing canvasRect: CGRect, in layout: DisplayLayout) -> [DisplayInfo] {
        layout.displays.filter { placement(for: canvasRect, on: $0) != nil }
    }
}
