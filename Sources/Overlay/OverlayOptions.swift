// Overlay · 可调选项与运行状态快照

import CoreGraphics
import DDMCore
import Foundation

/// 叠加层的可调选项。应用里用默认值即可（`OverlayHost()`）。
public struct OverlayOptions: Sendable, Equatable {
    /// 忽略一切"看不看得见"的判断：始终当作可见，并在每块屏上都建窗。
    /// **只给演示和测量用**（例如锁着屏测绘制开销）；应用里不要打开，否则没人看的时候也会照常出帧。
    public var assumesAlwaysVisible = false

    /// 每块屏最多保留几个桌面层窗口。桌面层窗口属于某一个桌面空间，每个去过的空间各留一个，
    /// 这样回到那个空间时脸和图标一起滑进来。设为 1 则每块屏只有一个窗口：
    /// 每次切换空间后都把它搬到新空间、等动画结束再淡入。
    public var maxDesktopWindowsPerDisplay = 6

    /// 系统在图标层前面放了整屏遮挡窗口时，是否认为"图标被隐藏了"并把脸也藏起来。
    /// macOS 27 上关掉"在桌面上显示项目"时就是这种遮挡（依据见 docs/模块说明/overlay.md）。
    /// 留这个开关是为了万一某个系统版本上判断有误，可以一行关掉。
    public var treatsDesktopShieldAsHidden = true

    public init() {}
}

/// 叠加层运行状态的快照。给演示程序、自检和排查问题用；不含任何用户数据。
public struct OverlayDiagnostics: Sendable, Equatable {
    /// 一块显示器上的情况。
    public struct Display: Sendable, Equatable {
        public var id: DisplayID
        /// 这块屏的全局矩形（点）。
        public var frame: CGRect
        public var scale: CGFloat
        /// 图标层的状态："visible" 看得见 / "absent" 屏上没有图标层（全屏空间等）/ "shielded" 被系统遮住（桌面项目被隐藏）。
        public var iconLayer: String
        /// 桌面层窗口总数（每个去过的空间一个）。
        public var desktopWindowCount: Int
        /// 这块屏当前的空间里有没有桌面层窗口。
        public var hasWindowOnActiveSpace: Bool
        /// 系统是否报告桌面层窗口被完全挡住。
        public var isOccluded: Bool
        /// 综合结论：这块屏的桌面层此刻有没有人看得见。
        public var isVisible: Bool
        /// 这块屏上的桌面层画布项数量。
        public var desktopItemCount: Int
        /// 这块屏上的拖拽层画布项数量。
        public var dragItemCount: Int
        /// 拖拽层窗口此刻是否显示着。
        public var isDragWindowShown: Bool
        /// 桌面层、拖拽层窗口的编号（在系统窗口列表里查它们用）。
        public var desktopWindowNumbers: [Int]
        public var dragWindowNumbers: [Int]
        /// 这块屏上所有叠加窗口是否都点击穿透。
        public var allWindowsIgnoreMouse: Bool
    }

    public var displays: [Display]
    public var isRunning: Bool
    public var isPaused: Bool
    public var isScreenLocked: Bool
    public var areDisplaysAsleep: Bool
    public var isSessionOnConsole: Bool
    public var isDesktopVisible: Bool
    /// 帧循环此刻的状态："every-refresh" 连续出帧 / "next-refresh" 等下一个刷新 / "timer" 定时器 / "sleep" 休息。
    public var frameLoop: String
    /// 节拍来源："displayRefresh" 显示刷新 / "timer" 备用定时器 / "stopped" 没在走。
    public var clockSource: String
    /// 启动以来的帧回调次数、绘制回调次数。
    public var frameCount: Int
    public var drawCount: Int
    /// 桌面层、拖拽层的窗口层级。
    public var desktopWindowLevel: Int
    public var dragWindowLevel: Int
}

/// 自检时读回的一个像素：颜色分量已乘过不透明度，范围都是 0…1。
public struct OverlayDebugPixel: Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    /// 不透明度：0 = 这一点什么都没画。
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}
