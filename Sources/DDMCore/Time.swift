// DDMCore · 时间与"何时需要下一帧"
//
// 所有逻辑模块都不自己读时钟：时间由应用（经叠加层的帧回调）统一传入，这样才能做确定性的单元测试。

import Foundation

/// 一帧的时间。由叠加层在每次帧回调时生成，一路传给交互感知、情绪引擎和表情绘制。
public struct FrameTime: Sendable, Equatable {
    /// 单调时钟，单位秒。只增不减、不受改系统时间影响，电脑睡眠期间不走。
    /// 与 CACurrentMediaTime()、ProcessInfo.systemUptime 同一时基。
    /// 动画、速度、时长、"最晚何时再算"等一切计时都用它。
    ///
    /// 约定：帧时间**不得超前**——它不能晚于帧回调发生那一刻的 `ProcessInfo.systemUptime`。
    /// （叠加层若用显示刷新的时间戳，要用"已经到了的"那个，不要用"下一次刷新的目标时刻"。）
    /// 否则同一帧里触发的图标重读，其 `capturedAt` 会比这一帧的时间还早，
    /// 交互感知就会误以为"这是松手之前读的"。
    public var monotonic: TimeInterval

    /// 墙上时间。只用来和图标的"最近修改时间"比较（打瞌睡），不要拿它算动画。
    public var wallClock: Date

    public init(monotonic: TimeInterval, wallClock: Date) {
        self.monotonic = monotonic
        self.wallClock = wallClock
    }

    /// 读取当前时间。只应由"产生帧"的一方（叠加层、演示程序的主循环）调用；
    /// 逻辑模块一律使用传进来的时间。
    public static func now() -> FrameTime {
        FrameTime(monotonic: ProcessInfo.processInfo.systemUptime, wallClock: Date())
    }

    /// 往后推 `seconds` 秒（两个时钟一起推）。写测试、编剧本时用。
    public func advanced(by seconds: TimeInterval) -> FrameTime {
        FrameTime(monotonic: monotonic + seconds, wallClock: wallClock.addingTimeInterval(seconds))
    }
}

/// 省电信号："我什么时候需要被再次调用"。
///
/// 交互感知、情绪引擎各自给出一个，应用取其中最紧的一个交给叠加层，
/// 叠加层据此决定是连续出帧、定时醒一次，还是彻底休息。
public enum FrameDemand: Sendable, Equatable {
    /// 有动画或连续变化正在进行：每个显示刷新都要一帧。
    case continuous
    /// 当前没有动画，但最晚在这个时刻（`FrameTime.monotonic` 的时基，秒）要再算一次，
    /// 例如下一次眨眼、下一次读鼠标。
    case by(TimeInterval)
    /// 没有任何定时需求；只在外部事件（图标变化、`requestFrame()`）到来时再算。
    case idle

    /// 是否需要连续出帧。
    public var isContinuous: Bool { self == .continuous }

    /// 两个需求里更紧的那个。
    public func merged(with other: FrameDemand) -> FrameDemand {
        switch (self, other) {
        case (.continuous, _), (_, .continuous):
            return .continuous
        case let (.by(a), .by(b)):
            return .by(min(a, b))
        case let (.by(a), .idle), let (.idle, .by(a)):
            return .by(a)
        case (.idle, .idle):
            return .idle
        }
    }
}
