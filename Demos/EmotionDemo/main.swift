// EmotionDemo · 情绪引擎的时间线打印程序
//
//   swift run EmotionDemo                      依次跑完全部内置剧本，逐行打印每个图标的表情和关键参数
//   swift run EmotionDemo --list               列出剧本
//   swift run EmotionDemo --script trash       只跑一条（名字见 --list，可以写多个）
//   swift run EmotionDemo --every 0.25         改成每 0.25 秒打印一次（默认每条剧本各有一个合适的间隔）
//   swift run -c release EmotionDemo --bench   量 100 个图标一次更新的耗时
//
// 只依赖 DDMCore 和 Emotion。图标数据全是编造的，时间是模拟的：不读真实桌面、不读鼠标、不开窗口，
// 瞬间跑完、自己结束，每次输出完全相同。每条剧本末尾有一段自己核对的"小结"；有一条不符合预期，退出码就是 1。

import DDMCore
import Emotion
import Foundation

var arguments = Array(CommandLine.arguments.dropFirst())
var selected: [String] = []
var every: TimeInterval?
var mode = "scripts"
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--bench":
        mode = "bench"
    case "--list":
        mode = "list"
    case "--script":
        if !arguments.isEmpty { selected.append(arguments.removeFirst()) }
    case "--every":
        if !arguments.isEmpty { every = TimeInterval(arguments.removeFirst()) }
    default:
        print("不认识的参数：\(argument)。可用：--list、--script <名字>、--every <秒>、--bench")
        exit(2)
    }
}

switch mode {
case "bench":
    runBench()
case "list":
    for script in scripts {
        print("\(pad(script.key, 14))\(pad(script.title, 28))\(script.synopsis)")
    }
default:
    let chosen = selected.isEmpty ? scripts : scripts.filter { selected.contains($0.key) }
    if chosen.isEmpty {
        print("没有这个剧本。可用的名字：" + scripts.map(\.key).joined(separator: "、"))
        exit(2)
    }
    if let every, !(every > 0) {
        print("--every 后面要跟一个正数（秒）")
        exit(2)
    }
    var failures = 0
    for (index, script) in chosen.enumerated() {
        print("")
        print("━━━━ 剧本 \(index + 1)/\(chosen.count)：\(script.title)（\(script.key)）━━━━")
        print(script.synopsis)
        failures += script.run(every)
    }
    print("")
    if failures == 0 {
        print("[EmotionDemo] \(chosen.count) 条剧本全部符合预期。")
    } else {
        print("[EmotionDemo] 有 \(failures) 处不符合预期（上面带 ✘ 的行）。")
        exit(1)
    }
}
