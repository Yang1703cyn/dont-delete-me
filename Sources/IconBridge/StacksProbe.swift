// IconBridge · 判断桌面是否开启了"叠放"
//
// 开了叠放之后，访达报告的图标位置对不上屏幕上的样子，脸会画在过期的位置上——所以要认出来，报告 `stacksEnabled`，什么都不画。
//
// 访达的脚本接口里没有"叠放"这个开关可读（实测：桌面窗口的显示选项只有排列方式、图标大小、文字大小、标签位置等几项）。
// 所以用两条办法（总览定的方案 A+B）：
//
//   B（主要依据）：读访达自己的一项桌面显示设置——偏好设置域 com.apple.finder 里
//       DesktopViewSettings 这一组设置中的 GroupBy（桌面按什么分组）。没开叠放时没有这一项（本机实测），
//       或者是"None"；开了叠放时是分组的依据（例如 Kind）。
//       这和图标桥本来就要读的图标大小、文字大小、标签位置是同一类信息：不是用户的文件，不含文件名，读它不需要任何授权。
//       限定条件：只读不写；经系统的偏好设置接口读，不按路径打开偏好文件；只取这一个值，同组的其它设置读到后立即丢弃，
//       不打印、不记录；读不到或格式不认识就当作"无法判断"，绝不因此判定"开了叠放"。
//
//   A（兜底）：B 无法判断时，看访达报告的位置——有好几个图标的位置完全相同，就认为是叠放。
//
// 两条办法都还没有在"真的开了叠放"的桌面上验证过（不能替用户切换叠放）；验证办法见 docs/模块说明/icon-bridge.md。

import CoreGraphics
import Foundation

/// 判断桌面是否开启了叠放（办法 B 的接口）。在图标桥的后台队列上调用，必须很快、不向访达发请求。
protocol StacksProbing: Sendable {
    /// true = 开了；false = 没开；nil = 无法判断（图标桥随后用办法 A 兜底）。
    func stacksEnabled() -> Bool?
}

/// 访达"桌面按什么分组"这一项设置读出来的样子。
enum DesktopGroupBySetting: Equatable, Sendable {
    /// 读不到那一组桌面显示设置（没有、或者不是预期的格式）。
    case unreadable
    /// 那一组设置读到了，里面没有"分组"这一项——没开叠放时就是这样。
    case absent
    /// 有这一项，是一段文字。
    case value(String)
    /// 有这一项，但不是文字。
    case unrecognized

    /// 由"桌面显示设置"那一组的原始值取出"分组"这一项。只看这一项，别的都不碰。
    static func parse(desktopViewSettings: Any?) -> DesktopGroupBySetting {
        guard let settings = desktopViewSettings as? [String: Any] else { return .unreadable }
        guard let groupBy = settings[FinderPreferenceStacksProbe.groupByKey] else { return .absent }
        guard let text = groupBy as? String else { return .unrecognized }
        return .value(text)
    }

    /// 这个取值说明叠放开没开；nil 表示无法判断。
    var stacksEnabled: Bool? {
        switch self {
        case .unreadable, .unrecognized:
            return nil
        case .absent:
            return false
        case let .value(text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }                       // 空的：不认识，无法判断
            return trimmed.caseInsensitiveCompare("None") != .orderedSame   // "None" = 不分组；其余 = 按某种依据分组，也就是叠放
        }
    }
}

/// 办法 B：读访达的那一项桌面显示设置。
struct FinderPreferenceStacksProbe: StacksProbing {
    static let finderDomain = "com.apple.finder"
    static let desktopViewSettingsKey = "DesktopViewSettings"
    static let groupByKey = "GroupBy"

    /// 怎样读出"分组"这一项。默认经系统的偏好设置接口读；测试里换成假的。
    var read: @Sendable () -> DesktopGroupBySetting = FinderPreferenceStacksProbe.readFromSystem

    func stacksEnabled() -> Bool? {
        read().stacksEnabled
    }

    /// 经系统的偏好设置接口读（只读，不写；不直接打开偏好文件）。
    static func readFromSystem() -> DesktopGroupBySetting {
        let domain = finderDomain as CFString
        // 系统会缓存别的应用的偏好设置；先同步一下，访达刚改过的值才读得到。
        CFPreferencesAppSynchronize(domain)
        // 系统接口只能按顶层的键取值，所以取回的是"桌面显示设置"这一组；这里只取其中的"分组"一项，其余立即丢弃。
        let settings = CFPreferencesCopyAppValue(desktopViewSettingsKey as CFString, domain)
        return DesktopGroupBySetting.parse(desktopViewSettings: settings)
    }
}

/// 办法 A：由访达报告的位置判断。
enum StacksHeuristic {
    /// 至少要有这么多个图标的位置完全相同，才认为是叠放。
    /// 正常的桌面上两个图标偶尔会被摆在同一个网格点上，三个以上完全重合就很反常了。
    static let coincidenceThreshold = 3

    static func looksStacked(positions: [CGPoint]) -> Bool {
        var counts: [String: Int] = [:]
        for position in positions {
            let key = "\(position.x),\(position.y)"
            counts[key, default: 0] += 1
            if counts[key, default: 0] >= coincidenceThreshold { return true }
        }
        return false
    }
}
