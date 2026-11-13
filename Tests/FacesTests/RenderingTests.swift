// FacesTests · 绘制：每种表情都画得出、不超出声明的范围、同输入同输出、不弄乱画布的状态
//
// 跑法：scripts/test.sh --filter FacesTests

import CoreGraphics
import DDMCore
import Foundation
import Testing
@testable import Faces

@Suite("绘制：画得出、不越界、可复现")
struct RenderingTests {
    /// 这个状态要在哪些时刻各画一遍：静止画面一个时刻就够，有循环小动画的多取几个。
    private func times(for state: FaceState) -> [TimeInterval] {
        FaceRenderer().animationInterval(for: state) == nil ? [0.4] : [0, 0.13, 0.4, 1.77, 3.3, 912.5]
    }

    /// 画一遍，返回发现的问题（没有问题为 nil）。
    private func check(
        _ state: FaceState, name: String, size: CGSize, scale: CGFloat, time: TimeInterval
    ) -> String? {
        let renderer = FaceRenderer()
        let rect = CGRect(origin: CGPoint(x: 200, y: 300), size: size)
        let margin = max(size.width, size.height)
        let canvas = TestCanvas(frame: rect.insetBy(dx: -margin, dy: -margin), scale: scale)
        renderer.draw(state, in: rect, context: canvas.context, time: time)
        let label = "\(name) · \(size.width)×\(size.height) 点 @\(Int(scale))x · t=\(time)"

        guard let painted = canvas.paintedBounds else {
            // 幽灵完全消散（进度 1）时本来就什么都不画。
            return state.mood == .ghost && state.ghost >= 1 ? nil : "\(label)：什么都没画出来"
        }
        // 声明的范围是整点，画布的像素边界也落在整点（或半点）上，所以这里不留余量：
        // 只要有一个像素完全落在声明的范围之外就算越界。
        let allowed = rect.expanded(by: renderer.outsets(for: state, iconSize: size))
        guard allowed.contains(painted) else {
            return "\(label)：画到了声明的范围之外。允许 \(allowed)，实际 \(painted)"
        }
        return nil
    }

    @Test(arguments: [32, 40, 48, 64, 96, 128] as [CGFloat])
    func 每种表情在各大小下都能画且不超出声明的范围(size: CGFloat) {
        var problems: [String] = []
        for (name, state) in Sample.gallery {
            for scale in [CGFloat(1), 2] {
                for time in times(for: state) {
                    if let problem = check(state, name: name, size: CGSize(width: size, height: size), scale: scale, time: time) {
                        problems.append(problem)
                    }
                }
            }
        }
        #expect(problems.isEmpty, "\(problems.count) 处问题，前几处：\(problems.prefix(5))")
    }

    @Test func 随机组合的表情参数也不越界() {
        var generator = SeededRandom(seed: 20261113)
        var problems: [String] = []
        for index in 0..<240 {
            let state = Sample.random(&generator)
            for size in [CGFloat(32), 64, 128] {
                for time in [0.21, 47.9] {
                    if let problem = check(state, name: "随机 #\(index)", size: CGSize(width: size, height: size), scale: 2, time: time) {
                        problems.append(problem)
                    }
                }
            }
        }
        #expect(problems.isEmpty, "\(problems.count) 处问题，前几处：\(problems.prefix(5))")
    }

    @Test func 不是整数的大小和长方形的图标矩形也不越界() {
        var problems: [String] = []
        let sizes = [CGSize(width: 47.5, height: 47.5), CGSize(width: 64, height: 80), CGSize(width: 90, height: 64), CGSize(width: 33, height: 51)]
        for (name, state) in Sample.gallery {
            for size in sizes {
                for time in times(for: state).prefix(3) {
                    if let problem = check(state, name: name, size: size, scale: 2, time: time) {
                        problems.append(problem)
                    }
                }
            }
        }
        #expect(problems.isEmpty, "\(problems.count) 处问题，前几处：\(problems.prefix(5))")
    }

    @Test func 同样的输入画出逐像素相同的画面() {
        for (name, state) in Sample.gallery {
            for size in [CGFloat(32), 64, 128] {
                let first = render(state, size: size, time: 1.77).bytes
                let second = render(state, size: size, time: 1.77).bytes
                #expect(first == second, "\(name) · \(size) 点：两次画出来不一样")
            }
        }
    }

    @Test func 画面与图标矩形在哪里无关() {
        // 叠加层可能只移动画布而不重画：同一张脸画在不同的位置，画面必须一样。
        for (name, state) in Sample.gallery {
            let here = render(state, time: 1.77, origin: CGPoint(x: 200, y: 300)).bytes
            let there = render(state, time: 1.77, origin: CGPoint(x: -3071, y: 5822)).bytes
            #expect(here == there, "\(name)：换了位置画出来不一样")
        }
    }

    @Test func 画完之后画布的状态和进来时一样() {
        // 画布是反复使用的：保存 / 恢复必须成对，坐标系和裁剪都不能留下痕迹。
        let renderer = FaceRenderer()
        let rect = CGRect(x: 200, y: 300, width: 64, height: 64)
        for (name, state) in Sample.gallery {
            let canvas = TestCanvas(frame: rect.insetBy(dx: -64, dy: -64), scale: 2)
            let context = canvas.context
            let transform = context.ctm
            let clip = context.boundingBoxOfClipPath
            renderer.draw(state, in: rect, context: context, time: 0.4)
            #expect(context.ctm == transform, "\(name)：坐标系被改了")
            #expect(context.boundingBoxOfClipPath == clip, "\(name)：裁剪范围被改了")
            // 再多恢复一次不该出事：如果绘制里多保存了一次，这里看不出来；
            // 但如果多恢复了一次，上面的坐标系比较就已经失败了。
        }
    }

    @Test func 不合法的输入不会出事() {
        let renderer = FaceRenderer()
        let canvas = TestCanvas(frame: CGRect(x: 0, y: 0, width: 200, height: 200), scale: 2)
        var wild = FaceState(seed: 3, gazeTarget: CGVector(dx: Double.infinity, dy: Double.nan), gazeFollow: 7)
        wild.fear = .nan
        wild.tears = -4
        wild.sleepiness = 99
        wild.cover = .infinity
        // 表情模块收到的本该是合法值；万一不是，也只是按夹回范围后的值来画。
        renderer.draw(wild, in: CGRect(x: 60, y: 60, width: 64, height: 64), context: canvas.context, time: .nan)
        renderer.draw(Sample.calm(), in: CGRect(x: 60, y: 60, width: 0, height: 0), context: canvas.context, time: 0)
        renderer.draw(Sample.calm(), in: CGRect(x: 60, y: 60, width: -5, height: 64), context: canvas.context, time: 0)
        renderer.draw(Sample.calm(gaze: CGVector(dx: 1e12, dy: -1e12)), in: CGRect(x: 60, y: 60, width: 64, height: 64), context: canvas.context, time: 1e9)
        #expect(renderer.outsets(for: wild, iconSize: CGSize(width: 64, height: 64)).top.isFinite)
        #expect(renderer.outsets(for: Sample.crying(), iconSize: .zero) == .zero)
        #expect(canvas.paintedCount > 0)
    }

    @Test func 每个图标长得略有不同而同一个图标每次都一样() {
        var looks: Set<[UInt8]> = []
        for raw in 1...12 {
            let seed = IconID(rawValue: UInt64(raw)).faceSeed
            let state = FaceState(seed: seed, gazeTarget: CGVector(dx: 95, dy: 60), gazeFollow: 1)
            let image = render(state).bytes
            #expect(image == render(state).bytes)
            looks.insert(image)
            let look = FaceLook(seed: seed)
            #expect(look == FaceLook(seed: seed))
            #expect((0.93...1.07).contains(look.eyeScale))
            #expect((-0.8...0.8).contains(look.gap))
            #expect((-1.0...1.0).contains(look.lift))
            #expect((0.85...1.15).contains(look.mouthScale))
        }
        #expect(looks.count == 12, "12 个不同的种子应该画出 12 张不同的脸，实际只有 \(looks.count) 种")
    }
}
