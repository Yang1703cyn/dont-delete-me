// IconBridgeDemo · 自测：用自己的临时文件走一遍"新增 / 移动 / 消失 / 进废纸篓"
//
// 运行：swift run IconBridgeDemo --selftest
// 全程只动自己新建的临时文件（名字以「别删我-测试」开头，同时最多 2 个，另加一个自建的小磁盘映像），结束后清理干净。

import DDMCore
import Foundation
import IconBridge

@MainActor
final class SelfTest {
    private var results: [(name: String, passed: Bool, detail: String)] = []
    private let session = DemoSession(printsUpdates: true, printsIcons: false)

    private func check(_ name: String, _ passed: Bool, _ detail: String) {
        results.append((name, passed, detail))
        say("  \(passed ? "✔" : "✘") \(name)：\(detail)")
    }

    func run() -> Int32 {
        say("自测开始。只使用自己新建的临时文件，结束后清理。")
        session.start()
        defer { session.stop() }

        guard session.waitForFirstUpdate(timeout: 20), session.provider.status == .ok else {
            say("第一次读取没有成功，状态：\(statusName(session.provider.status))。自测中止。")
            return 1
        }
        let layout = DemoDisplays.layout()
        guard let display = layout.primary ?? layout.displays.first else {
            say("没有可用的显示器信息，自测中止。")
            return 1
        }
        let spots = FreeSpot.find(count: 3, on: display, avoiding: session.provider.snapshot.icons)
        guard spots.count == 3 else {
            say("主屏上找不到足够的空位，自测中止。")
            return 1
        }
        let baselineCount = session.provider.snapshot.icons.count
        let trashBefore = TestBench.trashCount()
        say("起始：桌面 \(baselineCount) 个图标；废纸篓 \(trashBefore.map(String.init) ?? "?") 项；临时文件将放在 \(spots.map(format).joined(separator: " "))")

        let fileA = "\(TestBench.namePrefix)A"
        let fileB = "\(TestBench.namePrefix)B"
        defer {
            let clean = TestBench.cleanUp()
            let trashAfter = TestBench.trashCount()
            say("清理：临时文件\(clean ? "已全部删除" : "没有清理干净！请手动删除桌面上名字以「别删我-测试」开头的文件")；废纸篓 \(trashAfter.map(String.init) ?? "?") 项（起始 \(trashBefore.map(String.init) ?? "?") 项）")
        }

        do {
            // —— 1. 新建 → 新增 ——
            var mark = session.changes.count
            var t0 = now()
            try TestBench.createFile(named: fileA, at: spots[0])
            guard let added = session.waitForChange(from: mark, timeout: 8, where: { if case .added = $0 { return true } else { return false } }),
                  case let .added(iconA) = added.change
            else {
                check("新建 → 新增", false, "8 秒内没有收到新增事件")
                return finish()
            }
            // 新建和摆位是两步：可能先报"新增"（在访达自动安排的位置）、随后报"移动"。等它到位。
            let settled = pump(timeout: 5) { self.session.provider.snapshot.icon(withID: iconA.id)?.imageRect.center == spots[0] }
            let current = session.provider.snapshot.icon(withID: iconA.id)
            check(
                "新建 → 新增",
                iconA.kind == .file && settled && current?.displayID == display.id && session.provider.snapshot.icons.count == baselineCount + 1,
                String(format: "%.2f 秒后收到；种类 %@；到位后图像矩形 %@（期望中心 %@）；显示器 %@",
                       added.time - t0, kindName(iconA.kind), current.map { format($0.imageRect) } ?? "?", format(spots[0]),
                       current?.displayID.map { "\($0.rawValue)" } ?? "?")
            )

            // —— 2. 改位置 → 移动（只靠定时轮询发现）——
            pump(1.2)   // 等"发现变化后的追加读取"过去，让下面量到的是普通轮询的延迟
            mark = session.changes.count
            t0 = now()
            try TestBench.setPosition(of: fileA, to: spots[1])
            if let moved = session.waitForChange(from: mark, timeout: 15, where: { if case let .moved(_, to) = $0 { return to.id == iconA.id } else { return false } }),
               case let .moved(from, to) = moved.change {
                check(
                    "改位置 → 移动（定时轮询）",
                    from.imageRect.center == spots[0] && to.imageRect.center == spots[1],
                    String(format: "%.2f 秒后收到；%@ → %@", moved.time - t0, format(from.imageRect), format(to.imageRect))
                )
            } else {
                check("改位置 → 移动（定时轮询）", false, "15 秒内没有收到移动事件")
            }

            // —— 2b. 改位置 + refreshNow() → 移动（应用在鼠标松开时的用法）——
            pump(1.2)
            mark = session.changes.count
            try TestBench.setPosition(of: fileA, to: spots[0])
            t0 = now()
            session.provider.refreshNow()
            if let moved = session.waitForChange(from: mark, timeout: 8, where: { if case let .moved(_, to) = $0 { return to.id == iconA.id } else { return false } }),
               case let .moved(_, to) = moved.change {
                check(
                    "改位置 + 立即刷新 → 移动",
                    to.imageRect.center == spots[0] && moved.time - t0 < 0.5,
                    String(format: "调用 refreshNow() 后 %.0f 毫秒收到", (moved.time - t0) * 1000)
                )
            } else {
                check("改位置 + 立即刷新 → 移动", false, "8 秒内没有收到移动事件")
            }

            // —— 3. 直接删除 → 消失（没进废纸篓）——
            mark = session.changes.count
            try TestBench.createFile(named: fileB, at: spots[2])
            guard let addedB = session.waitForChange(from: mark, timeout: 8, where: { if case .added = $0 { return true } else { return false } }),
                  case let .added(iconB) = addedB.change
            else {
                check("直接删除 → 消失", false, "第二个临时文件没有被报告为新增")
                return finish()
            }
            pump(1.2)
            mark = session.changes.count
            t0 = now()
            try TestBench.deleteDirectly(fileB)
            if let removed = session.waitForChange(from: mark, timeout: 8, where: { if case let .removed(icon, _) = $0 { return icon.id == iconB.id } else { return false } }),
               case let .removed(last, verdict) = removed.change {
                check(
                    "直接删除 → 消失",
                    verdict == .no && last.imageRect.center == spots[2],
                    String(format: "%.2f 秒后收到；进了废纸篓：%@；最后位置 %@", removed.time - t0, verdict.rawValue, format(last.imageRect))
                )
            } else {
                check("直接删除 → 消失", false, "8 秒内没有收到消失事件")
            }

            // —— 4. 磁盘：挂载 → 新增（磁盘）；推出 → 消失（没进废纸篓）——
            runVolumeStep()

            // —— 5. 经访达移入废纸篓 → 消失 + 进了废纸篓 ——
            pump(1.2)
            mark = session.changes.count
            t0 = now()
            try TestBench.moveToTrash(fileA)
            if let removed = session.waitForChange(from: mark, timeout: 8, where: { if case let .removed(icon, _) = $0 { return icon.id == iconA.id } else { return false } }),
               case let .removed(last, verdict) = removed.change {
                check(
                    "移入废纸篓 → 消失 + 进了废纸篓",
                    verdict == .yes && last.imageRect.center == spots[0],
                    String(format: "%.2f 秒后收到；进了废纸篓：%@；最后位置 %@", removed.time - t0, verdict.rawValue, format(last.imageRect))
                )
            } else {
                check("移入废纸篓 → 消失 + 进了废纸篓", false, "8 秒内没有收到消失事件")
            }

            // —— 6. 立即刷新：没有变化也要回调一次 ——
            pump(1.6)
            let updatesBefore = session.updates.count
            let revisionBefore = session.provider.snapshot.revision
            t0 = now()
            session.provider.refreshNow()
            if pump(timeout: 5, until: { self.session.updates.count > updatesBefore }), let last = session.updates.last {
                check(
                    "立即刷新：没有变化也回调",
                    last.update.changes.isEmpty && !last.update.isReset && last.update.snapshot.revision == revisionBefore && last.update.snapshot.capturedAt >= t0,
                    String(format: "%.0f 毫秒后回调；变化 %d 个；版本号 %@；读取开始时刻不早于调用时刻：%@",
                           (last.time - t0) * 1000, last.update.changes.count,
                           last.update.snapshot.revision == revisionBefore ? "不变" : "变了",
                           last.update.snapshot.capturedAt >= t0 ? "是" : "否")
                )
            } else {
                check("立即刷新：没有变化也回调", false, "5 秒内没有回调")
            }
        } catch {
            check("测试台操作", false, "\(error)")
        }
        return finish()
    }

    /// 用一个自建的小磁盘映像验证"磁盘"这一种类。做不了（没有 hdiutil 等）就跳过，不算失败。
    private func runVolumeStep() {
        let volumeName = "\(TestBench.namePrefix)盘"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ddm-iconbridge-demo-\(getpid())")
        let image = directory.appendingPathComponent("volume.dmg")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func hdiutil(_ arguments: [String]) -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
        guard hdiutil(["create", "-size", "2m", "-fs", "HFS+", "-volname", volumeName, image.path]) else {
            say("  – 磁盘一步跳过：建不了磁盘映像")
            return
        }

        pump(1.2)
        var mark = session.changes.count
        guard hdiutil(["attach", image.path]) else {
            say("  – 磁盘一步跳过：挂载失败")
            return
        }
        let mountPoint = "/Volumes/\(volumeName)"
        defer { if FileManager.default.fileExists(atPath: mountPoint) { _ = hdiutil(["detach", mountPoint, "-force"]) } }

        guard let added = session.waitForChange(from: mark, timeout: 10, where: { if case let .added(icon) = $0 { return icon.kind == .volume } else { return false } }),
              case let .added(volume) = added.change
        else {
            // 访达偏好里可以设置"外置磁盘不显示在桌面上"，那样就不会有这个图标。
            say("  – 磁盘一步跳过：挂载后桌面上没有出现磁盘图标（访达可能设置了不在桌面显示外置磁盘）")
            return
        }
        check("挂载磁盘 → 新增（磁盘）", volume.kind == .volume, "种类 \(kindName(volume.kind))；图像矩形 \(format(volume.imageRect))")

        pump(1.2)
        mark = session.changes.count
        _ = hdiutil(["detach", mountPoint])
        if let removed = session.waitForChange(from: mark, timeout: 10, where: { if case let .removed(icon, _) = $0 { return icon.id == volume.id } else { return false } }),
           case let .removed(_, verdict) = removed.change {
            check("推出磁盘 → 消失", verdict == .no, "进了废纸篓：\(verdict.rawValue)")
        } else {
            check("推出磁盘 → 消失", false, "10 秒内没有收到消失事件")
        }
    }

    private func finish() -> Int32 {
        let failed = results.filter { !$0.passed }
        say("读取开销：\(session.cycleSummary())")
        if failed.isEmpty, !results.isEmpty {
            say("自测结果：全部通过（\(results.count) 项）")
            return 0
        }
        say("自测结果：\(failed.count) 项未通过（共 \(results.count) 项）")
        return 1
    }
}
