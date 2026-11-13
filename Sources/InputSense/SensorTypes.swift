// InputSense · 判断器与"读系统的薄层"之间交换的数据
//
// 模块分成两部分（见 docs/模块说明/input-sense.md）：
//   - 读系统的薄薄一层：`InteractionEnvironment`（真实实现是 `LiveEnvironment`）；
//   - 纯逻辑的判断器：`InteractionJudge`。
// 这个文件是两者之间的全部接口：薄层只回答"鼠标在哪、按着什么""这个点上最上面是什么窗口"
// "废纸篓大概在哪"，其余一切判断都在判断器里。演示程序和单元测试用一个编出来的薄层驱动同一个判断器。

import CoreGraphics
import DDMCore
import Foundation

/// 薄层一次读到的鼠标原始状态。
public struct PointerSample: Sendable, Equatable {
    /// 鼠标位置，全局坐标（主屏左上角为原点、y 向下、单位点）。
    public var position: CGPoint
    /// 当前按着的按键。
    public var buttons: MouseButtons
    /// 最近一次"左键按下"事件发生的时刻（`FrameTime.monotonic` 时基）；读不到为 nil。
    /// 只用来把按下点估得更准：两帧之间鼠标可能已经走了一段。
    public var lastLeftDownAt: TimeInterval?
    /// 最近一次"左键松开"事件发生的时刻；读不到为 nil。用来把松手点估得更准。
    public var lastLeftUpAt: TimeInterval?

    public init(
        position: CGPoint,
        buttons: MouseButtons = [],
        lastLeftDownAt: TimeInterval? = nil,
        lastLeftUpAt: TimeInterval? = nil
    ) {
        self.position = position
        self.buttons = buttons
        self.lastLeftDownAt = lastLeftDownAt
        self.lastLeftUpAt = lastLeftUpAt
    }
}

/// 某个点上"最上面的窗口"是什么。本应用自己的叠加窗口和系统的拖影不算（看它们下面的那个）。
public enum PointerSurface: String, Sendable, CaseIterable {
    /// 访达的桌面图标层，而且图标看得见。**只有这一种才算"在桌面图标上"。**
    case desktopIcons
    /// 访达的桌面图标层，但图标被系统的遮挡窗口盖住了（系统设置里关掉了"在桌面上显示项目"）。
    case shieldedDesktop
    /// 程序坞那一条（程序坞窗口上接收点击的部分）。
    case dock
    /// 别的窗口：普通窗口、菜单栏、桌面小组件、墙纸……
    case otherWindow
    /// 查不出来。按"不在桌面上"处理。
    case unknown

    /// 是否算"点在桌面图标层上"。
    public var isDesktop: Bool { self == .desktopIcons }
}

/// 废纸篓位置的估算。
public struct TrashEstimate: Sendable, Equatable {
    /// 估算是怎么来的。
    public enum Basis: String, Sendable {
        /// 只按程序坞的设置推算。
        case formula
        /// 量出了程序坞那一条此刻在屏幕上的实际范围，再从它的末端推出废纸篓。
        case measured
    }

    /// 估算出的废纸篓区域，全局坐标。可信度越低，沿程序坞方向留的余量越宽。
    public var rect: CGRect
    /// 可信度 0…1。
    public var confidence: Double
    public var basis: Basis
    /// 这份估算用上了几次"图标确实进了废纸篓"的松手位置（自学习）。
    public var lessonCount: Int

    public init(rect: CGRect, confidence: Double, basis: Basis = .formula, lessonCount: Int = 0) {
        self.rect = rect
        self.confidence = confidence
        self.basis = basis
        self.lessonCount = lessonCount
    }
}

/// 读系统的薄薄一层。真实实现是 `LiveEnvironment`；演示和测试可以用编出来的实现。
///
/// 约定：
/// - 只读：不产生、不拦截、不修改任何输入事件，不改任何系统设置；
/// - 不需要任何系统授权；
/// - 都在主线程调用，都必须很快（每帧关键路径上）。
@MainActor
public protocol InteractionEnvironment: AnyObject {
    /// 读一次鼠标。
    func readPointer() -> PointerSample

    /// 这个点（全局坐标）上最上面的窗口是什么。判断器自己限频，不会每帧都问。
    func surface(at point: CGPoint) -> PointerSurface

    /// 当前对废纸篓位置的估算；完全估算不出来为 nil。每帧都会问，实现应当自己缓存。
    /// - Parameter isDragging: 此刻是否有图标正被拖着（拖拽期间值得估得更勤、更准）。
    func trashEstimate(at time: FrameTime, isDragging: Bool) -> TrashEstimate?

    /// 自学习：一次拖拽确实以"图标进了废纸篓"结束，这是它松手的位置。
    func learnTrashLocation(releasePoint: CGPoint, at time: FrameTime)
}
