// InputSense · 读系统的薄层（模拟实现）
//
// 给演示程序的"剧本回放"用：鼠标、窗口遮挡、程序坞都是编的，不读任何真实的系统状态；
// 但废纸篓的估算、测量和自学习走的是和真实实现同一套代码（`TrashLocator` / `TrashEstimator` / `DockBarScan`）。
// 应用里不使用它。

import CoreGraphics
import DDMCore
import Foundation

/// 一个编出来的程序坞。
public struct SimulatedDock: Sendable {
    /// 程序坞所在的显示器，全局坐标。
    public var displayFrame: CGRect
    /// 设置里的图标大小（点）。
    public var tileSize: CGFloat
    /// 程序坞里真正有几项（含访达和废纸篓）。
    public var tileCount: Double
    /// 按设置数项目时漏数了几项（真实系统里例如最小化的窗口，设置里看不出来）。
    /// 漏数会让只靠公式的估算偏掉，用来演示"自学习把它纠正回来"。
    public var uncountedTiles: Double
    /// 程序坞此刻是否露在屏上。露着就量得到它的实际范围，藏着就只能靠公式。
    public var isVisible: Bool

    public init(
        displayFrame: CGRect,
        tileSize: CGFloat = 48,
        tileCount: Double = 12,
        uncountedTiles: Double = 0,
        isVisible: Bool = true
    ) {
        self.displayFrame = displayFrame
        self.tileSize = tileSize
        self.tileCount = tileCount
        self.uncountedTiles = uncountedTiles
        self.isVisible = isVisible
    }

    fileprivate var trueSettings: DockSettings {
        DockSettings(edge: .bottom, tileSize: tileSize, tileCount: tileCount, separatorCount: 2)
    }

    /// 程序坞那一条真正在哪（这个编出来的程序坞里）。
    public var trueBarRect: CGRect {
        DockModel.predictedBar(settings: trueSettings, displayFrame: displayFrame).bar
    }

    /// 废纸篓真正在哪。
    public var trueTrashRect: CGRect {
        let (bar, pitch) = DockModel.predictedBar(settings: trueSettings, displayFrame: displayFrame)
        return DockModel.trashSlot(bar: bar, pitch: pitch, edge: .bottom)
    }
}

@MainActor
public final class SimulatedEnvironment: InteractionEnvironment {
    /// 鼠标的当前状态。由调用方（剧本）每帧改写。
    public var pointer: PointerSample
    /// 程序坞那一条之外，"这个点上最上面是什么窗口"。默认到处都是桌面。
    /// 那一条上总是程序坞（藏着的程序坞，鼠标推到屏幕边上时会弹出来）。
    public var surfaceAt: (CGPoint) -> PointerSurface = { _ in .desktopIcons }
    /// 编出来的程序坞。可以中途修改（例如让它藏起来）。
    public var dock: SimulatedDock {
        didSet { reader.dock = dock }
    }

    private let reader: SimulatedDockReader
    private let locator: TrashLocator

    public init(pointer: PointerSample, dock: SimulatedDock) {
        self.pointer = pointer
        self.dock = dock
        self.reader = SimulatedDockReader(dock: dock)
        self.locator = TrashLocator(dock: reader, store: InMemoryTrashMemory())
    }

    /// 自学习记下了几次松手位置。
    public var lessonCount: Int { locator.lessonCount }

    public func readPointer() -> PointerSample { pointer }

    public func surface(at point: CGPoint) -> PointerSurface {
        dock.trueBarRect.contains(point) ? .dock : surfaceAt(point)
    }

    public func trashEstimate(at time: FrameTime, isDragging: Bool) -> TrashEstimate? {
        locator.estimate(at: time.monotonic, isDragging: isDragging)
    }

    public func learnTrashLocation(releasePoint: CGPoint, at time: FrameTime) {
        locator.learn(releasePoint: releasePoint)
    }
}

@MainActor
private final class SimulatedDockReader: DockReading {
    var dock: SimulatedDock

    init(dock: SimulatedDock) {
        self.dock = dock
    }

    var settings: DockSettings? {
        var settings = dock.trueSettings
        settings.tileCount = max(2, dock.tileCount - dock.uncountedTiles)
        return settings
    }

    var dockDisplayFrame: CGRect? { dock.displayFrame }
    var primaryDisplayFrame: CGRect? { dock.displayFrame }

    func requestRefresh() {}

    func measureBar(edge: DockEdge, displayFrame: CGRect) -> CGRect? {
        guard dock.isVisible else { return nil }
        let bar = DockModel.predictedBar(settings: dock.trueSettings, displayFrame: dock.displayFrame).bar
        return DockBarScan.measure(edge: edge, displayFrame: displayFrame) { bar.contains($0) }
    }
}
