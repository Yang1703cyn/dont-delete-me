// 帧流水线：把各模块按 docs/接口约定.md 的数据流接起来。
//
//   图标提供者 ──(onUpdate)──▶ 暂存
//   叠加层每帧回调 overlayFrame(at:) ──▶ 交互感知.update ──▶ 情绪引擎.update ──▶ 画布项清单
//   叠加层判定要重画的项 ──▶ drawOverlayItem ──▶ 表情绘制者.draw
//
// 它只认识 DDMCore 里的协议，不认识任何具体模块（具体类型在 Assembly.swift 里选定），
// 所以可以用假模块做测试（见 Tests/DontDeleteMeTests/）。

import CoreGraphics
import DDMCore
import Foundation

@MainActor
final class FramePipeline: OverlayFrameSource {
    /// 运行计数，供自检和测试观察。
    struct Stats: Equatable {
        /// 帧回调次数。
        var frames = 0
        /// 绘制回调次数。
        var draws = 0
        /// 收到图标提供者上报的次数。
        var iconUpdates = 0
        /// 桌面看不见时收到的帧回调次数。约定是"看不见就不出帧"，所以正常应当一直是 0。
        var framesWhileDesktopHidden = 0
        /// 因为"眼珠几乎没动"而省下的重画次数（见 FaceRedraw.swift）。
        var redrawsSaved = 0
    }

    /// 鼠标静止超过这么久（秒）且没有悬停、拖拽，就让图标提供者放慢读取。
    static let idlePaceThreshold: TimeInterval = 5

    private let icons: any IconProviding
    private let sensor: any InteractionSensing
    private var director: any EmotionDirecting
    private let renderer: any FaceRendering
    private let overlay: any OverlayHosting
    private let pause: PauseSwitch

    /// 一张已经交给叠加层的脸。
    private struct ShownFace {
        /// 表情。绘制回调时用它作画；下一帧用它判断"表情变没变"。
        var state: FaceState
        /// 交给叠加层的内容版本号。
        var version: UInt64
        /// 循环小动画下一次该重画的时刻（单调时钟）；没有循环动画为 nil。
        var redrawAt: TimeInterval?
    }

    /// 两帧之间收到的图标上报，合并后在下一帧一起交给交互感知和情绪引擎。
    private var pendingUpdate: IconUpdate?
    /// 上一帧的每张脸。
    private var shownFaces: [OverlayItem.Key: ShownFace] = [:]
    /// 全局递增的内容版本号。
    private var lastVersion: UInt64 = 0
    private var currentPace: IconPollingPace?
    private var pauseObservation: PauseObservation?
    private var isRunning = false

    private(set) var stats = Stats()

    init(
        icons: any IconProviding,
        sensor: any InteractionSensing,
        director: any EmotionDirecting,
        renderer: any FaceRendering,
        overlay: any OverlayHosting,
        pause: PauseSwitch = .shared
    ) {
        self.icons = icons
        self.sensor = sensor
        self.director = director
        self.renderer = renderer
        self.overlay = overlay
        self.pause = pause
    }

    // MARK: - 启停

    func start() {
        guard !isRunning else { return }
        isRunning = true

        icons.onUpdate = { [weak self] update in self?.receive(update) }
        overlay.frameSource = self
        overlay.onDesktopVisibilityChange = { [weak self] _ in self?.activityChanged() }
        pauseObservation = pause.addObserver { [weak self] _ in self?.activityChanged() }

        setPace(isActive ? .active : .suspended)
        icons.start()
        overlay.start()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        overlay.stop()
        icons.stop()
        pauseObservation?.cancel()
        pauseObservation = nil
        icons.onUpdate = nil
        overlay.onDesktopVisibilityChange = nil
        pendingUpdate = nil
        shownFaces = [:]
        currentPace = nil
    }

    /// 叠加层此刻是否认为桌面看得见。供自检观察。
    var isDesktopVisible: Bool { overlay.isDesktopVisible }

    /// 应用是否"在干活"：没被暂停，而且桌面看得见。
    private var isActive: Bool {
        !pause.isPaused && overlay.isDesktopVisible
    }

    /// 暂停状态或桌面可见性变了。
    private func activityChanged() {
        guard isRunning else { return }
        if isActive {
            // 重新开始干活：之前的判断和情绪都过期了，清掉；马上重读图标、马上出一帧。
            sensor.reset()
            director.reset()
            setPace(.active)
            icons.refreshNow()
            overlay.requestFrame()
        } else {
            setPace(.suspended)
        }
    }

    private func setPace(_ pace: IconPollingPace) {
        guard pace != currentPace else { return }
        currentPace = pace
        icons.setPollingPace(pace)
    }

    // MARK: - 图标上报

    private func receive(_ update: IconUpdate) {
        stats.iconUpdates += 1
        pendingUpdate = pendingUpdate?.merging(update) ?? update
        overlay.requestFrame()
    }

    // MARK: - OverlayFrameSource

    func overlayFrame(at time: FrameTime) -> OverlayFrame {
        stats.frames += 1
        if !overlay.isDesktopVisible {
            stats.framesWhileDesktopHidden += 1
        }

        // 1. 图标：取出两帧之间累积的上报；没有就是"没变化"。
        let iconUpdate = pendingUpdate ?? .unchanged(icons.snapshot)
        pendingUpdate = nil

        // 2. 交互感知：时间 + 图标 → 事实。
        let facts = sensor.update(time: time, icons: iconUpdate)
        if facts.wantsIconRefresh {
            icons.refreshNow()
        }
        let userIsBusy = facts.drag != nil || facts.hover != nil || !facts.releasedDrags.isEmpty
            || facts.mouse.idleDuration < Self.idlePaceThreshold
        setPace(userIsBusy ? .active : .idle)

        // 3. 情绪引擎：图标 + 事实 + 时间 → 要画的脸。
        let output = director.update(EmotionInput(time: time, icons: iconUpdate, facts: facts))

        // 4. 脸 → 画布项。只有两种情况换新的内容版本号（也就是让叠加层重画）：
        //    表情变了；或者表情带循环小动画，而且到了该刷新的时刻。
        var demand = facts.demand.merged(with: output.demand)
        var items: [OverlayItem] = []
        var faces: [OverlayItem.Key: ShownFace] = [:]
        for placement in output.faces {
            let key = OverlayItem.Key(iconID: placement.iconID, layer: placement.layer)
            // 约定同一个（图标，层）一帧最多一张脸；万一重复，只认第一张。
            guard faces[key] == nil else { continue }

            let state = placement.state.isValid ? placement.state : placement.state.clamped()
            let face: ShownFace
            if let shown = shownFaces[key],
               FaceRedraw.looksSame(shown.state, state, iconSize: placement.rect.size),
               !(shown.redrawAt.map { time.monotonic >= $0 } ?? false) {
                // 表情没变（或者只是视线目标挪了一点、眼珠几乎没动），循环动画（如果有）也还没到刷新的时刻：沿用。
                // 沿用的是屏幕上那张图对应的表情，所以下一帧仍然拿它来比——眼珠的偏差不会一点点攒起来。
                if shown.state != state {
                    stats.redrawsSaved += 1
                }
                face = shown
            } else {
                lastVersion += 1
                let interval = renderer.animationInterval(for: state)
                face = ShownFace(
                    state: state,
                    version: lastVersion,
                    redrawAt: interval.map { Self.nextRedraw(after: time.monotonic, every: $0) }
                )
            }
            // 循环动画的下一次刷新也是一种"何时需要下一帧"：间隔为 0 就是连续出帧。
            if let redrawAt = face.redrawAt {
                demand = demand.merged(with: redrawAt <= time.monotonic ? .continuous : .by(redrawAt))
            }

            faces[key] = face
            items.append(OverlayItem(
                iconID: placement.iconID,
                layer: placement.layer,
                rect: placement.rect,
                outsets: renderer.outsets(for: state, iconSize: placement.rect.size),
                contentVersion: face.version
            ))
        }
        shownFaces = faces

        return OverlayFrame(items: items, demand: demand)
    }

    /// 循环小动画下一次该重画的时刻：对齐到间隔的整数倍（严格晚于现在）。
    ///
    /// 不对齐的话，几张同类的脸（比如几个睡着的图标）各自从入睡那一刻起算，叠加层每秒要为它们分别醒好几次；
    /// 对齐之后它们落在同一批时刻上，一次唤醒一起重画。画面只取决于时间（表情绘制是无状态的），所以对齐不改变画面。
    /// 间隔为 0（每帧都要重画）或不是正数时，就是现在。
    static func nextRedraw(after now: TimeInterval, every interval: TimeInterval) -> TimeInterval {
        guard interval > 0, interval.isFinite, now.isFinite else { return now }
        // 加一点余量：浮点误差让"正好在整数倍上"的时刻算成略小于它时，不要只约到几乎同一时刻。
        return (floor(now / interval + 1e-6) + 1) * interval
    }

    func drawOverlayItem(_ item: OverlayItem, in context: CGContext, at time: FrameTime) {
        guard let face = shownFaces[item.key] else { return }
        stats.draws += 1
        renderer.draw(face.state, in: item.rect, context: context, time: time.monotonic)
    }
}
