// InputSense · 甩动强度（纯逻辑）
//
// "来回急甩越猛越高，平稳拖动接近 0"。做法：把鼠标轨迹切成一小段一小段，
// 看相邻两段之间拐了多大的弯；每次拐弯按"拐弯之前这一程最快有多快"加权，累进一个会自己衰减的能量里。
//   - 直线拖动：不拐弯，能量为 0；
//   - 来回甩：每次掉头拐 180°，甩得越快、掉头越勤，能量越高；
//   - 画圈搅动：一直在拐弯，也会晕，只是比来回甩温和。

import CoreGraphics
import DDMCore
import Foundation

struct ShakeMeter: Sendable, Equatable {
    /// 可调参数。默认值是按"每秒掉头几次、甩多快"推出来的，见 `docs/模块说明/input-sense.md`。
    struct Tuning: Sendable, Equatable {
        /// 轨迹每走这么远（点）切一段。太短会把手抖和取整误差当成拐弯。
        var segmentLength: CGFloat = 24
        /// 小于这个角度（弧度）的拐弯不算，过滤掉平缓的弧线和取整噪声。
        var angleDeadZone: Double = 0.12
        /// 能量的衰减时间常数（秒）：停手后大约一两秒晕劲儿过去。
        var energyDecay: TimeInterval = 0.6
        /// 这一程的最高速度低于它（点/秒）：这次拐弯完全不算甩。
        var speedFloor: CGFloat = 400
        /// 这一程的最高速度达到它（点/秒）：按最猛算。
        var speedCeiling: CGFloat = 3000
        /// 每弧度拐弯（满权重时）加多少能量。
        var gain: Double = 0.2
    }

    var tuning = Tuning()

    /// 累积的能量；强度 = 1 − e^(−能量)。
    private(set) var energy: Double = 0
    /// 当前这一小段的起点和开始时刻。
    private var anchor: CGPoint?
    private var anchorTime: TimeInterval = 0
    /// 上一小段的方向（单位向量）。
    private var lastHeading: CGVector?
    /// 从上一次拐弯到现在，这一程里最快的一小段有多快。
    /// 来回甩时掉头的那一瞬速度是 0，所以不能看拐弯那一刻的速度，要看刚甩完的这一程。
    /// 速度按每一小段"走了多远 ÷ 用了多久"算，不用平滑过的鼠标速度——平滑会把快速来回的峰值削掉一大截。
    private var strokePeak: CGFloat = 0
    private var lastTime: TimeInterval?

    /// 当前的甩动强度 0…1。
    var intensity: Double { 1 - exp(-energy) }

    /// 喂一个新位置，返回更新后的强度。
    @discardableResult
    mutating func update(position: CGPoint, at time: TimeInterval) -> Double {
        let dt = max(0, time - (lastTime ?? time))
        lastTime = time
        energy *= exp(-dt / tuning.energyDecay)
        if energy < 1e-4 { energy = 0 }

        guard let start = anchor else {
            anchor = position
            anchorTime = time
            return intensity
        }
        let step = position.offset(from: start)
        let length = step.length
        guard length >= tuning.segmentLength else { return intensity }

        let segmentSpeed = time > anchorTime ? length / CGFloat(time - anchorTime) : 0
        strokePeak = max(strokePeak, segmentSpeed)
        let heading = CGVector(dx: step.dx / length, dy: step.dy / length)
        if let previous = lastHeading {
            let cosine = Double(previous.dx * heading.dx + previous.dy * heading.dy)
            let turn = acos(min(1, max(-1, cosine))) - tuning.angleDeadZone
            if turn > 0 {
                let span = max(tuning.speedCeiling - tuning.speedFloor, 1)
                let weight = Double(min(1, max(0, (strokePeak - tuning.speedFloor) / span)))
                energy += tuning.gain * turn * weight
                // 拐过弯了：新的一程从这一小段算起。
                strokePeak = segmentSpeed
            }
        }
        lastHeading = heading
        anchor = position
        anchorTime = time
        return intensity
    }
}
