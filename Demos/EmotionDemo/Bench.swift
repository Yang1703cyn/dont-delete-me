// EmotionDemo · 耗时测量
//
// 运行：swift run -c release EmotionDemo --bench
// 量的是情绪引擎一次 update 的耗时（100 个编造的图标），不含绘制。请用发布版量，调试版慢得多。

import CoreGraphics
import DDMCore
import Emotion
import Foundation

func runBench(iconCount: Int = 100) {
    let clock = ContinuousClock()
    var icons: [DesktopIcon] = []
    for index in 0..<iconCount {
        // 两块屏：左侧外接屏（x 为负）和内屏各一半。
        let column = index % 10, row = index / 10
        let x = (index % 2 == 0 ? -1700 : 150) + 120 * CGFloat(column)
        var icon = makeIcon(UInt64(index + 1), center: CGPoint(x: x, y: 80 + 90 * CGFloat(row)))
        icon.modifiedAt = DemoStage.today.addingTimeInterval(-86400 * (index % 4 == 0 ? 400 : 3))
        icons.append(icon)
    }
    let snapshot = IconSnapshot(icons: icons, status: .ok, capturedAt: 0, revision: 1)
    let trashRect = CGRect(x: 1300, y: 900, width: 60, height: 70)

    /// 预先把一段输入造好，量的时候只调 update。
    func inputs(frames: Int, _ facts: (Int, FrameTime) -> InteractionFacts) -> [EmotionInput] {
        (0..<frames).map { frame in
            let time = FrameTime(monotonic: 100 + Double(frame) / 60, wallClock: DemoStage.today)
            return EmotionInput(
                time: time,
                icons: frame == 0 ? IconUpdate(snapshot: snapshot, isReset: true) : .unchanged(snapshot),
                facts: facts(frame, time)
            )
        }
    }

    func measure(_ title: String, _ inputs: [EmotionInput]) {
        var director = EmotionDirector(seed: 42)
        // 先走一小段让状态进入正题。
        var warm = 0
        while warm < min(300, inputs.count / 4) {
            _ = director.update(inputs[warm])
            warm += 1
        }
        var worst = Duration.zero
        var total = Duration.zero
        var faces = 0
        var continuous = 0
        for input in inputs[warm...] {
            let started = clock.now
            let output = director.update(input)
            let took = clock.now - started
            total += took
            if took > worst { worst = took }
            faces += output.faces.count
            if output.demand == .continuous { continuous += 1 }
        }
        let count = inputs.count - warm
        func ms(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        }
        print(String(
            format: "  %@  平均 %.4f 毫秒  最慢 %.4f 毫秒  （%d 帧，平均每帧 %.0f 张脸，%.0f%% 的帧要求连续出帧）",
            pad(title, 34), ms(total) / Double(count), ms(worst), count, Double(faces) / Double(count), 100 * Double(continuous) / Double(count)
        ))
    }

    #if DEBUG
    print("注意：这是调试版，数字比发布版慢好几倍。请用 swift run -c release EmotionDemo --bench。")
    #endif
    print("情绪引擎一次 update 的耗时，\(iconCount) 个图标（目标：不超过约 0.2 毫秒）：")

    measure("鼠标不动（只有眨眼）", inputs(frames: 6000) { _, time in
        InteractionFacts(time: time, mouse: MouseState(position: CGPoint(x: 700, y: 500), idleDuration: 3))
    })
    measure("鼠标一直在动（全员跟随）", inputs(frames: 6000) { frame, time in
        let t = Double(frame) / 60
        return InteractionFacts(time: time, mouse: MouseState(position: CGPoint(x: 700 + 600 * cos(t * 1.3), y: 500 + 350 * sin(t * 1.7))))
    })
    measure("鼠标在图标之间悬停", inputs(frames: 6000) { frame, time in
        let icon = icons[(frame / 45) % icons.count]
        return InteractionFacts(
            time: time, mouse: MouseState(position: icon.imageRect.center),
            hover: frame % 45 > 5 ? HoverState(iconID: icon.id, duration: 0.2) : nil
        )
    })
    measure("拖向废纸篓，全体围观（最热闹）", inputs(frames: 6000) { frame, time in
        // 每 5 秒一轮：从远处拖向废纸篓，在上方晃一会儿。
        let phase = Double(frame % 300) / 300
        let k = CGFloat(min(phase / 0.6, 1))
        let wobble = CGFloat(sin(Double(frame) * 0.4)) * 12
        let position = CGPoint(x: 400 + (trashRect.midX - 400) * k + wobble, y: 300 + (trashRect.midY - 300) * k)
        let drag = DragState(
            iconID: icons[7].id, grabOffset: CGVector(dx: 32, dy: 32), originImageRect: icons[7].imageRect,
            position: position, shake: phase < 0.2 ? 0.8 : 0.1, startedAt: 100
        )
        let trash = TrashInfo(
            estimatedRect: trashRect, confidence: 0.75, distance: trashRect.distance(to: position),
            isApproaching: phase < 0.6, isOver: trashRect.contains(position)
        )
        return InteractionFacts(time: time, mouse: MouseState(position: position, buttons: .left), drag: drag, trash: trash)
    })
    measure("一次删 10 个（幽灵 + 目送）", inputs(frames: 6000) { frame, time in
        var facts = InteractionFacts(time: time, mouse: MouseState(position: CGPoint(x: 700, y: 500), idleDuration: 1))
        if frame % 240 == 0 {
            facts.deletions = (0..<10).map { index in
                DeletionEvent(
                    iconID: IconID(rawValue: UInt64(100_000 + frame + index)),
                    lastImageRect: CGRect(x: 200 + 90 * CGFloat(index), y: 700, width: 64, height: 64),
                    wasDragged: false, trashed: .yes
                )
            }
        }
        return facts
    })
    measure("鼠标久不动（无聊，东张西望）", inputs(frames: 6000) { _, time in
        InteractionFacts(time: time, mouse: MouseState(position: CGPoint(x: 700, y: 500), idleDuration: 30))
    })

    print("")
    print("鼠标不动时的出帧量——严格按引擎给的需求出帧（要连续就每 1/60 秒一帧，否则睡到它说的时刻）：")
    print("  （\"重画\"= 表情与上一帧不同的脸的张数；表情模块自己的循环小动画不算在内）")
    for count in [10, 30, 100] {
        idleLoad(iconCount: count)
    }

    print("")
    print("围观高峰时有多少张脸要重画（每帧平均）：")
    for count in [30, 100] {
        crowdLoad(iconCount: count)
    }
}

/// 一桌都不打瞌睡的图标（量出帧量时不想让"睡着的不眨眼"把数字拉低）。
private func awakeIcons(_ count: Int) -> [DesktopIcon] {
    (0..<count).map { index in
        makeIcon(UInt64(index + 1), center: CGPoint(x: 150 + 120 * CGFloat(index % 10), y: 80 + 90 * CGFloat(index / 10)))
    }
}

/// 鼠标一直不动，按需求出帧：各个阶段每秒要算几帧、重画几张脸。
private func idleLoad(iconCount: Int) {
    let icons = awakeIcons(iconCount)
    let snapshot = IconSnapshot(icons: icons, status: .ok, capturedAt: 0, revision: 1)
    var director = EmotionDirector(seed: 42)
    var now = 100.0
    var previous: [FacePlacement] = []
    var first = true
    /// 从鼠标已静止 `from` 秒走到 `to` 秒。返回（每秒帧数，每秒重画张数）。
    func phase(from: TimeInterval, to: TimeInterval) -> (frames: Double, redraws: Double) {
        var idle = from
        var frames = 0
        var redraws = 0
        while idle < to {
            let time = FrameTime(monotonic: now, wallClock: DemoStage.today)
            let facts = InteractionFacts(time: time, mouse: MouseState(position: CGPoint(x: 700, y: 950), idleDuration: idle))
            let output = director.update(EmotionInput(
                time: time, icons: first ? IconUpdate(snapshot: snapshot, isReset: true) : .unchanged(snapshot), facts: facts
            ))
            first = false
            frames += 1
            if previous.count == output.faces.count {
                redraws += zip(output.faces, previous).filter { $0.state != $1.state }.count
            }
            previous = output.faces
            var wait = frameInterval
            // 交互感知在鼠标静止时也会每 0.1 秒读一次鼠标，所以最多睡 0.1 秒。
            if case let .by(time) = output.demand { wait = min(max(time - now, frameInterval), 0.1) }
            if case .idle = output.demand { wait = 0.1 }
            now += wait
            idle += wait
        }
        return (Double(frames) / (to - from), Double(redraws) / (to - from))
    }
    let justStopped = phase(from: 1, to: 12)
    let bored = phase(from: 12, to: 60)
    _ = phase(from: 60, to: 120)
    let quiet = phase(from: 120, to: 240)
    print(String(
        format: "  %3d 个图标：刚停下（1～12 秒）每秒 %4.1f 帧、重画 %4.1f 张；无聊（12～60 秒）每秒 %4.1f 帧、重画 %4.1f 张；安静后（2 分钟以上）每秒 %4.1f 帧、重画 %4.1f 张",
        iconCount, justStopped.frames, justStopped.redraws, bored.frames, bored.redraws, quiet.frames, quiet.redraws
    ))
}

/// 一个图标被拖向废纸篓、其余围观：途中和高峰时每帧有多少张脸要重画。
private func crowdLoad(iconCount: Int) {
    let icons = awakeIcons(iconCount)
    let snapshot = IconSnapshot(icons: icons, status: .ok, capturedAt: 0, revision: 1)
    let trashRect = CGRect(x: 1300, y: 900, width: 60, height: 70)
    var director = EmotionDirector(seed: 42)
    var previous: [FacePlacement] = []
    /// 走 `frames` 帧，返回平均每帧（表情变了的张数，每帧都要重画的张数，两者合计）。
    func run(startFrame: Int, frames: Int, position: (Int) -> CGPoint, approaching: Bool) -> (changed: Double, everyFrame: Double, either: Double) {
        var changed = 0
        var everyFrame = 0
        var either = 0
        for frame in startFrame..<(startFrame + frames) {
            let time = FrameTime(monotonic: 100 + Double(frame) / 60, wallClock: DemoStage.today)
            let point = position(frame - startFrame)
            let drag = DragState(
                iconID: icons[0].id, grabOffset: CGVector(dx: 32, dy: 32), originImageRect: icons[0].imageRect,
                position: point, startedAt: 100
            )
            let trash = TrashInfo(
                estimatedRect: trashRect, confidence: 0.75, distance: trashRect.distance(to: point),
                isApproaching: approaching, isOver: trashRect.contains(point)
            )
            let facts = InteractionFacts(time: time, mouse: MouseState(position: point, buttons: .left), drag: drag, trash: trash)
            let output = director.update(EmotionInput(
                time: time, icons: frame == 0 ? IconUpdate(snapshot: snapshot, isReset: true) : .unchanged(snapshot), facts: facts
            ))
            if previous.count == output.faces.count {
                for (face, old) in zip(output.faces, previous) {
                    let isChanged = face.state != old.state
                    let isEveryFrame = redrawInterval(for: face.state) == 0
                    if isChanged { changed += 1 }
                    if isEveryFrame { everyFrame += 1 }
                    if isChanged || isEveryFrame { either += 1 }
                }
            }
            previous = output.faces
        }
        return (Double(changed) / Double(frames), Double(everyFrame) / Double(frames), Double(either) / Double(frames))
    }
    let start = icons[0].imageRect.center
    let approach = run(startFrame: 0, frames: 180, position: { frame in
        let k = CGFloat(frame) / 180
        return CGPoint(x: start.x + (trashRect.midX - start.x) * k, y: start.y + (trashRect.midY - start.y) * k)
    }, approaching: true)
    _ = run(startFrame: 180, frames: 120, position: { _ in trashRect.center }, approaching: false)
    let hovering = run(startFrame: 300, frames: 180, position: { _ in trashRect.center }, approaching: false)
    let wobbling = run(startFrame: 480, frames: 180, position: { frame in
        CGPoint(x: trashRect.midX + 15 * CGFloat(sin(Double(frame) * 0.3)), y: trashRect.midY + 8 * CGFloat(cos(Double(frame) * 0.2)))
    }, approaching: false)
    print(String(
        format: "  %3d 个图标：拖过去的途中 %5.1f 张（其中每帧必画 %.1f）；悬在废纸篓上方不动 %4.1f 张（每帧必画 %.1f）；在上方晃动 %4.1f 张（每帧必画 %.1f）",
        iconCount, approach.either, approach.everyFrame, hovering.either, hovering.everyFrame, wobbling.either, wobbling.everyFrame
    ))
}
