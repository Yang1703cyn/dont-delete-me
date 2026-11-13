// 交互感知（InputSense）的独立演示程序。只依赖 DDMCore 和 InputSense。
//
//   swift run InputSenseDemo                      剧本回放（瞬间跑完）+ 8 秒实时读数
//   swift run InputSenseDemo --script             只跑剧本回放
//   swift run InputSenseDemo --live [选项]        只跑实时读数（默认 20 秒）
//   swift run InputSenseDemo --trash-check [选项] 废纸篓估算核对（默认 20 秒）
//   swift run InputSenseDemo --drag-probe [选项]  拖拽探针：量访达的起拖阈值（默认 40 秒）
//   swift run InputSenseDemo --bench              各种读取要多久（约 15 秒）
//
// 选项：--seconds N（最长 120）  --ignore-shield（桌面图标被系统遮住时也当作桌面）
//       --show（把假图标和废纸篓估算画在屏幕上）  --quiet（不打印每秒一行的全貌）
//
// 所有模式都会自己结束，不留窗口和进程；全程只读，不产生任何鼠标键盘事件，不需要系统授权。

import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

func flag(_ name: String) -> Bool { arguments.contains(name) }

func seconds(default fallback: Double) -> Double {
    guard let index = arguments.firstIndex(of: "--seconds"), index + 1 < arguments.count,
          let value = Double(arguments[index + 1]), value > 0
    else { return fallback }
    return min(value, 120)   // 上限 120 秒：演示必须自己结束
}

if flag("--help") || flag("-h") {
    print("""
    用法：InputSenseDemo [--script | --live | --trash-check | --drag-probe | --bench]
                         [--seconds N] [--ignore-shield] [--show] [--quiet]
      （不带参数）    剧本回放 + 8 秒实时读数
      --script        只跑剧本回放：假的鼠标轨迹和假图标，模拟时间
      --live          实时读数：真实的鼠标、窗口遮挡和程序坞，假的图标
      --trash-check   废纸篓估算核对：把鼠标停在废纸篓正中，读出偏差
      --drag-probe    拖拽探针：真人拖一个真实的桌面图标，量访达的起拖阈值
      --bench         各种读取要多久
      --seconds N     运行多少秒（最长 120）
      --ignore-shield 桌面图标被系统遮住时也当作桌面
      --show          把假图标和废纸篓估算画在屏幕上（点击穿透、不抢焦点）
      --quiet         不打印每秒一行的全貌
    """)
    exit(0)
}

var liveOptions = LiveOptions()
liveOptions.ignoreShield = flag("--ignore-shield")
liveOptions.show = flag("--show")
liveOptions.statusLines = !flag("--quiet")

if flag("--script") {
    print("== 剧本回放（假的鼠标轨迹 + 假的图标，模拟时间，不读真实系统）==")
    exit(Replay().run() ? 0 : 1)
} else if flag("--live") {
    liveOptions.seconds = seconds(default: 20)
    runLive(liveOptions)
} else if flag("--trash-check") {
    runTrashCheck(seconds: seconds(default: 20), show: flag("--show"))
} else if flag("--drag-probe") {
    runDragProbe(seconds: seconds(default: 40))
} else if flag("--bench") {
    runBench()
} else {
    print("== 一、剧本回放（假的鼠标轨迹 + 假的图标，模拟时间，不读真实系统）==")
    let passed = Replay().run()
    print("")
    print("== 二、实时读数（真实的鼠标、窗口遮挡和程序坞；图标是假的）==")
    liveOptions.seconds = seconds(default: 8)
    runLive(liveOptions)
    exit(passed ? 0 : 1)
}
