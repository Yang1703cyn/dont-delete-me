// IconBridgeDemo · 真人拖动检查：手动拖动图标后，访达报告的位置是否更新、延迟多久
//
// 运行：swift run IconBridgeDemo --drag-check
// 一条命令完成"新建临时图标 → 等你拖动 → 报告结果 → 清理"。不模拟鼠标：必须由真人来拖。
// 加 --rehearse 则不等人：先用编出来的时间线自检记账逻辑，再经访达直接改位置走一遍流程。
//
// 分两个阶段，各拖两次：
//   阶段一（访达自己）：图标桥不工作，本程序不停地直接问访达那个临时图标的位置，量出"松开鼠标后多久访达答出新位置"。
//          已知访达在拖动期间不回应请求：拖动途中发出的那一问会被卡到松手才回答，脚本会把它算作这次松手的结果，并报告被卡了多久。
//   阶段二（图标桥）：像应用那样，松开鼠标后连续调用 refreshNow() 直到图标桥上报"移动"，量出总延迟。
// 两个阶段分开，是因为实测同一个进程里两个线程同时向访达发请求会偶发约半秒的卡顿，混在一起测不准。

import AppKit
import DDMCore
import Foundation
import IconBridge

@MainActor
final class DragCheck {
    private let rehearse: Bool
    private let fileName = "\(TestBench.namePrefix)-请拖动我"
    private let dragsPerPhase: Int
    private let idleTimeout: TimeInterval = 150

    private var interrupted = false
    private var iconSize: CGFloat = 64
    private let mouse = MouseRecorder()
    /// 阶段一里，拖动途中发出的询问被访达卡住的最长时间。
    private var longestBlocked: TimeInterval = 0

    init(rehearse: Bool) {
        self.rehearse = rehearse
        dragsPerPhase = rehearse ? 1 : 2
    }

    func run() -> Int32 {
        if rehearse {
            // 先自检记账逻辑：其中第一个情形就是真人检查时出过误报的那个（拖动途中的一问被卡到松手才答）。
            let failures = DragLedger.selfCheck()
            if failures.isEmpty {
                say("记账自检：\(DragLedger.selfCheckScenarioCount) 个情形全部符合预期（含\"拖动途中的询问被访达卡到松手才回答\"）。")
            } else {
                for failure in failures { say("记账自检不符：\(failure)") }
                return 1
            }
        }

        // 先读一次桌面，为的是找空位、知道图标大小。读完就停，阶段一不需要图标桥。
        let session = DemoSession(printsUpdates: false)
        session.start()
        guard session.waitForFirstUpdate(timeout: 20), session.provider.status == .ok else {
            say("第一次读取没有成功，状态：\(statusName(session.provider.status))。中止。")
            session.stop()
            return 1
        }
        iconSize = session.provider.appearance.iconSize
        let layout = DemoDisplays.layout()
        let existing = session.provider.snapshot.icons
        session.stop()
        guard let display = layout.primary ?? layout.displays.first,
              case let spots = FreeSpot.find(count: 3, on: display, avoiding: existing), spots.count == 3
        else {
            say("主屏上找不到空位放临时图标。中止。")
            return 1
        }

        do {
            try TestBench.createFile(named: fileName, at: spots[0])
        } catch {
            say("新建临时图标失败：\(error)")
            return 1
        }
        defer { cleanUp() }

        // Ctrl-C 也要清理。
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.interrupted = true } }
        interrupt.resume()
        defer { interrupt.cancel() }

        guard pump(timeout: 8, until: { TestBench.position(of: self.fileName) == spots[0] }) else {
            say("临时图标没有出现在预定位置。中止。")
            return 1
        }
        mouse.start()
        defer { mouse.stop() }

        if rehearse {
            say("演练模式：不等真人，经访达把临时图标改两次位置（每个阶段一次），只检查脚本流程。")
        } else {
            say("——————————————————————————————————————————")
            say("桌面上（主屏，位置约 \(format(spots[0]))）新建了一个空白文件图标，名叫「\(fileName)」。")
            say("请用鼠标把它拖到桌面上别的空位再松手，一共拖 \(dragsPerPhase * 2) 次（可以有一次拖到另一块屏上）。")
            say("每拖一次这里会打印一行结果；拖够次数、或 \(Int(idleTimeout)) 秒无人操作后，自动汇报并删除这个临时文件。")
            say("请不要把它拖进废纸篓或文件夹。按 Ctrl-C 可以提前结束（同样会清理）。")
            say("——————————————————————————————————————————")
        }

        say("阶段一：访达自己多久答出新位置（请拖 \(dragsPerPhase) 次）")
        let direct = observeDirectly(start: spots[0], rehearsalTargets: [spots[1]])
        var viaBridge: [DragObservation] = []
        if !interrupted, TestBench.existsOnDesktop(fileName) {
            say("阶段二：图标桥多久上报移动（请再拖 \(dragsPerPhase) 次）")
            viaBridge = observeThroughBridge(rehearsalTargets: [spots[2]])
        }
        summarize(direct: direct, viaBridge: viaBridge)
        return 0
    }

    // MARK: 阶段一：直接问访达

    private func observeDirectly(start: CGPoint, rehearsalTargets: [CGPoint]) -> [DragObservation] {
        var observations: [DragObservation] = []
        var ledger = DragLedger(position: start, iconSize: iconSize)
        var lastActivity = now()
        var rehearsed = 0
        _ = mouse.drain()

        func record(_ observation: DragObservation?) {
            guard let observation else { return }
            observations.append(observation)
            lastActivity = now()
            if let blocked = observation.blockedFor { longestBlocked = max(longestBlocked, blocked) }
            let index = observations.filter(\.countsAsDrop).count
            say(observation.countsAsDrop ? "  第 \(index) 次：\(describe(observation))" : "  \(describe(observation))")
        }

        while observations.filter(\.countsAsDrop).count < dragsPerPhase, !interrupted, now() - lastActivity < idleTimeout {
            pump(0.003)
            if rehearse, !ledger.isAwaitingResult, rehearsed < rehearsalTargets.count {
                pump(0.8)
                try? TestBench.setPosition(of: fileName, to: rehearsalTargets[rehearsed])
                rehearsed += 1
            }

            // 问访达（拖动期间这一问会被卡住，直到松手才回来）。
            let sentAt = now()
            let answer = TestBench.position(of: fileName)
            let answeredAt = now()

            // 先把这期间积压的鼠标事件按时间顺序记上，再记这次答复——次序不能反：
            // 被卡住的这一问答回来时，"松手"已经发生了，只是主线程刚才没空看。
            for event in mouse.drain() {
                if event.isDown { lastActivity = event.time }
                record(ledger.note(mouse: event))
            }
            guard let position = answer else {
                // 这一问没有得到答复。如果鼠标还按着、或这一问等了很久，那是拖动期间访达不回应（等到超时了）——
                // 接着等下一问，不能当成"图标没了"。
                if mouse.isDown || answeredAt - sentAt > 2 {
                    longestBlocked = max(longestBlocked, answeredAt - sentAt)
                    continue
                }
                if !TestBench.existsOnDesktop(fileName) {
                    say("临时图标不在桌面上了（被拖进了废纸篓或文件夹？）。提前结束。")
                    break
                }
                continue
            }
            record(ledger.note(position: position, sentAt: sentAt, answeredAt: answeredAt))
            record(ledger.tick(now: now()))
        }
        return observations
    }

    // MARK: 阶段二：经图标桥

    private func observeThroughBridge(rehearsalTargets: [CGPoint]) -> [DragObservation] {
        let session = DemoSession(printsUpdates: false)
        session.start()
        defer { session.stop() }
        guard session.waitForFirstUpdate(timeout: 20), let start = TestBench.position(of: fileName),
              let icon = session.provider.snapshot.icons.first(where: { $0.imageRect.center == start })
        else {
            say("图标桥没有读到临时图标。跳过阶段二。")
            return []
        }

        var observations: [DragObservation] = []
        var ledger = DragLedger(position: start, iconSize: iconSize)
        var lastActivity = now()
        var rehearsed = 0
        var changeIndex = session.changes.count
        let updatesAtStart = session.updates.count
        _ = mouse.drain()

        func record(_ observation: DragObservation?) {
            guard let observation else { return }
            observations.append(observation)
            lastActivity = now()
            say("  第 \(observations.count) 次：\(describe(observation))")
        }

        while observations.count < dragsPerPhase, !interrupted, now() - lastActivity < idleTimeout {
            pump(0.003)
            if rehearse, ledger.pendingReleaseTime == nil, rehearsed < rehearsalTargets.count {
                pump(0.8)
                try? TestBench.setPosition(of: fileName, to: rehearsalTargets[rehearsed])
                ledger.noteRehearsedRelease(at: now())
                rehearsed += 1
            }
            for event in mouse.drain() {
                if event.isDown { lastActivity = event.time }
                _ = ledger.note(mouse: event)
            }
            if session.provider.status == .ok, session.provider.snapshot.icon(withID: icon.id) == nil, ledger.pendingReleaseTime == nil {
                say("临时图标不在桌面上了（被拖进了废纸篓或文件夹？）。提前结束。")
                break
            }

            // 图标桥有没有上报这个图标的移动。
            let moved = session.changes.dropFirst(changeIndex).first { entry in
                if case let .moved(_, to) = entry.change { return to.id == icon.id }
                return false
            }
            if let moved, case let .moved(_, to) = moved.change {
                changeIndex = session.changes.count
                record(ledger.noteReported(position: to.imageRect.center, at: moved.time))
                continue
            }
            if ledger.pendingReleaseTime != nil {
                // 应用在松手后就是这么做的：每帧请求立即刷新，直到看到结局。
                session.provider.refreshNow()
            }
            record(ledger.tick(now: now()))
        }

        // 拖动期间图标桥的表现：有没有清空过快照、被访达卡了多久。
        let during = session.updates.dropFirst(updatesAtStart)
        let resets = during.filter { $0.update.isReset }.count
        let stalled = session.cycles.map(\.stalledSeconds).max() ?? 0
        let busy = session.cycles.filter(\.finderWasBusy).count
        say(String(format: "  （这一阶段图标桥：整体重载 %d 次（应为 0）；请求被访达卡住最长 %.1f 秒；没等到回答的周期 %d 个；状态「%@」）", resets, stalled, busy, statusName(session.provider.status)))
        say("  （读取开销：\(session.cycleSummary())）")
        return observations
    }

    // MARK: 输出

    private func describe(_ observation: DragObservation) -> String {
        switch observation.kind {
        case .dropNotUpdated:
            let moved = observation.mouseDelta.map { String(format: "鼠标拖了 (%.0f,%.0f) 后松手，", $0.dx, $0.dy) } ?? ""
            return "\(moved)等了 3 秒，位置仍然是 \(format(observation.from))，【没有更新】"
        case .changedWhileDragging:
            return "（鼠标还按着、拖动途中，访达报告的位置就变了：\(format(observation.from)) → \(observation.to.map(format) ?? "?")）"
        case .dropUpdated, .changedWithoutMouse:
            guard let to = observation.to else { return "?" }
            var text = String(format: "位置 %@ → %@（位移 %.0f,%.0f）", format(observation.from), format(to), to.x - observation.from.x, to.y - observation.from.y)
            if let delta = observation.mouseDelta, observation.kind == .dropUpdated, delta != .zero {
                let mismatch = hypot((to.x - observation.from.x) - delta.dx, (to.y - observation.from.y) - delta.dy)
                text += String(format: "；鼠标位移 (%.0f,%.0f)，两者相差 %.1f 点", delta.dx, delta.dy, mismatch)
            }
            if let delay = observation.delay {
                text += String(format: "；%@ %.0f 毫秒看到新位置", observation.kind == .dropUpdated && !rehearse ? "松手后" : "（演练：位置是经访达设置的）设置后", delay * 1000)
            }
            if let blocked = observation.blockedFor {
                text += String(format: "（这一问是拖动途中发出的，被访达卡了 %.1f 秒，到松手才回答）", blocked)
            }
            return text
        }
    }

    private func summarize(direct: [DragObservation], viaBridge: [DragObservation]) {
        say("——— 汇总 ———")
        let directDrops = direct.filter(\.countsAsDrop)
        if directDrops.isEmpty, viaBridge.isEmpty {
            say(interrupted ? "被中断，没有记录到拖动。" : "没有检测到拖动（超时）。请重新运行并拖动那个临时图标。")
            return
        }
        func range(_ observations: [DragObservation]) -> String {
            let delays = observations.filter { $0.kind != .dropNotUpdated }.compactMap(\.delay).map { $0 * 1000 }
            guard let low = delays.min(), let high = delays.max() else { return "没有数据" }
            return String(format: "%.0f–%.0f 毫秒（%d 次）", low, high, delays.count)
        }
        let notUpdated = (directDrops + viaBridge).filter { $0.kind == .dropNotUpdated }.count
        let whileDragging = direct.filter { $0.kind == .changedWhileDragging }.count
        var directLine = "访达自己：松手后 \(range(directDrops)) 答出新位置；拖动途中位置变化 \(whileDragging) 次"
        if longestBlocked > 0 {
            directLine += String(format: "；拖动期间发出的询问被卡住最长 %.1f 秒（访达拖动期间不回应请求）", longestBlocked)
        }
        say(directLine)
        say("图标桥：松手后 \(range(viaBridge)) 上报移动")
        if rehearse {
            say("演练结论：脚本流程正常（记账自检 → 新建 → 两个阶段各观察一次位置变化 → 汇总 → 清理）。真人拖动的结论要等真人来做。")
        } else if notUpdated > 0 {
            say("结论：\(directDrops.count + viaBridge.count) 次松手里有 \(notUpdated) 次在 3 秒内位置【没有更新】。请把以上输出交给总览。")
        } else {
            say("结论：\(directDrops.count + viaBridge.count) 次松手后，访达报告的位置都【更新了】。请把以上输出交给总览。")
        }
    }

    private func cleanUp() {
        if TestBench.cleanUp() {
            say("清理：临时图标已删除。")
        } else {
            say("清理：没能删除临时文件。请手动删除名叫「\(fileName)」的文件（如果把它拖进了某个文件夹，它就在那个文件夹里）。")
        }
    }
}
