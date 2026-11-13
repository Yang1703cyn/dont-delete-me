// Faces · 姿态：把（表情状态、图标矩形、时间）算成"五官各在哪、多大"
//
// 这里只有数字，不碰画布：绘制（FacePainter）照着姿态画，测试直接检查姿态。
// 全部是纯函数——同样的输入永远得到同样的姿态。

import CoreGraphics
import DDMCore
import Foundation

/// 表情参数：从 `FaceState` 取出来、夹到合法范围的一份拷贝。
struct FaceParams {
    var seed: UInt64
    var isGhost: Bool
    var gazeTarget: CGVector
    var gazeFollow: CGFloat
    var blink: CGFloat
    var blush: CGFloat
    var fear: CGFloat
    var sweat: CGFloat
    var tremble: CGFloat
    var tears: CGFloat
    var dizziness: CGFloat
    var cover: CGFloat
    var peek: CGFloat
    var sleepiness: CGFloat
    var ghost: CGFloat

    init(_ state: FaceState) {
        seed = state.seed
        isGhost = state.mood == .ghost
        let target = state.gazeTarget
        gazeTarget = target.dx.isFinite && target.dy.isFinite ? target : .zero
        gazeFollow = FaceMath.unit(state.gazeFollow)
        blink = FaceMath.unit(state.blink)
        blush = FaceMath.unit(state.blush)
        fear = FaceMath.unit(state.fear)
        sweat = FaceMath.unit(state.sweat)
        tremble = FaceMath.unit(state.tremble)
        tears = FaceMath.unit(state.tears)
        dizziness = FaceMath.unit(state.dizziness)
        cover = FaceMath.unit(state.cover)
        peek = FaceMath.unit(state.peek)
        sleepiness = FaceMath.unit(state.sleepiness)
        ghost = FaceMath.unit(state.ghost)
    }
}

/// 长相：由长相种子决定、与表情无关的细微差别。同一个种子永远得到同一张脸。
struct FaceLook: Equatable {
    /// 眼睛大小的倍数，0.93…1.07。
    let eyeScale: CGFloat
    /// 两眼间距的增减，-0.8…0.8（单位 u）。
    let gap: CGFloat
    /// 整张脸的高低，-1…1（单位 u，正数偏下）。
    let lift: CGFloat
    /// 眼睛偏长还是偏圆，-0.06…0.06。
    let roundness: CGFloat
    /// 嘴宽的倍数，0.85…1.15。
    let mouthScale: CGFloat
    /// 循环小动画的相位，0…1：让一排图标发抖、掉泪、冒 Zzz 时不整齐划一。
    let phase: Double

    init(seed: UInt64) {
        // 第 0 路子种子归表情模块用（情绪模块用别的路，互不影响）。
        var random = SeededRandom(seed: SeededRandom.derive(seed, stream: 0))
        func spread(_ range: CGFloat) -> CGFloat { CGFloat(random.nextUnit() - 0.5) * 2 * range }
        eyeScale = 1 + spread(0.07)
        gap = spread(0.8)
        lift = spread(1.0)
        roundness = spread(0.06)
        mouthScale = 1 + spread(0.15)
        phase = random.nextUnit()
    }
}

/// 一张脸在某一刻的姿态。
struct FacePose {
    /// 一只眼睛。
    struct Eye {
        /// -1 左眼，+1 右眼。
        var side: CGFloat
        var center: CGPoint
        var rx: CGFloat
        var ry: CGFloat
        /// 没被眼皮盖住的那一段的上、下边界（y）。
        var top: CGFloat
        var bottom: CGFloat
        /// 上、下眼皮各盖住了眼睛高度的多少（0…1）。
        var coverTop: CGFloat
        var coverBottom: CGFloat
        /// 眼睛是不是闭上了（画成一条线）。
        var isClosed: Bool
        var pupil: CGPoint
        var pupilRadius: CGFloat

        /// 眼眶在高度 y 处的半宽。
        func halfWidth(at y: CGFloat) -> CGFloat {
            let relative = (y - center.y) / ry
            return rx * sqrt(max(0, 1 - relative * relative))
        }
    }

    let params: FaceParams
    let look: FaceLook
    let rect: CGRect
    let time: TimeInterval

    /// 效果（泪、汗、星星……）用的单位：图标短边 / 64。
    let u: CGFloat
    /// 五官用的单位：小图标上比 u 略大（见 `FaceStyle.smallIconBoost`）。
    let s: CGFloat
    /// 图标够大，可以画次要细节。
    let fine: Bool

    // 线宽（点）。
    let outline: CGFloat
    let lidLine: CGFloat
    let inkLine: CGFloat
    let halo: CGFloat
    let waterLine: CGFloat

    /// 两眼连线的中点（已含发抖、头晕摇晃、睡着时的起伏、朝视线方向探出去的位移）。
    let eyeLine: CGPoint
    /// 发抖造成的位移。
    let shake: CGVector
    let leftEye: Eye
    let rightEye: Eye

    // 由参数换算出来的各种"程度"，都是 0…1。
    /// 泪流（往下流的那两道）。
    let stream: CGFloat
    /// 眼眶里蓄着的泪。
    let pool: CGFloat
    /// 飞溅的泪珠。
    let splash: CGFloat
    /// 眼睛变成漩涡的程度。
    let spiral: CGFloat
    /// 星星出现的程度。
    let stars: CGFloat
    /// 睡着的深浅（Zzz、起伏）。
    let sleepDepth: CGFloat
    /// 呼吸：-1…1，随时间缓慢起伏；没睡着时为 0。
    let breath: CGFloat
    /// Zzz 里这一刻看得见的那几个 Z（由下往上）；没睡着时为空。
    let zzz: [ZLetter]
    /// Zzz 的不透明度：入睡的那一两秒里淡入，睡熟后为 1。
    let zzzAlpha: CGFloat
    /// 担忧（眉毛）。
    let worry: CGFloat
    /// 手抬到位的程度（已做缓动）。
    let handRise: CGFloat
    /// 瞳孔本来的半径（还没因为头晕而缩小时）。
    let pupilRestRadius: CGFloat

    var eyes: [Eye] { [leftEye, rightEye] }

    init(params p: FaceParams, rect: CGRect, time: TimeInterval) {
        params = p
        look = FaceLook(seed: p.seed)
        self.rect = rect
        self.time = time

        let size = min(rect.width, rect.height)
        let u = size / 64
        let boost = 1 + FaceStyle.smallIconBoost * min(max((64 - size) / 32, 0), 1)
        let s = u * boost
        self.u = u
        self.s = s
        fine = size >= FaceStyle.fineDetailMinSize
        outline = max(FaceStyle.outline * s, 1)
        lidLine = max(FaceStyle.lidLine * s, 1.25)
        inkLine = max(FaceStyle.inkLine * s, 1)
        halo = max(FaceStyle.halo * s, 0.75)
        waterLine = max(FaceStyle.waterLine * u, 0.75)

        // 各种"程度"。
        stream = FaceMath.smoothstep(FaceStyle.tearStreamThreshold, 0.85, p.tears)
        pool = FaceMath.smoothstep(0.05, 0.5, p.tears)
        splash = FaceMath.smoothstep(0.75, 0.95, p.tears)
        spiral = FaceMath.smoothstep(0.25, 0.7, p.dizziness)
        stars = FaceMath.smoothstep(0.2, 0.6, p.dizziness)
        sleepDepth = FaceMath.smoothstep(FaceStyle.zzzThreshold, 0.8, p.sleepiness)
        worry = max(p.fear, p.tears, 0.75 * p.cover)
        // 手：先快后慢地抬到位。
        let remaining = 1 - p.cover
        handRise = 1 - remaining * remaining * remaining

        let phase = look.phase * 2 * .pi
        // 起伏：周期 breathPeriod，每个图标的相位不同（与 Zzz 的循环用同一个相位，两者同步）。
        breath = sleepDepth > 0
            ? CGFloat(sin((time / FaceStyle.breathPeriod + look.phase) * 2 * .pi)) * sleepDepth
            : 0

        // 整张脸的位移：发抖（快）、头晕摇晃（慢）、睡着时的起伏（很慢）。
        var shake = CGVector.zero
        if p.tremble > 0 {
            shake = CGVector(
                dx: CGFloat(sin(time * 2 * .pi * 13 + phase)) * 1.3 * u * p.tremble,
                dy: CGFloat(sin(time * 2 * .pi * 17 + phase + 1.3)) * 0.6 * u * p.tremble
            )
        }
        self.shake = shake
        // Zzz 在入睡的那一两秒里随睡深一起长大、淡入；刚开始那一点点又小又淡，认不出来、像个脏点，干脆不画。
        let zzzAlpha = FaceMath.smoothstep(0.3, 0.8, sleepDepth)
        self.zzzAlpha = zzzAlpha
        zzz = zzzAlpha > 0.01
            ? FacePose.zzzLetters(rect: rect, u: u, s: s, fine: fine, look: look, depth: sleepDepth, time: time)
            : []
        let sway = p.dizziness > 0 ? CGFloat(sin(time * 2 * .pi * 0.9 + phase)) * 1.6 * u * p.dizziness : 0

        // 眼睛的大小：害怕时瞪大。
        let widen = 1 + FaceStyle.eyeWiden * p.fear
        let rx = FaceStyle.eyeRadiusX * s * look.eyeScale * widen
        let ry = FaceStyle.eyeRadiusY * s * look.eyeScale * (1 + look.roundness) * widen
        let halfSpacing = (FaceStyle.eyeRadiusX * look.eyeScale + FaceStyle.eyeHalfGap + look.gap) * s

        // 没动的时候两眼连线的中点；视线方向以它为准来算，这样发抖时眼神不乱晃。
        let rest = CGPoint(x: rect.midX, y: rect.minY + rect.height * FaceStyle.eyeLine + look.lift * s)
        let target = CGPoint(x: rect.midX + p.gazeTarget.dx, y: rect.midY + p.gazeTarget.dy)
        let reach = rect.width * FaceStyle.gazeReach
        // 整张脸朝视线方向探一点，眼睛的转动因此更明显。
        let lean = FacePose.gaze(from: rest, to: target, reach: reach, follow: p.gazeFollow)
        let eyeLine = CGPoint(
            x: rest.x + shake.dx + sway + lean.dx * FaceStyle.leanX * s,
            y: rest.y + shake.dy + breath * FaceStyle.breathLift * u + lean.dy * FaceStyle.leanY * s
        )
        self.eyeLine = eyeLine

        // 眼皮：各盖住眼睛高度的多少。眨眼上下一起合（上 70%、下 30%，合在中线偏下的地方）；
        // 犯困是上眼皮慢慢耷下来（眼睛成了一只浅碗），快睡熟时下眼皮才迎上去合拢；
        // 害羞、流泪时下眼皮被顶上来一点。
        let sleepTop = FaceStyle.lidTopShare * FaceMath.smoothstep(0, 0.85, p.sleepiness)
        let sleepBottom = FaceStyle.lidBottomShare * FaceMath.smoothstep(0.8, 1, p.sleepiness)
        let coverTop = max(FaceStyle.lidTopShare * p.blink, sleepTop)
        let coverBottom = max(FaceStyle.lidBottomShare * p.blink, sleepBottom, 0.2 * p.blush, 0.1 * p.tears)

        // 瞳孔：害怕时缩小；头晕时先是打转，再缩没、换成漩涡。
        let pupilRestRadius = FaceMath.lerp(FaceStyle.pupilRadius, FaceStyle.pupilRadiusScared, p.fear)
            * s * look.eyeScale
        self.pupilRestRadius = pupilRestRadius
        let pupilRadius = pupilRestRadius * (1 - spiral)
        let rollMix = min(p.dizziness * 2.5, 1)
        let rollAmount = min(p.dizziness * 3, 0.85)

        func makeEye(side: CGFloat) -> Eye {
            let center = CGPoint(x: eyeLine.x + side * halfSpacing, y: eyeLine.y)
            let top = center.y - ry + coverTop * 2 * ry
            let bottom = center.y + ry - coverBottom * 2 * ry
            let isClosed = bottom - top < FacePose.closedThreshold * s

            // 每只眼睛各自朝目标看：目标离得很近时，两眼自然对到一起。
            let origin = CGPoint(x: rest.x + side * halfSpacing, y: rest.y)
            var direction = FacePose.gaze(from: origin, to: target, reach: reach, follow: p.gazeFollow)
            if rollMix > 0 {
                let angle = time * 2 * .pi * 1.1 + phase + Double(side) * 0.5
                direction = CGVector(
                    dx: direction.dx * (1 - rollMix) + CGFloat(cos(angle)) * rollAmount,
                    dy: direction.dy * (1 - rollMix) + CGFloat(sin(angle)) * rollAmount
                )
            }
            let roomX = max(rx - pupilRadius - FaceStyle.pupilMargin * s, 0)
            let roomY = max(ry - pupilRadius - FaceStyle.pupilMargin * s, 0)
            var pupil = CGPoint(x: center.x + direction.dx * roomX, y: center.y + direction.dy * roomY)

            // 从指缝偷看：瞳孔凑到指缝（眼睛正中偏上）那里去。
            let peeking = 0.85 * p.peek * p.cover
            if peeking > 0 {
                pupil.x = FaceMath.lerp(pupil.x, center.x, peeking)
                pupil.y = FaceMath.lerp(pupil.y, center.y - ry * 0.3, peeking)
            }
            // 眼皮合上一部分时，瞳孔别整个藏到眼皮后面。
            let keep = pupilRadius * 0.55
            if bottom - top > keep * 2 {
                pupil.y = min(max(pupil.y, top + keep), bottom - keep)
            } else {
                pupil.y = (top + bottom) / 2
            }
            return Eye(
                side: side, center: center, rx: rx, ry: ry, top: top, bottom: bottom,
                coverTop: coverTop, coverBottom: coverBottom, isClosed: isClosed,
                pupil: pupil, pupilRadius: pupilRadius
            )
        }
        leftEye = makeEye(side: -1)
        rightEye = makeEye(side: 1)
    }

    /// Zzz 里的一个 Z：中心和半宽（点）。
    struct ZLetter: Equatable {
        /// 第几个：0 最下面的小 z，2 最上面的大 Z。
        var index: Int
        var center: CGPoint
        var half: CGFloat
    }

    /// Zzz：三个由小到大的"Z"，在头的右上方由下往上排成一串。
    /// 按每秒 4 帧设计（见 FaceStyle.sleepFrameInterval）：每 0.75 秒冒出一个——先下面的小 z，再中间的，再上面的大 Z——
    /// 每个停留 3 秒，期间慢慢往右上飘一点（64 点图标上每帧不到半个点），然后按冒出来的顺序依次消失。
    /// 冒出来时从八成大长到原大，消失前缩回八成；只变大小、不变透明度，所以睡熟时所有的 Z 能一次画完。
    /// 小图标上最小的那个太小、认不出来，把它放大到和中间那个一样大（不能省掉：省掉的话一轮里有一小会儿一个 Z 都没有）。
    static func zzzLetters(
        rect: CGRect, u: CGFloat, s: CGFloat, fine: Bool, look: FaceLook, depth: CGFloat, time: TimeInterval
    ) -> [ZLetter] {
        let loop = FaceStyle.breathPeriod
        let life = FaceStyle.zzzLife
        // 与起伏用同一个相位：Zzz 和起伏同步。
        let clock = FaceMath.fract(time / loop + look.phase) * loop
        var letters: [ZLetter] = []
        let smallest = FaceStyle.zzzLetters[1].half
        for (index, letter) in FaceStyle.zzzLetters.enumerated() {
            // 这个 Z 冒出来多久了（秒）；超过停留时间就不画。
            let age = FaceMath.fract((clock - letter.spawn) / loop) * loop
            guard age < life else { continue }
            let seconds = CGFloat(age)
            let grow: CGFloat = 0.8 + 0.2 * FaceMath.smoothstep(0, 0.3, seconds)
            let shrink: CGFloat = 1 - 0.2 * FaceMath.smoothstep(CGFloat(life) - 0.3, CGFloat(life), seconds)
            let drift = CGFloat(age / life)
            letters.append(ZLetter(
                index: index,
                center: CGPoint(
                    x: rect.midX + (letter.x + FaceStyle.zzzDriftX * drift) * u,
                    y: rect.minY + (letter.y - FaceStyle.zzzDriftY * drift) * u
                ),
                half: (fine ? letter.half : max(letter.half, smallest)) * s * depth * grow * shrink
            ))
        }
        return letters
    }

    /// 眼睛睁开的那一段矮于这个高度（单位：五官单位 s）就算闭上了，画成一条线。
    static let closedThreshold: CGFloat = 0.9

    /// 从 origin 朝 target 看的方向，返回单位圆内的向量：
    /// 目标越远越接近"看到头"（长度趋近 follow），目标就在眼前时趋近 0。
    static func gaze(from origin: CGPoint, to target: CGPoint, reach: CGFloat, follow: CGFloat) -> CGVector {
        guard follow > 0 else { return .zero }
        let dx = target.x - origin.x
        let dy = target.y - origin.y
        let distance = hypot(dx, dy)
        guard distance > 1e-6 else { return .zero }
        let strength = distance / (distance + reach) * follow
        return CGVector(dx: dx / distance * strength, dy: dy / distance * strength)
    }
}

// MARK: - 嘴

/// 嘴的形状：一条可以带弧度、带波浪的线；张开时变成一个口。
struct MouthShape {
    var center: CGPoint
    var width: CGFloat
    /// 弧度：正数向下鼓（微笑），负数向上鼓（撇嘴），单位点。
    var curve: CGFloat
    /// 波浪的振幅（点）、个数、相位。
    var wave: CGFloat
    var waveCycles: CGFloat
    var wavePhase: CGFloat
    /// 张开的高度（点）；小到一定程度就只画一条线。
    var open: CGFloat
    /// 是不是"纯粹睡着"的小圆嘴（没有掺别的嘴形）：这时画成椭圆，比一般的嘴便宜得多。
    var isSnoreOnly: Bool

    /// 张开到这个高度以上（单位：五官单位 s）才画成一个口。
    static let openThreshold: CGFloat = 0.9

    init(pose: FacePose) {
        let p = pose.params
        let s = pose.s
        // 四种嘴按权重混合，所以参数连续变化时嘴形也连续变化：
        //   wail  大哭时张大的嘴
        //   upset 害怕、头晕、不忍心看时的波浪线
        //   snore 睡着时的小圆嘴
        //   calm  平时的小微笑（害羞时抿成一道小波浪）
        let wail = FaceMath.smoothstep(0.35, 0.9, p.tears)
        let upset = max(p.fear, 0.8 * p.dizziness, 0.6 * p.cover) * (1 - wail)
        let snore = FaceMath.smoothstep(0.5, 0.9, p.sleepiness) * (1 - wail) * (1 - upset)
        let calm = (1 - upset) * (1 - wail) * (1 - snore)

        let eyeBottom = pose.eyeLine.y + pose.leftEye.ry
        center = CGPoint(x: pose.eyeLine.x, y: eyeBottom + FaceMath.lerp(FaceStyle.mouthDrop, 3.6, wail) * s)
        width = (
            FaceMath.lerp(FaceStyle.smileWidth, 3.8, p.blush) * calm * pose.look.mouthScale
                + FaceMath.lerp(7, 10.5, upset) * upset + 10 * wail + 3.4 * snore
        ) * s
        curve = (FaceStyle.smileCurve * calm * (1 - 0.85 * p.blush) - 1.3 * wail - 1.0 * snore) * s
        wave = (0.8 * p.blush * calm + 1.35 * upset) * s
        waveCycles = FaceMath.lerp(1, 2.5, FaceMath.smoothstep(0.1, 0.5, max(upset, wail)))
        // 嘴的波浪只在发抖时才随时间滚动——不发抖的害怕是一幅静止画面，不必每帧重画。
        wavePhase = p.tremble > 0 ? CGFloat(pose.time * 16) : 0
        // 哭的时候嘴一张一合；睡着时随呼吸微微开合。
        let sob = p.tears > FaceStyle.tearStreamThreshold ? 1 + 0.08 * CGFloat(sin(pose.time * 2 * .pi * 5)) : 1
        open = (6.8 * wail * sob + 2.4 * snore * (1 + 0.2 * pose.breath)) * s
        isSnoreOnly = snore >= 1 && wail == 0 && upset == 0
    }

    /// 上唇上的第 i 个点（共 steps + 1 个）。
    func upperPoint(_ i: Int, of steps: Int) -> CGPoint {
        let t = CGFloat(i) / CGFloat(steps)
        let bulge = 1 - (2 * t - 1) * (2 * t - 1)
        let ripple = wave == 0 ? 0 : wave * sin(t * 2 * .pi * waveCycles + wavePhase)
        return CGPoint(x: center.x + (t - 0.5) * width, y: center.y + curve * bulge + ripple)
    }
}
