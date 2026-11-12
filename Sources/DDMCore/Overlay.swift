// DDMCore · 叠加层宿主
//
// 叠加层只管"画布"：在屏幕的正确位置、正确层级，以流畅且省电的方式把别人给的内容显示出来。
// 它不知道画的是脸——它只认识一个个「画布项」：一个矩形、一个版本号，需要重画时回调调用方。

import CoreGraphics
import Foundation

/// 叠加层上的一小块画布（在本应用里就是一张脸）。
public struct OverlayItem: Sendable, Equatable {
    /// 画布项的身份：（图标，层）。同一个 key 跨帧视为同一块画布——
    /// 位置变了就移动它，版本变了才重画它。
    public struct Key: Hashable, Sendable {
        public var iconID: IconID
        public var layer: OverlayLayer

        public init(iconID: IconID, layer: OverlayLayer) {
            self.iconID = iconID
            self.layer = layer
        }
    }

    /// 属于哪个图标。
    public var iconID: IconID
    /// 在哪一层。
    public var layer: OverlayLayer
    /// 基准矩形（图标图像矩形），全局坐标。
    public var rect: CGRect
    /// 画布比基准矩形向四周各多出多少（表情会画到图标外面）。
    public var outsets: EdgeOutsets
    /// 内容版本号。与上一帧相同 = 内容没变，叠加层不必重画（位置变了只需移动）；
    /// 不同 = 需要重画。另外，画布尺寸（`rect.size` 或 `outsets`）变了叠加层总会重画。
    public var contentVersion: UInt64

    public init(
        iconID: IconID,
        layer: OverlayLayer = .desktop,
        rect: CGRect,
        outsets: EdgeOutsets = .zero,
        contentVersion: UInt64 = 0
    ) {
        self.iconID = iconID
        self.layer = layer
        self.rect = rect
        self.outsets = outsets
        self.contentVersion = contentVersion
    }

    public var key: Key { Key(iconID: iconID, layer: layer) }

    /// 画布矩形 = 基准矩形外扩 `outsets`，全局坐标。绘制被裁剪在这个范围内。
    public var canvasRect: CGRect { rect.expanded(by: outsets) }
}

/// 帧回调返回给叠加层的内容：这一帧屏幕上应该有哪些画布项，以及下一帧什么时候要。
public struct OverlayFrame: Sendable, Equatable {
    /// 这一帧的全部画布项。同一个 key 最多出现一次。上一帧有、这一帧没有的项会被移除。
    /// 只要有 `.drag` 层的项，拖拽层窗口就显示；没有就隐藏。
    /// 数组顺序就是同一层内的叠放次序：排在后面的画在上面。
    public var items: [OverlayItem]
    /// 下一帧什么时候要。
    public var demand: FrameDemand

    public init(items: [OverlayItem] = [], demand: FrameDemand = .idle) {
        self.items = items
        self.demand = demand
    }
}

/// 帧回调的接收方（"调用方"）：叠加层按帧回调它来取内容、来作画。由应用入口实现。
/// 所有方法都在主线程被调用。
@MainActor
public protocol OverlayFrameSource: AnyObject {
    /// 取这一帧的内容。调用方在这里推进自己的全部逻辑（读输入、算情绪）。
    /// 每帧恰好调用一次；应用被暂停、桌面不可见时不会被调用。
    func overlayFrame(at time: FrameTime) -> OverlayFrame

    /// 画一个画布项。只有叠加层判定该项需要重画时才调用。
    /// - Parameters:
    ///   - item: `overlayFrame(at:)` 刚返回的某一项。
    ///   - context: 已由叠加层准备好的画布：坐标系就是**全局坐标**（y 向下、单位点），
    ///     所以直接用 `item.rect` 作画即可，不必再做任何换算；已裁剪到 `item.canvasRect`；
    ///     画布已清空为全透明。
    ///   - time: 与本帧 `overlayFrame(at:)` 相同的时间。
    /// 注意：同一项在同一帧里可能被调用不止一次（例如矩形跨两块屏时每块屏各画一次），
    /// 所以绘制必须是幂等的。
    func drawOverlayItem(_ item: OverlayItem, in context: CGContext, at time: FrameTime)
}

/// 叠加层宿主。由 Overlay 实现。
///
/// 它拥有窗口和帧循环：
/// - 桌面层：每块显示器一个透明、点击穿透的窗口，层级为"桌面图标层 +1"；
/// - 拖拽层：只在有 `.drag` 项时出现的透明、点击穿透的最上层窗口；
/// - 帧循环：按 `OverlayFrame.demand` 决定连续出帧、定时醒一次，还是休息；
///   没变化就不重画；
/// - 自己读取全局暂停开关（`PauseSwitch.shared`）：暂停时隐藏所有窗口、停止帧回调，
///   恢复时自动重新开始；
/// - 自己跟随系统状态（切换空间、全屏、图标被隐藏、锁屏、显示器插拔），
///   桌面不可见时停止帧回调。
///
/// 线程：所有属性和方法都在主线程使用，回调也在主线程。
@MainActor
public protocol OverlayHosting: AnyObject {
    /// 帧回调的接收方。实现应弱引用它。
    var frameSource: (any OverlayFrameSource)? { get set }

    /// 桌面层此刻是否对用户可见。以下情况为 false：在全屏应用的空间、锁屏、屏幕睡眠、
    /// 访达隐藏了桌面图标、所有桌面层窗口都被别的窗口完全挡住。与"暂停"无关。
    /// 只要叠加层因为"看不见"而停了帧回调，这个值就必须是 false——
    /// 应用靠它让图标提供者停止读取，否则访达会在没人看的时候照旧被轮询。
    var isDesktopVisible: Bool { get }

    /// `isDesktopVisible` 变化时的回调（主线程）。应用用它让图标提供者暂停或恢复读取。
    var onDesktopVisibilityChange: (@MainActor (Bool) -> Void)? { get set }

    /// 建窗并开始帧循环。重复调用无副作用。
    func start()

    /// 关闭所有窗口、停止帧循环。可再次 `start()`。
    func stop()

    /// 请求尽快出一帧（下一个显示刷新）。用于被外部事件唤醒：图标有更新、暂停被解除等。
    /// 正在连续出帧时调用无影响；暂停或桌面不可见时被忽略。
    func requestFrame()
}
