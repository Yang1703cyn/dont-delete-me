// Overlay · 模块入口
//
// 应用以 `OverlayHost()` 构造它。它实现 `OverlayHosting`（docs/接口约定.md §7）：
//   - 桌面层：每块屏上、紧贴在访达图标之上的透明点击穿透窗口；
//   - 拖拽层：只在有拖拽项时出现的最上层透明点击穿透窗口；
//   - 帧循环：按省电信号决定连续出帧、定时醒一次还是休息；没变化就不重画；
//   - 自己跟随暂停开关和系统状态（空间、全屏、图标被隐藏、锁屏、睡眠、显示器变化）。
//
// 文件分工：
//   CanvasGeometry / ItemRasterizer   坐标换算、画布（纯逻辑）
//   ScenePlanner                      "没变化就不重画"的判定（纯逻辑）
//   FrameScheduler / FrameClock       什么时候出帧 / 显示刷新节拍
//   DesktopVisibility / SystemProbe   桌面看不看得见（纯逻辑） / 向系统打听
//   CanvasWindow / DisplayStage       叠加窗口 / 一块屏上的一层画布
//   OverlayHost（本文件）              把它们串起来
//
// 设计依据和实测数据见 docs/模块说明/overlay.md。

import AppKit
import DDMCore
import Foundation

@MainActor
public final class OverlayHost: OverlayHosting {
    public weak var frameSource: (any OverlayFrameSource)? {
        didSet { if frameSource != nil { requestFrame() } }
    }

    public private(set) var isDesktopVisible = false
    public var onDesktopVisibilityChange: (@MainActor (Bool) -> Void)?

    /// 桌面露在外面时，每隔这么久看一眼系统窗口列表（图标有没有被隐藏）。一次约 0.5 毫秒。
    static let livePollInterval: TimeInterval = 1
    /// 桌面被窗口完全挡住、或停在全屏空间时，巡检间隔拉长（这些状态结束时都有系统通知，巡检只是保险）。
    static let coveredPollInterval: TimeInterval = 10
    /// 锁屏、睡眠期间只读"是否锁屏、屏幕是否睡着"这两个极便宜的状态（约 0.06 毫秒），
    /// 为的是万一漏了解锁 / 唤醒的通知，脸也能在两秒内回来。
    static let dormantPollInterval: TimeInterval = 2

    private let pause: PauseSwitch
    private let options: OverlayOptions
    private let layoutProvider: @MainActor () -> DisplayLayout

    private let clock = FrameClock()
    private let monitor = SystemEventMonitor()
    private var scheduler = FrameScheduler()
    private var pauseObservation: PauseObservation?

    private var layout = DisplayLayout(displays: [])
    private var desktopStages: [DisplayID: DisplayStage] = [:]
    private var dragStages: [DisplayID: DisplayStage] = [:]

    private var session = SessionState.live
    private var isSystemAsleep = false
    /// 收到"电脑要睡了"的时刻。之后只要又清醒地跑了几秒，就说明已经醒了——即使漏了"醒了"的通知。
    private var systemSleepNotedAt: TimeInterval = 0
    /// 切换空间之后过多久复查一次。
    static let spaceRecheckDelay: TimeInterval = 1
    private var tracker = IconLayerTracker()
    private var iconStates: [DisplayID: IconLayerState] = [:]
    private var visibleDisplays: Set<DisplayID> = []
    /// 系统的"窗口被挡住"报告是否可信：只有亲眼见过它报告"没被挡住"之后才采信"被挡住"。
    /// 这样即便某个系统版本上这份报告对我们的窗口不起作用，后果也只是多费点电，而不是永远不画。
    private var isOcclusionTrusted = false

    private var pollTimer: Timer?
    private var pollInterval: TimeInterval = 0
    private var spaceRecheckTimer: Timer?
    private var confirmTimer: Timer?
    private var wakeTimer: Timer?
    private var wakeDeadline: TimeInterval?

    private var isRunning = false
    /// 启动（或显示器布局变化）后是否已经完整地读过一遍系统状态。
    private var hasFullyRefreshed = false
    private var isInFrame = false
    private var frameRequestedDuringFrame = false
    private var frameCount = 0
    private var drawCount = 0

    /// - Parameters:
    ///   - pause: 暂停开关。应用里用全局那一个；测试里传自己的。
    ///   - options: 可调选项，默认值适合应用。
    ///   - layoutProvider: 怎么读显示器布局。默认读系统的；演示和测试可以换成假的，模拟显示器变化。
    public init(
        pause: PauseSwitch = .shared,
        options: OverlayOptions = OverlayOptions(),
        layoutProvider: (@MainActor () -> DisplayLayout)? = nil
    ) {
        self.pause = pause
        self.options = options
        self.layoutProvider = layoutProvider ?? { DisplayLayout.current() }
    }

    // MARK: - OverlayHosting

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        isSystemAsleep = false

        layout = layoutProvider()
        rebuildStages()

        clock.onTick = { [weak self] in self?.clockTicked() }
        monitor.onEvent = { [weak self] event in self?.handle(event) }
        monitor.start()
        pauseObservation = pause.addObserver { [weak self] paused in self?.pauseChanged(paused) }

        refreshSystemState()
        requestFrame()
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false

        pauseObservation?.cancel()
        pauseObservation = nil
        monitor.stop()
        monitor.onEvent = nil
        clock.invalidate()
        clock.onTick = nil
        scheduler.suspend()
        for timer in [pollTimer, confirmTimer, wakeTimer, spaceRecheckTimer] { timer?.invalidate() }
        pollTimer = nil
        pollInterval = 0
        spaceRecheckTimer = nil
        confirmTimer = nil
        wakeTimer = nil
        wakeDeadline = nil

        closeAllStages()
        CanvasBackingPool.shared.drain()
        hasFullyRefreshed = false
        tracker.reset()
        iconStates.removeAll()
        visibleDisplays.removeAll()
        // 停止之后不再回调；只把值归位。
        isDesktopVisible = false
    }

    public func requestFrame() {
        guard isActive else { return }
        if isInFrame {
            frameRequestedDuringFrame = true
            return
        }
        scheduler.requestFrame(now: ProcessInfo.processInfo.systemUptime)
        updateClock()
    }

    // MARK: - 帧循环

    /// 是否在出帧：在运行、没被暂停、桌面看得见。
    private var isActive: Bool {
        isRunning && !pause.isPaused && isDesktopVisible
    }

    private func clockTicked() {
        guard scheduler.shouldRunFrame(onTickAt: ProcessInfo.processInfo.systemUptime) else { return }
        runFrame()
    }

    private func wakeTimerFired() {
        wakeTimer = nil
        wakeDeadline = nil
        guard scheduler.shouldRunFrame(onTimerAt: ProcessInfo.processInfo.systemUptime) else {
            updateClock()
            return
        }
        runFrame()
    }

    private func runFrame() {
        // 帧回调里又转起了主循环、节拍再次进来：这一下不出帧，也不动调度状态。
        guard !isInFrame else { return }
        guard isActive, let source = frameSource else {
            scheduler.suspend()
            updateClock()
            return
        }

        isInFrame = true
        // 帧时间取"此刻"，不取显示刷新的目标时刻——约定要求帧时间不得超前。
        let time = FrameTime.now()
        let frame = source.overlayFrame(at: time)
        frameCount += 1
        // 调用方可能就在这次回调里暂停或停止了我们：那就不画了。
        if isActive {
            render(frame.items, at: time, source: source)
        }
        isInFrame = false

        scheduler.frameFinished(demand: frame.demand, now: time.monotonic)
        if frameRequestedDuringFrame {
            frameRequestedDuringFrame = false
            scheduler.requestFrame(now: ProcessInfo.processInfo.systemUptime)
        }
        // 帧回调里调用方可能暂停或停止了我们。
        guard isActive else {
            scheduler.suspend()
            updateClock()
            return
        }
        if !scheduler.needsRefreshTicks {
            // 空下来了：顺手把别的空间里的窗口也更新到最新。
            for stage in desktopStages.values { stage.syncStaleWindows() }
        }
        updateClock()
    }

    private func render(_ items: [OverlayItem], at time: FrameTime, source: any OverlayFrameSource) {
        var desktopItems: [OverlayItem] = []
        var dragItems: [OverlayItem] = []
        desktopItems.reserveCapacity(items.count)
        for item in items {
            switch item.layer {
            case .desktop: desktopItems.append(item)
            case .drag: dragItems.append(item)
            }
        }

        let draw: (OverlayItem, CGContext) -> Void = { item, context in
            source.drawOverlayItem(item, in: context, at: time)
        }
        // 绘制回调里调用方可能暂停或停止我们：之后剩下的项不再画，也不再显示任何窗口。
        let shouldStop: () -> Bool = { [unowned self] in !self.isActive }
        for display in layout.displays {
            guard isActive else { break }
            if let stage = desktopStages[display.id] {
                drawCount += stage.render(
                    items: desktopItems, canDraw: visibleDisplays.contains(display.id),
                    shouldStop: shouldStop, draw: draw
                )
            }
            // 拖拽层的窗口用到时才建：这一帧有拖拽项落在这块屏上。
            if dragStages[display.id] == nil,
               dragItems.contains(where: { CanvasGeometry.placement(for: $0.canvasRect, on: display) != nil }) {
                dragStages[display.id] = makeStage(.drag, on: display)
            }
            if let stage = dragStages[display.id] {
                drawCount += stage.render(items: dragItems, canDraw: true, shouldStop: shouldStop, draw: draw)
            }
        }
    }

    /// 让显示刷新回调和定时器与调度状态一致。
    private func updateClock() {
        clock.setRunning(isRunning && scheduler.needsRefreshTicks)

        let deadline = isRunning ? scheduler.timerDeadline : nil
        guard deadline != wakeDeadline else { return }
        wakeTimer?.invalidate()
        wakeTimer = nil
        wakeDeadline = deadline
        guard let deadline else { return }
        // 多留半毫秒：定时器按墙上时间走，略早于单调时钟上的那个时刻就白响一次。
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime) + 0.0005
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.wakeTimerFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        wakeTimer = timer
    }

    // MARK: - 暂停

    private func pauseChanged(_ paused: Bool) {
        guard isRunning else { return }
        if paused {
            // 暂停：停止帧回调，所有内容隐藏，拖拽层收起。窗口留着，恢复时不必重建。
            scheduler.suspend()
            updateClock()
            for stage in desktopStages.values { stage.setContentWanted(false, animated: true) }
            for stage in dragStages.values { stage.hideDragWindow() }
            updatePolling()
        } else {
            // 恢复：完整地重新读一遍系统状态（暂停期间没有跟踪），重新显示并出一帧。
            isSystemAsleep = false
            hasFullyRefreshed = false
            refreshSystemState()
            requestFrame()
        }
    }

    // MARK: - 系统状态

    private func handle(_ event: SystemEvent) {
        guard isRunning else { return }
        if event == .screenParametersChanged {
            displayConfigurationChanged()
            return
        }
        // 暂停期间不跟踪系统状态（省电）；恢复时会整体重读。
        guard !pause.isPaused else { return }
        refreshSystemState(after: event)
    }

    /// 显示器插拔、分辨率或排列变了：按新布局重建全部窗口，下一帧所有画布项重画。
    private func displayConfigurationChanged() {
        let newLayout = layoutProvider()
        guard newLayout != layout else {
            if !pause.isPaused { refreshSystemState() }
            return
        }
        layout = newLayout
        rebuildStages()
        hasFullyRefreshed = false
        tracker.reset()
        iconStates.removeAll()
        visibleDisplays.removeAll()
        refreshSystemState()
        requestFrame()
    }

    /// 重新读取系统状态，更新窗口、内容显隐和"桌面是否可见"。
    /// - Parameter event: 触发这次读取的事件。事件刚发生时系统的状态查询可能还没跟上，所以以事件为准。
    private func refreshSystemState(after event: SystemEvent? = nil) {
        guard isRunning else { return }
        let now = ProcessInfo.processInfo.systemUptime

        // 1. 会话：锁屏、睡眠、是否在前台。
        if options.assumesAlwaysVisible {
            session = .live
        } else {
            var state = SystemProbe.sessionState()
            if isSystemAsleep, event != .systemWillSleep, now - systemSleepNotedAt > 5 {
                // 这个时钟在电脑睡着时不走。收到"要睡了"之后又清醒地过了 5 秒，说明已经醒了。
                isSystemAsleep = false
            }
            switch event {
            case .systemWillSleep:
                isSystemAsleep = true
                systemSleepNotedAt = now
            case .systemDidWake: isSystemAsleep = false
            case .screenLocked: state.isScreenLocked = true
            case .screenUnlocked: state.isScreenLocked = false
            case .displaysSlept: state.areDisplaysAsleep = true
            case .displaysWoke: state.areDisplaysAsleep = false
            case .sessionResigned: state.isOnConsole = false
            case .sessionBecameActive: state.isOnConsole = true
            default: break
            }
            state.isSystemAsleep = isSystemAsleep
            let stillDormant = !state.isLive && !session.isLive
            session = state
            if stillDormant, event == nil, hasFullyRefreshed {
                // 锁屏 / 睡眠期间的例行巡检，什么都没变：到此为止，不去查窗口列表。
                return
            }
        }
        hasFullyRefreshed = true

        // 2. 每块屏的图标层：在不在、有没有被系统遮住。
        // 3. 窗口：当前空间里没有就建一个。全屏应用的空间里没有图标层，不建。
        // 启动时、每次状态变化时都照做，锁屏和睡眠期间也不例外：窗口提前备好，解锁的一瞬间脸就在。
        if options.assumesAlwaysVisible {
            for display in layout.displays {
                iconStates[display.id] = .visible
                desktopStages[display.id]?.reconcileWindows(allowCreate: true, now: now, trigger: .assumeActive)
            }
        } else {
            let observed = observeIconLayers()
            let recheckAt = tracker.ingest(observed, at: now)
            scheduleConfirmation(at: recheckAt, now: now)
            let isSpaceEvent = event == .spaceChanged || event == .spaceSettled
            for display in layout.displays {
                iconStates[display.id] = tracker.state(for: display.id)
                desktopStages[display.id]?.reconcileWindows(
                    allowCreate: observed[display.id] != .absent, now: now,
                    trigger: isSpaceEvent ? .spaceChange : .routine
                )
            }
            if isSpaceEvent {
                // 刚换了空间：让这个空间里原有的窗口立刻跟上最新内容。
                for stage in desktopStages.values { stage.syncStaleWindows() }
            }
            if event == .spaceChanged {
                scheduleSpaceRecheck()
            }
        }

        // 4. 内容显隐：图标看不见（或应用被暂停）时，脸也藏起来。
        for display in layout.displays {
            let wanted = !pause.isPaused && iconStates[display.id] == .visible
            desktopStages[display.id]?.setContentWanted(wanted, animated: true)
        }

        // 5. 结论。
        var visible = Set<DisplayID>()
        for display in layout.displays {
            guard let stage = desktopStages[display.id] else { continue }
            if options.assumesAlwaysVisible {
                visible.insert(display.id)
                continue
            }
            let unoccluded = stage.isUnoccluded
            if unoccluded { isOcclusionTrusted = true }
            let signals = StageSignals(
                iconLayer: iconStates[display.id] ?? .absent,
                hasWindowOnActiveSpace: stage.hasWindowOnActiveSpace,
                isOccluded: isOcclusionTrusted && !unoccluded
            )
            if VisibilityModel.isStageVisible(signals, session: session) {
                visible.insert(display.id)
            }
        }
        let newlyVisible = !visible.isSubset(of: visibleDisplays)
        visibleDisplays = visible

        // 节拍跟着"正在显示脸的那块屏"走。
        clock.setDisplay(layout.displays.first { visible.contains($0.id) } ?? layout.primary)
        setDesktopVisible(!visible.isEmpty)
        if newlyVisible {
            // 有屏刚变得看得见：补上它欠着的重画。
            requestFrame()
        }
        updatePolling()
    }

    /// 看一眼系统的窗口列表，得出每块屏上图标层的状态。
    private func observeIconLayers() -> [DisplayID: IconLayerState] {
        let entries = SystemProbe.onScreenWindows()
        let finderPID = SystemProbe.finderPID()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var observed: [DisplayID: IconLayerState] = [:]
        for display in layout.displays {
            var state = IconLayerAnalysis.state(
                on: display, entries: entries, finderPID: finderPID, ownPID: ownPID,
                iconLevel: SystemProbe.desktopIconLevel
            )
            if state == .shielded, !options.treatsDesktopShieldAsHidden { state = .visible }
            observed[display.id] = state
        }
        return observed
    }

    private func setDesktopVisible(_ visible: Bool) {
        guard visible != isDesktopVisible else { return }
        isDesktopVisible = visible
        if !visible {
            scheduler.suspend()
            updateClock()
            for stage in dragStages.values { stage.hideDragWindow() }
        }
        onDesktopVisibilityChange?(visible)
        if visible { requestFrame() }
    }

    /// 切换空间一秒之后再核对一次窗口。切换那一刻系统对"窗口在不在当前空间"的回答可能还没跟上；
    /// 用户也可能紧接着又切了一次。连续切换时只保留最后一次约的复查。
    private func scheduleSpaceRecheck() {
        spaceRecheckTimer?.invalidate()
        let timer = Timer(timeInterval: Self.spaceRecheckDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, !self.pause.isPaused else { return }
                self.spaceRecheckTimer = nil
                self.refreshSystemState(after: .spaceSettled)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        spaceRecheckTimer = timer
    }

    /// "图标层看得见"要过一小会儿再确认一次才作数（见 IconLayerTracker）。
    private func scheduleConfirmation(at deadline: TimeInterval?, now: TimeInterval) {
        confirmTimer?.invalidate()
        confirmTimer = nil
        guard let deadline else { return }
        let timer = Timer(timeInterval: max(0.01, deadline - now + 0.01), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, !self.pause.isPaused else { return }
                self.confirmTimer = nil
                self.refreshSystemState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        confirmTimer = timer
    }

    /// 定时巡检：系统隐藏 / 显示桌面图标没有任何通知，只能隔一会儿看一眼窗口列表。
    /// - 暂停时不巡检；
    /// - 桌面露在外面（会话在线，且至少有一块屏的桌面层窗口没被完全挡住）时每秒看一眼；
    /// - 桌面被窗口完全挡住、停在全屏空间时拉长到 10 秒；
    /// - 锁屏、睡眠期间每 2 秒只读一下"是否锁屏、屏幕是否睡着"。
    ///   后两种状态结束时都有系统通知，巡检只是保险：万一漏了通知也能恢复。
    private func updatePolling() {
        let interval: TimeInterval
        if !isRunning || pause.isPaused || options.assumesAlwaysVisible {
            interval = 0
        } else {
            let isDesktopExposed = session.isLive && desktopStages.values.contains { stage in
                stage.hasWindowOnActiveSpace && !(isOcclusionTrusted && !stage.isUnoccluded)
            }
            if !session.isLive {
                interval = Self.dormantPollInterval
            } else {
                interval = isDesktopExposed ? Self.livePollInterval : Self.coveredPollInterval
            }
        }
        guard interval != pollInterval else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        pollInterval = interval
        guard interval > 0 else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            // 宿主没停止就被释放了：定时器自己注销。
            guard self != nil else { return timer.invalidate() }
            MainActor.assumeIsolated { self?.refreshSystemState() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    // MARK: - 窗口

    private func rebuildStages() {
        closeAllStages()
        for display in layout.displays {
            desktopStages[display.id] = makeStage(.desktop, on: display)
        }
    }

    private func makeStage(_ kind: DisplayStage.Kind, on display: DisplayInfo) -> DisplayStage {
        DisplayStage(
            kind: kind,
            display: display,
            appKitFrame: layout.appKitRect(fromGlobal: display.frame),
            maxWindows: kind == .desktop ? options.maxDesktopWindowsPerDisplay : 1
        )
    }

    private func closeAllStages() {
        for stage in desktopStages.values { stage.closeAll() }
        for stage in dragStages.values { stage.closeAll() }
        desktopStages.removeAll()
        dragStages.removeAll()
    }
}

// MARK: - 运行状态快照与自检

extension OverlayHost {
    /// 运行状态的快照。给演示程序、自检和排查问题用。
    public var diagnostics: OverlayDiagnostics {
        let displays = layout.displays.map { display -> OverlayDiagnostics.Display in
            let desktop = desktopStages[display.id]
            let drag = dragStages[display.id]
            let unoccluded = desktop?.isUnoccluded ?? false
            return OverlayDiagnostics.Display(
                id: display.id,
                frame: display.frame,
                scale: display.scale,
                iconLayer: (iconStates[display.id] ?? .absent).rawValue,
                desktopWindowCount: desktop?.windowCounts.total ?? 0,
                hasWindowOnActiveSpace: desktop?.hasWindowOnActiveSpace ?? false,
                isOccluded: isOcclusionTrusted && !unoccluded,
                isVisible: visibleDisplays.contains(display.id),
                desktopItemCount: desktop?.itemCount ?? 0,
                dragItemCount: drag?.itemCount ?? 0,
                isDragWindowShown: drag?.isDragWindowShown ?? false,
                desktopWindowNumbers: desktop?.windowNumbers ?? [],
                dragWindowNumbers: drag?.windowNumbers ?? [],
                allWindowsIgnoreMouse: (desktop?.allWindowsIgnoreMouse ?? true) && (drag?.allWindowsIgnoreMouse ?? true)
            )
        }
        let loop: String
        switch scheduler.wake {
        case .everyRefresh: loop = "every-refresh"
        case .refresh: loop = "next-refresh"
        case .timer: loop = "timer"
        case .sleep: loop = "sleep"
        }
        return OverlayDiagnostics(
            displays: displays,
            isRunning: isRunning,
            isPaused: pause.isPaused,
            isScreenLocked: session.isScreenLocked,
            areDisplaysAsleep: session.areDisplaysAsleep,
            isSessionOnConsole: session.isOnConsole,
            isDesktopVisible: isDesktopVisible,
            frameLoop: loop,
            clockSource: clock.source.rawValue,
            frameCount: frameCount,
            drawCount: drawCount,
            desktopWindowLevel: SystemProbe.desktopIconLevel + 1,
            dragWindowLevel: SystemProbe.draggingLevel + 1
        )
    }

    /// 自检用：叠加窗口里某一点实际渲染出来的颜色。那一点不在任何屏上、或那块屏上没有窗口时为 nil。
    /// 它把窗口的图层树画到离屏位图上再读像素——不截屏，也不依赖屏幕是否亮着。
    public func debugRenderedPixel(at globalPoint: CGPoint, layer: OverlayLayer) -> OverlayDebugPixel? {
        guard let display = layout.display(containing: globalPoint) else { return nil }
        let stage = layer == .desktop ? desktopStages[display.id] : dragStages[display.id]
        return stage?.renderedPixel(atLocalPoint: display.localPoint(fromGlobal: globalPoint))
    }
}
