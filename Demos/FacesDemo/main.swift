// 表情绘制的独立演示程序。只依赖 DDMCore 和 Faces（外加系统框架）。在工程根目录下运行：
//
//   swift run FacesDemo                     不带参数：离屏自检 + 耗时一览，几秒内自己结束；不开窗口、不写文件
//   swift run FacesDemo --play              试玩窗口：眼睛跟着鼠标动，可以切换表情和强度、播放连续演示；关窗即退出
//   swift run FacesDemo --play --seconds 5  同上，5 秒后自己退出（加 --autoplay 则一打开就播放连续演示）
//   swift run FacesDemo --play --selfcheck  打开试玩窗口自检一遍（约 15 秒）：在进程内触发每个按钮、滑杆的动作并播放连续演示
//   swift run FacesDemo --bench             绘制耗时表，以及睡着的脸每秒的开销（要看真实数字请加 -c release）
//   swift run -c release FacesDemo --sleep-sheet  睡着的脸省电前后的逐帧对比：docs/样张/睡着-省电前后.png（见 SleepSheet.swift）
//   swift run FacesDemo --sheets            生成 docs/样张/全表情.png 和 docs/样张/试玩窗口.png
//   swift run FacesDemo --snapshot --at 6   不开窗口，把连续演示第 6 秒的窗口画面存成 docs/样张/试玩窗口.png
//   swift run FacesDemo --style-proposal    重新生成第一阶段的风格提案样张（三种待选风格的画法在 Proposal/ 里）
//
// 安全线：只用系统自带的通用图标，不读用户的任何文件；图片只写到 docs/样张/；
// 试玩窗口是普通窗口，不置顶、不全屏、不点击穿透。

import AppKit
import CoreGraphics
import DDMCore
import Faces
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

/// 取"--名字 数值"形式的参数。
func value(after flag: String) -> Double? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return Double(arguments[index + 1])
}

func report(_ urls: [URL]) {
    for url in urls {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        print("[FacesDemo] 已写出 docs/样张/\(url.lastPathComponent)（\(bytes / 1024) KB）")
    }
}

do {
    switch arguments.first {
    case nil:
        guard runOffscreenCheck() else { exit(1) }
        FaceBench.printTable(rounds: 300)
        print("[FacesDemo] 离屏自检结束。试玩窗口：swift run FacesDemo --play")
    case "--play":
        if arguments.contains("--selfcheck") {
            Playground.selfCheck()
        } else {
            Playground.run(seconds: value(after: "--seconds"), autoplay: arguments.contains("--autoplay"))
        }
    case "--bench":
        FaceBench.printTable(rounds: Int(value(after: "--rounds") ?? 3000))
        FaceBench.printSleepTable(rounds: Int(value(after: "--rounds") ?? 3000))
    case "--sleep-strip":
        // 用当前的绘制代码出一条睡着的脸的逐帧样张：docs/样张/睡着-<名字>-逐帧.png。
        let name = arguments.count > 1 && !arguments[1].hasPrefix("--") ? arguments[1] : "现在"
        report([try SleepSheet.writeStrip(name: name, period: value(after: "--period") ?? SleepSheet.breathPeriod)])
    case "--sleep-sheet":
        // 把 睡着-省电前-逐帧.png 和当前代码现画的逐帧拼成 docs/样张/睡着-省电前后.png。
        report([try SleepSheet.writeComparison()])
    case "--sheets":
        report(try ExpressionSheet.generate())
        report([try Playground.snapshot(scriptTime: 4.4)])
    case "--snapshot":
        // 把试玩窗口某一刻的画面存成 docs/样张/试玩窗口.png：--at 秒数 是连续演示的第几秒；不给就是"自动"玩法。
        report([try Playground.snapshot(scriptTime: value(after: "--at"))])
    case "--style-proposal":
        report(try StyleProposal.generate())
    default:
        print("用法：swift run FacesDemo [--play [--seconds N] [--autoplay] [--selfcheck] | --bench | --sheets | --snapshot [--at 秒] | --sleep-strip 名字 [--period 秒] | --sleep-sheet | --style-proposal]")
        exit(2)
    }
} catch {
    print("[FacesDemo] 失败：\(error)")
    exit(1)
}

/// 不带参数时的自检：把 8 种表情在几种大小下各画一遍，确认都画得出东西、没有画到声明的范围之外。
/// 全部在离屏画布上进行，不开窗口、不写文件。
@MainActor
func runOffscreenCheck() -> Bool {
    let renderer = FaceRenderer()
    let seed = IconID(rawValue: 1).faceSeed
    var failures = 0
    for preset in ExpressionPreset.allCases {
        var summary: [String] = []
        for size in [CGFloat(32), 64, 128] {
            let state = preset.state(seed: seed, intensity: preset == .ghost ? 0.5 : 1, gaze: CGVector(dx: 95, dy: 60))
            let rect = CGRect(x: size * 1.5, y: size * 1.5, width: size, height: size)
            guard let canvas = SheetCanvas(size: CGSize(width: size * 4, height: size * 4), scale: 2) else {
                print("[FacesDemo] 创建离屏画布失败")
                return false
            }
            renderer.draw(state, in: rect, context: canvas.context, time: 0.4)
            let allowed = rect.expanded(by: renderer.outsets(for: state, iconSize: rect.size))
            let counts = paintedPixels(in: canvas, allowed: allowed)
            if counts.inside == 0 || counts.outside > 0 { failures += 1 }
            summary.append("\(Int(size)) 点 \(counts.inside) 像素" + (counts.outside > 0 ? "（越界 \(counts.outside)）" : ""))
        }
        let interval = renderer.animationInterval(
            for: preset.state(seed: seed, intensity: preset == .ghost ? 0.5 : 1)
        )
        let pace = interval.map { $0 == 0 ? "每帧重画" : "每 \($0) 秒重画" } ?? "静止画面"
        print("[FacesDemo] \(preset.title)：\(summary.joined(separator: "，"))；\(pace)")
    }
    if failures > 0 {
        print("[FacesDemo] 有 \(failures) 项没通过（什么都没画出来，或画到了声明的范围之外）")
    }
    return failures == 0
}

/// 数一数画布上画了东西的像素：落在允许范围（点）之内的、之外的各多少。
func paintedPixels(in canvas: SheetCanvas, allowed: CGRect) -> (inside: Int, outside: Int) {
    let context = canvas.context
    guard let data = context.data else { return (0, 0) }
    let bytes = data.assumingMemoryBound(to: UInt8.self)
    var inside = 0
    var outside = 0
    for row in 0..<context.height {
        for column in 0..<context.width where bytes[row * context.bytesPerRow + column * 4 + 3] > 0 {
            // 这个像素覆盖的那一小块（点）是否完全在允许范围之外。
            let pixel = CGRect(
                x: CGFloat(column) / canvas.scale, y: CGFloat(row) / canvas.scale,
                width: 1 / canvas.scale, height: 1 / canvas.scale
            )
            if pixel.intersects(allowed) { inside += 1 } else { outside += 1 }
        }
    }
    return (inside, outside)
}
