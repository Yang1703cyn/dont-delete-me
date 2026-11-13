// Emotion · 渐入渐出
//
// 所有连续参数都用同一种办法逼近目标：先按指数规律快速靠近（走掉剩余差值的固定比例），
// 快到的时候改成匀速走完。这样既没有一帧之内的突变，又能在有限时间内**正好**到达目标——
// 到达之后数值不再变化，应用才能停止出帧。

import CoreGraphics
import DDMCore
import Foundation

/// 一条通道在这一帧用的几个数。
struct Ease: Sendable {
    /// 这一帧走掉剩余差值的多大比例。
    var k: Double
    /// 这一帧至少走这么多（收尾用）。
    var minStep: Double
    /// 这是一条"慢"的渐变（时间常数不小于 `EmotionTuning.slowChannelTime`）：不必每个显示刷新都算。
    var isSlow: Bool

    /// - Parameters:
    ///   - step: 这一帧按多长时间算（秒）。
    ///   - time: 时间常数（秒）。不大于 0 表示立即到位。
    ///   - settle: 收尾比例，见 `EmotionTuning.settleFraction`。
    ///   - slowFrom: 时间常数不小于这个值算"慢"；不大于 0 表示没有慢的。
    init(step: TimeInterval, time: TimeInterval, settle: Double, slowFrom: TimeInterval) {
        isSlow = slowFrom > 0 && time >= slowFrom
        guard step > 0 else {
            k = 0
            minStep = 0
            return
        }
        guard time > 0 else {
            k = 1
            minStep = 1
            return
        }
        k = 1 - exp(-step / time)
        minStep = max(settle, 0) * step / time
    }
}

/// 这一帧之后还有没有东西没到位（还需要下一帧），以及要得多急。
struct Motion: Sendable {
    /// 有快的渐变还没到位：每个显示刷新都要一帧。
    var fast = false
    /// 只有慢的渐变还没到位：隔一小会儿再算就行。
    var slow = false
}

/// 让 `value` 朝 `target` 走一帧。变大用 `rise`，变小用 `fall`。
/// 走完这一帧还没到的话，记到 `motion` 里；这一帧正好走到则不记（不需要下一帧了）。
@inline(__always)
func approach(_ value: inout Double, _ target: Double, rise: Ease, fall: Ease, _ motion: inout Motion) {
    let diff = target - value
    if diff == 0 { return }
    let ease = diff > 0 ? rise : fall
    let distance = abs(diff)
    let step = max(distance * ease.k, ease.minStep)
    if step >= distance {
        value = target
        return
    }
    value += diff > 0 ? step : -step
    if ease.isSlow {
        motion.slow = true
    } else {
        motion.fast = true
    }
}

/// 把 `x` 从区间 [from, to] 线性映射到 0…1，区间外夹住。`from == to` 时是一道台阶。
@inline(__always)
func ramp(_ x: Double, _ from: Double, _ to: Double) -> Double {
    if to <= from { return x >= to ? 1 : 0 }
    return min(max((x - from) / (to - from), 0), 1)
}

/// 夹到 0…1；非数字按 0。
@inline(__always)
func unit(_ x: Double) -> Double {
    x >= 0 ? (x <= 1 ? x : 1) : 0
}

/// 一帧里所有通道要用的 `Ease`，每帧算一次，所有图标共用。
struct Eases: Sendable {
    let gaze: Ease
    let homing: Ease
    let fearRise: Ease
    let fearFall: Ease
    let sweatRise: Ease
    let sweatFall: Ease
    let trembleRise: Ease
    let trembleFall: Ease
    let tearsRise: Ease
    let tearsFall: Ease
    let dizzyRise: Ease
    let dizzyFall: Ease
    let blushRise: Ease
    let blushFall: Ease
    let scareRise: Ease
    let scareFall: Ease
    let wake: Ease
    let dozeOff: Ease
    let headingRise: Ease
    let headingFall: Ease

    init(step: TimeInterval, tuning t: EmotionTuning) {
        func make(_ time: TimeInterval) -> Ease {
            Ease(step: step, time: time, settle: t.settleFraction, slowFrom: t.slowChannelTime)
        }
        gaze = make(t.gazeTime)
        homing = make(t.homingTime)
        fearRise = make(t.fearRiseTime)
        fearFall = make(t.fearFallTime)
        sweatRise = make(t.sweatRiseTime)
        sweatFall = make(t.sweatFallTime)
        trembleRise = make(t.trembleRiseTime)
        trembleFall = make(t.trembleFallTime)
        tearsRise = make(t.tearsRiseTime)
        tearsFall = make(t.tearsFallTime)
        dizzyRise = make(t.dizzyRiseTime)
        dizzyFall = make(t.dizzyFallTime)
        blushRise = make(t.blushRiseTime)
        blushFall = make(t.blushFallTime)
        scareRise = make(t.scareRiseTime)
        scareFall = make(t.scareFallTime)
        wake = make(t.wakeTime)
        dozeOff = make(t.dozeOffTime)
        headingRise = make(t.headingRiseTime)
        headingFall = make(t.headingFallTime)
    }
}

/// 省电信号的累加器：一帧里谁还在动、谁最早需要再被叫醒，都记到这里。
struct Pulse: Sendable {
    let now: TimeInterval
    /// 有参数还在逐帧变化。
    var animating = false
    /// 最早需要再算一次的时刻；没有则为无穷大。
    var wakeAt = TimeInterval.infinity

    init(now: TimeInterval) {
        self.now = now
    }

    /// 登记"最晚在 time 时刻要再算一次"。已经过去的时刻等于"下一帧就要"。
    mutating func schedule(_ time: TimeInterval) {
        if time > now {
            if time < wakeAt { wakeAt = time }
        } else if time <= now {
            animating = true
        }
        // 非数字：两个比较都不成立，忽略。
    }

    /// 把一处的"还没到位"记进来。只有慢的渐变时不要求连续出帧，约一个很近的时刻就行。
    mutating func absorb(_ motion: Motion, slowInterval: TimeInterval) {
        if motion.fast {
            animating = true
        } else if motion.slow {
            if slowInterval > 0 {
                schedule(now + slowInterval)
            } else {
                animating = true
            }
        }
    }

    var demand: FrameDemand {
        if animating { return .continuous }
        return wakeAt.isFinite ? .by(wakeAt) : .idle
    }
}

// MARK: - 输入的把关

extension CGPoint {
    /// 两个坐标都是有限数，而且不离谱（绝对值小于十亿点）。
    /// 把关之后，引擎里所有的距离、平方都不会溢出，也就不会算出非数字。
    var isSane: Bool {
        x.isFinite && y.isFinite && abs(x) < 1e9 && abs(y) < 1e9
    }
}

extension CGRect {
    /// 能在上面画脸的矩形：位置不离谱，宽高是正的有限数（看的是原始的宽高，负的不算）。
    var isDrawable: Bool {
        origin.isSane && size.width > 0 && size.height > 0 && size.width < 1e6 && size.height < 1e6
    }
}
