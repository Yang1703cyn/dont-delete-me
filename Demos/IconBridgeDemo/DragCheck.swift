// IconBridgeDemo · 真人拖动检查：手动拖动图标后，访达报告的位置是否更新、延迟多久
//
// 运行：swift run IconBridgeDemo --drag-check
// 一条命令完成"新建临时图标 → 等你拖动 → 报告结果 → 清理"。不模拟鼠标：必须由真人来拖。
// 加 --rehearse 则不等人，改为经访达直接改位置，只用来确认脚本本身的流程能跑通。
//
// 分两个阶段，各拖两次：
//   阶段一（访达自己）：图标桥不工作，本程序每 15 毫秒左右直接问访达一次那个临时图标的位置，
//          量出"松开鼠标后多久 desktop position 变成新位置"，以及按住拖动期间位置是否已经在变。
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

    /// 一次拖动的观察结果。
    private struct Observation {
        var from: CGPoint
        var to: CGPoint?
        /// 鼠标从按下到松开的位移；演练模式没有。
        var mouseDelta: CGVector?
        /// 松手（演练：经访达改位置）到"看到新位置"的时间，秒。nil = 等了 3 秒也没变。
        var delay: TimeInterval?
        /// 松手之前（还按着鼠标拖动的途中）位置就已经变了。
        var changedWhileDragging = false
    }

    init(rehearse: Bool) {
        self.rehearse = rehearse
        dragsPerPhase = rehearse ? 1 : 2
    }

    func run() -> Int32 {
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

        say("阶段一：访达自己多久更新位置（请拖 \(dragsPerPhase) 次）")
        let direct = observeDirectly(rehearsalTargets: [spots[1]])
        var viaBridge: [Observation] = []
        if !interrupted, TestBench.existsOnDesktop(fileName) {
            say("阶段二：图标桥多久上报移动（请再拖 \(dragsPerPhase) 次）")
            viaBridge = observeThroughBridge(rehearsalTargets: [spots[2]])
        }
        summarize(direct: direct, viaBridge: viaBridge)
        return 0
    }

    // MARK: 鼠标（只读状态，不需要任何权限）

    private struct MouseTracker {
        var isDown = false
        var pressedOnIcon = false
        var pressPoint = CGPoint.zero

        /// 读一次鼠标。返回值不为 nil 表示：刚刚在图标上按下并拖动后松开了，值是鼠标的位移。
        mutating func poll(iconPosition: CGPoint, iconSize: CGFloat) -> CGVector? {
            let down = CGEventSource.buttonState(.combinedSessionState, button: .left)
            let mouse = CGEvent(source: nil)?.location ?? .zero
            defer { isDown = down }
            if down, !isDown {
                pressPoint = mouse
                // 图标图像连同下方的标签，四周放宽一点。
                let image = CGRect(x: iconPosition.x - iconSize / 2, y: iconPosition.y - iconSize / 2, width: iconSize, height: iconSize)
                let label = CGRect(x: iconPosition.x - 80, y: image.maxY, width: 160, height: 44)
                pressedOnIcon = image.insetBy(dx: -12, dy: -12).contains(mouse) || label.contains(mouse)
            } else if !down, isDown, pressedOnIcon {
                let delta = CGVector(dx: mouse.x - pressPoint.x, dy: mouse.y - pressPoint.y)
                if hypot(delta.dx, delta.dy) > 4 { return delta }
            }
            return nil
        }
    }

    // MARK: 阶段一：直接问访达

    private func observeDirectly(rehearsalTargets: [CGPoint]) -> [Observation] {
        var observations: [Observation] = []
        var mouse = MouseTracker()
        guard var position = TestBench.position(of: fileName) else { return [] }
        var pending: (releasedAt: TimeInterval, delta: CGVector?, from: CGPoint)?
        var lastActivity = now()
        var rehearsed = 0

        while observations.count < dragsPerPhase, !interrupted, now() - lastActivity < idleTimeout {
            pump(0.003)
            if rehearse, pending == nil, rehearsed < rehearsalTargets.count {
                pump(0.8)
                try? TestBench.setPosition(of: fileName, to: rehearsalTargets[rehearsed])
                pending = (now(), nil, position)
                rehearsed += 1
            }
            if let delta = mouse.poll(iconPosition: position, iconSize: iconSize), pending == nil {
                pending = (now(), delta, position)
                lastActivity = now()
            }

            guard let current = TestBench.position(of: fileName) else {
                if !TestBench.existsOnDesktop(fileName) {
                    say("临时图标不在桌面上了（被拖进了废纸篓或文件夹？）。提前结束。")
                    break
                }
                continue
            }
            if current != position {
                let seenAt = now()
                var observation = Observation(from: position, to: current)
                if let release = pending {
                    observation.mouseDelta = release.delta
                    observation.delay = seenAt - release.releasedAt
                    pending = nil
                } else {
                    // 没有"松手"记录而位置变了：只可能是还按着鼠标、拖动途中。
                    observation.changedWhileDragging = mouse.isDown
                }
                position = current
                lastActivity = seenAt
                if observation.changedWhileDragging {
                    say("  （拖动途中访达报告的位置就变了：\(format(observation.from)) → \(format(current))）")
                    observations.append(observation)
                } else {
                    observations.append(observation)
                    say("  第 \(observations.filter { !$0.changedWhileDragging }.count) 次：\(describe(observation))")
                }
            } else if let release = pending, now() - release.releasedAt > 3 {
                pending = nil
                let observation = Observation(from: release.from, to: nil, mouseDelta: release.delta, delay: nil)
                observations.append(observation)
                say("  第 \(observations.count) 次：\(describe(observation))")
            }
        }
        return observations
    }

    // MARK: 阶段二：经图标桥

    private func observeThroughBridge(rehearsalTargets: [CGPoint]) -> [Observation] {
        let session = DemoSession(printsUpdates: false)
        session.start()
        defer { session.stop() }
        guard session.waitForFirstUpdate(timeout: 20), let start = TestBench.position(of: fileName),
              let icon = session.provider.snapshot.icons.first(where: { $0.imageRect.center == start })
        else {
            say("图标桥没有读到临时图标。跳过阶段二。")
            return []
        }

        var observations: [Observation] = []
        var mouse = MouseTracker()
        var position = start
        var pending: (releasedAt: TimeInterval, delta: CGVector?, from: CGPoint, changeIndex: Int)?
        var lastActivity = now()
        var rehearsed = 0

        while observations.count < dragsPerPhase, !interrupted, now() - lastActivity < idleTimeout {
            pump(0.003)
            if rehearse, pending == nil, rehearsed < rehearsalTargets.count {
                pump(0.8)
                try? TestBench.setPosition(of: fileName, to: rehearsalTargets[rehearsed])
                pending = (now(), nil, position, session.changes.count)
                rehearsed += 1
            }
            if let delta = mouse.poll(iconPosition: position, iconSize: iconSize), pending == nil {
                pending = (now(), delta, position, session.changes.count)
                lastActivity = now()
            }
            if session.provider.snapshot.icon(withID: icon.id) == nil, session.provider.status == .ok, pending == nil {
                say("临时图标不在桌面上了（被拖进了废纸篓或文件夹？）。提前结束。")
                break
            }

            guard let release = pending else {
                // 没在等结果：跟上图标桥报告的最新位置（例如拖动途中的变化）。
                position = session.provider.snapshot.icon(withID: icon.id)?.imageRect.center ?? position
                continue
            }
            // 应用在松手后就是这么做的：每帧请求立即刷新，直到看到结局。
            session.provider.refreshNow()
            let moved = session.changes.dropFirst(release.changeIndex).first { entry in
                if case let .moved(_, to) = entry.change { return to.id == icon.id }
                return false
            }
            if let moved, case let .moved(_, to) = moved.change {
                let observation = Observation(from: release.from, to: to.imageRect.center, mouseDelta: release.delta, delay: moved.time - release.releasedAt)
                position = to.imageRect.center
                pending = nil
                lastActivity = now()
                observations.append(observation)
                say("  第 \(observations.count) 次：\(describe(observation))")
            } else if now() - release.releasedAt > 3 {
                pending = nil
                let observation = Observation(from: release.from, to: nil, mouseDelta: release.delta, delay: nil)
                observations.append(observation)
                say("  第 \(observations.count) 次：\(describe(observation))")
            }
        }
        say("  （阶段二的读取开销：\(session.cycleSummary())）")
        return observations
    }

    // MARK: 输出

    private func describe(_ observation: Observation) -> String {
        guard let to = observation.to, let delay = observation.delay else {
            let moved = observation.mouseDelta.map { String(format: "鼠标拖了 (%.0f,%.0f) 后松手，", $0.dx, $0.dy) } ?? ""
            return "\(moved)等了 3 秒，位置仍然是 \(format(observation.from))，【没有更新】"
        }
        var text = String(format: "位置 %@ → %@（位移 %.0f,%.0f）", format(observation.from), format(to), to.x - observation.from.x, to.y - observation.from.y)
        if let delta = observation.mouseDelta {
            let mismatch = hypot((to.x - observation.from.x) - delta.dx, (to.y - observation.from.y) - delta.dy)
            text += String(format: "；鼠标位移 (%.0f,%.0f)，两者相差 %.1f 点；松手后 %.0f 毫秒看到新位置", delta.dx, delta.dy, mismatch, delay * 1000)
        } else {
            text += String(format: "；（演练：位置是经访达设置的）设置后 %.0f 毫秒看到新位置", delay * 1000)
        }
        return text
    }

    private func summarize(direct: [Observation], viaBridge: [Observation]) {
        say("——— 汇总 ———")
        let directDrops = direct.filter { !$0.changedWhileDragging }
        if directDrops.isEmpty, viaBridge.isEmpty {
            say(interrupted ? "被中断，没有记录到拖动。" : "没有检测到拖动（超时）。请重新运行并拖动那个临时图标。")
            return
        }
        func range(_ observations: [Observation]) -> String {
            let delays = observations.compactMap(\.delay).map { $0 * 1000 }
            guard let low = delays.min(), let high = delays.max() else { return "没有数据" }
            return String(format: "%.0f–%.0f 毫秒（%d 次）", low, high, delays.count)
        }
        let notUpdated = (directDrops + viaBridge).filter { $0.to == nil }.count
        let whileDragging = direct.filter(\.changedWhileDragging).count
        say("访达自己：松手后 \(range(directDrops)) 位置更新；拖动途中位置变化 \(whileDragging) 次")
        say("图标桥：松手后 \(range(viaBridge)) 上报移动")
        if rehearse {
            say("演练结论：脚本流程正常（新建 → 两个阶段各观察一次位置变化 → 汇总 → 清理）。真人拖动的结论要等真人来做。")
        } else if notUpdated > 0 {
            say("结论：有 \(notUpdated) 次松手后 3 秒内位置【没有更新】。这是全项目的阻塞问题，请把以上输出交给总览。")
        } else {
            say("结论：手动拖动后访达报告的位置【会更新】。请把以上输出交给总览。")
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
