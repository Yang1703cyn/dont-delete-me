// Overlay · 桌面看不看得见（纯逻辑）
//
// 把系统给的零散信号（锁屏、屏幕睡眠、窗口列表、窗口遮挡、所在空间）归结成两个结论：
//   - 每块屏的桌面层此刻有没有人看得见（看不见就不在那块屏上作画）；
//   - 整个桌面层是否可见（`OverlayHosting.isDesktopVisible`，全都看不见就停止帧回调）。
// 这里全是值类型和纯函数；读取系统状态的代码在 SystemProbe.swift。

import CoreGraphics
import DDMCore
import Foundation

/// 访达的图标层在某块屏上的状态。
enum IconLayerState: String, Sendable, Equatable {
    /// 图标层窗口在屏上，前面没有遮挡——图标看得见。
    case visible
    /// 屏上没有图标层窗口：这块屏停在全屏应用的空间，或者访达没在运行、窗口被收起、被调成全透明。
    case absent
    /// 图标层窗口在，但被系统在同一层级放的一块遮挡窗口盖住了：
    /// 系统设置里关掉了"在桌面上显示项目"（或台前调度里不显示桌面项目）时就是这样。
    case shielded
}

/// 窗口列表里的一个窗口。只取判断需要的几项——不读窗口标题，也不读程序名。
struct WindowEntry: Equatable, Sendable {
    /// 窗口编号。
    var number: Int
    /// 所属进程。
    var ownerPID: Int32
    /// 窗口层级。
    var layer: Int
    /// 整窗透明度，0…1。
    var alpha: Double
    /// 窗口边界，全局坐标。
    var bounds: CGRect
}

enum IconLayerAnalysis {
    /// 透明度不超过这个值的窗口当作不存在（淡出到底的窗口）。
    static let minimumAlpha = 0.05
    /// 访达的图标层窗口至少盖住一块屏的这个比例，才算"这块屏的图标层"。
    static let finderCoverage: CGFloat = 0.5
    /// 别的窗口至少盖住一块屏的这个比例，才算"把图标层整个遮住了"。
    static let shieldCoverage: CGFloat = 0.9

    /// 判断图标层在某块屏上的状态。
    ///
    /// 依据（macOS 27 实测，见 docs/模块说明/overlay.md）：
    /// - 访达在每块屏上各有一个层级为"桌面图标层"的整屏窗口；这块屏停在全屏空间时，它不在"在屏窗口"里；
    /// - 系统隐藏桌面项目时并不动访达的窗口，而是在**同一层级、访达窗口的前面**放一块整屏的遮挡窗口。
    ///
    /// - Parameters:
    ///   - entries: 当前在屏的窗口，**从前到后**。
    ///   - finderPID: 访达的进程号；访达没在运行为 nil。
    ///   - ownPID: 本进程——自己的窗口不算遮挡。
    ///   - iconLevel: "桌面图标层"的层级值。
    static func state(
        on display: DisplayInfo,
        entries: [WindowEntry],
        finderPID: Int32?,
        ownPID: Int32,
        iconLevel: Int
    ) -> IconLayerState {
        guard let finderPID else { return .absent }
        var isShielded = false
        for entry in entries where entry.layer == iconLevel && entry.alpha > minimumAlpha {
            let coverage = self.coverage(of: display.frame, by: entry.bounds)
            if entry.ownerPID == finderPID {
                if coverage >= finderCoverage {
                    return isShielded ? .shielded : .visible
                }
            } else if entry.ownerPID != ownPID, coverage >= shieldCoverage {
                isShielded = true
            }
        }
        return .absent
    }

    /// `rect` 被 `cover` 盖住的面积比例，0…1。
    static func coverage(of rect: CGRect, by cover: CGRect) -> CGFloat {
        let area = rect.width * rect.height
        guard area > 0 else { return 0 }
        let overlap = rect.intersection(cover)
        guard !overlap.isNull else { return 0 }
        return overlap.width * overlap.height / area
    }
}

/// "图标层看得见"要连续成立一小段时间才作数；"看不见"立刻生效。
///
/// 为什么：切换空间、显示桌面这类过渡动画进行中，系统会短暂地撤掉再放回遮挡窗口。
/// 藏得快、出得慢，脸就不会在动画中途闪一下。
struct IconLayerTracker: Sendable {
    /// "看得见"要持续这么久才作数（秒）。
    static let confirmDelay: TimeInterval = 0.35

    private var visibleSince: [DisplayID: TimeInterval] = [:]
    private(set) var states: [DisplayID: IconLayerState] = [:]

    /// 某块屏生效中的状态；还没观察过的屏算 `.absent`。
    func state(for display: DisplayID) -> IconLayerState {
        states[display] ?? .absent
    }

    /// 记入一次观察。
    /// - Returns: 如果有"看得见"还在等确认，返回最早该复查的时刻；否则为 nil。
    mutating func ingest(_ observed: [DisplayID: IconLayerState], at now: TimeInterval) -> TimeInterval? {
        var nextStates: [DisplayID: IconLayerState] = [:]
        var nextSince: [DisplayID: TimeInterval] = [:]
        var recheckAt: TimeInterval?

        for (display, observation) in observed {
            guard observation == .visible else {
                nextStates[display] = observation
                continue
            }
            if states[display] == .visible {
                nextStates[display] = .visible
                continue
            }
            let since = visibleSince[display] ?? now
            if now - since >= Self.confirmDelay {
                nextStates[display] = .visible
            } else {
                nextStates[display] = states[display] ?? .absent
                nextSince[display] = since
                recheckAt = min(recheckAt ?? .infinity, since + Self.confirmDelay)
            }
        }

        states = nextStates
        visibleSince = nextSince
        return recheckAt
    }

    /// 清空（显示器布局变了之后）。
    mutating func reset() {
        states.removeAll()
        visibleSince.removeAll()
    }
}

/// 整个登录会话的状态：这些情况下屏幕上根本没有桌面可看。
struct SessionState: Equatable, Sendable {
    /// 锁屏中。
    var isScreenLocked = false
    /// 所有显示器都睡着了。
    var areDisplaysAsleep = false
    /// 电脑正要睡眠 / 还没醒。
    var isSystemAsleep = false
    /// 本用户的会话是否在前台（快速用户切换到别人时为 false）。
    var isOnConsole = true

    /// 用户此刻是否可能看得到桌面。
    var isLive: Bool {
        !isScreenLocked && !areDisplaysAsleep && !isSystemAsleep && isOnConsole
    }

    static let live = SessionState()
}

/// 一块屏的桌面层的各项信号。
struct StageSignals: Equatable, Sendable {
    /// 图标层的状态（已经过 `IconLayerTracker` 确认）。
    var iconLayer: IconLayerState
    /// 我们在这块屏当前的空间里有没有窗口。
    var hasWindowOnActiveSpace: Bool
    /// 我们的窗口是否被别的窗口完全挡住。
    var isOccluded: Bool
}

enum VisibilityModel {
    /// 这块屏的桌面层此刻有没有人看得见。
    static func isStageVisible(_ signals: StageSignals, session: SessionState) -> Bool {
        session.isLive && signals.iconLayer == .visible && signals.hasWindowOnActiveSpace && !signals.isOccluded
    }

    /// 桌面层是否对用户可见：至少有一块屏看得见。
    static func isDesktopVisible(session: SessionState, stages: [StageSignals]) -> Bool {
        stages.contains { isStageVisible($0, session: session) }
    }
}
