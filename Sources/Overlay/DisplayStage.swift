// Overlay · 一块屏上的一层画布
//
// 桌面层和拖拽层在每块屏上各有一个 DisplayStage。它负责三件事：
//   1. 按 ScenePlanner 的判定，只重画需要重画的画布项；
//   2. 管这块屏上的叠加窗口；
//   3. 把画好的内容贴到窗口里的图层上。
//
// 【桌面层的窗口为什么不止一个】
// 桌面层的窗口**属于某一个桌面空间**（不是"所有空间都有"的那种窗口）。这样切换空间时，
// 它和普通窗口一样跟着自己的空间一起滑走，和图标保持同步，不会出现"图标滑走、脸留在原地"。
// 代价是每个空间需要各自的窗口：第一次来到某个空间时新建一个（等切换动画结束后淡入），
// 之后再回到这个空间，窗口已经在那里了，和图标一起滑进来。所有窗口显示同样的内容。
//
// 拖拽层只有一个窗口，所有空间都有，只在有拖拽项时显示。

import AppKit
import DDMCore
import QuartzCore

@MainActor
final class DisplayStage {
    enum Kind: Sendable {
        case desktop
        case drag
    }

    /// 新来到一个空间时，等这么久（切换动画结束）再让脸淡入。
    static let spaceSettleDelay: TimeInterval = 0.45
    /// 淡入 / 淡出的时长。
    static let fadeInDuration: TimeInterval = 0.2
    static let fadeOutDuration: TimeInterval = 0.12
    /// 刚建好的窗口在这段时间内一律当作"在当前空间里"，不依赖系统的即时回答。
    private static let newWindowGrace: TimeInterval = 1
    /// 例行巡检时（不是切换空间引起的）最多每隔这么久新建一个窗口。
    /// 正常情况下用不到；它防的是"系统总说我们的窗口不在当前空间"这种意外——那样也只是偶尔多建一个，而不是每秒建一个。
    private static let routineCreationInterval: TimeInterval = 10

    let kind: Kind
    let display: DisplayInfo

    private let appKitFrame: CGRect
    private let maxWindows: Int
    private var planner = ScenePlanner()
    private var images: [OverlayItem.Key: CGImage] = [:]
    private var visuals: [ItemVisual] = []

    private var windows: [CanvasWindow] = []
    /// 在这块屏当前空间里的窗口（由 `reconcileWindows` 更新）。
    private var activeWindows: [CanvasWindow] = []
    private var createdAt: [ObjectIdentifier: TimeInterval] = [:]
    private var lastCreationAt: TimeInterval = -.infinity
    /// 还在等"切换动画结束"、暂时不显示内容的窗口。
    private var pendingReveal: Set<ObjectIdentifier> = []
    /// 不在当前空间的窗口，内容是否落后了。
    private var hasStaleWindows = false
    private var isContentWanted = true
    /// 已经关闭（叠加层停止了，或显示器布局变了）。关闭之后不再作画，也不再建窗、显示窗口。
    private var isClosed = false

    /// - Parameters:
    ///   - appKitFrame: 这块屏的矩形，AppKit 坐标。窗口与它等大。
    ///   - maxWindows: 最多保留几个桌面层窗口。
    init(kind: Kind, display: DisplayInfo, appKitFrame: CGRect, maxWindows: Int) {
        self.kind = kind
        self.display = display
        self.appKitFrame = appKitFrame
        self.maxWindows = max(1, maxWindows)
    }

    // MARK: - 作画

    /// 这块屏上现在有多少个画布项。
    var itemCount: Int { visuals.count }

    /// 按这一帧的清单更新这块屏：该重画的回调 `draw` 重画，其余只挪位置或不动。
    /// - Parameters:
    ///   - items: 这一层的全部画布项（不必预先筛出"在这块屏上的"）。
    ///   - canDraw: 这块屏此刻是否看得见。看不见时不回调 `draw`，欠着的等看得见了再补。
    ///   - shouldStop: 每次回调 `draw` 之前问一次"还要不要继续"。调用方可能就在绘制回调里暂停或停止了叠加层：
    ///     那之后剩下的项不再画（记成欠着），也不再显示任何窗口。
    ///   - draw: 画一个画布项。画布已经是全局坐标、已裁剪、已清空。
    /// - Returns: 回调了几次 `draw`。
    @discardableResult
    func render(
        items: [OverlayItem],
        canDraw: Bool,
        shouldStop: () -> Bool = { false },
        draw: (OverlayItem, CGContext) -> Void
    ) -> Int {
        guard !isClosed else { return 0 }
        let slots = planner.plan(items: items, on: display, canDraw: canDraw)

        var drawCount = 0
        var stopped = false
        var changed = slots.count != visuals.count
        var next: [ItemVisual] = []
        next.reserveCapacity(slots.count)
        var liveImages: [OverlayItem.Key: CGImage] = [:]
        liveImages.reserveCapacity(slots.count)

        for (index, slot) in slots.enumerated() {
            let key = slot.item.key
            if slot.action == .draw {
                stopped = stopped || shouldStop()
                if stopped {
                    // 不画了：记成欠着，沿用旧图（如果有）。
                    planner.markDrawFailed(key)
                } else {
                    drawCount += 1
                    let image = ItemRasterizer.render(
                        placement: slot.placement, display: display, clip: slot.item.canvasRect
                    ) { draw(slot.item, $0) }
                    if image == nil { planner.markDrawFailed(key) }
                    images[key] = image
                }
            }
            guard let image = images[key] else {
                changed = true      // 还没有图（从没画成过）：这一项暂时不显示
                continue
            }
            liveImages[key] = image
            if slot.action != .keep || index >= visuals.count || visuals[index].key != key {
                changed = true
            }
            next.append(ItemVisual(key: key, placement: slot.placement, image: image))
        }

        images = liveImages
        visuals = next
        // 绘制回调里叠加层被暂停或停止了：到此为止，不碰窗口。
        guard !isClosed, !(stopped || shouldStop()) else { return drawCount }
        if changed {
            pushToWindows()
        } else if kind == .drag, !visuals.isEmpty, let window = windows.first, !window.isVisible {
            // 内容没变，但窗口之前被收起了（暂停、桌面一度看不见）：重新显示。
            window.orderFrontRegardless()
        }
        return drawCount
    }

    private func pushToWindows() {
        guard !isClosed else { return }
        switch kind {
        case .desktop:
            for window in activeWindows { window.apply(visuals) }
            if windows.count > activeWindows.count { hasStaleWindows = true }
        case .drag:
            if visuals.isEmpty {
                // 没有拖拽项：窗口不显示。
                windows.first?.apply([])
                windows.first?.orderOut(nil)
            } else {
                let window = windows.first ?? makeWindow()
                window.apply(visuals)
                if !window.isVisible { window.orderFrontRegardless() }
            }
        }
    }

    /// 把不在当前空间的窗口也更新到最新内容。帧循环空下来时、切换空间时调用——
    /// 这样回到别的空间时，跟着滑进来的是新内容而不是很久以前的样子。
    func syncStaleWindows() {
        guard hasStaleWindows else { return }
        hasStaleWindows = false
        for window in windows where !activeWindows.contains(where: { $0 === window }) {
            window.apply(visuals)
        }
    }

    // MARK: - 窗口

    /// 这块屏当前的空间里有没有我们的窗口。
    var hasWindowOnActiveSpace: Bool { !activeWindows.isEmpty }

    /// 当前空间里的窗口是否至少有一部分没被挡住（系统给的遮挡状态）。
    var isUnoccluded: Bool {
        activeWindows.contains { $0.occlusionState.contains(.visible) }
    }

    /// 一共有几个窗口、其中几个在当前空间。
    var windowCounts: (total: Int, active: Int) { (windows.count, activeWindows.count) }

    /// 所有窗口的编号（自检时用来在系统的窗口列表里找到它们）。
    var windowNumbers: [Int] { windows.filter(\.isVisible).map(\.windowNumber) }

    /// 所有窗口是否都点击穿透（自检用）。
    var allWindowsIgnoreMouse: Bool { windows.allSatisfy(\.ignoresMouseEvents) }

    /// 为什么要核对窗口。
    enum ReconcileTrigger: Sendable {
        /// 启动、定时巡检、其它系统事件。
        case routine
        /// 刚切换了桌面空间（或其后的复查）。
        case spaceChange
        /// "强制可见"：不问系统窗口在不在当前空间，已有的一律算在。
        case assumeActive
    }

    /// 桌面层：核对"当前空间里有没有窗口"，没有就建一个；多了就关掉。
    /// - Parameters:
    ///   - allowCreate: 当前空间是不是一个有桌面图标层的空间。全屏应用的空间里不建窗。
    ///   - trigger: 为什么核对。切换空间时：不给刚建的窗口宽限（它多半属于上一个空间）、新建不限频、
    ///     新窗口等切换动画结束再淡入。
    func reconcileWindows(allowCreate: Bool, now: TimeInterval, trigger: ReconcileTrigger) {
        guard kind == .desktop, !isClosed else { return }

        var active = windows.filter { window in
            guard window.isVisible else { return false }
            switch trigger {
            case .assumeActive:
                return true
            case .spaceChange:
                return window.isOnActiveSpace
            case .routine:
                if let created = createdAt[ObjectIdentifier(window)], now - created < Self.newWindowGrace { return true }
                return window.isOnActiveSpace
            }
        }

        // 同一个空间里出现了不止一个（比如某个空间被删掉，它的窗口并进了隔壁）：只留一个。
        for extra in active.dropFirst() { close(extra) }
        active = Array(active.prefix(1))

        // 切换空间或一个窗口都没有时立刻建；例行巡检时限一下频率。
        let mayCreate = trigger != .routine || windows.isEmpty
            || now - lastCreationAt >= Self.routineCreationInterval
        if active.isEmpty, allowCreate, mayCreate {
            lastCreationAt = now
            let window = makeWindow()
            window.apply(visuals)
            if trigger == .spaceChange {
                window.setContentShown(false, duration: 0)
                scheduleReveal(of: window, after: Self.spaceSettleDelay)
            } else {
                window.setContentShown(isContentWanted, duration: 0)
            }
            window.orderFrontRegardless()
            active = [window]
        }

        for window in active { window.lastActiveAt = now }

        // 窗口太多（空间很多）：关掉最久没用的。
        while windows.count > maxWindows {
            let idle = windows.filter { window in !active.contains(where: { $0 === window }) }
            guard let oldest = idle.min(by: { $0.lastActiveAt < $1.lastActiveAt }) else { break }
            close(oldest)
        }

        let changed = active.count != activeWindows.count || zip(active, activeWindows).contains { $0 !== $1 }
        activeWindows = active
        if changed {
            for window in active { window.apply(visuals) }
            hasStaleWindows = windows.count > active.count
        }
    }

    /// 内容该不该显示（图标被隐藏、应用被暂停时为 false）。窗口本身不动，只是内容淡出 / 淡入。
    func setContentWanted(_ wanted: Bool, animated: Bool) {
        guard wanted != isContentWanted else { return }
        isContentWanted = wanted
        for window in windows where !pendingReveal.contains(ObjectIdentifier(window)) {
            let duration = animated ? (wanted ? Self.fadeInDuration : Self.fadeOutDuration) : 0
            window.setContentShown(wanted, duration: duration)
        }
    }

    /// 拖拽层：立刻收起窗口（桌面看不见或暂停时）。下一帧有拖拽项时会再出现。
    func hideDragWindow() {
        guard kind == .drag else { return }
        windows.first?.orderOut(nil)
    }

    /// 拖拽层窗口此刻是否显示着。
    var isDragWindowShown: Bool { kind == .drag && (windows.first?.isVisible ?? false) }

    /// 关闭所有窗口，并且从此不再作画、不再建窗。
    func closeAll() {
        isClosed = true
        for window in windows { close(window) }
        activeWindows.removeAll()
    }

    /// 自检用：这块屏上某一点（屏内坐标）渲染出来的颜色。
    func renderedPixel(atLocalPoint point: CGPoint) -> OverlayDebugPixel? {
        let window = kind == .desktop ? (activeWindows.first ?? windows.first) : windows.first
        return window?.renderedPixel(atLocalPoint: point, scale: display.scale)
    }

    private func makeWindow() -> CanvasWindow {
        let window: CanvasWindow
        switch kind {
        case .desktop:
            // 桌面图标层 +1：压在访达图标之上、普通窗口之下。
            // 不加"所有空间都有"；.stationary：调度中心、显示桌面时留在原地，像桌面的一部分。
            window = CanvasWindow(
                appKitFrame: appKitFrame,
                level: NSWindow.Level(rawValue: SystemProbe.desktopIconLevel + 1),
                behavior: [.stationary, .ignoresCycle, .fullScreenNone]
            )
        case .drag:
            // 拖影层 +1：在普通窗口、程序坞、菜单栏和系统的拖影之上，在屏保和锁屏之下。
            // 所有空间都有（拖着图标切换空间时脸不丢），全屏应用上方也能显示。
            window = CanvasWindow(
                appKitFrame: appKitFrame,
                level: NSWindow.Level(rawValue: SystemProbe.draggingLevel + 1),
                behavior: [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            )
        }
        windows.append(window)
        createdAt[ObjectIdentifier(window)] = ProcessInfo.processInfo.systemUptime
        return window
    }

    private func scheduleReveal(of window: CanvasWindow, after delay: TimeInterval) {
        let id = ObjectIdentifier(window)
        pendingReveal.insert(id)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, self.pendingReveal.remove(id) != nil, let window else { return }
                window.setContentShown(self.isContentWanted, duration: Self.fadeInDuration)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func close(_ window: CanvasWindow) {
        let id = ObjectIdentifier(window)
        pendingReveal.remove(id)
        createdAt[id] = nil
        windows.removeAll { $0 === window }
        activeWindows.removeAll { $0 === window }
        window.orderOut(nil)
        window.close()
    }
}
