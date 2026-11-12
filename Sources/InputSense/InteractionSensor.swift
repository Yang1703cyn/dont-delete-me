// 占位，由 input-sense 子对话替换。
//
// 模块入口：应用以 `InteractionSensor()` 构造它——请保留这个类型名和无参构造方式
// （可以增加带默认值的参数），内部实现和文件组织随意。
// 要实现的协议与约定见 docs/接口约定.md 第 3 节。
//
// 占位行为：不读取任何系统状态；永远报告"鼠标在原点不动、没有悬停、没有拖拽、不知道废纸篓在哪"，
// 并请应用每秒再来问一次（让数据流以最低的开销空转）。

import DDMCore
import Foundation

@MainActor
public final class InteractionSensor: InteractionSensing {
    private var firstFrameAt: TimeInterval?

    public init() {}

    public func update(time: FrameTime, icons: IconUpdate) -> InteractionFacts {
        let firstFrameAt = self.firstFrameAt ?? time.monotonic
        self.firstFrameAt = firstFrameAt
        return InteractionFacts(
            time: time,
            mouse: MouseState(idleDuration: time.monotonic - firstFrameAt),
            demand: .by(time.monotonic + 1)
        )
    }

    public func reset() {
        firstFrameAt = nil
    }
}
