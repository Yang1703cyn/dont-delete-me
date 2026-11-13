// 「别删我」可执行入口。
//
// 菜单栏应用：不出现在程序坞，没有主窗口。
// 这个目标由 scaffold 搭好，之后归总览；它是全工程唯一同时依赖所有模块的地方。

import AppKit

let options = LaunchOptions(arguments: CommandLine.arguments)

// 已经有一个在运行：后启动的这个自己退出（见 SingleInstance.swift）。
if SingleInstance.anotherInstanceShouldStay() {
    if options.smokeTestDuration != nil {
        print("smoke-test: 已经有一个「别删我」在运行，这一个不启动。请先退出它再自检")
        print("smoke-test: FAIL")
        exit(1)
    }
    exit(0)
}

let delegate = AppDelegate(options: options)

let application = NSApplication.shared
application.delegate = delegate
// 与 Info.plist 里的 LSUIElement 一致；这样用 `swift run` 直接跑（没有 Info.plist）时也不进程序坞。
application.setActivationPolicy(.accessory)
application.run()
