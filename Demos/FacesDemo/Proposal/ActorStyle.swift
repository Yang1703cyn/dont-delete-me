// FacesDemo · 风格提案 ③ 大眼小嘴（faces 的推荐方向）
//
// 眼睛是主角：略高的椭圆眼眶、又大又黑的瞳孔、两点高光，视线一眼就能看出来。
// 嘴和眉毛是配角：平时只有一个很小的微笑，情绪上来了才"长"出眉毛、嘴才变形——
// 这样桌面上一排平静的脸不显乱，而害怕、大哭又足够夸张。

import CoreGraphics
import DDMCore
import Foundation

struct ActorStyle: ProposalStyle {
    let title = "③ 大眼小嘴"
    let tagline = "亮晶晶的大瞳孔，情绪上来才长出眉毛和嘴"
    let fileTag = "3-大眼小嘴"

    func draw(_ state: FaceState, in iconRect: CGRect, context ctx: CGContext, time: TimeInterval) {
        let u = iconRect.width / 64
        let fear = CGFloat(state.fear)
        let tears = CGFloat(state.tears)
        let blush = CGFloat(state.blush)
        let blink = CGFloat(state.blink)
        let tremble = CGFloat(state.tremble)

        var rng = SeededRandom(seed: SeededRandom.derive(state.seed, stream: 0))
        let sizeVariation = 1 + CGFloat(rng.nextUnit() - 0.5) * 0.14
        let gapVariation = CGFloat(rng.nextUnit() - 0.5) * 1.6 * u
        let liftVariation = CGFloat(rng.nextUnit() - 0.5) * 2.0 * u
        let roundness = CGFloat(rng.nextUnit() - 0.5) * 0.12      // 眼睛偏圆还是偏长
        let mouthVariation = 1 + CGFloat(rng.nextUnit() - 0.5) * 0.3

        let shake = Kit.trembleOffset(state.tremble, u: u, time: time)
        let eyeLine = CGPoint(
            x: iconRect.midX + shake.dx,
            y: iconRect.minY + iconRect.height * 0.47 + liftVariation + shake.dy
        )
        let widen = 1 + 0.12 * fear
        let rx = 7.4 * u * sizeVariation * widen
        let ry = 8.4 * u * sizeVariation * (1 + roundness) * widen
        let halfSpacing = 7.4 * u * sizeVariation + 2.0 * u + gapVariation
        let halo = 1.0 * u

        ctx.saveGState()
        defer { ctx.restoreGState() }

        // 眼皮：眨眼上下一起合；害羞时下眼皮被脸颊顶上来一点（上眼皮耷下来会像"不耐烦"）；
        // 哭的时候下眼皮也被泪顶上来一点。
        let coverTop = 0.575 * blink
        let coverBottom = max(0.425 * blink, 0.2 * blush, 0.1 * tears)

        var eyes: [RoundEye] = []
        for side in [CGFloat(-1), 1] {
            let center = CGPoint(x: eyeLine.x + side * halfSpacing, y: eyeLine.y)
            // 平时瞳孔很大（显得乖）；害怕时缩成一个小点。
            let pupil = Kit.lerp(5.0, 2.0, fear) * u * sizeVariation
            // 泪汪汪时高光变大，并且微微晃动。
            let wobble = 0.06 * tears * CGFloat(sin(time * 2 * .pi * 3 + Double(side)))
            eyes.append(RoundEye(
                center: center, rx: rx, ry: ry,
                coverTop: coverTop, coverBottom: coverBottom,
                pupilRadius: pupil,
                gaze: Kit.gaze(from: center, state: state, iconRect: iconRect),
                outlineWidth: 1.5 * u, lidWidth: 2.0 * u,
                highlights: [
                    (-0.36 + wobble, -0.4, 0.34 + 0.1 * tears),
                    (0.42, 0.4 - wobble, 0.16 + 0.08 * tears),
                ],
                tearPool: Kit.smoothstep(0.05, 0.5, tears),
                poolPhase: CGFloat(time * 5) + side
            ))
        }

        // 泪先画，上端藏在眼睛后面。
        let stream = Kit.smoothstep(0.4, 0.85, tears)
        for (index, eye) in eyes.enumerated() {
            Effects.drawTearStream(
                in: ctx, x: eye.center.x, top: eye.center.y + eye.ry * 0.55,
                bottom: iconRect.maxY + 9 * u, width: 4.6 * u, strength: stream,
                u: u, time: time, phase: Double(index) * 1.7
            )
        }

        // 腮红：眼睛外下方。
        for side in [CGFloat(-1), 1] {
            Effects.drawBlush(
                in: ctx,
                center: CGPoint(x: eyeLine.x + side * (halfSpacing + 5.6 * u), y: eyeLine.y + ry + 1.6 * u),
                rx: 4.2 * u, ry: 2.4 * u, amount: blush, hatch: true, u: u
            )
        }

        for eye in eyes { eye.draw(in: ctx, u: u) }

        // 飞溅的泪珠：从两边眼角抛出去。
        for (index, eye) in eyes.enumerated() {
            let side: CGFloat = index == 0 ? -1 : 1
            Effects.drawFlyingTears(
                in: ctx, from: CGPoint(x: eye.center.x + side * eye.rx * 0.8, y: eye.center.y + eye.ry * 0.2),
                side: side, strength: stream, u: u, time: time, phase: Double(index) * 0.45
            )
        }

        // 眉毛：平时没有；害怕或想哭时长出来，内端上扬（"八字眉"）。
        let worry = max(fear, tears)
        if worry > 0.05 {
            let half = 3.4 * u * Kit.smoothstep(0.05, 0.5, worry)
            let slope = 0.5 * worry
            let path = CGMutablePath()
            for side in [CGFloat(-1), 1] {
                let middle = CGPoint(
                    x: eyeLine.x + side * (halfSpacing + 0.6 * u),
                    y: eyeLine.y - ry - (2.6 + 1.0 * worry) * u
                )
                // side = -1 是左眉：内端在右边。
                path.move(to: CGPoint(x: middle.x + side * half, y: middle.y + half * slope))
                path.addLine(to: CGPoint(x: middle.x - side * half, y: middle.y - half * slope))
            }
            ctx.strokeWithHalo(path, width: 1.7 * u, halo: halo)
        }

        // 嘴：平时一个很小的微笑；害羞抿成小波浪；害怕拉长成抖动的波浪线；哭的时候张大。
        let open = Kit.smoothstep(0.35, 0.9, tears)
        let upset = fear * (1 - open)
        let calm = (1 - fear) * (1 - open)
        Mouth(
            center: CGPoint(x: eyeLine.x, y: eyeLine.y + ry + Kit.lerp(4.6, 3.6, open) * u),
            width: (Kit.lerp(4.8, 3.8, blush) * calm * mouthVariation + 10.5 * upset + 10.0 * open) * u,
            curve: (1.7 * calm * (1 - 0.85 * blush) - 1.3 * open) * u,
            wave: (0.8 * blush * calm + 1.35 * upset) * u,
            wavePhase: CGFloat(time * 16) * (upset > 0.05 ? 1 : 0),
            waveCycles: Kit.lerp(1, 2.5, Kit.smoothstep(0.1, 0.5, max(fear, open))),
            open: 6.8 * u * open * (1 + 0.08 * CGFloat(sin(time * 2 * .pi * 5))),
            lineWidth: 1.5 * u, halo: halo
        ).draw(in: ctx, u: u)

        // 发抖的示意线：脸两侧各两道小弧线。
        if tremble > 0.25 {
            let alpha = Kit.smoothstep(0.25, 0.6, tremble)
            let path = CGMutablePath()
            for side in [CGFloat(-1), 1] {
                for (i, reach) in [CGFloat(21.5), 24.5].enumerated() {
                    let x = iconRect.midX + side * reach * u
                    let half = (3.2 - CGFloat(i) * 0.9) * u
                    let y = eyeLine.y - shake.dy + 9 * u
                    path.move(to: CGPoint(x: x, y: y - half))
                    path.addQuadCurve(
                        to: CGPoint(x: x, y: y + half), control: CGPoint(x: x + side * 1.8 * u, y: y)
                    )
                }
            }
            ctx.stroke(path, color: Tint.white.copy(alpha: alpha)!, width: 1.2 * u + halo * 2)
            ctx.stroke(path, color: Tint.ink.copy(alpha: alpha)!, width: 1.2 * u)
        }

        Effects.drawSweat(
            in: ctx, around: CGPoint(x: eyeLine.x, y: eyeLine.y), reach: CGSize(width: 22 * u, height: 15 * u),
            amount: CGFloat(state.sweat), u: u, time: time
        )
    }
}
