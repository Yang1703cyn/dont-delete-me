// FacesDemo · 风格提案 · 三种风格共用的部分
//
// 第一阶段的"风格提案"代码：三种风格各画 4 个关键表情，供用户挑选。
// 它们只存在于演示程序里，不进正式的 Faces 模块；用户改选风格时可以从这里重新出图。
// 输入与正式接口相同（FaceState + 图标矩形 + 时间），同样的输入永远画出同样的画面。
//
// 尺寸单位：下文的 u = 图标宽度 / 64，也就是"64 点图标上的 1 点"。所有尺寸都按 u 给出，
// 所以图标放大缩小时整张脸等比缩放。

import CoreGraphics
import DDMCore
import Foundation

/// 一种待选的风格。
protocol ProposalStyle: Sendable {
    /// 样张上的标题，例如"① 经典大眼睛"。
    var title: String { get }
    /// 一句话说明。
    var tagline: String { get }
    /// 细节图的文件名片段。
    var fileTag: String { get }
    /// 画一张脸。约定与 `FaceRendering.draw` 相同：y 向下、单位点、iconRect 给的是哪里就画在哪里。
    func draw(_ state: FaceState, in iconRect: CGRect, context: CGContext, time: TimeInterval)
}

/// 颜色。全部按 sRGB 给出（叠加层的画布和窗口都是 sRGB）。
enum Tint {
    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// 墨线：轮廓、瞳孔、嘴线。偏紫的近黑色，比纯黑柔和。
    static let ink = hex(0x221E2B)
    static let white = hex(0xFFFFFF)
    /// 腮红。
    static let blush = hex(0xFF6B8E)
    /// 腮红上的斜线。
    static let blushLine = hex(0xE23A64)
    /// 泪和汗的填充色：很浅的蓝，在蓝色文件夹上也比底色亮。
    static let water = hex(0xC4EEFF)
    /// 泪和汗的描边：较深的蓝，在浅色墙纸和白色文稿上靠它显形。
    static let waterEdge = hex(0x2B8BDA)
    /// 张开的嘴里面。
    static let mouthInside = hex(0x6E1F35)
    static let tongue = hex(0xFF8FA6)
    /// 豆豆眼风格"吓得脸发青"的竖线。
    static let gloom = hex(0x5560D6)
}

/// 小数学工具。
enum Kit {
    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    /// 平滑台阶：x 从 e0 到 e1 时，结果从 0 平滑升到 1。
    static func smoothstep(_ e0: CGFloat, _ e1: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// 小数部分，结果在 [0, 1)。
    static func fract(_ x: Double) -> Double { x - floor(x) }

    /// 一只眼睛（或整张脸）朝视线目标看的方向，返回单位圆内的向量。
    /// 每只眼睛各算各的，所以目标离得很近时两眼会自然对到一起。
    /// 目标越远越接近"看到头"，离得近时偏移变小。
    static func gaze(from origin: CGPoint, state: FaceState, iconRect: CGRect) -> CGVector {
        guard state.gazeFollow > 0 else { return .zero }
        let target = iconRect.center.moved(by: state.gazeTarget)
        let dx = target.x - origin.x
        let dy = target.y - origin.y
        let distance = hypot(dx, dy)
        guard distance > 1e-6 else { return .zero }
        let reach = iconRect.width * 0.3
        let strength = distance / (distance + reach) * CGFloat(state.gazeFollow)
        return CGVector(dx: dx / distance * strength, dy: dy / distance * strength)
    }

    /// 发抖：整张脸的位移。
    static func trembleOffset(_ amount: Double, u: CGFloat, time: TimeInterval) -> CGVector {
        guard amount > 0 else { return .zero }
        let a = CGFloat(amount)
        return CGVector(
            dx: CGFloat(sin(time * 2 * .pi * 13)) * 1.3 * u * a,
            dy: CGFloat(sin(time * 2 * .pi * 17 + 1.3)) * 0.6 * u * a
        )
    }
}

extension CGContext {
    func fillEllipse(center: CGPoint, rx: CGFloat, ry: CGFloat, color: CGColor) {
        setFillColor(color)
        fillEllipse(in: CGRect(x: center.x - rx, y: center.y - ry, width: rx * 2, height: ry * 2))
    }

    func strokeEllipse(center: CGPoint, rx: CGFloat, ry: CGFloat, color: CGColor, width: CGFloat) {
        setStrokeColor(color)
        setLineWidth(width)
        strokeEllipse(in: CGRect(x: center.x - rx, y: center.y - ry, width: rx * 2, height: ry * 2))
    }

    /// 圆头圆角地描一条路径。
    func stroke(_ path: CGPath, color: CGColor, width: CGFloat) {
        setStrokeColor(color)
        setLineWidth(width)
        setLineCap(.round)
        setLineJoin(.round)
        addPath(path)
        strokePath()
    }

    func fill(_ path: CGPath, color: CGColor) {
        setFillColor(color)
        addPath(path)
        fillPath()
    }

    func strokeLine(from start: CGPoint, to end: CGPoint, color: CGColor, width: CGFloat) {
        let path = CGMutablePath()
        path.move(to: start)
        path.addLine(to: end)
        stroke(path, color: color, width: width)
    }

    /// 墨线外面包一圈白边（"贴纸边"）：这样墨线画在深色图标上也看得清。
    func strokeWithHalo(_ path: CGPath, width: CGFloat, halo: CGFloat, color: CGColor = Tint.ink) {
        stroke(path, color: Tint.white, width: width + halo * 2)
        stroke(path, color: color, width: width)
    }
}

// MARK: - 圆眼睛（风格 ①、③ 共用）

/// 一只"白眼球 + 瞳孔"的眼睛。
struct RoundEye {
    var center: CGPoint
    var rx: CGFloat
    var ry: CGFloat
    /// 上、下眼皮各盖住眼睛高度的多少（0…1）；两者之和到 1 就是闭上。
    var coverTop: CGFloat = 0
    var coverBottom: CGFloat = 0
    var pupilRadius: CGFloat
    /// 视线：单位圆内的向量。
    var gaze: CGVector = .zero
    var outlineWidth: CGFloat
    /// 上眼皮那条线的粗细。
    var lidWidth: CGFloat
    /// 高光：位置和半径都以瞳孔半径为单位。
    var highlights: [(dx: CGFloat, dy: CGFloat, r: CGFloat)] = []
    /// 眼眶里蓄着的泪（0…1）。
    var tearPool: CGFloat = 0
    /// 泪水水面晃动的相位。
    var poolPhase: CGFloat = 0

    /// 没被眼皮盖住的那一段的上、下边界。
    var openBand: (top: CGFloat, bottom: CGFloat) {
        (center.y - ry + coverTop * 2 * ry, center.y + ry - coverBottom * 2 * ry)
    }

    func draw(in ctx: CGContext, u: CGFloat) {
        let band = openBand
        let box = CGRect(x: center.x - rx, y: center.y - ry, width: rx * 2, height: ry * 2)

        guard band.bottom - band.top > 0.6 * u else {
            // 闭上了：一条横线。
            let y = (band.top + band.bottom) / 2
            let half = chordHalfWidth(at: y)
            ctx.strokeLine(
                from: CGPoint(x: center.x - half, y: y), to: CGPoint(x: center.x + half, y: y),
                color: Tint.ink, width: lidWidth
            )
            return
        }

        ctx.saveGState()
        // 眼皮盖住的部分不画；没盖的那一侧给轮廓线留出半个线宽。
        let slackTop = coverTop > 0.01 ? 0 : outlineWidth
        let slackBottom = coverBottom > 0.01 ? 0 : outlineWidth
        ctx.clip(to: CGRect(
            x: box.minX - outlineWidth, y: band.top - slackTop,
            width: box.width + outlineWidth * 2, height: band.bottom - band.top + slackTop + slackBottom
        ))
        ctx.setFillColor(Tint.white)
        ctx.fillEllipse(in: box)

        // 眼白里面的东西（瞳孔、高光、泪）裁在眼眶内。
        ctx.saveGState()
        ctx.addEllipse(in: box)
        ctx.clip()
        let roomX = max(rx - pupilRadius - 0.9 * u, 0)
        let roomY = max(ry - pupilRadius - 0.9 * u, 0)
        var pupil = CGPoint(x: center.x + gaze.dx * roomX, y: center.y + gaze.dy * roomY)
        // 眼皮耷下来时，瞳孔别整个藏到眼皮后面。
        let hide = pupilRadius * 0.55
        if band.bottom - band.top > hide * 2 {
            pupil.y = min(max(pupil.y, band.top + hide), band.bottom - hide)
        } else {
            pupil.y = (band.top + band.bottom) / 2
        }
        // 眼眶里蓄着的泪：先在瞳孔后面画一层实的，瞳孔画完再盖一层半透明的——
        // 这样泪水漫过瞳孔时，瞳孔透过水面还看得见。
        if tearPool > 0.02 {
            drawTearPool(in: ctx, band: band, u: u, alpha: 1, withSurfaceLine: false)
        }
        ctx.fillEllipse(center: pupil, rx: pupilRadius, ry: pupilRadius, color: Tint.ink)
        if tearPool > 0.02 {
            drawTearPool(in: ctx, band: band, u: u, alpha: 0.3, withSurfaceLine: true)
        }
        for h in highlights {
            ctx.fillEllipse(
                center: CGPoint(x: pupil.x + h.dx * pupilRadius, y: pupil.y + h.dy * pupilRadius),
                rx: h.r * pupilRadius, ry: h.r * pupilRadius, color: Tint.white
            )
        }
        ctx.restoreGState()

        ctx.strokeEllipse(center: center, rx: rx, ry: ry, color: Tint.ink, width: outlineWidth)
        ctx.restoreGState()

        // 眼皮线。
        if coverTop > 0.01 {
            let half = chordHalfWidth(at: band.top)
            ctx.strokeLine(
                from: CGPoint(x: center.x - half, y: band.top), to: CGPoint(x: center.x + half, y: band.top),
                color: Tint.ink, width: lidWidth
            )
        }
        if coverBottom > 0.01 {
            let half = chordHalfWidth(at: band.bottom)
            ctx.strokeLine(
                from: CGPoint(x: center.x - half, y: band.bottom), to: CGPoint(x: center.x + half, y: band.bottom),
                color: Tint.ink, width: outlineWidth
            )
        }
    }

    /// 眼眶在高度 y 处的半宽。
    private func chordHalfWidth(at y: CGFloat) -> CGFloat {
        let rel = (y - center.y) / ry
        return rx * sqrt(max(0, 1 - rel * rel))
    }

    /// 眼眶下半部蓄着的泪：一汪带波纹的水面。
    private func drawTearPool(
        in ctx: CGContext, band: (top: CGFloat, bottom: CGFloat), u: CGFloat, alpha: CGFloat, withSurfaceLine: Bool
    ) {
        let depth = (band.bottom - band.top) * 0.38 * tearPool
        let surface = band.bottom - depth
        let path = CGMutablePath()
        let steps = 12
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = center.x - rx + t * rx * 2
            let y = surface + sin(t * 2 * .pi * 1.5 + poolPhase) * 0.7 * u
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        let wave = path.copy()!
        path.addLine(to: CGPoint(x: center.x + rx, y: center.y + ry + u))
        path.addLine(to: CGPoint(x: center.x - rx, y: center.y + ry + u))
        path.closeSubpath()
        ctx.fill(path, color: Tint.water.copy(alpha: alpha)!)
        if withSurfaceLine {
            ctx.stroke(wave, color: Tint.waterEdge, width: 0.8 * u)
        }
    }
}

// MARK: - 嘴（风格 ②、③ 共用）

/// 一张嘴：一条可以带弧度、带波浪的线；张开时变成一个口。
struct Mouth {
    var center: CGPoint
    var width: CGFloat
    /// 弧度：正数向下鼓（微笑），负数向上鼓（撇嘴），单位点。
    var curve: CGFloat = 0
    /// 波浪的振幅（点）和相位。
    var wave: CGFloat = 0
    var wavePhase: CGFloat = 0
    /// 整张嘴宽度上有几个波浪。
    var waveCycles: CGFloat = 2.5
    /// 张开的高度（点）；0 就是一条线。
    var open: CGFloat = 0
    var lineWidth: CGFloat
    /// 白边的宽度。
    var halo: CGFloat

    func draw(in ctx: CGContext, u: CGFloat) {
        let steps = 18
        func upper(_ i: Int) -> CGPoint {
            let t = CGFloat(i) / CGFloat(steps)
            let bulge = 1 - (2 * t - 1) * (2 * t - 1)
            let y = curve * bulge + wave * sin(t * 2 * .pi * waveCycles + wavePhase)
            return CGPoint(x: center.x + (t - 0.5) * width, y: center.y + y)
        }
        let path = CGMutablePath()
        path.move(to: upper(0))
        for i in 1...steps { path.addLine(to: upper(i)) }

        guard open > 0.4 * u else {
            ctx.strokeWithHalo(path, width: lineWidth, halo: halo)
            return
        }
        // 下唇：从右往左，按半圆的轮廓向下鼓出。
        for i in stride(from: steps, through: 0, by: -1) {
            let t = CGFloat(i) / CGFloat(steps)
            let bulge = sqrt(max(0, 1 - (2 * t - 1) * (2 * t - 1)))
            let p = upper(i)
            path.addLine(to: CGPoint(x: p.x, y: p.y + open * bulge))
        }
        path.closeSubpath()
        ctx.stroke(path, color: Tint.white, width: lineWidth + halo * 2)
        ctx.fill(path, color: Tint.mouthInside)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.fillEllipse(
            center: CGPoint(x: center.x, y: center.y + open * 1.02),
            rx: width * 0.3, ry: open * 0.42, color: Tint.tongue
        )
        ctx.restoreGState()
        ctx.stroke(path, color: Tint.ink, width: lineWidth)
    }
}

// MARK: - 三种风格共用的效果：腮红、汗、泪

enum Effects {
    /// 腮红：一块粉色，可以带三道斜线。
    static func drawBlush(
        in ctx: CGContext, center: CGPoint, rx: CGFloat, ry: CGFloat, amount: CGFloat, hatch: Bool, u: CGFloat
    ) {
        guard amount > 0.01 else { return }
        ctx.fillEllipse(center: center, rx: rx, ry: ry, color: Tint.blush.copy(alpha: 0.82 * amount)!)
        guard hatch, amount > 0.3 else { return }
        let alpha = Kit.smoothstep(0.3, 0.7, amount)
        for i in -1...1 {
            let x = center.x + CGFloat(i) * rx * 0.5
            ctx.strokeLine(
                from: CGPoint(x: x - 0.7 * u, y: center.y + ry * 0.62),
                to: CGPoint(x: x + 0.7 * u, y: center.y - ry * 0.62),
                color: Tint.blushLine.copy(alpha: alpha)!, width: 0.9 * u
            )
        }
    }

    /// 水滴的轮廓：圆底、尖朝上。`center` 是圆底的圆心。
    static func dropPath(center: CGPoint, radius r: CGFloat, tipLength: CGFloat, tilt: CGFloat = 0) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: -tipLength))
        path.addCurve(
            to: CGPoint(x: r, y: 0),
            control1: CGPoint(x: r * 0.2, y: -tipLength * 0.55), control2: CGPoint(x: r, y: -r * 0.75)
        )
        // 画布 y 向下：角度从 0 增加到 π，经过的是圆的下半边。
        path.addArc(center: .zero, radius: r, startAngle: 0, endAngle: .pi, clockwise: false)
        path.addCurve(
            to: CGPoint(x: 0, y: -tipLength),
            control1: CGPoint(x: -r, y: -r * 0.75), control2: CGPoint(x: -r * 0.2, y: -tipLength * 0.55)
        )
        path.closeSubpath()
        var transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: tilt)
        return path.copy(using: &transform)!
    }

    /// 画一滴水（汗珠、飞溅的泪珠）。
    static func drawDrop(
        in ctx: CGContext, center: CGPoint, radius r: CGFloat, tipLength: CGFloat, tilt: CGFloat = 0,
        alpha: CGFloat = 1, u: CGFloat
    ) {
        guard r > 0.2 * u, alpha > 0.02 else { return }
        let path = dropPath(center: center, radius: r, tipLength: tipLength, tilt: tilt)
        ctx.fill(path, color: Tint.water.copy(alpha: alpha)!)
        ctx.stroke(path, color: Tint.waterEdge.copy(alpha: alpha)!, width: 0.9 * u)
        ctx.fillEllipse(
            center: CGPoint(x: center.x - r * 0.32, y: center.y - r * 0.1),
            rx: r * 0.26, ry: r * 0.36, color: Tint.white.copy(alpha: alpha)!
        )
    }

    /// 汗：最多三滴，依次出现在右上、左上、右侧；每滴冒出来、往下滑一小段、淡出，循环往复。
    /// - Parameter reach: 第一滴汗相对脸中心的横、纵距离。
    static func drawSweat(
        in ctx: CGContext, around center: CGPoint, reach: CGSize, amount: CGFloat, u: CGFloat, time: TimeInterval
    ) {
        let drops: [(x: CGFloat, y: CGFloat, size: CGFloat, threshold: CGFloat, phase: Double)] = [
            (1.0, -1.0, 1.0, 0.0, 0.05),
            (-1.04, -0.62, 0.86, 0.35, 0.42),
            (1.16, -0.05, 0.72, 0.62, 0.74),
        ]
        for drop in drops {
            let appear = Kit.smoothstep(drop.threshold, drop.threshold + 0.25, amount)
            guard appear > 0.01 else { continue }
            let cycle = CGFloat(Kit.fract(time / 1.1 + drop.phase))
            let grow = Kit.smoothstep(0, 0.18, cycle)
            let fade = 1 - Kit.smoothstep(0.72, 1.0, cycle)
            let r = 2.4 * u * drop.size * appear * (0.55 + 0.45 * grow)
            let position = CGPoint(
                x: center.x + drop.x * reach.width,
                y: center.y + drop.y * reach.height + cycle * 5.5 * u
            )
            drawDrop(
                in: ctx, center: position, radius: r, tipLength: r * 2.0,
                tilt: drop.x > 0 ? 0.3 : -0.3, alpha: fade, u: u
            )
        }
    }

    /// 一道往下流的泪：一条微微扭动的水带，末端鼓成一滴，下面还有一颗正在掉落的小泪珠。
    /// 先画泪、再画眼睛，这样泪的上端被眼睛盖住。
    /// - Parameters:
    ///   - top: 起点（眼睛下缘附近）的 y。
    ///   - bottom: 泪流满时末端的 y。
    ///   - strength: 0…1，泪有多长。
    static func drawTearStream(
        in ctx: CGContext, x: CGFloat, top: CGFloat, bottom: CGFloat, width w: CGFloat, strength: CGFloat,
        u: CGFloat, time: TimeInterval, phase: Double
    ) {
        guard strength > 0.02 else { return }
        let bulb = w * 0.72
        let end = Kit.lerp(top + bulb * 2 + u, bottom, strength)
        let neck = end - bulb            // 水带到这里为止，再往下是末端的圆滴
        func sway(_ y: CGFloat) -> CGFloat {
            let fadeIn = Kit.smoothstep(0, 5 * u, y - top)
            return CGFloat(sin(Double((y - top) / (12 * u)) * 2 * .pi - time * 2 * .pi * 1.5 + phase)) * w * 0.06 * fadeIn
        }
        let steps = max(Int(((neck - top) / (1.5 * u)).rounded(.up)), 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x - w / 2 + sway(top), y: top))
        for i in 1...steps {
            let y = top + (neck - top) * CGFloat(i) / CGFloat(steps)
            path.addLine(to: CGPoint(x: x - w / 2 + sway(y), y: y))
        }
        let bulbCenter = CGPoint(x: x + sway(neck), y: neck)
        // 画布 y 向下：从 π 减到 0 且 clockwise 为 true，经过的是圆的下半边。
        path.addArc(center: bulbCenter, radius: bulb, startAngle: .pi, endAngle: 0, clockwise: true)
        for i in stride(from: steps, through: 0, by: -1) {
            let y = top + (neck - top) * CGFloat(i) / CGFloat(steps)
            path.addLine(to: CGPoint(x: x + w / 2 + sway(y), y: y))
        }
        path.closeSubpath()
        ctx.fill(path, color: Tint.water)
        ctx.stroke(path, color: Tint.waterEdge, width: 0.9 * u)

        // 水带上往下跑的高光。
        let span = neck - top - 3 * u
        if span > 4 * u {
            for i in 0..<3 {
                let offset = CGFloat(Kit.fract(time * 1.6 + Double(i) / 3 + phase)) * span
                let y = top + 2 * u + offset
                let length = min(3.2 * u, neck - y)
                guard length > 0.8 * u else { continue }
                ctx.strokeLine(
                    from: CGPoint(x: x - w * 0.16 + sway(y), y: y),
                    to: CGPoint(x: x - w * 0.16 + sway(y + length), y: y + length),
                    color: Tint.white, width: max(w * 0.2, 0.7 * u)
                )
            }
        }

        // 末端掉下去的小泪珠。
        let fall = CGFloat(Kit.fract(time / 0.55 + phase * 0.31))
        let dropAlpha = strength * (1 - Kit.smoothstep(0.55, 1.0, fall))
        drawDrop(
            in: ctx, center: CGPoint(x: bulbCenter.x, y: end + 1.5 * u + fall * 4.5 * u),
            radius: 1.25 * u * (1 - 0.3 * fall), tipLength: 2.4 * u, alpha: dropAlpha, u: u
        )
    }

    /// 向外飞溅的泪珠：从眼角抛出去，沿抛物线落下。
    /// - Parameter side: -1 往左飞，+1 往右飞。
    static func drawFlyingTears(
        in ctx: CGContext, from origin: CGPoint, side: CGFloat, strength: CGFloat, u: CGFloat,
        time: TimeInterval, phase: Double
    ) {
        guard strength > 0.02 else { return }
        for i in 0..<2 {
            let cycle = CGFloat(Kit.fract(time / 0.7 + Double(i) * 0.5 + phase))
            let x = origin.x + side * (3 * u + cycle * (9 + CGFloat(i) * 3) * u)
            let y = origin.y - cycle * 11 * u + cycle * cycle * 17 * u
            let alpha = strength * Kit.smoothstep(0.08, 0.3, cycle) * (1 - Kit.smoothstep(0.75, 1.0, cycle))
            // 水滴的尖端指向来的方向。
            let velocity = CGVector(dx: side * 10, dy: -11 + 34 * cycle)
            let tilt = atan2(velocity.dx, -velocity.dy) + .pi
            drawDrop(
                in: ctx, center: CGPoint(x: x, y: y), radius: 1.5 * u, tipLength: 3.0 * u,
                tilt: tilt, alpha: alpha, u: u
            )
        }
    }
}
