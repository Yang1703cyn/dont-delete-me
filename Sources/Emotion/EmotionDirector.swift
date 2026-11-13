// Emotion · 情绪引擎（模块入口）
//
// "导演"：每帧拿到「图标快照 + 交互事实 + 时间」，决定这一帧要画哪些脸、各自在哪、画在哪一层、
// 表情参数是什么。纯逻辑：不读系统时钟、不用全局随机数、不做文件读写、不依赖 AppKit；
// 时间和随机数种子都由外部传入，同样的种子 + 同样的输入序列永远得到同样的输出序列。
//
// 文件分工：
//   EmotionDirector.swift        入口与每一帧的流程（本文件）
//   EmotionDirector+Cast.swift   演员表：跟着快照增减演员、排"谁该打瞌睡"
//   EmotionDirector+Scene.swift  场景：主角（被拖的图标）、围观、幽灵、两个彩蛋
//   Performer.swift              演员：单个图标的情绪通道与表情
//   Gaze.swift · Easing.swift    视线的平滑 · 渐入渐出
//   EmotionTuning.swift          调参表
//
// 剧本、优先级、调参表的说明见 docs/模块说明/emotion.md；接口见 docs/接口约定.md 第 5 节。

import CoreGraphics
import DDMCore
import Foundation

public struct EmotionDirector: EmotionDirecting, Sendable {
    /// 调参表。可以随时改，下一帧生效（性格在图标第一次出现时按当时的比例定下，之后不变）。
    public var tuning: EmotionTuning

    let seed: UInt64

    /// 演员表。顺序与当前快照的图标顺序一致。
    var performers: [Performer] = []
    /// 图标编号 → 在演员表里排第几。
    var indexByID: [IconID: Int] = [:]
    /// 正在飘的（和排着队等出场的）幽灵。
    var ghosts: [Ghost] = []
    /// 导演自己的随机数（挑谁张望）。每个演员另有自己的一路。
    var random: SeededRandom

    var lastTime: TimeInterval?
    /// 最近一次合法的鼠标位置。
    var mouse = CGPoint.zero
    /// "主角正朝废纸篓去"的程度，0…1（把交互感知给的是/否平滑一下）。
    var heading = 0.0
    var alarm: Alarm?
    var newcomer: Newcomer?
    /// 下一次"有谁张望一下"的时刻；不无聊时为 nil。
    var nextGlanceAt: TimeInterval?
    /// 上一帧是否处于"安静"状态。
    var wasQuiet = false

    /// 打瞌睡名单是否需要重排。
    var sleepersStale = true
    var sleepersRevision: UInt64?
    var sleepersCheckedAt: Date?

    /// - Parameters:
    ///   - seed: 随机数种子。同样的种子 + 同样的输入序列 → 同样的输出序列。
    ///   - tuning: 调参表，默认值见 `EmotionTuning`。
    public init(seed: UInt64, tuning: EmotionTuning = EmotionTuning()) {
        self.seed = seed
        self.tuning = tuning
        random = SeededRandom(seed: SeededRandom.derive(seed, stream: 3))
    }

    /// 清空所有进行中的情绪和动画，回到初始状态（随机数序列也从种子重新开始）。
    public mutating func reset() {
        self = EmotionDirector(seed: seed, tuning: tuning)
    }

    /// 某个图标的性格（按当前调参表里的比例）。供演示和调试用。
    public func personality(of iconID: IconID) -> EmotionPersonality {
        EmotionPersonality(faceSeed: iconID.faceSeed, tuning: tuning)
    }

    // MARK: - 每一帧

    public mutating func update(_ input: EmotionInput) -> EmotionOutput {
        let t = tuning
        let facts = input.facts
        let icons = input.icons.snapshot.icons

        // 时间。两帧之间隔得再久，平滑也只按一小步算（见 maxSmoothingStep）。
        // 接口保证时间单调不减；万一倒流或不是数字，当作时间没有流逝（停在原地，等它追上来）。
        let given = input.time.monotonic
        let now = given.isFinite ? max(given, lastTime ?? given) : (lastTime ?? 0)
        let elapsed = lastTime.map { now - $0 } ?? 0
        lastTime = now
        let step = min(elapsed, max(t.maxSmoothingStep, 0))
        let eases = Eases(step: step, tuning: t)
        var pulse = Pulse(now: now)

        if facts.mouse.position.isSane {
            mouse = facts.mouse.position
        }
        let idle = facts.mouse.idleDuration.isFinite ? max(facts.mouse.idleDuration, 0) : 0

        // 演员表跟上快照；排打瞌睡名单。
        syncCast(with: input.icons, now: now)
        refreshSleepers(snapshot: input.icons.snapshot, wallClock: input.time.wallClock)

        // 场景：幽灵、主角、围观、大家看哪、无聊。
        updateGhosts(deletions: facts.deletions, now: now, pulse: &pulse)
        let star = updateStars(facts: facts, icons: icons, now: now, eases: eases, pulse: &pulse)
        let scareLevel = updateAlarm(star: star, now: now)
        let focus = currentFocus(star: star, icons: icons, now: now, pulse: &pulse)

        let isQuiet = idle >= t.quietAfter
        let quietStretch = 1 + (max(t.quietStretch, 1) - 1) * ramp(idle, t.quietAfter, 2 * t.quietAfter)
        let rerollBlinks = wasQuiet && !isQuiet
        wasQuiet = isQuiet

        let nothingGoingOn = facts.drag == nil && facts.releasedDrags.isEmpty
            && ghosts.isEmpty && alarm == nil && focus == nil
        let bored = updateBoredom(
            nothingGoingOn: nothingGoingOn, idle: idle, quietStretch: quietStretch,
            hoverID: facts.hover?.iconID, icons: icons, now: now, pulse: &pulse
        )

        let context = FrameContext(
            now: now,
            step: step,
            eases: eases,
            mouse: mouse,
            mouseMoving: idle < t.wakeStillness,
            hoverID: facts.hover?.iconID,
            trashCenter: facts.trash.flatMap { trash in
                let center = trash.estimatedRect.center
                return center.isSane ? center : nil
            },
            focus: focus?.point,
            focusOwner: focus?.owner,
            alarm: alarm,
            scareLevel: scareLevel,
            bored: bored,
            rerollBlinks: rerollBlinks,
            quietStretch: quietStretch
        )

        // 每个演员走一帧。叠放次序：桌面上的脸按快照顺序 → 被拿着的脸 → 幽灵（最上面）。
        var faces: [FacePlacement] = []
        faces.reserveCapacity(performers.count + ghosts.count)
        var carried: [FacePlacement] = []
        for index in performers.indices {
            let icon = icons[performers[index].iconIndex]
            guard let face = performers[index].advance(icon: icon, context: context, tuning: t, pulse: &pulse)
            else { continue }
            if face.layer == .drag {
                carried.append(face)
            } else {
                faces.append(face)
            }
        }
        faces.append(contentsOf: carried)
        appendGhostFaces(to: &faces, now: now)

        return EmotionOutput(faces: faces, demand: pulse.demand)
    }
}
