// IconBridgeDemo · 与"叠放"有关的线索
//
// 运行：swift run IconBridgeDemo --stacks-check
// 图标桥识别叠放靠两条办法（见 Sources/IconBridge/StacksProbe.swift）：访达的一项桌面显示设置（分组方式）为主，
// "好几个图标位置完全相同"兜底。两条都还没在真的开了叠放的桌面上验证过。
// 请在"没开叠放"和"开了叠放"（桌面空白处点右键 → 使用叠放）两种状态下各运行一次，把两次的输出交给总览：
// 开了叠放的那一次，第一行应当是"桌面开启了叠放"。
// 只读，不改任何设置。除了"分组方式"这一项，不读取也不打印访达的任何其它偏好内容。

import DDMCore
import Foundation
import IconBridge

@MainActor
final class StacksCheck {
    func run() -> Int32 {
        let session = DemoSession(printsUpdates: false)
        session.start()
        let gotFirst = session.waitForFirstUpdate(timeout: 20)
        session.stop()

        let snapshot = session.provider.snapshot
        say("图标桥的判断：\(gotFirst ? "" : "（没有读到第一份快照）")状态「\(statusName(snapshot.status))」；提供图标 \(snapshot.icons.count) 个")

        // 办法 B 看的那一项：访达的桌面分组方式。
        say("访达的桌面分组设置（办法 B 的依据）：\(groupBySetting())")

        // 办法 A 看的东西：访达报告的位置里，有多少个图标的位置完全相同。直接问访达，状态是"叠放"时也看得到。
        if let positions = TestBench.allDesktopPositions() {
            var groups: [String: Int] = [:]
            for position in positions {
                groups["\(position.x),\(position.y)", default: 0] += 1
            }
            let shared = groups.values.filter { $0 > 1 }
            let layout = DemoDisplays.layout()
            let offscreen = positions.filter { layout.display(containing: $0) == nil }.count
            say("访达报告的位置（办法 A 的依据）：共 \(positions.count) 个图标、\(groups.count) 个不同的位置；\(shared.count) 个位置被多个图标共用，最多 \(shared.max() ?? 1) 个图标挤在同一个位置；位置不在任何一块屏上的 \(offscreen) 个")
        } else {
            say("访达报告的位置：读不到")
        }
        say("请在开、关\"叠放\"两种状态下各运行一次本命令，把两次输出都交给总览。")
        return 0
    }

    /// 只读出"分组方式"这一项的有无和取值；同组的其它设置不看、不打印。
    private func groupBySetting() -> String {
        let domain = "com.apple.finder" as CFString
        CFPreferencesAppSynchronize(domain)
        guard let settings = CFPreferencesCopyAppValue("DesktopViewSettings" as CFString, domain) as? [String: Any] else {
            return "读不到（无法判断）"
        }
        guard let groupBy = settings["GroupBy"] else { return "没有这一项（没开叠放时就是这样）" }
        guard let text = groupBy as? String else { return "有这一项，但不是文字（无法判断）" }
        return "\(text)"
    }
}
