// IconBridgeDemo · 各模式共用的小工具：输出、等待、显示器布局、CPU 计量

import AppKit
import DDMCore
import Foundation
import IconBridge

/// 统一的输出前缀。演示程序的任何输出都不含文件名。
func say(_ text: String) {
    print("[IconBridgeDemo] \(text)")
    fflush(stdout)
}

func now() -> TimeInterval {
    ProcessInfo.processInfo.systemUptime
}

/// 让主线程转 `seconds` 秒，期间照常处理图标桥的回调。
@MainActor
func pump(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

/// 让主线程转到条件成立或超时。返回条件是否成立。
@MainActor
@discardableResult
func pump(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
    let deadline = now() + timeout
    while !condition() {
        if now() >= deadline { return false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return true
}

// MARK: - 显示器

/// 演示用的显示器布局。
///
/// 正常情况下就是 `DisplayLayout.current()`。显示器全都睡着时（例如没人在电脑前），系统报告的"活跃显示器"为 0，
/// 那样所有图标的"所在显示器"都判断不出来；为了仍能验证坐标换算，这时退回到"在线显示器"——
/// 它们的位置和尺寸在睡眠期间保持不变。
enum DemoDisplays {
    static func layout() -> DisplayLayout {
        let current = DisplayLayout.current()
        return current.displays.isEmpty ? onlineLayout() : current
    }

    static var isUsingFallback: Bool {
        DisplayLayout.current().displays.isEmpty && !onlineLayout().displays.isEmpty
    }

    static func onlineLayout() -> DisplayLayout {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else {
            return DisplayLayout(displays: [])
        }
        return DisplayLayout(displays: ids.prefix(Int(count)).map { id in
            var scale: CGFloat = 1
            if let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 {
                scale = CGFloat(mode.pixelWidth) / CGFloat(mode.width)
            }
            return DisplayInfo(id: DisplayID(rawValue: id), frame: CGDisplayBounds(id), scale: scale)
        })
    }

    static func describe(_ layout: DisplayLayout) -> String {
        layout.displays.map { display in
            "\(display.id.rawValue)\(display.isPrimary ? "(主屏)" : "") \(format(display.frame)) @\(Int(display.scale))x"
        }.joined(separator: "；")
    }

    /// 会话是否处于锁屏。
    static var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}

// MARK: - 格式化（只有数字和种类，没有名字）

func format(_ rect: CGRect) -> String {
    String(format: "(%.0f,%.0f %.0f×%.0f)", rect.minX, rect.minY, rect.width, rect.height)
}

func format(_ point: CGPoint) -> String {
    String(format: "(%.0f,%.0f)", point.x, point.y)
}

func kindName(_ kind: IconKind) -> String {
    switch kind {
    case .file: return "文件"
    case .folder: return "文件夹"
    case .application: return "应用"
    case .volume: return "磁盘"
    case .other: return "其它"
    }
}

func statusName(_ status: IconProviderStatus) -> String {
    switch status {
    case .starting: return "启动中"
    case .ok: return "正常"
    case .finderUnavailable: return "访达不可用"
    case .permissionDenied: return "被拒绝授权"
    case .stacksEnabled: return "桌面开启了叠放"
    }
}

/// 各种类的数量，例如"文件 18、文件夹 1"。
func kindSummary(_ icons: [DesktopIcon]) -> String {
    let parts = IconKind.allCases.compactMap { kind -> String? in
        let count = icons.filter { $0.kind == kind }.count
        return count > 0 ? "\(kindName(kind)) \(count)" : nil
    }
    return parts.isEmpty ? "无" : parts.joined(separator: "、")
}

func describe(_ appearance: DesktopAppearance) -> String {
    "图标 \(Int(appearance.iconSize)) 点、文字 \(Int(appearance.textSize)) 点、标签在\(appearance.labelPosition == .bottom ? "下" : "右")"
}

func describe(_ icon: DesktopIcon, layout: DisplayLayout, at wallClock: Date = Date()) -> String {
    var text = "\(icon.id) \(kindName(icon.kind)) 图像\(format(icon.imageRect))"
    if let label = icon.labelRect {
        text += " 标签\(format(label))"
    }
    if let id = icon.displayID {
        text += " 显示器 \(id.rawValue)\(layout.display(withID: id)?.isPrimary == true ? "(主屏)" : "")"
    } else {
        text += " 显示器 ?"
    }
    if let modified = icon.modifiedAt {
        let days = wallClock.timeIntervalSince(modified) / 86400
        text += days >= 1 ? String(format: " 修改于 %.0f 天前", days) : String(format: " 修改于 %.1f 小时前", days * 24)
    }
    return text
}

func describe(_ change: IconChange) -> String {
    switch change {
    case let .added(icon):
        return "新增 \(icon.id) \(kindName(icon.kind)) 图像\(format(icon.imageRect))"
    case let .removed(icon, trashed):
        let verdict: String
        switch trashed {
        case .yes: verdict = "是"
        case .no: verdict = "否"
        case .unknown: verdict = "不确定"
        }
        return "消失 \(icon.id) \(kindName(icon.kind)) 最后位置\(format(icon.imageRect))，进了废纸篓：\(verdict)"
    case let .moved(from, to):
        return String(
            format: "移动 %@ %@ → %@（位移 %.0f,%.0f）",
            "\(to.id)", format(from.imageRect), format(to.imageRect),
            to.imageRect.minX - from.imageRect.minX, to.imageRect.minY - from.imageRect.minY
        )
    }
}

// MARK: - CPU 计量

enum CPUMeter {
    /// 某个进程自启动以来累计用掉的 CPU 时间（秒）；读不到为 nil。
    static func cpuSeconds(of pid: pid_t) -> Double? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else { return nil }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = info.ri_user_time + info.ri_system_time
        return Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    static var finderPID: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier
    }
}
