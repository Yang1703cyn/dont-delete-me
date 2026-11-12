// DDMCore · 交互事实：鼠标、悬停、拖拽、废纸篓、结局、删除
//
// 产生者：InputSense（交互感知）。它只陈述事实和数值，不谈情绪。
// 消费者：Emotion（把事实变成表情）、应用入口（看省电信号、转达"请刷新图标"）。
//
// 分两类：
//   - 状态：每帧都有当前值（鼠标、悬停、拖拽、废纸篓……）；
//   - 一次性事件：只在产生的那一帧出现一次（拖拽结局、删除），下一帧就没有了。

import CoreGraphics
import Foundation

// MARK: - 鼠标

/// 按下的鼠标按键集合。
public struct MouseButtons: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let left = MouseButtons(rawValue: 1 << 0)
    public static let right = MouseButtons(rawValue: 1 << 1)
    /// 中键及其它按键。
    public static let other = MouseButtons(rawValue: 1 << 2)
}

/// 鼠标状态。
public struct MouseState: Sendable, Equatable {
    /// 位置，全局坐标。
    public var position: CGPoint
    /// 当前按下的按键。
    public var buttons: MouseButtons
    /// 速度，点/秒（已做平滑）。
    public var velocity: CGVector
    /// 鼠标已经静止了多久，秒。一动就归零。
    public var idleDuration: TimeInterval

    public init(
        position: CGPoint = .zero,
        buttons: MouseButtons = [],
        velocity: CGVector = .zero,
        idleDuration: TimeInterval = 0
    ) {
        self.position = position
        self.buttons = buttons
        self.velocity = velocity
        self.idleDuration = idleDuration
    }

    /// 速率，点/秒。
    public var speed: CGFloat { velocity.length }
}

// MARK: - 悬停

/// 鼠标正停在某个图标上（已确认该处桌面没有被别的窗口挡住，且没有按键按下）。
public struct HoverState: Sendable, Equatable {
    public var iconID: IconID
    /// 已经悬停了多久，秒。
    public var duration: TimeInterval

    public init(iconID: IconID, duration: TimeInterval) {
        self.iconID = iconID
        self.duration = duration
    }
}

// MARK: - 拖拽

/// 一次正在进行的拖拽（左键按住、已移动超过起拖阈值）。松手后它就不存在了，转为 `ReleasedDrag`。
///
/// 拖拽期间图标桥报告的图标位置**不会变**，要到松手后才更新；
/// 所以拖影（跟着鼠标走的那个半透明图标）的位置只能由这里推算。
public struct DragState: Sendable, Equatable {
    /// 被抓住的图标。多选拖拽时只认鼠标抓住的那一个。
    public var iconID: IconID
    /// 抓取偏移 = 按下瞬间的鼠标位置 − 图标图像矩形的左上角。
    public var grabOffset: CGVector
    /// 被抓起时图标图像矩形（原位置），全局坐标。
    public var originImageRect: CGRect
    /// 当前鼠标位置，全局坐标。
    public var position: CGPoint
    /// 当前速度，点/秒。
    public var velocity: CGVector
    /// 甩动强度 0…1：来回急甩越猛越高，平稳拖动接近 0。
    public var shake: Double
    /// 拖拽开始（越过起拖阈值）的时刻，`FrameTime.monotonic` 时基。
    public var startedAt: TimeInterval

    public init(
        iconID: IconID,
        grabOffset: CGVector,
        originImageRect: CGRect,
        position: CGPoint,
        velocity: CGVector = .zero,
        shake: Double = 0,
        startedAt: TimeInterval
    ) {
        self.iconID = iconID
        self.grabOffset = grabOffset
        self.originImageRect = originImageRect
        self.position = position
        self.velocity = velocity
        self.shake = shake
        self.startedAt = startedAt
    }

    /// 拖影上图标图像所在的矩形 = 鼠标位置 − 抓取偏移，大小不变。被拖图标的脸就画在这里。
    public var currentImageRect: CGRect {
        CGRect(
            origin: CGPoint(x: position.x - grabOffset.dx, y: position.y - grabOffset.dy),
            size: originImageRect.size
        )
    }
}

/// 已经松手、但结局还没判定出来的拖拽（在等图标桥的新快照）。
/// 结局一出，它就从列表里消失，同一帧出现对应的 `DragOutcome`。
public struct ReleasedDrag: Sendable, Equatable {
    public var iconID: IconID
    /// 松手时的鼠标位置。
    public var releasePoint: CGPoint
    /// 松手那一刻拖影上的图标图像矩形。
    public var imageRectAtRelease: CGRect
    /// 松手时刻，`FrameTime.monotonic` 时基。
    public var releasedAt: TimeInterval

    public init(iconID: IconID, releasePoint: CGPoint, imageRectAtRelease: CGRect, releasedAt: TimeInterval) {
        self.iconID = iconID
        self.releasePoint = releasePoint
        self.imageRectAtRelease = imageRectAtRelease
        self.releasedAt = releasedAt
    }
}

/// 一次拖拽最后怎么样了。
public enum DragOutcomeKind: String, Sendable, CaseIterable {
    /// 在桌面上挪了位置。
    case moved
    /// 进了废纸篓。
    case trashed
    /// 离开桌面去了别处（拖进了某个文件夹、窗口、别的应用……），但没进废纸篓。
    case leftDesktop
    /// 取消：弹回原位，什么都没变。
    case cancelled
    /// 等了规定时间仍判断不出来。
    case unknown
}

/// 拖拽结局。一次性事件。
public struct DragOutcome: Sendable, Equatable {
    public var iconID: IconID
    public var kind: DragOutcomeKind
    /// 松手时的鼠标位置。
    public var releasePoint: CGPoint
    /// 结局为 `.moved` 时：图标的新图像矩形；其它结局为 nil。
    public var newImageRect: CGRect?

    public init(iconID: IconID, kind: DragOutcomeKind, releasePoint: CGPoint, newImageRect: CGRect? = nil) {
        self.iconID = iconID
        self.kind = kind
        self.releasePoint = releasePoint
        self.newImageRect = newImageRect
    }
}

// MARK: - 废纸篓

/// 废纸篓在哪、鼠标和它的关系。位置只是估算（靠程序坞设置推算 + 自学习修正），所以带可信度。
public struct TrashInfo: Sendable, Equatable {
    /// 估算出的废纸篓区域，全局坐标。
    public var estimatedRect: CGRect
    /// 估算的可信度 0…1：纯推算时较低，被实际删除"教"过之后升高。
    public var confidence: Double
    /// 鼠标到估算区域的距离，点；鼠标在区域内为 0。
    public var distance: CGFloat
    /// 鼠标朝废纸篓靠近的速度，点/秒；正数表示在靠近，负数表示在远离。
    public var closingSpeed: CGFloat
    /// 鼠标是否正朝废纸篓移动（交互感知已做防抖，比直接看 `closingSpeed` 的正负更稳）。
    public var isApproaching: Bool
    /// 鼠标是否已在废纸篓上方。
    public var isOver: Bool

    public init(
        estimatedRect: CGRect,
        confidence: Double,
        distance: CGFloat,
        closingSpeed: CGFloat = 0,
        isApproaching: Bool = false,
        isOver: Bool = false
    ) {
        self.estimatedRect = estimatedRect
        self.confidence = confidence
        self.distance = distance
        self.closingSpeed = closingSpeed
        self.isApproaching = isApproaching
        self.isOver = isOver
    }
}

// MARK: - 删除

/// "某个图标被删掉了"。一次性事件。**情绪模块见到它就在原地放幽灵，不需要再做任何判断。**
///
/// 发不发由交互感知判定，规则是：
/// - 图标从桌面消失，且图标桥确认它进了废纸篓（`trashed == .yes`）→ 必发；
/// - 确认没进废纸篓（`.no`：挪进了文件夹、被改名等）→ 不发；
/// - 查不出来（`.unknown`）→ 由交互感知按自己掌握的事实决定（例如松手点是否在废纸篓上方），
///   拿不准就不发——宁可少一个幽灵，也不要给没被删的文件"送葬"。
///
/// 经过拖拽的删除，同一帧里还会有一条 `kind == .trashed` 的 `DragOutcome`；
/// 没有拖拽过程的删除（快捷键、右键菜单）只有这一条。
public struct DeletionEvent: Sendable, Equatable {
    public var iconID: IconID
    /// 图标被删前在**桌面上的原位置**的图像矩形（即它最后一次出现在快照里的 `imageRect`），
    /// 幽灵从这里飘起。经过拖拽的删除也是原位置，**不是**松手处的拖影位置——
    /// 松手处在程序坞上，画在桌面层的幽灵会被挡住。
    public var lastImageRect: CGRect
    /// 是否经过了拖拽。
    public var wasDragged: Bool
    /// 图标桥给出的原始线索（仅供调试和记录；放不放幽灵不必再看它）。
    public var trashed: TrashVerdict

    public init(iconID: IconID, lastImageRect: CGRect, wasDragged: Bool, trashed: TrashVerdict) {
        self.iconID = iconID
        self.lastImageRect = lastImageRect
        self.wasDragged = wasDragged
        self.trashed = trashed
    }
}

// MARK: - 一帧的全部交互事实

/// 交互感知每帧输出的全部事实。
public struct InteractionFacts: Sendable, Equatable {
    /// 这些事实对应的时间（就是传给 `update` 的那个）。
    public var time: FrameTime

    // 状态
    public var mouse: MouseState
    /// 鼠标所在位置最上面的窗口是不是访达的桌面图标层（已排除本应用自己的叠加窗口）。
    /// 为 false 时不会有悬停，也不会开始拖拽。
    public var isMouseOverDesktop: Bool
    /// 当前悬停；没有则为 nil。拖拽期间恒为 nil。
    public var hover: HoverState?
    /// 当前正在进行的拖拽；没有则为 nil。
    public var drag: DragState?
    /// 已松手、结局未定的拖拽。
    public var releasedDrags: [ReleasedDrag]
    /// 废纸篓；完全估算不出来时为 nil。
    public var trash: TrashInfo?

    // 一次性事件
    /// 这一帧判定出的拖拽结局。
    public var dragOutcomes: [DragOutcome]
    /// 这一帧判定出的删除。
    public var deletions: [DeletionEvent]

    // 给应用的信号
    /// 请应用立即调用图标提供者的 `refreshNow()`（例如刚松手，需要尽快知道图标去哪了）。
    public var wantsIconRefresh: Bool
    /// 省电信号：交互感知最晚什么时候需要再被喂一次。
    /// 鼠标在动时是 `.continuous`；鼠标静止时给一个较远的时刻（降低读鼠标的频率）。
    public var demand: FrameDemand

    public init(
        time: FrameTime,
        mouse: MouseState = MouseState(),
        isMouseOverDesktop: Bool = false,
        hover: HoverState? = nil,
        drag: DragState? = nil,
        releasedDrags: [ReleasedDrag] = [],
        trash: TrashInfo? = nil,
        dragOutcomes: [DragOutcome] = [],
        deletions: [DeletionEvent] = [],
        wantsIconRefresh: Bool = false,
        demand: FrameDemand = .idle
    ) {
        self.time = time
        self.mouse = mouse
        self.isMouseOverDesktop = isMouseOverDesktop
        self.hover = hover
        self.drag = drag
        self.releasedDrags = releasedDrags
        self.trash = trash
        self.dragOutcomes = dragOutcomes
        self.deletions = deletions
        self.wantsIconRefresh = wantsIconRefresh
        self.demand = demand
    }
}

// MARK: - 交互感知协议

/// 交互感知：看懂用户在干什么。由 InputSense 实现。
///
/// - 不自带定时器：应用每帧调用一次 `update`，它在里面读鼠标等系统状态并更新判断；
/// - 图标快照和变化事件由应用从图标提供者转交，本模块不直接依赖图标桥；
/// - 线程：在主线程调用。`update` 处在每帧的关键路径上，必须很快（目标 0.5 毫秒以内）；
///   较慢的系统查询（如窗口列表）要自己限频或挪到后台，不能让某一帧卡住。
@MainActor
public protocol InteractionSensing: AnyObject {
    /// 喂一帧数据，得到这一帧的交互事实。
    /// - Parameters:
    ///   - time: 这一帧的时间。
    ///   - icons: 最新的图标快照，以及自上一次调用以来累积的变化事件。
    func update(time: FrameTime, icons: IconUpdate) -> InteractionFacts

    /// 丢弃进行到一半的判断（悬停计时、拖拽、等待中的结局），回到初始状态。
    /// 应用在"暂停后恢复""桌面重新可见"时调用，避免用过期的状态接着判断。
    /// 学到的废纸篓位置不受影响。
    func reset()
}
