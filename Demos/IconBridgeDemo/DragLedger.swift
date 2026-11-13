// IconBridgeDemo · 拖动检查的记账：鼠标记录器 + "这次位置变化算在哪次松手头上"
//
// 实测：访达一旦把图标拖起来，就不再回应 Apple 事件，一直卡到松手那一刻才回答（回答的已经是新位置）。
// 所以检查脚本在主线程上问访达时，自己也会被卡住——上一版因此把"松手那一刻答回来的新位置"误记成"拖动途中位置变了"，
// 又在下一轮空等 3 秒报"没有更新"。现在：
//   - 鼠标的按下 / 松开由后台线程记录（带精确时刻），主线程被访达卡住也不会漏记、不会记晚；
//   - 位置变化先和松手记录对账，再下结论（`DragLedger`，纯逻辑，自带几个情形的自检）。

import AppKit
import Foundation

/// 后台线程每 2 毫秒看一眼鼠标左键，记下每一次按下 / 松开的时刻和位置。只读状态，不需要任何权限，也不产生任何输入事件。
final class MouseRecorder: @unchecked Sendable {
    struct Event: Sendable {
        var time: TimeInterval
        var isDown: Bool
        var location: CGPoint
    }

    private let lock = NSLock()
    private var events: [Event] = []
    private var running = false
    private var down = false

    func start() {
        lock.withLock { running = true }
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let isDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
                if isDown != lock.withLock({ down }) {
                    let event = Event(
                        time: ProcessInfo.processInfo.systemUptime,
                        isDown: isDown,
                        location: CGEvent(source: nil)?.location ?? .zero
                    )
                    lock.withLock {
                        down = isDown
                        events.append(event)
                    }
                }
                usleep(2000)
            }
        }
    }

    func stop() {
        lock.withLock { running = false }
    }

    /// 取走到目前为止记下的全部事件（按时间先后）。
    func drain() -> [Event] {
        lock.withLock {
            let result = events
            events = []
            return result
        }
    }

    /// 此刻左键是否按着。
    var isDown: Bool { lock.withLock { down } }
}

/// 一次观察到的结果。
struct DragObservation: Equatable {
    enum Kind: Equatable {
        /// 松手之后位置更新了。
        case dropUpdated
        /// 松手 3 秒之后位置仍然没变。
        case dropNotUpdated
        /// 鼠标还按着（拖动途中）位置就变了。
        case changedWhileDragging
        /// 位置变了，但没有对应的鼠标操作（演练时经访达直接改位置）。
        case changedWithoutMouse
    }

    var kind: Kind
    var from: CGPoint
    var to: CGPoint?
    /// 鼠标从按下到松开的位移。
    var mouseDelta: CGVector?
    /// 从松手到看到新位置的时间（秒）。
    var delay: TimeInterval?
    /// 给出新位置的那一问，如果是松手之前发出的：它被访达卡了多久（秒）。
    var blockedFor: TimeInterval?

    /// 是否算"一次拖动的结果"（用来数够次数）。
    var countsAsDrop: Bool {
        kind == .dropUpdated || kind == .dropNotUpdated || kind == .changedWithoutMouse
    }
}

/// 把鼠标事件和"访达答复的位置"对账，得出每一次拖动的结果。纯逻辑。
struct DragLedger {
    /// 松手之后等多久还没变，就判定"没有更新"。
    static let notUpdatedAfter: TimeInterval = 3
    /// 位置变了而鼠标看上去还按着时，再等这么久看有没有紧跟着的松手记录（两个线程之间有几毫秒的先后误差）。
    static let attributionSlack: TimeInterval = 0.25

    private(set) var position: CGPoint
    let iconSize: CGFloat

    private var press: (location: CGPoint, onIcon: Bool)?
    /// 在图标上按下、拖动后松开了，还没看到结果。
    private var pendingDrop: (releasedAt: TimeInterval, delta: CGVector, from: CGPoint)?
    /// 位置变了，暂时还不知道算在谁头上。
    private var unattributed: (from: CGPoint, to: CGPoint, sentAt: TimeInterval, answeredAt: TimeInterval)?

    init(position: CGPoint, iconSize: CGFloat) {
        self.position = position
        self.iconSize = iconSize
    }

    /// 有没有一次松手在等结果。
    var isAwaitingResult: Bool { pendingDrop != nil || unattributed != nil }

    /// 记一个鼠标事件。可能当场得出一个结果（位置先变、松手记录后到的情形）。
    mutating func note(mouse event: MouseRecorder.Event) -> DragObservation? {
        if event.isDown {
            // 图标图像连同下方的标签，四周放宽一点。
            let image = CGRect(x: position.x - iconSize / 2, y: position.y - iconSize / 2, width: iconSize, height: iconSize)
            let label = CGRect(x: position.x - 80, y: image.maxY, width: 160, height: 44)
            // 位置刚变、还没对上账时，按下的地方要按变化之前的位置来认。
            let before = unattributed.map { CGRect(x: $0.from.x - iconSize / 2, y: $0.from.y - iconSize / 2, width: iconSize, height: iconSize + 44) }
            let onIcon = image.insetBy(dx: -12, dy: -12).contains(event.location) || label.contains(event.location)
                || (before?.insetBy(dx: -48, dy: -12).contains(event.location) ?? false)
            press = (event.location, onIcon)
            return nil
        }
        guard let press else { return nil }
        self.press = nil
        let delta = CGVector(dx: event.location.x - press.location.x, dy: event.location.y - press.location.y)
        let wasDrag = press.onIcon && hypot(delta.dx, delta.dy) > 4

        if let change = unattributed {
            // 按着鼠标的这段时间里位置变过，还没对上账——现在松手了，就在这里了结，不留到以后。
            unattributed = nil
            if wasDrag, abs(event.time - change.answeredAt) <= Self.attributionSlack {
                // 位置的答复比松手记录早到了一点点：它就是这次松手的结果。
                return DragObservation(
                    kind: .dropUpdated, from: change.from, to: change.to, mouseDelta: delta,
                    delay: max(0, change.answeredAt - event.time),
                    blockedFor: change.sentAt < event.time ? change.answeredAt - change.sentAt : nil
                )
            }
            // 对不上这次松手：要么是拖动途中位置早就变了，要么这一下根本不是在拖这个图标。
            // 无论哪种，这次松手都不再另记一笔"等结果"（位置已经变过了）。
            return DragObservation(kind: wasDrag ? .changedWhileDragging : .changedWithoutMouse, from: change.from, to: change.to)
        }
        guard wasDrag else { return nil }
        pendingDrop = (event.time, delta, position)
        return nil
    }

    /// 访达答复了一次位置查询。`sentAt` / `answeredAt` 是发问和答复的时刻。
    mutating func note(position newPosition: CGPoint, sentAt: TimeInterval, answeredAt: TimeInterval) -> DragObservation? {
        guard newPosition != position else { return nil }
        let from = position
        position = newPosition
        if press != nil {
            // 鼠标此刻按着：多半是这次拖动的结果，只是松手记录比答复晚到了几毫秒。先不下结论，等松手记录或等一小会儿。
            // （即使前一次松手还在等结果也一样——不能把这次变化抢先算到前一次头上。）
            unattributed = (from, newPosition, sentAt, answeredAt)
            return nil
        }
        if let drop = pendingDrop {
            // 这次松手的结果。发问如果早于松手，说明这一问是在拖动途中发出、被访达卡到松手才回答的。
            pendingDrop = nil
            return DragObservation(
                kind: .dropUpdated, from: drop.from, to: newPosition, mouseDelta: drop.delta,
                delay: max(0, answeredAt - drop.releasedAt),
                blockedFor: sentAt < drop.releasedAt ? answeredAt - sentAt : nil
            )
        }
        return DragObservation(kind: .changedWithoutMouse, from: from, to: newPosition, delay: answeredAt - sentAt)
    }

    /// 时间流逝：到点还没对上的账在这里了结。
    mutating func tick(now: TimeInterval) -> DragObservation? {
        if let change = unattributed, now - change.answeredAt > Self.attributionSlack {
            unattributed = nil
            if let drop = pendingDrop {
                // 等过了，没有紧跟着的松手：这次变化是前一次松手迟到的结果（用户随后又按下了鼠标）。
                pendingDrop = nil
                return DragObservation(
                    kind: .dropUpdated, from: drop.from, to: change.to, mouseDelta: drop.delta,
                    delay: max(0, change.answeredAt - drop.releasedAt),
                    blockedFor: change.sentAt < drop.releasedAt ? change.answeredAt - change.sentAt : nil
                )
            }
            // 鼠标确实一直按着：拖动途中位置就变了。
            return DragObservation(kind: .changedWhileDragging, from: change.from, to: change.to)
        }
        if let drop = pendingDrop, now - drop.releasedAt > Self.notUpdatedAfter {
            pendingDrop = nil
            return DragObservation(kind: .dropNotUpdated, from: drop.from, to: nil, mouseDelta: drop.delta)
        }
        return nil
    }

    /// 取走"刚松手、还没看到结果"的那一次的松手时刻（阶段二用它来计时）。
    var pendingReleaseTime: TimeInterval? { pendingDrop?.releasedAt }

    /// 阶段二：图标桥上报了移动。和等着的那次松手对账。
    mutating func noteReported(position newPosition: CGPoint, at time: TimeInterval) -> DragObservation? {
        guard let drop = pendingDrop else {
            let from = position
            position = newPosition
            return DragObservation(kind: .changedWithoutMouse, from: from, to: newPosition)
        }
        pendingDrop = nil
        position = newPosition
        return DragObservation(kind: .dropUpdated, from: drop.from, to: newPosition, mouseDelta: drop.delta, delay: max(0, time - drop.releasedAt))
    }

    /// 阶段二（演练）：没有鼠标，由脚本自己记一次"松手"。
    mutating func noteRehearsedRelease(at time: TimeInterval) {
        pendingDrop = (time, .zero, position)
    }
}

// MARK: - 自检：几个情形各应得出什么结果

extension DragLedger {
    /// 自检里一共有几个情形。
    static let selfCheckScenarioCount = 10

    /// 用编出来的时间线检查记账逻辑，包括真人检查时出过误报的那个情形。返回不符合预期的情形的说明（空 = 全部符合）。
    static func selfCheck() -> [String] {
        var failures: [String] = []
        let start = CGPoint(x: 160, y: 220)
        let end = CGPoint(x: 506, y: 225)
        func down(_ time: TimeInterval, at point: CGPoint = CGPoint(x: 165, y: 222)) -> MouseRecorder.Event {
            MouseRecorder.Event(time: time, isDown: true, location: point)
        }
        func up(_ time: TimeInterval, at point: CGPoint = CGPoint(x: 515, y: 228)) -> MouseRecorder.Event {
            MouseRecorder.Event(time: time, isDown: false, location: point)
        }
        func expect(_ name: String, _ got: [DragObservation.Kind], _ wanted: [DragObservation.Kind]) {
            if got != wanted { failures.append("\(name)：得到 \(got)，应为 \(wanted)") }
        }

        // 情形一（真人检查时误报的那个）：拖动途中发出的一问被访达卡住，松手那一刻答回新位置。
        do {
            var ledger = DragLedger(position: start, iconSize: 64)
            var seen: [DragObservation] = []
            seen += [ledger.note(mouse: down(10.0))].compactMap { $0 }
            // 10.5 发问，被卡住；15.0 松手；15.02 答复（主线程这时才回来，一并处理积压的鼠标事件）。
            seen += [ledger.note(mouse: up(15.0))].compactMap { $0 }
            seen += [ledger.note(position: end, sentAt: 10.5, answeredAt: 15.02)].compactMap { $0 }
            seen += [ledger.tick(now: 15.3), ledger.tick(now: 19.0)].compactMap { $0 }
            expect("拖动途中的一问被卡到松手才答", seen.map(\.kind), [.dropUpdated])
            if let first = seen.first {
                if abs((first.delay ?? -1) - 0.02) > 1e-6 { failures.append("情形一：延迟应为 20 毫秒") }
                if abs((first.blockedFor ?? -1) - 4.52) > 1e-6 { failures.append("情形一：应记下这一问被卡了 4.52 秒") }
            }
        }
        // 情形二：答复比松手记录早到了 1 毫秒（两个线程的先后误差）。
        do {
            var ledger = DragLedger(position: start, iconSize: 64)
            var seen: [DragObservation] = []
            seen += [ledger.note(mouse: down(10.0))].compactMap { $0 }
            seen += [ledger.note(position: end, sentAt: 10.5, answeredAt: 15.000)].compactMap { $0 }
            seen += [ledger.note(mouse: up(15.001))].compactMap { $0 }
            seen += [ledger.tick(now: 15.4), ledger.tick(now: 19.0)].compactMap { $0 }
            expect("答复略早于松手记录", seen.map(\.kind), [.dropUpdated])
        }
        // 情形三：平常的情形——松手之后才发问，30 毫秒后答出新位置。
        do {
            var ledger = DragLedger(position: start, iconSize: 64)
            var seen: [DragObservation] = []
            seen += [ledger.note(mouse: down(20.0)), ledger.note(mouse: up(20.5))].compactMap { $0 }
            seen += [ledger.note(position: end, sentAt: 20.51, answeredAt: 20.53)].compactMap { $0 }
            seen += [ledger.tick(now: 24.0)].compactMap { $0 }
            expect("松手后发问", seen.map(\.kind), [.dropUpdated])
            if let first = seen.first, first.blockedFor != nil { failures.append("情形三：这一问没有被卡住") }
        }
        // 情形四：松手之后位置一直没变。
        do {
            var ledger = DragLedger(position: start, iconSize: 64)
            var seen: [DragObservation] = []
            seen += [ledger.note(mouse: down(30.0)), ledger.note(mouse: up(30.5))].compactMap { $0 }
            seen += [ledger.note(position: start, sentAt: 30.6, answeredAt: 30.62)].compactMap { $0 }
            seen += [ledger.tick(now: 32.0), ledger.tick(now: 33.6), ledger.tick(now: 40.0)].compactMap { $0 }
            expect("松手后没有更新", seen.map(\.kind), [.dropNotUpdated])
        }
        // 情形五：鼠标一直按着，位置却变了（真正的"拖动途中就变了"）。
        do {
            var ledger = DragLedger(position: start, iconSize: 64)
            var seen: [DragObservation] = []
            seen += [ledger.note(mouse: down(40.0))].compactMap { $0 }
            seen += [ledger.note(position: end, sentAt: 41.0, answeredAt: 41.02)].compactMap { $0 }
            seen += [ledger.tick(now: 41.1), ledger.tick(now: 41.4)].compactMap { $0 }
            expect("拖动途中位置变了", seen.map(\.kind), [.changedWhileDragging])
        }
        // 情形六：在别处点了一下（没按在图标上），之后位置由别的原因变了。
        do {
            var ledger = DragLedger(position: start, iconSize: 64)
            var seen: [DragObservation] = []
            seen += [ledger.note(mouse: down(50.0, at: CGPoint(x: 900, y: 700))), ledger.note(mouse: up(50.2, at: CGPoint(x: 950, y: 700)))].compactMap { $0 }
            seen += [ledger.note(position: end, sentAt: 51.0, answeredAt: 51.02)].compactMap { $0 }
            seen += [ledger.tick(now: 60.0)].compactMap { $0 }
            expect("没有对应的鼠标操作", seen.map(\.kind), [.changedWithoutMouse])
        }
        // 情形八：前一次松手什么都没变（还在等结果），用户又拖了一次；这次的答复比松手记录早到 1 毫秒。
        // 变化应当算在这一次头上，前一次到点后记"没有更新"。
        do {
            var ledger = DragLedger(position: start, iconSize: 64)
            var seen: [DragObservation] = []
            seen += [ledger.note(mouse: down(70.0)), ledger.note(mouse: up(70.5, at: CGPoint(x: 175, y: 226)))].compactMap { $0 }
            seen += [ledger.note(mouse: down(71.0))].compactMap { $0 }
            seen += [ledger.note(position: end, sentAt: 71.2, answeredAt: 72.000)].compactMap { $0 }
            seen += [ledger.note(mouse: up(72.001))].compactMap { $0 }
            seen += [ledger.tick(now: 72.4), ledger.tick(now: 74.0), ledger.tick(now: 80.0)].compactMap { $0 }
            expect("前一次还在等结果时又拖了一次", seen.map(\.kind), [.dropUpdated, .dropNotUpdated])
        }
        // 情形九：按着鼠标时位置变了，随后松手但几乎没动（不算拖动）——当场了结，不再迟报"拖动途中就变了"。
        do {
            var ledger = DragLedger(position: start, iconSize: 64)
            var seen: [DragObservation] = []
            seen += [ledger.note(mouse: down(80.0))].compactMap { $0 }
            seen += [ledger.note(position: end, sentAt: 80.4, answeredAt: 80.5)].compactMap { $0 }
            seen += [ledger.note(mouse: up(80.6, at: CGPoint(x: 166, y: 222)))].compactMap { $0 }
            seen += [ledger.tick(now: 81.0), ledger.tick(now: 90.0)].compactMap { $0 }
            expect("松手时几乎没动", seen.map(\.kind), [.changedWithoutMouse])
        }
        // 情形十：拖动途中位置早就变了，过了 1 秒才松手——只记"拖动途中就变了"，松手后不再空等 3 秒报"没有更新"。
        do {
            var ledger = DragLedger(position: start, iconSize: 64)
            var seen: [DragObservation] = []
            seen += [ledger.note(mouse: down(90.0))].compactMap { $0 }
            seen += [ledger.note(position: end, sentAt: 90.9, answeredAt: 91.0)].compactMap { $0 }
            seen += [ledger.note(mouse: up(92.0))].compactMap { $0 }
            seen += [ledger.tick(now: 92.5), ledger.tick(now: 96.0)].compactMap { $0 }
            expect("拖动途中早就变了", seen.map(\.kind), [.changedWhileDragging])
        }
        // 情形七：连着拖两次，各算各的。
        do {
            var ledger = DragLedger(position: start, iconSize: 64)
            var seen: [DragObservation] = []
            seen += [ledger.note(mouse: down(60.0)), ledger.note(mouse: up(61.0))].compactMap { $0 }
            seen += [ledger.note(position: end, sentAt: 60.2, answeredAt: 61.02)].compactMap { $0 }
            let second = CGPoint(x: 700, y: 400)
            seen += [ledger.note(mouse: down(63.0, at: CGPoint(x: 510, y: 230))), ledger.note(mouse: up(64.0, at: CGPoint(x: 705, y: 404)))].compactMap { $0 }
            seen += [ledger.note(position: second, sentAt: 64.01, answeredAt: 64.04)].compactMap { $0 }
            seen += [ledger.tick(now: 70.0)].compactMap { $0 }
            expect("连着拖两次", seen.map(\.kind), [.dropUpdated, .dropUpdated])
        }
        return failures
    }
}
