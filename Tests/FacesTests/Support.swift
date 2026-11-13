// FacesTests · 测试用的工具：离屏画布、读像素、造表情状态

import CoreGraphics
import DDMCore
import Foundation
@testable import Faces

/// 一块离屏位图：和叠加层交给表情模块的画布一样——sRGB、y 向下、单位点，覆盖 `frame` 这块范围。
struct TestCanvas {
    let context: CGContext
    /// 画布覆盖的范围（点）。
    let frame: CGRect
    /// 1 点等于几个像素。
    let scale: CGFloat

    init(frame: CGRect, scale: CGFloat) {
        self.frame = frame
        self.scale = scale
        let context = CGContext(
            data: nil,
            width: Int((frame.width * scale).rounded(.up)),
            height: Int((frame.height * scale).rounded(.up)),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.translateBy(x: 0, y: CGFloat(context.height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -frame.minX, y: -frame.minY)
        self.context = context
    }

    var pixelWidth: Int { context.width }
    var pixelHeight: Int { context.height }

    /// 全部像素（每个像素 4 字节：红、绿、蓝、不透明度），行与行之间没有填充。
    var bytes: [UInt8] {
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = pixelWidth * 4
        var result: [UInt8] = []
        result.reserveCapacity(rowBytes * pixelHeight)
        for row in 0..<pixelHeight {
            result.append(contentsOf: UnsafeBufferPointer(start: data + row * context.bytesPerRow, count: rowBytes))
        }
        return result
    }

    /// 画了东西（不透明度大于 0）的像素有多少。
    var paintedCount: Int {
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        var count = 0
        for row in 0..<pixelHeight {
            let line = data + row * context.bytesPerRow
            for column in 0..<pixelWidth where line[column * 4 + 3] > 0 { count += 1 }
        }
        return count
    }

    /// 画了东西的像素的外接矩形（点）；什么都没画为 nil。
    var paintedBounds: CGRect? {
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for row in 0..<pixelHeight {
            let line = data + row * context.bytesPerRow
            for column in 0..<pixelWidth where line[column * 4 + 3] > 0 {
                if column < minX { minX = column }
                if column > maxX { maxX = column }
                if row < minY { minY = row }
                maxY = row
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(
            x: frame.minX + CGFloat(minX) / scale, y: frame.minY + CGFloat(minY) / scale,
            width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale
        )
    }

    /// 接近纯白的不透明像素有多少（眼白、高光）。
    var whiteCount: Int {
        let all = bytes
        var count = 0
        for index in stride(from: 0, to: all.count, by: 4)
            where all[index] > 245 && all[index + 1] > 245 && all[index + 2] > 245 && all[index + 3] > 250 {
            count += 1
        }
        return count
    }
}

/// 把一张脸画到一块足够大的画布上。
/// - Parameter margin: 图标四周各留多少空，以图标大小为单位。默认 1（幽灵最多升到图标上方 0.8 个图标高）。
func render(
    _ state: FaceState, size: CGFloat = 64, scale: CGFloat = 2, time: TimeInterval = 0.4,
    origin: CGPoint = CGPoint(x: 200, y: 300), margin: CGFloat = 1
) -> TestCanvas {
    let rect = CGRect(x: origin.x, y: origin.y, width: size, height: size)
    let canvas = TestCanvas(frame: rect.insetBy(dx: -size * margin, dy: -size * margin), scale: scale)
    FaceRenderer().draw(state, in: rect, context: canvas.context, time: time)
    return canvas
}

/// 两张图差多少：所有字节之差的总和，折算成"多少个像素完全变了"。
func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
    precondition(a.count == b.count)
    var total = 0
    a.withUnsafeBufferPointer { first in
        b.withUnsafeBufferPointer { second in
            for index in 0..<first.count { total += abs(Int(first[index]) - Int(second[index])) }
        }
    }
    return Double(total) / 255 / 4
}

/// 测试用的长相种子。
let testSeed = IconID(rawValue: 1).faceSeed

/// 8 种表情各一组有代表性的参数（和演示程序里的"标准参数"是同一套思路）。
enum Sample {
    static func calm(gaze: CGVector = CGVector(dx: 95, dy: 60)) -> FaceState {
        FaceState(mood: .calm, seed: testSeed, gazeTarget: gaze, gazeFollow: 1)
    }

    static func shy(_ level: Double = 1) -> FaceState {
        FaceState(mood: .shy, seed: testSeed, gazeTarget: CGVector(dx: -70, dy: 75), gazeFollow: 0.9, blush: level)
    }

    static func dizzy(_ level: Double = 1) -> FaceState {
        FaceState(mood: .dizzy, seed: testSeed, dizziness: level)
    }

    static func scared(_ level: Double = 1) -> FaceState {
        FaceState(
            mood: .scared, seed: testSeed, gazeTarget: CGVector(dx: 260, dy: 190), gazeFollow: 1,
            fear: level, sweat: level, tremble: 0.8 * level
        )
    }

    static func crying(_ level: Double = 1) -> FaceState {
        FaceState(
            mood: .crying, seed: testSeed, gazeTarget: CGVector(dx: 40, dy: 120), gazeFollow: 1,
            fear: 0.25 + 0.3 * level, tremble: 0.5 * level, tears: level
        )
    }

    static func covering(_ level: Double = 1, peek: Double = 0) -> FaceState {
        FaceState(mood: .coveringEyes, seed: testSeed, gazeFollow: 1, cover: level, peek: peek)
    }

    static func dozing(_ level: Double = 1) -> FaceState {
        FaceState(mood: .dozing, seed: testSeed, sleepiness: level)
    }

    static func ghost(_ progress: Double = 0.4) -> FaceState {
        FaceState(mood: .ghost, seed: testSeed, ghost: progress)
    }

    /// 8 种表情 × 若干强度：越界、确定性等测试共用的一大批状态。
    static var gallery: [(name: String, state: FaceState)] {
        var result: [(String, FaceState)] = []
        let levels: [Double] = [0, 0.1, 0.25, 0.4, 0.41, 0.5, 0.75, 1]
        for gaze in [CGVector(dx: -600, dy: -400), CGVector(dx: 700, dy: 500), CGVector(dx: 0, dy: 3), CGVector(dx: 5, dy: -900)] {
            result.append(("平静 视线 \(gaze.dx),\(gaze.dy)", calm(gaze: gaze)))
        }
        for blink in [0.3, 0.7, 0.97, 1.0] {
            var state = calm()
            state.blink = blink
            result.append(("眨眼 \(blink)", state))
        }
        for level in levels {
            result.append(("害羞 \(level)", shy(level)))
            result.append(("头晕 \(level)", dizzy(level)))
            result.append(("害怕 \(level)", scared(level)))
            result.append(("哭 \(level)", crying(level)))
            result.append(("捂眼 \(level)", covering(level)))
            result.append(("捂眼 \(level) 偷看", covering(level, peek: 1)))
            result.append(("打瞌睡 \(level)", dozing(level)))
            result.append(("幽灵 \(level)", ghost(level)))
        }
        // 所有参数同时拉满：没有哪种组合可以画到声明的范围之外。
        var everything = FaceState(mood: .crying, seed: testSeed, gazeTarget: CGVector(dx: -900, dy: 900), gazeFollow: 1)
        for parameter in FaceState.unitParameters { everything[keyPath: parameter.keyPath] = 1 }
        result.append(("全部拉满", everything))
        everything.blink = 0
        everything.cover = 0
        result.append(("全部拉满（不闭眼、不捂眼）", everything))
        return result
    }

    /// 用种子造一个随机的（非幽灵）表情状态：每个参数有一半的机会是 0。
    static func random(_ generator: inout SeededRandom) -> FaceState {
        let moods: [FaceMood] = [.calm, .shy, .dizzy, .scared, .crying, .coveringEyes, .dozing]
        var state = FaceState(mood: moods[Int(generator.next() % UInt64(moods.count))], seed: generator.next())
        state.gazeTarget = CGVector(dx: (generator.nextUnit() - 0.5) * 1600, dy: (generator.nextUnit() - 0.5) * 1200)
        for parameter in FaceState.unitParameters where parameter.name != "ghost" {
            state[keyPath: parameter.keyPath] = generator.nextUnit() < 0.5 ? 0 : generator.nextUnit()
        }
        return state
    }
}
