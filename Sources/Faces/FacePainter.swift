// Faces · 绘制：照着姿态把脸画到画布上
//
// 为了快，同一种颜色的东西尽量攒成一条路径、一次画完：
//   水（泪流 + 泪珠 + 汗珠）→ 腮红 → 眼睛 → 墨线（眉毛 + 嘴 + 发抖线 + Zzz）→ 张开的嘴 → 星星 → 手
// 最常见的"平静、只是视线在变"只有 5 次填充或描边，不做裁剪。
//
// 画布约定：y 向下、单位点。不改动画布的状态（调用方 FaceRenderer.draw 已经成对地保存 / 恢复）。

import CoreGraphics
import DDMCore
import Foundation

struct FacePainter {
    let pose: FacePose
    let context: CGContext

    func paint() {
        context.setLineCap(.round)
        context.setLineJoin(.round)
        paintWater()
        paintBlush()
        paintEyes()
        let mouth = MouthShape(pose: pose)
        paintInkLines(mouth: mouth)
        paintOpenMouth(mouth)
        paintStars()
        paintHands()
    }

    // MARK: - 水：泪流、泪珠、汗珠

    private func paintWater() {
        let p = pose.params
        guard pose.stream > 0 || p.sweat > 0 else { return }
        let u = pose.u
        let water = CGMutablePath()
        // 水面上的白色高光：都是短线，最后一起描。
        let glints = CGMutablePath()

        if pose.stream > 0 {
            for (index, eye) in pose.eyes.enumerated() {
                addTearStream(below: eye, phase: pose.look.phase + Double(index) * 0.27, to: water, glints: glints)
            }
            // 哭得最凶时，两边眼角各甩出一颗泪珠。小图标上省掉。
            if pose.fine, pose.splash > 0 {
                for eye in pose.eyes {
                    let cycle = CGFloat(FaceMath.fract(pose.time / 0.7 + pose.look.phase + Double(eye.side) * 0.22))
                    let startX = eye.center.x + eye.side * (eye.rx * 0.8 + 2 * u)
                    let endX = pose.rect.midX + eye.side * pose.rect.width * 0.42
                    let center = CGPoint(
                        x: FaceMath.lerp(startX, endX, cycle),
                        y: eye.center.y + eye.ry * 0.2 - cycle * 9 * u + cycle * cycle * 15 * u
                    )
                    let size = FaceMath.smoothstep(0.05, 0.25, cycle) * (1 - FaceMath.smoothstep(0.75, 1, cycle))
                    // 水滴的尖端拖在后面（指向来的方向）。
                    let velocity = CGVector(dx: endX - startX, dy: (-9 + 30 * cycle) * u)
                    FaceShapes.addDrop(
                        to: water, glints: glints, center: center, radius: 1.5 * u * pose.splash * size,
                        tilt: atan2(-velocity.dx, velocity.dy), u: u
                    )
                }
            }
        }

        if p.sweat > 0 {
            // 已经在流泪时汗就少画一点：画面上的水太多会乱。
            let amount = p.sweat * (1 - 0.6 * pose.stream)
            // 最多三滴，依次出现在右上、左上、右侧；位置按图标矩形的比例给，保证不出图标矩形。
            let drops: [(x: CGFloat, y: CGFloat, size: CGFloat, threshold: CGFloat, phase: Double)] = [
                (0.35, -0.22, 1.0, 0.0, 0.05),
                (-0.36, -0.13, 0.86, 0.35, 0.42),
                (0.40, -0.01, 0.72, 0.62, 0.74),
            ]
            for (index, drop) in drops.enumerated() where pose.fine || index < 2 {
                let appear = FaceMath.smoothstep(drop.threshold, drop.threshold + 0.25, amount)
                guard appear > 0.01 else { continue }
                // 一滴汗：冒出来、往下滑一小段、缩没，循环往复。
                let cycle = CGFloat(FaceMath.fract(pose.time / 1.1 + drop.phase + pose.look.phase))
                let grow = FaceMath.smoothstep(0, 0.18, cycle)
                let vanish = 1 - FaceMath.smoothstep(0.72, 1, cycle)
                let center = CGPoint(
                    x: pose.rect.midX + drop.x * pose.rect.width,
                    y: pose.eyeLine.y - pose.shake.dy + drop.y * pose.rect.height + cycle * 5.5 * u
                )
                FaceShapes.addDrop(
                    to: water, glints: glints, center: center,
                    radius: 2.4 * u * drop.size * appear * (0.55 + 0.45 * grow) * vanish,
                    tilt: drop.x > 0 ? 0.3 : -0.3, u: u
                )
            }
        }

        guard !water.isEmpty else { return }
        context.addPath(water)
        context.setFillColor(FaceStyle.water)
        context.setStrokeColor(FaceStyle.waterEdge)
        context.setLineWidth(pose.waterLine)
        context.drawPath(using: .fillStroke)
        if !glints.isEmpty {
            context.addPath(glints)
            context.setStrokeColor(FaceStyle.white)
            context.setLineWidth(max(0.9 * u, 0.7))
            context.strokePath()
        }
    }

    /// 一道往下流的泪：从眼睛下缘流到图标下方，一条微微扭动的水带，末端鼓成一滴，
    /// 下面还有一颗正在掉落的小泪珠。先画泪、后画眼睛，所以泪的上端被眼睛盖住。
    private func addTearStream(
        below eye: FacePose.Eye, phase: Double, to water: CGMutablePath, glints: CGMutablePath
    ) {
        let u = pose.u
        let x = eye.center.x
        let top = eye.center.y + eye.ry * 0.55
        // 刚开始流的时候又细又短，随后变粗变长——从无到有是连续的，不会突然冒出一截。
        let width = 4.6 * pose.s * FaceMath.smoothstep(0, 0.3, pose.stream)
        guard width > 0.3 * u else { return }
        let bulb = width * 0.72
        // 泪越多流得越长；流满时末端在图标下缘以下 tearReach 处。
        let end = FaceMath.lerp(top + bulb * 2, pose.rect.maxY + FaceStyle.tearReach * u, pose.stream)
        let neck = end - bulb
        let time = pose.time
        func sway(_ y: CGFloat) -> CGFloat {
            let settle = FaceMath.smoothstep(0, 5 * u, y - top)
            let wiggle = sin(Double((y - top) / (12 * u)) * 2 * .pi - time * 2 * .pi * 1.5 + phase * 2 * .pi)
            return CGFloat(wiggle) * width * 0.06 * settle
        }

        let steps = max(Int(((neck - top) / (2.5 * u)).rounded(.up)), 2)
        water.move(to: CGPoint(x: x - width / 2 + sway(top), y: top))
        for i in 1...steps {
            let y = top + (neck - top) * CGFloat(i) / CGFloat(steps)
            water.addLine(to: CGPoint(x: x - width / 2 + sway(y), y: y))
        }
        let bulbCenter = CGPoint(x: x + sway(neck), y: neck)
        // 画布 y 向下：角度从 π 减到 0（clockwise 为 true），经过的是圆的下半边。
        water.addArc(center: bulbCenter, radius: bulb, startAngle: .pi, endAngle: 0, clockwise: true)
        for i in stride(from: steps, through: 0, by: -1) {
            let y = top + (neck - top) * CGFloat(i) / CGFloat(steps)
            water.addLine(to: CGPoint(x: x + width / 2 + sway(y), y: y))
        }
        water.closeSubpath()

        // 水带上往下跑的高光。
        let span = neck - top - 3 * u
        if span > 4 * u {
            for i in 0..<(pose.fine ? 3 : 2) {
                let offset = CGFloat(FaceMath.fract(time * 1.6 + Double(i) / 3 + phase)) * span
                let y = top + 2 * u + offset
                let length = min(3.2 * u, neck - y)
                guard length > 0.8 * u else { continue }
                glints.move(to: CGPoint(x: x - width * 0.16 + sway(y), y: y))
                glints.addLine(to: CGPoint(x: x - width * 0.16 + sway(y + length), y: y + length))
            }
        }

        // 末端掉下去的小泪珠：往下掉 3.5u，边掉边缩没。
        let fall = CGFloat(FaceMath.fract(time / 0.55 + phase))
        let vanish = 1 - FaceMath.smoothstep(0.6, 1, fall)
        FaceShapes.addDrop(
            to: water, glints: glints,
            center: CGPoint(x: bulbCenter.x, y: end + (1.5 + fall * 3.5) * u),
            radius: 1.25 * u * (1 - 0.3 * fall) * pose.stream * vanish, tilt: 0, u: u
        )
    }

    // MARK: - 腮红

    private func paintBlush() {
        let blush = pose.params.blush
        guard blush > 0.01 else { return }
        let s = pose.s
        let rx = 4.2 * s
        let ry = 2.4 * s
        let hatch = CGMutablePath()
        context.setFillColor(FaceStyle.blush)
        context.setAlpha(FaceStyle.blushAlpha * blush)
        for eye in pose.eyes {
            // 眼睛的外下方。
            let center = CGPoint(x: eye.center.x + eye.side * 5.6 * s, y: eye.center.y + eye.ry + 1.6 * s)
            context.fillEllipse(in: CGRect(x: center.x - rx, y: center.y - ry, width: rx * 2, height: ry * 2))
            for i in -1...1 {
                let x = center.x + CGFloat(i) * rx * 0.5
                hatch.move(to: CGPoint(x: x - 0.7 * s, y: center.y + ry * 0.62))
                hatch.addLine(to: CGPoint(x: x + 0.7 * s, y: center.y - ry * 0.62))
            }
        }
        // 三道斜线：害羞到一定程度才出现；小图标上省掉。
        if pose.fine, blush > 0.3 {
            context.setAlpha(FaceMath.smoothstep(0.3, 0.7, blush))
            context.addPath(hatch)
            context.setStrokeColor(FaceStyle.blushLine)
            context.setLineWidth(max(0.9 * s, 0.7))
            context.strokePath()
        }
        context.setAlpha(1)
    }

    // MARK: - 眼睛

    private func paintEyes() {
        let left = pose.leftEye
        let right = pose.rightEye
        let s = pose.s

        // 上眼皮的线、闭着的眼睛：比轮廓粗一点，最后一起描。
        let lids = CGMutablePath()

        if left.isClosed {
            for eye in [left, right] {
                // 闭眼：一道微微下垂的弧线。刚合上的那一刻是平的（和合上前的那道缝接得上），合得越紧越弯。
                let y = (eye.top + eye.bottom) / 2
                let half = eye.halfWidth(at: y)
                let sag = 1 - max(eye.bottom - eye.top, 0) / (FacePose.closedThreshold * s)
                lids.move(to: CGPoint(x: eye.center.x - half, y: y - 0.5 * s * sag))
                lids.addQuadCurve(
                    to: CGPoint(x: eye.center.x + half, y: y - 0.5 * s * sag),
                    control: CGPoint(x: eye.center.x, y: y + 2.0 * s * sag)
                )
            }
        } else {
            let lidded = left.coverTop > 0.001 || left.coverBottom > 0.001
            let openings = CGMutablePath()
            for eye in [left, right] {
                if lidded {
                    FaceShapes.addEyeOpening(to: openings, eye: eye)
                } else {
                    openings.addEllipse(in: CGRect(
                        x: eye.center.x - eye.rx, y: eye.center.y - eye.ry, width: eye.rx * 2, height: eye.ry * 2
                    ))
                }
            }

            if !lidded, pose.pool <= 0 {
                // 最常见的情形：眼睛全睁、没有泪。瞳孔碰不到眼眶，不用裁剪，眼白和轮廓一次画完。
                context.addPath(openings)
                context.setFillColor(FaceStyle.white)
                context.setStrokeColor(FaceStyle.ink)
                context.setLineWidth(pose.outline)
                context.drawPath(using: .fillStroke)
                paintPupils(tearLayer: false)
            } else {
                context.addPath(openings)
                context.setFillColor(FaceStyle.white)
                context.fillPath()
                // 瞳孔和泪水可能伸到眼皮外面：裁在睁开的那一段里。
                context.saveGState()
                context.addPath(openings)
                context.clip()
                paintPupils(tearLayer: pose.pool > 0)
                context.restoreGState()
                context.addPath(openings)
                context.setStrokeColor(FaceStyle.ink)
                context.setLineWidth(pose.outline)
                context.strokePath()
            }

            if left.coverTop > 0.001 {
                for eye in [left, right] {
                    let half = eye.halfWidth(at: eye.top)
                    lids.move(to: CGPoint(x: eye.center.x - half, y: eye.top))
                    lids.addLine(to: CGPoint(x: eye.center.x + half, y: eye.top))
                }
            }
            paintSpirals()
        }

        if !lids.isEmpty {
            context.addPath(lids)
            context.setStrokeColor(FaceStyle.ink)
            context.setLineWidth(pose.lidLine)
            context.strokePath()
        }
    }

    /// 瞳孔、高光，以及（需要时）眼眶里的泪。
    private func paintPupils(tearLayer: Bool) {
        let eyes = pose.eyes
        let tears = pose.params.tears

        // 眼眶里蓄着的泪：先在瞳孔后面画一层实的，瞳孔画完再盖一层半透明的——
        // 这样泪水漫过瞳孔时，瞳孔透过水面还看得见。
        var pools: CGMutablePath?
        var surfaces: CGMutablePath?
        if tearLayer {
            let fill = CGMutablePath()
            let line = CGMutablePath()
            for eye in eyes {
                let depth = (eye.bottom - eye.top) * 0.38 * pose.pool
                let surface = eye.bottom - depth
                let phase = CGFloat(pose.time * 5) + eye.side
                let steps = 10
                for i in 0...steps {
                    let t = CGFloat(i) / CGFloat(steps)
                    let point = CGPoint(
                        x: eye.center.x - eye.rx + t * eye.rx * 2,
                        y: surface + sin(t * 2 * .pi * 1.5 + phase) * 0.7 * pose.s
                    )
                    if i == 0 {
                        fill.move(to: point)
                        line.move(to: point)
                    } else {
                        fill.addLine(to: point)
                        line.addLine(to: point)
                    }
                }
                fill.addLine(to: CGPoint(x: eye.center.x + eye.rx, y: eye.center.y + eye.ry + 1))
                fill.addLine(to: CGPoint(x: eye.center.x - eye.rx, y: eye.center.y + eye.ry + 1))
                fill.closeSubpath()
            }
            pools = fill
            surfaces = line
            context.addPath(fill)
            context.setFillColor(FaceStyle.water)
            context.fillPath()
        }

        if eyes[0].pupilRadius > 0.2 {
            for eye in eyes {
                let r = eye.pupilRadius
                context.addEllipse(in: CGRect(x: eye.pupil.x - r, y: eye.pupil.y - r, width: r * 2, height: r * 2))
            }
            context.setFillColor(FaceStyle.ink)
            context.fillPath()
        }

        if let pools, let surfaces {
            context.addPath(pools)
            context.setFillColor(FaceStyle.water)
            context.setAlpha(FaceStyle.tearOverPupilAlpha)
            context.fillPath()
            context.setAlpha(1)
            context.addPath(surfaces)
            context.setStrokeColor(FaceStyle.waterEdge)
            context.setLineWidth(max(0.8 * pose.s, 0.6))
            context.strokePath()
        }

        // 高光：左上一大点；图标够大时右下再加一小点。泪汪汪时高光变大，并微微晃动。
        if eyes[0].pupilRadius > 0.6 {
            for eye in eyes {
                let r = eye.pupilRadius
                let wobble = pose.pool > 0
                    ? 0.06 * pose.pool * CGFloat(sin(pose.time * 2 * .pi * 3 + Double(eye.side)))
                    : 0
                let big = r * (0.34 + 0.1 * tears)
                context.addEllipse(in: CGRect(
                    x: eye.pupil.x + (-0.36 + wobble) * r - big, y: eye.pupil.y - 0.4 * r - big,
                    width: big * 2, height: big * 2
                ))
                if pose.fine {
                    let small = r * (0.16 + 0.08 * tears)
                    context.addEllipse(in: CGRect(
                        x: eye.pupil.x + 0.42 * r - small, y: eye.pupil.y + (0.4 - wobble) * r - small,
                        width: small * 2, height: small * 2
                    ))
                }
            }
            context.setFillColor(FaceStyle.white)
            context.fillPath()
        }
    }

    /// 头晕：瞳孔换成一圈圈转动的漩涡。
    private func paintSpirals() {
        guard pose.spiral > 0.02 else { return }
        let path = CGMutablePath()
        for eye in pose.eyes {
            // 瞳孔一边缩小，漩涡一边从瞳孔里面往外长（起初完全藏在瞳孔里，所以是慢慢显形的）；
            // 漩涡的中心也从瞳孔所在的位置慢慢回到眼眶正中。
            let maxRadius = FaceMath.lerp(pose.pupilRestRadius * 0.7, min(eye.rx, eye.ry) * 0.72, pose.spiral)
            let center = CGPoint(
                x: FaceMath.lerp(eye.pupil.x, eye.center.x, pose.spiral),
                y: FaceMath.lerp(eye.pupil.y, eye.center.y, pose.spiral)
            )
            let spin = pose.time * 2 * .pi * 1.3 * Double(eye.side) + pose.look.phase * 2 * .pi
            let turns = 2.2
            let steps = 26
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let angle = t * turns * 2 * .pi + spin
                let radius = maxRadius * CGFloat(t)
                let point = CGPoint(
                    x: center.x + radius * CGFloat(cos(angle)),
                    y: center.y + radius * CGFloat(sin(angle))
                )
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
        context.addPath(path)
        context.setStrokeColor(FaceStyle.ink)
        context.setLineWidth(max(1.4 * pose.s, 1))
        context.strokePath()
    }

    // MARK: - 墨线：眉毛、嘴（没张开时）、发抖线、Zzz

    private func paintInkLines(mouth: MouthShape) {
        let p = pose.params
        let s = pose.s
        let u = pose.u
        // 已经完全显形的线攒在一条路径里一次画完；正在渐显的线（刚长出来的眉毛、刚冒头的 Z……）
        // 各带各的不透明度单独画——这样它们是慢慢浮现的，不是突然蹦出来一个点。
        let solid = CGMutablePath()
        var emerging: [(path: CGMutablePath, alpha: CGFloat)] = []
        func lines(alpha: CGFloat) -> CGMutablePath {
            if alpha >= 0.995 { return solid }
            let path = CGMutablePath()
            emerging.append((path, alpha))
            return path
        }

        // 眉毛：平时没有；害怕、想哭、不忍心看时长出来，内端上扬（"八字眉"）。
        if pose.worry > 0.05 {
            let half = 3.4 * s * FaceMath.smoothstep(0.05, 0.5, pose.worry)
            let slope = 0.5 * pose.worry
            let path = lines(alpha: FaceMath.smoothstep(0.05, 0.3, pose.worry))
            for eye in pose.eyes {
                let middle = CGPoint(
                    x: eye.center.x + eye.side * 0.6 * s,
                    y: eye.center.y - eye.ry - (2.6 + 1.0 * pose.worry) * s
                )
                // 外端低、内端高。
                path.move(to: CGPoint(x: middle.x + eye.side * half, y: middle.y + half * slope))
                path.addLine(to: CGPoint(x: middle.x - eye.side * half, y: middle.y - half * slope))
            }
        }

        // 嘴：没张开时是一条线。
        if mouth.open <= MouthShape.openThreshold * s, mouth.width > 0.5 * s {
            if mouth.wave == 0 {
                // 没有波浪：一段弧线就够。
                solid.move(to: mouth.upperPoint(0, of: 1))
                solid.addQuadCurve(
                    to: mouth.upperPoint(1, of: 1),
                    control: CGPoint(x: mouth.center.x, y: mouth.center.y + mouth.curve * 2)
                )
            } else {
                let steps = 16
                solid.move(to: mouth.upperPoint(0, of: steps))
                for i in 1...steps { solid.addLine(to: mouth.upperPoint(i, of: steps)) }
            }
        }

        // 发抖线：脸两侧各两道小弧线。已经在流泪时不画（画面上的东西够多了）；小图标上省掉。
        let quiver = FaceMath.smoothstep(0.25, 0.6, p.tremble) * (1 - pose.stream)
        if pose.fine, quiver > 0.01 {
            let path = lines(alpha: FaceMath.smoothstep(0, 0.4, quiver))
            let y = pose.eyeLine.y - pose.shake.dy + 9 * u
            for side in [CGFloat(-1), 1] {
                for (index, reach) in [CGFloat(0.336), 0.383].enumerated() {
                    let x = pose.rect.midX + side * reach * pose.rect.width
                    let half = (3.2 - CGFloat(index) * 0.9) * u * quiver
                    path.move(to: CGPoint(x: x, y: y - half))
                    path.addQuadCurve(to: CGPoint(x: x, y: y + half), control: CGPoint(x: x + side * 1.8 * u, y: y))
                }
            }
        }

        // Zzz：三个由小到大的"Z"，从头的右上方飘出去，边飘边长大，到顶缩小、淡出。用折线画，不是文字。
        if pose.sleepDepth > 0 {
            let rect = pose.rect
            for i in 0..<3 {
                let progress = CGFloat(FaceMath.fract(pose.time / 2.6 + Double(i) / 3 + pose.look.phase))
                let visible = FaceMath.smoothstep(0, 0.15, progress) * (1 - FaceMath.smoothstep(0.8, 1, progress))
                let half = FaceMath.lerp(0.028, 0.062, progress) * rect.width * pose.sleepDepth * visible
                // 太小的 Z 认不出来：小到一定程度就淡掉。
                let alpha = FaceMath.smoothstep(0.5 * u, 1.8 * u, half)
                guard alpha > 0.01 else { continue }
                let center = CGPoint(
                    x: rect.midX + FaceMath.lerp(0.22, 0.38, progress) * rect.width
                        + sin(progress * 2 * .pi * 1.5) * 0.015 * rect.width,
                    y: rect.minY + FaceMath.lerp(0.22, -0.10, progress) * rect.height
                )
                // 略向右倾的 Z。
                let path = lines(alpha: alpha)
                path.move(to: CGPoint(x: center.x - half * 0.8, y: center.y - half))
                path.addLine(to: CGPoint(x: center.x + half, y: center.y - half))
                path.addLine(to: CGPoint(x: center.x - half, y: center.y + half))
                path.addLine(to: CGPoint(x: center.x + half * 0.8, y: center.y + half))
            }
        }

        // 先描一圈白边（"贴纸边"），再描墨线：这样墨线画在深色图标、深色墙纸上也看得清。
        func stroke(_ path: CGMutablePath) {
            guard !path.isEmpty else { return }
            context.addPath(path)
            context.setStrokeColor(FaceStyle.white)
            context.setLineWidth(pose.inkLine + pose.halo * 2)
            context.strokePath()
            context.addPath(path)
            context.setStrokeColor(FaceStyle.ink)
            context.setLineWidth(pose.inkLine)
            context.strokePath()
        }
        stroke(solid)
        for line in emerging {
            context.setAlpha(line.alpha)
            stroke(line.path)
        }
        if !emerging.isEmpty { context.setAlpha(1) }
    }

    // MARK: - 张开的嘴

    private func paintOpenMouth(_ mouth: MouthShape) {
        let s = pose.s
        guard mouth.open > MouthShape.openThreshold * s else { return }
        let steps = 14
        let path = CGMutablePath()
        path.move(to: mouth.upperPoint(0, of: steps))
        for i in 1...steps { path.addLine(to: mouth.upperPoint(i, of: steps)) }
        // 下唇：从右往左，按半圆的轮廓向下鼓出。
        for i in stride(from: steps, through: 0, by: -1) {
            let t = CGFloat(i) / CGFloat(steps)
            let bulge = sqrt(max(0, 1 - (2 * t - 1) * (2 * t - 1)))
            let point = mouth.upperPoint(i, of: steps)
            path.addLine(to: CGPoint(x: point.x, y: point.y + mouth.open * bulge))
        }
        path.closeSubpath()

        context.addPath(path)
        context.setStrokeColor(FaceStyle.white)
        context.setLineWidth(pose.inkLine + pose.halo * 2)
        context.strokePath()
        context.addPath(path)
        context.setFillColor(FaceStyle.mouthInside)
        context.fillPath()
        // 舌头：嘴底部的一个椭圆，随嘴张大慢慢长出来。大小和位置保证它整个在嘴里面，所以不用裁剪。
        let tongue = FaceMath.smoothstep(1.5 * s, 3.5 * s, mouth.open)
        if tongue > 0.05 {
            let bottom = mouth.upperPoint(steps / 2, of: steps).y + mouth.open
            let rx = mouth.width * 0.26 * tongue
            let ry = mouth.open * 0.3 * tongue
            context.setFillColor(FaceStyle.tongue)
            context.fillEllipse(in: CGRect(
                x: mouth.center.x - rx, y: bottom - 0.6 * s - ry * 2, width: rx * 2, height: ry * 2
            ))
        }
        context.addPath(path)
        context.setStrokeColor(FaceStyle.ink)
        context.setLineWidth(pose.inkLine)
        context.strokePath()
    }

    // MARK: - 头晕的星星

    private func paintStars() {
        guard pose.stars > 0.02 else { return }
        let rect = pose.rect
        let u = pose.u
        // 三颗星绕着头顶上方的一个椭圆转；转到前面（椭圆下半边）时大一点，转到后面时小一点。
        let orbit = CGPoint(x: pose.eyeLine.x, y: pose.eyeLine.y - pose.leftEye.ry - 0.11 * rect.height)
        let path = CGMutablePath()
        for i in 0..<3 {
            let angle = (pose.time * 0.6 + Double(i) / 3 + pose.look.phase) * 2 * .pi
            let depth = CGFloat(sin(angle))
            let center = CGPoint(
                x: orbit.x + CGFloat(cos(angle)) * 0.2 * rect.width,
                y: orbit.y + depth * 0.055 * rect.height
            )
            FaceShapes.addStar(
                to: path, center: center, radius: 3.6 * u * pose.stars * (0.85 + 0.15 * depth),
                rotation: CGFloat(angle) * 0.5
            )
        }
        context.addPath(path)
        context.setFillColor(FaceStyle.star)
        context.setStrokeColor(FaceStyle.ink)
        context.setLineWidth(max(0.7 * u, 0.6))
        context.drawPath(using: .fillStroke)
    }

    // MARK: - 捂眼的手

    private func paintHands() {
        let cover = pose.params.cover
        guard cover > 0.01 else { return }
        let s = pose.s
        let peek = pose.params.peek
        let rise = pose.handRise
        // 手从下方抬上来；刚露头时小一点，到位后是原大。
        let scale = FaceMath.lerp(0.7, 1, rise) * FaceMath.smoothstep(0, 0.12, cover)
        let path = CGMutablePath()
        for eye in pose.eyes {
            // 手从下方 17 个单位处抬上来，到位时手心对着眼睛正中偏下。
            let origin = CGPoint(
                x: eye.center.x + eye.side * (1 - rise) * 5 * s,
                y: eye.center.y + (1 - rise) * 17 * s
            )
            FaceShapes.addHand(to: path, origin: origin, unit: s * scale * pose.look.eyeScale, peek: peek)
        }
        // 先用墨色把所有手指和手掌粗粗地描一遍，再整个填白：手指交叠处的线被填充盖掉，
        // 只剩外轮廓和指缝——两次绘制就得到一只"手套"。
        context.addPath(path)
        context.setStrokeColor(FaceStyle.ink)
        context.setLineWidth(pose.outline * 2)
        context.strokePath()
        context.addPath(path)
        context.setFillColor(FaceStyle.hand)
        context.fillPath()
    }
}
