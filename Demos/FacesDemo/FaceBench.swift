// FacesDemo · 绘制耗时
//
// 量"画一张脸要多久"：每种表情在一块离屏画布上连画很多次，取平均。
// 画布和叠加层给的一样（sRGB、y 向下、按像素倍数缩放），大小是"图标矩形 + 声明的外扩"。
// 调试版的数字偏大，只有发布版（swift run -c release FacesDemo --bench）的数字才算数。

import CoreGraphics
import DDMCore
import Faces
import Foundation

enum FaceBench {
    /// 一种要测的情形。
    struct Scenario: Sendable {
        let name: String
        /// 第 round 次画的时候用什么表情状态（让视线、参数像真实使用时那样每次都在变）。
        let state: @Sendable (Int) -> FaceState
    }

    static let seed = IconID(rawValue: 1).faceSeed

    static let scenarios: [Scenario] = [
        Scenario(name: "平静 · 视线跟随（最常见）") { round in
            // 鼠标绕着图标转：每次视线都不同。
            let angle = Double(round) * 0.05
            return ExpressionPreset.calm.state(
                seed: seed, intensity: 0, gaze: CGVector(dx: cos(angle) * 300, dy: sin(angle) * 200)
            )
        },
        Scenario(name: "平静 · 眨眼中") { round in
            var state = ExpressionPreset.calm.state(seed: seed, intensity: 0, gaze: CGVector(dx: 95, dy: 60))
            state.blink = 0.2 + 0.6 * Double(round % 10) / 10
            return state
        },
        Scenario(name: "害羞 100%") { _ in ExpressionPreset.shy.state(seed: seed, intensity: 1) },
        Scenario(name: "头晕 100%") { _ in ExpressionPreset.dizzy.state(seed: seed, intensity: 1) },
        Scenario(name: "害怕 50%") { _ in
            ExpressionPreset.scared.state(seed: seed, intensity: 0.5, gaze: CGVector(dx: 260, dy: 190))
        },
        Scenario(name: "害怕 100%") { _ in
            ExpressionPreset.scared.state(seed: seed, intensity: 1, gaze: CGVector(dx: 260, dy: 190))
        },
        Scenario(name: "哭 30%（泪汪汪）") { _ in ExpressionPreset.crying.state(seed: seed, intensity: 0.3) },
        Scenario(name: "哭 100%（眼泪直流）") { _ in ExpressionPreset.crying.state(seed: seed, intensity: 1) },
        Scenario(name: "捂眼 100%") { _ in ExpressionPreset.coveringEyes.state(seed: seed, intensity: 1) },
        Scenario(name: "捂眼 100% + 偷看") { _ in ExpressionPreset.coveringEyes.state(seed: seed, intensity: 1, peek: 1) },
        Scenario(name: "打瞌睡 50%") { _ in ExpressionPreset.dozing.state(seed: seed, intensity: 0.5) },
        Scenario(name: "打瞌睡 100%（睡熟）") { _ in ExpressionPreset.dozing.state(seed: seed, intensity: 1) },
        Scenario(name: "幽灵 40%") { _ in ExpressionPreset.ghost.state(seed: seed, intensity: 0.4) },
    ]

    /// 量一种情形：返回平均每次绘制的毫秒数。
    static func measure(_ scenario: Scenario, iconSize: CGFloat, scale: CGFloat, rounds: Int) -> Double {
        let renderer = FaceRenderer()
        // 画布留得足够大（四周各一个图标），不同表情用同一块画布。
        let canvasSize = CGSize(width: iconSize * 3, height: iconSize * 3)
        guard let canvas = SheetCanvas(size: canvasSize, scale: scale) else { return .nan }
        let rect = CGRect(x: iconSize, y: iconSize, width: iconSize, height: iconSize)
        // 先画几次热身（第一次会建立颜色等缓存）。
        for round in 0..<20 {
            renderer.draw(scenario.state(round), in: rect, context: canvas.context, time: Double(round) / 60)
        }
        let started = DispatchTime.now().uptimeNanoseconds
        for round in 0..<rounds {
            renderer.draw(scenario.state(round), in: rect, context: canvas.context, time: 100 + Double(round) / 60)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        return Double(elapsed) / Double(rounds) / 1_000_000
    }

    /// 把所有情形量一遍并打印成表。
    static func printTable(rounds: Int) {
        #if DEBUG
        let build = "调试版（数字偏大，仅供参考；真实耗时请用 swift run -c release FacesDemo --bench）"
        #else
        let build = "发布版"
        #endif
        // 正式开始前先空跑一阵：让处理器升到工作频率，免得排在第一行的情形吃亏。
        _ = measure(scenarios[0], iconSize: 64, scale: 2, rounds: max(rounds, 2000))
        print("[FacesDemo] 绘制耗时 · \(build) · 每种情形连画 \(rounds) 次取平均 · 单位：毫秒 / 张")
        print("[FacesDemo]   " + "情形".padding(toLength: 22, withPad: " ", startingAt: 0) + "  64点@2x   64点@1x  128点@2x   32点@2x")
        for scenario in scenarios {
            let cells = [(CGFloat(64), CGFloat(2)), (64, 1), (128, 2), (32, 2)].map { size, scale in
                String(format: "%8.3f", measure(scenario, iconSize: size, scale: scale, rounds: rounds))
            }
            // 中文字符在等宽终端里占两格：按显示宽度补齐。
            let width = scenario.name.unicodeScalars.reduce(0) { $0 + ($1.value > 0x2E80 ? 2 : 1) }
            let padding = String(repeating: " ", count: max(0, 28 - width))
            print("[FacesDemo]   \(scenario.name)\(padding) \(cells.joined(separator: "  "))")
        }
    }
}
