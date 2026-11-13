// InputSense · 读系统：某个点上最上面是什么窗口
//
// 只读、不需要任何授权。用到的系统信息：
//   - "鼠标点在这个点上会落到哪个窗口"（窗口服务器自己的命中规则：透明的地方、不接收点击的窗口都会被跳过）；
//   - 窗口的所属进程、层级、边界、透明度。
// 不读窗口标题，不读程序名，不截屏。

import AppKit
import CoreGraphics
import DDMCore
import Foundation

@MainActor
final class WindowProbe {
    /// 访达桌面图标窗口所在的层级。
    nonisolated static let desktopIconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
    /// 系统拖放时拖影所在的层级。
    nonisolated static let draggingLevel = Int(CGWindowLevelForKey(.draggingWindow))
    /// 程序坞窗口所在的层级。
    nonisolated static let dockLevel = Int(CGWindowLevelForKey(.dockWindow))

    struct WindowInfo: Sendable, Equatable {
        var number: Int
        var ownerPID: pid_t
        var layer: Int
        var alpha: Double
        var bounds: CGRect
    }

    /// 一个窗口是哪一类。
    enum Kind: Sendable {
        /// 访达的桌面图标窗口。
        case finderDesktop
        /// 程序坞的窗口。
        case dock
        case other
    }

    /// 一个窗口"是什么"查过之后记这么久（秒）。窗口的所属进程和层级不会变、窗口编号也不会马上被别的窗口重用，
    /// 记着是为了不每次都去查（查一次也是一趟往返）。
    private let classificationLifetime: TimeInterval = 60
    /// 桌面图标层上"不是访达"的结论只记这么久（秒）：访达刚重启时可能一时查不到它的进程信息，
    /// 不能因此把桌面当成"被遮住"一分钟。
    private let doubtfulClassificationLifetime: TimeInterval = 3
    /// "图标是否被系统遮住"每隔这么久在后台复查一次（秒）；只在鼠标正处在访达的桌面图标层上时才查。
    private let shieldLifetime: TimeInterval = 0.5
    /// 显示器布局、遮挡状态记着用、过期了在后台重读；但旧到超过这么久（秒）——例如应用暂停了一阵——就当场重读，不用太旧的。
    private let staleLimit: TimeInterval = 5

    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private var classified: [Int: (info: WindowInfo, kind: Kind, expiresAt: TimeInterval)] = [:]
    /// 每块显示器上，访达的图标是不是被系统的遮挡窗口盖住了。还没查过为 nil。
    private var shieldStates: [DisplayID: Bool]?
    private var shieldsScannedAt: TimeInterval = 0
    private var isScanningShields = false
    private var cachedLayout: (value: DisplayLayout, readAt: TimeInterval)?
    private var isReadingLayout = false

    init() {
        // "鼠标点在这里会落到哪个窗口"要先和窗口服务器建立连接；应用里早就有了，命令行程序里靠这一句。
        // 只是取得应用对象，不激活、不出现在程序坞、不建窗口。
        _ = NSApplication.shared
        // 第一次问窗口服务器要一两毫秒（建立连接），放在这里做掉，别算在某一帧头上。
        _ = NSWindow.windowNumber(at: .zero, belowWindowWithWindowNumber: 0)
        rescanShieldsInBackground()
    }

    // MARK: 命中

    /// 鼠标点在这个点（全局坐标）上会落到的窗口。本进程自己的窗口和系统的拖影不算，看它们下面的那个。
    func topWindow(at point: CGPoint) -> WindowInfo? {
        classifiedTopWindow(at: point)?.info
    }

    private func classifiedTopWindow(at point: CGPoint) -> (info: WindowInfo, kind: Kind)? {
        let appKitPoint = layout().appKitPoint(fromGlobal: point)
        var below = 0
        // 最多往下看几层：自家的叠加窗口本来就不接收点击，正常一次就够。
        for _ in 0..<6 {
            let number = NSWindow.windowNumber(at: appKitPoint, belowWindowWithWindowNumber: below)
            guard number > 0, let found = classify(number) else { return nil }
            if found.info.ownerPID == ownPID || found.info.layer == Self.draggingLevel {
                below = number
                continue
            }
            return found
        }
        return nil
    }

    /// 这个点上最上面的窗口是什么。
    func surface(at point: CGPoint) -> PointerSurface {
        guard let window = classifiedTopWindow(at: point) else { return .unknown }
        switch window.kind {
        case .dock:
            return .dock
        case .finderDesktop:
            // 遮挡窗口也可能不接收点击、被命中规则跳过了，所以再按窗口次序核对一遍。
            return isDesktopShielded(near: point) ? .shieldedDesktop : .desktopIcons
        case .other:
            // 桌面图标这一层上不是访达的窗口：就是系统用来遮住图标的那块窗口。
            return window.info.layer == Self.desktopIconLevel ? .shieldedDesktop : .otherWindow
        }
    }

    // MARK: 窗口信息

    /// 某个窗口此刻的信息（不走缓存）；窗口不存在为 nil。任何线程可调。
    nonisolated static func currentInfo(for number: Int) -> WindowInfo? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[CFString: Any]] else {
            return nil
        }
        return list.lazy.compactMap(parse).first { $0.number == number }
    }

    /// 当前在屏的窗口，从前到后。任何线程可调；一次约 0.6 毫秒，所以主线程上只在万不得已时用。
    nonisolated static func onScreenWindows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[CFString: Any]] else {
            return []
        }
        return list.compactMap(parse)
    }

    /// 所有窗口（含不在屏上的）。窗口多时要好几毫秒，**只能在后台线程调用**。
    nonisolated static func allWindows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[CFString: Any]] else {
            return []
        }
        return list.compactMap(parse)
    }

    private nonisolated static func parse(_ entry: [CFString: Any]) -> WindowInfo? {
        guard let number = entry[kCGWindowNumber] as? Int,
              let pid = entry[kCGWindowOwnerPID] as? Int32,
              let layer = entry[kCGWindowLayer] as? Int,
              let boundsInfo = entry[kCGWindowBounds] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary)
        else { return nil }
        return WindowInfo(number: number, ownerPID: pid, layer: layer, alpha: entry[kCGWindowAlpha] as? Double ?? 1, bounds: bounds)
    }

    private func classify(_ number: Int) -> (info: WindowInfo, kind: Kind)? {
        let now = ProcessInfo.processInfo.systemUptime
        if let known = classified[number], known.expiresAt > now {
            return (known.info, known.kind)
        }
        guard let info = Self.currentInfo(for: number) else {
            classified[number] = nil
            return nil
        }
        // 只有这两个层级上的窗口才需要知道是谁的。
        var kind = Kind.other
        if info.layer == Self.desktopIconLevel || info.layer == Self.dockLevel {
            let owner = NSRunningApplication(processIdentifier: info.ownerPID)?.bundleIdentifier
            if info.layer == Self.desktopIconLevel, owner == "com.apple.finder" { kind = .finderDesktop }
            if info.layer == Self.dockLevel, owner == "com.apple.dock" { kind = .dock }
        }
        if classified.count > 64 {
            classified = classified.filter { $0.value.expiresAt > now }
        }
        let isDoubtful = info.layer == Self.desktopIconLevel && kind == .other
        classified[number] = (info, kind, now + (isDoubtful ? doubtfulClassificationLifetime : classificationLifetime))
        return (info, kind)
    }

    // MARK: 图标是否被系统遮住

    /// 这个点所在的显示器上，访达的图标是不是被系统的遮挡窗口盖住了。
    ///
    /// 系统设置里关掉"在桌面上显示项目"之后，访达的图标窗口照常在屏，但系统会在**同一层级、它的前面**
    /// 放一块整屏的窗口把图标遮住（见 docs/模块说明/overlay.md §6.3）。判断方法与叠加层一致。
    ///
    /// 这要看整份在屏窗口列表（约 0.6 毫秒），所以结果记着用，过期了在后台线程重查；
    /// 只有一次都没查过时才当场查。
    private func isDesktopShielded(near point: CGPoint) -> Bool {
        let layout = layout()
        guard let display = layout.display(containing: point) ?? layout.display(nearestTo: point) else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        if let states = shieldStates, now - shieldsScannedAt < staleLimit {
            if now - shieldsScannedAt >= shieldLifetime { rescanShieldsInBackground() }
            return states[display.id] ?? false
        }
        // 一次都没查过，或者上次查的已经太旧：当场查。
        let states = Self.scanShields(ownPID: ownPID)
        shieldStates = states
        shieldsScannedAt = now
        return states[display.id] ?? false
    }

    private func rescanShieldsInBackground() {
        guard !isScanningShields else { return }
        isScanningShields = true
        let ownPID = self.ownPID
        Task.detached(priority: .userInitiated) { [weak self] in
            let states = WindowProbe.scanShields(ownPID: ownPID)
            await self?.adoptShields(states)
        }
    }

    private func adoptShields(_ states: [DisplayID: Bool]) {
        isScanningShields = false
        shieldStates = states
        shieldsScannedAt = ProcessInfo.processInfo.systemUptime
    }

    /// 看一遍在屏窗口，得出每块显示器上图标有没有被遮住。任何线程可调。
    private nonisolated static func scanShields(ownPID: pid_t) -> [DisplayID: Bool] {
        let finderPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").map(\.processIdentifier))
        let iconLevelWindows = onScreenWindows().filter { $0.layer == desktopIconLevel }
        var states: [DisplayID: Bool] = [:]
        for display in DisplayLayout.current().displays {
            var isShielded = false
            for window in iconLevelWindows where covers(window.bounds, display.frame) {
                if finderPIDs.contains(window.ownerPID) { break }   // 走到访达的图标窗口了：它前面没有遮挡
                if window.ownerPID != ownPID, window.alpha > 0.01 {
                    isShielded = true
                    break
                }
            }
            states[display.id] = isShielded
        }
        return states
    }

    /// 窗口是否盖住了这块显示器的九成以上。
    private nonisolated static func covers(_ bounds: CGRect, _ display: CGRect) -> Bool {
        let overlap = bounds.intersection(display)
        guard !overlap.isNull, display.width > 0, display.height > 0 else { return false }
        return overlap.width * overlap.height >= 0.9 * display.width * display.height
    }

    // MARK: 坐标

    /// 当前的显示器布局。读一次要 0.5 毫秒上下，所以记着用，每秒在后台线程重读一次；
    /// 只有第一次、以及记着的已经太旧时（例如应用暂停了一阵）才当场读。
    /// 帧不断流时，显示器插拔或改排列之后最多晚一秒跟上。
    func layout() -> DisplayLayout {
        let now = ProcessInfo.processInfo.systemUptime
        guard let cached = cachedLayout, now - cached.readAt < staleLimit else {
            let layout = DisplayLayout.current()
            cachedLayout = (layout, now)
            return layout
        }
        if now - cached.readAt >= 1, !isReadingLayout {
            isReadingLayout = true
            Task.detached(priority: .userInitiated) { [weak self] in
                let layout = DisplayLayout.current()
                await self?.adoptLayout(layout)
            }
        }
        return cached.value
    }

    private func adoptLayout(_ layout: DisplayLayout) {
        isReadingLayout = false
        cachedLayout = (layout, ProcessInfo.processInfo.systemUptime)
    }
}
