// EmotionTests · 测试用的小舞台
//
// 一块编造的桌面：几个假图标、一只假鼠标、一个假废纸篓。测试用它一帧一帧地喂情绪引擎，
// 时间全靠传入（每帧往后推 1/60 秒），不等待、不读真实时钟；图标数据全是编的，不碰真实桌面。

import CoreGraphics
import DDMCore
import Foundation
import Testing
@testable import Emotion

/// 每秒 60 帧时一帧多长。
let frameInterval: TimeInterval = 1.0 / 60

final class Stage {
    var director: EmotionDirector
    private(set) var icons: [DesktopIcon]
    private(set) var time: FrameTime

    // 这一帧的事实，由测试摆布。
    var mouse = CGPoint(x: 400, y: 300)
    /// 鼠标已经静止多久。鼠标位置没变时每帧自动累加，一动归零；也可以直接改。
    var idle: TimeInterval = 0
    var hover: IconID?
    var drag: DragState?
    var released: [ReleasedDrag] = []
    /// 假废纸篓的估算区域；nil 表示估算不出来。
    var trashRect: CGRect? = CGRect(x: 1300, y: 900, width: 60, height: 70)
    var trashConfidence = 0.75
    /// 强行指定"是否正朝废纸篓去"；nil 时按鼠标是不是离它更近了来算。
    var approaching: Bool?

    // 一次性事件：下一帧送出，然后清空。
    var outcomes: [DragOutcome] = []
    var deletions: [DeletionEvent] = []
    private var changes: [IconChange] = []
    private var pendingReset = true

    private var revision: UInt64 = 1
    private var lastMouse: CGPoint?
    private var lastTrashDistance: CGFloat?
    private var hoverSince: TimeInterval = 0
    private(set) var output = EmotionOutput()
    private(set) var frames = 0

    init(icons: [DesktopIcon], seed: UInt64 = 42, tuning: EmotionTuning = EmotionTuning(), start: TimeInterval = 100) {
        self.icons = icons
        director = EmotionDirector(seed: seed, tuning: tuning)
        time = FrameTime(monotonic: start, wallClock: Stage.today)
    }

    /// 测试里的"今天"。
    static let today = Date(timeIntervalSince1970: 1_800_000_000)

    /// 距今这么多天以前。
    static func daysAgo(_ days: Double) -> Date {
        today.addingTimeInterval(-days * 86400)
    }

    // MARK: 推进

    /// 喂一帧（先把时间往后推 `dt`；第一帧不推）。
    @discardableResult
    func step(_ dt: TimeInterval = frameInterval) -> EmotionOutput {
        if frames > 0 { time = time.advanced(by: dt) }
        frames += 1

        if drag != nil { mouse = drag!.position }
        if let lastMouse, lastMouse == mouse {
            idle += frames > 1 ? dt : 0
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
                closingSpeed: 0, isApproaching: approaching ?? closing, isOver: trashRect.contains(mouse)
            )
            lastTrashDistance = distance
        }

        let snapshot = IconSnapshot(icons: icons, status: .ok, capturedAt: time.monotonic, revision: revision)
        let update = pendingReset ? IconUpdate(snapshot: snapshot, isReset: true) : IconUpdate(snapshot: snapshot, changes: changes)
        pendingReset = false
        changes = []

        let facts = InteractionFacts(
            time: time,
            mouse: MouseState(position: mouse, buttons: drag != nil ? .left : [], idleDuration: idle),
            isMouseOverDesktop: true,
            hover: hover.map { HoverState(iconID: $0, duration: time.monotonic - hoverSince) },
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

    /// 连续喂 `seconds` 秒。`each` 在每一帧之后调用，可以检查输出、也可以改下一帧的事实。
    @discardableResult
    func run(_ seconds: TimeInterval, each: ((Stage) -> Void)? = nil) -> EmotionOutput {
        let count = max(Int((seconds / frameInterval).rounded()), 1)
        for _ in 0..<count {
            step()
            each?(self)
        }
        return output
    }

    // MARK: 查看输出

    func face(_ id: IconID, layer: OverlayLayer? = nil) -> FacePlacement? {
        output.faces.first { $0.iconID == id && (layer == nil || $0.layer == layer) && $0.state.mood != .ghost }
    }

    /// 某个图标这一帧的表情；没画脸时测试失败。
    func state(_ id: IconID, sourceLocation: SourceLocation = #_sourceLocation) -> FaceState {
        guard let face = face(id) else {
            Issue.record("图标 \(id) 这一帧没有脸", sourceLocation: sourceLocation)
            return FaceState(seed: 0)
        }
        return face.state
    }

    var ghosts: [FacePlacement] { output.faces.filter { $0.state.mood == .ghost } }

    func icon(_ id: IconID) -> DesktopIcon? { icons.first { $0.id == id } }

    // MARK: 摆布桌面

    func hoverOn(_ id: IconID?) {
        if let id, let icon = icon(id) {
            mouse = icon.imageRect.center
            if hover != id { hoverSince = time.monotonic }
        }
        hover = id
    }

    /// 把鼠标挪到别处（顺便结束悬停）。
    func moveMouse(to point: CGPoint) {
        mouse = point
        hover = nil
    }

    /// 抓起一个图标（鼠标按在它的正中）。
    func startDrag(_ id: IconID, shake: Double = 0) {
        guard let icon = icon(id) else { return }
        hover = nil
        mouse = icon.imageRect.center
        drag = DragState(
            iconID: id,
            grabOffset: CGVector(dx: icon.imageRect.width / 2, dy: icon.imageRect.height / 2),
            originImageRect: icon.imageRect,
            position: mouse,
            shake: shake,
            startedAt: time.monotonic
        )
    }

    func dragTo(_ point: CGPoint) {
        drag?.position = point
        mouse = point
    }

    /// 松手：拖拽变成"已松手、结局未定"。
    func release() {
        guard let drag else { return }
        released.append(ReleasedDrag(
            iconID: drag.iconID, releasePoint: drag.position,
            imageRectAtRelease: drag.currentImageRect, releasedAt: time.monotonic
        ))
        self.drag = nil
    }

    private func takeReleased(_ id: IconID) -> ReleasedDrag? {
        guard let index = released.firstIndex(where: { $0.iconID == id }) else { return nil }
        return released.remove(at: index)
    }

    /// 结局：挪了位置。
    func settleMoved(_ id: IconID, to rect: CGRect) {
        let entry = takeReleased(id)
        guard let index = icons.firstIndex(where: { $0.id == id }) else { return }
        let old = icons[index]
        icons[index].imageRect = rect
        revision += 1
        changes.append(.moved(from: old, to: icons[index]))
        outcomes.append(DragOutcome(iconID: id, kind: .moved, releasePoint: entry?.releasePoint ?? mouse, newImageRect: rect))
    }

    /// 结局：取消 / 判断不出（图标原地不动）。
    func settle(_ id: IconID, as kind: DragOutcomeKind) {
        let entry = takeReleased(id)
        outcomes.append(DragOutcome(iconID: id, kind: kind, releasePoint: entry?.releasePoint ?? mouse))
    }

    /// 结局：进了废纸篓（图标从桌面消失，同帧给出结局和删除事件）。
    func settleTrashed(_ id: IconID) {
        let entry = takeReleased(id)
        guard let icon = removeIcon(id, trashed: .yes) else { return }
        outcomes.append(DragOutcome(iconID: id, kind: .trashed, releasePoint: entry?.releasePoint ?? mouse))
        deletions.append(DeletionEvent(iconID: id, lastImageRect: icon.imageRect, wasDragged: true, trashed: .yes))
    }

    /// 结局：离开桌面去了别处（图标消失，没有删除事件）。
    func settleLeftDesktop(_ id: IconID) {
        let entry = takeReleased(id)
        guard removeIcon(id, trashed: .no) != nil else { return }
        outcomes.append(DragOutcome(iconID: id, kind: .leftDesktop, releasePoint: entry?.releasePoint ?? mouse))
    }

    /// 没有拖拽过程的删除（快捷键、右键菜单）。
    func deleteWithoutDrag(_ ids: [IconID]) {
        for id in ids {
            guard let icon = removeIcon(id, trashed: .yes) else { continue }
            deletions.append(DeletionEvent(iconID: id, lastImageRect: icon.imageRect, wasDragged: false, trashed: .yes))
        }
    }

    /// 图标从桌面消失（不带删除事件）。
    @discardableResult
    func removeIcon(_ id: IconID, trashed: TrashVerdict = .no) -> DesktopIcon? {
        guard let index = icons.firstIndex(where: { $0.id == id }) else { return nil }
        let icon = icons.remove(at: index)
        revision += 1
        changes.append(.removed(icon, trashed: trashed))
        return icon
    }

    /// 桌面上多了一个图标。`announce` 为 false 时不带"新增"事件（悄悄多出来）。
    func addIcon(_ icon: DesktopIcon, announce: Bool = true) {
        icons.append(icon)
        revision += 1
        if announce { changes.append(.added(icon)) }
    }

    /// 改一个图标（位置、修改时间……），不带事件。
    func modifyIcon(_ id: IconID, _ body: (inout DesktopIcon) -> Void) {
        guard let index = icons.firstIndex(where: { $0.id == id }) else { return }
        body(&icons[index])
        revision += 1
    }

    /// 下一帧按"整体重载"送出当前的图标。
    func reloadAll(_ icons: [DesktopIcon]? = nil) {
        if let icons { self.icons = icons }
        revision += 1
        pendingReset = true
    }
}

// MARK: - 造图标

/// 图标的边长。
let iconSide: CGFloat = 64

/// 一个假图标，图像矩形以 `center` 为中心。
func makeIcon(_ raw: UInt64, center: CGPoint, modifiedAt: Date? = nil) -> DesktopIcon {
    DesktopIcon(
        id: IconID(rawValue: raw), kind: .file,
        imageRect: CGRect(x: center.x - iconSide / 2, y: center.y - iconSide / 2, width: iconSide, height: iconSide),
        modifiedAt: modifiedAt
    )
}

/// 排成几列的一桌假图标，编号从 `firstRaw` 起。间距 110 点，左上角那个的中心在 `origin`。
func makeGrid(count: Int, columns: Int = 4, origin: CGPoint = CGPoint(x: 900, y: 120), firstRaw: UInt64 = 1) -> [DesktopIcon] {
    (0..<count).map { index in
        makeIcon(
            firstRaw + UInt64(index),
            center: CGPoint(x: origin.x + 110 * CGFloat(index % columns), y: origin.y + 110 * CGFloat(index / columns))
        )
    }
}

/// 找出指定性格的图标编号：从 `from` 起往后数，第一个性格相符的。
func rawID(of personality: EmotionPersonality, from: UInt64 = 1) -> UInt64 {
    var raw = from
    while EmotionPersonality(faceSeed: IconID(rawValue: raw).faceSeed) != personality { raw += 1 }
    return raw
}

// MARK: - 小工具

extension FaceState {
    /// 画面上视线大致偏到哪里（单位圆内的向量）：跟随程度 × 方向 × 远近。
    /// 用它而不是原始的 `gazeTarget` 来检查"视线有没有突变"——目标在远处挪动几百点，眼睛其实几乎不动。
    func lookVector(softness: Double = 9.6) -> (x: Double, y: Double, z: Double) {
        let dx = Double(gazeTarget.dx), dy = Double(gazeTarget.dy)
        let reach = (dx * dx + dy * dy).squareRoot() + softness
        return (dx * gazeFollow / reach, dy * gazeFollow / reach, gazeFollow * softness / reach)
    }

    /// 是否朝着某个相对位移的方向看（夹角在 `tolerance` 度以内，且确实在跟随）。
    func isLooking(toward offset: CGVector, tolerance: Double = 12) -> Bool {
        guard gazeFollow > 0.5 else { return false }
        let a = atan2(Double(gazeTarget.dy), Double(gazeTarget.dx))
        let b = atan2(Double(offset.dy), Double(offset.dx))
        var difference = abs(a - b)
        if difference > .pi { difference = 2 * .pi - difference }
        return difference * 180 / .pi <= tolerance
    }
}

/// 除了眨眼和视线，其余强度参数全是 0（一张平静、清醒的脸）。
func isCalmAndAwake(_ state: FaceState) -> Bool {
    state.mood == .calm && state.blush == 0 && state.fear == 0 && state.sweat == 0 && state.tremble == 0
        && state.tears == 0 && state.dizziness == 0 && state.cover == 0 && state.peek == 0
        && state.sleepiness == 0 && state.ghost == 0
}
