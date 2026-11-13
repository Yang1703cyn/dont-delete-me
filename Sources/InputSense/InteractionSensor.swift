// InputSense · 模块入口：交互感知
//
// 应用以 `InteractionSensor()` 构造它，每帧调用一次 `update`。它把两部分接在一起：
//   - 读系统的薄薄一层（`InteractionEnvironment`，默认是真实的 `LiveEnvironment`）；
//   - 纯逻辑的判断器（`InteractionJudge`）。
// 自己没有定时器、没有后台任务：没人调用 `update`（应用被暂停、桌面看不见）时什么都不读，开销为零。
// 接口约定见 docs/接口约定.md 第 3 节；结论、数据和限制见 docs/模块说明/input-sense.md。

import CoreGraphics
import DDMCore
import Foundation

@MainActor
public final class InteractionSensor: InteractionSensing {
    /// 读系统的那一层。
    public let environment: any InteractionEnvironment
    private var judge = InteractionJudge()

    /// - Parameter environment: 读系统的那一层。应用里用默认的真实实现；演示和测试可以换成编出来的。
    public init(environment: any InteractionEnvironment = LiveEnvironment()) {
        self.environment = environment
    }

    public func update(time: FrameTime, icons: IconUpdate) -> InteractionFacts {
        let input = JudgeInput(
            time: time,
            pointer: environment.readPointer(),
            icons: icons,
            trash: environment.trashEstimate(at: time, isDragging: judge.isDragging)
        )
        let output = judge.step(input) { [environment] point in environment.surface(at: point) }
        for releasePoint in output.trashLessons {
            environment.learnTrashLocation(releasePoint: releasePoint, at: time)
        }
        return output.facts
    }

    public func reset() {
        // 只丢掉进行到一半的判断；学到的废纸篓位置在读系统的那一层里，不受影响。
        judge.reset()
    }

    // MARK: 排查

    /// 最近一次查到的"鼠标处最上面是什么窗口"；还没查过为 nil。
    public var lastSurface: PointerSurface? { judge.lastSurface }

    /// 一共问了多少次"鼠标处最上面是什么窗口"（判断器会限频，不是每帧都问）。
    public var surfaceSampleCount: Int { judge.surfaceSampleCount }
}
