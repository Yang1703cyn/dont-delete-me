// IconBridgeDemo · 一次演示会话：建一个图标提供者，把它上报的东西记下来、打印出来

import DDMCore
import Foundation
import IconBridge

@MainActor
final class DemoSession {
    let provider: DesktopIconProvider
    /// 会话开始的时刻（单调时钟）。
    let startedAt = now()

    /// 收到的每一次上报及收到的时刻。
    private(set) var updates: [(time: TimeInterval, update: IconUpdate)] = []
    /// 收到的每一个变化事件及收到的时刻。
    private(set) var changes: [(time: TimeInterval, change: IconChange)] = []
    /// 每个读取周期的概况。
    private(set) var cycles: [IconBridgeCycleReport] = []

    /// 上报时是否打印。
    var printsUpdates: Bool
    /// 整体重载时是否逐个打印图标。
    var printsIcons: Bool

    init(printsUpdates: Bool = true, printsIcons: Bool = true) {
        self.printsUpdates = printsUpdates
        self.printsIcons = printsIcons
        // 演示程序用自己的暂停开关（不动应用的全局开关），编号用的盐不落盘。
        provider = DesktopIconProvider(
            pause: PauseSwitch(),
            identityStorage: .ephemeral,
            displayLayout: { DemoDisplays.layout() }
        )
        provider.onUpdate = { [weak self] update in
            self?.received(update)
        }
        provider.onCycle = { [weak self] report in
            self?.cycles.append(report)
        }
    }

    func start() {
        provider.start()
    }

    func stop() {
        provider.stop()
    }

    private func received(_ update: IconUpdate) {
        let time = now()
        updates.append((time, update))
        for change in update.changes {
            changes.append((time, change))
        }
        guard printsUpdates else { return }

        let snapshot = update.snapshot
        let stamp = String(format: "%6.2fs", time - startedAt)
        var line = "\(stamp) 上报 #\(updates.count)"
        if update.isReset { line += "【整体重载】" }
        line += " 状态：\(statusName(snapshot.status))；图标 \(snapshot.icons.count) 个（\(kindSummary(snapshot.icons))）"
        line += "；\(describe(snapshot.appearance))；版本 \(snapshot.revision)"
        line += String(format: "；读取开始于 %.2fs", snapshot.capturedAt - startedAt)
        say(line)
        if update.isReset, printsIcons {
            let layout = DemoDisplays.layout()
            for icon in snapshot.icons {
                say("         \(describe(icon, layout: layout))")
            }
        }
        for change in update.changes {
            say("         变化：\(describe(change))")
        }
        if !update.isReset, update.changes.isEmpty {
            say("         （没有变化事件：由 refreshNow() 引发的回调，或只是种类 / 修改时间 / 标签有变）")
        }
    }

    // MARK: 等待

    /// 等到第一次上报。
    func waitForFirstUpdate(timeout: TimeInterval) -> Bool {
        pump(timeout: timeout) { !self.updates.isEmpty }
    }

    /// 等一个满足条件的变化事件（只看下标 `index` 及之后的）。返回事件和它到达的时刻。
    func waitForChange(from index: Int, timeout: TimeInterval, where matches: (IconChange) -> Bool) -> (change: IconChange, time: TimeInterval)? {
        var found: (IconChange, TimeInterval)?
        pump(timeout: timeout) {
            if let hit = self.changes.dropFirst(index).first(where: { matches($0.change) }) {
                found = (hit.change, hit.time)
                return true
            }
            return false
        }
        return found
    }

    /// 读取周期的统计：完整读取与快速检查各多少次、平均耗时、平均请求数。
    func cycleSummary(since index: Int = 0) -> String {
        let recent = Array(cycles.dropFirst(index))
        func summarize(_ reports: [IconBridgeCycleReport]) -> String {
            guard !reports.isEmpty else { return "0 次" }
            let milliseconds = reports.map { $0.duration * 1000 }
            let average = milliseconds.reduce(0, +) / Double(reports.count)
            let requests = Double(reports.map(\.requestCount).reduce(0, +)) / Double(reports.count)
            return String(format: "%d 次（平均 %.1f 毫秒，最长 %.1f 毫秒，每次 %.1f 个请求）", reports.count, average, milliseconds.max() ?? 0, requests)
        }
        return "完整读取 \(summarize(recent.filter(\.wasFullRead)))；快速检查 \(summarize(recent.filter { !$0.wasFullRead }))"
    }
}

// MARK: - 桌面空白处

@MainActor
enum FreeSpot {
    /// 在某块显示器上找几个空位（返回图标的 desktop position）：周围没有别的图标，也避开菜单栏和屏幕边缘。
    static func find(count: Int, on display: DisplayInfo, avoiding icons: [DesktopIcon]) -> [CGPoint] {
        let occupied = icons.map { $0.hitBounds.insetBy(dx: -30, dy: -30) }
        var spots: [CGPoint] = []
        let area = display.frame.insetBy(dx: 160, dy: 0)
        var y = display.frame.minY + 220
        while y < display.frame.maxY - 260, spots.count < count {
            var x = area.minX
            while x < area.maxX, spots.count < count {
                // 预留的范围：图标本身加上一个比较长的标签。
                let footprint = CGRect(x: x - 110, y: y - 50, width: 220, height: 130)
                let free = !occupied.contains { $0.intersects(footprint) }
                    && !spots.contains { CGRect(x: $0.x - 110, y: $0.y - 50, width: 220, height: 130).intersects(footprint) }
                if free {
                    spots.append(CGPoint(x: x.rounded(), y: y.rounded()))
                }
                x += 240
            }
            y += 150
        }
        return spots
    }
}
