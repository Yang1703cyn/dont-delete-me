// Overlay · 显示刷新时钟
//
// 需要连续出帧时，跟着显示器的刷新节拍回调（不超过每秒 60 次）；不需要时完全停掉，不占任何开销。
// "什么时候需要"由 FrameScheduler 决定，这里只管把节拍送到。

import AppKit
import DDMCore
import QuartzCore

@MainActor
final class FrameClock: NSObject {
    /// 节拍从哪来。
    enum Source: String, Sendable {
        /// 没在走。
        case stopped
        /// 显示器的刷新回调。
        case displayRefresh
        /// 备用的定时器：显示刷新回调迟迟不来时顶上（见 `watchdogFired`）。
        case timer
    }

    /// 每秒最多出多少帧。内屏最高 120、外接屏常见 144，脸的动画用不着那么密，封顶 60 省一半电。
    static let maxFramesPerSecond = 60

    /// 显示刷新回调这么久没来（正常是每 1/60 秒一次，这相当于连丢三四次），就改用备用定时器。
    /// 实测：亮屏未解锁时回调偶尔会停一下；阈值定得短，停顿就不至于被看出来。
    static let stallThreshold: TimeInterval = 0.06

    /// 每个节拍回调一次（主线程）。
    var onTick: (@MainActor () -> Void)?

    private(set) var source: Source = .stopped

    private var link: CADisplayLink?
    private var linkDisplay: DisplayID?
    private var targetDisplay: DisplayInfo?
    private var fallbackTimer: Timer?
    private var watchdog: Timer?
    private var lastLinkTick: TimeInterval = 0
    /// 上一次运行时显示刷新回调是不是停着的。是的话，下次一开始就让备用定时器顶上，不必再等看门狗发现。
    private var isLinkStalled = false
    private var isRunning = false

    /// 跟着哪块屏的刷新节拍走（通常是正在显示脸的那块）。传 nil 表示没有可用的屏。
    func setDisplay(_ display: DisplayInfo?) {
        targetDisplay = display
        guard display?.id != linkDisplay || link == nil else { return }
        dropLink()
        if isRunning { startTicking() }
    }

    /// 开始 / 停止送节拍。停止后不再有任何回调和定时器。
    func setRunning(_ running: Bool) {
        guard running != isRunning else { return }
        isRunning = running
        if running {
            startTicking()
        } else {
            link?.isPaused = true
            stopTimers()
            source = .stopped
        }
    }

    /// 彻底拆掉（停止运行时调用）。
    func invalidate() {
        isRunning = false
        dropLink()
        stopTimers()
        source = .stopped
    }

    // MARK: - 内部

    private func startTicking() {
        lastLinkTick = ProcessInfo.processInfo.systemUptime
        if link == nil, let display = targetDisplay, let screen = display.screen {
            let target = DisplayLinkTarget()
            target.clock = self
            let link = screen.displayLink(target: target, selector: #selector(DisplayLinkTarget.fired(_:)))
            let rate = Float(Self.maxFramesPerSecond)
            // 屏的刷新率不是 60 的整数倍时（例如 144），系统会在这个范围里挑一个它给得出的档位。
            link.preferredFrameRateRange = CAFrameRateRange(minimum: rate * 0.8, maximum: rate * 1.2, preferred: rate)
            // .common：菜单展开、拖动期间也照常出帧。
            link.add(to: .main, forMode: .common)
            self.link = link
            linkDisplay = display.id
        }
        if let link {
            link.isPaused = false
            source = .displayRefresh
            startWatchdog()
            if isLinkStalled { startFallbackTimer() }
        } else {
            startFallbackTimer()
        }
    }

    fileprivate func linkFired() {
        guard isRunning else { return }
        lastLinkTick = ProcessInfo.processInfo.systemUptime
        isLinkStalled = false
        if fallbackTimer != nil {
            // 显示刷新回调恢复了，备用定时器退下。
            fallbackTimer?.invalidate()
            fallbackTimer = nil
            source = .displayRefresh
        }
        onTick?()
    }

    /// 看门狗：显示刷新回调可能悄悄停掉（所跟的屏睡了、被拔了、合上了盖子）。
    /// 帧循环不能因此卡死，所以隔一会儿看一眼，停了就让备用定时器顶上。
    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = Timer(timeInterval: Self.stallThreshold / 2, repeats: true) { [weak self] timer in
            guard self != nil else { return timer.invalidate() }
            MainActor.assumeIsolated { self?.watchdogFired() }
        }
        timer.tolerance = Self.stallThreshold / 8
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func watchdogFired() {
        guard isRunning, fallbackTimer == nil else { return }
        if ProcessInfo.processInfo.systemUptime - lastLinkTick > Self.stallThreshold {
            isLinkStalled = true
            startFallbackTimer()
        }
    }

    private func startFallbackTimer() {
        guard fallbackTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / Double(Self.maxFramesPerSecond), repeats: true) { [weak self] timer in
            guard self != nil else { return timer.invalidate() }
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.onTick?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
        source = .timer
    }

    private func stopTimers() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        watchdog?.invalidate()
        watchdog = nil
    }

    private func dropLink() {
        link?.invalidate()
        link = nil
        linkDisplay = nil
        isLinkStalled = false
    }
}

/// 显示刷新回调的接收者。
///
/// 系统的显示刷新回调会一直拿着它的接收者不放。让它拿着这个小对象而不是时钟本身，
/// 时钟（以及拥有它的叠加层）就算没被显式停止也能正常释放——释放之后，回调在下一个节拍自己注销。
@MainActor
private final class DisplayLinkTarget: NSObject {
    weak var clock: FrameClock?

    @objc func fired(_ link: CADisplayLink) {
        guard let clock else {
            link.invalidate()
            return
        }
        clock.linkFired()
    }
}
