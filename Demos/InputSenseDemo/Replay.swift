// InputSenseDemo · 剧本回放
//
// 用一条编好的鼠标轨迹把所有判断走一遍：悬停、单击、按住不动、被窗口挡住、挪位置、甩动、
// 拖进废纸篓（并且自学习）、取消、快捷键删除、鼠标静止后的省电信号。
// 时间是模拟的（每帧 1/60 秒），不读真实的鼠标、窗口和程序坞，所以瞬间跑完、每次输出都一样。

import CoreGraphics
import DDMCore
import Foundation
import InputSense

@MainActor
final class Replay {
    private let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let environment: SimulatedEnvironment
    private let sensor: InteractionSensor
    private let desktop: FakeDesktop
    private let narrator: Narrator
    private let icons: [DesktopIcon]

    private var time = FrameTime(monotonic: 0, wallClock: Date(timeIntervalSince1970: 1_800_000_000))
    private let frameInterval = 1.0 / 60
    private var facts: InteractionFacts
    private var frames = 0
    private var demandLabel = ""

    /// 一个盖住假图标 3 的窗口，和一个远处的大窗口。
    private let coveringWindow = CGRect(x: 424, y: 150, width: 110, height: 300)
    private let farWindow = CGRect(x: 800, y: 200, width: 400, height: 300)

    init() {
        icons = (0..<4).map { index in
            let x = 200 + CGFloat(index) * 120
            return DesktopIcon(
                id: IconID(rawValue: UInt64(index + 1)), kind: .file,
                imageRect: CGRect(x: x, y: 200, width: 64, height: 64),
                labelRect: CGRect(x: x - 10, y: 268, width: 84, height: 30)
            )
        }
        // 程序坞是自动隐藏的（量不到，鼠标推到屏幕底边才弹出来），而且设置里少数了 2 项：只靠公式的估算会偏出去一格。
        let dock = SimulatedDock(displayFrame: display, tileSize: 48, tileCount: 14, uncountedTiles: 2, isVisible: false)
        environment = SimulatedEnvironment(pointer: PointerSample(position: CGPoint(x: 700, y: 600)), dock: dock)
        sensor = InteractionSensor(environment: environment)
        desktop = FakeDesktop(icons: icons, now: 0)
        narrator = Narrator(origin: 0, icons: icons)
        facts = InteractionFacts(time: time)

        let covering = coveringWindow, far = farWindow
        environment.surfaceAt = { point in
            covering.contains(point) || far.contains(point) ? .otherWindow : .desktopIcons
        }
    }

    // MARK: 推进

    private func frame() {
        time = time.advanced(by: frameInterval)
        frames += 1
        let now = time.monotonic
        let previous = facts
        facts = sensor.update(time: time, icons: desktop.update(now: now))
        if facts.wantsIconRefresh { desktop.refreshNow() }
        for released in facts.releasedDrags where !previous.releasedDrags.contains(where: { $0.iconID == released.iconID }) {
            desktop.drop(
                released, onto: environment.surface(at: released.releasePoint),
                trashRect: environment.dock.trueTrashRect, now: now
            )
        }
        narrator.observe(facts, surface: sensor.lastSurface)

        let label = demandName(facts.demand, now: now)
        if label != demandLabel {
            narrator.note(facts, "  省电信号：\(label)")
            demandLabel = label
        }
    }

    private func wait(_ seconds: TimeInterval) {
        for _ in 0..<max(1, Int((seconds / frameInterval).rounded())) { frame() }
    }

    private func move(to target: CGPoint, in seconds: TimeInterval) {
        let start = environment.pointer.position
        let steps = max(1, Int((seconds / frameInterval).rounded()))
        for step in 1...steps {
            let fraction = CGFloat(step) / CGFloat(steps)
            environment.pointer.position = CGPoint(
                x: start.x + (target.x - start.x) * fraction, y: start.y + (target.y - start.y) * fraction
            )
            frame()
        }
    }

    private func press() {
        environment.pointer.buttons = [.left]
        environment.pointer.lastLeftDownAt = time.monotonic
        frame()
    }

    private func release() {
        environment.pointer.buttons = []
        environment.pointer.lastLeftUpAt = time.monotonic
        frame()
    }

    private func chapter(_ title: String) {
        say("")
        say("—— \(title) ——")
    }

    private func check(_ passed: Bool, _ what: String) {
        narrator.note(facts, "\(passed ? "✔" : "✘") \(what)")
        if !passed { failures += 1 }
    }

    private(set) var failures = 0

    // MARK: 剧本

    func run() -> Bool {
        say("假图标 4 个，64×64，图像矩形从左到右：" + icons.map { text($0.imageRect) }.joined(separator: " "))
        say("假窗口 2 个：\(text(coveringWindow)) 盖住了假图标 3；\(text(farWindow)) 在远处")
        frame()
        let truth = environment.dock.trueTrashRect
        if let trash = facts.trash {
            say("假程序坞藏着、且设置里少数了 2 项。废纸篓真正在 \(text(truth))；")
            say("只靠公式估在 \(text(trash.estimatedRect))，可信度 \(text(trash.confidence))，中心偏了 \(text(Double(abs(trash.estimatedRect.midX - truth.midX)), 0)) 点")
        }

        chapter("1 悬停")
        move(to: CGPoint(x: 232, y: 232), in: 0.4)
        wait(1.2)
        check(facts.hover?.iconID == icons[0].id && (facts.hover?.duration ?? 0) > 1.1,
              "悬停时长 \(text(facts.hover?.duration ?? 0)) 秒")

        chapter("2 单击、按住不动：都不算拖")
        press(); wait(0.08); release(); wait(0.3)
        press(); wait(0.8); release(); wait(0.3)
        check(narrator.outcomeCount == 0 && facts.drag == nil && facts.releasedDrags.isEmpty, "没有出现任何拖拽")

        chapter("3 图标被窗口挡住：不算悬停，也拖不起来")
        move(to: CGPoint(x: 472, y: 232), in: 0.3)
        wait(0.5)
        check(facts.hover == nil && !facts.isMouseOverDesktop, "鼠标在假图标 3 的位置上，但最上面是别的窗口：没有悬停")
        press()
        move(to: CGPoint(x: 472, y: 420), in: 0.3)
        check(facts.drag == nil, "按住移动了 188 点：没有开始拖")
        release()

        chapter("4 正常拖动：挪位置")
        move(to: CGPoint(x: 232, y: 232), in: 0.3)
        wait(0.2)
        press()
        move(to: CGPoint(x: 300, y: 500), in: 0.5)
        check(facts.drag?.currentImageRect.origin == CGPoint(x: 268, y: 468), "拖影上的图标图像在 \(text(facts.drag?.currentImageRect ?? .zero))（鼠标位置 − 抓取偏移）")
        release()
        wait(0.6)

        chapter("5 甩动，然后拖进废纸篓")
        move(to: CGPoint(x: 352, y: 232), in: 0.3)
        wait(0.2)
        press()
        move(to: CGPoint(x: 700, y: 500), in: 0.5)
        check((facts.drag?.shake ?? 1) < 0.05, "平稳拖动：甩动强度 \(text(facts.drag?.shake ?? -1))")
        for step in 1...90 {   // 来回猛甩 1.5 秒：每秒 4 个来回，幅度 120 点
            let t = Double(step) * frameInterval
            environment.pointer.position = CGPoint(x: 700 + 120 * sin(2 * .pi * 4 * t), y: 500)
            frame()
        }
        check((facts.drag?.shake ?? 0) > 0.8, "来回猛甩 1.5 秒：甩动强度 \(text(facts.drag?.shake ?? -1))")
        wait(0.4)
        move(to: truth.center, in: 0.9)
        check(facts.trash?.isOver == false, "松手点在真正的废纸篓上，但此刻的估算偏了：isOver = \(facts.trash?.isOver ?? false)")
        release()
        wait(0.6)
        check(facts.trash.map { $0.estimatedRect.contains(truth.center) && $0.confidence > 0.6 } ?? false,
              "自学习：估算挪到了松手点上，现在是 \(text(facts.trash?.estimatedRect ?? .zero))，可信度 \(text(facts.trash?.confidence ?? 0))")

        chapter("6 拖到一半取消（松在一个不接受它的窗口上，弹回原位）")
        move(to: CGPoint(x: 592, y: 232), in: 0.5)
        wait(0.2)
        press()
        move(to: CGPoint(x: 900, y: 300), in: 0.4)
        release()
        wait(0.6)
        check(narrator.outcomeCount == 2 && facts.releasedDrags.count == 1, "松手 0.6 秒了还没下结论：松在窗口上要多等一会儿，免得把访达慢半拍的搬动当成取消")
        wait(0.8)
        check(narrator.outcomeCount == 3, "约 1.1 秒后确认取消")

        chapter("7 快捷键删除（没有拖拽过程）")
        desktop.deleteByKeyboard(icons[2].id)
        narrator.note(facts, "假图标 3 被快捷键删掉了（图标桥下一次例行读取才会发现）")
        wait(1.3)

        chapter("8 再拖一个进废纸篓：这回估算是准的")
        move(to: CGPoint(x: 300, y: 500), in: 0.4)
        wait(0.2)
        press()
        move(to: truth.center, in: 0.9)
        check(facts.trash?.isOver == true, "到了废纸篓上方：isOver = \(facts.trash?.isOver ?? false)，距离 \(text(Double(facts.trash?.distance ?? -1), 0))")
        release()
        wait(0.6)

        chapter("9 鼠标不动：读得越来越少")
        move(to: CGPoint(x: 700, y: 600), in: 0.3)
        let before = frames
        wait(2)
        narrator.note(facts, "（剧本里每帧都喂了数据，一共 \(frames - before) 帧；应用里会按上面的省电信号少喂）")

        say("")
        let expected = narrator.outcomeCount == 4 && narrator.deletionCount == 3
        if !expected { failures += 1 }
        say("回放结束：\(frames) 帧，查了 \(sensor.surfaceSampleCount) 次\u{201C}鼠标处最上面是什么窗口\u{201D}；"
            + "结局 \(narrator.outcomeCount) 个（应为 4），删除事件 \(narrator.deletionCount) 个（应为 3），自学习 \(environment.lessonCount) 次；"
            + (failures == 0 ? "全部符合预期" : "\(failures) 处不符合预期"))
        return failures == 0
    }
}
