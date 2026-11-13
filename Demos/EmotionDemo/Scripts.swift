// EmotionDemo · 内置剧本
//
// 每条剧本摆好一桌假图标，按时间线摆布鼠标、拖拽、结局等事实，隔一段时间打印一次所有的脸；
// 末尾有一段"小结"，把关键的时刻量出来并自己核对一遍（不符合预期时退出码为 1）。

import CoreGraphics
import DDMCore
import Emotion
import Foundation

/// 跑一条剧本用的小工具：推进、定时打印、记录事件、核对。
final class Runner {
    let stage: DemoStage
    let printer: Printer
    /// 每隔多久打印一次全貌。
    var sampleEvery: TimeInterval
    /// 是否把每次眨眼打印成一行事件。
    var printsBlinks = false
    /// 每一帧之后调用（量时刻用）。
    var onFrame: ((DemoStage) -> Void)?
    private(set) var failures = 0
    private var nextSample: TimeInterval = 0
    private var blinking: Set<IconID> = []
    private(set) var blinkCounts: [IconID: Int] = [:]

    init(stage: DemoStage, sampleEvery: TimeInterval) {
        self.stage = stage
        printer = Printer(stage: stage)
        self.sampleEvery = sampleEvery
    }

    /// 一直跑到剧本的第 `time` 秒。`body` 在每一帧之前调用，用来摆布这一帧的事实。
    func play(until time: TimeInterval, _ body: ((DemoStage) -> Void)? = nil) {
        while stage.elapsed < time - 1e-9 || nextSample == 0 {
            body?(stage)
            stage.step()
            for face in stage.output.faces where face.state.mood != .ghost {
                if face.state.blink > 0 {
                    if blinking.insert(face.iconID).inserted {
                        blinkCounts[face.iconID, default: 0] += 1
                        if printsBlinks { printer.event("\(stage.name(face.iconID)) 眨眼") }
                    }
                } else {
                    blinking.remove(face.iconID)
                }
            }
            onFrame?(stage)
            if stage.elapsed >= nextSample - 1e-9 {
                printer.sample()
                nextSample += sampleEvery
            }
        }
    }

    func note(_ text: String) {
        printer.event(text)
    }

    func check(_ ok: Bool, _ text: String) {
        print("  \(ok ? "✔" : "✘") \(text)")
        if !ok { failures += 1 }
    }
}

struct Script {
    let key: String
    let title: String
    let synopsis: String
    /// 跑完返回不符合预期的条数。
    let run: (_ sampleEvery: TimeInterval?) -> Int
}

private func calm(_ state: FaceState) -> Bool {
    state.blush == 0 && state.fear == 0 && state.sweat == 0 && state.tremble == 0 && state.tears == 0
        && state.dizziness == 0 && state.cover == 0 && state.sleepiness == 0
}

private func smoothstep(_ x: Double) -> CGFloat {
    let k = min(max(x, 0), 1)
    return CGFloat(k * k * (3 - 2 * k))
}

private func describeCast(_ stage: DemoStage, trash: Bool = true) {
    let cast = stage.icons.map { icon in
        "\(stage.name(icon.id))·\(personalityName(stage.director.personality(of: icon.id))) (\(Int(icon.imageRect.midX)),\(Int(icon.imageRect.midY)))"
    }
    print("桌面：" + cast.joined(separator: "  "))
    if trash, let rect = stage.trashRect {
        print("废纸篓（估算，可信度 \(stage.trashConfidence)）：中心 (\(Int(rect.midX)),\(Int(rect.midY)))")
    }
    print("每一行：图标·性格 / 画在哪一层 / 表情 / 不为零的参数 / 在看什么")
}

/// 把主角沿直线从 `from` 拖到 `to`（先慢后快再慢），进度由时间决定。
private func dragAlong(_ stage: DemoStage, from: CGPoint, to: CGPoint, start: TimeInterval, end: TimeInterval) {
    let k = smoothstep((stage.elapsed + frameInterval - start) / (end - start))
    stage.dragTo(CGPoint(x: from.x + (to.x - from.x) * k, y: from.y + (to.y - from.y) * k))
}

@MainActor let scripts: [Script] = [
    Script(key: "everyday", title: "平时", synopsis: "鼠标划过桌面再停住：眼睛跟着鼠标，各自随机眨眼") { every in
        let stage = DemoStage(icons: makeCast([.timid, .curious, .bold, .timid, .curious]))
        let runner = Runner(stage: stage, sampleEvery: every ?? 1.0)
        runner.printsBlinks = true
        describeCast(stage, trash: false)
        stage.mouse = CGPoint(x: 300, y: 250)
        runner.note("鼠标从 (300,250) 划向 (1150,700)")
        runner.play(until: 3) { stage in
            let k = smoothstep(stage.elapsed / 3)
            stage.mouse = CGPoint(x: 300 + 850 * k, y: 250 + 450 * k)
        }
        runner.note("鼠标停住")
        runner.play(until: 11)
        print("小结：")
        let onMouse = stage.icons.allSatisfy { stage.face($0.id)?.state.gazeTarget == stage.mouse.offset(from: $0.imageRect.center) }
        runner.check(onMouse, "鼠标停住后，所有图标都正好盯着鼠标")
        runner.check(stage.icons.allSatisfy { calm(stage.face($0.id)!.state) }, "全程只有平静的脸")
        let counts = stage.icons.map { "\(stage.name($0.id)) \(runner.blinkCounts[$0.id] ?? 0) 次" }.joined(separator: "，")
        runner.check(stage.icons.allSatisfy { (runner.blinkCounts[$0.id] ?? 0) >= 1 }, "11 秒里每个图标都眨过眼：\(counts)")
        return runner.failures
    },

    Script(key: "hover", title: "悬停", synopsis: "鼠标停在「乙」上 1.5 秒再移开：脸红、眼神躲闪，移开后慢慢恢复") { every in
        let stage = DemoStage(icons: makeCast([.timid, .curious, .bold, .timid]))
        let runner = Runner(stage: stage, sampleEvery: every ?? 0.5)
        describeCast(stage, trash: false)
        let shy = stage.icons[1]
        var fullAt: TimeInterval?
        var clearAt: TimeInterval?
        runner.onFrame = { stage in
            let blush = stage.face(shy.id)?.state.blush ?? 0
            if blush == 1, fullAt == nil { fullAt = stage.elapsed }
            if blush == 0, fullAt != nil, clearAt == nil { clearAt = stage.elapsed }
        }
        stage.mouse = CGPoint(x: 700, y: 400)
        runner.play(until: 0.5)
        stage.hoverOn(shy.id, offset: CGVector(dx: 12, dy: 0))
        runner.note("鼠标停到「乙」上（中心偏右 12 点）")
        runner.play(until: 2.0)
        let hovered = stage.face(shy.id)!.state
        stage.moveMouse(to: CGPoint(x: 700, y: 400))
        runner.note("鼠标移开，回到 (700,400)")
        runner.play(until: 6.0)
        print("小结：")
        runner.check(hovered.mood == .shy && hovered.blush == 1, "悬停时「乙」害羞，脸红到 1.00（悬停后 \(String(format: "%.2f", (fullAt ?? 99) - 0.5)) 秒到顶）")
        runner.check(hovered.gazeTarget.dx < 0 && hovered.gazeTarget.dy > 0, "眼神躲闪：鼠标在右边，它看向左下 (\(Int(hovered.gazeTarget.dx)), \(Int(hovered.gazeTarget.dy)))")
        let fade = (clearAt ?? 99) - 2.0
        runner.check(fade > 1.5 && fade < 3.5, "移开后慢慢恢复：\(String(format: "%.2f", fade)) 秒后脸红退尽")
        runner.check(stage.icons.allSatisfy { calm(stage.face($0.id)!.state) }, "最后全体平静")
        return runner.failures
    },

    Script(key: "trash", title: "拖向废纸篓并删除", synopsis: "「丁」被拖向废纸篓：冒汗 → 发抖 → 大哭，其余由近到远围观；松手被删，原位置飘起幽灵") { every in
        let stage = DemoStage(icons: makeCast([.timid, .curious, .bold, .curious, .timid, .bold, .curious]))
        let runner = Runner(stage: stage, sampleEvery: every ?? 0.5)
        describeCast(stage)
        let star = stage.icons[3]
        let home = star.imageRect
        let from = home.center
        let trash = stage.trashRect!.center
        var firstReaction: [IconID: TimeInterval] = [:]
        var alarmAt: TimeInterval?
        var epicenter = CGPoint.zero
        var ghostFrom: TimeInterval?
        var ghostUntil: TimeInterval?
        var stages: [String: TimeInterval] = [:]
        runner.onFrame = { stage in
            if let face = stage.face(star.id) {
                if face.state.sweat > 0, stages["汗"] == nil { stages["汗"] = stage.elapsed }
                if face.state.tremble > 0, stages["抖"] == nil { stages["抖"] = stage.elapsed }
                if face.state.tears > 0.4, stages["哭"] == nil { stages["哭"] = stage.elapsed }
            }
            for icon in stage.icons where icon.id != star.id && firstReaction[icon.id] == nil {
                guard let state = stage.face(icon.id)?.state, state.fear > 0 || state.cover > 0 else { continue }
                firstReaction[icon.id] = stage.elapsed
                if alarmAt == nil {
                    alarmAt = stage.elapsed
                    epicenter = stage.face(star.id)?.rect.center ?? .zero
                }
            }
            if !stage.ghosts.isEmpty {
                if ghostFrom == nil { ghostFrom = stage.elapsed }
                ghostUntil = stage.elapsed
            }
        }
        stage.mouse = CGPoint(x: 900, y: 500)
        runner.play(until: 0.5)
        stage.startDrag(star.id)
        runner.note("抓起「丁」，拖向废纸篓")
        runner.play(until: 3.5) { stage in dragAlong(stage, from: from, to: trash, start: 0.5, end: 3.5) }
        runner.note("到了废纸篓上方，悬着")
        runner.play(until: 4.6 - frameInterval)
        // 高峰时有多少张脸要重画：比较相邻两帧。
        let previousFaces = stage.output.faces
        runner.play(until: 4.6)
        let peakEveryFrame = stage.output.faces.filter { redrawInterval(for: $0.state) == 0 }.count
        let peakChanging = zip(stage.output.faces, previousFaces).filter { $0.state != $1.state || redrawInterval(for: $0.state) == 0 }.count
        let crying = stage.face(star.id)!.state
        let bystanders = stage.icons.filter { $0.id != star.id }
        let reactions = bystanders.map { stage.face($0.id)!.state }
        stage.release()
        runner.note("松手")
        runner.play(until: 4.75)
        let waiting = stage.face(star.id)
        stage.settleTrashed(star.id)
        runner.note("结局：进了废纸篓（同一帧收到删除事件）")
        runner.play(until: 10)

        print("小结：")
        runner.check((stages["汗"] ?? 99) < (stages["抖"] ?? 99) && (stages["抖"] ?? 99) < (stages["哭"] ?? 99),
                     String(format: "主角先冒汗（%.2fs）→ 再发抖（%.2fs）→ 最后哭（%.2fs）", stages["汗"] ?? -1, stages["抖"] ?? -1, stages["哭"] ?? -1))
        runner.check(crying.mood == .crying && crying.tears == 1, "悬在废纸篓上方时大哭（泪 1.00）")
        let order = bystanders.sorted { $0.imageRect.center.distance(to: epicenter) < $1.imageRect.center.distance(to: epicenter) }
        let ripple = order.map { String(format: "%@ %.0f点 +%.2fs", stage.name($0.id), $0.imageRect.center.distance(to: epicenter), (firstReaction[$0.id] ?? 99) - (alarmAt ?? 0)) }
        let times = order.map { firstReaction[$0.id] ?? 99 }
        runner.check(zip(times, times.dropFirst()).allSatisfy { $0 <= $1 } && times.allSatisfy { $0 < 99 },
                     String(format: "围观由近到远传开（离主角当时位置的距离，以及比第一个有反应的 %.2fs 晚多久）：", alarmAt ?? -1) + ripple.joined(separator: "，"))
        runner.check(peakEveryFrame == 1 && peakChanging == 1,
                     "围观高峰（主角悬在废纸篓上方不动）：每帧必须重画的脸 \(peakEveryFrame) 张（主角自己），表情还在变的脸 \(peakChanging) 张；其余 \(bystanders.count) 张是静止画面")
        var byKind: [EmotionPersonality: [String]] = [:]
        for (icon, state) in zip(bystanders, reactions) {
            let kind = stage.director.personality(of: icon.id)
            byKind[kind, default: []].append(String(format: "%@ 捂眼 %.2f 偷看 %.2f 惊恐 %.2f", stage.name(icon.id), state.cover, state.peek, state.fear))
            switch kind {
            case .timid: runner.check(state.cover == 1 && state.peek == 0, "胆小的捂眼不看：" + byKind[kind]!.last!)
            case .curious: runner.check(state.cover == 1 && state.peek > 0.8, "好奇的从指缝偷看：" + byKind[kind]!.last!)
            case .bold: runner.check(state.cover == 0 && state.fear > 0.6, "胆大的瞪眼看：" + byKind[kind]!.last!)
            }
        }
        runner.check(waiting?.layer == .drag && (waiting?.state.tears ?? 0) == 1, "松手后、结局出来前：脸还在松手处（拖拽层），还在哭")
        let lifetime = (ghostUntil ?? 0) - (ghostFrom ?? 0)
        runner.check(abs((ghostFrom ?? 0) - 4.75) < 0.03 && lifetime > 2.5 && lifetime < 2.7,
                     String(format: "幽灵 %.2fs 出现在「丁」的原位置，飘了 %.2f 秒后消散", ghostFrom ?? -1, lifetime))
        runner.check(stage.face(star.id) == nil && stage.output.faces.count == bystanders.count, "「丁」不再有脸；剩下 \(bystanders.count) 张")
        runner.check(bystanders.allSatisfy { calm(stage.face($0.id)!.state) }, "最后围观者全体恢复平静")
        _ = home
        return runner.failures
    },

    Script(key: "false-alarm", title: "虚惊一场", synopsis: "「丁」被拖到废纸篓旁边吓哭，最后松在桌面上（挪了位置）：汗慢慢收，围观者放下手") { every in
        let stage = DemoStage(icons: makeCast([.timid, .curious, .bold, .curious, .timid, .bold]))
        let runner = Runner(stage: stage, sampleEvery: every ?? 0.5)
        describeCast(stage)
        let star = stage.icons[3]
        let from = star.imageRect.center
        let beside = CGPoint(x: stage.trashRect!.minX - 45, y: stage.trashRect!.midY - 60)
        var goneAt: [String: TimeInterval] = [:]
        var handsDownAt: TimeInterval?
        var releasedAt: TimeInterval = 0
        runner.onFrame = { stage in
            guard releasedAt > 0, let state = stage.face(star.id)?.state else { return }
            if state.tears == 0, goneAt["泪"] == nil { goneAt["泪"] = stage.elapsed - releasedAt }
            if state.tremble == 0, goneAt["抖"] == nil { goneAt["抖"] = stage.elapsed - releasedAt }
            if state.fear == 0, goneAt["惊恐"] == nil { goneAt["惊恐"] = stage.elapsed - releasedAt }
            if state.sweat == 0, goneAt["汗"] == nil { goneAt["汗"] = stage.elapsed - releasedAt }
            if handsDownAt == nil, stage.icons.allSatisfy({ ($0.id == star.id) || (stage.face($0.id)?.state.cover ?? 0) == 0 }) {
                handsDownAt = stage.elapsed - releasedAt
            }
        }
        stage.mouse = CGPoint(x: 900, y: 500)
        runner.play(until: 0.5)
        stage.startDrag(star.id)
        runner.note("抓起「丁」，拖向废纸篓旁边")
        runner.play(until: 3.0) { stage in dragAlong(stage, from: from, to: beside, start: 0.5, end: 3.0) }
        runner.note("停在废纸篓左上方约 60 点处")
        runner.play(until: 4.0)
        let scared = stage.face(star.id)!.state
        let covering = stage.icons.filter { (stage.face($0.id)?.state.cover ?? 0) > 0.9 }.count
        stage.release()
        runner.note("松手（松在桌面上）")
        runner.play(until: 4.1)
        let newRect = stage.released[0].imageRectAtRelease.offsetBy(dx: -3, dy: 0)
        stage.settleMoved(star.id, to: newRect)
        releasedAt = stage.elapsed
        runner.note("结局：挪了位置（虚惊一场）")
        runner.play(until: 10)

        print("小结：")
        runner.check(scared.tears > 0.4 && scared.sweat == 1, String(format: "松手前主角吓哭了（泪 %.2f、汗 %.2f、发抖 %.2f），%d 个围观者捂着眼", scared.tears, scared.sweat, scared.tremble, covering))
        runner.check(stage.face(star.id)?.rect == newRect && stage.face(star.id)?.layer == .desktop, "结局一出，脸落在图标的新位置、回到桌面层")
        runner.check((goneAt["汗"] ?? 0) > (goneAt["泪"] ?? 99) && (goneAt["汗"] ?? 0) > (goneAt["抖"] ?? 99) && (goneAt["汗"] ?? 0) > 2,
                     String(format: "汗最后才收干净：发抖 %.2f 秒、泪 %.2f 秒、惊恐 %.2f 秒、汗 %.2f 秒后消失", goneAt["抖"] ?? -1, goneAt["泪"] ?? -1, goneAt["惊恐"] ?? -1, goneAt["汗"] ?? -1))
        runner.check((handsDownAt ?? 99) < 1.5, String(format: "围观者 %.2f 秒后全部放下手", handsDownAt ?? -1))
        runner.check(stage.icons.allSatisfy { calm(stage.face($0.id)!.state) } && stage.output.faces.count == stage.icons.count, "最后全体恢复平静，一张脸都不少")
        return runner.failures
    },

    Script(key: "shake", title: "猛甩", synopsis: "抓着「丙」来回猛甩 1.5 秒再松手：头晕转圈，松手后再晕两三秒") { every in
        let stage = DemoStage(icons: makeCast([.timid, .curious, .bold, .timid]))
        let runner = Runner(stage: stage, sampleEvery: every ?? 0.5)
        stage.trashRect = nil
        describeCast(stage, trash: false)
        let star = stage.icons[2]
        var peak = 0.0
        var releasedAt: TimeInterval = 0
        var fadedAt: TimeInterval?
        var clearAt: TimeInterval?
        runner.onFrame = { stage in
            let value = stage.face(star.id)?.state.dizziness ?? 0
            peak = max(peak, value)
            guard releasedAt > 0 else { return }
            if value < 0.25, fadedAt == nil { fadedAt = stage.elapsed - releasedAt }
            if value == 0, clearAt == nil { clearAt = stage.elapsed - releasedAt }
        }
        stage.mouse = CGPoint(x: 800, y: 500)
        runner.play(until: 0.5)
        stage.startDrag(star.id)
        runner.note("抓起「丙」，拖到 (700,450)")
        runner.play(until: 1.0) { stage in dragAlong(stage, from: star.imageRect.center, to: CGPoint(x: 700, y: 450), start: 0.5, end: 1.0) }
        let before = stage.face(star.id)!.state
        runner.note("开始来回猛甩（交互感知给的甩动强度升到 0.9）")
        runner.play(until: 2.5) { stage in
            let phase = (stage.elapsed - 1.0) * 3.5 * 2 * .pi
            stage.dragTo(CGPoint(x: 700 + 110 * CGFloat(sin(phase)), y: 450))
            stage.drag?.shake = min(0.9, (stage.elapsed - 1.0) * 1.5)
        }
        stage.release()
        releasedAt = stage.elapsed
        runner.note("松手")
        runner.play(until: 2.6)
        stage.settleMoved(star.id, to: stage.released[0].imageRectAtRelease)
        runner.note("结局：挪了位置")
        runner.play(until: 7)

        print("小结：")
        runner.check(before.dizziness == 0, "平稳拖动时不晕")
        runner.check(peak > 0.8, String(format: "猛甩时头晕到 %.2f", peak))
        runner.check((fadedAt ?? 0) > 1.5 && (fadedAt ?? 99) < 3.0, String(format: "松手后再晕 %.2f 秒才缓过来（头晕退到 0.25 以下，眼睛不再是漩涡）", fadedAt ?? -1))
        runner.check((clearAt ?? 99) < 4.0, String(format: "松手后 %.2f 秒彻底恢复", clearAt ?? -1))
        runner.check(stage.icons.allSatisfy { calm(stage.face($0.id)!.state) }, "最后全体平静")
        return runner.failures
    },

    Script(key: "doze", title: "打瞌睡", synopsis: "6 个图标里 3 个超过半年没动，只有最久的 2 个睡；鼠标靠近「戊」把它惊醒，停住不动后它再慢慢睡着") { every in
        let stage = DemoStage(icons: makeCast([.timid, .curious, .bold, .timid, .curious, .bold], dozing: [1, 3, 4]))
        let runner = Runner(stage: stage, sampleEvery: every ?? 1.0)
        stage.trashRect = nil
        describeCast(stage, trash: false)
        print("最近修改：甲 20 天前，乙 450 天前，丙 20 天前，丁 550 天前，戊 600 天前，己 20 天前（半年 = 182.5 天；6 个图标最多睡 2 个）")
        let sleeper = stage.icons[4]
        stage.mouse = CGPoint(x: 500, y: 700)
        stage.idle = 5
        var wokeAt: TimeInterval?
        var asleepAgainAt: TimeInterval?
        var nearAt: TimeInterval?
        runner.onFrame = { stage in
            let value = stage.face(sleeper.id)?.state.sleepiness ?? 0
            if nearAt == nil, sleeper.imageRect.distance(to: stage.mouse) < 90 { nearAt = stage.elapsed }
            if value == 0, wokeAt == nil { wokeAt = stage.elapsed }
            if value == 1, wokeAt != nil, asleepAgainAt == nil { asleepAgainAt = stage.elapsed }
        }
        runner.play(until: 2)
        let sleepers = stage.icons.filter { (stage.face($0.id)?.state.sleepiness ?? 0) == 1 }.map { stage.name($0.id) }
        runner.note("鼠标晃到「戊」旁边")
        let near = CGPoint(x: sleeper.imageRect.minX - 40, y: sleeper.imageRect.midY)
        runner.play(until: 3) { stage in
            let k = smoothstep(stage.elapsed - 2)
            stage.mouse = CGPoint(x: 500 + (near.x - 500) * k, y: 700 + (near.y - 700) * k)
        }
        runner.note("鼠标停在它旁边不动了")
        runner.play(until: 16)

        print("小结：")
        runner.check(sleepers == ["丁", "戊"], "一开始睡着的是最久没动的两个：\(sleepers.joined(separator: "、"))（乙也超过半年，但名额只有 2 个）")
        runner.check((wokeAt ?? 99) - (nearAt ?? 0) < 0.5, String(format: "鼠标 %.2fs 进到「戊」90 点以内，它 %.2fs 完全清醒（惊醒用了 %.2f 秒）", nearAt ?? -1, wokeAt ?? -1, (wokeAt ?? 99) - (nearAt ?? 0)))
        let dozeOff = (asleepAgainAt ?? 99) - 3
        runner.check(dozeOff > 7 && dozeOff < 12, String(format: "鼠标停住后它又看了一会儿，%.2f 秒后重新睡熟（%.2fs）", dozeOff, asleepAgainAt ?? -1))
        return runner.failures
    },

    Script(key: "bored", title: "彩蛋·无聊", synopsis: "鼠标 12 秒不动：图标们开始东张西望；鼠标一动立刻回神") { every in
        let stage = DemoStage(icons: makeCast([.timid, .curious, .bold, .timid, .curious, .bold]))
        let runner = Runner(stage: stage, sampleEvery: every ?? 2.0)
        stage.trashRect = nil
        describeCast(stage, trash: false)
        stage.mouse = CGPoint(x: 600, y: 600)
        var wandering: Set<IconID> = []
        var everWandered: Set<IconID> = []
        var firstAt: TimeInterval?
        var movedAt: TimeInterval = 0
        var backAt: TimeInterval?
        runner.onFrame = { stage in
            var now: Set<IconID> = []
            for icon in stage.icons where stage.face(icon.id)?.state.gazeTarget != stage.mouse.offset(from: icon.imageRect.center) {
                now.insert(icon.id)
            }
            if movedAt == 0 {
                for id in now.subtracting(wandering) {
                    if firstAt == nil { firstAt = stage.elapsed }
                    runner.note("「\(stage.name(id))」张望")
                }
                everWandered.formUnion(now)
            } else if now.isEmpty, backAt == nil {
                backAt = stage.elapsed - movedAt
            }
            wandering = now
        }
        runner.note("鼠标停在 (600,600) 不动")
        runner.play(until: 24)
        // 等到正好有图标在张望时动一下鼠标。
        runner.play(until: 40) { stage in
            if movedAt == 0, !wandering.isEmpty, stage.elapsed > 24 {
                movedAt = stage.elapsed
                stage.mouse.x += 6
                runner.note("鼠标动了一下")
            } else if movedAt > 0, stage.elapsed - movedAt > 2 {
                stage.mouse.x += 0.5   // 之后鼠标一直在慢慢动
            }
        }
        print("小结：")
        runner.check((firstAt ?? 0) >= 12 && (firstAt ?? 99) < 14, String(format: "第一次张望在 %.2fs（鼠标静止满 12 秒之后）", firstAt ?? -1))
        runner.check(everWandered.count >= 3, "24 秒之前共有 \(everWandered.count) 个图标张望过")
        runner.check((backAt ?? 99) < 0.5, String(format: "鼠标一动，%.2f 秒内全部重新盯住鼠标", backAt ?? -1))
        runner.check(wandering.isEmpty, "鼠标在动的时候没有图标张望")
        return runner.failures
    },

    Script(key: "newcomer", title: "彩蛋·新来的 + 一次删三个", synopsis: "桌面上多了一个「庚」：大家看它一眼，它眨几下眼；随后用快捷键一次删掉三个：幽灵错开出现") { every in
        let stage = DemoStage(icons: makeCast([.timid, .curious, .bold, .timid, .curious, .bold]))
        let runner = Runner(stage: stage, sampleEvery: every ?? 0.5)
        runner.printsBlinks = true
        stage.trashRect = nil
        describeCast(stage, trash: false)
        stage.mouse = CGPoint(x: 700, y: 650)
        var ghostAt: [IconID: TimeInterval] = [:]
        var lastGhostAt: TimeInterval = 0
        runner.onFrame = { stage in
            for ghost in stage.ghosts {
                if ghostAt[ghost.iconID] == nil { ghostAt[ghost.iconID] = stage.elapsed }
                lastGhostAt = stage.elapsed
            }
        }
        runner.play(until: 1)
        let fresh = makeIcon(rawID(of: .bold, from: 5000), center: CGPoint(x: 950, y: 300), modifiedAt: DemoStage.today)
        stage.addIcon(name: "庚", fresh)
        let blinksBefore = runner.blinkCounts[fresh.id] ?? 0
        runner.note("桌面上出现新图标「庚」(950,300)")
        var watchers = 0
        runner.play(until: 2) { stage in
            if stage.elapsed > 1.4 {
                watchers = stage.icons.filter { icon in
                    guard icon.id != fresh.id, let state = stage.face(icon.id)?.state else { return false }
                    let offset = fresh.imageRect.center.offset(from: icon.imageRect.center)
                    return abs(atan2(Double(state.gazeTarget.dy), Double(state.gazeTarget.dx)) - atan2(Double(offset.dy), Double(offset.dx))) < 0.05
                }.count
            }
        }
        runner.play(until: 4)
        let blinks = (runner.blinkCounts[fresh.id] ?? 0) - blinksBefore
        let victims = [stage.icons[0], stage.icons[2], stage.icons[5]]
        stage.deleteWithoutDrag(victims.map(\.id))
        runner.note("快捷键一次删掉 甲、丙、己（没有拖拽过程）")
        runner.play(until: 9)

        print("小结：")
        runner.check(watchers == 6, "新图标出现后，其余 \(watchers) 个图标都转头看着它")
        runner.check(blinks >= 3, "新图标在 3 秒里眨了 \(blinks) 下（出场连眨三下）")
        let appear = victims.map { String(format: "%@ %.2fs", stage.name($0.id), ghostAt[$0.id] ?? -1) }.joined(separator: "，")
        let gaps = zip(victims, victims.dropFirst()).map { (ghostAt[$1.id] ?? 0) - (ghostAt[$0.id] ?? 0) }
        runner.check(gaps.allSatisfy { abs($0 - 0.15) < 0.02 }, "三个幽灵错开 0.15 秒出现：\(appear)")
        runner.check(lastGhostAt < 4 + 0.3 + 2.6 + 0.05 && stage.ghosts.isEmpty, String(format: "最后一个幽灵在 %.2fs 消散", lastGhostAt))
        runner.check(stage.output.faces.count == 4 && stage.icons.allSatisfy { calm(stage.face($0.id)!.state) }, "剩下 4 个图标，全体平静")
        return runner.failures
    },
]
