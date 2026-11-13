// InputSenseDemo · 公用的小工具：格式化、假桌面、把事实的变化打印出来
//
// 演示程序只依赖 DDMCore 和 InputSense。图标是假的（不读真实桌面）；
// "图标桥"也是假的：`FakeDesktop` 按接口约定回应"请重读图标"，让结局判定有东西可判。

import AppKit
import CoreGraphics
import DDMCore
import Foundation
import InputSense

func text(_ point: CGPoint) -> String { String(format: "(%.0f, %.0f)", point.x, point.y) }
func text(_ vector: CGVector) -> String { String(format: "(%.0f, %.0f)", vector.dx, vector.dy) }
func text(_ rect: CGRect) -> String { String(format: "(%.0f, %.0f %.0f×%.0f)", rect.minX, rect.minY, rect.width, rect.height) }
func text(_ value: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", value) }

func say(_ line: String) {
    print(line)
    fflush(stdout)
}

/// 让主线程"转一会儿"：等到某个时刻，其间照常处理主线程上的任务。
@MainActor
func spin(until deadline: TimeInterval) {
    while true {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        if remaining <= 0 { return }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(min(remaining, 0.05)))
    }
}

func surfaceName(_ surface: PointerSurface?) -> String {
    switch surface {
    case .desktopIcons: return "桌面图标层"
    case .shieldedDesktop: return "桌面图标层（图标被系统遮住）"
    case .dock: return "程序坞"
    case .otherWindow: return "别的窗口"
    case .unknown: return "查不出来"
    case nil: return "还没查"
    }
}

func outcomeName(_ kind: DragOutcomeKind) -> String {
    switch kind {
    case .moved: return "挪了位置"
    case .trashed: return "进了废纸篓"
    case .leftDesktop: return "离开桌面去了别处"
    case .cancelled: return "取消（弹回原位）"
    case .unknown: return "超时未知"
    }
}

/// 假桌面：几个假图标，外加一个假的"图标桥"。
///
/// 它像真的图标桥那样工作：平时每秒读一次"真相"；被要求立即刷新时马上读一次（读一次要 0.08 秒），
/// 读完给出一份新快照和变化事件——即使什么都没变也给（快照的读取时刻会更新）。
@MainActor
final class FakeDesktop {
    /// 桌面上真正的情况（"访达那边"）。
    private(set) var truth: [DesktopIcon]
    /// 图标桥最近一次读到的快照。
    private(set) var snapshot: IconSnapshot
    private let originals: [DesktopIcon]

    private var trashVerdicts: [IconID: TrashVerdict] = [:]
    private var readStartedAt: TimeInterval?
    private var refreshQueued = false
    private var lastReadAt: TimeInterval
    private var pending: IconUpdate?
    /// 被删的假图标什么时候重新放回来（只在实时模式里用）。
    private var respawnAt: [IconID: TimeInterval] = [:]
    var respawnDelay: TimeInterval?

    private let readDuration: TimeInterval = 0.08
    private let pollInterval: TimeInterval = 1

    init(icons: [DesktopIcon], now: TimeInterval) {
        truth = icons
        originals = icons
        snapshot = IconSnapshot(icons: icons, status: .ok, capturedAt: now, revision: 1)
        lastReadAt = now
    }

    /// 用户松手了：访达这边立刻照办（挪位置 / 进废纸篓 / 什么都不做）。
    func drop(_ released: ReleasedDrag, onto surface: PointerSurface, trashRect: CGRect?, now: TimeInterval) {
        guard let index = truth.firstIndex(where: { $0.id == released.iconID }) else { return }
        if let trashRect, trashRect.contains(released.releasePoint) {
            trashVerdicts[released.iconID] = .yes
            truth.remove(at: index)
            if let respawnDelay { respawnAt[released.iconID] = now + respawnDelay }
        } else if surface.isDesktop {
            let old = truth[index]
            let delta = released.imageRectAtRelease.origin.offset(from: old.imageRect.origin)
            truth[index].imageRect = released.imageRectAtRelease
            truth[index].labelRect = old.labelRect?.offsetBy(dx: delta.dx, dy: delta.dy)
        }
        // 松在别的窗口上：这个假桌面里当作"目标不接受"，图标弹回原位。
    }

    /// 没有拖拽过程的删除（快捷键、右键菜单）。
    func deleteByKeyboard(_ id: IconID) {
        guard let index = truth.firstIndex(where: { $0.id == id }) else { return }
        trashVerdicts[id] = .yes
        truth.remove(at: index)
    }

    /// 应用转达"请立即重读图标"。
    func refreshNow() {
        refreshQueued = true
    }

    /// 每帧调一次：推进假图标桥，取出这一帧该交给交互感知的图标输入。
    func update(now: TimeInterval) -> IconUpdate {
        for (id, time) in respawnAt where now >= time {
            respawnAt[id] = nil
            if let original = originals.first(where: { $0.id == id }), !truth.contains(where: { $0.id == id }) {
                truth.append(original)
            }
        }
        if let started = readStartedAt, now - started >= readDuration {
            finishRead(startedAt: started)
            readStartedAt = nil
        }
        if readStartedAt == nil, refreshQueued || now - lastReadAt >= pollInterval {
            readStartedAt = now
            lastReadAt = now
        }
        defer { pending = nil }
        return pending ?? .unchanged(snapshot)
    }

    private func finishRead(startedAt: TimeInterval) {
        let forced = refreshQueued
        refreshQueued = false
        var changes: [IconChange] = []
        for old in snapshot.icons {
            if let new = truth.first(where: { $0.id == old.id }) {
                if new.imageRect != old.imageRect { changes.append(.moved(from: old, to: new)) }
            } else {
                changes.append(.removed(old, trashed: trashVerdicts[old.id] ?? .unknown))
            }
        }
        for new in truth where !snapshot.icons.contains(where: { $0.id == new.id }) {
            changes.append(.added(new))
        }
        guard forced || !changes.isEmpty else { return }   // 例行读取没变化：不上报
        snapshot = IconSnapshot(
            icons: truth, status: .ok, capturedAt: startedAt,
            revision: snapshot.revision + (changes.isEmpty ? 0 : 1)
        )
        let update = IconUpdate(snapshot: snapshot, changes: changes)
        pending = pending?.merging(update) ?? update
    }
}

/// 把事实的"变化"打印出来：开始悬停、开始拖、甩动强度过档、朝废纸篓去、松手、结局……
@MainActor
final class Narrator {
    private let origin: TimeInterval
    private var previous: InteractionFacts?
    private var shakeBand = 0
    private var names: [IconID: String] = [:]
    private(set) var outcomeCount = 0
    private(set) var deletionCount = 0

    init(origin: TimeInterval, icons: [DesktopIcon]) {
        self.origin = origin
        for (index, icon) in icons.enumerated() { names[icon.id] = "假图标 \(index + 1)" }
    }

    func stamp(_ facts: InteractionFacts) -> String {
        String(format: "[%6.2fs]", facts.time.monotonic - origin)
    }

    func name(_ id: IconID) -> String { names[id] ?? "\(id)" }

    func note(_ facts: InteractionFacts, _ line: String) {
        say("\(stamp(facts)) \(line)")
    }

    /// 看一帧事实，有变化就打印。
    func observe(_ facts: InteractionFacts, surface: PointerSurface?) {
        defer { previous = facts }
        let before = previous

        if facts.isMouseOverDesktop != before?.isMouseOverDesktop, before != nil {
            note(facts, "鼠标处最上面是：\(surfaceName(surface))")
        }
        if facts.hover?.iconID != before?.hover?.iconID {
            if let hover = facts.hover {
                note(facts, "悬停在 \(name(hover.iconID)) 上")
            } else if let old = before?.hover {
                note(facts, "离开 \(name(old.iconID))（悬停了 \(text(old.duration, 1)) 秒）")
            }
        }
        if let drag = facts.drag, before?.drag == nil {
            shakeBand = 0
            note(facts, "▶ 开始拖 \(name(drag.iconID))：抓取偏移 \(text(drag.grabOffset))，原位置 \(text(drag.originImageRect))")
        }
        if let drag = facts.drag {
            let band = Int(drag.shake * 4)   // 0.25 一档
            if band != shakeBand {
                note(facts, "  甩动强度 \(band > shakeBand ? "升到" : "降到") \(text(drag.shake))（速度 \(text(Double(drag.velocity.length), 0)) 点/秒）")
                shakeBand = band
            }
        }
        if let trash = facts.trash, let old = before?.trash {
            if trash.isApproaching != old.isApproaching, facts.drag != nil {
                note(facts, trash.isApproaching
                    ? "  正朝废纸篓移动：还有 \(text(Double(trash.distance), 0)) 点，靠近速度 \(text(Double(trash.closingSpeed), 0)) 点/秒"
                    : "  不再朝废纸篓移动（距离 \(text(Double(trash.distance), 0)) 点）")
            }
            if trash.isOver != old.isOver {
                note(facts, trash.isOver ? "  到了废纸篓上方" : "  离开了废纸篓上方")
            }
            if trash.estimatedRect != old.estimatedRect || trash.confidence != old.confidence {
                note(facts, "  废纸篓估算更新：\(text(trash.estimatedRect))，可信度 \(text(trash.confidence))")
            }
        }
        for released in facts.releasedDrags where !(before?.releasedDrags.contains { $0.iconID == released.iconID } ?? false) {
            note(facts, "■ 松手于 \(text(released.releasePoint))，拖影在 \(text(released.imageRectAtRelease))；等结局\(facts.wantsIconRefresh ? "，已请求重读图标" : "")")
        }
        for outcome in facts.dragOutcomes {
            outcomeCount += 1
            let extra = outcome.newImageRect.map { "，新位置 \(text($0))" } ?? ""
            note(facts, "★ 结局：\(name(outcome.iconID)) \(outcomeName(outcome.kind))\(extra)")
        }
        for deletion in facts.deletions {
            deletionCount += 1
            note(facts, "✝ 删除：\(name(deletion.iconID)) 被删（\(deletion.wasDragged ? "经过拖拽" : "没有拖拽过程")），最后位置 \(text(deletion.lastImageRect))")
        }
    }

    /// 一行"现在的全貌"。
    func status(_ facts: InteractionFacts, surface: PointerSurface?) -> String {
        var parts: [String] = []
        parts.append("鼠标 \(text(facts.mouse.position)) 速度 \(text(Double(facts.mouse.speed), 0)) 静止 \(text(facts.mouse.idleDuration, 1)) 秒")
        parts.append("最上面：\(surfaceName(surface))")
        if let hover = facts.hover {
            parts.append("悬停 \(name(hover.iconID)) \(text(hover.duration, 1)) 秒")
        } else if let drag = facts.drag {
            parts.append("拖着 \(name(drag.iconID)) 甩动 \(text(drag.shake))")
        } else {
            parts.append("没有悬停、没有拖拽")
        }
        if let trash = facts.trash {
            parts.append("离废纸篓 \(text(Double(trash.distance), 0)) 点\(trash.isOver ? "（在上方）" : trash.isApproaching ? "（正朝它去）" : "")")
        } else {
            parts.append("废纸篓估算不出来")
        }
        return "\(stamp(facts)) " + parts.joined(separator: " | ")
    }
}

func demandName(_ demand: FrameDemand, now: TimeInterval) -> String {
    switch demand {
    case .continuous: return "连续出帧"
    case let .by(time): return "每 \(text((time - now) * 1000, 0)) 毫秒读一次"
    case .idle: return "休息"
    }
}
