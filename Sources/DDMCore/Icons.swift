// DDMCore · 桌面图标：快照、变化事件、图标提供者协议
//
// 产生者：IconBridge（图标桥）。
// 消费者：应用入口（转交）、InputSense（命中测试、结局判定）、Emotion（决定画哪些脸）。

import CoreGraphics
import Foundation

// MARK: - 单个图标

/// 图标的稳定编号。不可读：对外绝不暴露文件名，也不能从编号反推出文件名。
///
/// 约定（由图标桥保证）：
/// - 同一个桌面项目在多次读取之间编号不变；尽量做到跨启动也不变（这样它每次长得一样）；
/// - 改名后算作"旧的消失、新的出现"是可以接受的；
/// - 编号里不得直接包含文件名的任何片段（建议：每次安装随机生成的盐 + 名字，取哈希）。
public struct IconID: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// 调试输出用的短形式：编号十六进制的末 8 位，例如 `icon#3fa91c02`。
    public var description: String {
        let hex = String(rawValue & 0xFFFF_FFFF, radix: 16)
        return "icon#" + String(repeating: "0", count: 8 - hex.count) + hex
    }

    /// 长相种子：由编号派生，同一个图标永远相同。
    /// 情绪模块用它定性格、错开眨眼；表情模块用它让五官略有不同。
    public var faceSeed: UInt64 { SeededRandom.mix(rawValue) }
}

/// 图标种类。
public enum IconKind: String, Sendable, CaseIterable {
    /// 普通文件（文稿、图片、替身等）。
    case file
    /// 文件夹。
    case folder
    /// 应用程序。
    case application
    /// 磁盘、外接卷宗、网络卷宗。
    case volume
    /// 认不出来的其它东西。
    case other
}

/// 桌面上的一个图标。所有矩形都是全局坐标（见 Coordinates.swift）。
public struct DesktopIcon: Sendable, Equatable, Identifiable {
    public var id: IconID
    public var kind: IconKind

    /// 图标图像（那张方形的图）所占的矩形。画脸用：脸就画在这个矩形上。
    public var imageRect: CGRect

    /// 文字标签所占的矩形（估算）。读不到或没有标签时为 nil。
    public var labelRect: CGRect?

    /// 图标所在的显示器；判断不出来时为 nil。
    public var displayID: DisplayID?

    /// 最近修改时间（墙上时间）。读不到时为 nil——这样的图标不参与"打瞌睡"。
    /// 不必每次轮询都重读。
    public var modifiedAt: Date?

    public init(
        id: IconID,
        kind: IconKind,
        imageRect: CGRect,
        labelRect: CGRect? = nil,
        displayID: DisplayID? = nil,
        modifiedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.imageRect = imageRect
        self.labelRect = labelRect
        self.displayID = displayID
        self.modifiedAt = modifiedAt
    }

    /// 连文字标签在内的可点击区域的外接矩形。只适合粗筛；精确判断用 `hitTest(_:)`。
    public var hitBounds: CGRect {
        guard let labelRect else { return imageRect }
        return imageRect.union(labelRect)
    }

    /// 命中测试：点（全局坐标）是否落在图标图像或文字标签上。
    public func hitTest(_ point: CGPoint) -> Bool {
        imageRect.contains(point) || (labelRect?.contains(point) ?? false)
    }
}

// MARK: - 变化事件

/// 三态判断：是 / 否 / 不确定。目前用于"消失的图标是不是进了废纸篓"。
public enum TrashVerdict: String, Sendable, CaseIterable {
    /// 确认进了废纸篓。
    case yes
    /// 确认没进废纸篓（挪去了别的文件夹、被别的程序删掉等）。
    case no
    /// 查不出来。
    case unknown
}

/// 相邻两份快照之间的一个变化。
public enum IconChange: Sendable, Equatable {
    /// 桌面上多了一个图标。
    case added(DesktopIcon)
    /// 一个图标从桌面消失。`icon` 是它消失前最后的样子（含最后位置）；
    /// `trashed` 是图标桥给出的线索：它是不是进了废纸篓。事件发出后不会再更正。
    case removed(DesktopIcon, trashed: TrashVerdict)
    /// 一个图标换了位置（图像矩形变了）。`from` 是旧样子，`to` 是新样子，编号相同。
    case moved(from: DesktopIcon, to: DesktopIcon)

    /// 这个变化说的是哪个图标。
    public var iconID: IconID {
        switch self {
        case let .added(icon): return icon.id
        case let .removed(icon, _): return icon.id
        case let .moved(_, to): return to.id
        }
    }
}

// MARK: - 访达桌面的外观设置

/// 文字标签相对图标图像的位置（访达"查看显示选项"里的设置）。
public enum LabelPosition: String, Sendable, CaseIterable {
    case bottom
    case right
}

/// 访达桌面的外观设置。图标桥读出、变化时跟上；它们决定图像矩形和标签矩形怎么推算。
public struct DesktopAppearance: Sendable, Equatable {
    /// 图标大小：图标图像的边长，单位点。
    public var iconSize: CGFloat
    /// 标签文字大小，单位点。
    public var textSize: CGFloat
    /// 标签在图标的下方还是右侧。
    public var labelPosition: LabelPosition

    public init(iconSize: CGFloat, textSize: CGFloat, labelPosition: LabelPosition) {
        self.iconSize = iconSize
        self.textSize = textSize
        self.labelPosition = labelPosition
    }

    /// 访达的出厂设置：64 点图标、12 点文字、标签在下。还没读到真实设置时用它。
    public static let finderDefault = DesktopAppearance(iconSize: 64, textSize: 12, labelPosition: .bottom)
}

// MARK: - 状态

/// 图标提供者的状态。只有 `.ok` 时快照里的图标才可信；其余状态下快照一律为空（宁可不画，也不乱画）。
public enum IconProviderStatus: String, Sendable, CaseIterable {
    /// 还没完成第一次读取（包括系统授权弹窗正等用户回答的期间）。
    case starting
    /// 正常。
    case ok
    /// 访达没在运行、正在重启或没有响应。其它无法归类的读取失败也归到这里。
    case finderUnavailable
    /// 用户拒绝了"控制访达"的授权。
    case permissionDenied
    /// 桌面开启了"叠放"，图标位置不可靠。
    case stacksEnabled

    /// 是否可以画脸。
    public var isUsable: Bool { self == .ok }
}

// MARK: - 快照

/// 某一时刻桌面的全貌。值类型，可随意跨线程传递。
public struct IconSnapshot: Sendable, Equatable {
    /// 所有桌面图标。顺序没有含义，但图标桥应尽量保持稳定（方便调试输出对比）。
    /// 状态不是 `.ok` 时为空。
    public var icons: [DesktopIcon]

    /// 读取时访达桌面的外观设置。
    public var appearance: DesktopAppearance

    /// 读取时图标提供者的状态。
    public var status: IconProviderStatus

    /// 这次读取**开始**的时刻（`FrameTime.monotonic` 的时基，秒）。
    /// 含义：快照反映的是不早于这一刻的桌面。交互感知用它判断
    /// "松手之后是否已经读到过一份新的快照"。
    public var capturedAt: TimeInterval

    /// 内容版本号：图标、外观或状态任一发生变化时加一；只是重读了一遍而内容没变则不变。
    public var revision: UInt64

    public init(
        icons: [DesktopIcon],
        appearance: DesktopAppearance = .finderDefault,
        status: IconProviderStatus,
        capturedAt: TimeInterval,
        revision: UInt64
    ) {
        self.icons = icons
        self.appearance = appearance
        self.status = status
        self.capturedAt = capturedAt
        self.revision = revision
    }

    /// 空快照。提供者启动前、状态异常时用。
    public static func empty(status: IconProviderStatus = .starting, capturedAt: TimeInterval = 0) -> IconSnapshot {
        IconSnapshot(icons: [], status: status, capturedAt: capturedAt, revision: 0)
    }

    /// 按编号找图标。
    public func icon(withID id: IconID) -> DesktopIcon? {
        icons.first { $0.id == id }
    }

    /// 该点（全局坐标）命中的图标；没有命中时为 nil。多个图标重叠时取排在前面的那个。
    public func icon(at point: CGPoint) -> DesktopIcon? {
        icons.first { $0.hitTest(point) }
    }
}

// MARK: - 更新

/// 图标提供者的一次"上报"，也是应用每帧喂给交互感知和情绪引擎的图标输入。
public struct IconUpdate: Sendable, Equatable {
    /// 最新的快照。
    public var snapshot: IconSnapshot

    /// 相对上一份快照的变化，按发生顺序排列。`isReset` 为 true 时恒为空。
    public var changes: [IconChange]

    /// 整体重载：快照被整个换掉了，不是"某几个图标变了"。
    /// 发生在：第一次读到图标、状态切换（如访达重启、授权变化、叠放开关）、
    /// 外观设置或显示器排列变了导致所有矩形一起变、从 `.suspended` 恢复后的第一次读取。
    /// 消费者此时应当按新快照**无动画地重建**自己的状态——
    /// 不要把一桌图标都当成"新来的"，也不要给"不见了"的图标放幽灵。
    public var isReset: Bool

    public init(snapshot: IconSnapshot, changes: [IconChange] = [], isReset: Bool = false) {
        self.snapshot = snapshot
        self.changes = isReset ? [] : changes
        self.isReset = isReset
    }

    /// "这一帧图标没有任何变化"。
    public static func unchanged(_ snapshot: IconSnapshot) -> IconUpdate {
        IconUpdate(snapshot: snapshot)
    }

    /// 把更晚的一次更新并进来（应用在两帧之间可能收到不止一次上报）。
    /// 结果：快照取最新；变化事件按顺序接起来；其中任何一次是整体重载，结果就是整体重载。
    public func merging(_ later: IconUpdate) -> IconUpdate {
        if isReset || later.isReset {
            return IconUpdate(snapshot: later.snapshot, isReset: true)
        }
        return IconUpdate(snapshot: later.snapshot, changes: changes + later.changes)
    }
}

// MARK: - 图标提供者协议

/// 应用给图标提供者的节奏提示。具体每档多久读一次由图标桥自己定。
public enum IconPollingPace: String, Sendable, CaseIterable {
    /// 停止读取：应用被暂停，或桌面此刻根本看不见。
    case suspended
    /// 空闲：用户有一阵没动鼠标了，可以读得很慢。
    case idle
    /// 活跃：用户正在操作，变化需要尽快被发现。
    case active
}

/// 图标提供者：让应用知道"桌面上每个图标在哪、是什么"。由 IconBridge 实现。
///
/// 线程约定：
/// - 协议里的所有属性和方法都在主线程调用，并且**立即返回**；
/// - 真正的读取（向访达发请求，约 0.27 秒 / 19 个图标）必须在后台进行，绝不能阻塞主线程；
/// - `onUpdate` 回调在主线程。
@MainActor
public protocol IconProviding: AnyObject {
    /// 最近一次读到的快照。只是取缓存，不触发读取。`start()` 之前是 `.empty()`。
    var snapshot: IconSnapshot { get }

    /// 有新情况时的回调（主线程）。触发时机：
    /// 1. 第一次读取完成（`isReset == true`）；
    /// 2. 之后任何一次读取发现图标、外观或状态有变化；
    /// 3. `refreshNow()` 引发的读取完成时——**即使没有变化也要回调一次**
    ///    （此时 `changes` 为空、`revision` 不变、`capturedAt` 更新），
    ///    交互感知靠它确认"松手后已经重读过了"。
    /// 普通的定时轮询若什么都没变，则不回调。
    var onUpdate: (@MainActor (IconUpdate) -> Void)? { get set }

    /// 开始工作：发起第一次读取，并按节奏持续轮询。重复调用无副作用。
    func start()

    /// 停止工作并取消尚未完成的读取。之后不再回调。可再次 `start()`。
    func stop()

    /// 立即重读一次（应用在鼠标松开等时刻调用）。不阻塞；结果经 `onUpdate` 送达。
    /// 如果已有一次读取正在进行，应保证在它之后**再读一次**，使结果不早于本次调用。
    func refreshNow()

    /// 节奏提示，见 `IconPollingPace`。默认按 `.active` 处理。
    func setPollingPace(_ pace: IconPollingPace)
}

extension IconProviding {
    /// 当前状态（取自最近的快照）。
    public var status: IconProviderStatus { snapshot.status }

    /// 访达桌面的外观设置（取自最近的快照）。
    public var appearance: DesktopAppearance { snapshot.appearance }
}
