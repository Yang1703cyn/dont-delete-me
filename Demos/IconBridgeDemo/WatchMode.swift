// IconBridgeDemo · 只读模式：持续打印图标数量、各种类数量、矩形、变化事件（不含文件名）

import DDMCore
import Foundation
import IconBridge

@MainActor
func runWatch(seconds: TimeInterval) -> Int32 {
    let layout = DemoDisplays.layout()
    say("只读演示，持续 \(Int(seconds)) 秒。显示器：\(DemoDisplays.describe(layout))")
    if DemoDisplays.isUsingFallback {
        say("注意：显示器此刻都在睡眠，系统报告的活跃显示器为 0；以下的\"所在显示器\"按在线显示器的位置计算。")
    }

    let session = DemoSession()
    session.start()
    let gotFirst = session.waitForFirstUpdate(timeout: min(seconds, 20))
    if !gotFirst {
        say("还没有读到第一份快照（状态：\(statusName(session.provider.status))）。如果屏幕上有\"是否允许控制访达\"的询问，回答之后就会继续。")
    }
    pump(max(0, seconds - (now() - session.startedAt)))
    session.stop()

    let snapshot = session.provider.snapshot
    say("结束：状态 \(statusName(snapshot.status))；图标 \(snapshot.icons.count) 个（\(kindSummary(snapshot.icons))）；共上报 \(session.updates.count) 次、变化事件 \(session.changes.count) 个")
    say("读取开销：\(session.cycleSummary())")
    switch snapshot.status {
    case .ok, .starting:
        break
    case .permissionDenied:
        say("提示：系统设置 → 隐私与安全性 → 自动化 里，允许启动本程序的那个程序控制\"访达\"后会自动恢复。")
    case .finderUnavailable:
        say("提示：访达没有运行或没有响应；它恢复之后会自动重新读取。")
    case .stacksEnabled:
        say("提示：桌面开启了\"叠放\"，图标位置不可靠，所以不提供图标。")
    }
    return 0
}
