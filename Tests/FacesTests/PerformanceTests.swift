// FacesTests · 绘制耗时
//
// 测试是用调试版跑的，数字比真实使用时大好几倍，所以这里只打印出来、卡一个很宽的上限，防止出现数量级的退步。
// 真实耗时请用发布版量：swift run -c release FacesDemo --bench（数据记在 docs/模块说明/faces.md 里）。

import CoreGraphics
import DDMCore
import Foundation
import Testing
@testable import Faces

@Suite("绘制耗时")
struct PerformanceTests {
    /// 平均画一次要多少毫秒（64 点图标、2x）。
    private func milliseconds(_ state: FaceState, rounds: Int = 400) -> Double {
        let renderer = FaceRenderer()
        let rect = CGRect(x: 200, y: 300, width: 64, height: 64)
        let canvas = TestCanvas(frame: rect.insetBy(dx: -64, dy: -64), scale: 2)
        for round in 0..<20 { renderer.draw(state, in: rect, context: canvas.context, time: Double(round) / 60) }
        let started = DispatchTime.now().uptimeNanoseconds
        for round in 0..<rounds {
            renderer.draw(state, in: rect, context: canvas.context, time: 100 + Double(round) / 60)
        }
        return Double(DispatchTime.now().uptimeNanoseconds - started) / Double(rounds) / 1_000_000
    }

    @Test func 各表情的绘制耗时() {
        let cases: [(String, FaceState)] = [
            ("平静跟随", Sample.calm()), ("害羞", Sample.shy()), ("头晕", Sample.dizzy()), ("害怕", Sample.scared()),
            ("哭", Sample.crying()), ("捂眼", Sample.covering(1, peek: 1)), ("打瞌睡", Sample.dozing()), ("幽灵", Sample.ghost()),
        ]
        var lines: [String] = []
        for (name, state) in cases {
            let cost = milliseconds(state)
            lines.append(String(format: "%@ %.3f", name, cost))
            // 预算是发布版每张约 0.3 毫秒。调试版慢几倍，这里只防数量级的退步。
            #expect(cost < 3, "\(name) 画一次要 \(cost) 毫秒，太慢了")
        }
        print("[FacesTests] 绘制耗时（调试版，64 点 @2x，毫秒 / 张）：\(lines.joined(separator: "，"))")
    }
}
