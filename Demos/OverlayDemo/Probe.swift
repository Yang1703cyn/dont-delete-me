// OverlayDemo · 系统状态探针
//
// 运行：swift run OverlayDemo --probe            打印一次
//       swift run OverlayDemo --probe --watch 40  持续 40 秒，叠加层的判断一变就打印一行（期间照常画替身脸）
//
// 用来回答"图标层此刻看不看得见、叠加层是怎么判断的"。人工检查时，在不同的系统状态下各跑一次即可对照。
// 只读：桌面附近那几层的系统窗口（属主程序名、层级、透明度、边界——不读窗口标题），
// 以及系统设置里"桌面与程序坞"的几个开关。不读桌面上的任何内容。

import AppKit
import CoreGraphics
import DDMCore
import Foundation
import Overlay

@MainActor
func runProbe(_ arguments: Arguments) -> Never {
    let layout = DisplayLayout.current()
    let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))

    print("[探针] 显示器：")
    for display in layout.displays {
        print("  屏 \(display.id.rawValue)：位于 (\(Int(display.frame.minX)), \(Int(display.frame.minY)))，\(Int(display.frame.width))×\(Int(display.frame.height)) @\(Int(display.scale))x\(display.isPrimary ? "（主屏）" : "")")
    }

    print("[探针] 系统设置「桌面与程序坞」里与桌面项目有关的开关（只读）：")
    func setting(_ key: String) -> String {
        guard let value = CFPreferencesCopyAppValue(key as CFString, "com.apple.WindowManager" as CFString) else { return "未设置（系统默认）" }
        return (value as? Bool).map { $0 ? "是" : "否" } ?? "\(value)"
    }
    print("  在桌面上隐藏项目（StandardHideDesktopIcons）：\(setting("StandardHideDesktopIcons"))")
    print("  台前调度里隐藏项目（HideDesktop）：\(setting("HideDesktop"))")
    print("  台前调度已开启（GloballyEnabled）：\(setting("GloballyEnabled"))")
    print("  点按墙纸显示桌面·始终（EnableStandardClickToShowDesktop）：\(setting("EnableStandardClickToShowDesktop"))")

    print("[探针] 此刻在屏、位于桌面附近层级的系统窗口（从前到后；层级写成相对「桌面图标层」的差）：")
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[CFString: Any]] ?? []
    var printed = 0
    for info in list {
        guard let layer = info[kCGWindowLayer] as? Int, layer < 0,
              let boundsInfo = info[kCGWindowBounds],
              let bounds = CGRect(dictionaryRepresentation: boundsInfo as! CFDictionary) else { continue }
        let owner = info[kCGWindowOwnerName] as? String ?? "?"
        let alpha = info[kCGWindowAlpha] as? Double ?? 1
        let delta = layer - iconLevel
        let onDisplay = layout.display(bestFor: bounds).map { "屏 \($0.id.rawValue)" } ?? "?"
        print("  \(owner)：图标层\(delta >= 0 ? "+" : "")\(delta)，透明度 \(format(alpha, 2))，\(Int(bounds.width))×\(Int(bounds.height))，在\(onDisplay)")
        printed += 1
    }
    if printed == 0 { print("  （没有）") }

    print("[探针] 叠加层（默认设置）的判断：")
    let host = makeHost(arguments)
    Lifecycle.shared.onExit { host.stop() }

    guard let watch = arguments.value("--watch") else {
        host.start()
        spin(0.8)
        print(describe(host.diagnostics))
        print("  说明：图标层 visible=看得见；absent=这块屏上没有访达的图标层窗口（全屏应用的空间、访达没运行）；")
        print("        shielded=图标层被系统的整屏遮挡窗口盖住（系统设置里关了「在桌面上显示项目」等）。")
        Lifecycle.shared.finish(code: 0)
    }

    // 持续观察：照常画替身脸，判断一变就打印。
    let seconds = min(max(Double(watch) ?? 30, 1), demoTimeLimit)
    let source = DemoSource(icons: FakeDesktop.icons(count: arguments.int("--count", default: 30), on: layout), layout: layout)
    source.mode = .follow
    host.frameSource = source
    host.start()
    print("[探针] 观察 \(Int(seconds)) 秒。现在可以切换空间、进出全屏、显示桌面、锁屏……判断一变就会打印。")
    var lastSummary = ""
    let end = uptime() + seconds
    while uptime() < end, !Lifecycle.shared.shouldQuit {
        spin(0.2)
        let diagnostics = host.diagnostics
        let summary = "桌面可见=\(diagnostics.isDesktopVisible) 锁屏=\(diagnostics.isScreenLocked) 屏幕睡眠=\(diagnostics.areDisplaysAsleep) | "
            + diagnostics.displays.map {
                "屏 \($0.id.rawValue)：图标层=\($0.iconLayer) 窗口=\($0.desktopWindowCount) 当前空间有=\($0.hasWindowOnActiveSpace) 被挡住=\($0.isOccluded) 看得见=\($0.isVisible)"
            }.joined(separator: "；")
        if summary != lastSummary {
            lastSummary = summary
            print("  [\(format(seconds - (end - uptime())))s] \(summary)")
        }
    }
    print("[探针] 结束。期间帧回调 \(source.frames) 次，重画 \(source.draws) 次。")
    Lifecycle.shared.finish(code: 0)
}
