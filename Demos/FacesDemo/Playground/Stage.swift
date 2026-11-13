// FacesDemo · 试玩窗口 · 舞台（数据和"导演"）
//
// 一小块假桌面：几排带脸的系统图标、右下角一个画出来的废纸篓。每一帧由这里决定每张脸的表情参数——
// 正式应用里这是情绪模块（Emotion）的事；演示程序不依赖它，这里是一个只够演示用的简化版。
//
// 三种玩法：
//   自动      眼睛跟着鼠标，鼠标停在谁身上谁就害羞，偶尔眨眼；
//   指定表情  所有图标都做同一种表情，强度由滑杆决定；
//   连续演示  一个图标被"拖"向废纸篓：越近越怕 → 大哭 → 被删 → 原地飘起幽灵，邻居捂眼、偷看、目送。

import AppKit
import CoreGraphics
import DDMCore
import Foundation

@MainActor
final class Stage {
    /// 舞台上的一个图标。
    struct Actor {
        let icon: SampleIcon
        let seed: UInt64
        /// 平时所在位置（图标矩形的中心）。
        var home: CGPoint = .zero
        /// 害羞的程度（自动玩法里随鼠标悬停渐入渐出）。
        var blush: Double = 0
    }

    /// 这一帧要画的一个图标。
    struct Placement {
        let icon: SampleIcon
        var rect: CGRect
        var state: FaceState
        /// 图标本身的不透明度（被删之后是 0，只剩幽灵）。
        var iconAlpha: CGFloat = 1
    }

    /// 一帧的全部内容。
    struct Frame {
        var placements: [Placement] = []
        var trash: CGRect = .zero
        /// 连续演示里那只假的鼠标指针；没有为 nil。
        var cursor: CGPoint?
    }

    enum Mode: Equatable {
        case live
        case preset(ExpressionPreset)
    }

    // 由控制面板设置。
    var mode: Mode = .live
    var intensity: Double = 1
    var peek: Double = 0
    var iconSize: CGFloat = 64 { didSet { layout() } }
    var followsMouse = true
    var isDark = false

    /// 鼠标在舞台里的位置；不在舞台里为 nil。
    var mouse: CGPoint?
    /// 舞台大小。
    var size = CGSize(width: 640, height: 560) { didSet { layout() } }

    /// 连续演示开始的时刻；没在演示为 nil。
    private(set) var scriptStart: TimeInterval?
    /// 连续演示的总时长（秒）。
    static let scriptDuration: TimeInterval = 9.2

    private(set) var actors: [Actor]
    private var lastFrameTime: TimeInterval?

    init() {
        // 都是系统自带的通用图标：不读用户的任何文件。
        let workspace = NSWorkspace.shared
        let standard = SampleIcon.standardSet()
        let icons = [
            standard[0], standard[1], standard[2],
            SampleIcon(label: "图片", image: workspace.icon(for: .image)),
            SampleIcon(label: "磁盘", image: workspace.icon(for: .volume)),
            standard[1],
            SampleIcon(label: "应用", image: workspace.icon(for: .applicationBundle)),
            standard[0],
        ]
        actors = icons.enumerated().map { index, icon in
            Actor(icon: icon, seed: IconID(rawValue: UInt64(index + 11)).faceSeed)
        }
        layout()
    }

    /// 把图标排成两排。
    private func layout() {
        let columns = 4
        let stepX = max(iconSize + 44, (size.width - 80) / CGFloat(columns))
        let stepY = iconSize + 84
        let left = (size.width - stepX * CGFloat(columns)) / 2 + stepX / 2
        for index in actors.indices {
            let column = index % columns
            let row = index / columns
            actors[index].home = CGPoint(
                x: left + stepX * CGFloat(column) - (row == 1 ? 0 : 0),
                y: 70 + iconSize / 2 + stepY * CGFloat(row)
            )
        }
    }

    /// 废纸篓：右下角。
    var trashRect: CGRect {
        CGRect(x: size.width - 108, y: size.height - 112, width: 72, height: 84)
    }

    func startScript(at time: TimeInterval) {
        scriptStart = time
    }

    var isPlayingScript: Bool { scriptStart != nil }

    // MARK: - 每一帧

    func frame(at time: TimeInterval) -> Frame {
        let delta = min(max(time - (lastFrameTime ?? time), 0), 0.1)
        lastFrameTime = time
        if let start = scriptStart {
            let elapsed = time - start
            if elapsed < Stage.scriptDuration {
                return scriptFrame(elapsed: elapsed, time: time)
            }
            scriptStart = nil
        }
        return liveFrame(time: time, delta: delta)
    }

    private func rect(around center: CGPoint, scale: CGFloat = 1) -> CGRect {
        let side = iconSize * scale
        return CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
    }

    /// 眨眼：每个图标按自己的节奏，隔几秒眨一下。是时间的纯函数，不需要记状态。
    private func blink(for actor: Actor, at time: TimeInterval) -> Double {
        var random = SeededRandom(seed: SeededRandom.derive(actor.seed, stream: 7))
        let period = 3.2 + 2.6 * random.nextUnit()
        let offset = Double(actor.seed % 1000) / 1000 * period
        let position = (time + offset).truncatingRemainder(dividingBy: period)
        let duration = 0.17
        return position < duration ? sin(.pi * position / duration) : 0
    }

    private func gaze(from actor: Actor, to point: CGPoint?) -> CGVector {
        guard let point else { return .zero }
        return point.offset(from: actor.home)
    }

    /// "自动"和"指定表情"两种玩法。
    private func liveFrame(time: TimeInterval, delta: TimeInterval) -> Frame {
        var frame = Frame(trash: trashRect)
        let target = followsMouse ? mouse : nil
        for index in actors.indices {
            let iconRect = rect(around: actors[index].home)
            let gaze = gaze(from: actors[index], to: target)
            var state: FaceState
            switch mode {
            case .live:
                // 鼠标停在谁身上谁就害羞；渐入渐出。
                let hovered = mouse.map { iconRect.insetBy(dx: -4, dy: -4).contains($0) } ?? false
                let goal: Double = hovered ? 1 : 0
                actors[index].blush += (goal - actors[index].blush) * (1 - exp(-delta / 0.14))
                if abs(actors[index].blush - goal) < 0.002 { actors[index].blush = goal }
                state = ExpressionPreset.shy.state(seed: actors[index].seed, intensity: actors[index].blush, gaze: gaze)
                state.mood = actors[index].blush > 0.5 ? .shy : .calm
                state.gazeFollow = target == nil ? 0 : 1
                state.blink = blink(for: actors[index], at: time)
            case let .preset(preset):
                actors[index].blush = 0
                state = preset.state(seed: actors[index].seed, intensity: intensity, gaze: gaze, peek: peek)
                if preset != .dozing { state.gazeFollow = target == nil ? 0 : 1 }
                if preset == .calm { state.blink = max(blink(for: actors[index], at: time), intensity < 1 ? 1 - intensity : 0) }
            }
            var placement = Placement(icon: actors[index].icon, rect: iconRect, state: state)
            if state.mood == .ghost { placement.iconAlpha = 0.14 }
            frame.placements.append(placement)
        }
        return frame
    }

    /// 连续演示：第 0 个图标被拖向废纸篓。
    private func scriptFrame(elapsed t: TimeInterval, time: TimeInterval) -> Frame {
        var frame = Frame(trash: trashRect)
        let victim = actors[0]
        let trashCenter = trashRect.center
        func smooth(_ from: Double, _ to: Double, _ x: Double) -> Double {
            let k = min(max((x - from) / (to - from), 0), 1)
            return k * k * (3 - 2 * k)
        }

        // 时间线（秒）：0–0.7 被抓起；0.7–4.2 拖向废纸篓；4.2–4.9 悬在废纸篓上方大哭；
        // 4.9–5.3 掉进去；5.3–7.9 幽灵从原位飘起；7.9–9.2 虚惊一场，图标回到原位。
        let travel = smooth(0.7, 4.2, t)
        let drop = smooth(4.9, 5.3, t)
        let ghost = min(max((t - 5.3) / 2.6, 0), 1)
        let comeBack = smooth(8.1, 9.0, t)

        // 被拖的图标的位置：沿一条略带弧度的路线过去，手还有点抖。
        let hover = CGPoint(x: trashCenter.x - 6, y: trashRect.minY - iconSize * 0.42)
        var position = CGPoint(
            x: victim.home.x + (hover.x - victim.home.x) * travel,
            y: victim.home.y + (hover.y - victim.home.y) * travel - sin(travel * .pi) * 46
        )
        position.x += sin(t * 5.1) * 3 * travel * (1 - drop)
        position.y += (trashCenter.y - hover.y) * drop
        let scale = CGFloat(1 - 0.85 * drop)

        // 离废纸篓越近越怕；过了大半程开始掉泪，悬在上方时哭到最凶。
        let near = smooth(0.15, 0.95, travel)
        var victimState = FaceState(mood: .scared, seed: victim.seed)
        victimState.gazeTarget = trashCenter.offset(from: position)
        victimState.gazeFollow = 1
        victimState.fear = 0.15 + 0.85 * near
        victimState.sweat = near
        victimState.tremble = 0.85 * near
        victimState.tears = smooth(0.62, 0.98, travel)
        if victimState.tears > 0.5 { victimState.mood = .crying }

        if t < 5.3 {
            frame.placements.append(Placement(
                icon: victim.icon, rect: rect(around: position, scale: scale), state: victimState
            ))
            // 假指针抓在图标的右下角。
            frame.cursor = CGPoint(x: position.x + iconSize * 0.2 * scale, y: position.y + iconSize * 0.25 * scale)
        } else if t < 7.9 {
            var state = FaceState(mood: .ghost, seed: victim.seed)
            state.ghost = ghost
            frame.placements.append(Placement(icon: victim.icon, rect: rect(around: victim.home), state: state, iconAlpha: 0))
        } else {
            // 回到原位：惊魂未定，慢慢平复。
            var state = FaceState(mood: .scared, seed: victim.seed)
            state.fear = 0.5 * (1 - comeBack)
            state.sweat = 0.6 * (1 - comeBack)
            state.gazeTarget = gaze(from: victim, to: mouse)
            state.gazeFollow = mouse == nil ? 0 : comeBack
            frame.placements.append(Placement(
                icon: victim.icon, rect: rect(around: victim.home, scale: CGFloat(0.4 + 0.6 * comeBack)),
                state: state, iconAlpha: CGFloat(comeBack)
            ))
        }

        // 邻居：先是盯着被拖走的同伴，越看越怕；快到废纸篓时捂眼（一半的图标从指缝偷看）；
        // 幽灵飘起时放下手、含着泪目送；最后平复。
        let ghostCenter = CGPoint(x: victim.home.x, y: victim.home.y - iconSize * ghost)
        for (index, actor) in actors.enumerated().dropFirst() {
            var state = FaceState(mood: .calm, seed: actor.seed)
            let watching = t < 5.3 ? position : ghostCenter
            state.gazeTarget = watching.offset(from: actor.home)
            state.gazeFollow = 1 - comeBack * (mouse == nil ? 1 : 0)
            if comeBack > 0, let mouse {
                let toMouse = mouse.offset(from: actor.home)
                state.gazeTarget = CGVector(
                    dx: state.gazeTarget.dx + (toMouse.dx - state.gazeTarget.dx) * comeBack,
                    dy: state.gazeTarget.dy + (toMouse.dy - state.gazeTarget.dy) * comeBack
                )
            }
            let coverUp = smooth(0.55, 0.8, travel) * (1 - smooth(5.3, 5.9, t))
            state.fear = 0.55 * near * (1 - smooth(5.3, 6.5, t))
            state.cover = coverUp
            state.peek = index.isMultiple(of: 2) ? 0.9 * smooth(0.8, 0.95, travel) : 0
            state.tears = 0.32 * smooth(5.4, 6.2, t) * (1 - smooth(7.6, 8.8, t))
            state.blink = blink(for: actor, at: time) * (1 - coverUp)
            if coverUp > 0.5 { state.mood = .coveringEyes } else if state.fear > 0.3 { state.mood = .scared }
            frame.placements.append(Placement(icon: actor.icon, rect: rect(around: actor.home), state: state))
        }
        // 被拖的图标要画在最上面。
        frame.placements.append(frame.placements.removeFirst())
        return frame
    }
}
