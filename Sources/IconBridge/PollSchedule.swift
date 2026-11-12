// IconBridge · 轮询节奏（纯逻辑）
//
// 实测（19 个图标，macOS 27；详见 docs/模块说明/icon-bridge.md 的"读取开销"一节）：
//   - 访达隔一阵被问一次，比连着被问贵得多：隔半秒以上问一次"桌面上有几个图标"，访达要花约 20 毫秒 CPU；
//     问一次"每个图标的位置"约 78 毫秒；一次完整读取（位置 + 名字 + 显示选项 + 废纸篓计数）约 140 毫秒。
//   - 开销随图标数量大致线性增长。
// 所以轮询分两档，而且都不能太勤：
//   - 快速检查（便宜）：只数个数，用来发现图标的增减（例如用键盘删除、别的程序往桌面存文件）；
//   - 完整读取（贵）：用来发现移动和改名。隔得很久——用户用鼠标造成的变化，由应用在松开鼠标时调用
//     `refreshNow()` 来及时发现，不靠轮询。
// 两档的间隔都有下限，并且按实测耗时自动拉长，使读取占用的时间比例不超过上限：图标很多的桌面自然读得更稀。

import DDMCore
import Foundation

/// 轮询参数。
struct PollingPolicy: Equatable, Sendable {
    struct Pace: Equatable, Sendable {
        /// 两次快速检查之间至少隔多久（秒）。
        var quickInterval: TimeInterval
        /// 两次完整读取之间至少隔多久（秒）。
        var fullInterval: TimeInterval
        /// 快速检查的耗时最多占多大比例：间隔 ≥ 耗时 ÷ 这个比例。
        var quickDutyLimit: Double
        /// 完整读取的耗时最多占多大比例。
        var fullDutyLimit: Double
        /// 访达不可用、被拒绝授权时，隔多久再试一次（秒）。
        /// （开了叠放时另算：靠那一项设置认出来的，按快速检查的间隔复查——几乎不花开销；
        /// 靠位置认出来的，每次复查都要完整读一遍，按完整读取的间隔。）
        var recoveryInterval: TimeInterval
    }

    /// 用户正在操作：增减约一秒内发现；没有鼠标参与的移动和改名最迟八秒发现。
    /// 19 个图标时访达约占 3.8% 的 CPU（快速检查 2% + 完整读取 1.8%）。
    var active = Pace(quickInterval: 1, fullInterval: 8, quickDutyLimit: 1.0 / 50, fullDutyLimit: 1.0 / 80, recoveryInterval: 1)
    /// 用户有一阵没动了：读得很慢。19 个图标时访达约占 0.9% 的 CPU。
    var idle = Pace(quickInterval: 5, fullInterval: 30, quickDutyLimit: 1.0 / 250, fullDutyLimit: 1.0 / 300, recoveryInterval: 5)

    /// 发现图标有增减或移动之后，追加几次完整读取（相对这次读取结束的延迟，秒）：
    /// 变化往往不是一步到位的（例如新文件先出现、随后才被访达摆到位）。
    var followUpDelays: [TimeInterval] = [0.4, 1.0]
    /// 一次读取因为桌面正在变化而作废后，隔多久重读（秒）。
    var inconsistentRetryDelay: TimeInterval = 0.2
    /// 间隔按耗时拉长时，最多拉到下限的几倍。访达偶尔慢一次（例如正忙着拷贝），不该让轮询停上几分钟。
    var maxStretch: Double = 4
    /// `refreshNow()` 引发的读取，两次开始之间至少隔多久（秒）。
    /// 第一次总是立即开始；应用连续多帧调用时，后续的读取按这个间隔排开，免得让访达连轴转。
    var minForcedSpacing: TimeInterval = 0.15

    func pace(_ pace: IconPollingPace) -> Pace? {
        switch pace {
        case .active: return active
        case .idle: return idle
        case .suspended: return nil
        }
    }
}

/// 记录读取的历史，算出"下一次什么时候读、读哪一种"。
struct PollSchedule: Equatable, Sendable {
    var policy: PollingPolicy

    private var lastCycleStart: TimeInterval?
    private var lastFullStart: TimeInterval?
    /// 最近几次快速检查、常规完整读取的耗时。估计"平时要花多久"时取其中最小的：偶然的一次慢读取不算数。
    private var quickDurations: [TimeInterval] = []
    private var fullDurations: [TimeInterval] = []
    private static let rememberedDurations = 3
    /// 待做的追加读取（绝对时刻，升序）。
    private var followUps: [TimeInterval] = []
    private var status = IconProviderStatus.starting
    /// 上一个周期有没有向访达发请求。
    private var lastCycleAskedFinder = false

    init(policy: PollingPolicy = PollingPolicy()) {
        self.policy = policy
    }

    /// 忘掉历史（重新 `start()` 时）。
    mutating func reset() {
        self = PollSchedule(policy: policy)
    }

    /// 记下一个刚结束的周期。
    mutating func record(_ outcome: CycleOutcome) {
        let end = outcome.startedAt + outcome.duration
        lastCycleStart = outcome.startedAt
        status = outcome.snapshot.status
        lastCycleAskedFinder = outcome.requestCount > 0
        if outcome.performedFullRead {
            lastFullStart = outcome.startedAt
            if outcome.wasRoutineRead {
                Self.remember(outcome.duration, in: &fullDurations)
            }
            // 这次完整读取已经顶替了到期的追加读取。
            followUps.removeAll { $0 <= end }
        } else {
            Self.remember(outcome.duration, in: &quickDurations)
        }
        if outcome.foundChanges {
            followUps = policy.followUpDelays.map { end + $0 }
        }
        if outcome.wasInconsistent {
            followUps.insert(end + policy.inconsistentRetryDelay, at: 0)
            followUps.sort()
        }
    }

    /// 下一个周期：哪一种、最早什么时刻开始（可能已经过了，那就是立刻）。停止读取时为 nil。
    func next(pace: IconPollingPace) -> (kind: CycleKind, at: TimeInterval)? {
        guard let pace = policy.pace(pace) else { return nil }
        guard let lastCycleStart, let lastFullStart else {
            return (.full, 0)   // 还没读过：立刻完整读取
        }
        switch status {
        case .ok:
            break
        case .stacksEnabled:
            // 开了叠放：隔一阵再看它关了没有。上一次没惊动访达（靠设置认出来的）就按快速检查的间隔，否则按完整读取的间隔。
            return (.full, lastCycleStart + (lastCycleAskedFinder ? pace.fullInterval : pace.quickInterval))
        case .starting, .finderUnavailable, .permissionDenied:
            // 状态不正常时没有"快速检查"可做，隔一阵完整地再试一次。
            return (.full, lastCycleStart + pace.recoveryInterval)
        }
        var fullAt = lastFullStart + interval(base: pace.fullInterval, durations: fullDurations, dutyLimit: pace.fullDutyLimit)
        if let followUp = followUps.first {
            fullAt = min(fullAt, followUp)
        }
        let quickAt = lastCycleStart + interval(base: pace.quickInterval, durations: quickDurations, dutyLimit: pace.quickDutyLimit)
        return fullAt <= quickAt ? (.full, fullAt) : (.quick, quickAt)
    }

    /// 实际采用的间隔：不小于下限；按"平时的耗时 ÷ 占比上限"拉长；但最多拉到下限的 `maxStretch` 倍。
    private func interval(base: TimeInterval, durations: [TimeInterval], dutyLimit: Double) -> TimeInterval {
        let typical = durations.min() ?? 0
        return min(max(base, typical / dutyLimit), base * policy.maxStretch)
    }

    private static func remember(_ duration: TimeInterval, in durations: inout [TimeInterval]) {
        durations.append(duration)
        if durations.count > rememberedDurations {
            durations.removeFirst(durations.count - rememberedDurations)
        }
    }
}
