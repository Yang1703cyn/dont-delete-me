// 占位，由 faces 子对话替换。
//
// 模块入口：应用以 `FaceRenderer()` 构造它——请保留这个类型名和无参构造方式
// （可以增加带默认值的参数），内部实现和文件组织随意。
// 要实现的协议与约定见 docs/接口约定.md 第 6 节。
//
// 占位行为：什么都不画，不占用图标矩形以外的任何空间，没有任何动画。

import CoreGraphics
import DDMCore
import Foundation

public struct FaceRenderer: FaceRendering {
    public init() {}

    public func draw(_ state: FaceState, in iconRect: CGRect, context: CGContext, time: TimeInterval) {}

    public func outsets(for state: FaceState, iconSize: CGSize) -> EdgeOutsets {
        .zero
    }

    public func animationInterval(for state: FaceState) -> TimeInterval? {
        nil
    }
}
