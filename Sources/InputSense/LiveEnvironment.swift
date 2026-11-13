// InputSense · 读系统的薄薄一层（真实实现）
//
// 判断器需要的系统信息全部从这里来：鼠标、"某个点上最上面是什么窗口"、废纸篓的估算。
// 全部是只读查询，不需要任何系统授权；不产生、不拦截、不修改任何输入事件；不改任何系统设置。
// 唯一写入的东西：学到的废纸篓位置（几个数字），存在应用自己的偏好设置里。

import AppKit
import CoreGraphics
import DDMCore
import Foundation

@MainActor
public final class LiveEnvironment: InteractionEnvironment {
    public struct Options: Sendable {
        /// 学到的废纸篓位置要不要存进偏好设置。应用里是 true；演示和测试设成 false，只记在内存里。
        public var remembersTrashLocation = true
        /// **只给演示用**：把"图标被系统遮住的桌面"也当作桌面。
        /// 开发机的桌面项目是被系统隐藏的，不开这个就没法在真实屏幕上试悬停和拖拽。应用里不要开。
        public var countsShieldedDesktopAsDesktop = false

        public init() {}
    }

    /// 排查用的状态快照。不含任何用户数据。
    public struct Diagnostics: Sendable, Equatable {
        /// 程序坞靠在哪一边：bottom / left / right。还没读到为 nil。
        public var dockEdge: String?
        /// 设置里的图标大小。
        public var dockTileSize: CGFloat?
        /// 估计的项目数（含访达和废纸篓）。
        public var dockTileCount: Double?
        public var dockAutohide: Bool?
        public var dockMagnification: Bool?
        /// 程序坞所在显示器的范围。
        public var dockDisplayFrame: CGRect?
        /// 这块显示器是查到的（true），还是只能假定主屏（false）。
        public var isDockDisplayKnown = false
        /// 量到的程序坞那一条的范围；量不到为 nil。
        public var measuredDockBar: CGRect?
        /// 按设置推算的那一条的范围（不管有没有量到都给，方便对照）。
        public var predictedDockBar: CGRect?
        /// 学到了几条废纸篓位置。
        public var lessonCount = 0
    }

    /// 鼠标静止超过这么久（秒），就少读程序坞的设置。
    private static let idleAfter: TimeInterval = 10

    private let options: Options
    private let probe: WindowProbe
    private let locator: TrashLocator
    private var lastPosition: CGPoint?
    private var lastMovedAt: TimeInterval = 0

    public init(options: Options = Options()) {
        self.options = options
        let probe = WindowProbe()
        self.probe = probe
        let store: any TrashMemoryStoring = options.remembersTrashLocation ? PersistentTrashMemory() : InMemoryTrashMemory()
        self.locator = TrashLocator(dock: SystemDockReader(probe: probe), store: store)
    }

    // MARK: InteractionEnvironment

    public func readPointer() -> PointerSample {
        // 都是"现在是什么状态"的查询，不是事件监听。
        let position = probe.layout().globalPoint(fromAppKit: NSEvent.mouseLocation)
        let pressed = NSEvent.pressedMouseButtons
        var buttons: MouseButtons = []
        if pressed & 0b1 != 0 { buttons.insert(.left) }
        if pressed & 0b10 != 0 { buttons.insert(.right) }
        if pressed & ~0b11 != 0 { buttons.insert(.other) }

        let now = ProcessInfo.processInfo.systemUptime
        if position != lastPosition {
            lastPosition = position
            lastMovedAt = now
        }
        func lastEvent(_ type: CGEventType) -> TimeInterval? {
            let elapsed = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type)
            return elapsed.isFinite && elapsed >= 0 ? now - elapsed : nil
        }
        return PointerSample(
            position: position,
            buttons: buttons,
            lastLeftDownAt: lastEvent(.leftMouseDown),
            lastLeftUpAt: lastEvent(.leftMouseUp)
        )
    }

    public func surface(at point: CGPoint) -> PointerSurface {
        let surface = probe.surface(at: point)
        if surface == .shieldedDesktop, options.countsShieldedDesktopAsDesktop {
            return .desktopIcons
        }
        return surface
    }

    public func trashEstimate(at time: FrameTime, isDragging: Bool) -> TrashEstimate? {
        let isIdle = ProcessInfo.processInfo.systemUptime - lastMovedAt > Self.idleAfter
        return locator.estimate(at: time.monotonic, isDragging: isDragging, isIdle: isIdle)
    }

    public func learnTrashLocation(releasePoint: CGPoint, at time: FrameTime) {
        locator.learn(releasePoint: releasePoint)
    }

    // MARK: 排查

    /// 不经过 `countsShieldedDesktopAsDesktop` 的原始判断：这个点上最上面到底是什么窗口。
    public func rawSurface(at point: CGPoint) -> PointerSurface {
        probe.surface(at: point)
    }

    public var diagnostics: Diagnostics {
        var result = Diagnostics()
        result.lessonCount = locator.lessonCount
        guard let observation = locator.observation else { return result }
        result.dockEdge = observation.settings.edge.rawValue
        result.dockTileSize = observation.settings.tileSize
        result.dockTileCount = observation.settings.tileCount
        result.dockAutohide = observation.settings.autohide
        result.dockMagnification = observation.settings.magnification
        result.dockDisplayFrame = observation.displayFrame
        result.isDockDisplayKnown = observation.isDisplayKnown
        result.measuredDockBar = observation.measuredBar
        result.predictedDockBar = DockModel.predictedBar(settings: observation.settings, displayFrame: observation.displayFrame).bar
        return result
    }
}
