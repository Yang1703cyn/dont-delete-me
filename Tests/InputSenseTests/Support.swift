// InputSenseTests · 公用的假数据和"舞台"
//
// 测试不碰真实的鼠标、窗口、程序坞和桌面：图标是编的，鼠标轨迹是编的，
// "鼠标处最上面是什么窗口"由测试自己说了算。时间靠一帧一帧往后推，不读时钟、不等待。

import CoreGraphics
import DDMCore
import Foundation
@testable import InputSense

enum Fixture {
    /// 照着开发机的样子：内屏是主屏，外接屏在它左边、略高出一截。
    static let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)
    static let external = CGRect(x: -1920, y: -58, width: 1920, height: 1080)

    /// 一个 64×64 的图标，带一块比图像宽的标签。
    static func icon(_ id: UInt64, x: CGFloat, y: CGFloat) -> DesktopIcon {
        DesktopIcon(
            id: IconID(rawValue: id), kind: .file,
            imageRect: CGRect(x: x, y: y, width: 64, height: 64),
            labelRect: CGRect(x: x - 12, y: y + 68, width: 88, height: 30)
        )
    }

    static let iconA = icon(1, x: 100, y: 100)
    static let iconB = icon(2, x: 300, y: 100)

    /// 程序坞那一条：贴着内屏的底边。
    static let dockBar = CGRect(x: 34, y: 913, width: 1444, height: 69)
    /// 一份够可信的废纸篓估算：程序坞末端的最后一格。
    static let trash = TrashEstimate(rect: CGRect(x: 1400, y: 913, width: 60, height: 69), confidence: 0.75, basis: .measured)
    static let trashCenter = CGPoint(x: 1430, y: 947)

    /// 默认的窗口布置：程序坞那一条上是程序坞，其余到处都是桌面。
    static func defaultSurface(_ point: CGPoint) -> PointerSurface {
        dockBar.contains(point) ? .dock : .desktopIcons
    }
}

/// 舞台：按固定帧率把编好的鼠标剧本一帧一帧喂给判断器，并记下每一帧的事实。
struct Stage {
    var judge = InteractionJudge()
    var time = FrameTime(monotonic: 1000, wallClock: Date(timeIntervalSince1970: 1_700_000_000))
    var frameInterval: TimeInterval = 1.0 / 60

    // —— 鼠标 ——
    var position: CGPoint
    var buttons: MouseButtons = []
    var lastLeftDownAt: TimeInterval?
    var lastLeftUpAt: TimeInterval?

    // —— 窗口遮挡 ——
    /// "这个点上最上面是什么窗口"。默认：程序坞那一条上是程序坞，其余到处都是桌面。
    var surface: (CGPoint) -> PointerSurface = Fixture.defaultSurface

    // —— 图标（由"图标桥"上报）——
    var snapshot: IconSnapshot
    private var queuedChanges: [IconChange] = []
    private var queuedReset = false

    // —— 废纸篓 ——
    var trash: TrashEstimate? = Fixture.trash

    // —— 记录 ——
    private(set) var facts: [InteractionFacts] = []
    private(set) var lessons: [CGPoint] = []
    private(set) var surfaceQueries: [CGPoint] = []

    init(at position: CGPoint, icons: [DesktopIcon] = [Fixture.iconA, Fixture.iconB]) {
        self.position = position
        self.snapshot = IconSnapshot(icons: icons, status: .ok, capturedAt: 900, revision: 1)
    }

    var now: TimeInterval { time.monotonic }
    var last: InteractionFacts { facts[facts.count - 1] }
    var outcomes: [DragOutcome] { facts.flatMap(\.dragOutcomes) }
    var deletions: [DeletionEvent] { facts.flatMap(\.deletions) }
    var refreshRequests: Int { facts.filter(\.wantsIconRefresh).count }

    // MARK: 推进

    /// 往后推一帧。
    @discardableResult
    mutating func frame() -> InteractionFacts {
        time = time.advanced(by: frameInterval)
        let update = IconUpdate(snapshot: snapshot, changes: queuedChanges, isReset: queuedReset)
        queuedChanges = []
        queuedReset = false

        var queries: [CGPoint] = []
        let surface = self.surface
        let input = JudgeInput(
            time: time,
            pointer: PointerSample(position: position, buttons: buttons, lastLeftDownAt: lastLeftDownAt, lastLeftUpAt: lastLeftUpAt),
            icons: update,
            trash: trash
        )
        let output = judge.step(input) { point in
            queries.append(point)
            return surface(point)
        }
        surfaceQueries += queries
        lessons += output.trashLessons
        facts.append(output.facts)
        return output.facts
    }

    /// 鼠标不动，过这么久。
    mutating func wait(_ seconds: TimeInterval) {
        for _ in 0..<max(1, Int((seconds / frameInterval).rounded())) { frame() }
    }

    /// 匀速移到某一点。
    mutating func move(to target: CGPoint, in seconds: TimeInterval) {
        let start = position
        let steps = max(1, Int((seconds / frameInterval).rounded()))
        for step in 1...steps {
            let fraction = CGFloat(step) / CGFloat(steps)
            position = CGPoint(x: start.x + (target.x - start.x) * fraction, y: start.y + (target.y - start.y) * fraction)
            frame()
        }
    }

    /// 沿一条轨迹走这么久。`path` 的参数是从现在起过了多少秒。
    mutating func follow(for seconds: TimeInterval, path: (TimeInterval) -> CGPoint) {
        let steps = max(1, Int((seconds / frameInterval).rounded()))
        for step in 1...steps {
            position = path(Double(step) * frameInterval)
            frame()
        }
    }

    /// 按下按键（发生在上一帧之后、下一帧之前）。
    mutating func press(_ button: MouseButtons = .left) {
        buttons.insert(button)
        if button == .left { lastLeftDownAt = now }
    }

    mutating func release(_ button: MouseButtons = .left) {
        buttons.remove(button)
        if button == .left { lastLeftUpAt = now }
    }

    /// 在当前位置按下，拖到目标点（还不松手）。
    mutating func drag(to target: CGPoint, in seconds: TimeInterval = 0.4) {
        press()
        frame()
        move(to: target, in: seconds)
    }

    // MARK: 图标桥的上报

    /// 重读了一遍，什么都没变。
    mutating func reportUnchanged() {
        snapshot.capturedAt = now
    }

    /// 某个图标换了位置。
    mutating func reportMoved(_ icon: DesktopIcon, to origin: CGPoint) {
        var moved = icon
        moved.imageRect.origin = origin
        moved.labelRect = moved.labelRect.map { $0.offsetBy(dx: origin.x - icon.imageRect.minX, dy: origin.y - icon.imageRect.minY) }
        snapshot.icons = snapshot.icons.map { $0.id == icon.id ? moved : $0 }
        snapshot.capturedAt = now
        snapshot.revision += 1
        queuedChanges.append(.moved(from: icon, to: moved))
    }

    /// 某个图标从桌面消失了。
    mutating func reportRemoved(_ icon: DesktopIcon, trashed: TrashVerdict) {
        snapshot.icons.removeAll { $0.id == icon.id }
        snapshot.capturedAt = now
        snapshot.revision += 1
        queuedChanges.append(.removed(icon, trashed: trashed))
    }

    /// 整体重载。
    mutating func reportReset(icons: [DesktopIcon], status: IconProviderStatus = .ok) {
        snapshot = IconSnapshot(icons: status.isUsable ? icons : [], status: status, capturedAt: now, revision: snapshot.revision + 1)
        queuedChanges = []
        queuedReset = true
    }
}

/// 假的程序坞：设置、所在显示器、那一条的范围都由测试说了算。
@MainActor
final class FakeDock: DockReading {
    var settings: DockSettings? = DockSettings(edge: .bottom, tileSize: 64, tileCount: 32, separatorCount: 2)
    var dockDisplayFrame: CGRect? = Fixture.external
    var primaryDisplayFrame: CGRect? = Fixture.builtIn
    /// 程序坞那一条此刻在屏上的范围；nil 表示程序坞没露出来。
    var bar: CGRect?

    private(set) var refreshRequests = 0
    private(set) var measurements = 0

    func requestRefresh() {
        refreshRequests += 1
    }

    func measureBar(edge: DockEdge, displayFrame: CGRect) -> CGRect? {
        measurements += 1
        guard let bar else { return nil }
        return DockBarScan.measure(edge: edge, displayFrame: displayFrame) { bar.contains($0) }
    }
}

/// 假的"读系统的薄层"：给模块入口的测试用。
@MainActor
final class FakeEnvironment: InteractionEnvironment {
    var pointer = PointerSample(position: .zero)
    var surfaceValue: PointerSurface = .desktopIcons
    var trash: TrashEstimate? = Fixture.trash

    private(set) var pointerReads = 0
    private(set) var surfaceQueries = 0
    private(set) var learned: [CGPoint] = []
    private(set) var draggingFlags: [Bool] = []

    func readPointer() -> PointerSample {
        pointerReads += 1
        return pointer
    }

    func surface(at point: CGPoint) -> PointerSurface {
        surfaceQueries += 1
        return surfaceValue
    }

    func trashEstimate(at time: FrameTime, isDragging: Bool) -> TrashEstimate? {
        draggingFlags.append(isDragging)
        return trash
    }

    func learnTrashLocation(releasePoint: CGPoint, at time: FrameTime) {
        learned.append(releasePoint)
    }
}
