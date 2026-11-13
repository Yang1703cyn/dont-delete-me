// EmotionDemo · 假桌面
//
// 几个编造的图标、一只假鼠标、一个假废纸篓，按剧本一帧一帧地喂情绪引擎。
// 时间是模拟的（每帧往后推 1/60 秒），所以再长的剧本也是瞬间跑完，而且每次输出完全相同。
// 不读真实桌面、不读鼠标、不开窗口。

import CoreGraphics
import DDMCore
import Emotion
import Foundation

let frameInterval: TimeInterval = 1.0 / 60

final class DemoStage {
    var director: EmotionDirector
    private(set) var icons: [DesktopIcon]
    private(set) var time: FrameTime
    /// 图标的称呼（甲、乙、丙……），只用于打印。被删的图标也留着名字（幽灵要用）。
    private(set) var names: [IconID: String] = [:]

    var mouse = CGPoint(x: 400, y: 300)
    var idle: TimeInterval = 0
    var hover: IconID?
    var drag: DragState?
    var released: [ReleasedDrag] = []
    var trashRect: CGRect? = CGRect(x: 1300, y: 900, width: 60, height: 70)
    var trashConfidence = 0.75

    private var outcomes: [DragOutcome] = []
    private var deletions: [DeletionEvent] = []
    private var changes: [IconChange] = []
    private var pendingReset = true
    private var revision: UInt64 = 1
    private var lastMouse: CGPoint?
    private var lastTrashDistance: CGFloat?
    private var steps = 0

    private(set) var output = EmotionOutput()
    /// 最近一帧送进引擎的事实（打印"看向哪里"时要用）。
    private(set) var facts: InteractionFacts
    /// 剧本开始的时刻；打印时间用相对值。
    let startedAt: TimeInterval
    /// 最近出现的新图标（打印"看向哪里"时要用）。
    private(set) var newcomer: IconID?

    static let today = Date(timeIntervalSince1970: 1_800_000_000)

    init(icons: [(name: String, icon: DesktopIcon)], seed: UInt64 = 42) {
        self.icons = icons.map(\.icon)
        for entry in icons { names[entry.icon.id] = entry.name }
        director = EmotionDirector(seed: seed)
        startedAt = 100
        time = FrameTime(monotonic: startedAt, wallClock: DemoStage.today)
        facts = InteractionFacts(time: time)
    }

    var elapsed: TimeInterval { time.monotonic - startedAt }

    func name(_ id: IconID) -> String { names[id] ?? "?" }
    func icon(_ id: IconID) -> DesktopIcon? { icons.first { $0.id == id } }
    func face(_ id: IconID) -> FacePlacement? { output.faces.first { $0.iconID == id && $0.state.mood != .ghost } }
    var ghosts: [FacePlacement] { output.faces.filter { $0.state.mood == .ghost } }

    // MARK: 推进

    @discardableResult
    func step(_ dt: TimeInterval = frameInterval) -> EmotionOutput {
        if steps > 0 { time = time.advanced(by: dt) }
        steps += 1
        if let drag { mouse = drag.position }
        if let lastMouse, lastMouse == mouse {
            if steps > 1 { idle += dt }
        } else if lastMouse != nil {
            idle = 0
        }
        lastMouse = mouse

        var trash: TrashInfo?
        if let trashRect {
            let distance = trashRect.distance(to: mouse)
            let closing = lastTrashDistance.map { distance < $0 - 0.01 } ?? false
            trash = TrashInfo(
                estimatedRect: trashRect, confidence: trashConfidence, distance: distance,
                isApproaching: closing, isOver: trashRect.contains(mouse)
            )
            lastTrashDistance = distance
        }
        let snapshot = IconSnapshot(icons: icons, status: .ok, capturedAt: time.monotonic, revision: revision)
        let update = pendingReset ? IconUpdate(snapshot: snapshot, isReset: true) : IconUpdate(snapshot: snapshot, changes: changes)
        pendingReset = false
        changes = []
        facts = InteractionFacts(
            time: time,
            mouse: MouseState(position: mouse, buttons: drag != nil ? .left : [], idleDuration: idle),
            isMouseOverDesktop: true,
            hover: hover.map { HoverState(iconID: $0, duration: 0) },
            drag: drag,
            releasedDrags: released,
            trash: trash,
            dragOutcomes: outcomes,
            deletions: deletions
        )
        outcomes = []
        deletions = []
        output = director.update(EmotionInput(time: time, icons: update, facts: facts))
        return output
    }

    // MARK: 摆布桌面（含义与真实的交互事实一一对应）

    func hoverOn(_ id: IconID, offset: CGVector = .zero) {
        guard let icon = icon(id) else { return }
        mouse = icon.imageRect.center.moved(by: offset)
        hover = id
    }

    func moveMouse(to point: CGPoint) {
        mouse = point
        hover = nil
    }

    func startDrag(_ id: IconID) {
        guard let icon = icon(id) else { return }
        hover = nil
        mouse = icon.imageRect.center
        drag = DragState(
            iconID: id,
            grabOffset: CGVector(dx: icon.imageRect.width / 2, dy: icon.imageRect.height / 2),
            originImageRect: icon.imageRect, position: mouse, startedAt: time.monotonic
        )
    }

    func dragTo(_ point: CGPoint) {
        drag?.position = point
        mouse = point
    }

    func release() {
        guard let drag else { return }
        released.append(ReleasedDrag(
            iconID: drag.iconID, releasePoint: drag.position,
            imageRectAtRelease: drag.currentImageRect, releasedAt: time.monotonic
        ))
        self.drag = nil
    }

    func settleMoved(_ id: IconID, to rect: CGRect) {
        released.removeAll { $0.iconID == id }
        guard let index = icons.firstIndex(where: { $0.id == id }) else { return }
        let old = icons[index]
        icons[index].imageRect = rect
        revision += 1
        changes.append(.moved(from: old, to: icons[index]))
        outcomes.append(DragOutcome(iconID: id, kind: .moved, releasePoint: mouse, newImageRect: rect))
    }

    func settleCancelled(_ id: IconID) {
        released.removeAll { $0.iconID == id }
        outcomes.append(DragOutcome(iconID: id, kind: .cancelled, releasePoint: mouse))
    }

    func settleTrashed(_ id: IconID) {
        released.removeAll { $0.iconID == id }
        guard let icon = remove(id, trashed: .yes) else { return }
        outcomes.append(DragOutcome(iconID: id, kind: .trashed, releasePoint: mouse))
        deletions.append(DeletionEvent(iconID: id, lastImageRect: icon.imageRect, wasDragged: true, trashed: .yes))
    }

    func deleteWithoutDrag(_ ids: [IconID]) {
        for id in ids {
            guard let icon = remove(id, trashed: .yes) else { continue }
            deletions.append(DeletionEvent(iconID: id, lastImageRect: icon.imageRect, wasDragged: false, trashed: .yes))
        }
    }

    private func remove(_ id: IconID, trashed: TrashVerdict) -> DesktopIcon? {
        guard let index = icons.firstIndex(where: { $0.id == id }) else { return nil }
        let icon = icons.remove(at: index)
        revision += 1
        changes.append(.removed(icon, trashed: trashed))
        return icon
    }

    func addIcon(name: String, _ icon: DesktopIcon) {
        icons.append(icon)
        names[icon.id] = name
        newcomer = icon.id
        revision += 1
        changes.append(.added(icon))
    }
}

// MARK: - 造图标

/// 找一个指定性格的图标编号（从 `from` 起往后数）。
func rawID(of personality: EmotionPersonality, from: UInt64) -> UInt64 {
    var raw = from
    while EmotionPersonality(faceSeed: IconID(rawValue: raw).faceSeed) != personality { raw += 1 }
    return raw
}

func makeIcon(_ raw: UInt64, center: CGPoint, modifiedAt: Date? = nil) -> DesktopIcon {
    DesktopIcon(
        id: IconID(rawValue: raw), kind: .file,
        imageRect: CGRect(x: center.x - 32, y: center.y - 32, width: 64, height: 64),
        modifiedAt: modifiedAt
    )
}

/// 演示用的一桌图标：像真实桌面那样靠右排成一列多（间距 110 点），性格按给定的顺序。
/// 名字是甲、乙、丙……
func makeCast(_ personalities: [EmotionPersonality], dozing: Set<Int> = []) -> [(name: String, icon: DesktopIcon)] {
    let labels = ["甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸"]
    var raw: UInt64 = 1
    return personalities.enumerated().map { index, personality in
        let id = rawID(of: personality, from: raw)
        raw = id + 1
        let center = CGPoint(x: 1380 - 110 * CGFloat(index / 4), y: 120 + 110 * CGFloat(index % 4))
        let modifiedAt = DemoStage.today.addingTimeInterval(-86400 * (dozing.contains(index) ? 400 + Double(index) * 50 : 20))
        return (labels[index % labels.count], makeIcon(id, center: center, modifiedAt: modifiedAt))
    }
}

func personalityName(_ personality: EmotionPersonality) -> String {
    switch personality {
    case .timid: "胆小"
    case .curious: "好奇"
    case .bold: "胆大"
    }
}
