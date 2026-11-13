// FacesTests · 睡着的脸：省电与低帧率下的观感
//
// 桌面上睡着的图标是常态，它们每秒要重画几次，这一项决定了空闲时的耗电。
// 这里检查三件事：重画得够少；按这个帧率取的相邻两帧之间变化够小（不显得卡、没有突变）；画得够便宜。

import CoreGraphics
import DDMCore
import Foundation
import Testing
@testable import Faces

@Suite("睡着的脸")
struct SleepTests {
    private let renderer = FaceRenderer()
    /// 应用里每隔多久重画一张睡着的脸。
    private var frame: TimeInterval { renderer.animationInterval(for: Sample.dozing(1)) ?? 0 }

    private func pose(_ state: FaceState, size: CGFloat = 64, time: TimeInterval) -> FacePose {
        FacePose(params: FaceParams(state), rect: CGRect(x: 200, y: 300, width: size, height: size), time: time)
    }

    @Test func 睡着时每秒最多重画4次() {
        for level in stride(from: 0.36, through: 1.0, by: 0.01) {
            let interval = renderer.animationInterval(for: Sample.dozing(level))
            #expect(interval == 0.25, "困意 \(level)：刷新间隔 \(String(describing: interval))")
        }
        // 困意还没到门槛：没有 Zzz、不起伏，是静止画面。
        #expect(renderer.animationInterval(for: Sample.dozing(0.35)) == nil)
    }

    @Test(arguments: [32, 64, 128] as [CGFloat])
    func 相邻两帧之间起伏和Z都只动一点点(size: CGFloat) {
        // 按应用里的帧率连续取两个多周期；起点错开几种，覆盖各种相位。
        let u = size / 64
        for start in [0.0, 0.07, 0.13, 0.19] {
            var previous = pose(Sample.dozing(1), size: size, time: 100 + start)
            for step in 1...36 {
                let current = pose(Sample.dozing(1), size: size, time: 100 + start + Double(step) * frame)
                // 起伏：整张脸每帧上下移动不到 0.3u（64 点图标上不到 0.3 点）。
                let bob = abs(current.eyeLine.y - previous.eyeLine.y)
                #expect(bob < 0.3 * u, "\(size) 点：起伏一帧跳了 \(bob) 点")
                // 前后两帧都在的 Z：位置每帧移动不到 0.3u，大小最多变 25%。
                for letter in current.zzz {
                    guard let before = previous.zzz.first(where: { $0.index == letter.index }) else { continue }
                    let moved = letter.center.distance(to: before.center)
                    #expect(moved < 0.3 * u, "\(size) 点：第 \(letter.index) 个 Z 一帧跳了 \(moved) 点")
                    let ratio = max(letter.half, before.half) / min(letter.half, before.half)
                    #expect(ratio < 1.26, "\(size) 点：第 \(letter.index) 个 Z 一帧大小变了 \(ratio) 倍")
                }
                // 每帧最多冒出一个、消失一个 Z；冒出来的那个不到原大。
                let appeared = current.zzz.filter { letter in !previous.zzz.contains { $0.index == letter.index } }
                let vanished = previous.zzz.filter { letter in !current.zzz.contains { $0.index == letter.index } }
                #expect(appeared.count <= 1 && vanished.count <= 1)
                for letter in appeared {
                    // 原大：小图标上最小的那个放大到和中间那个一样。
                    let base = FaceStyle.zzzLetters[letter.index].half
                    let full = (current.fine ? base : max(base, FaceStyle.zzzLetters[1].half)) * current.s
                    #expect(letter.half < full * 0.99, "刚冒出来的 Z 应该比原大小一点")
                }
                previous = current
            }
        }
    }

    @Test func 睡熟时任何时候都有Z在而且整串是连着往上飘的() {
        // 每 0.05 秒看一次，一个完整周期：至少有一个 Z；最上面那个 Z 消失之前，下一轮最下面的 z 已经冒出来了。
        for size in [CGFloat(32), 64, 128] {
            for step in 0..<80 {
                let letters = pose(Sample.dozing(1), size: size, time: 100 + Double(step) * 0.05).zzz
                #expect(!letters.isEmpty, "\(size) 点、第 \(Double(step) * 0.05) 秒：一个 Z 都没有")
            }
        }
        // 64 点：Z 由下往上、由小到大。
        for step in 0..<16 {
            let letters = pose(Sample.dozing(1), time: 100 + Double(step) * 0.25).zzz
            for (lower, upper) in zip(letters, letters.dropFirst()) {
                #expect(upper.center.y < lower.center.y && upper.index > lower.index)
            }
        }
    }

    @Test func 睡着时任何时刻都不超出声明的范围() {
        // Z 在停留的最后时刻飘得最高：按很密的时间间隔取一整个周期，各种大小、长方形的矩形都试一遍。
        let sizes = [CGSize(width: 32, height: 32), CGSize(width: 48, height: 48), CGSize(width: 64, height: 64),
                     CGSize(width: 128, height: 128), CGSize(width: 90, height: 64), CGSize(width: 33, height: 51)]
        var problems: [String] = []
        for size in sizes {
            for scale in [CGFloat(1), 2] {
                for step in 0..<40 {
                    let time = 100 + Double(step) * 0.1
                    for level in [0.5, 0.9, 1.0] {
                        let state = Sample.dozing(level)
                        let rect = CGRect(origin: CGPoint(x: 200, y: 300), size: size)
                        let canvas = TestCanvas(frame: rect.insetBy(dx: -size.width, dy: -size.height), scale: scale)
                        renderer.draw(state, in: rect, context: canvas.context, time: time)
                        let allowed = rect.expanded(by: renderer.outsets(for: state, iconSize: size))
                        if let painted = canvas.paintedBounds, !allowed.contains(painted) {
                            problems.append("\(size) @\(Int(scale))x 困意 \(level) t=\(time)：允许 \(allowed)，实际 \(painted)")
                        }
                    }
                }
            }
        }
        #expect(problems.isEmpty, "\(problems.count) 处越界，前几处：\(problems.prefix(3))")
    }

    @Test func 睡熟时的小圆嘴和一般画法几乎一样() {
        // 困意 0.9 起嘴是"纯粹睡着"的小圆嘴，改用三个椭圆画；0.89 时还掺着一点微笑，走一般的画法。
        // 两者相差 0.01 的困意，画面只能差一点点（没有突变）。
        #expect(MouthShape(pose: pose(Sample.dozing(0.9), time: 100)).isSnoreOnly)
        #expect(!MouthShape(pose: pose(Sample.dozing(0.89), time: 100)).isSnoreOnly)
        // 掺了别的情绪就不是纯粹睡着了。
        var scared = Sample.dozing(1)
        scared.fear = 0.2
        #expect(!MouthShape(pose: pose(scared, time: 100)).isSnoreOnly)

        for size in [CGFloat(32), 64, 128] {
            let general = render(Sample.dozing(0.899), size: size, time: 100.6, margin: 0.5)
            let ellipse = render(Sample.dozing(0.9), size: size, time: 100.6, margin: 0.5)
            let changed = difference(general.bytes, ellipse.bytes)
            let ratio = changed / Double(ellipse.paintedCount)
            #expect(ratio < 0.02, "\(size) 点：换画法的那一刻画面变了 \(ratio * 100)%")
        }
    }

    @Test func 睡熟的脸画一次不比平静的脸贵() {
        // 测试是调试版，绝对耗时没有意义；拿最常见的"平静跟随"作参照，比相对值（各量三遍取最快的一遍，减少偶然的干扰）。
        // 省电前，睡熟的脸画一次约是平静跟随的 3～4 倍；现在发布版里不到它的一半，调试版里两者差不多。
        func milliseconds(_ state: FaceState, step: TimeInterval) -> Double {
            let rect = CGRect(x: 200, y: 300, width: 64, height: 64)
            let canvas = TestCanvas(frame: rect.insetBy(dx: -64, dy: -64), scale: 2)
            for round in 0..<40 { renderer.draw(state, in: rect, context: canvas.context, time: Double(round) * step) }
            let rounds = 600
            let started = DispatchTime.now().uptimeNanoseconds
            for round in 0..<rounds {
                renderer.draw(state, in: rect, context: canvas.context, time: 100 + Double(round) * step)
            }
            return Double(DispatchTime.now().uptimeNanoseconds - started) / Double(rounds) / 1_000_000
        }
        let calm = (0..<3).map { _ in milliseconds(Sample.calm(), step: 1.0 / 60) }.min() ?? 0
        let asleep = (0..<3).map { _ in milliseconds(Sample.dozing(1), step: frame) }.min() ?? 0
        print(String(format: "[FacesTests] 调试版、64 点 @2x：平静跟随 %.3f 毫秒，睡熟 %.3f 毫秒（每秒 %.0f 次 → 每秒 %.3f 毫秒）", calm, asleep, 1 / frame, asleep / frame))
        #expect(asleep < calm * 1.5, "睡熟的脸画一次 \(asleep) 毫秒，平静跟随 \(calm) 毫秒")
    }
}
