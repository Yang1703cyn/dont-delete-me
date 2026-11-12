// FacesDemo · 风格提案 ① 经典大眼睛
//
// 像贴在东西上的"活动眼珠"：两只圆圆的白眼球、黑瞳孔，除了眼睛什么都没有。
// 情绪全靠眼睛本身（大小、瞳孔、眼皮）加上脸外面的效果（腮红、汗、泪）来表达。

import CoreGraphics
import DDMCore
import Foundation

struct GooglyStyle: ProposalStyle {
    let title = "① 经典大眼睛"
    let tagline = "白眼球 + 黑瞳孔，只有眼睛"
    let fileTag = "1-经典大眼睛"

    func draw(_ state: FaceState, in iconRect: CGRect, context ctx: CGContext, time: TimeInterval) {
        let u = iconRect.width / 64
        let fear = CGFloat(state.fear)
        let tears = CGFloat(state.tears)
        let blush = CGFloat(state.blush)
        let blink = CGFloat(state.blink)

        // 长相：眼睛大小、间距、高低、左右眼大小差，都由长相种子决定。
        var rng = SeededRandom(seed: SeededRandom.derive(state.seed, stream: 0))
        let sizeVariation = 1 + CGFloat(rng.nextUnit() - 0.5) * 0.14
        let gapVariation = CGFloat(rng.nextUnit() - 0.5) * 1.6 * u
        let liftVariation = CGFloat(rng.nextUnit() - 0.5) * 2.0 * u
        let unevenness = CGFloat(rng.nextUnit() - 0.5) * 0.10

        let shake = Kit.trembleOffset(state.tremble, u: u, time: time)
        let faceCenter = CGPoint(
            x: iconRect.midX + shake.dx,
            y: iconRect.minY + iconRect.height * 0.5 + liftVariation + shake.dy
        )
        let baseRadius = 9.0 * u * sizeVariation
        let halfSpacing = baseRadius + 0.9 * u + gapVariation

        ctx.saveGState()
        defer { ctx.restoreGState() }

        // 眼皮：眨眼时上下一起合；害羞时下眼皮被脸颊顶上来一点（上眼皮耷下来会像"不耐烦"）。
        let coverTop = 0.575 * blink
        let coverBottom = max(0.425 * blink, 0.2 * blush)

        var eyes: [RoundEye] = []
        for side in [CGFloat(-1), 1] {
            // 害怕时眼睛瞪大、瞳孔缩小；泪汪汪时瞳孔略放大。
            let radius = baseRadius * (1 + side * unevenness * 0.5) * (1 + 0.13 * fear)
            let center = CGPoint(x: faceCenter.x + side * halfSpacing, y: faceCenter.y)
            let pupil = radius * Kit.lerp(0.5, 0.24, fear) * (1 + 0.12 * tears * (1 - fear))
            eyes.append(RoundEye(
                center: center, rx: radius, ry: radius,
                coverTop: coverTop, coverBottom: coverBottom,
                pupilRadius: pupil,
                gaze: Kit.gaze(from: center, state: state, iconRect: iconRect),
                outlineWidth: 1.5 * u, lidWidth: 1.7 * u,
                highlights: [(-0.36, -0.38, 0.3 * (1 - fear) + 0.12 * tears)],
                tearPool: Kit.smoothstep(0.05, 0.5, tears),
                poolPhase: CGFloat(time * 5) + side
            ))
        }

        // 泪先画，上端藏在眼睛后面。
        let stream = Kit.smoothstep(0.4, 0.85, tears)
        for (index, eye) in eyes.enumerated() {
            Effects.drawTearStream(
                in: ctx, x: eye.center.x, top: eye.center.y + eye.ry * 0.6,
                bottom: iconRect.maxY + 9 * u, width: 5.2 * u, strength: stream,
                u: u, time: time, phase: Double(index) * 1.7
            )
        }

        for eye in eyes {
            // 一小块影子，让眼睛像是"贴"在图标上。
            // 影子跟着睁开的那一段走：眼皮盖住的部分没有影子。
            let band = eye.openBand
            ctx.fillEllipse(
                center: CGPoint(x: eye.center.x, y: (band.top + band.bottom) / 2 + 1.3 * u),
                rx: eye.rx + 0.6 * u, ry: (band.bottom - band.top) / 2 + 0.6 * u,
                color: Tint.ink.copy(alpha: 0.2)!
            )
            eye.draw(in: ctx, u: u)
        }

        // 腮红：没有脸，就画在两只眼睛的外下方。
        for eye in eyes {
            let side: CGFloat = eye.center.x < faceCenter.x ? -1 : 1
            Effects.drawBlush(
                in: ctx,
                center: CGPoint(x: eye.center.x + side * 3.5 * u, y: eye.center.y + eye.ry + 3.4 * u),
                rx: 4.6 * u, ry: 2.5 * u, amount: blush, hatch: true, u: u
            )
        }

        Effects.drawSweat(
            in: ctx, around: faceCenter, reach: CGSize(width: 23 * u, height: 14 * u),
            amount: CGFloat(state.sweat), u: u, time: time
        )
    }
}
