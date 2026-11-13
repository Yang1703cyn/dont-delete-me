// InputSense · 鼠标的速度与静止时长（纯逻辑）

import CoreGraphics
import DDMCore
import Foundation

/// 由一串"时刻 + 位置"算出平滑后的速度，以及鼠标已经静止了多久。
struct PointerMotion: Sendable, Equatable {
    /// 最近一次的位置。
    private(set) var position: CGPoint = .zero
    /// 平滑后的速度，点/秒。
    private(set) var velocity: CGVector = .zero
    /// 最近一次读数的时刻；还没有读数为 nil。
    private(set) var lastTime: TimeInterval?
    /// 最近一次发现"位置变了"的时刻。
    private(set) var lastMovedAt: TimeInterval = 0

    /// 喂一个新读数。
    /// - Parameter smoothing: 速度平滑的时间常数（秒）。读数间隔远大于它时，速度就是这段间隔里的平均速度。
    mutating func update(position newPosition: CGPoint, at time: TimeInterval, smoothing: TimeInterval) {
        guard let previousTime = lastTime else {
            // 第一个读数：没有速度可言；静止时长从这一刻算起。
            position = newPosition
            lastTime = time
            lastMovedAt = time
            return
        }
        let dt = time - previousTime
        guard dt > 0 else {
            // 时间没有前进（同一帧被喂了两次）：只跟上位置，不动速度。
            if newPosition != position {
                position = newPosition
                lastMovedAt = time
            }
            return
        }
        let instantaneous = CGVector(dx: (newPosition.x - position.x) / dt, dy: (newPosition.y - position.y) / dt)
        let blend = 1 - exp(-dt / max(smoothing, 0.001))
        velocity = CGVector(
            dx: velocity.dx + (instantaneous.dx - velocity.dx) * blend,
            dy: velocity.dy + (instantaneous.dy - velocity.dy) * blend
        )
        // 停稳之后别留下一条永远衰减不完的小尾巴。
        if velocity.length < 0.5 { velocity = .zero }
        if newPosition != position {
            position = newPosition
            lastMovedAt = time
        }
        lastTime = time
    }

    /// 到 `time` 为止鼠标已经静止了多久（秒）。
    func idleDuration(at time: TimeInterval) -> TimeInterval {
        guard lastTime != nil else { return 0 }
        return max(0, time - lastMovedAt)
    }
}
