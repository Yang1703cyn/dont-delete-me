// FacesTests · 姿态：参数的视觉含义——视线、对眼、瞳孔、眼皮、幽灵的高度

import CoreGraphics
import DDMCore
import Foundation
import Testing
@testable import Faces

@Suite("参数的视觉含义")
struct PoseTests {
    private let rect = CGRect(x: 200, y: 300, width: 64, height: 64)

    private func pose(_ state: FaceState, time: TimeInterval = 0.4) -> FacePose {
        FacePose(params: FaceParams(state), rect: rect, time: time)
    }

    /// 瞳孔相对眼眶中心的位移。
    private func offset(_ eye: FacePose.Eye) -> CGVector {
        eye.pupil.offset(from: eye.center)
    }

    // MARK: - 视线

    @Test func 瞳孔朝视线目标偏() {
        let right = pose(Sample.calm(gaze: CGVector(dx: 300, dy: 0)))
        #expect(offset(right.leftEye).dx > 1 && offset(right.rightEye).dx > 1)
        let upLeft = pose(Sample.calm(gaze: CGVector(dx: -300, dy: -300)))
        #expect(offset(upLeft.leftEye).dx < -1 && offset(upLeft.leftEye).dy < -1)
        #expect(offset(upLeft.rightEye).dx < -1 && offset(upLeft.rightEye).dy < -1)
    }

    @Test func 不跟随时平视前方而跟随程度居中时偏得少一些() {
        var state = Sample.calm(gaze: CGVector(dx: 300, dy: 200))
        state.gazeFollow = 0
        let none = pose(state)
        #expect(offset(none.leftEye) == .zero && offset(none.rightEye) == .zero)
        state.gazeFollow = 0.5
        let half = offset(pose(state).leftEye).length
        state.gazeFollow = 1
        let full = offset(pose(state).leftEye).length
        #expect(half > 0 && half < full)
    }

    @Test func 鼠标很近时会对眼() {
        // 目标就在两眼之间：左眼往右看，右眼往左看。
        let close = pose(Sample.calm(gaze: CGVector(dx: 0, dy: -2)))
        #expect(offset(close.leftEye).dx > 0.8)
        #expect(offset(close.rightEye).dx < -0.8)
        // 目标在远处：两眼朝同一个方向。
        let far = pose(Sample.calm(gaze: CGVector(dx: 0, dy: 600)))
        #expect(abs(offset(far.leftEye).dx - offset(far.rightEye).dx) < 0.3)
    }

    @Test func 瞳孔始终在眼眶里() {
        var generator = SeededRandom(seed: 31)
        var problems: [String] = []
        for _ in 0..<400 {
            var state = Sample.random(&generator)
            state.dizziness = 0   // 头晕时瞳孔会缩没，另有测试
            let pose = pose(state, time: generator.nextUnit() * 50)
            for eye in pose.eyes where !eye.isClosed {
                // 瞳孔别整个藏到眼皮后面。
                if eye.pupil.y < eye.top || eye.pupil.y > eye.bottom {
                    problems.append("瞳孔整个藏到眼皮后面去了：\(state)")
                }
                // 眼睛全睁时绘制不做裁剪，所以瞳孔必须整个在眼眶里：
                // 圆心在"眼眶往里缩一个瞳孔半径"的椭圆之内。
                // （眼皮盖住一部分时瞳孔可以伸到眼皮后面，那时绘制会裁剪。）
                guard eye.coverTop == 0, eye.coverBottom == 0 else { continue }
                let dx = (eye.pupil.x - eye.center.x) / (eye.rx - eye.pupilRadius)
                let dy = (eye.pupil.y - eye.center.y) / (eye.ry - eye.pupilRadius)
                if dx * dx + dy * dy > 1.0001 { problems.append("瞳孔跑到眼眶外面去了：\(state)") }
            }
        }
        #expect(problems.isEmpty, "\(problems.count) 处问题，第一处：\(problems.first ?? "")")
    }

    @Test func 画出来的瞳孔也跟着视线走() {
        // 不看内部数据，只看画面：深色像素的重心随视线左右移动。
        func darkCentroidX(_ gaze: CGVector) -> Double {
            let canvas = render(Sample.calm(gaze: gaze))
            let bytes = canvas.bytes
            var sum = 0.0
            var count = 0.0
            for row in 0..<canvas.pixelHeight {
                for column in 0..<canvas.pixelWidth {
                    let index = (row * canvas.pixelWidth + column) * 4
                    if bytes[index + 3] > 200, bytes[index] < 80, bytes[index + 1] < 80 {
                        sum += Double(column)
                        count += 1
                    }
                }
            }
            return sum / count
        }
        let left = darkCentroidX(CGVector(dx: -400, dy: 0))
        let right = darkCentroidX(CGVector(dx: 400, dy: 0))
        #expect(right - left > 4, "视线从左到右，瞳孔应该明显右移（单位：像素），实际只移了 \(right - left)")
    }

    // MARK: - 惊恐、眼皮

    @Test func 越害怕瞳孔越小眼睛越大() {
        var previous = pose(FaceState(seed: testSeed, fear: 0))
        for step in 1...10 {
            let current = pose(FaceState(seed: testSeed, fear: Double(step) / 10))
            #expect(current.leftEye.pupilRadius < previous.leftEye.pupilRadius)
            #expect(current.leftEye.rx > previous.leftEye.rx)
            previous = current
        }
        let calm = pose(FaceState(seed: testSeed)).leftEye.pupilRadius
        #expect(previous.leftEye.pupilRadius < calm * 0.5, "最害怕时瞳孔应该不到平时的一半")
    }

    @Test func 眨眼和睡熟时眼睛闭上() {
        var state = Sample.calm()
        #expect(!pose(state).leftEye.isClosed)
        state.blink = 0.5
        let half = pose(state).leftEye
        #expect(!half.isClosed && half.coverTop > 0.3 && half.coverBottom > 0.1)
        state.blink = 1
        #expect(pose(state).leftEye.isClosed)
        #expect(pose(Sample.dozing(1)).leftEye.isClosed)
        // 犯困但没睡着：只是上眼皮耷下来。
        let drowsy = pose(Sample.dozing(0.5)).leftEye
        #expect(!drowsy.isClosed && drowsy.coverTop > 0.25 && drowsy.coverBottom == 0)

        // 画面上：闭眼后眼白没了，只剩嘴线外面那圈白边。
        let open = render(Sample.calm()).whiteCount
        let closed = render(state).whiteCount
        #expect(open > 400 && closed < open / 6, "睁眼 \(open) 个白像素，闭眼 \(closed) 个")
    }

    @Test func 害羞和流泪时下眼皮顶上来一点() {
        #expect(pose(Sample.shy(1)).leftEye.coverBottom > 0.15)
        #expect(pose(FaceState(seed: testSeed, tears: 1)).leftEye.coverBottom > 0.05)
        #expect(pose(Sample.calm()).leftEye.coverBottom == 0)
    }

    @Test func 头晕到头时瞳孔换成漩涡() {
        let mild = pose(Sample.dizzy(0.2))
        #expect(mild.spiral == 0 && mild.leftEye.pupilRadius > 3)
        let full = pose(Sample.dizzy(1))
        #expect(full.spiral == 1 && full.leftEye.pupilRadius == 0)
        // 轻度头晕：瞳孔在打转——两个时刻位置不同。
        let early = pose(Sample.dizzy(0.2), time: 0.1).leftEye.pupil
        let late = pose(Sample.dizzy(0.2), time: 0.4).leftEye.pupil
        #expect(early.distance(to: late) > 0.5)
    }

    // MARK: - 效果出现的门槛

    @Test func 泪先是泪汪汪超过门槛才往下流() {
        let welling = pose(FaceState(seed: testSeed, tears: 0.3))
        #expect(welling.pool > 0 && welling.stream == 0)
        let flowing = pose(FaceState(seed: testSeed, tears: 0.6))
        #expect(flowing.stream > 0)
        // 泪流满时，画面的下缘到了图标下方。
        let bounds = render(Sample.crying(1)).paintedBounds!
        #expect(bounds.maxY > rect.maxY + 6, "泪应该流到图标下面去")
        #expect(render(Sample.crying(0.3)).paintedBounds!.maxY <= rect.maxY)
    }

    @Test func 睡着才冒Zzz() {
        #expect(pose(Sample.dozing(0.3)).sleepDepth == 0)
        #expect(pose(Sample.dozing(0.9)).sleepDepth > 0.9)
        // 睡熟时，某些时刻 Zzz 飘到了图标上方。
        let highest = stride(from: 0.0, to: 4.0, by: 0.25)
            .compactMap { render(Sample.dozing(1), time: $0).paintedBounds?.minY }
            .min()!
        #expect(highest < rect.minY - 4, "Zzz 应该飘到图标上面去")
    }

    @Test func 手抬起来才遮住眼睛() {
        // 手到位后，眼睛那一片主要是手的颜色，眼白大幅减少。
        let open = render(FaceState(seed: testSeed)).whiteCount
        let covered = render(Sample.covering(1)).whiteCount
        #expect(covered < open / 3, "捂眼后眼白应该大部分被遮住：睁眼 \(open)，捂眼 \(covered)")
        // 从指缝偷看时又露出来一些。
        let peeking = render(Sample.covering(1, peek: 1)).whiteCount
        #expect(peeking > covered)
    }

    // MARK: - 幽灵

    @Test func 幽灵随进度匀速上升一个图标高() {
        // 与情绪模块的约定：进度为 p 时，幽灵的中心比图标矩形的中心高 p × 一个图标高。
        let look = FaceLook(seed: testSeed)
        for progress in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let center = GhostPainter.center(progress: CGFloat(progress), rect: rect, look: look, time: 3.3)
            #expect(abs(center.y - (rect.midY - CGFloat(progress) * rect.height)) < 0.001)
        }
        // 画面上也是如此：幽灵身体的上下中点在约定的高度附近（下摆在荡漾，留 3 点的余量）。
        for progress in [0.2, 0.4, 0.6] {
            let bounds = render(Sample.ghost(progress)).paintedBounds!
            #expect(abs(bounds.midY - (rect.midY - CGFloat(progress) * rect.height)) < 3)
        }
        // 快到头时淡出，到头完全消失。
        #expect(GhostPainter.opacity(progress: 0.5) == 1)
        #expect(GhostPainter.opacity(progress: 0.8) < 0.6)
        #expect(GhostPainter.opacity(progress: 1) == 0)
        #expect(render(Sample.ghost(1)).paintedBounds == nil)
    }

    // MARK: - 大小适配

    @Test func 小图标上五官相对放大线条不会细到发虚() {
        let small = FacePose(params: FaceParams(Sample.calm()), rect: CGRect(x: 0, y: 0, width: 32, height: 32), time: 0)
        let normal = pose(Sample.calm())
        let large = FacePose(params: FaceParams(Sample.calm()), rect: CGRect(x: 0, y: 0, width: 128, height: 128), time: 0)
        // 32 点图标上，眼睛占图标的比例比 64 点时大。
        #expect(small.leftEye.rx / 32 > normal.leftEye.rx / 64)
        #expect(abs(large.leftEye.rx / 128 - normal.leftEye.rx / 64) < 0.0001)
        // 线宽有下限（点）。
        #expect(small.outline >= 1 && small.inkLine >= 1 && small.lidLine >= 1.25)
        #expect(!small.fine && normal.fine && large.fine)
        // 五官的总宽度不超过图标宽度的 62%（文稿图标只占矩形中间约 68%）。
        for pose in [small, normal, large] {
            let width = (pose.rightEye.center.x + pose.rightEye.rx) - (pose.leftEye.center.x - pose.leftEye.rx)
            #expect(width / pose.rect.width < 0.62)
        }
    }
}
