// 图标桥的独立演示程序。只依赖 DDMCore 和 IconBridge。
//
//   swift run IconBridgeDemo                  只读：打印桌面图标的数量、种类、矩形和 8 秒内的变化事件，然后自己结束
//   swift run IconBridgeDemo --watch 300      只读：同上，持续 300 秒（一边看一边在桌面上新建、拖动、删除文件）
//   swift run IconBridgeDemo --selftest       用自己的临时文件实测：新增 / 移动 / 消失 / 进废纸篓 / 磁盘
//   swift run IconBridgeDemo --drag-check     需要真人：新建一个临时图标，等你用鼠标拖它，报告访达多久更新位置，然后清理
//   swift run IconBridgeDemo --slow-drag-check 需要真人：按住图标很久才松手 / 才扔进废纸篓，看图标桥在访达不回应期间扛不扛得住
//   swift run IconBridgeDemo --displays       把一个临时图标依次放到每块显示器上，核对坐标和"所在显示器"
//   swift run IconBridgeDemo --bench          量读取耗时，以及不同轮询频率下本进程和访达的 CPU 占用（约 3 分钟）
//   swift run IconBridgeDemo --calibrate      截图校准锚点和标签矩形（需要屏幕亮着、已解锁、有录屏权限）
//   swift run IconBridgeDemo --stacks-check   打印图标桥对"叠放"的判断和依据（开关叠放前后各跑一次，用来确认识别得对不对）
//
// 任何模式的输出都不含文件名：图标用不可读的编号、种类和矩形表示。
// 写入类的模式只动自己新建的、名字以「别删我-测试」开头的临时文件，结束时清理。

import DDMCore
import Foundation
import IconBridge

let arguments = Array(CommandLine.arguments.dropFirst())

func argumentValue(after flag: String) -> Double? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return Double(arguments[index + 1])
}

let exitCode: Int32
if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    用法：swift run IconBridgeDemo [模式]
      （不带参数）      只读，打印图标与 8 秒内的变化后结束
      --watch [秒]      只读，持续打印（默认 60 秒）
      --selftest        用自己的临时文件实测新增 / 移动 / 消失 / 进废纸篓 / 磁盘
      --drag-check      真人拖动检查（加 --rehearse 则不等人，自己经访达改位置来演练流程）
      --slow-drag-check 真人检查：按住图标至少 25 秒再松手、再扔进废纸篓（加 --rehearse 则不等人）
      --displays        多显示器坐标核对
      --bench           读取耗时与 CPU 占用
      --calibrate       截图校准锚点（需要屏幕亮着、已解锁、有录屏权限；加 --force 跳过这项预检，只为检查流程）
      --stacks-check    打印图标桥对"叠放"的判断和依据
    """)
    exitCode = 0
} else if arguments.contains("--selftest") {
    exitCode = SelfTest().run()
} else if arguments.contains("--slow-drag-check") {
    exitCode = SlowDragCheck(rehearse: arguments.contains("--rehearse")).run()
} else if arguments.contains("--drag-check") {
    exitCode = DragCheck(rehearse: arguments.contains("--rehearse")).run()
} else if arguments.contains("--displays") {
    exitCode = DisplaysCheck().run()
} else if arguments.contains("--bench") {
    exitCode = Bench().run()
} else if arguments.contains("--calibrate") {
    exitCode = Calibrate(force: arguments.contains("--force")).run()
} else if arguments.contains("--stacks-check") {
    exitCode = StacksCheck().run()
} else if arguments.contains("--watch") {
    exitCode = runWatch(seconds: argumentValue(after: "--watch") ?? 60)
} else {
    exitCode = runWatch(seconds: 8)
}
exit(exitCode)
