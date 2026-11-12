// Overlay · 什么时候出下一帧（纯逻辑）
//
// 把调用方给的省电信号（FrameDemand）翻译成"帧循环现在该处于哪种状态"。
// 真正的显示刷新回调和定时器在 FrameClock 里；这里只做决定，所以可以脱离时钟做单元测试。

import DDMCore
import Foundation

struct FrameScheduler: Equatable, Sendable {
    /// 帧循环的状态。
    enum Wake: Equatable, Sendable {
        /// 每个显示刷新都出一帧。
        case everyRefresh
        /// 等显示刷新，在不早于这个时刻的第一个刷新出一帧。
        case refresh(notBefore: TimeInterval)
        /// 离得还远：关掉显示刷新回调，用定时器在这个时刻醒一次。
        case timer(at: TimeInterval)
        /// 休息，直到有人请求一帧。
        case sleep
    }

    /// `.by(t)` 离现在不超过这么久，就守着显示刷新等它；更远就交给定时器，中间彻底休息。
    static let refreshWaitWindow: TimeInterval = 0.05

    private(set) var wake: Wake = .sleep

    /// 现在是否需要显示刷新回调。
    var needsRefreshTicks: Bool {
        switch wake {
        case .everyRefresh, .refresh: return true
        case .timer, .sleep: return false
        }
    }

    /// 需要定时器在什么时刻叫醒；不需要为 nil。
    var timerDeadline: TimeInterval? {
        if case let .timer(deadline) = wake { return deadline }
        return nil
    }

    /// 刚出完一帧，调用方给了下一帧的需求。
    mutating func frameFinished(demand: FrameDemand, now: TimeInterval) {
        switch demand {
        case .continuous:
            wake = .everyRefresh
        case let .by(deadline):
            if deadline.isNaN || deadline == .infinity {
                // 不是一个时刻：当作"没有定时需求"，免得定时器被反复重建。
                wake = .sleep
            } else if deadline - now <= Self.refreshWaitWindow {
                wake = .refresh(notBefore: max(deadline, now))
            } else {
                wake = .timer(at: deadline)
            }
        case .idle:
            wake = .sleep
        }
    }

    /// 有人请求尽快出一帧：在下一个显示刷新出。已经在连续出帧、或已经约了更早的一帧时无影响。
    mutating func requestFrame(now: TimeInterval) {
        switch wake {
        case .everyRefresh:
            break
        case let .refresh(notBefore) where notBefore <= now:
            break
        case .refresh, .timer, .sleep:
            wake = .refresh(notBefore: now)
        }
    }

    /// 停下来（暂停、桌面看不见、停止运行）。
    mutating func suspend() {
        wake = .sleep
    }

    /// 来了一个显示刷新回调：这一下要不要出帧。
    ///
    /// 约定的时刻没到就不出，哪怕只差一点点：调用方是拿帧时间和它约的时刻比的，早到的那一帧它什么都不会做，
    /// 只会原样再约一次——白出一帧，真正的重画反而晚一个刷新。
    func shouldRunFrame(onTickAt now: TimeInterval) -> Bool {
        switch wake {
        case .everyRefresh:
            return true
        case let .refresh(notBefore):
            return now >= notBefore
        case .timer, .sleep:
            return false
        }
    }

    /// 定时器响了：这一下要不要出帧。时刻没到（定时器略早）或早已不是定时状态（过期的定时器）都不出。
    func shouldRunFrame(onTimerAt now: TimeInterval) -> Bool {
        guard case let .timer(deadline) = wake else { return false }
        return now >= deadline
    }
}
