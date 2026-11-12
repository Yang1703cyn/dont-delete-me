// 占位，由 overlay 子对话替换。
//
// 模块入口：应用以 `OverlayHost()` 构造它——请保留这个类型名和无参构造方式
// （可以增加带默认值的参数），内部实现和文件组织随意。
// 要实现的协议与约定见 docs/接口约定.md 第 7 节。
//
// 占位行为：不创建任何窗口、什么都不画；只用一个普通定时器按 `FrameDemand` 回调帧，
// 让整条数据流从第一天起就能空转。真正的实现要换成与显示刷新同步的帧循环。

import DDMCore
import Foundation

@MainActor
public final class OverlayHost: OverlayHosting {
    public weak var frameSource: (any OverlayFrameSource)?
    public private(set) var isDesktopVisible = true
    public var onDesktopVisibilityChange: (@MainActor (Bool) -> Void)?

    private let pause: PauseSwitch
    private var pauseObservation: PauseObservation?
    private var timer: Timer?
    private var isRunning = false

    public init(pause: PauseSwitch = .shared) {
        self.pause = pause
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        pauseObservation = pause.addObserver { [weak self] paused in
            if paused {
                self?.cancelTimer()
            } else {
                self?.requestFrame()
            }
        }
        requestFrame()
    }

    public func stop() {
        isRunning = false
        pauseObservation?.cancel()
        pauseObservation = nil
        cancelTimer()
    }

    public func requestFrame() {
        guard isRunning, !pause.isPaused else { return }
        schedule(after: 0)
    }

    private func runFrame() {
        guard isRunning, !pause.isPaused, let frameSource else { return }
        let time = FrameTime.now()
        let frame = frameSource.overlayFrame(at: time)
        // 占位：frame.items 被直接丢弃——没有窗口，也就不会回调 drawOverlayItem。
        switch frame.demand {
        case .continuous:
            schedule(after: 1.0 / 60)
        case let .by(deadline):
            schedule(after: max(0, deadline - time.monotonic))
        case .idle:
            break
        }
    }

    private func schedule(after delay: TimeInterval) {
        cancelTimer()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.runFrame() }
        }
        // .common：菜单展开期间也照常出帧。
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func cancelTimer() {
        timer?.invalidate()
        timer = nil
    }
}
