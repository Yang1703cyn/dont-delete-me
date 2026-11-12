// Overlay · 读取系统状态
//
// 这个文件是模块里"向系统打听"的全部内容：在屏窗口列表、访达的进程号、锁屏与屏幕睡眠。
// 都是只读查询，不需要任何授权；不读窗口标题和程序名，不读任何用户文件。

import AppKit
import CoreGraphics
import DDMCore
import Foundation

enum SystemProbe {
    /// "桌面图标层"的窗口层级。访达的图标窗口就在这一层。
    static let desktopIconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))

    /// 系统拖放时"拖影"所在的窗口层级。
    static let draggingLevel = Int(CGWindowLevelForKey(.draggingWindow))

    /// 当前在屏的窗口，从前到后。只取编号、所属进程、层级、透明度、边界。
    static func onScreenWindows() -> [WindowEntry] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[CFString: Any]] else {
            return []
        }
        return list.compactMap { info in
            guard let number = info[kCGWindowNumber] as? Int,
                  let pid = info[kCGWindowOwnerPID] as? Int32,
                  let layer = info[kCGWindowLayer] as? Int,
                  let boundsInfo = info[kCGWindowBounds],
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as! CFDictionary)
            else { return nil }
            let alpha = info[kCGWindowAlpha] as? Double ?? 1
            return WindowEntry(number: number, ownerPID: pid, layer: layer, alpha: alpha, bounds: bounds)
        }
    }

    /// 访达的进程号；访达没在运行为 nil。
    @MainActor
    static func finderPID() -> Int32? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier
    }

    /// 读取会话状态：是否锁屏、是否所有显示器都睡着、会话是否在前台。
    /// `isSystemAsleep` 读不到，由调用方根据系统通知自己记。
    static func sessionState() -> SessionState {
        var state = SessionState()
        if let info = CGSessionCopyCurrentDictionary() as? [String: Any] {
            // 这个键只在锁屏期间出现。
            state.isScreenLocked = (info["CGSSessionScreenIsLocked"] as? Bool) ?? false
            state.isOnConsole = (info[kCGSessionOnConsoleKey as String] as? Bool) ?? true
        }
        state.areDisplaysAsleep = allDisplaysAsleep()
        return state
    }

    /// 是否所有连着的显示器都睡着了。一块都没连着也算。
    private static func allDisplaysAsleep() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return true }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).allSatisfy { CGDisplayIsAsleep($0) != 0 }
    }
}

/// 引起"该重新看一眼系统状态"的事件。
enum SystemEvent: Equatable, Sendable {
    case screenLocked
    case screenUnlocked
    case displaysSlept
    case displaysWoke
    case systemWillSleep
    case systemDidWake
    case sessionResigned
    case sessionBecameActive
    /// 切换了桌面空间（含进出全屏应用的空间）。
    case spaceChanged
    /// 切换空间约一秒之后的复查（不是系统发的，是叠加层自己约的）：
    /// 切换那一刻系统的回答可能还没跟上，或者用户紧接着又切了一次。
    case spaceSettled
    /// 显示器插拔、分辨率或排列变化。
    case screenParametersChanged
    /// 前台应用变了、有应用启动或退出（显示桌面、访达重启时会伴随发生）。
    case applicationsChanged
    /// 我们的某个窗口被挡住 / 露出来了。
    case occlusionChanged
}

/// 监听上面这些事件。只负责"喊一声"，状态本身由 OverlayHost 重新读取。
@MainActor
final class SystemEventMonitor {
    var onEvent: (@MainActor (SystemEvent) -> Void)?

    private var tokens: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

    func start() {
        guard tokens.isEmpty else { return }

        let distributed = DistributedNotificationCenter.default()
        observe(distributed, "com.apple.screenIsLocked", .screenLocked)
        observe(distributed, "com.apple.screenIsUnlocked", .screenUnlocked)

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification, .displaysSlept)
        observe(workspace, NSWorkspace.screensDidWakeNotification, .displaysWoke)
        observe(workspace, NSWorkspace.willSleepNotification, .systemWillSleep)
        observe(workspace, NSWorkspace.didWakeNotification, .systemDidWake)
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification, .sessionResigned)
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification, .sessionBecameActive)
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification, .spaceChanged)
        observe(workspace, NSWorkspace.didActivateApplicationNotification, .applicationsChanged)
        observe(workspace, NSWorkspace.didLaunchApplicationNotification, .applicationsChanged)
        observe(workspace, NSWorkspace.didTerminateApplicationNotification, .applicationsChanged)

        let local = NotificationCenter.default
        observe(local, NSApplication.didChangeScreenParametersNotification, .screenParametersChanged)
        // 只关心自己的叠加窗口。
        let token = local.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let isOurs = notification.object is CanvasWindow
            MainActor.assumeIsolated {
                if isOurs { self?.onEvent?(.occlusionChanged) }
            }
        }
        tokens.append((local, token))
    }

    func stop() {
        for (center, token) in tokens {
            center.removeObserver(token)
        }
        tokens.removeAll()
    }

    private func observe(_ center: NotificationCenter, _ name: String, _ event: SystemEvent) {
        observe(center, Notification.Name(name), event)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ event: SystemEvent) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEvent?(event) }
        }
        tokens.append((center, token))
    }
}
