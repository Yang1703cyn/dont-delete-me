// 界面文案。
//
// 打包后的 .app 里有 en.lproj / zh-Hans.lproj 两份 Localizable.strings（见 Resources/），
// 系统按用户语言自动选择。用 `swift run` 直接跑时没有这些文件，就落到下面写的中文默认值。

import Foundation

enum L10n {
    /// 应用名（菜单栏图标的辅助功能描述）。
    static var appName: String { text("app.name", "别删我") }
    /// 菜单项：暂停。
    static var pause: String { text("menu.pause", "暂停") }
    /// 菜单项：继续（暂停之后显示）。
    static var resume: String { text("menu.resume", "继续") }
    /// 菜单项：退出。
    static var quit: String { text("menu.quit", "退出") }

    private static func text(_ key: String, _ fallback: String) -> String {
        Bundle.main.localizedString(forKey: key, value: fallback, table: nil)
    }
}
