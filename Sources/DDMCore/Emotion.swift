// DDMCore · 情绪引擎的输入输出与协议
//
// 情绪引擎是"导演"：每帧拿到图标 + 交互事实 + 时间，决定这一帧要画哪些脸、各自在哪、是什么表情。
// 纯逻辑：不读系统时钟、不用全局随机数、不做文件读写、不依赖 AppKit。

import CoreGraphics
import Foundation

/// 叠加层的两层画布。
public enum OverlayLayer: String, Sendable, Hashable, CaseIterable {
    /// 桌面层：每块屏一个，压在访达图标之上、普通窗口之下。平时所有的脸都在这层。
    case desktop
    /// 拖拽层：只在拖拽期间出现，在所有窗口和程序坞之上。只画"正被拖着的那个图标"的脸。
    case drag
}

/// 一张要画的脸：画在哪、哪一层、什么表情。
public struct FacePlacement: Sendable, Equatable {
    /// 这张脸属于哪个图标。约定：同一帧里，同一个（图标，层）组合最多出现一次。
    /// 幽灵沿用被删图标的编号。
    public var iconID: IconID
    /// 图标图像矩形，全局坐标。脸画在这个矩形上。
    /// 被拖着的图标：用 `DragState.currentImageRect`（鼠标位置 − 抓取偏移）。
    /// 幽灵：用图标被删前最后的矩形。
    public var rect: CGRect
    /// 画在哪一层。
    public var layer: OverlayLayer
    /// 表情。
    public var state: FaceState

    public init(iconID: IconID, rect: CGRect, layer: OverlayLayer = .desktop, state: FaceState) {
        self.iconID = iconID
        self.rect = rect
        self.layer = layer
        self.state = state
    }
}

/// 情绪引擎一帧的输入。
public struct EmotionInput: Sendable, Equatable {
    /// 这一帧的时间。
    public var time: FrameTime
    /// 最新的图标快照，以及自上一帧以来累积的变化事件（与喂给交互感知的是同一份）。
    public var icons: IconUpdate
    /// 交互感知这一帧给出的事实。
    public var facts: InteractionFacts

    public init(time: FrameTime, icons: IconUpdate, facts: InteractionFacts) {
        self.time = time
        self.icons = icons
        self.facts = facts
    }
}

/// 情绪引擎一帧的输出。
public struct EmotionOutput: Sendable, Equatable {
    /// 这一帧要画的全部的脸。不在清单里的图标这一帧不画脸。
    /// 数组顺序就是同一层内的叠放次序：排在后面的画在上面（例如幽灵放在最后）。
    public var faces: [FacePlacement]
    /// 省电信号：`.continuous` = 有参数还在逐帧变化；`.by(t)` = 现在是静止的，但最晚 t 时刻
    /// 要再算一次（例如下一次眨眼）；`.idle` = 除非有新输入，否则不必再算。
    /// 只需考虑情绪参数自身的变化；表情模块的循环小动画（`animationInterval`）由应用另行处理。
    public var demand: FrameDemand

    public init(faces: [FacePlacement] = [], demand: FrameDemand = .idle) {
        self.faces = faces
        self.demand = demand
    }
}

/// 情绪引擎。由 Emotion 实现。
///
/// - 确定性：输出只取决于构造时传入的随机数种子和历次 `update` 的输入；
///   同样的种子 + 同样的输入序列，永远得到同样的输出序列。
/// - 线程：纯逻辑，不绑定线程；应用里在主线程逐帧调用。
/// - 性能目标：100 个图标一次 `update` 不超过约 0.2 毫秒。
public protocol EmotionDirecting {
    /// 推进一帧。`input.time.monotonic` 必须单调不减。
    mutating func update(_ input: EmotionInput) -> EmotionOutput

    /// 清空所有进行中的情绪和动画，回到初始状态（随机数序列也从种子重新开始）。
    mutating func reset()
}
