// InputSenseTests · 废纸篓：和鼠标的关系、位置估算、量程序坞、自学习

import CoreGraphics
import DDMCore
import Foundation
import Testing
@testable import InputSense

@Suite("鼠标和废纸篓的关系")
struct TrashApproachTests {
    @Test func 给出距离_朝它移动时靠近速度为正() throws {
        var stage = Stage(at: CGPoint(x: 600, y: 947))
        stage.wait(0.3)
        let still = try #require(stage.last.trash)
        #expect(still.estimatedRect == Fixture.trash.rect)
        #expect(still.confidence == 0.75)
        #expect(still.distance == 800)          // 废纸篓区域的左边缘在 x = 1400
        #expect(still.closingSpeed == 0)
        #expect(!still.isApproaching)
        #expect(!still.isOver)

        stage.move(to: CGPoint(x: 1000, y: 947), in: 0.5)   // 向右 800 点/秒，正对着废纸篓
        let moving = try #require(stage.last.trash)
        #expect(moving.distance == 400)
        #expect(abs(moving.closingSpeed - 800) < 20)
        #expect(moving.isApproaching)
        #expect(!moving.isOver)
    }

    @Test func 到了上方_距离为零() throws {
        var stage = Stage(at: CGPoint(x: 1000, y: 947))
        stage.move(to: Fixture.trashCenter, in: 0.4)
        let trash = try #require(stage.last.trash)
        #expect(trash.isOver)
        #expect(trash.distance == 0)
        #expect(trash.closingSpeed == 0)
        // 停在上面不动，过一会儿就不再算"正朝它移动"。
        stage.wait(0.5)
        #expect(try #require(stage.last.trash).isOver)
        #expect(try #require(stage.last.trash).isApproaching == false)
    }

    @Test func 远离时靠近速度为负_不算朝它移动() throws {
        var stage = Stage(at: CGPoint(x: 1300, y: 947))
        stage.wait(0.2)
        stage.move(to: CGPoint(x: 700, y: 947), in: 0.6)
        let trash = try #require(stage.last.trash)
        #expect(trash.closingSpeed < -900)
        #expect(!trash.isApproaching)
    }

    @Test func 横着从旁边掠过不算朝它移动() throws {
        // 从 (900, 500) 看，废纸篓在右下方。沿着和这个方向垂直的方向走：速度很快，但距离几乎不变。
        var stage = Stage(at: CGPoint(x: 900, y: 500))
        stage.wait(0.2)
        stage.move(to: CGPoint(x: 772.6, y: 654.2), in: 0.2)   // 1000 点/秒
        let speeds = stage.facts.suffix(8).map(\.mouse.speed)
        #expect(speeds.allSatisfy { $0 > 800 })
        #expect(stage.facts.compactMap(\.trash).allSatisfy { !$0.isApproaching })
        #expect(stage.facts.compactMap(\.trash).allSatisfy { abs($0.closingSpeed) < 350 })
    }

    @Test func 朝它移动的判断是防抖的_中途顿一下不会来回跳() throws {
        var stage = Stage(at: CGPoint(x: 400, y: 947))
        stage.move(to: CGPoint(x: 700, y: 947), in: 0.4)
        #expect(try #require(stage.last.trash).isApproaching)

        let before = stage.facts.count
        stage.wait(0.15)                                     // 手顿了一下
        stage.move(to: CGPoint(x: 1000, y: 947), in: 0.4)    // 接着走
        let flags = stage.facts[before...].compactMap(\.trash).map(\.isApproaching)
        #expect(flags.allSatisfy { $0 }, "中途不应该变成 false")

        // 真的停下来超过 0.3 秒才改口。
        stage.wait(0.6)
        #expect(try #require(stage.last.trash).isApproaching == false)
    }

    @Test func 刚开始朝它动的头几帧还不算_连续成立一小会儿才算() throws {
        var stage = Stage(at: CGPoint(x: 400, y: 947))
        stage.wait(0.3)
        stage.position.x += 14
        stage.frame()
        #expect(try #require(stage.last.trash).isApproaching == false)
        stage.move(to: CGPoint(x: 700, y: 947), in: 0.3)
        #expect(try #require(stage.last.trash).isApproaching)
    }

    @Test func 估算不出来时没有废纸篓事实() throws {
        var stage = Stage(at: CGPoint(x: 600, y: 600))
        stage.trash = nil
        stage.wait(0.2)
        #expect(stage.last.trash == nil)
    }
}

@Suite("程序坞的几何模型")
struct DockModelTests {
    /// 开发机的情形：图标大小设成 64，共 32 项、2 条分隔线，放不下所以被挤满。
    let crowded = DockSettings(edge: .bottom, tileSize: 64, tileCount: 32, separatorCount: 2)

    @Test func 复现本机实测_外接屏上那一条长一八五二厚六十九() throws {
        // 实测（命中测试扫描）：x 从 −1886 到 −34，y 从 953 到屏幕底边 1022。
        let (bar, pitch) = DockModel.predictedBar(settings: crowded, displayFrame: Fixture.external)
        #expect(abs(bar.minX - -1886) < 0.01)
        #expect(abs(bar.maxX - -34) < 0.01)
        #expect(abs(bar.minY - 953) < 0.5)
        #expect(bar.maxY == 1022)
        #expect(abs(pitch - 56.5) < 0.01)
    }

    @Test func 复现本机实测_内屏上那一条厚五十六() throws {
        // 程序坞在内屏时系统报告的底部留空是 56 点。
        let (bar, _) = DockModel.predictedBar(settings: crowded, displayFrame: Fixture.builtIn)
        #expect(abs(bar.height - 56) < 0.5)
        #expect(bar.minX == 34 && bar.maxX == 1512 - 34)
    }

    @Test func 项目少放得下时_按设置的图标大小排_沿边居中() throws {
        let roomy = DockSettings(edge: .bottom, tileSize: 48, tileCount: 10, separatorCount: 1)
        let (bar, pitch) = DockModel.predictedBar(settings: roomy, displayFrame: Fixture.builtIn)
        #expect(pitch == 52.5)
        #expect(bar.width == 10 * 52.5 + 20 + 12)
        #expect(bar.midX == Fixture.builtIn.midX)
        #expect(bar.height == 65)
        #expect(bar.maxY == Fixture.builtIn.maxY)
    }

    @Test func 废纸篓是那一条末端的最后一格() throws {
        let bar = CGRect(x: -1886, y: 953, width: 1852, height: 69)
        let slot = DockModel.trashSlot(bar: bar, pitch: 56.5, edge: .bottom)
        #expect(slot == CGRect(x: -34 - 10 - 56.5, y: 953, width: 56.5, height: 69))
    }

    @Test func 程序坞在左右两侧_那一条竖着_废纸篓在最下面() throws {
        let left = DockSettings(edge: .left, tileSize: 48, tileCount: 10, separatorCount: 1)
        let (leftBar, pitch) = DockModel.predictedBar(settings: left, displayFrame: Fixture.builtIn)
        #expect(leftBar.minX == 0 && leftBar.width == 65)
        #expect(leftBar.midY == Fixture.builtIn.midY)
        let leftSlot = DockModel.trashSlot(bar: leftBar, pitch: pitch, edge: .left)
        #expect(leftSlot == CGRect(x: 0, y: leftBar.maxY - 10 - 52.5, width: 65, height: 52.5))

        var right = left
        right.edge = .right
        let (rightBar, _) = DockModel.predictedBar(settings: right, displayFrame: Fixture.external)
        #expect(rightBar.maxX == Fixture.external.maxX && rightBar.width == 65)
        #expect(DockModel.trashSlot(bar: rightBar, pitch: pitch, edge: .right).maxY == rightBar.maxY - 10)
    }

    @Test func 离谱的输入也不会算出零或负数() throws {
        let weird = DockSettings(edge: .bottom, tileSize: -5, tileCount: 0, separatorCount: -3)
        let (bar, pitch) = DockModel.predictedBar(settings: weird, displayFrame: Fixture.builtIn)
        #expect(pitch >= DockModel.minimumPitch)
        #expect(bar.width > 0 && bar.height > 0)

        let huge = DockSettings(edge: .bottom, tileSize: 128, tileCount: 500, separatorCount: 2)
        let squeezed = DockModel.predictedBar(settings: huge, displayFrame: Fixture.builtIn)
        #expect(squeezed.pitch >= DockModel.minimumPitch)
    }
}

@Suite("量程序坞那一条")
struct DockBarScanTests {
    @Test func 量出来的范围和实际一致_不超过四十次查询() throws {
        let bar = CGRect(x: -1886, y: 953, width: 1852, height: 69)
        var probes = 0
        let measured = DockBarScan.measure(edge: .bottom, displayFrame: Fixture.external) { point in
            probes += 1
            return bar.contains(point)
        }
        #expect(measured == bar)
        #expect(probes <= 40, "用了 \(probes) 次查询")
    }

    @Test(arguments: [
        CGRect(x: 500, y: 917, width: 512, height: 65),      // 项目少：短短一条
        CGRect(x: 0, y: 930, width: 1512, height: 52),       // 顶到屏幕两端
        CGRect(x: 301, y: 842, width: 911, height: 140),     // 很大的图标
    ])
    func 各种长短厚薄都量得准(bar: CGRect) throws {
        let measured = DockBarScan.measure(edge: .bottom, displayFrame: Fixture.builtIn) { bar.contains($0) }
        #expect(measured == bar)
    }

    @Test func 左右两侧也能量() throws {
        let leftBar = CGRect(x: 0, y: 200, width: 65, height: 582)
        #expect(DockBarScan.measure(edge: .left, displayFrame: Fixture.builtIn) { leftBar.contains($0) } == leftBar)

        let rightBar = CGRect(x: -65, y: 100, width: 65, height: 700)
        #expect(DockBarScan.measure(edge: .right, displayFrame: Fixture.external) { rightBar.contains($0) } == rightBar)
    }

    @Test func 程序坞没露出来_量不到_只花一次查询() throws {
        var probes = 0
        let measured = DockBarScan.measure(edge: .bottom, displayFrame: Fixture.builtIn) { _ in
            probes += 1
            return false
        }
        #expect(measured == nil)
        #expect(probes == 1)
    }

    @Test func 整块屏都被程序坞的窗口占着_不是那一条_不采信() throws {
        // 例如调度中心打开时，程序坞有一块整屏的窗口。
        #expect(DockBarScan.measure(edge: .bottom, displayFrame: Fixture.builtIn) { _ in true } == nil)
    }

    @Test func 核对上一次量到的范围_没变时只花四次查询() throws {
        let bar = CGRect(x: -1886, y: 953, width: 1852, height: 69)
        var probes = 0
        let holds = DockBarScan.stillHolds(bar, edge: .bottom, displayFrame: Fixture.external) { point in
            probes += 1
            return bar.contains(point)
        }
        #expect(holds)
        #expect(probes == 4)

        // 顶到屏幕末端的那一条：末端没有"外面"，只花三次。
        let full = CGRect(x: 0, y: 930, width: 1512, height: 52)
        probes = 0
        #expect(DockBarScan.stillHolds(full, edge: .bottom, displayFrame: Fixture.builtIn) { probes += 1; return full.contains($0) })
        #expect(probes == 3)
    }

    @Test(arguments: [
        CGRect(x: -1886, y: 953, width: 1795, height: 69),    // 少了一项：右端缩进去了
        CGRect(x: -1915, y: 953, width: 1910, height: 69),    // 多了一项：两端伸出去了
        CGRect(x: -1886, y: 941, width: 1852, height: 81),    // 图标变大：变厚了
        CGRect(x: -1886, y: 965, width: 1852, height: 57),    // 图标变小：变薄了
    ])
    func 核对上一次量到的范围_程序坞变了样就对不上(actual: CGRect) throws {
        let remembered = CGRect(x: -1886, y: 953, width: 1852, height: 69)
        #expect(!DockBarScan.stillHolds(remembered, edge: .bottom, displayFrame: Fixture.external) { actual.contains($0) })
    }

    @Test func 核对上一次量到的范围_程序坞藏起来了_一次查询就知道() throws {
        var probes = 0
        let remembered = CGRect(x: 0, y: 200, width: 65, height: 582)
        let holds = DockBarScan.stillHolds(remembered, edge: .left, displayFrame: Fixture.builtIn) { _ in
            probes += 1
            return false
        }
        #expect(!holds)
        #expect(probes == 1)
        // 左右两侧同样可以核对。
        #expect(DockBarScan.stillHolds(remembered, edge: .left, displayFrame: Fixture.builtIn) { remembered.contains($0) })
    }

    @Test func 薄得不像程序坞的不采信() throws {
        let sliver = CGRect(x: 600, y: 972, width: 300, height: 10)
        #expect(DockBarScan.measure(edge: .bottom, displayFrame: Fixture.builtIn) { sliver.contains($0) } == nil)
    }
}

@Suite("废纸篓位置的估算")
struct TrashEstimatorTests {
    let settings = DockSettings(edge: .bottom, tileSize: 64, tileCount: 32, separatorCount: 2)
    let bar = CGRect(x: -1886, y: 953, width: 1852, height: 69)

    func observation(measured: Bool, settings: DockSettings? = nil, display: CGRect = Fixture.external) -> DockObservation {
        DockObservation(settings: settings ?? self.settings, displayFrame: display, measuredBar: measured ? bar : nil)
    }

    @Test func 只靠公式_可信度较低_区域留得宽() throws {
        let estimate = TrashEstimator.estimate(observation: observation(measured: false), lessons: [])
        #expect(estimate.basis == .formula)
        #expect(estimate.confidence == 0.45)
        #expect(estimate.lessonCount == 0)
        // 那一格是 x −100.5…−44；可信度 0.45，两边各多留 (1 − 0.45) × 0.5 × 56.5 ≈ 15.5 点。
        #expect(abs(estimate.rect.minX - (-100.5 - 15.5375)) < 0.01)
        #expect(abs(estimate.rect.maxX - (-44 + 15.5375)) < 0.01)
        #expect(abs(estimate.rect.minY - 953) < 0.5 && estimate.rect.maxY == 1022)
    }

    @Test func 量到了那一条_可信度更高_区域更窄() throws {
        let formula = TrashEstimator.estimate(observation: observation(measured: false), lessons: [])
        let measured = TrashEstimator.estimate(observation: observation(measured: true), lessons: [])
        #expect(measured.basis == .measured)
        #expect(measured.confidence == 0.75)
        #expect(measured.rect.width < formula.rect.width)
        #expect(measured.rect.contains(CGPoint(x: -72, y: 990)))
    }

    @Test func 不知道程序坞在哪块屏_假定主屏_可信度再打折() throws {
        var unknown = observation(measured: false, display: Fixture.builtIn)
        unknown.isDisplayKnown = false
        let estimate = TrashEstimator.estimate(observation: unknown, lessons: [])
        #expect(abs(estimate.confidence - 0.315) < 1e-9)
        #expect(Fixture.builtIn.contains(estimate.rect.center))
    }

    @Test func 左右两侧的公式没校准过_可信度更低() throws {
        var side = settings
        side.edge = .left
        let estimate = TrashEstimator.estimate(observation: observation(measured: false, settings: side), lessons: [])
        #expect(estimate.confidence == 0.3)
        // 废纸篓在竖着的那一条的最下面。
        #expect(estimate.rect.midY > Fixture.external.midY)
        #expect(estimate.rect.minX == Fixture.external.minX)
    }

    @Test func 开了放大_区域向外放宽_可信度打折() throws {
        var magnified = settings
        magnified.magnification = true
        magnified.largeSize = 128
        let plain = TrashEstimator.base(for: observation(measured: true))
        let grown = TrashEstimator.base(for: observation(measured: true, settings: magnified))
        #expect(grown.slot.width > plain.slot.width)
        #expect(grown.slot.height > plain.slot.height)
        #expect(grown.slot.maxX > plain.slot.maxX)       // 往外（屏幕边缘方向）多放一些
        #expect(grown.slot.minX < plain.slot.minX)
        #expect(grown.slot.maxY == plain.slot.maxY)      // 仍然贴着屏幕底边
        // 0.75 × 0.75：明确低于"凭位置认定被删"要求的 0.6。
        #expect(abs(grown.confidence - 0.5625) < 1e-9)
        #expect(grown.confidence < JudgeTuning().trashInferenceConfidence)
    }

    @Test func 自学习_松手点落在估算的那一格里_位置不动_更有把握() throws {
        let current = observation(measured: true)
        let before = TrashEstimator.estimate(observation: current, lessons: [])
        let lesson = try #require(TrashEstimator.lesson(releasePoint: CGPoint(x: -65, y: 995), observation: current))
        #expect(abs(lesson.axisDelta - 7.25) < 0.01)   // 那一格的中心在 x = −72.25

        let after = TrashEstimator.estimate(observation: current, lessons: [lesson])
        #expect(after.lessonCount == 1)
        #expect(after.confidence == 0.875)
        #expect(after.rect.midX == before.rect.midX)
        #expect(after.rect.width < before.rect.width)   // 更有把握，余量更小
    }

    @Test func 自学习_松手点在估算之外_估算被挪到松手点上() throws {
        // 公式以为废纸篓在 x ≈ −72，实际松手在 x = −190（比如程序坞里多了两个没数到的项目，整条更靠左）。
        let current = observation(measured: false)
        let before = TrashEstimator.estimate(observation: current, lessons: [])
        let release = CGPoint(x: -190, y: 990)
        #expect(!before.rect.contains(release))

        let lesson = try #require(TrashEstimator.lesson(releasePoint: release, observation: current))
        let after = TrashEstimator.estimate(observation: current, lessons: [lesson])
        #expect(after.rect.contains(release))
        #expect(abs(after.rect.midX - -190) < 0.01)
        #expect(after.confidence == 0.7)
        #expect(after.confidence > before.confidence)

        // 第二次、第三次在差不多的位置：取平均，越来越有把握。
        let second = try #require(TrashEstimator.lesson(releasePoint: CGPoint(x: -180, y: 1000), observation: current))
        let twice = TrashEstimator.estimate(observation: current, lessons: [lesson, second])
        #expect(abs(twice.rect.midX - -185) < 0.01)
        #expect(twice.confidence == 0.85)
        #expect(twice.lessonCount == 2)
    }

    @Test func 自学习记的是偏差_程序坞变长变短之后仍然适用() throws {
        // 学的时候 32 项；后来多开了两个应用变成 34 项。被挤满的程序坞两端不动，偏差照旧适用。
        let learnedAt = observation(measured: false)
        let lesson = try #require(TrashEstimator.lesson(releasePoint: CGPoint(x: -190, y: 990), observation: learnedAt))

        var more = settings
        more.tileCount = 34
        let later = observation(measured: false, settings: more)
        let estimate = TrashEstimator.estimate(observation: later, lessons: [lesson])
        #expect(estimate.lessonCount == 1)
        #expect(estimate.rect.contains(CGPoint(x: -190, y: 990)))
    }

    @Test func 程序坞设置变了_旧的教训不再适用_回到重新估算() throws {
        let learnedAt = observation(measured: false)
        let lesson = try #require(TrashEstimator.lesson(releasePoint: CGPoint(x: -190, y: 990), observation: learnedAt))

        var smaller = settings
        smaller.tileSize = 36                       // 用户把程序坞调小了
        var moved = settings
        moved.edge = .left                          // 或者挪到了左边
        for changed in [smaller, moved] {
            let fresh = TrashEstimator.estimate(observation: observation(measured: false, settings: changed), lessons: [])
            let withOldLesson = TrashEstimator.estimate(observation: observation(measured: false, settings: changed), lessons: [lesson])
            #expect(withOldLesson == fresh)
            #expect(withOldLesson.lessonCount == 0)
        }
        // 换了一块屏也一样。
        let otherDisplay = observation(measured: false, display: Fixture.builtIn)
        #expect(TrashEstimator.estimate(observation: otherDisplay, lessons: [lesson]).lessonCount == 0)
        // 设置换回来，教训又用得上了。
        #expect(TrashEstimator.estimate(observation: learnedAt, lessons: [lesson]).lessonCount == 1)
    }

    @Test func 公式的教训和实测的教训互不通用() throws {
        let formulaLesson = try #require(TrashEstimator.lesson(releasePoint: CGPoint(x: -190, y: 990), observation: observation(measured: false)))
        #expect(formulaLesson.basis == "formula")
        let measured = TrashEstimator.estimate(observation: observation(measured: true), lessons: [formulaLesson])
        #expect(measured.lessonCount == 0)
        #expect(measured.confidence == 0.75)
    }

    @Test func 松手点不在程序坞那一带_不当教训() throws {
        let current = observation(measured: true)
        // 拖进了一个打开着的废纸篓窗口（屏幕中间）。
        #expect(TrashEstimator.lesson(releasePoint: CGPoint(x: -900, y: 400), observation: current) == nil)
        // 在程序坞上，但在前半段（那里不可能是废纸篓）。
        #expect(TrashEstimator.lesson(releasePoint: CGPoint(x: -1500, y: 990), observation: current) == nil)
        // 在另一块屏上。
        #expect(TrashEstimator.lesson(releasePoint: CGPoint(x: 1400, y: 960), observation: current) == nil)
        // 在程序坞末端附近：算。
        #expect(TrashEstimator.lesson(releasePoint: CGPoint(x: -60, y: 1000), observation: current) != nil)
    }

    @Test func 几次松手点彼此差得很远_不敢太自信() throws {
        let current = observation(measured: false)
        let near = try #require(TrashEstimator.lesson(releasePoint: CGPoint(x: -72, y: 990), observation: current))
        let far = try #require(TrashEstimator.lesson(releasePoint: CGPoint(x: -230, y: 990), observation: current))
        let estimate = TrashEstimator.estimate(observation: current, lessons: [near, far])
        // 压到 0.5：低于"凭位置认定被删"要求的 0.6。
        #expect(estimate.confidence == 0.5)
        #expect(estimate.confidence < JudgeTuning().trashInferenceConfidence)
    }

    @Test func 混进一条离谱的教训_估算不被带偏() throws {
        let current = observation(measured: true)
        var lessons: [TrashLesson] = []
        for x in [-70.0, -75.0, -68.0, -74.0] {
            lessons.append(try #require(TrashEstimator.lesson(releasePoint: CGPoint(x: x, y: 990), observation: current)))
        }
        let clean = TrashEstimator.estimate(observation: current, lessons: lessons)

        // 第五条偏了两格半（勉强够得上被记下来）。
        lessons.append(try #require(TrashEstimator.lesson(releasePoint: CGPoint(x: -210, y: 990), observation: current)))
        let polluted = TrashEstimator.estimate(observation: current, lessons: lessons)
        // 取的是中位数：位置不动。只是不再那么自信。
        #expect(polluted.rect.midX == clean.rect.midX)
        #expect(polluted.rect.contains(CGPoint(x: -72, y: 990)))
        #expect(polluted.confidence == 0.5)
    }

    @Test func 偏差超过三格的松手点不学() throws {
        let current = observation(measured: true)   // 估算的那一格中心在 x = −72.25，一格宽 56.5
        #expect(TrashEstimator.lesson(releasePoint: CGPoint(x: -72.25 - 169, y: 990), observation: current) != nil)
        #expect(TrashEstimator.lesson(releasePoint: CGPoint(x: -72.25 - 171, y: 990), observation: current) == nil)
        // 屏幕右半边、底部那一带的随便一个位置（比如一个废纸篓窗口的下沿）：不学。
        #expect(TrashEstimator.lesson(releasePoint: CGPoint(x: -400, y: 960), observation: current) == nil)
    }

    @Test func 教训只留最近几条_总量有上限() throws {
        let current = observation(measured: true)
        var lessons: [TrashLesson] = []
        for index in 0..<12 {
            let lesson = try #require(TrashEstimator.lesson(releasePoint: CGPoint(x: -80 + CGFloat(index), y: 990), observation: current))
            lessons = TrashEstimator.remember(lesson, in: lessons)
        }
        #expect(lessons.count == TrashEstimator.lessonWindow)
        // 留下的是最新的五条。
        #expect(abs(lessons[0].axisDelta - (-80 + 7 - -72.25)) < 0.01)

        // 很多组不同的设置：总量不超过上限。
        for size in 0..<60 {
            var other = settings
            other.tileSize = CGFloat(20 + size)
            let observed = observation(measured: false, settings: other)
            if let lesson = TrashEstimator.lesson(releasePoint: TrashEstimator.base(for: observed).slot.center, observation: observed) {
                lessons = TrashEstimator.remember(lesson, in: lessons)
            }
        }
        #expect(lessons.count <= 40)
    }
}

@MainActor
@Suite("废纸篓定位：读取的时机与记忆")
struct TrashLocatorTests {
    let bar = CGRect(x: -1886, y: 953, width: 1852, height: 69)

    @Test func 没有显示器或还没读到程序坞的设置时_估算不出来() throws {
        let noDisplay = FakeDock()
        noDisplay.dockDisplayFrame = nil
        noDisplay.primaryDisplayFrame = nil
        #expect(TrashLocator(dock: noDisplay, store: InMemoryTrashMemory()).estimate(at: 100, isDragging: false) == nil)

        // 设置是在后台读的：读到之前没有估算，读到之后（哪怕只过了一帧）就有了。
        let loading = FakeDock()
        let settings = loading.settings
        loading.settings = nil
        let locator = TrashLocator(dock: loading, store: InMemoryTrashMemory())
        #expect(locator.estimate(at: 100, isDragging: false) == nil)
        #expect(loading.refreshRequests == 1)
        loading.settings = settings
        #expect(locator.estimate(at: 100.02, isDragging: false) != nil)
    }

    @Test func 程序坞没露出来_用公式_露出来了就用量到的() throws {
        let dock = FakeDock()
        let locator = TrashLocator(dock: dock, store: InMemoryTrashMemory())
        let hidden = try #require(locator.estimate(at: 100, isDragging: false))
        #expect(hidden.basis == .formula)

        dock.bar = bar
        // 还没到下一次测量的时刻（平时 10 秒一次）：沿用旧的。
        #expect(try #require(locator.estimate(at: 105, isDragging: false)).basis == .formula)
        let shown = try #require(locator.estimate(at: 110.1, isDragging: false))
        #expect(shown.basis == .measured)
        #expect(shown.confidence == 0.75)
        #expect(locator.observation?.measuredBar == bar)
    }

    @Test func 每帧都问也只按节奏读系统() throws {
        let dock = FakeDock()
        dock.bar = bar
        let locator = TrashLocator(dock: dock, store: InMemoryTrashMemory())
        var time = 100.0
        for _ in 0..<600 {          // 十秒，每秒六十次
            _ = locator.estimate(at: time, isDragging: false)
            time += 1.0 / 60
        }
        #expect((3...4).contains(dock.refreshRequests), "请求重读了 \(dock.refreshRequests) 次设置")
        #expect((1...2).contains(dock.measurements), "量了 \(dock.measurements) 次")
    }

    @Test func 一开始拖就马上量一次_拖拽期间每半秒量一次() throws {
        let dock = FakeDock()
        let locator = TrashLocator(dock: dock, store: InMemoryTrashMemory())
        _ = locator.estimate(at: 100, isDragging: false)
        #expect(dock.measurements == 1)

        dock.bar = bar                                   // 程序坞这时露出来了
        let atDragStart = try #require(locator.estimate(at: 101, isDragging: true))
        #expect(dock.measurements == 2)
        #expect(atDragStart.basis == .measured)

        var time = 101.0
        for _ in 0..<120 {                               // 接着拖两秒
            time += 1.0 / 60
            _ = locator.estimate(at: time, isDragging: true)
        }
        #expect((5...7).contains(dock.measurements), "量了 \(dock.measurements) 次")
    }

    @Test func 程序坞设置变了_读到新设置的那一帧就重新估算() throws {
        let dock = FakeDock()
        let locator = TrashLocator(dock: dock, store: InMemoryTrashMemory())
        let before = try #require(locator.estimate(at: 100, isDragging: false))
        #expect(locator.estimate(at: 100.5, isDragging: false) == before)

        dock.settings?.edge = .left                      // 后台读到：用户把程序坞挪到了左边
        let after = try #require(locator.estimate(at: 101, isDragging: false))
        #expect(after != before)
        #expect(after.rect.minX == Fixture.external.minX)
        #expect(after.rect.midY > Fixture.external.midY)
        #expect(locator.observation?.settings.edge == .left)
    }

    @Test func 鼠标很久没动时_每三十秒才请求重读一次设置_一开始拖就恢复() throws {
        let dock = FakeDock()
        let locator = TrashLocator(dock: dock, store: InMemoryTrashMemory())
        _ = locator.estimate(at: 100, isDragging: false, isIdle: true)
        #expect(dock.refreshRequests == 1)
        _ = locator.estimate(at: 120, isDragging: false, isIdle: true)
        #expect(dock.refreshRequests == 1)
        _ = locator.estimate(at: 130, isDragging: false, isIdle: true)
        #expect(dock.refreshRequests == 2)
        _ = locator.estimate(at: 134, isDragging: true, isIdle: true)
        #expect(dock.refreshRequests == 3)
    }

    @Test func 每三秒请求重读一次程序坞的设置() throws {
        let dock = FakeDock()
        let locator = TrashLocator(dock: dock, store: InMemoryTrashMemory())
        _ = locator.estimate(at: 100, isDragging: false)
        #expect(dock.refreshRequests == 1)
        _ = locator.estimate(at: 102.9, isDragging: false)
        #expect(dock.refreshRequests == 1)
        _ = locator.estimate(at: 103, isDragging: false)
        #expect(dock.refreshRequests == 2)
    }

    @Test func 程序坞换到另一块屏_跟着换() throws {
        let dock = FakeDock()
        let locator = TrashLocator(dock: dock, store: InMemoryTrashMemory())
        let onExternal = try #require(locator.estimate(at: 100, isDragging: false))
        #expect(Fixture.external.contains(onExternal.rect.center))

        dock.dockDisplayFrame = Fixture.builtIn
        let onBuiltIn = try #require(locator.estimate(at: 103, isDragging: false))
        #expect(Fixture.builtIn.contains(onBuiltIn.rect.center))
    }

    @Test func 量到的范围在程序坞藏起来之后继续沿用_前提变了就作废() throws {
        let dock = FakeDock()
        dock.bar = bar
        let locator = TrashLocator(dock: dock, store: InMemoryTrashMemory())
        #expect(try #require(locator.estimate(at: 100, isDragging: false)).basis == .measured)

        dock.bar = nil                                   // 进了全屏空间，程序坞看不见了
        #expect(try #require(locator.estimate(at: 111, isDragging: false)).basis == .measured)

        dock.settings?.tileCount = 33                    // 多开了一个应用：那一条变长了，旧的测量不能用了
        #expect(try #require(locator.estimate(at: 114, isDragging: false)).basis == .formula)
    }

    @Test func 前提变了而程序坞露着_当帧就重新量_不等下一个整点() throws {
        let dock = FakeDock()
        dock.bar = bar
        let locator = TrashLocator(dock: dock, store: InMemoryTrashMemory())
        _ = locator.estimate(at: 100, isDragging: false)
        #expect(dock.measurements == 1)

        // 多开了一个应用：那一条变了样。离上次测量才 1 秒（平时 10 秒量一次），但旧的测量已经不能用了。
        dock.settings?.tileCount = 33
        dock.bar = CGRect(x: -1880, y: 955, width: 1840, height: 67)
        let estimate = try #require(locator.estimate(at: 101, isDragging: false))
        #expect(dock.measurements == 2)
        #expect(estimate.basis == .measured)
        #expect(locator.observation?.measuredBar == dock.bar)
    }

    @Test func 量到的范围过期作废() throws {
        let dock = FakeDock()
        dock.bar = bar
        let locator = TrashLocator(dock: dock, store: InMemoryTrashMemory())
        _ = locator.estimate(at: 100, isDragging: false)
        dock.bar = nil
        #expect(try #require(locator.estimate(at: 390, isDragging: false)).basis == .measured)
        #expect(try #require(locator.estimate(at: 401, isDragging: false)).basis == .formula)
    }

    @Test func 自学习后废纸篓位置被修正_并且记得住() throws {
        let dock = FakeDock()
        let store = InMemoryTrashMemory()
        let locator = TrashLocator(dock: dock, store: store)
        let before = try #require(locator.estimate(at: 100, isDragging: false))
        let release = CGPoint(x: -190, y: 990)
        #expect(!before.rect.contains(release))

        locator.learn(releasePoint: release)
        let after = try #require(locator.estimate(at: 100.1, isDragging: false))
        #expect(after.rect.contains(release))
        #expect(after.confidence > before.confidence)
        #expect(after.lessonCount == 1)
        #expect(locator.lessonCount == 1)

        // 下次启动（新的定位器、同一份存储）：还记得。
        let relaunched = TrashLocator(dock: dock, store: store)
        #expect(try #require(relaunched.estimate(at: 500, isDragging: false)) == after)
    }

    @Test func 不像样的松手点不会被记住() throws {
        let dock = FakeDock()
        let store = InMemoryTrashMemory()
        let locator = TrashLocator(dock: dock, store: store)
        _ = locator.estimate(at: 100, isDragging: false)
        locator.learn(releasePoint: CGPoint(x: -900, y: 400))
        #expect(locator.lessonCount == 0)
        #expect(store.load().isEmpty)
    }

    @Test func 学到的位置能存下来再读回_读不懂的旧内容当作没学过() throws {
        // 用内存里的字典顶替偏好设置：测试不往用户的偏好设置目录里写任何东西。
        let storage = DictionaryStorage()
        let store = PersistentTrashMemory(storage: storage)
        #expect(store.load().isEmpty)

        let observation = DockObservation(settings: DockSettings(edge: .bottom, tileSize: 64, tileCount: 32, separatorCount: 2), displayFrame: Fixture.external)
        let lesson = try #require(TrashEstimator.lesson(releasePoint: CGPoint(x: -190, y: 990), observation: observation))
        store.save([lesson])
        #expect(PersistentTrashMemory(storage: storage).load() == [lesson])
        // 存的只有这一个键，内容里只有数字和几个固定的词。
        #expect(storage.values.keys.sorted() == ["InputSense.trashLessons"])
        let stored = try #require(storage.values["InputSense.trashLessons"].flatMap { String(data: $0, encoding: .utf8) })
        #expect(stored.contains("axisDelta") && stored.contains("bottom"))

        storage.values["InputSense.trashLessons"] = Data("不是合法的内容".utf8)
        #expect(store.load().isEmpty)
    }

    @Test func 用同一份存储重新启动_学到的位置还在() throws {
        let storage = DictionaryStorage()
        let dock = FakeDock()
        let first = TrashLocator(dock: dock, store: PersistentTrashMemory(storage: storage))
        _ = first.estimate(at: 100, isDragging: false)
        first.learn(releasePoint: CGPoint(x: -190, y: 990))

        let second = TrashLocator(dock: dock, store: PersistentTrashMemory(storage: storage))
        #expect(second.lessonCount == 1)
        #expect(try #require(second.estimate(at: 100, isDragging: false)).rect.contains(CGPoint(x: -190, y: 990)))
    }
}

/// 内存里的字典，顶替偏好设置。
final class DictionaryStorage: LessonStorage {
    var values: [String: Data] = [:]

    func lessonData(forKey key: String) -> Data? { values[key] }
    func setLessonData(_ data: Data, forKey key: String) { values[key] = data }
}
