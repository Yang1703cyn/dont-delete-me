// FacesTests · 接口约定：外扩成档、刷新间隔、静止画面不随时间变、情绪标签不影响画面、参数连续变化

import CoreGraphics
import DDMCore
import Foundation
import Testing
@testable import Faces

@Suite("接口约定")
struct ContractTests {
    private let renderer = FaceRenderer()
    private let icon = CGSize(width: 64, height: 64)

    // MARK: - 外扩

    @Test func 外扩只有几档而且与强度无关() {
        // 往下流的泪：超过 0.4 才有，之后不管多强都是同一档。
        #expect(renderer.outsets(for: Sample.crying(0.4), iconSize: icon) == .zero)
        let tears = renderer.outsets(for: Sample.crying(0.41), iconSize: icon)
        #expect(tears == EdgeOutsets(bottom: 16))
        #expect(renderer.outsets(for: Sample.crying(1), iconSize: icon) == tears)
        // Zzz：超过 0.35 才有。
        #expect(renderer.outsets(for: Sample.dozing(0.35), iconSize: icon) == .zero)
        let zzz = renderer.outsets(for: Sample.dozing(0.36), iconSize: icon)
        #expect(zzz == EdgeOutsets(top: 14))
        #expect(renderer.outsets(for: Sample.dozing(1), iconSize: icon) == zzz)
        // 幽灵：与进度无关。
        let ghost = renderer.outsets(for: Sample.ghost(0), iconSize: icon)
        #expect(ghost == EdgeOutsets(top: 51))
        #expect(renderer.outsets(for: Sample.ghost(0.99), iconSize: icon) == ghost)
        // 其它表情都画在图标矩形以内。
        for state in [Sample.calm(), Sample.shy(), Sample.dizzy(), Sample.scared(), Sample.covering(1, peek: 1)] {
            #expect(renderer.outsets(for: state, iconSize: icon) == .zero)
        }
    }

    @Test func 随机参数下外扩也只落在固定的几档上() {
        var generator = SeededRandom(seed: 7)
        var seen: Set<[CGFloat]> = []
        for _ in 0..<2000 {
            let outsets = renderer.outsets(for: Sample.random(&generator), iconSize: icon)
            seen.insert([outsets.top, outsets.left, outsets.bottom, outsets.right])
        }
        // 没有 / 只有泪 / 只有 Zzz / 两者都有。
        #expect(seen == [[0, 0, 0, 0], [0, 0, 16, 0], [14, 0, 0, 0], [14, 0, 16, 0]])
    }

    @Test func 外扩随图标大小等比变化并取整() {
        for size in [CGFloat(32), 48, 64, 100, 128] {
            let side = CGSize(width: size, height: size)
            let tears = renderer.outsets(for: Sample.crying(), iconSize: side)
            #expect(tears.bottom == (size * 0.25).rounded(.up))
            #expect(tears.top == 0 && tears.left == 0 && tears.right == 0)
            let ghost = renderer.outsets(for: Sample.ghost(), iconSize: side)
            #expect(ghost.top == (size / 2 + 19 * size / 64).rounded(.up))
        }
    }

    // MARK: - 刷新间隔

    @Test func 没有循环小动画的表情返回nil() {
        #expect(renderer.animationInterval(for: FaceState(seed: 1)) == nil)
        #expect(renderer.animationInterval(for: Sample.calm()) == nil)
        #expect(renderer.animationInterval(for: Sample.shy()) == nil)
        #expect(renderer.animationInterval(for: Sample.covering(1, peek: 0.6)) == nil)
        // 犯困但还没睡着：只是眼皮耷下来，没有 Zzz。
        #expect(renderer.animationInterval(for: Sample.dozing(0.3)) == nil)
        // 害怕但没发抖、没出汗：一幅静止画面。
        #expect(renderer.animationInterval(for: FaceState(mood: .scared, seed: 1, fear: 0.8)) == nil)
        var blinking = Sample.calm()
        blinking.blink = 0.5
        #expect(renderer.animationInterval(for: blinking) == nil)
    }

    @Test func 快动画每帧重画而慢动画给出间隔() {
        #expect(renderer.animationInterval(for: Sample.scared()) == 0)       // 发抖
        #expect(renderer.animationInterval(for: Sample.dizzy(0.1)) == 0)     // 眼睛转圈
        #expect(renderer.animationInterval(for: Sample.crying(1)) == 0)      // 泪流
        #expect(renderer.animationInterval(for: Sample.ghost(0.5)) == 0)
        // 只有汗：每秒 30 次；只是泪汪汪：每秒 20 次；睡着：每秒 10 次。
        #expect(renderer.animationInterval(for: FaceState(seed: 1, sweat: 0.5)) == 1.0 / 30)
        #expect(renderer.animationInterval(for: FaceState(seed: 1, tears: 0.3)) == 1.0 / 20)
        #expect(renderer.animationInterval(for: Sample.dozing(1)) == 0.25)
        #expect(renderer.animationInterval(for: Sample.dozing(0.5)) == 0.25)
        // 几种同时出现时取最紧的。
        #expect(renderer.animationInterval(for: FaceState(seed: 1, sweat: 0.5, sleepiness: 1)) == 1.0 / 30)
    }

    @Test func 返回nil的表情画面确实不随时间变化() {
        // 这是省电的根基：应用看到 nil 就不再重画，所以画面绝不能偷偷依赖时间。
        var generator = SeededRandom(seed: 99)
        var checked = 0
        var attempts = 0
        while checked < 150, attempts < 5000 {
            attempts += 1
            var state = Sample.random(&generator)
            // 多造一些"安静"的状态：把会动的参数随机清零。
            if generator.nextUnit() < 0.8 { state.tremble = 0 }
            if generator.nextUnit() < 0.8 { state.dizziness = 0 }
            if generator.nextUnit() < 0.8 { state.sweat = 0 }
            if generator.nextUnit() < 0.7 { state.tears = min(state.tears, 0.05) }
            if generator.nextUnit() < 0.7 { state.sleepiness = min(state.sleepiness, 0.35) }
            guard renderer.animationInterval(for: state) == nil else { continue }
            checked += 1
            let early = render(state, time: 0.37).bytes
            let late = render(state, time: 912.11).bytes
            #expect(early == late, "声称是静止画面，但两个时刻画出来不一样：\(state)")
        }
        #expect(checked == 150)
    }

    @Test func 有循环小动画的表情画面确实在动() {
        for state in [Sample.scared(), Sample.dizzy(), Sample.crying(), Sample.dozing(), Sample.ghost(0.5),
                      FaceState(seed: 1, sweat: 0.8), FaceState(seed: 1, tears: 0.3)] {
            #expect(render(state, time: 0.37).bytes != render(state, time: 0.61).bytes, "\(state.mood) 应该随时间变化")
        }
    }

    // MARK: - 情绪标签

    @Test func 情绪标签不影响画面只有幽灵例外() {
        // 画面只看连续参数；标签切换的那一帧不能跳变。
        var generator = SeededRandom(seed: 5)
        for _ in 0..<25 {
            var state = Sample.random(&generator)
            state.mood = .calm
            let reference = render(state).bytes
            for mood in [FaceMood.shy, .dizzy, .scared, .crying, .coveringEyes, .dozing] {
                state.mood = mood
                #expect(render(state).bytes == reference, "标签换成 \(mood) 之后画面变了")
            }
        }
        // 非幽灵的标签下，幽灵进度不起作用。
        var state = Sample.calm()
        let reference = render(state).bytes
        state.ghost = 0.6
        #expect(render(state).bytes == reference)
    }

    // MARK: - 连续性

    /// 把一个参数从 0 扫到 1（每步 0.01），看相邻两帧之间有没有"突然跳一下"。
    /// 返回最大的一步变化占画面的比例，以及它出现在哪里。
    private func largestJump(
        sweeping keyPath: WritableKeyPath<FaceState, Double>, from base: FaceState
    ) -> (ratio: Double, at: Double) {
        var previous: [UInt8]?
        var steps: [Double] = []
        var painted = 1
        for index in 0...100 {
            var state = base
            state[keyPath: keyPath] = Double(index) / 100
            // 幽灵要升到图标上方，四周多留一些；其它表情留半个图标就够。
            let canvas = render(state, time: 0.4, margin: base.mood == .ghost ? 1 : 0.5)
            painted = max(painted, canvas.paintedCount)
            let image = canvas.bytes
            if let previous { steps.append(difference(previous, image)) }
            previous = image
        }
        // 一步的变化量，减去它前后两步里较大的那个：平滑的运动相邻几步差不多，突变则是一个孤立的尖峰。
        var worst = (ratio: 0.0, at: 0.0)
        for index in steps.indices {
            let before = index > 0 ? steps[index - 1] : 0
            let after = index + 1 < steps.count ? steps[index + 1] : 0
            let spike = (steps[index] - max(before, after)) / Double(painted)
            if spike > worst.ratio { worst = (spike, Double(index + 1) / 100) }
        }
        return worst
    }

    @Test func 每个参数连续变化时画面也连续变化() {
        // 两种底：其它参数全为 0；其它参数都在半程（中间状态也要成立）。
        var plain = FaceState(seed: testSeed, gazeTarget: CGVector(dx: 95, dy: 60), gazeFollow: 1)
        plain.cover = 0
        var busy = plain
        busy.blush = 0.5
        busy.fear = 0.5
        busy.sweat = 0.5
        busy.tears = 0.5
        busy.sleepiness = 0.3
        var covered = plain
        covered.cover = 1

        var report: [String] = []
        for parameter in FaceState.unitParameters where parameter.name != "ghost" {
            // 偷看只在捂着眼时有意义。
            let bases = parameter.name == "peek" ? [covered] : [plain, busy]
            for (index, base) in bases.enumerated() {
                let jump = largestJump(sweeping: parameter.keyPath, from: base)
                report.append(String(format: "%@%@ %.2f%%@%.2f", parameter.name, index == 0 ? "" : "(半程底)", jump.ratio * 100, jump.at))
                // 每一步（参数变 0.01）额外的变化不到画面的 1.5%：没有哪个东西是突然蹦出来的。
                #expect(jump.ratio < 0.015, "\(parameter.name) 在 \(jump.at) 附近画面突变了 \(jump.ratio * 100)%")
            }
        }
        print("[FacesTests] 参数扫一遍时最大的单步突变（占画面的比例@出现的位置）：\(report.joined(separator: "，"))")

        // 幽灵：进度连续变化时也连续（它的出现是唯一允许的突变，不在此列）。
        let ghost = largestJump(sweeping: \.ghost, from: FaceState(mood: .ghost, seed: testSeed))
        #expect(ghost.ratio < 0.015, "幽灵在进度 \(ghost.at) 附近突变了 \(ghost.ratio * 100)%")
    }
}
