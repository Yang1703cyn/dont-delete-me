// 「别删我」图标生成脚本
//
// 用法（在工程根目录下执行；只需要系统自带的 swift 和 iconutil，不依赖工程里的任何模块）：
//
//     swift Assets/generate_icons.swift final
//
// 生成正式的图标文件（用户选定的是候选 A「哭着求饶的文稿」）：
//
//     Assets/AppIcon.icns              应用图标（打包脚本 scripts/build-app.sh 会自动使用）
//     Assets/AppIcon.iconset/          应用图标的十种规格（16 到 1024 像素），.icns 就是由它们合成的
//     Assets/MenuBarIcon.pdf           菜单栏图标：单色矢量图、透明底（打包脚本会自动使用；应用把它当作模板图，
//                                      颜色由系统按深色 / 浅色菜单栏决定）
//     Assets/预览/图标预览.png          以上两样在各种大小、深浅底色上的样子，给人看的
//
// 其它子命令：
//
//     swift Assets/generate_icons.swift candidates              重新生成当初的 3 个候选样张（写到 Assets/候选/）
//     swift Assets/generate_icons.swift iconset <A|B|C> <目录>   把某个候选画成图标集，写到指定目录（检查用）
//
// 除了 iconset 子命令写到调用者指定的目录以外，脚本只写 Assets/ 里的文件；
// 不读取任何用户文件，不开窗口，不联网。重复运行，生成的文件逐字节相同。
//
// 画法遵循选定的表情风格「大眼小嘴」（规范见 docs/模块说明/faces.md §3）：
// 墨色 #221E2B 的眼眶和大瞳孔、两点高光、很小的嘴；泪和汗是浅蓝填充 + 深蓝描边。
// 应用图标的每种大小都是按该大小单独绘制的（小尺寸会放大五官、加粗线条、省掉次要细节），不是把大图缩小。

import CoreGraphics
import CoreText
import Foundation
import ImageIO

// MARK: - 颜色

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// 与表情模块一致的一套颜色（docs/模块说明/faces.md §3.1）。
enum Ink {
    static let ink = rgb(0x221E2B)
    static let white = rgb(0xFFFFFF)
    static let blush = rgb(0xFF6B8E)
    static let water = rgb(0xC4EEFF)
    static let waterEdge = rgb(0x2B8BDA)
    static let mouthInside = rgb(0x6E1F35)
    static let tongue = rgb(0xFF8FA6)
    static let star = rgb(0xFFD64A)
    static let ghostBlush = rgb(0xFFB3C4)
}

// MARK: - 画布

/// 一块正方形的画布。绘制一律用"设计单位"：整张图标是 1024 × 1024，y 向下。
final class Painter {
    let ctx: CGContext
    /// 画布边长（像素）。
    let px: Int
    /// 每个设计单位是多少像素。
    let k: CGFloat

    init(px: Int) {
        self.px = px
        k = CGFloat(px) / 1024
        ctx = CGContext(
            data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.translateBy(x: 0, y: CGFloat(px))
        ctx.scaleBy(x: k, y: -k)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
    }

    /// 极小尺寸（16 像素）：只留最大的几块形状。
    var tiny: Bool { px <= 16 }
    /// 小尺寸（32 像素及以下）：五官放大、线条加粗、省掉次要细节。
    var small: Bool { px <= 32 }
    /// 中等尺寸（128 像素及以下）：省掉最细的细节。
    var medium: Bool { px <= 128 }

    /// 线宽：设计值，但不细于若干像素。
    func lw(_ design: CGFloat, minPx: CGFloat = 1) -> CGFloat { max(design, minPx / k) }

    func image() -> CGImage { ctx.makeImage()! }

    func fill(_ path: CGPath, _ color: CGColor) {
        ctx.addPath(path)
        ctx.setFillColor(color)
        ctx.fillPath()
    }

    func stroke(_ path: CGPath, _ color: CGColor, width: CGFloat) {
        ctx.addPath(path)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.strokePath()
    }

    /// 墨线；`halo` 为真时外面包一圈白边（风格规范：墨色的线外面都包白边）。
    func inkLine(_ path: CGPath, width: CGFloat, halo: Bool, haloWidth: CGFloat = 0) {
        if halo { stroke(path, Ink.white, width: width + 2 * haloWidth) }
        stroke(path, Ink.ink, width: width)
    }

    func gradient(_ path: CGPath, from top: CGColor, to bottom: CGColor, y0: CGFloat, y1: CGFloat) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let g = CGGradient(colorsSpace: sRGB, colors: [top, bottom] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(
            g, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        ctx.restoreGState()
    }

    /// 投影。偏移和模糊按设计单位给（系统的投影参数是按像素算的，这里换算）。
    func withShadow(dy: CGFloat, blur: CGFloat, alpha: CGFloat, _ body: () -> Void) {
        ctx.saveGState()
        // 画布翻转过，像素坐标里"向下"是负方向。
        ctx.setShadow(offset: CGSize(width: 0, height: -dy * k), blur: blur * k, color: rgb(0x000000, alpha))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}

// MARK: - 形状

/// macOS 应用图标的底板形状（近似）：超椭圆。
func squircle(_ rect: CGRect, n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 480
    for i in 0..<steps {
        let t = 2 * CGFloat.pi * CGFloat(i) / CGFloat(steps)
        let c = cos(t), s = sin(t)
        let point = CGPoint(
            x: rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n),
            y: rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        )
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

/// 水滴：圆底、尖朝上；`center` 是圆底的圆心。
func dropPath(center: CGPoint, radius r: CGFloat, tilt: CGFloat = 0) -> CGPath {
    let path = CGMutablePath()
    let tip = r * 2.0
    let t = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: tilt)
    path.move(to: CGPoint(x: 0, y: -tip), transform: t)
    path.addCurve(
        to: CGPoint(x: r, y: 0), control1: CGPoint(x: r * 0.2, y: -tip * 0.55), control2: CGPoint(x: r, y: -r * 0.75),
        transform: t
    )
    // y 向下：角度从 0 到 π 经过的是圆的下半边。
    path.addArc(center: .zero, radius: r, startAngle: 0, endAngle: .pi, clockwise: false, transform: t)
    path.addCurve(
        to: CGPoint(x: 0, y: -tip), control1: CGPoint(x: -r, y: -r * 0.75), control2: CGPoint(x: -r * 0.2, y: -tip * 0.55),
        transform: t
    )
    path.closeSubpath()
    return path
}

/// 文稿：圆角矩形，右上角折了一个角。以 (0, 0) 为中心。
func documentPath(width w: CGFloat, height h: CGFloat, fold f: CGFloat, corner r: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: -w / 2 + r, y: -h / 2))
    path.addLine(to: CGPoint(x: w / 2 - f, y: -h / 2))
    path.addLine(to: CGPoint(x: w / 2, y: -h / 2 + f))
    path.addLine(to: CGPoint(x: w / 2, y: h / 2 - r))
    path.addQuadCurve(to: CGPoint(x: w / 2 - r, y: h / 2), control: CGPoint(x: w / 2, y: h / 2))
    path.addLine(to: CGPoint(x: -w / 2 + r, y: h / 2))
    path.addQuadCurve(to: CGPoint(x: -w / 2, y: h / 2 - r), control: CGPoint(x: -w / 2, y: h / 2))
    path.addLine(to: CGPoint(x: -w / 2, y: -h / 2 + r))
    path.addQuadCurve(to: CGPoint(x: -w / 2 + r, y: -h / 2), control: CGPoint(x: -w / 2, y: -h / 2))
    path.closeSubpath()
    return path
}

/// 文稿折起来的那个角。
func foldPath(width w: CGFloat, height h: CGFloat, fold f: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let r = f * 0.22
    path.move(to: CGPoint(x: w / 2 - f, y: -h / 2))
    path.addLine(to: CGPoint(x: w / 2 - f, y: -h / 2 + f - r))
    path.addQuadCurve(to: CGPoint(x: w / 2 - f + r, y: -h / 2 + f), control: CGPoint(x: w / 2 - f, y: -h / 2 + f))
    path.addLine(to: CGPoint(x: w / 2, y: -h / 2 + f))
    path.closeSubpath()
    return path
}

/// 幽灵的身体：圆顶、直身、下摆三道波浪。以 (0, 0) 为中心；比例与表情模块的幽灵一致（半宽 14、半高 17）。
func ghostPath(unit g: CGFloat) -> CGPath {
    let a = 14 * g, b = 17 * g, hem = 3.4 * g
    func hemY(_ x: CGFloat) -> CGFloat {
        let wave = cos(Double((x + a) / (2 * a)) * 3 * 2 * .pi)
        return b - hem * 0.5 * (1 + CGFloat(wave))
    }
    let path = CGMutablePath()
    path.move(to: CGPoint(x: -a, y: hemY(-a)))
    path.addLine(to: CGPoint(x: -a, y: -b + a))
    // y 向下：角度从 π 到 2π 经过的是圆的上半边。
    path.addArc(center: CGPoint(x: 0, y: -b + a), radius: a, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
    let steps = 48
    for i in 0...steps {
        let x = a - 2 * a * CGFloat(i) / CGFloat(steps)
        path.addLine(to: CGPoint(x: x, y: hemY(x)))
    }
    path.closeSubpath()
    return path
}

/// 鼠标指针（箭头）。尖端在 (0, 0)，高度为 `size`。
func cursorPath(size s: CGFloat) -> CGPath {
    let points: [(CGFloat, CGFloat)] = [
        (0, 0), (0, 0.80), (0.185, 0.625), (0.325, 0.94), (0.455, 0.885), (0.315, 0.575), (0.57, 0.575),
    ]
    let path = CGMutablePath()
    for (i, p) in points.enumerated() {
        let point = CGPoint(x: p.0 * s, y: p.1 * s)
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

/// 四角星（夜空里的小闪光）。
func sparklePath(center c: CGPoint, radius r: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let q = r * 0.22
    path.move(to: CGPoint(x: c.x, y: c.y - r))
    path.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + q, y: c.y - q))
    path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + q, y: c.y + q))
    path.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - q, y: c.y + q))
    path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - q, y: c.y - q))
    path.closeSubpath()
    return path
}

// MARK: - 脸（「大眼小嘴」）

enum Mouth { case smile, wavy, cry, none }

/// 一张脸的参数。长度单位 u 与表情模块相同（"64 点图标上的 1 点"），这里由调用方给出 u 相当于多少设计单位。
struct Face {
    var u: CGFloat
    /// 视线方向，长度不超过 1：1 表示瞳孔贴到眼眶边上。
    var gaze = CGPoint.zero
    /// 瞳孔半径（u）：平静 4.6，最害怕 2.0。
    var pupil: CGFloat = 4.6
    /// 眼睛瞪大的比例（0…0.12）。
    var widen: CGFloat = 0
    /// 八字眉（0…1）。
    var brows: CGFloat = 0
    var mouth = Mouth.smile
    /// 眼眶里蓄的泪（0…1）。
    var pool: CGFloat = 0
    /// 泪带流到眼眶下缘以下多远（设计单位；0 = 没有泪带）。
    var stream: CGFloat = 0
    /// 泪带的宽度（u）。
    var streamWidth: CGFloat = 4.6
    /// 墨线外面白边的粗细（1 = 规范里的 1.0u）。脸很大时白边显得太重，可以调细。
    var haloScale: CGFloat = 1
    /// 把眼睛画成两颗墨点（只在 16 像素时用）。
    var dotEyes = false
    /// 眼眶轮廓最细不小于多少像素。
    var outlineMinPx: CGFloat = 1
}

extension Painter {
    /// 画脸。`center` 是两眼连线的中点。
    func draw(_ f: Face, at c: CGPoint) {
        let u = f.u
        let rx = 7.6 * u * (1 + f.widen), ry = 8.6 * u * (1 + f.widen)
        let dx = (2.0 + 7.6) * u
        let outline = lw(1.5 * u, minPx: f.outlineMinPx)
        let line = lw(1.6 * u, minPx: 1)
        let halo = lw(1.0 * u * f.haloScale, minPx: 0.75)
        let waterLine = lw(0.9 * u, minPx: 0.75)
        let eyes = [CGPoint(x: c.x - dx, y: c.y), CGPoint(x: c.x + dx, y: c.y)]

        // 1. 泪带（在眼睛下面一层）。
        if f.stream > 0 {
            let w = f.streamWidth * u
            for eye in eyes {
                let top = eye.y + ry * 0.5
                let bottom = eye.y + ry + f.stream
                // 一条微微扭动的带子，末端是圆的（小尺寸不扭，免得糊成一团）。
                let amp = small ? 0 : 0.55 * u
                func sway(_ y: CGFloat) -> CGFloat { amp * sin((y - top) / (15 * u) * 2 * .pi) }
                let end = bottom - w / 2
                let band = CGMutablePath()
                let steps = 28
                for i in 0...steps {
                    let y = top + (end - top) * CGFloat(i) / CGFloat(steps)
                    let point = CGPoint(x: eye.x - w / 2 + sway(y), y: y)
                    if i == 0 { band.move(to: point) } else { band.addLine(to: point) }
                }
                // y 向下：角度从 π 减小到 0 经过的是圆的下半边。
                band.addArc(center: CGPoint(x: eye.x + sway(end), y: end), radius: w / 2, startAngle: .pi, endAngle: 0, clockwise: true)
                for i in (0...steps).reversed() {
                    let y = top + (end - top) * CGFloat(i) / CGFloat(steps)
                    band.addLine(to: CGPoint(x: eye.x + w / 2 + sway(y), y: y))
                }
                band.closeSubpath()
                fill(band, Ink.water)
                stroke(band, Ink.waterEdge, width: waterLine)
                if !medium {
                    // 泪带上的高光，和末端掉下来的小泪珠。
                    let glint = CGMutablePath()
                    let from = eye.y + ry + 2.2 * u, to = bottom - w * 0.9
                    for i in 0...16 {
                        let y = from + (to - from) * CGFloat(i) / 16
                        let point = CGPoint(x: eye.x - w * 0.2 + sway(y), y: y)
                        if i == 0 { glint.move(to: point) } else { glint.addLine(to: point) }
                    }
                    stroke(glint, rgb(0xFFFFFF, 0.9), width: 0.9 * u)
                    let bead = dropPath(center: CGPoint(x: eye.x + sway(end), y: bottom + 3.6 * u), radius: 1.25 * u)
                    fill(bead, Ink.water)
                    stroke(bead, Ink.waterEdge, width: waterLine)
                }
            }
        }

        // 2. 眼睛：眼白 → 泪池 → 瞳孔 → 高光 → 眼眶轮廓。
        if f.dotEyes {
            // 极小尺寸：眼眶、瞳孔、高光挤在三四个像素里只会糊掉，直接画成两颗墨点。
            for eye in eyes {
                fill(CGPath(ellipseIn: CGRect(x: eye.x - rx * 0.66, y: eye.y - ry * 0.7, width: rx * 1.32, height: ry * 1.4), transform: nil), Ink.ink)
            }
        }
        for eye in f.dotEyes ? [] : eyes {
            let socket = CGPath(ellipseIn: CGRect(x: eye.x - rx, y: eye.y - ry, width: 2 * rx, height: 2 * ry), transform: nil)
            fill(socket, Ink.white)

            ctx.saveGState()
            ctx.addPath(socket)
            ctx.clip()

            let r = f.pupil * u
            var g = f.gaze
            let length = hypot(g.x, g.y)
            if length > 1 { g.x /= length; g.y /= length }
            let reachX = max(rx - r - 0.3 * u - outline / 2, 0)
            let reachY = max(ry - r - 0.3 * u - outline / 2, 0)
            let pupil = CGPoint(x: eye.x + g.x * reachX, y: eye.y + g.y * reachY)

            var poolPath: CGPath?
            if f.pool > 0 {
                let level = eye.y + ry - 2 * ry * 0.62 * f.pool
                let p = CGMutablePath()
                p.move(to: CGPoint(x: eye.x - rx, y: level))
                p.addCurve(
                    to: CGPoint(x: eye.x + rx, y: level),
                    control1: CGPoint(x: eye.x - rx * 0.35, y: level + 1.5 * u),
                    control2: CGPoint(x: eye.x + rx * 0.35, y: level - 1.5 * u)
                )
                p.addLine(to: CGPoint(x: eye.x + rx, y: eye.y + ry))
                p.addLine(to: CGPoint(x: eye.x - rx, y: eye.y + ry))
                p.closeSubpath()
                poolPath = p
                fill(p, Ink.water)
            }

            fill(CGPath(ellipseIn: CGRect(x: pupil.x - r, y: pupil.y - r, width: 2 * r, height: 2 * r), transform: nil), Ink.ink)

            if let poolPath {
                // 泪水漫过瞳孔的部分：盖一层半透明的水色，瞳孔还看得见。
                fill(poolPath, rgb(0xC4EEFF, 0.34))
            }

            // 高光：左上一大点，右下一小点（小尺寸只留大的）。
            let big = r * (small ? 0.38 : 0.34)
            fill(
                CGPath(ellipseIn: CGRect(x: pupil.x - r * 0.38 - big, y: pupil.y - r * 0.38 - big, width: 2 * big, height: 2 * big), transform: nil),
                Ink.white
            )
            if !small {
                let tiny = r * 0.16
                fill(
                    CGPath(ellipseIn: CGRect(x: pupil.x + r * 0.42 - tiny, y: pupil.y + r * 0.42 - tiny, width: 2 * tiny, height: 2 * tiny), transform: nil),
                    Ink.white
                )
            }

            if poolPath != nil, !small {
                // 水面那条线。
                let surface = CGMutablePath()
                let y = eye.y + ry - 2 * ry * 0.62 * f.pool
                surface.move(to: CGPoint(x: eye.x - rx, y: y))
                surface.addCurve(
                    to: CGPoint(x: eye.x + rx, y: y),
                    control1: CGPoint(x: eye.x - rx * 0.35, y: y + 1.5 * u),
                    control2: CGPoint(x: eye.x + rx * 0.35, y: y - 1.5 * u)
                )
                stroke(surface, Ink.waterEdge, width: waterLine)
            }
            ctx.restoreGState()

            stroke(socket, Ink.ink, width: outline)
        }

        // 3. 八字眉：外端低、内端高。
        if f.brows > 0 {
            let brows = CGMutablePath()
            for (i, eye) in eyes.enumerated() {
                let side: CGFloat = i == 0 ? -1 : 1
                let y = eye.y - ry - 3.2 * u
                brows.move(to: CGPoint(x: eye.x + side * 3.8 * u, y: y + 1.9 * u * f.brows))
                brows.addLine(to: CGPoint(x: eye.x - side * 2.8 * u, y: y - 1.5 * u * f.brows))
            }
            inkLine(brows, width: line, halo: true, haloWidth: halo)
        }

        // 4. 嘴。
        let my = c.y + 8.6 * u + 4.6 * u
        switch f.mouth {
        case .none:
            break
        case .smile:
            let half = (small ? 3.4 : 2.4) * u
            let smile = CGMutablePath()
            smile.move(to: CGPoint(x: c.x - half, y: my))
            smile.addQuadCurve(to: CGPoint(x: c.x + half, y: my), control: CGPoint(x: c.x, y: my + 3.4 * u * (small ? 1.3 : 1)))
            inkLine(smile, width: line, halo: true, haloWidth: halo)
        case .wavy:
            let half = 4.6 * u, amp = 1.25 * u
            let wave = CGMutablePath()
            let steps = 40
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let point = CGPoint(x: c.x - half + 2 * half * t, y: my + 0.6 * u + amp * sin(t * 2 * .pi * 2.5))
                if i == 0 { wave.move(to: point) } else { wave.addLine(to: point) }
            }
            inkLine(wave, width: line, halo: true, haloWidth: halo)
        case .cry:
            // 哭嚎的嘴：上圆下平、嘴角朝下，露出舌头。
            // （产品里动起来的哭脸是"上平下圆"的；静止的图标上那样容易被看成大笑，所以这里把它倒过来。）
            let half = 4.9 * u, height = 6.6 * u, top = my - 1.6 * u
            let base = top + height
            let mouth = CGMutablePath()
            mouth.move(to: CGPoint(x: c.x - half, y: base))
            mouth.addCurve(
                to: CGPoint(x: c.x, y: top),
                control1: CGPoint(x: c.x - half, y: top + height * 0.3), control2: CGPoint(x: c.x - half * 0.62, y: top)
            )
            mouth.addCurve(
                to: CGPoint(x: c.x + half, y: base),
                control1: CGPoint(x: c.x + half * 0.62, y: top), control2: CGPoint(x: c.x + half, y: top + height * 0.3)
            )
            mouth.addQuadCurve(to: CGPoint(x: c.x - half, y: base), control: CGPoint(x: c.x, y: base - 1.5 * u))
            mouth.closeSubpath()
            stroke(mouth, Ink.white, width: line + 2 * halo)
            fill(mouth, Ink.mouthInside)
            if !small {
                ctx.saveGState()
                ctx.addPath(mouth)
                ctx.clip()
                fill(
                    CGPath(ellipseIn: CGRect(x: c.x - 3.1 * u, y: base - 3.3 * u, width: 6.2 * u, height: 5.0 * u), transform: nil),
                    Ink.tongue
                )
                ctx.restoreGState()
            }
            stroke(mouth, Ink.ink, width: line)
        }
    }

    /// 应用图标的底板：824 × 824 的圆角方块居中，带一点投影（macOS 的图标规格）。
    func tile(top: CGColor, bottom: CGColor) -> CGPath {
        let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = squircle(rect)
        withShadow(dy: 12, blur: 24, alpha: 0.28) {
            fill(shape, bottom)
        }
        gradient(shape, from: top, to: bottom, y0: rect.minY, y1: rect.maxY)
        // 顶部一点点提亮，让底板不那么平。
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        let glow = CGGradient(colorsSpace: sRGB, colors: [rgb(0xFFFFFF, 0.16), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(glow, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.midY), options: [])
        ctx.restoreGState()
        return shape
    }

    func waterDrop(center: CGPoint, radius: CGFloat, tilt: CGFloat, u: CGFloat) {
        let drop = dropPath(center: center, radius: radius, tilt: tilt)
        fill(drop, Ink.water)
        stroke(drop, Ink.waterEdge, width: lw(0.9 * u, minPx: 0.75))
        if !medium {
            let glint = CGMutablePath()
            let t = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: tilt)
            glint.move(to: CGPoint(x: -radius * 0.34, y: -radius * 0.35), transform: t)
            glint.addLine(to: CGPoint(x: -radius * 0.34, y: radius * 0.1), transform: t)
            stroke(glint, Ink.white, width: 0.9 * u)
        }
    }
}

// MARK: - 三个候选

struct Candidate {
    let key: String
    let title: String
    let caption: String
    let pros: String
    let cons: String
    var recommended = false
    let draw: (Painter) -> Void
}

/// A · 哭着求饶的文稿：一张白色文稿放声大哭——就是"别删我"这句话本身。
func drawCandidateA(_ p: Painter) {
    _ = p.tile(top: rgb(0xFF9A7B), bottom: rgb(0xF2565A))

    // 图标越小，文稿和脸占得越满。
    let boost: CGFloat = p.tiny ? 1.32 : (p.small ? 1.22 : (p.medium ? 1.08 : 1))
    let w = 430 * boost, h = 540 * boost, fold = 128 * boost
    let u = 9.6 * boost * (p.small ? 1.1 : 1)
    let center = CGPoint(x: 512, y: p.small ? 506 : 492)
    let outline = p.lw(1.5 * u, minPx: p.tiny ? 0.8 : 1)

    p.ctx.saveGState()
    p.ctx.translateBy(x: center.x, y: center.y)
    p.ctx.rotate(by: (p.tiny ? 0 : -5) * .pi / 180)

    let paper = documentPath(width: w, height: h, fold: fold, corner: 36 * boost)
    p.withShadow(dy: 16, blur: 30, alpha: 0.26) {
        p.fill(paper, Ink.white)
    }
    p.gradient(paper, from: rgb(0xFFFFFF), to: rgb(0xEDEFF5), y0: -h / 2, y1: h / 2)
    let flap = foldPath(width: w, height: h, fold: fold)
    p.gradient(flap, from: rgb(0xE4E6EE), to: rgb(0xCDD1DC), y0: -h / 2, y1: -h / 2 + fold)
    p.stroke(flap, Ink.ink, width: outline)
    p.stroke(paper, Ink.ink, width: outline)

    // 脸：泪汪汪的眼睛、两道泪、八字眉、张嘴哭嚎。
    let eyeY: CGFloat = p.small ? -14 : 6
    var face = Face(u: u)
    face.gaze = CGPoint(x: 0, y: 0.25)
    face.pupil = p.small ? 4.0 : 3.9
    face.widen = 0.06
    face.brows = p.tiny ? 0 : 1
    face.mouth = p.tiny ? .none : .cry
    face.pool = p.small ? 0 : 0.62
    face.stream = h / 2 - eyeY - 8.6 * u + (p.small ? 20 : 56)
    face.streamWidth = p.tiny ? 6.6 : (p.small ? 5.8 : 4.6)
    face.dotEyes = p.tiny
    p.draw(face, at: CGPoint(x: p.tiny ? 0 : -4, y: eyeY))

    if !p.small {
        // 眼角甩出去的泪珠。
        p.waterDrop(center: CGPoint(x: -20.5 * u, y: eyeY - 2.5 * u), radius: 1.9 * u, tilt: -0.9, u: u)
        p.waterDrop(center: CGPoint(x: 20.0 * u, y: eyeY - 4.5 * u), radius: 1.7 * u, tilt: 0.9, u: u)
    }
    p.ctx.restoreGState()
}

/// B · 盯着鼠标的大脸：整块底板就是一张脸，两只大眼睛盯着右上角的鼠标指针。
func drawCandidateB(_ p: Painter) {
    _ = p.tile(top: rgb(0x9E90FF), bottom: rgb(0x6A54EC))

    let u: CGFloat = p.tiny ? 20.5 : (p.small ? 18.2 : (p.medium ? 17.2 : 16.2))
    let center = CGPoint(x: 512, y: p.tiny ? 512 : (p.small ? 548 : 520))

    var face = Face(u: u)
    face.gaze = CGPoint(x: 0.78, y: -0.62)
    face.mouth = p.tiny ? .none : .smile
    face.haloScale = 0.55
    if p.tiny {
        face.pupil = 3.7
        face.outlineMinPx = 0.7
    }
    p.draw(face, at: center)

    // 鼠标指针：黑箭头、白描边，和 macOS 的指针一样。16 像素时放不下，省掉。
    if !p.tiny {
        let size: CGFloat = p.small ? 205 : 190
        let tip = p.small ? CGPoint(x: 705, y: 150) : CGPoint(x: 700, y: 166)
        p.ctx.saveGState()
        p.ctx.translateBy(x: tip.x, y: tip.y)
        let cursor = cursorPath(size: size)
        p.withShadow(dy: 6, blur: 10, alpha: 0.3) {
            p.stroke(cursor, Ink.white, width: p.lw(size * 0.13, minPx: 1.5))
            p.fill(cursor, Ink.white)
        }
        p.fill(cursor, Ink.ink)
        p.ctx.restoreGState()
    }
}

/// C · 飘起来的小幽灵：被删掉的文件原地飘起一个小幽灵——产品里最出人意料的那一下。
func drawCandidateC(_ p: Painter) {
    let shape = p.tile(top: rgb(0x453F86), bottom: rgb(0x1F1B40))

    let g: CGFloat = p.tiny ? 19.5 : (p.small ? 17.5 : (p.medium ? 15.4 : 14.2))
    let center = CGPoint(x: 512, y: p.small ? 512 : 444)

    // 幽灵身后的一团柔光。
    p.ctx.saveGState()
    p.ctx.addPath(shape)
    p.ctx.clip()
    let glow = CGGradient(colorsSpace: sRGB, colors: [rgb(0x8E86FF, 0.5), rgb(0x8E86FF, 0)] as CFArray, locations: [0, 1])!
    p.ctx.drawRadialGradient(
        glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: 400, options: []
    )
    p.ctx.restoreGState()

    if !p.small {
        // 它原来的位置：一个只剩虚线轮廓的文稿。
        p.ctx.saveGState()
        p.ctx.translateBy(x: 512, y: 640)
        let fileOutline = documentPath(width: 340, height: 420, fold: 96, corner: 30)
        p.ctx.addPath(fileOutline)
        p.ctx.setStrokeColor(rgb(0xFFFFFF, p.medium ? 0.45 : 0.38))
        p.ctx.setLineWidth(p.lw(11, minPx: 1))
        p.ctx.setLineDash(phase: 0, lengths: p.medium ? [34, 30] : [30, 26])
        p.ctx.strokePath()
        p.ctx.restoreGState()
        p.ctx.setLineDash(phase: 0, lengths: [])

        // 几颗小闪光。
        for (x, y, r) in [(238.0, 300.0, 30.0), (796.0, 250.0, 22.0), (790.0, 560.0, 16.0)] as [(CGFloat, CGFloat, CGFloat)] {
            p.fill(sparklePath(center: CGPoint(x: x, y: y), radius: p.medium ? r * 1.25 : r), Ink.star)
        }
    }

    p.ctx.saveGState()
    p.ctx.translateBy(x: center.x, y: center.y)
    p.ctx.rotate(by: (p.tiny ? 0 : 5) * .pi / 180)
    let body = ghostPath(unit: g)
    p.withShadow(dy: 14, blur: 26, alpha: 0.3) {
        p.fill(body, Ink.white)
    }
    p.stroke(body, Ink.ink, width: p.lw(1.5 * g, minPx: p.tiny ? 0.8 : 1))

    // 腮红、两只墨色的椭圆眼睛、一张小圆嘴（与产品里的幽灵相同）。
    for side in [CGFloat(-1), 1] {
        p.fill(
            CGPath(ellipseIn: CGRect(x: side * 8.2 * g - 2.5 * g, y: -0.4 * g - 1.5 * g, width: 5.0 * g, height: 3.0 * g), transform: nil),
            Ink.ghostBlush
        )
        let eye = CGRect(x: side * 4.6 * g - 2.0 * g, y: -4.6 * g - 2.8 * g, width: 4.0 * g, height: 5.6 * g)
        p.fill(CGPath(ellipseIn: eye, transform: nil), Ink.ink)
        if !p.medium {
            let r = 0.75 * g
            p.fill(
                CGPath(ellipseIn: CGRect(x: eye.midX - 0.55 * g - r, y: eye.midY - 1.2 * g - r, width: 2 * r, height: 2 * r), transform: nil),
                Ink.white
            )
        }
    }
    if !p.tiny {
        p.fill(CGPath(ellipseIn: CGRect(x: -1.7 * g, y: 1.4 * g, width: 3.4 * g, height: 4.0 * g), transform: nil), Ink.ink)
    }
    p.ctx.restoreGState()
}

let candidates = [
    Candidate(
        key: "A", title: "A · 哭着求饶的文稿", caption: "一张文稿放声大哭——“别删我”这句话本身",
        pros: "优点：不用解释就是“别删我”——文件长了脸、在求饶；暖色在一排蓝色图标里显眼",
        cons: "缺点：细节最多，32 像素以下偏挤；哭脸的情绪偏“惨”",
        recommended: true, draw: drawCandidateA
    ),
    Candidate(
        key: "B", title: "B · 盯着鼠标的大脸", caption: "整块底板就是一张脸，眼睛盯着鼠标指针",
        pros: "优点：最干净，最贴「大眼小嘴」的平静表情；直接演示“眼睛跟着鼠标”",
        cons: "缺点：看不出和“文件”“删除”有关；盯鼠标的眼睛类小工具已有不少",
        draw: drawCandidateB
    ),
    Candidate(
        key: "C", title: "C · 飘起来的小幽灵", caption: "被删的文件原地飘起小幽灵——产品里的那个包袱",
        pros: "优点：轮廓最好认，16 像素也清楚；最讨喜",
        cons: "缺点：看不出“图标长了脸”；把“删了会变幽灵”的包袱提前抖了",
        draw: drawCandidateC
    ),
]

func render(_ candidate: Candidate, px: Int) -> CGImage {
    let painter = Painter(px: px)
    candidate.draw(painter)
    return painter.image()
}

// MARK: - 样张

/// 一张普通的画布（单位是像素，y 向下），用来拼样张。
final class Sheet {
    let ctx: CGContext
    let width: Int, height: Int

    init(width: Int, height: Int, background: CGColor) {
        self.width = width
        self.height = height
        ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(background)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }

    func panel(_ rect: CGRect, _ color: CGColor, radius: CGFloat) {
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(color)
        ctx.fillPath()
    }

    /// 贴一张图。`pixelated` 为真时逐像素放大（不做平滑），用来看清小尺寸的每个像素。
    func image(_ image: CGImage, in rect: CGRect, pixelated: Bool = false) {
        ctx.saveGState()
        ctx.interpolationQuality = pixelated ? .none : .high
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    enum Align { case left, center }

    /// 写一行字。`y` 是这行字的基线。
    func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, color: CGColor, bold: Bool = false, align: Align = .left) {
        let font = CTFontCreateWithName((bold ? "PingFangSC-Semibold" : "PingFangSC-Regular") as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: align == .center ? x - width / 2 : x, y: y)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    func write(to url: URL) throws {
        try writePNG(ctx.makeImage()!, to: url)
    }
}

struct IconError: Error, CustomStringConvertible {
    let description: String
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw IconError(description: "无法创建文件：\(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw IconError(description: "写入失败：\(url.path)")
    }
}

let lightChip = rgb(0xE9ECF2)
let darkChip = rgb(0x1F2026)
let textColor = rgb(0x1D1D22)
let subtleText = rgb(0x6B6B76)

/// 对比样张：三列，每列一个候选；上面是 1024 像素原大，下面是 128、32 像素在浅色和深色底上的样子。
func makeComparisonSheet() -> Sheet {
    let margin: CGFloat = 80, column: CGFloat = 1024, gap: CGFloat = 80
    let width = Int(margin * 2 + column * 3 + gap * 2)
    let sheet = Sheet(width: width, height: 1880, background: rgb(0xF6F6F8))

    sheet.text("「别删我」应用图标候选 · 表情风格「大眼小嘴」", x: margin, y: 96, size: 54, color: textColor, bold: true)
    sheet.text(
        "每个候选的三种大小都是按该大小单独绘制的（小尺寸放大了五官、加粗了线条、省掉了次要细节），不是把大图缩小。标着“原大”的都是 1 比 1。",
        x: margin, y: 150, size: 28, color: subtleText
    )

    for (i, candidate) in candidates.enumerated() {
        let x = margin + CGFloat(i) * (column + gap)
        sheet.text(candidate.title, x: x, y: 244, size: 44, color: textColor, bold: true)
        if candidate.recommended {
            let tag = CGRect(x: x + column - 250, y: 200, width: 250, height: 58)
            sheet.panel(tag, rgb(0x221E2B), radius: 29)
            sheet.text("release 的推荐", x: tag.midX, y: tag.minY + 40, size: 28, color: rgb(0xFFFFFF), bold: true, align: .center)
        }
        sheet.text(candidate.caption, x: x, y: 292, size: 27, color: subtleText)

        // 1024 像素，原大。
        let big = CGRect(x: x, y: 330, width: column, height: column)
        sheet.panel(big, rgb(0xE4E8EF), radius: 36)
        sheet.image(render(candidate, px: 1024), in: big)
        sheet.text("1024 像素（原大）", x: x + 24, y: big.minY + 48, size: 26, color: subtleText)

        // 128、32 像素：浅色底、深色底各一份；32 像素另有放大 4 倍的。
        let rowY = big.maxY + 90
        sheet.text("128 像素（原大）", x: x, y: rowY - 18, size: 26, color: subtleText)
        sheet.text("32 像素（原大）", x: x + 432, y: rowY - 18, size: 26, color: subtleText)
        sheet.text("32 像素 · 放大 4 倍", x: x + 664, y: rowY - 18, size: 26, color: subtleText)

        let icon128 = render(candidate, px: 128)
        let icon32 = render(candidate, px: 32)
        var cursor = x
        for chip in [lightChip, darkChip] {
            let rect = CGRect(x: cursor, y: rowY, width: 200, height: 200)
            sheet.panel(rect, chip, radius: 20)
            sheet.image(icon128, in: CGRect(x: rect.midX - 64, y: rect.midY - 64, width: 128, height: 128))
            cursor += 216
        }
        for chip in [lightChip, darkChip] {
            let rect = CGRect(x: cursor, y: rowY, width: 100, height: 200)
            sheet.panel(rect, chip, radius: 20)
            sheet.image(icon32, in: CGRect(x: rect.midX - 16, y: rect.midY - 16, width: 32, height: 32))
            cursor += 116
        }
        for chip in [lightChip, darkChip] {
            let rect = CGRect(x: cursor, y: rowY, width: 172, height: 200)
            sheet.panel(rect, chip, radius: 20)
            sheet.image(icon32, in: CGRect(x: rect.midX - 64, y: rect.midY - 64, width: 128, height: 128), pixelated: true)
            cursor += 188
        }

        sheet.text(candidate.pros, x: x, y: rowY + 262, size: 26, color: textColor)
        sheet.text(candidate.cons, x: x, y: rowY + 304, size: 26, color: textColor)
    }

    sheet.text(
        "这个应用不出现在程序坞，图标多半以小尺寸露面（访达的列表、系统设置里的应用列表等），所以 32 像素认不认得出很要紧。16 像素的效果见同目录的“小尺寸放大.png”。",
        x: margin, y: 1826, size: 26, color: subtleText
    )
    return sheet
}

/// 小尺寸检查图：每个候选一行；16 / 32 / 64 像素逐像素放大到 192 像素，128 像素原大；
/// 每组最右边一列是 16 / 32 / 64 像素的原大。浅色底、深色底各一组。
func makeSmallSizeSheet() -> Sheet {
    let sizes: [(px: Int, zoom: Int)] = [(16, 12), (32, 6), (64, 3), (128, 1)]
    let cell: CGFloat = 192, gap: CGFloat = 12, margin: CGFloat = 40, rowHeight: CGFloat = 300, actual: CGFloat = 84
    let groupWidth = CGFloat(sizes.count) * (cell + gap) + actual
    let width = Int(margin * 2 + groupWidth * 2 + 40)
    let sheet = Sheet(width: width, height: Int(210 + rowHeight * CGFloat(candidates.count)), background: rgb(0xF6F6F8))
    sheet.text("小尺寸检查：逐像素放大（不做平滑）", x: margin, y: 68, size: 38, color: textColor, bold: true)
    sheet.text(
        "16、32、64 像素分别放大 12、6、3 倍，128 像素是原大；每组最右边一列是 16、32、64 像素的原大。左组浅色底，右组深色底。",
        x: margin, y: 112, size: 24, color: subtleText
    )
    for (i, candidate) in candidates.enumerated() {
        let y = 190 + CGFloat(i) * rowHeight
        sheet.text(candidate.title, x: margin, y: y - 16, size: 28, color: textColor, bold: true)
        let images = Dictionary(uniqueKeysWithValues: sizes.map { ($0.px, render(candidate, px: $0.px)) })
        for (group, chip) in [lightChip, darkChip].enumerated() {
            let x0 = margin + CGFloat(group) * (groupWidth + 40)
            for (j, size) in sizes.enumerated() {
                let rect = CGRect(x: x0 + CGFloat(j) * (cell + gap), y: y, width: cell, height: cell)
                sheet.panel(rect, chip, radius: 14)
                let side = CGFloat(size.px * size.zoom)
                sheet.image(
                    images[size.px]!,
                    in: CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side),
                    pixelated: true
                )
                sheet.text(
                    size.zoom == 1 ? "\(size.px) 像素" : "\(size.px) 像素 ×\(size.zoom)",
                    x: rect.midX, y: rect.maxY + 34, size: 22, color: subtleText, align: .center
                )
            }
            // 原大的一列：16、32、64 像素从上到下。
            let column = CGRect(x: x0 + CGFloat(sizes.count) * (cell + gap), y: y, width: actual, height: cell)
            sheet.panel(column, chip, radius: 14)
            var top = column.minY + 16
            for px in [16, 32, 64] {
                let side = CGFloat(px)
                sheet.image(images[px]!, in: CGRect(x: column.midX - side / 2, y: top, width: side, height: side))
                top += side + 16
            }
            sheet.text("原大", x: column.midX, y: column.maxY + 34, size: 22, color: subtleText, align: .center)
        }
    }
    return sheet
}

// MARK: - 菜单栏图标

/// 菜单栏图标：一双看向右上方的大眼睛。单色、透明底，只有形状——应用把它当作模板图，颜色由系统决定。
/// 画布 27 × 18 点（应用会按比例缩到 18 点高；宽高都取整数，系统读入时才不会把它拉伸），y 向下。全部用"填充"画成（眼眶是两个椭圆之间的环），
/// 这样无论谁来渲染结果都一样。
enum MenuBarGlyph {
    static let size = CGSize(width: 27, height: 18)

    /// 若干块形状；每一块都按"奇偶规则"填充（所以大椭圆套小椭圆 = 一个环，圆里套小圆 = 带一个透明的高光）。
    static func shapes() -> [CGPath] {
        var result: [CGPath] = []
        let stroke: CGFloat = 1.6
        let rx: CGFloat = 5.0, ry: CGFloat = 6.3          // 眼眶线条中心所在的椭圆
        let pupil: CGFloat = 3.0, highlight: CGFloat = 0.95
        for centerX in [size.width / 2 - 6.4, size.width / 2 + 6.4] {
            let center = CGPoint(x: centerX, y: size.height / 2)
            let ring = CGMutablePath()
            ring.addEllipse(in: CGRect(
                x: center.x - rx - stroke / 2, y: center.y - ry - stroke / 2,
                width: 2 * rx + stroke, height: 2 * ry + stroke
            ))
            ring.addEllipse(in: CGRect(
                x: center.x - rx + stroke / 2, y: center.y - ry + stroke / 2,
                width: 2 * rx - stroke, height: 2 * ry - stroke
            ))
            result.append(ring)

            // 瞳孔偏向右上方，贴近眼眶；里面留一个透明的小圆当高光。
            let p = CGPoint(x: center.x + 1.0, y: center.y - 1.35)
            let dot = CGMutablePath()
            dot.addEllipse(in: CGRect(x: p.x - pupil, y: p.y - pupil, width: 2 * pupil, height: 2 * pupil))
            dot.addEllipse(in: CGRect(
                x: p.x - 1.05 - highlight, y: p.y - 1.05 - highlight, width: 2 * highlight, height: 2 * highlight
            ))
            result.append(dot)
        }
        return result
    }

    /// 画到一块画布上（画布的坐标已经是 y 向下、1 单位 = 1 点）。
    static func draw(in ctx: CGContext, color: CGColor) {
        ctx.setFillColor(color)
        for shape in shapes() {
            ctx.addPath(shape)
            ctx.fillPath(using: .evenOdd)
        }
    }

    /// 写成一个只有一页的 PDF。
    /// 不用系统的 PDF 画布，而是自己写出文件内容：系统的画布会往文件里写入生成时间，每次运行文件都不一样；
    /// 自己写的话内容完全确定，重复运行逐字节相同。
    static func pdfData() -> Data {
        func number(_ value: CGFloat) -> String {
            var text = String(format: "%.4f", Double(value))
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
            return text == "-0" ? "0" : text
        }
        // PDF 的 y 向上，这里把 y 翻过来。
        func point(_ p: CGPoint) -> String { "\(number(p.x)) \(number(size.height - p.y))" }

        var content = "0 g\n"
        for shape in shapes() {
            var current = CGPoint.zero
            shape.applyWithBlock { element in
                let e = element.pointee
                switch e.type {
                case .moveToPoint:
                    current = e.points[0]
                    content += "\(point(current)) m\n"
                case .addLineToPoint:
                    current = e.points[0]
                    content += "\(point(current)) l\n"
                case .addQuadCurveToPoint:
                    // 二次曲线换算成三次曲线。
                    let control = e.points[0], end = e.points[1]
                    let c1 = CGPoint(x: current.x + 2 / 3 * (control.x - current.x), y: current.y + 2 / 3 * (control.y - current.y))
                    let c2 = CGPoint(x: end.x + 2 / 3 * (control.x - end.x), y: end.y + 2 / 3 * (control.y - end.y))
                    content += "\(point(c1)) \(point(c2)) \(point(end)) c\n"
                    current = end
                case .addCurveToPoint:
                    content += "\(point(e.points[0])) \(point(e.points[1])) \(point(e.points[2])) c\n"
                    current = e.points[2]
                case .closeSubpath:
                    content += "h\n"
                @unknown default:
                    break
                }
            }
            content += "f*\n"
        }

        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(number(size.width)) \(number(size.height))] /Contents 4 0 R /Resources << >> >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream",
        ]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            pdf += String(format: "%010d 00000 n \n", offset)
        }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(pdf.utf8)
    }

    /// 按给定的像素高度画成位图（预览用）：`scale` 是每点多少像素。
    static func bitmap(scale: CGFloat, color: CGColor) -> CGImage {
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        draw(in: ctx, color: color)
        return ctx.makeImage()!
    }
}

// MARK: - 正式图标

/// 用户选定的应用图标。
let chosenCandidateKey = "A"

/// 预览图：应用图标的各种大小 + 菜单栏图标在浅色、深色菜单栏上的样子。
func makeFinalPreviewSheet() -> Sheet {
    let candidate = candidates.first { $0.key == chosenCandidateKey }!
    let margin: CGFloat = 60
    let sheet = Sheet(width: 1900, height: 1500, background: rgb(0xF6F6F8))
    sheet.text("「别删我」正式图标预览", x: margin, y: 84, size: 46, color: textColor, bold: true)
    sheet.text(
        "应用图标：\(candidate.title)。菜单栏图标：一双看向右上方的大眼睛（单色，颜色由系统按菜单栏的深浅决定）。",
        x: margin, y: 132, size: 26, color: subtleText
    )

    // 应用图标：512 像素一张大的；256 / 128 / 64 / 32 / 16 像素原大，浅色底和深色底各一排。
    sheet.text("应用图标", x: margin, y: 210, size: 34, color: textColor, bold: true)
    let big = CGRect(x: margin, y: 236, width: 560, height: 560)
    sheet.panel(big, lightChip, radius: 28)
    sheet.image(render(candidate, px: 512), in: CGRect(x: big.midX - 256, y: big.midY - 256, width: 512, height: 512))
    sheet.text("512 像素（原大）", x: big.minX + 20, y: big.minY + 40, size: 22, color: subtleText)

    let sizes = [256, 128, 64, 32, 16]
    for (row, chip) in [lightChip, darkChip].enumerated() {
        let rect = CGRect(x: 660, y: 236 + CGFloat(row) * 290, width: 1180, height: 270)
        sheet.panel(rect, chip, radius: 28)
        var x = rect.minX + 40
        for px in sizes {
            let side = CGFloat(px)
            sheet.image(render(candidate, px: px), in: CGRect(x: x, y: rect.midY - side / 2, width: side, height: side))
            x += side + 40
        }
        // 32 和 16 像素另外逐像素放大一份。
        for (px, zoom) in [(32, 5), (16, 10)] {
            let side = CGFloat(px * zoom)
            sheet.image(render(candidate, px: px), in: CGRect(x: x + 20, y: rect.midY - side / 2, width: side, height: side), pixelated: true)
            x += side + 30
        }
    }
    sheet.text(
        "每排从左到右：256 / 128 / 64 / 32 / 16 像素原大；再往右是 32 像素放大 5 倍、16 像素放大 10 倍。",
        x: 660, y: 846, size: 22, color: subtleText
    )

    // 菜单栏图标。
    let top: CGFloat = 930
    sheet.text("菜单栏图标", x: margin, y: top, size: 34, color: textColor, bold: true)
    sheet.text(
        "上：浅色菜单栏；下：深色菜单栏。每条从左到右：普通屏（18 像素高）原大、高清屏（36 像素高）原大，然后各放大 8 倍和 4 倍。",
        x: margin, y: top + 40, size: 22, color: subtleText
    )
    let bars: [(bar: CGColor, glyph: CGColor)] = [(rgb(0xECECEE), rgb(0x1D1D1F)), (rgb(0x2A2A2E), rgb(0xFFFFFF))]
    for (row, colors) in bars.enumerated() {
        let rect = CGRect(x: margin, y: top + 66 + CGFloat(row) * 220, width: 1780, height: 200)
        sheet.panel(rect, colors.bar, radius: 20)
        var x = rect.minX + 50
        for (scale, zoom) in [(1, 1), (2, 1), (1, 8), (2, 4)] as [(CGFloat, CGFloat)] {
            let image = MenuBarGlyph.bitmap(scale: scale, color: colors.glyph)
            let w = CGFloat(image.width) * zoom, h = CGFloat(image.height) * zoom
            sheet.image(image, in: CGRect(x: x, y: rect.midY - h / 2, width: w, height: h), pixelated: zoom > 1)
            x += w + 90
        }
        // 再放一份平滑的大图，看形状本身。
        let large = MenuBarGlyph.bitmap(scale: 9, color: colors.glyph)
        sheet.image(large, in: CGRect(x: rect.maxX - 50 - CGFloat(large.width), y: rect.midY - CGFloat(large.height) / 2, width: CGFloat(large.width), height: CGFloat(large.height)))
    }
    sheet.text(
        "最右边是形状本身（放大 9 倍）。暂停时图标由系统变淡，这里没有画。",
        x: margin, y: top + 66 + 2 * 220 + 20, size: 22, color: subtleText
    )
    return sheet
}

func generateFinal() throws {
    let iconset = assetsDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
    try generateIconset(key: chosenCandidateKey, directory: iconset)

    // 用系统自带的 iconutil 把图标集合成 .icns。
    let icns = assetsDirectory.appendingPathComponent("AppIcon.icns")
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        throw IconError(description: "iconutil 失败，退出码 \(iconutil.terminationStatus)")
    }
    print("已生成 \(icns.path)")

    let menuBar = assetsDirectory.appendingPathComponent("MenuBarIcon.pdf")
    try MenuBarGlyph.pdfData().write(to: menuBar)
    print("已生成 \(menuBar.path)")

    let previewDirectory = assetsDirectory.appendingPathComponent("预览", isDirectory: true)
    try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
    let preview = previewDirectory.appendingPathComponent("图标预览.png")
    try makeFinalPreviewSheet().write(to: preview)
    print("已生成 \(preview.path)")
}

// MARK: - 入口

let assetsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

func generateCandidates() throws {
    let directory = assetsDirectory.appendingPathComponent("候选", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let comparison = directory.appendingPathComponent("应用图标候选.png")
    try makeComparisonSheet().write(to: comparison)
    print("已生成 \(comparison.path)")

    let smallSizes = directory.appendingPathComponent("小尺寸放大.png")
    try makeSmallSizeSheet().write(to: smallSizes)
    print("已生成 \(smallSizes.path)")

    for candidate in candidates {
        let url = directory.appendingPathComponent("candidate-\(candidate.key)-1024.png")
        try writePNG(render(candidate, px: 1024), to: url)
        print("已生成 \(url.path)")
    }
}

/// macOS 图标集的十种规格：文件名 → 像素边长。
let iconsetEntries: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

func generateIconset(key: String, directory: URL) throws {
    guard let candidate = candidates.first(where: { $0.key == key.uppercased() }) else {
        throw IconError(description: "没有这个候选：\(key)（可选：\(candidates.map(\.key).joined(separator: "、"))）")
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for entry in iconsetEntries {
        try writePNG(render(candidate, px: entry.px), to: directory.appendingPathComponent(entry.name))
    }
    print("已生成 \(directory.path)（\(iconsetEntries.count) 个文件）")
}

let usage = """
用法：
  swift Assets/generate_icons.swift final                   生成正式图标：AppIcon.icns、AppIcon.iconset/、MenuBarIcon.pdf、预览图
  swift Assets/generate_icons.swift candidates              重新生成 3 个候选的样张（写到 Assets/候选/）
  swift Assets/generate_icons.swift iconset <A|B|C> <目录>   把一个候选画成图标集，写到指定目录
"""

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "final" where arguments.count == 1:
        try generateFinal()
    case "candidates" where arguments.count == 1:
        try generateCandidates()
    case "iconset" where arguments.count == 3:
        try generateIconset(key: arguments[1], directory: URL(fileURLWithPath: arguments[2], isDirectory: true))
    default:
        print(usage)
        exit(arguments.isEmpty ? 0 : 2)
    }
} catch {
    print("出错：\(error)")
    exit(1)
}
