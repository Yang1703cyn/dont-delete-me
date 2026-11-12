// IconBridgeDemo · 多显示器核对：图标在每块屏上时，坐标换算和"所在显示器"是否正确
//
// 运行：swift run IconBridgeDemo --displays
// 用一个自己的临时文件，依次放到每块显示器的中部和两个角附近，核对：
//   - 访达原样接受并报告这个全局坐标（说明各块屏确实共用同一套坐标）；
//   - 图标桥给出的图像矩形以该坐标为中心；
//   - "所在显示器"就是这块屏；换成屏内坐标后落在这块屏的范围内；换成 AppKit 坐标后落在对应 NSScreen 的范围内。

import AppKit
import DDMCore
import Foundation
import IconBridge

@MainActor
final class DisplaysCheck {
    private let fileName = "\(TestBench.namePrefix)屏"

    func run() -> Int32 {
        let session = DemoSession(printsUpdates: false)
        session.start()
        defer { session.stop() }
        guard session.waitForFirstUpdate(timeout: 20), session.provider.status == .ok else {
            say("第一次读取没有成功，状态：\(statusName(session.provider.status))。中止。")
            return 1
        }
        let layout = DemoDisplays.layout()
        say("显示器：\(DemoDisplays.describe(layout))")
        if DemoDisplays.isUsingFallback {
            say("注意：显示器此刻都在睡眠（活跃显示器为 0），以下按在线显示器的位置核对。")
        }
        guard let first = layout.displays.first,
              let start = FreeSpot.find(count: 1, on: first, avoiding: session.provider.snapshot.icons).first
        else {
            say("找不到空位。中止。")
            return 1
        }
        do {
            try TestBench.createFile(named: fileName, at: start)
        } catch {
            say("新建临时文件失败：\(error)")
            return 1
        }
        defer {
            say(TestBench.cleanUp() ? "清理：临时文件已删除。" : "清理：没能删除临时文件，请手动删除桌面上名叫「\(fileName)」的文件。")
        }
        guard let added = session.waitForChange(from: 0, timeout: 8, where: { if case .added = $0 { return true } else { return false } }),
              case let .added(icon) = added.change
        else {
            say("临时文件没有被报告为新增。中止。")
            return 1
        }

        var failures = 0
        for display in layout.displays {
            let existing = session.provider.snapshot.icons.filter { $0.id != icon.id }
            var targets: [(String, CGPoint)] = []
            if let free = FreeSpot.find(count: 1, on: display, avoiding: existing).first {
                targets.append(("中部", free))
            }
            // 两个角附近：离边缘一个图标远，确保整个图标仍在这块屏内。
            targets.append(("左上角附近", CGPoint(x: display.frame.minX + 70, y: display.frame.minY + 110)))
            targets.append(("右下角附近", CGPoint(x: display.frame.maxX - 70, y: display.frame.maxY - 190)))

            for (label, target) in targets {
                // 角上的位置可能已经有用户的图标：只读地避开，不去叠在别人上面。
                let footprint = CGRect(x: target.x - 60, y: target.y - 45, width: 120, height: 110)
                if existing.contains(where: { $0.hitBounds.intersects(footprint) }) {
                    say("  – 显示器 \(display.id.rawValue) \(label) \(format(target))：那里已有图标，跳过")
                    continue
                }
                do {
                    try TestBench.setPosition(of: fileName, to: target)
                } catch {
                    say("  ✘ 显示器 \(display.id.rawValue) \(label)：设置位置失败 \(error)")
                    failures += 1
                    continue
                }
                let finderPosition = TestBench.position(of: fileName)
                session.provider.refreshNow()
                let arrived = pump(timeout: 5) { session.provider.snapshot.icon(withID: icon.id)?.imageRect.center == target }
                guard let current = session.provider.snapshot.icon(withID: icon.id) else {
                    say("  ✘ 显示器 \(display.id.rawValue) \(label)：快照里找不到临时图标")
                    failures += 1
                    continue
                }
                let local = display.localRect(fromGlobal: current.imageRect)
                let localOK = CGRect(origin: .zero, size: display.frame.size).contains(local)
                let appKit = layout.appKitRect(fromGlobal: current.imageRect)
                let screen = NSScreen.screens.first { $0.ddmDisplayID == display.id }
                let appKitOK = screen.map { $0.frame.contains(appKit) }
                let passed = finderPosition == target && arrived && current.displayID == display.id && localOK && appKitOK != false
                if !passed { failures += 1 }
                say("  \(passed ? "✔" : "✘") 显示器 \(display.id.rawValue)\(display.isPrimary ? "(主屏)" : "") \(label)：设置 \(format(target))，访达读回 \(finderPosition.map(format) ?? "?")；图像矩形 \(format(current.imageRect))；所在显示器 \(current.displayID.map { "\($0.rawValue)" } ?? "?")；屏内坐标 \(format(local))\(localOK ? "" : "（越界！）")；AppKit 坐标 \(format(appKit))\(appKitOK.map { $0 ? "，在对应 NSScreen 内" : "，不在对应 NSScreen 内！" } ?? "（找不到对应的 NSScreen）")")
            }
        }

        // 屏幕之外的位置：访达会拒绝，图标留在原处。
        let before = TestBench.position(of: fileName)
        let outside = CGPoint(x: layout.bounds.maxX + 500, y: layout.bounds.maxY + 500)
        try? TestBench.setPosition(of: fileName, to: outside)
        let after = TestBench.position(of: fileName)
        say("  \(before == after ? "✔" : "✘") 屏幕之外的位置 \(format(outside))：访达\(before == after ? "没有接受，图标留在原处" : "接受了（与预期不符）")")
        if before != after { failures += 1 }

        say(failures == 0 ? "多显示器核对：全部通过" : "多显示器核对：\(failures) 项未通过")
        return failures == 0 ? 0 : 1
    }
}
