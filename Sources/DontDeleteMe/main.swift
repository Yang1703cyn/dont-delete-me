// 「别删我」可执行入口。
//
// 菜单栏应用：不出现在程序坞，没有主窗口。
// 这个目标由 scaffold 搭好，之后归总览；它是全工程唯一同时依赖所有模块的地方。

import AppKit

let options = LaunchOptions(arguments: CommandLine.arguments)
let delegate = AppDelegate(options: options)

let application = NSApplication.shared
application.delegate = delegate
// 与 Info.plist 里的 LSUIElement 一致；这样用 `swift run` 直接跑（没有 Info.plist）时也不进程序坞。
application.setActivationPolicy(.accessory)
application.run()
