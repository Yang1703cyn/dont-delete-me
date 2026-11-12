// OverlayTests · 桌面看不看得见
//
// 窗口列表的假数据照着开发机上实测到的样子造（macOS 27）：
//   - 访达在每块屏上各有一个层级为"桌面图标层"的整屏窗口；
//   - 系统设置里关掉"在桌面上显示项目"时，系统在同一层级、访达窗口的前面放一块整屏的遮挡窗口；
//   - 某块屏停在全屏应用的空间时，那块屏上访达的图标窗口不在"在屏窗口"里；
//   - 比图标层高一级的地方，系统在每块屏顶部有一条不到百点高的窗口（菜单栏的衬底）。

import CoreGraphics
import DDMCore
import Foundation
import Testing
@testable import Overlay

private let iconLevel = -2_147_483_603
private let finder: Int32 = 200
private let system: Int32 = 300
private let ours: Int32 = 999

private func window(_ pid: Int32, layer: Int = iconLevel, alpha: Double = 1, _ bounds: CGRect) -> WindowEntry {
    WindowEntry(number: Int.random(in: 1...100_000), ownerPID: pid, layer: layer, alpha: alpha, bounds: bounds)
}

private func state(_ display: DisplayInfo, _ entries: [WindowEntry], finderPID: Int32? = finder) -> IconLayerState {
    IconLayerAnalysis.state(on: display, entries: entries, finderPID: finderPID, ownPID: ours, iconLevel: iconLevel)
}

@Suite("图标层在不在、有没有被遮住")
struct IconLayerAnalysisTests {
    private let builtIn = Fixture.builtIn
    private let external = Fixture.external

    @Test func 访达的图标窗口在屏上_前面没有遮挡_看得见() {
        let entries = [
            window(system, layer: 0, external.frame),                                   // 一个普通窗口
            window(system, layer: iconLevel + 1, CGRect(x: -1920, y: -58, width: 1920, height: 91)),   // 菜单栏衬底
            window(finder, external.frame),
            window(system, layer: iconLevel - 21, external.frame),                      // 墙纸一类
        ]
        #expect(state(external, entries) == .visible)
    }

    @Test func 开发机实测的样子_外接屏被遮挡_内屏停在全屏空间() {
        // 从前到后：外接屏顶部的衬底条、系统的遮挡窗口（图标层）、访达的图标窗口（外接屏）、内屏和外接屏的墙纸层。
        let entries = [
            window(system, layer: iconLevel + 1, CGRect(x: -1920, y: -58, width: 1920, height: 91)),
            window(system, external.frame),
            window(finder, external.frame),
            window(system, layer: iconLevel - 19, builtIn.frame),
            window(system, layer: iconLevel - 21, builtIn.frame),
            window(system, layer: iconLevel - 21, external.frame),
        ]
        #expect(state(external, entries) == .shielded)
        #expect(state(builtIn, entries) == .absent)
    }

    @Test func 遮挡窗口排在访达窗口后面_不算遮挡() {
        let entries = [window(finder, external.frame), window(system, external.frame)]
        #expect(state(external, entries) == .visible)
    }

    @Test func 只盖住一小条的窗口_不算遮挡() {
        let strip = CGRect(x: -1920, y: -58, width: 1920, height: 91)
        #expect(state(external, [window(system, strip), window(finder, external.frame)]) == .visible)
    }

    @Test func 别的层级的整屏窗口_不算遮挡() {
        // 例如另一个程序放在"图标层 +1"的透明叠加窗口（包括本项目的另一个实例）。
        let entries = [window(system, layer: iconLevel + 1, external.frame), window(finder, external.frame)]
        #expect(state(external, entries) == .visible)
    }

    @Test func 自己的窗口_不算遮挡() {
        #expect(state(external, [window(ours, external.frame), window(finder, external.frame)]) == .visible)
    }

    @Test func 淡出到底的遮挡窗口_不算遮挡() {
        #expect(state(external, [window(system, alpha: 0, external.frame), window(finder, external.frame)]) == .visible)
        #expect(state(external, [window(system, alpha: 0.5, external.frame), window(finder, external.frame)]) == .shielded)
    }

    @Test func 访达的图标窗口全透明_或访达没在运行_算不在() {
        #expect(state(external, [window(finder, alpha: 0, external.frame)]) == .absent)
        #expect(state(external, [window(finder, external.frame)], finderPID: nil) == .absent)
        #expect(state(external, []) == .absent)
    }

    @Test func 另一块屏上的图标窗口不算这块屏的() {
        #expect(state(builtIn, [window(finder, external.frame)]) == .absent)
        #expect(state(external, [window(finder, builtIn.frame), window(finder, external.frame)]) == .visible)
    }

    @Test func 访达的普通窗口不是图标层() {
        #expect(state(external, [window(finder, layer: 0, external.frame)]) == .absent)
    }

    @Test func 覆盖比例() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(IconLayerAnalysis.coverage(of: rect, by: rect) == 1)
        #expect(IconLayerAnalysis.coverage(of: rect, by: CGRect(x: 50, y: 0, width: 100, height: 100)) == 0.5)
        #expect(IconLayerAnalysis.coverage(of: rect, by: CGRect(x: 200, y: 0, width: 100, height: 100)) == 0)
        #expect(IconLayerAnalysis.coverage(of: .zero, by: rect) == 0)
    }
}

@Suite("看得见要等一等才作数，看不见立刻生效")
struct IconLayerTrackerTests {
    private let id = Fixture.external.id

    @Test func 第一次观察到看得见_先不算_过了确认时间才算() {
        var tracker = IconLayerTracker()
        let recheck = tracker.ingest([id: .visible], at: 10)
        #expect(tracker.state(for: id) == .absent)
        #expect(recheck == 10 + IconLayerTracker.confirmDelay)

        #expect(tracker.ingest([id: .visible], at: 10.2) == 10 + IconLayerTracker.confirmDelay)
        #expect(tracker.state(for: id) == .absent)

        #expect(tracker.ingest([id: .visible], at: 10.36) == nil)
        #expect(tracker.state(for: id) == .visible)
    }

    @Test func 看不见立刻生效() {
        var tracker = IconLayerTracker()
        _ = tracker.ingest([id: .visible], at: 10)
        _ = tracker.ingest([id: .visible], at: 11)
        #expect(tracker.state(for: id) == .visible)

        #expect(tracker.ingest([id: .shielded], at: 11.1) == nil)
        #expect(tracker.state(for: id) == .shielded)
        _ = tracker.ingest([id: .absent], at: 11.2)
        #expect(tracker.state(for: id) == .absent)
    }

    @Test func 中途闪了一下看不见_重新计时() {
        var tracker = IconLayerTracker()
        _ = tracker.ingest([id: .visible], at: 10)
        _ = tracker.ingest([id: .shielded], at: 10.2)          // 过渡动画里遮挡窗口又回来了
        let recheck = tracker.ingest([id: .visible], at: 10.3)
        #expect(recheck == 10.3 + IconLayerTracker.confirmDelay)
        _ = tracker.ingest([id: .visible], at: 10.4)
        #expect(tracker.state(for: id) == .shielded)           // 还在等：沿用上一个确定的状态
        _ = tracker.ingest([id: .visible], at: 10.66)
        #expect(tracker.state(for: id) == .visible)
    }

    @Test func 已经看得见的_继续看得见不用再等() {
        var tracker = IconLayerTracker()
        _ = tracker.ingest([id: .visible], at: 10)
        _ = tracker.ingest([id: .visible], at: 10.5)
        #expect(tracker.ingest([id: .visible], at: 10.6) == nil)
        #expect(tracker.state(for: id) == .visible)
    }

    @Test func 每块屏各算各的_没观察过的屏算不在() {
        var tracker = IconLayerTracker()
        let other = Fixture.builtIn.id
        _ = tracker.ingest([id: .visible, other: .absent], at: 10)
        _ = tracker.ingest([id: .visible, other: .visible], at: 10.4)
        #expect(tracker.state(for: id) == .visible)
        #expect(tracker.state(for: other) == .absent)          // 内屏刚开始计时
        #expect(tracker.state(for: DisplayID(rawValue: 77)) == .absent)

        tracker.reset()
        #expect(tracker.state(for: id) == .absent)
    }
}

@Suite("桌面是否可见")
struct VisibilityModelTests {
    private let seen = StageSignals(iconLayer: .visible, hasWindowOnActiveSpace: true, isOccluded: false)

    @Test func 会话在线_图标看得见_当前空间有窗口_没被挡住_才算看得见() {
        #expect(VisibilityModel.isStageVisible(seen, session: .live))

        var signals = seen
        signals.iconLayer = .shielded
        #expect(!VisibilityModel.isStageVisible(signals, session: .live))       // 访达隐藏了桌面图标
        signals.iconLayer = .absent
        #expect(!VisibilityModel.isStageVisible(signals, session: .live))       // 全屏应用的空间

        signals = seen
        signals.hasWindowOnActiveSpace = false
        #expect(!VisibilityModel.isStageVisible(signals, session: .live))

        signals = seen
        signals.isOccluded = true
        #expect(!VisibilityModel.isStageVisible(signals, session: .live))       // 被别的窗口完全挡住
    }

    @Test func 锁屏_屏幕睡眠_电脑睡眠_切到别的用户_都看不见() {
        var session = SessionState.live
        #expect(session.isLive)

        session.isScreenLocked = true
        #expect(!session.isLive && !VisibilityModel.isStageVisible(seen, session: session))

        session = .live
        session.areDisplaysAsleep = true
        #expect(!session.isLive && !VisibilityModel.isStageVisible(seen, session: session))

        session = .live
        session.isSystemAsleep = true
        #expect(!session.isLive)

        session = .live
        session.isOnConsole = false
        #expect(!session.isLive)
    }

    @Test func 至少一块屏看得见_桌面层就算可见() {
        let hidden = StageSignals(iconLayer: .absent, hasWindowOnActiveSpace: false, isOccluded: false)
        #expect(VisibilityModel.isDesktopVisible(session: .live, stages: [hidden, seen]))
        #expect(!VisibilityModel.isDesktopVisible(session: .live, stages: [hidden, hidden]))
        #expect(!VisibilityModel.isDesktopVisible(session: .live, stages: []))

        var locked = SessionState.live
        locked.isScreenLocked = true
        #expect(!VisibilityModel.isDesktopVisible(session: locked, stages: [seen, seen]))
    }
}
