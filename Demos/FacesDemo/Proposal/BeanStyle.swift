// FacesDemo · 风格提案 ② 软萌豆豆眼
//
// 两颗小黑豆眼、腮红、一张小嘴，没有眼白。看鼠标时整张脸朝那个方向"转头"。
// 所有墨色的五官外面都包一圈白边，这样在深色图标上也看得清。

import CoreGraphics
import DDMCore
import Foundation

struct BeanStyle: ProposalStyle {
    let title = "② 软萌豆豆眼"
    let tagline = "小黑豆眼 + 腮红 + 小嘴"
    let fileTag = "2-软萌豆豆眼"

    func draw(_ state: FaceState, in iconRect: CGRect, context ctx: CGContext, time: TimeInterval) {
        let u = iconRect.width / 64
        let fear = CGFloat(state.fear)
        let tears = CGFloat(state.tears)
        let blush = CGFloat(state.blush)
        let blink = CGFloat(state.blink)

        var rng = SeededRandom(seed: SeededRandom.derive(state.seed, stream: 0))
        let sizeVariation = 1 + CGFloat(rng.nextUnit() - 0.5) * 0.2
        let gapVariation = CGFloat(rng.nextUnit() - 0.5) * 2.0 * u
        let liftVariation = CGFloat(rng.nextUnit() - 0.5) * 2.0 * u
        let mouthVariation = 1 + CGFloat(rng.nextUnit() - 0.5) * 0.3

        let shake = Kit.trembleOffset(state.tremble, u: u, time: time)
        let rest = CGPoint(
            x: iconRect.midX + shake.dx,
            y: iconRect.minY + iconRect.height * 0.52 + liftVariation + shake.dy
        )
        // 没有眼白，视线靠"转头"表达：五官一起朝目标平移，嘴移得多一点、腮红少一点，有点立体感。
        let turn = Kit.gaze(from: rest, state: state, iconRect: iconRect)
        func shifted(_ x: CGFloat, _ y: CGFloat, depth: CGFloat) -> CGPoint {
            CGPoint(x: rest.x + x + turn.dx * 3.6 * u * depth, y: rest.y + y + turn.dy * 2.8 * u * depth)
        }

        ctx.saveGState()
        defer { ctx.restoreGState() }

        // 哭的时候眼睛压扁成一横，泪从这一横下面挂下来——就是"T_T"。
        let bar = Kit.smoothstep(0.3, 0.8, tears)
        let halo = 1.1 * u
        let eyeY: CGFloat = -2.8 * u
        let eyeX = 8.8 * u + gapVariation

        var eyeCenters: [CGPoint] = []
        for side in [CGFloat(-1), 1] {
            var center = shifted(side * eyeX, eyeY, depth: 1)
            // 每只眼睛再各自朝目标挪一点：目标很近时两眼会往中间凑。
            let own = Kit.gaze(from: center, state: state, iconRect: iconRect)
            center.x += (own.dx - turn.dx) * 2.2 * u
            center.y += (own.dy - turn.dy) * 1.2 * u
            eyeCenters.append(center)
        }

        // 泪先画。
        let stream = Kit.smoothstep(0.4, 0.85, tears)
        for (index, center) in eyeCenters.enumerated() {
            Effects.drawTearStream(
                in: ctx, x: center.x, top: center.y + 0.6 * u,
                bottom: iconRect.maxY + 9 * u, width: 3.8 * u, strength: stream,
                u: u, time: time, phase: Double(index) * 1.7
            )
        }

        // 腮红：平时就有淡淡的一点，害羞时变大变浓、加斜线。
        for side in [CGFloat(-1), 1] {
            Effects.drawBlush(
                in: ctx, center: shifted(side * (14.2 * u + gapVariation), 3.4 * u, depth: 0.8),
                rx: Kit.lerp(3.3, 4.8, blush) * u, ry: Kit.lerp(2.0, 2.9, blush) * u,
                amount: Kit.lerp(0.62, 1.0, blush), hatch: blush > 0.3, u: u
            )
        }

        // 吓得脸发青：额头右上方几道竖线。
        if fear > 0.5 {
            let alpha = Kit.smoothstep(0.5, 0.75, fear)
            let lengths: [CGFloat] = [4.5, 6.5, 5.5, 3.5]
            let path = CGMutablePath()
            for (i, length) in lengths.enumerated() {
                let top = shifted((4.5 + CGFloat(i) * 3.0) * u, -14.5 * u, depth: 0.6)
                path.move(to: top)
                path.addLine(to: CGPoint(x: top.x, y: top.y + length * u))
            }
            ctx.stroke(path, color: Tint.white.copy(alpha: alpha)!, width: 2.6 * u)
            ctx.stroke(path, color: Tint.gloom.copy(alpha: alpha)!, width: 1.1 * u)
        }

        // 眼睛。
        for center in eyeCenters {
            // 平时是一颗竖着的小黑豆；害怕时撑成一个圆圈，中间露出眼白和一点小瞳孔。
            var rx = Kit.lerp(2.7 * sizeVariation, 4.7, fear) * u
            var ry = Kit.lerp(3.3 * sizeVariation, 4.7, fear) * u
            rx = Kit.lerp(rx, 4.6 * u, bar)
            ry = Kit.lerp(ry, 0.95 * u, bar)
            // 眨眼、害羞：压扁。
            ry = max(ry * (1 - blink) * (1 - 0.3 * blush * (1 - bar)), 0.8 * u)

            ctx.fillEllipse(center: center, rx: rx + halo, ry: ry + halo, color: Tint.white)
            ctx.fillEllipse(center: center, rx: rx, ry: ry, color: Tint.ink)

            let ring = Kit.smoothstep(0.1, 0.7, fear) * (1 - bar)
            let innerX = (rx - 1.3 * u) * ring
            let innerY = min((ry - 1.3 * u) * ring, innerX)
            let pupil = Kit.lerp(2.2, 1.1, fear) * u
            if innerY > pupil + 0.3 * u {
                ctx.fillEllipse(center: center, rx: innerX, ry: innerY, color: Tint.white)
                ctx.fillEllipse(center: center, rx: pupil, ry: pupil, color: Tint.ink)
            } else if ry > 1.8 * u {
                // 小高光，让豆豆眼有神。
                let shine = min(rx, ry) * 0.34
                ctx.fillEllipse(
                    center: CGPoint(x: center.x - rx * 0.32, y: center.y - ry * 0.36),
                    rx: shine, ry: shine, color: Tint.white
                )
            }
        }

        // 嘴：平时是小小的微笑；害羞时抿成一道小波浪；害怕时拉长成抖动的波浪；哭的时候张开。
        let open = Kit.smoothstep(0.35, 0.9, tears)
        let upset = max(fear * (1 - open), 0)
        let calm = (1 - fear) * (1 - open)
        Mouth(
            center: shifted(0, Kit.lerp(4.0, 5.2, max(fear, open)) * u, depth: 1.15),
            width: (Kit.lerp(4.6, 3.6, blush) * calm * mouthVariation + 8.5 * upset + 6.2 * open) * u,
            curve: (1.7 * calm * (1 - 0.85 * blush) - 0.9 * open) * u,
            wave: (0.75 * blush * calm + 1.15 * upset) * u,
            wavePhase: CGFloat(time * 16) * (upset > 0.05 ? 1 : 0),
            waveCycles: Kit.lerp(1, 2.5, Kit.smoothstep(0.1, 0.5, max(fear, open))),
            open: 4.6 * u * open * (1 + 0.08 * CGFloat(sin(time * 2 * .pi * 5))),
            lineWidth: 1.4 * u, halo: halo
        ).draw(in: ctx, u: u)

        Effects.drawSweat(
            in: ctx, around: rest, reach: CGSize(width: 21 * u, height: 13 * u),
            amount: CGFloat(state.sweat), u: u, time: time
        )
    }
}
