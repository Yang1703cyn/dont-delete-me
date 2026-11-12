// OverlayDemo · 假的桌面图标与替身脸
//
// 演示只用假的图标矩形：不读取桌面上的任何东西。
// 替身脸是两只会转的眼睛，画在一块半透明底色上（底色让人看得出"假图标"在哪）。

import CoreGraphics
import DDMCore
import Foundation

/// 一个假的桌面图标。
struct FakeIcon {
    var id: IconID
    /// 图标图像矩形，全局坐标。
    var rect: CGRect
    /// 底色的色相，0…1。
    var hue: CGFloat
}

enum FakeDesktop {
    /// 假图标的边长（点），与访达默认的图标大小一致。
    static let iconSize: CGFloat = 64

    /// 每张脸的画布比图标矩形多出的一圈：上面留给汗滴，下面留给眼泪。
    static let outsets = EdgeOutsets(top: 12, left: 10, bottom: 30, right: 10)

    /// 在给定的显示器上摆 `count` 个假图标：从每块屏的右上角起，像访达那样一列一列往左排。
    /// 有两块相邻的屏时，最后一个图标骑在两块屏的接缝上，用来看"跨屏也画对"。
    static func icons(count: Int, on layout: DisplayLayout, only: DisplayID? = nil) -> [FakeIcon] {
        let displays = layout.displays.filter { only == nil || $0.id == only }
        guard !displays.isEmpty, count > 0 else { return [] }

        var icons: [FakeIcon] = []
        let perDisplay = Int((Double(count) / Double(displays.count)).rounded(.up))
        for display in displays {
            let rows = max(1, min(5, Int((display.frame.height - 160) / 110)))
            for index in 0..<perDisplay where icons.count < count {
                let column = index / rows
                let row = index % rows
                let x = display.frame.maxX - 40 - iconSize - CGFloat(column) * 104
                let y = display.frame.minY + 60 + CGFloat(row) * 110
                icons.append(FakeIcon(
                    id: IconID(rawValue: UInt64(icons.count + 1)),
                    rect: CGRect(x: x, y: y, width: iconSize, height: iconSize),
                    hue: CGFloat(icons.count % 12) / 12
                ))
            }
        }

        if only == nil, let seam = seamPoint(in: layout), let last = icons.indices.last {
            icons[last].rect = CGRect(
                x: seam.x - iconSize / 2, y: seam.y - iconSize / 2, width: iconSize, height: iconSize
            )
        }
        return icons
    }

    /// 两块屏接缝上的一个点（左右相邻或上下相邻）；没有相邻的屏时为 nil。
    static func seamPoint(in layout: DisplayLayout) -> CGPoint? {
        let displays = layout.displays
        for a in displays {
            for b in displays where a.id != b.id {
                if a.frame.maxX == b.frame.minX {
                    let top = max(a.frame.minY, b.frame.minY), bottom = min(a.frame.maxY, b.frame.maxY)
                    if bottom - top > 200 { return CGPoint(x: a.frame.maxX, y: top + (bottom - top) * 0.45) }
                }
                if a.frame.maxY == b.frame.minY {
                    let left = max(a.frame.minX, b.frame.minX), right = min(a.frame.maxX, b.frame.maxX)
                    if right - left > 200 { return CGPoint(x: left + (right - left) * 0.45, y: a.frame.maxY) }
                }
            }
        }
        return nil
    }
}

/// 替身脸的状态。同样的状态（加上同样的时间）永远画出同样的画面。
struct StandInFace: Equatable {
    /// 视线方向与幅度：长度 0 = 平视前方，1 = 瞳孔贴到眼眶边上。
    var gaze = CGVector.zero
    /// 是否闭着眼。
    var isBlinking = false
    /// 是否吓哭了：流泪、冒汗（会随时间动）。
    var isScared = false
    /// 底色的色相。
    var hue: CGFloat = 0
    /// 是否画那块半透明底色。不画时就只剩两只会转的眼睛（最轻的替身，测量时用）。
    var showsBody = true

    /// 朝某个点看：离得越近，瞳孔偏得越少。
    /// - Parameter steps: 结果取整到 1/steps。演示时用 64（目标挪一点点不至于整桌重画）；
    ///   测量时用很大的数，让目标一动每张脸的状态都变——真实应用里视线是连续量，这才是最坏情形。
    static func gaze(from center: CGPoint, toward target: CGPoint, steps: CGFloat = 64) -> CGVector {
        let dx = target.x - center.x, dy = target.y - center.y
        let distance = hypot(dx, dy)
        guard distance > 0.5 else { return .zero }
        let strength = min(1, distance / 160)
        func quantize(_ value: CGFloat) -> CGFloat { (value * steps).rounded() / steps }
        return CGVector(dx: quantize(dx / distance * strength), dy: quantize(dy / distance * strength))
    }

    /// 把这张脸画在 `rect` 上。画布是 y 向下、单位点。
    func draw(in rect: CGRect, context: CGContext, time: TimeInterval) {
        let size = rect.width

        // 半透明底色：标出"假图标"的位置。
        if showsBody {
            let body = CGPath(
                roundedRect: rect.insetBy(dx: 1, dy: 1), cornerWidth: size * 0.22, cornerHeight: size * 0.22, transform: nil
            )
            let (r, g, b) = Self.rgb(hue: hue)
            context.addPath(body)
            context.setFillColor(red: r, green: g, blue: b, alpha: 0.30)
            context.fillPath()
            context.addPath(body)
            context.setStrokeColor(red: r, green: g, blue: b, alpha: 0.75)
            context.setLineWidth(1)
            context.strokePath()
        }

        // 两只眼睛。
        let eyeRadius = size * (isScared ? 0.17 : 0.15)
        let pupilRadius = size * (isScared ? 0.05 : 0.075)
        for side in [-1.0, 1.0] {
            let center = CGPoint(x: rect.midX + side * size * 0.2, y: rect.midY - size * 0.04)
            if isBlinking {
                context.setStrokeColor(gray: 0.1, alpha: 1)
                context.setLineWidth(2)
                context.move(to: CGPoint(x: center.x - eyeRadius, y: center.y))
                context.addLine(to: CGPoint(x: center.x + eyeRadius, y: center.y))
                context.strokePath()
                continue
            }
            let eye = CGRect(x: center.x - eyeRadius, y: center.y - eyeRadius, width: eyeRadius * 2, height: eyeRadius * 2)
            context.setFillColor(gray: 1, alpha: 1)
            context.fillEllipse(in: eye)
            context.setStrokeColor(gray: 0.1, alpha: 1)
            context.setLineWidth(1.5)
            context.strokeEllipse(in: eye)

            let reach = eyeRadius - pupilRadius - 1.5
            let pupil = CGPoint(x: center.x + gaze.dx * reach, y: center.y + gaze.dy * reach)
            context.setFillColor(gray: 0.05, alpha: 1)
            context.fillEllipse(in: CGRect(
                x: pupil.x - pupilRadius, y: pupil.y - pupilRadius, width: pupilRadius * 2, height: pupilRadius * 2
            ))
        }

        guard isScared else { return }
        // 眼泪：从图标下沿往下掉，画在图标矩形外面（画布多留的那一圈里）。
        for (index, side) in [-1.0, 1.0].enumerated() {
            let phase = (time * 1.4 + Double(index) * 0.5).truncatingRemainder(dividingBy: 1)
            let x = rect.midX + side * size * 0.2
            let y = rect.maxY - 6 + CGFloat(phase) * 26
            context.setFillColor(red: 0.25, green: 0.6, blue: 1, alpha: 0.9 * (1 - phase * 0.6))
            context.fillEllipse(in: CGRect(x: x - 3, y: y, width: 6, height: 8))
        }
        // 汗滴：在右上角外面晃。
        let wobble = CGFloat(sin(time * 9)) * 2
        context.setFillColor(red: 0.4, green: 0.75, blue: 1, alpha: 0.9)
        context.fillEllipse(in: CGRect(x: rect.maxX - 2 + wobble, y: rect.minY - 9, width: 6, height: 9))
    }

    private static func rgb(hue: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let h = hue * 6
        let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
        let (r, g, b): (CGFloat, CGFloat, CGFloat)
        switch Int(h) % 6 {
        case 0: (r, g, b) = (1, x, 0)
        case 1: (r, g, b) = (x, 1, 0)
        case 2: (r, g, b) = (0, 1, x)
        case 3: (r, g, b) = (0, x, 1)
        case 4: (r, g, b) = (x, 0, 1)
        default: (r, g, b) = (1, 0, x)
        }
        return (0.25 + r * 0.7, 0.25 + g * 0.7, 0.25 + b * 0.7)
    }
}
