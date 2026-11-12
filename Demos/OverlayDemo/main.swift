// OverlayDemo · 叠加层的独立演示程序
//
// 只依赖 DDMCore 和 Overlay。只用假的图标矩形，不读取桌面上的任何东西；
// 所有窗口都点击穿透、不抢焦点；任何模式都限时自动退出（最长 60 秒），也可以随时 Ctrl-C。
//
//   swift run OverlayDemo                         自动巡演：空闲 → 全员跟随 → 模拟拖拽，共约 20 秒
//   swift run OverlayDemo --mode follow           只看一种模式（idle / follow / drag），默认 20 秒
//   swift run OverlayDemo --self-check            自动自检（窗口层级、点击穿透、坐标、暂停、显示器变化……）
//   swift run OverlayDemo --probe                 打印系统状态：图标层看不看得见、为什么
//   swift run -c release OverlayDemo --bench      实测选定方案的处理器占用和帧率
//   swift run -c release OverlayDemo --bench-compare   对比几种绘制方式
//
// 公用参数：
//   --seconds N     运行多久（1…60）
//   --force         不管桌面看不看得见都照常建窗、出帧（锁屏时测试用）
//   --pointer mouse|synthetic|auto   指针用真实鼠标 / 自动绕圈的虚拟指针 / 鼠标停了就自动绕圈（默认）
//   --count N       假图标的个数（默认 30）
//   --single-window 每块屏只用一个桌面层窗口（切换空间后搬过去再淡入），用来和默认做法对比
//   --ignore-shield 不把系统的遮挡窗口当作"图标被隐藏"
//   --fine          视线不取整：指针一动，所有的脸每帧都重画（最坏情形，测量和排查用）

import AppKit
import DDMCore
import Foundation
import Overlay

let arguments = Arguments()

// 不出现在程序坞里，不抢前台。
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.finishLaunching()
Lifecycle.shared.install()

if arguments.has("--help") || arguments.has("-h") {
    print("""
    用法：
      swift run OverlayDemo                       自动巡演三种模式（约 20 秒）
      swift run OverlayDemo --mode idle|follow|drag [--seconds N]
      swift run OverlayDemo --self-check          自动自检
      swift run OverlayDemo --probe [--watch N]   打印 / 持续观察系统状态
      swift run -c release OverlayDemo --bench    实测处理器占用和帧率
      swift run -c release OverlayDemo --bench-compare
    公用参数：--seconds N（1…60） --force --pointer mouse|synthetic|auto --count N --single-window --ignore-shield
    """)
    exit(0)
}

if arguments.has("--self-check") {
    runSelfCheck(arguments)
} else if arguments.has("--probe") {
    runProbe(arguments)
} else if arguments.has("--bench") {
    runBench(arguments)
} else if arguments.has("--bench-compare") {
    runBenchCompare(arguments)
} else {
    runShow(arguments)
}

// MARK: - 巡演与单一模式

/// 按命令行参数造一个叠加层。
@MainActor
func makeHost(_ arguments: Arguments, pause: PauseSwitch = PauseSwitch()) -> OverlayHost {
    var options = OverlayOptions()
    options.assumesAlwaysVisible = arguments.has("--force")
    if arguments.has("--single-window") { options.maxDesktopWindowsPerDisplay = 1 }
    if arguments.has("--ignore-shield") { options.treatsDesktopShieldAsHidden = false }
    return OverlayHost(pause: pause, options: options)
}

@MainActor
func runShow(_ arguments: Arguments) -> Never {
    let layout = DisplayLayout.current()
    let source = DemoSource(icons: FakeDesktop.icons(count: arguments.int("--count", default: 30), on: layout), layout: layout)
    source.pointerSource = PointerSource(rawValue: arguments.value("--pointer") ?? "auto") ?? .auto
    if arguments.has("--fine") { source.gazeSteps = 1_048_576 }
    source.drawsNothing = arguments.has("--empty-draw")     // 排查用：重画时不画内容，只剩叠加层自己的开销
    source.eyesOnly = arguments.has("--eyes-only")          // 排查用：只画两只眼睛

    let host = makeHost(arguments)
    host.frameSource = source
    host.onDesktopVisibilityChange = { visible in
        print("[OverlayDemo] 桌面\(visible ? "看得见了：开始出帧" : "看不见了：停止出帧")")
    }
    Lifecycle.shared.onExit { host.stop() }

    let phases: [(DemoMode, TimeInterval)]
    if let name = arguments.value("--mode") {
        guard let mode = DemoMode(rawValue: name) else {
            print("[OverlayDemo] 不认识的模式：\(name)（可选：idle / follow / drag）")
            exit(2)
        }
        phases = [(mode, arguments.seconds("--seconds", default: 20))]
    } else {
        phases = [(.idle, 5), (.follow, 7), (.drag, 8)]
    }

    print("[OverlayDemo] \(layout.displays.count) 块屏，\(source.icons.count) 个假图标。所有窗口点击穿透、不抢焦点；随时可以 Ctrl-C。")
    host.start()
    spin(0.6)   // 等"图标层看得见"确认完
    if !host.isDesktopVisible {
        print("[OverlayDemo] 桌面此刻看不见，所以不出帧、不作画（这是正常行为）。原因见下面的状态；想强制作画请加 --force。")
        print(describe(host.diagnostics))
    }

    for (index, (mode, seconds)) in phases.enumerated() {
        guard !Lifecycle.shared.shouldQuit else { break }
        source.mode = mode
        source.resetCounters()
        host.requestFrame()
        let meter = CPUMeter()
        spin(seconds)
        let rate = Double(source.frames) / seconds
        print(
            "[OverlayDemo] [\(index + 1)/\(phases.count)] \(mode.title) \(format(seconds, 0)) 秒："
                + "帧回调 \(source.frames) 次（每秒 \(format(rate))），重画 \(source.draws) 次，"
                + "本进程处理器占用 \(format(meter.percent))%"
        )
    }

    print("[OverlayDemo] 结束时的状态：")
    print(describe(host.diagnostics))
    if source.timeRuleViolations > 0 {
        print("[OverlayDemo] ✘ 帧时间超前于系统时钟 \(source.timeRuleViolations) 次（违反约定）")
        Lifecycle.shared.finish(code: 1)
    }
    print("[OverlayDemo] 演示结束，窗口已全部关闭。")
    Lifecycle.shared.finish(code: 0)
}
