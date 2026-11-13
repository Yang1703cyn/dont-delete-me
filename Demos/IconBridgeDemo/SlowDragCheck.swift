// IconBridgeDemo · 真人检查：慢慢拖（按住很久才松手）时，图标桥扛不扛得住
//
// 运行：swift run IconBridgeDemo --slow-drag-check
// 背景：访达在用户拖着图标期间完全不回应请求，一直卡到松手。图标桥此时应当保留上一份快照、不上报重载，
// 松手后尽快报出结果；拖了很久才扔进废纸篓时，仍要给出"进了废纸篓"。这个模式请真人来验证这两件事：
//   第一步：把临时图标拖起来，按住至少 25 秒，在桌面空位松手；
//   第二步：再把它拖起来，按住至少 25 秒，扔进废纸篓。
// 按住够久时会响一声提示音。结束后脚本把临时文件从废纸篓移回并删除。不模拟鼠标：必须由真人来拖。
// 加 --rehearse 则不等人，经访达直接改位置、移入废纸篓，只检查脚本流程（那样访达不会卡住）。

import AppKit
import DDMCore
import Foundation
import IconBridge

@MainActor
final class SlowDragCheck {
    private let rehearse: Bool
    private let fileName = "\(TestBench.namePrefix)-请慢慢拖我"
    private let minimumHold: TimeInterval = 25
    private let idleTimeout: TimeInterval = 240

    private var interrupted = false
    private let mouse = MouseRecorder()
    private let session = DemoSession(printsUpdates: false)
    private var failures = 0

    init(rehearse: Bool) {
        self.rehearse = rehearse
    }

    private func check(_ name: String, _ passed: Bool, _ detail: String) {
        if !passed { failures += 1 }
        say("  \(passed ? "✔" : "✘") \(name)：\(detail)")
    }

    func run() -> Int32 {
        session.start()
        defer { session.stop() }
        guard session.waitForFirstUpdate(timeout: 20), session.provider.status == .ok else {
            say("第一次读取没有成功，状态：\(statusName(session.provider.status))。中止。")
            return 1
        }
        let layout = DemoDisplays.layout()
        guard let display = layout.primary ?? layout.displays.first,
              case let spots = FreeSpot.find(count: 2, on: display, avoiding: session.provider.snapshot.icons), spots.count == 2
        else {
            say("主屏上找不到空位放临时图标。中止。")
            return 1
        }
        let trashBefore = TestBench.trashCount()
        do {
            try TestBench.createFile(named: fileName, at: spots[0])
        } catch {
            say("新建临时图标失败：\(error)")
            return 1
        }
        defer {
            let clean = TestBench.cleanUp()
            say("清理：\(clean ? "临时图标已删除" : "没能删除临时文件，请手动删除名叫「\(fileName)」的文件")；废纸篓 \(TestBench.trashCount().map(String.init) ?? "?") 项（开始时 \(trashBefore.map(String.init) ?? "?") 项）。")
        }

        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.interrupted = true } }
        interrupt.resume()
        defer { interrupt.cancel() }

        guard pump(timeout: 8, until: { self.session.provider.snapshot.icons.contains { $0.imageRect.center == spots[0] } }),
              let icon = session.provider.snapshot.icons.first(where: { $0.imageRect.center == spots[0] })
        else {
            say("图标桥没有读到临时图标。中止。")
            return 1
        }
        mouse.start()
        defer { mouse.stop() }

        if rehearse {
            say("演练模式：不等真人，经访达直接改位置、移入废纸篓，只检查脚本流程（访达不会卡住）。")
            say("（演练里的「松手后多少毫秒」包含访达执行这一步操作本身的时间，不代表真人拖动时的延迟。）")
        } else {
            say("——————————————————————————————————————————")
            say("桌面上（主屏，位置约 \(format(spots[0]))）新建了一个空白文件图标，名叫「\(fileName)」。一共两步：")
            say("第一步：把它拖起来，按住不放至少 \(Int(minimumHold)) 秒（可以慢慢移动），然后在桌面上别的空位松手。")
            say("第二步：再把它拖起来，按住不放至少 \(Int(minimumHold)) 秒，然后扔进废纸篓。")
            say("按住够久时会响一声提示音，这里也会提示。按 Ctrl-C 可以提前结束（会清理）。")
            say("——————————————————————————————————————————")
        }

        // —— 第一步：慢慢拖，在桌面上松手 ——
        say("第一步：慢慢拖到桌面上别的空位")
        guard let first = waitForSlowDrop(of: icon, rehearsal: { try TestBench.setPosition(of: self.fileName, to: spots[1]) }) else {
            say(interrupted ? "被中断。" : "没有等到拖动（超时）。")
            return 1
        }
        let moved = awaitChange(after: first) { change in
            if case let .moved(_, to) = change, to.id == icon.id { return true }
            return false
        }
        report(hold: first)
        if let moved {
            check("松手后报出移动", true, String(format: "松手后 %.0f 毫秒上报", (moved.time - first.releasedAt) * 1000))
        } else {
            check("松手后报出移动", false, "松手 5 秒内没有收到这个图标的移动事件")
        }

        // —— 第二步：慢慢拖进废纸篓 ——
        pump(1.5)
        guard !interrupted, let current = session.provider.snapshot.icon(withID: icon.id) else {
            say("临时图标不在桌面上了，跳过第二步。")
            return finish()
        }
        say("第二步：慢慢拖进废纸篓")
        guard let second = waitForSlowDrop(of: current, rehearsal: { try TestBench.moveToTrash(self.fileName) }) else {
            say(interrupted ? "被中断。" : "没有等到拖动（超时）。")
            return finish()
        }
        let removed = awaitChange(after: second) { change in
            if case let .removed(gone, _) = change, gone.id == icon.id { return true }
            return false
        }
        report(hold: second)
        if let removed, case let .removed(_, verdict) = removed.change {
            check("扔进废纸篓后报出\"消失 + 进了废纸篓\"", verdict == .yes,
                  String(format: "松手后 %.0f 毫秒上报；进了废纸篓：%@", (removed.time - second.releasedAt) * 1000, verdict.rawValue))
        } else {
            check("扔进废纸篓后报出\"消失 + 进了废纸篓\"", false, "松手 5 秒内没有收到这个图标的消失事件（是不是没扔进废纸篓？）")
        }
        return finish()
    }

    private func finish() -> Int32 {
        say(failures == 0 ? "结果：全部符合预期。请把以上输出交给总览。" : "结果：有 \(failures) 项不符合预期。请把以上输出交给总览。")
        return failures == 0 ? 0 : 1
    }

    // MARK: 一次"按住很久再松手"

    private struct SlowDrop {
        var pressedAt: TimeInterval
        var releasedAt: TimeInterval
        /// 按住期间图标桥的表现。
        var updatesDuringHold: Int
        var resetsDuringHold: Int
        var statusStayedOK: Bool
        var iconsStayed: Bool
        var busyCycles: Int
        var longestStall: TimeInterval
        var changeIndex: Int
    }

    /// 等一次"在图标上按下、按住够久、再松手"。演练时不等人，直接执行 `rehearsal`。
    private func waitForSlowDrop(of icon: DesktopIcon, rehearsal: () throws -> Void) -> SlowDrop? {
        _ = mouse.drain()
        if rehearse {
            pump(0.5)
            let index = session.changes.count
            let time = now()
            do { try rehearsal() } catch { say("演练操作失败：\(error)"); return nil }
            return SlowDrop(pressedAt: time, releasedAt: time, updatesDuringHold: 0, resetsDuringHold: 0, statusStayedOK: true, iconsStayed: true, busyCycles: 0, longestStall: 0, changeIndex: index)
        }

        let hitArea = icon.imageRect.insetBy(dx: -12, dy: -12).union((icon.labelRect ?? icon.imageRect).insetBy(dx: -8, dy: -4))
        let iconCount = session.provider.snapshot.icons.count
        var pressedAt: TimeInterval?
        var announced = 0
        var cued = false
        var updatesAtPress = 0, cyclesAtPress = 0, changesAtPress = 0
        var statusStayedOK = true, iconsStayed = true
        var lastActivity = now()

        while !interrupted, now() - lastActivity < idleTimeout {
            pump(0.01)
            for event in mouse.drain() {
                if event.isDown {
                    guard hitArea.contains(event.location) else { continue }
                    pressedAt = event.time
                    announced = 0
                    cued = false
                    updatesAtPress = session.updates.count
                    cyclesAtPress = session.cycles.count
                    changesAtPress = session.changes.count
                    statusStayedOK = true
                    iconsStayed = true
                    lastActivity = event.time
                } else if let pressed = pressedAt {
                    pressedAt = nil
                    let held = event.time - pressed
                    lastActivity = event.time
                    if held < minimumHold {
                        say(String(format: "  只按住了 %.0f 秒，不够 %d 秒。请再来一次。", held, Int(minimumHold)))
                        continue
                    }
                    let during = session.updates.dropFirst(updatesAtPress).filter { $0.time <= event.time }
                    let cycles = session.cycles.dropFirst(cyclesAtPress)
                    return SlowDrop(
                        pressedAt: pressed, releasedAt: event.time,
                        updatesDuringHold: during.count,
                        resetsDuringHold: during.filter { $0.update.isReset }.count,
                        statusStayedOK: statusStayedOK, iconsStayed: iconsStayed,
                        busyCycles: cycles.filter(\.finderWasBusy).count,
                        longestStall: cycles.map(\.stalledSeconds).max() ?? 0,
                        changeIndex: changesAtPress
                    )
                }
            }
            guard let pressed = pressedAt else { continue }
            // 按住期间：盯着图标桥的状态和图标数。
            if session.provider.status != .ok { statusStayedOK = false }
            if session.provider.snapshot.icons.count != iconCount { iconsStayed = false }
            let held = now() - pressed
            if Int(held / 5) > announced {
                announced = Int(held / 5)
                say("  已按住 \(announced * 5) 秒……（图标桥：状态「\(statusName(session.provider.status))」，图标 \(session.provider.snapshot.icons.count) 个）")
            }
            if held >= minimumHold, !cued {
                cued = true
                NSSound.beep()
                say("  够 \(Int(minimumHold)) 秒了，可以松手了。")
            }
        }
        return nil
    }

    /// 松手之后像应用那样连续请求立即刷新，直到出现想要的变化事件；最多等 5 秒。
    private func awaitChange(after drop: SlowDrop, where matches: (IconChange) -> Bool) -> (change: IconChange, time: TimeInterval)? {
        let deadline = now() + 5
        while now() < deadline, !interrupted {
            if let hit = session.changes.dropFirst(drop.changeIndex).first(where: { matches($0.change) }) {
                return (hit.change, hit.time)
            }
            session.provider.refreshNow()
            pump(0.004)
        }
        return nil
    }

    private func report(hold drop: SlowDrop) {
        guard !rehearse else { return }
        let held = drop.releasedAt - drop.pressedAt
        check(
            "按住期间图标桥保留快照、不上报重载",
            drop.resetsDuringHold == 0 && drop.statusStayedOK && drop.iconsStayed,
            String(format: "按住 %.0f 秒；期间上报 %d 次（其中整体重载 %d 次，应为 0）；状态一直正常：%@；图标一个不少：%@",
                   held, drop.updatesDuringHold, drop.resetsDuringHold, drop.statusStayedOK ? "是" : "否", drop.iconsStayed ? "是" : "否")
        )
        say(String(format: "    （期间请求被访达卡住最长 %.1f 秒；没等到回答的周期 %d 个——按住超过 15 秒时应当至少有 1 个）", drop.longestStall, drop.busyCycles))
    }
}
