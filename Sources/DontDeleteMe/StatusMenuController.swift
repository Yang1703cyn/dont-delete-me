// 菜单栏图标和它的菜单。菜单项只有两个：「暂停 / 继续」「退出」。

import AppKit
import DDMCore

@MainActor
final class StatusMenuController: NSObject {
    /// 打包时如果 Assets/ 里有菜单栏图标，会以这个名字放进应用（见 scripts/build-app.sh）。
    static let bundledIconName = "MenuBarIcon"
    /// 没有正式图标时用的系统符号（正式图标归 release）。
    static let placeholderSymbolName = "eyes"
    /// 菜单栏图标的标准高度，点。
    static let iconHeight: CGFloat = 18

    private let pause: PauseSwitch
    private let statusItem: NSStatusItem
    private let pauseItem: NSMenuItem
    private let quitItem: NSMenuItem
    private var pauseObservation: PauseObservation?

    init(pause: PauseSwitch = .shared) {
        self.pause = pause
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        pauseItem = NSMenuItem(title: L10n.pause, action: #selector(togglePause(_:)), keyEquivalent: "")
        quitItem = NSMenuItem(title: L10n.quit, action: #selector(quit(_:)), keyEquivalent: "q")
        super.init()

        pauseItem.target = self
        quitItem.target = self
        let menu = NSMenu()
        menu.addItem(pauseItem)
        menu.addItem(quitItem)
        statusItem.menu = menu

        if let button = statusItem.button {
            if let image = Self.makeIcon() {
                button.image = image
            } else {
                button.title = "👀"
            }
            button.setAccessibilityLabel(L10n.appName)
        }

        pauseObservation = pause.addObserver { [weak self] _ in self?.refresh() }
        refresh()
    }

    /// 菜单栏图标：优先用打包进来的正式图标，否则用系统符号占位。一律按模板图处理（自动适配深浅色菜单栏）。
    private static func makeIcon() -> NSImage? {
        let image: NSImage?
        if let bundled = Bundle.main.image(forResource: bundledIconName) {
            // 不管原图多大，统一缩到菜单栏图标的标准高度，宽度按比例。
            if bundled.size.height > 0 {
                let scale = iconHeight / bundled.size.height
                bundled.size = NSSize(width: bundled.size.width * scale, height: iconHeight)
            }
            image = bundled
        } else {
            image = NSImage(systemSymbolName: placeholderSymbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        }
        image?.isTemplate = true
        return image
    }

    /// 让菜单和图标跟上暂停状态：暂停时菜单项变成「继续」，图标变淡。
    private func refresh() {
        let paused = pause.isPaused
        pauseItem.title = paused ? L10n.resume : L10n.pause
        statusItem.button?.appearsDisabled = paused
    }

    // 以下几个只读属性供自检和测试使用。

    /// 菜单项标题，按显示顺序。
    var menuItemTitles: [String] { statusItem.menu?.items.map(\.title) ?? [] }
    /// 菜单栏图标是否已经有图像（或兜底文字）。
    var hasIcon: Bool { statusItem.button?.image != nil || !(statusItem.button?.title.isEmpty ?? true) }
    /// 系统是否把这个状态项摆进了菜单栏（用户可以在系统设置里把它关掉）。
    var isIconVisible: Bool { statusItem.isVisible && statusItem.button?.window != nil }
    /// 菜单栏图标在屏幕上的位置（AppKit 坐标）；没有摆进菜单栏时为 nil。
    var iconFrameOnScreen: CGRect? { statusItem.button?.window?.frame }
    /// 菜单栏图标所在窗口当前是否可见（没有被遮挡、没有被系统收起）。
    var isIconOnScreen: Bool { statusItem.button?.window?.occlusionState.contains(.visible) ?? false }

    @objc func togglePause(_ sender: Any?) {
        pause.toggle()
    }

    @objc func quit(_ sender: Any?) {
        NSApp.terminate(sender)
    }
}
