// InputSense · 读系统：程序坞的设置、所在显示器、那一条的实际范围
//
// 只读、不需要任何授权，也不改程序坞的任何设置。用到的系统信息：
//   - 程序坞自己的偏好设置（靠哪边、图标大小、放大、自动隐藏、常驻项目的个数）；
//   - 正在运行的普通应用里有几个不在常驻项目中（它们也各占一格）——只数个数；
//   - 程序坞窗口的边界（它是整屏大小的，由此知道程序坞在哪块屏）；
//   - "鼠标点在这个点上会不会落到程序坞的窗口"（由此量出那一条的范围）。
// 应用的名字、标识只在这个文件里比较，不保存、不输出。
//
// 前三样读起来慢（数一遍正在运行的应用约 10 毫秒），所以放在后台线程读，主线程只取读好的结果；
// 最后一样必须在主线程问，但很快（见 `DockBarScan`）。

import AppKit
import CoreGraphics
import DDMCore
import Foundation

@MainActor
final class SystemDockReader: DockReading {
    private nonisolated static let dockBundleID = "com.apple.dock"
    private nonisolated static let finderBundleID = "com.apple.finder"

    /// 后台读一遍得到的全部内容。
    private struct Report: Sendable {
        var settings: DockSettings
        var dockWindow: WindowProbe.WindowInfo?
        var dockDisplayFrame: CGRect?
        var primaryDisplayFrame: CGRect?
    }

    private let probe: WindowProbe
    private var dockWindowNumber: Int?
    private var isLoading = false
    /// 上一次量到的那一条，以及是在什么前提下量的。
    private var lastBar: (bar: CGRect, edge: DockEdge, displayFrame: CGRect)?

    private(set) var settings: DockSettings?
    private(set) var dockDisplayFrame: CGRect?
    private(set) var primaryDisplayFrame: CGRect?

    init(probe: WindowProbe) {
        self.probe = probe
    }

    // MARK: 后台读取

    func requestRefresh() {
        guard !isLoading else { return }
        isLoading = true
        let known = dockWindowNumber
        Task.detached(priority: .utility) { [weak self] in
            let report = SystemDockReader.load(knownDockWindow: known)
            await self?.adopt(report)
        }
    }

    private func adopt(_ report: Report) {
        isLoading = false
        settings = report.settings
        dockWindowNumber = report.dockWindow?.number
        dockDisplayFrame = report.dockDisplayFrame
        primaryDisplayFrame = report.primaryDisplayFrame
    }

    /// 在后台线程上把程序坞的情况读一遍。用到的接口都可以在后台线程调用。
    private nonisolated static func load(knownDockWindow: Int?) -> Report {
        let layout = DisplayLayout.current()
        let window = findDockWindow(known: knownDockWindow)
        return Report(
            settings: readSettings(),
            dockWindow: window,
            // 程序坞的窗口和它所在的显示器一样大。
            dockDisplayFrame: window.flatMap { layout.display(bestFor: $0.bounds)?.frame },
            primaryDisplayFrame: layout.primary?.frame
        )
    }

    private nonisolated static func findDockWindow(known: Int?) -> WindowProbe.WindowInfo? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: dockBundleID).first?.processIdentifier else {
            return nil
        }
        func isDock(_ window: WindowProbe.WindowInfo) -> Bool {
            window.ownerPID == pid && window.layer == WindowProbe.dockLevel
        }
        // 上次找到的窗口还在：直接问它（快）。程序坞重启过的话它就不在了。
        if let known, let window = WindowProbe.currentInfo(for: known), isDock(window) {
            return window
        }
        // 程序坞露在屏上时，在屏窗口里就有；藏着（全屏空间、自动隐藏）时要到全部窗口里找（慢，所以只在后台做）。
        return WindowProbe.onScreenWindows().first(where: isDock) ?? WindowProbe.allWindows().first(where: isDock)
    }

    private nonisolated static func readSettings() -> DockSettings {
        let domain = dockBundleID as CFString
        // 程序坞是另一个进程：先同步，才看得到它刚改的设置。
        CFPreferencesAppSynchronize(domain)
        func value(_ key: String) -> Any? { CFPreferencesCopyAppValue(key as CFString, domain) }
        func number(_ key: String) -> Double? { (value(key) as? NSNumber)?.doubleValue }
        func flag(_ key: String, default fallback: Bool) -> Bool { (value(key) as? NSNumber)?.boolValue ?? fallback }

        var settings = DockSettings()
        settings.edge = (value("orientation") as? String).flatMap(DockEdge.init(rawValue:)) ?? .bottom
        settings.tileSize = CGFloat(number("tilesize") ?? 48)
        settings.magnification = flag("magnification", default: false)
        settings.largeSize = CGFloat(number("largesize") ?? max(Double(settings.tileSize) * 1.5, 64))
        settings.autohide = flag("autohide", default: false)

        // —— 数一数程序坞里有几项 ——
        let persistentApps = tiles(value("persistent-apps"))
        let persistentOthers = tiles(value("persistent-others"))
        let recentApps = tiles(value("recent-apps"))
        // "只显示打开的应用"：常驻的应用一个都不显示。
        let onlyRunning = flag("static-only", default: false)
        let showsRecents = flag("show-recents", default: true) && !onlyRunning

        let pinned = onlyRunning ? Set<String>() : persistentApps.bundleIDs
        let running = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier))
            .subtracting([finderBundleID])
        // 正在运行、但不在常驻项目里的应用：排在常驻应用后面，各占一格。
        let runningUnpinned = running.subtracting(pinned).count
        // "最近使用的应用"：和上面那些合起来凑够最多三个。
        let recentIdle = recentApps.bundleIDs.subtracting(running).subtracting(pinned).count
        let transient = showsRecents ? max(runningUnpinned, min(3, runningUnpinned + recentIdle)) : runningUnpinned

        // 访达 + 常驻应用 + 运行中/最近的应用 + 文件夹和文稿 + 废纸篓。
        settings.tileCount = 1 + (onlyRunning ? 0 : persistentApps.units) + Double(transient) + persistentOthers.units + 1
        // 应用和右边那一段之间总有一条分隔线；有"运行中/最近的应用"这一段时再多一条。
        settings.separatorCount = 1 + (transient > 0 ? 1 : 0)
        return settings
    }

    /// 偏好设置里的一组程序坞项目：占几格、各是什么应用。
    private nonisolated static func tiles(_ value: Any?) -> (units: Double, bundleIDs: Set<String>) {
        guard let entries = value as? [[String: Any]] else { return (0, []) }
        var units = 0.0
        var bundleIDs: Set<String> = []
        for entry in entries {
            // 占位空格有大小两种：小的只占半格。
            units += (entry["tile-type"] as? String) == "small-spacer-tile" ? 0.5 : 1
            if let data = entry["tile-data"] as? [String: Any], let id = data["bundle-identifier"] as? String {
                bundleIDs.insert(id)
            }
        }
        return (units, bundleIDs)
    }

    // MARK: 那一条的实际范围

    func measureBar(edge: DockEdge, displayFrame: CGRect) -> CGRect? {
        guard let number = dockWindowNumber else { return nil }
        let isDockAt: (CGPoint) -> Bool = { [probe] point in probe.topWindow(at: point)?.number == number }
        // 多数时候程序坞没变：先花 4 次查询核对上一次的结果，对不上才重新量一遍（三十来次查询）。
        if let last = lastBar, last.edge == edge, last.displayFrame == displayFrame,
           DockBarScan.stillHolds(last.bar, edge: edge, displayFrame: displayFrame, isDockAt: isDockAt) {
            return last.bar
        }
        let bar = DockBarScan.measure(edge: edge, displayFrame: displayFrame, isDockAt: isDockAt)
        lastBar = bar.map { ($0, edge, displayFrame) }
        return bar
    }
}
