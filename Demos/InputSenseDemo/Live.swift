// InputSenseDemo · 实时读数
//
// 读真实的鼠标、真实的窗口遮挡、真实的程序坞设置（全部只读，不需要授权），图标是假的。
// 每当判断有变化就打印一行；另外每秒打印一行全貌。按交互感知给出的省电信号来决定多久读一次。

import AppKit
import CoreGraphics
import DDMCore
import Foundation
import InputSense

struct LiveOptions {
    var seconds: Double = 20
    /// 把"图标被系统遮住的桌面"也当作桌面（开发机的桌面项目是隐藏的，不开这个没法试悬停和拖拽）。
    var ignoreShield = false
    /// 在屏幕上把假图标和废纸篓的估算区域画出来（一个点击穿透、不抢焦点的透明窗口）。
    var show = false
    /// 每秒一行的全貌要不要打印。
    var statusLines = true
}

@MainActor
func runLive(_ options: LiveOptions) {
    var environmentOptions = LiveEnvironment.Options()
    environmentOptions.remembersTrashLocation = false          // 演示不往偏好设置里写东西
    environmentOptions.countsShieldedDesktopAsDesktop = options.ignoreShield
    let environment = LiveEnvironment(options: environmentOptions)
    let sensor = InteractionSensor(environment: environment)

    // 假图标：第一个就放在鼠标此刻所在的位置，其余的往旁边排开。
    let start = environment.readPointer().position
    let layout = DisplayLayout.current()
    let display = (layout.display(containing: start) ?? layout.primary)?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    let direction: CGFloat = start.x + 3 * 110 + 60 < display.maxX ? 1 : -1
    let icons: [DesktopIcon] = (0..<4).map { index in
        let center = CGPoint(x: start.x + direction * CGFloat(index) * 110, y: min(max(start.y, display.minY + 80), display.maxY - 160))
        return DesktopIcon(
            id: IconID(rawValue: UInt64(index + 1)), kind: .file,
            imageRect: CGRect(x: center.x - 32, y: center.y - 32, width: 64, height: 64),
            labelRect: CGRect(x: center.x - 42, y: center.y + 36, width: 84, height: 30)
        )
    }

    let began = FrameTime.now().monotonic
    let desktop = FakeDesktop(icons: icons, now: began)
    desktop.respawnDelay = 3
    let narrator = Narrator(origin: began, icons: icons)
    let marker = options.show ? MarkerWindows() : nil

    say("实时读数 \(text(options.seconds, 0)) 秒（只读：不产生任何鼠标键盘事件，不需要授权）。")
    say("假图标 4 个（\(options.show ? "屏幕上的蓝框" : "看不见，只是 4 块 64×64 的区域；加 --show 可以画出来")）："
        + "第 1 个就在鼠标现在的位置 \(text(start))，其余每隔 110 点向\(direction > 0 ? "右" : "左")排开。")
    say("可以试：鼠标停在原地（悬停）；移到窗口上再移回桌面；在假图标上按住拖动、来回甩、拖到程序坞的废纸篓上松手。")
    if options.show {
        say("已加 --show：蓝框是假图标，紫框是被拖着的那个的拖影，红框是废纸篓的估算区域，黄框是量到的程序坞。")
    }
    if options.ignoreShield {
        say("已加 --ignore-shield：桌面图标被系统遮住时也当作桌面。")
    }

    var updateCosts: [Double] = []
    var framesByDemand: [String: Int] = [:]
    var lastStatusAt = began - 1
    var facts = InteractionFacts(time: FrameTime.now())
    let deadline = began + options.seconds

    while ProcessInfo.processInfo.systemUptime < deadline {
        let time = FrameTime.now()
        let now = time.monotonic
        let iconUpdate = desktop.update(now: now)
        let previous = facts

        let startedAt = ProcessInfo.processInfo.systemUptime
        facts = sensor.update(time: time, icons: iconUpdate)
        updateCosts.append(ProcessInfo.processInfo.systemUptime - startedAt)

        if facts.wantsIconRefresh { desktop.refreshNow() }
        for released in facts.releasedDrags where !previous.releasedDrags.contains(where: { $0.iconID == released.iconID }) {
            desktop.drop(released, onto: environment.surface(at: released.releasePoint), trashRect: facts.trash?.estimatedRect, now: now)
        }
        narrator.observe(facts, surface: sensor.lastSurface)
        if options.statusLines, now - lastStatusAt >= 1 {
            lastStatusAt = now
            say(narrator.status(facts, surface: sensor.lastSurface) + " | " + demandName(facts.demand, now: now))
        }
        marker?.show(icons: desktop.truth.map(\.imageRect), dragged: facts.drag?.currentImageRect, trash: facts.trash?.estimatedRect, dockBar: environment.diagnostics.measuredDockBar)

        // 按省电信号决定下一次什么时候读。
        let wake: TimeInterval
        switch facts.demand {
        case .continuous:
            wake = now + 1.0 / 60
            framesByDemand["连续", default: 0] += 1
        case let .by(time):
            wake = max(time, now + 1.0 / 120)
            framesByDemand["定时", default: 0] += 1
        case .idle:
            wake = now + 1
            framesByDemand["休息", default: 0] += 1
        }
        spin(until: min(wake, deadline))
    }
    marker?.close()

    let sorted = updateCosts.sorted()
    let mean = updateCosts.reduce(0, +) / Double(max(updateCosts.count, 1))
    say("")
    say("实时读数结束：共读了 \(updateCosts.count) 次（连续出帧时 \(framesByDemand["连续", default: 0]) 次，定时醒来 \(framesByDemand["定时", default: 0]) 次），"
        + "平均每秒 \(text(Double(updateCosts.count) / options.seconds, 1)) 次；查了 \(sensor.surfaceSampleCount) 次\u{201C}鼠标处最上面是什么窗口\u{201D}。")
    if !sorted.isEmpty {
        say("每次 update 耗时：平均 \(text(mean * 1000, 3)) 毫秒，中位 \(text(sorted[sorted.count / 2] * 1000, 3))，95% \(text(sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] * 1000, 3))，最大 \(text(sorted[sorted.count - 1] * 1000, 3))（目标 0.5 以内）。")
    }
    say("结局 \(narrator.outcomeCount) 个，删除事件 \(narrator.deletionCount) 个。")
    describeDock(environment.diagnostics, estimate: facts.trash)
}

@MainActor
func describeDock(_ diagnostics: LiveEnvironment.Diagnostics, estimate: TrashInfo?) {
    guard let edge = diagnostics.dockEdge, let frame = diagnostics.dockDisplayFrame else {
        say("程序坞：还没读到。")
        return
    }
    let edgeName = ["bottom": "底部", "left": "左侧", "right": "右侧"][edge] ?? edge
    say("程序坞：在\(edgeName)，所在显示器 \(text(frame))\(diagnostics.isDockDisplayKnown ? "" : "（没查到，假定主屏）")；"
        + "设置里图标大小 \(text(Double(diagnostics.dockTileSize ?? 0), 0))，估计 \(text(diagnostics.dockTileCount ?? 0, 1)) 项；"
        + "自动隐藏 \(diagnostics.dockAutohide == true ? "开" : "关")，放大 \(diagnostics.dockMagnification == true ? "开" : "关")。")
    if let predicted = diagnostics.predictedDockBar {
        if let measured = diagnostics.measuredDockBar {
            say("那一条的范围：量到 \(text(measured))；按公式推算 \(text(predicted))；"
                + "两端相差 \(text(Double(measured.minX - predicted.minX), 1)) / \(text(Double(measured.maxX - predicted.maxX), 1)) 点，厚度相差 \(text(Double(measured.height - predicted.height), 1)) 点。")
        } else {
            say("那一条的范围：此刻量不到（程序坞没露在屏上）；按公式推算 \(text(predicted))。")
        }
    }
    if let estimate {
        say("废纸篓估算：\(text(estimate.estimatedRect))，可信度 \(text(estimate.confidence))。")
    }
}
