// IconBridge · 模块入口：图标提供者
//
// 应用以 `DesktopIconProvider()` 构造它。协议与约定见 docs/接口约定.md 第 2 节；
// 本模块的结论、已知限制和集成注意事项见 docs/模块说明/icon-bridge.md。
//
// 分工：
//   - 这个类运行在主线程，只做调度：什么时候读、读哪一种、结果怎么上报。所有方法立即返回。
//   - 真正向访达发请求、比对变化的是 `BridgeCore`，由 `BridgeEngine` 放在后台队列上执行。
//
// 隐私：本模块只向访达询问（只需要"控制访达"一项授权），不直接读取桌面文件夹；
// 文件名只在模块内部用来区分图标，不写日志、不打印，对外只有不可读的编号。

import DDMCore
import Foundation

/// 一个读取周期的概况，供演示程序和基准测试观察（不含任何图标信息）。
public struct IconBridgeCycleReport: Sendable, Equatable {
    /// 是否做了完整读取；false 表示只是数了数个数、发现没变。
    public var wasFullRead: Bool
    /// 是否由 `refreshNow()` 引发。
    public var wasForced: Bool
    /// 周期开始的时刻（单调时钟，秒）。
    public var startedAt: TimeInterval
    /// 周期耗时（秒）：从开始到所有请求都得到访达的回复。
    public var duration: TimeInterval
    /// 向访达发了几次请求。
    public var requestCount: Int
    /// 是否发现了图标的增减或移动。
    public var foundChanges: Bool
    /// 这个周期里，请求被访达卡住（等了很久才有回答，或等到超时也没有回答）的时间（秒）。平时为 0。
    public var stalledSeconds: TimeInterval
    /// 访达这一轮没空回答（典型情形：用户正拖着图标）。快照原样保留，图标桥会继续等。
    public var finderWasBusy: Bool
}

@MainActor
public final class DesktopIconProvider: IconProviding {
    public private(set) var snapshot: IconSnapshot = .empty()
    public var onUpdate: (@MainActor (IconUpdate) -> Void)?

    /// 每个读取周期结束时回调一次（主线程），包括没有任何变化、不触发 `onUpdate` 的周期。只用于观察开销。
    public var onCycle: (@MainActor (IconBridgeCycleReport) -> Void)?

    private let engine: BridgeEngine
    private let pause: PauseSwitch
    private let clock: @Sendable () -> TimeInterval
    private var schedule: PollSchedule

    private var isRunning = false
    /// 每次 start() / stop() 加一；读取结果回来时对不上就丢弃——这就是"取消未完成的读取"。
    private var generation: UInt64 = 0
    private var pace: IconPollingPace = .active
    private var pauseObservation: PauseObservation?

    /// 有一次读取正在后台进行。
    private var isReading = false
    /// 读取进行期间又收到了 refreshNow()：这次读完之后要再读一次。
    private var refreshPending = false
    /// 最近一次"读取进行期间收到 refreshNow()"的时刻。
    private var refreshRequestedAt: TimeInterval = 0
    /// 已经排好了一次由 refreshNow() 引发、稍后开始的读取。
    private var forcedReadIsScheduled = false
    private var lastForcedStart: TimeInterval = -.infinity
    /// 下一次读取要带上的标记。
    private var restartPending = false
    private var resumePending = false
    /// 上一次检查时是否处于"停止读取"。
    private var wasSuspended = false
    private var timer: Task<Void, Never>?

    // MARK: 构造

    /// - Parameters:
    ///   - pause: 全局暂停开关。暂停期间不向访达读取。
    ///   - identityStorage: 图标编号用的盐存在哪里。应用用默认值（存进偏好设置，编号跨启动不变）；
    ///     演示程序用 `.ephemeral`（不落盘）。
    ///   - displayLayout: 怎样取当前的显示器布局。默认 `DisplayLayout.current()`。
    public convenience init(
        pause: PauseSwitch = .shared,
        identityStorage: IconIdentityStorage = .persistent,
        displayLayout: (@Sendable () -> DisplayLayout)? = nil
    ) {
        let core = BridgeCore(
            source: FinderDesktopSource(),
            identity: IconIdentity(salt: identityStorage.loadSalt()),
            layoutProvider: displayLayout ?? { DisplayLayout.current() }
        )
        self.init(pause: pause, core: core)
    }

    /// 测试用：注入假的桌面和节奏参数。
    init(
        pause: PauseSwitch,
        core: BridgeCore,
        policy: PollingPolicy = PollingPolicy(),
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.pause = pause
        self.engine = BridgeEngine(core: core)
        self.schedule = PollSchedule(policy: policy)
        self.clock = clock
    }

    deinit {
        // 没有 stop() 就被释放时，把登记在暂停开关上的观察和还在等的定时任务收掉。
        pauseObservation?.cancel()
        timer?.cancel()
    }

    // MARK: IconProviding

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        generation &+= 1
        // 回到"启动中"的空快照；版本号接着往上数，重新启动前后的快照不会碰巧同号。
        snapshot = IconSnapshot(icons: [], status: .starting, capturedAt: 0, revision: snapshot.revision)
        schedule.reset()
        isReading = false
        refreshPending = false
        forcedReadIsScheduled = false
        restartPending = true
        resumePending = false
        pauseObservation = pause.addObserver { [weak self] _ in
            self?.suspensionMayHaveChanged()
        }
        wasSuspended = isSuspended
        if !wasSuspended {
            beginCycle(.full, forced: false)
        }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        generation &+= 1
        cancelTimer()
        pauseObservation?.cancel()
        pauseObservation = nil
        isReading = false
        refreshPending = false
        forcedReadIsScheduled = false
    }

    public func refreshNow() {
        // 先对一下"是否处于停止读取"：如果暂停开关刚刚解除、而我们的观察回调还没轮到，
        // 这里就要先把"恢复后的第一次读取是整体重载"记上，再发起读取。
        suspensionMayHaveChanged()
        // 停止读取期间（应用暂停、桌面看不见）不读：此时没有帧，也没有人等这个结果。
        guard isRunning, !isSuspended else { return }
        if isReading {
            refreshPending = true
            refreshRequestedAt = clock()
        } else if !forcedReadIsScheduled {
            startForcedRead()
        }
    }

    public func setPollingPace(_ pace: IconPollingPace) {
        guard pace != self.pace else { return }
        self.pace = pace
        suspensionMayHaveChanged()
        // 活跃 ↔ 空闲：按新的节奏重排下一次读取。
        if isRunning, !isSuspended, !isReading, !forcedReadIsScheduled {
            scheduleNextCycle()
        }
    }

    // MARK: 暂停与恢复

    /// 应用要求停止读取，或全局暂停开关处于暂停。
    private var isSuspended: Bool {
        pace == .suspended || pause.isPaused
    }

    private func suspensionMayHaveChanged() {
        guard isRunning else { return }
        let suspended = isSuspended
        guard suspended != wasSuspended else { return }
        wasSuspended = suspended
        if suspended {
            cancelTimer()
            refreshPending = false
            forcedReadIsScheduled = false
        } else {
            // 恢复后的第一次读取按"整体重载"上报。
            resumePending = true
            if !isReading {
                beginCycle(.full, forced: false)
            }
        }
    }

    // MARK: 读取周期

    private func beginCycle(_ kind: CycleKind, forced: Bool) {
        cancelTimer()
        forcedReadIsScheduled = false
        isReading = true
        if forced {
            lastForcedStart = clock()
        }
        let request = CycleRequest(kind: forced ? .full : kind, forced: forced, resumed: resumePending, restart: restartPending)
        resumePending = false
        restartPending = false
        let generation = generation
        Task { [weak self, engine] in
            // 这里让出主线程：读取在图标桥的后台队列上进行，读完再回到主线程。
            let outcome = await engine.run(request)
            self?.finishCycle(outcome, request: request, generation: generation)
        }
    }

    private func finishCycle(_ outcome: CycleOutcome, request: CycleRequest, generation: UInt64) {
        guard isRunning, generation == self.generation else { return }   // 已经 stop()：结果作废
        isReading = false
        onCycle?(IconBridgeCycleReport(
            wasFullRead: outcome.performedFullRead,
            wasForced: request.forced,
            startedAt: outcome.startedAt,
            duration: outcome.duration,
            requestCount: outcome.requestCount,
            foundChanges: outcome.foundChanges,
            stalledSeconds: outcome.stalledSeconds,
            finderWasBusy: outcome.finderWasBusy
        ))
        guard isRunning, generation == self.generation else { return }
        if isSuspended {
            // 读取期间被要求停止：结果不上报。后台的核心已经前进了一步，所以恢复后必须整体重载。
            resumePending = true
            return
        }

        snapshot = outcome.snapshot
        schedule.record(outcome)
        var update = outcome.update
        if refreshPending, outcome.performedFullRead, !outcome.finderWasBusy, !outcome.wasInconsistent,
           outcome.snapshot.capturedAt >= refreshRequestedAt {
            // 这个周期的完整读取是在 refreshNow() 之后才开始的（典型情形：之前的请求被访达卡到松手才回答，
            // 回答之后才开始完整读取）。它已经"不早于那次调用"，不必再读一遍：就用它兑现"读完一定回调"。
            refreshPending = false
            update = update ?? IconUpdate(snapshot: outcome.snapshot)
        }
        if let update {
            onUpdate?(update)
        }
        // 回调里可能调用了 stop() / refreshNow() / setPollingPace()，重新看一眼现状。
        guard isRunning, generation == self.generation, !isSuspended, !isReading else { return }

        if request.forced, outcome.wasInconsistent || outcome.finderWasBusy {
            // refreshNow() 的那次读取没读成（桌面正在变，或访达没空回答）：承诺的"读完回调一次"顺延到重读的那一次。
            refreshPending = true
        }
        if resumePending {
            // 这次读取进行期间经历过"停止读取 → 恢复"：不等下一个定时点，马上补一次整体重载。
            // 期间如果有人调用过 refreshNow()，这一次就顺带兑现"读完一定回调"。
            let forced = refreshPending
            refreshPending = false
            beginCycle(.full, forced: forced)
        } else if refreshPending {
            refreshPending = false
            startForcedRead()
        } else if !forcedReadIsScheduled {
            scheduleNextCycle()
        }
    }

    /// 发起 refreshNow() 的读取：距上一次这样的读取够久就立刻开始，否则排到间隔满足的那一刻。
    private func startForcedRead() {
        let earliest = lastForcedStart + schedule.policy.minForcedSpacing
        if clock() >= earliest {
            beginCycle(.full, forced: true)
        } else {
            forcedReadIsScheduled = true
            setTimer(at: earliest) { provider in
                provider.beginCycle(.full, forced: true)
            }
        }
    }

    private func scheduleNextCycle() {
        guard let next = schedule.next(pace: pace) else { return }
        setTimer(at: next.at) { provider in
            provider.beginCycle(next.kind, forced: false)
        }
    }

    // MARK: 定时

    private func setTimer(at time: TimeInterval, _ action: @escaping @MainActor (DesktopIconProvider) -> Void) {
        cancelTimer()
        let delay = max(0, time - clock())
        timer = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled, let self, self.isRunning, !self.isSuspended, !self.isReading else { return }
            self.timer = nil
            action(self)
        }
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }
}
