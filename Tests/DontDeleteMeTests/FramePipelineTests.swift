// 帧流水线的测试：用假模块验证"数据确实按接口约定的路线流动"。
//
// 假模块只实现 DDMCore 的协议，并把收到的调用记下来；流水线对此毫不知情——
// 这也是模块边界清不清楚的一个检验。

import CoreGraphics
import Foundation
import Testing
@testable import DDMCore
@testable import DontDeleteMe

// MARK: - 假模块

@MainActor
private final class FakeIcons: IconProviding {
    var snapshot: IconSnapshot = .empty()
    var onUpdate: (@MainActor (IconUpdate) -> Void)?
    var startCount = 0, stopCount = 0, refreshCount = 0
    var paces: [IconPollingPace] = []

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
    func refreshNow() { refreshCount += 1 }
    func setPollingPace(_ pace: IconPollingPace) { paces.append(pace) }

    /// 模拟"后台读完一轮"的上报。
    func report(_ update: IconUpdate) {
        snapshot = update.snapshot
        onUpdate?(update)
    }
}

@MainActor
private final class FakeSensor: InteractionSensing {
    var received: [IconUpdate] = []
    var resetCount = 0
    /// 下一帧要返回的事实（由测试设定）。
    var next: (FrameTime) -> InteractionFacts = { InteractionFacts(time: $0) }

    func update(time: FrameTime, icons: IconUpdate) -> InteractionFacts {
        received.append(icons)
        return next(time)
    }

    func reset() { resetCount += 1 }
}

/// 假的情绪引擎：每个图标一张脸；表情和省电需求由测试设定。用引用类型，方便测试观察。
private final class FakeDirector: EmotionDirecting {
    var received: [EmotionInput] = []
    var resetCount = 0
    var demand: FrameDemand = .idle
    var stateFor: (DesktopIcon) -> FaceState = { FaceState(seed: $0.id.faceSeed) }
    var extraFaces: [FacePlacement] = []

    func update(_ input: EmotionInput) -> EmotionOutput {
        received.append(input)
        let faces = input.icons.snapshot.icons.map {
            FacePlacement(iconID: $0.id, rect: $0.imageRect, state: stateFor($0))
        }
        return EmotionOutput(faces: faces + extraFaces, demand: demand)
    }

    func reset() { resetCount += 1 }
}

/// 假的表情绘制者：记下画了什么。哭的脸带"每帧都动"的循环动画并向下外扩；打瞌睡的脸带"每 0.125 秒动一下"的慢动画。
/// （只在测试的主线程上使用，所以标 @unchecked Sendable。）
private final class FakeRenderer: FaceRendering, @unchecked Sendable {
    var drawn: [(state: FaceState, rect: CGRect, time: TimeInterval)] = []

    func draw(_ state: FaceState, in iconRect: CGRect, context: CGContext, time: TimeInterval) {
        drawn.append((state, iconRect, time))
    }

    func outsets(for state: FaceState, iconSize: CGSize) -> EdgeOutsets {
        state.tears > 0 ? EdgeOutsets(bottom: iconSize.height / 2) : .zero
    }

    func animationInterval(for state: FaceState) -> TimeInterval? {
        if state.tears > 0 { return 0 }
        if state.sleepiness > 0 { return 0.125 }
        return nil
    }
}

@MainActor
private final class FakeOverlay: OverlayHosting {
    weak var frameSource: (any OverlayFrameSource)?
    var isDesktopVisible = true
    var onDesktopVisibilityChange: (@MainActor (Bool) -> Void)?
    var startCount = 0, stopCount = 0, requestCount = 0

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
    func requestFrame() { requestCount += 1 }

    func setVisible(_ visible: Bool) {
        isDesktopVisible = visible
        onDesktopVisibilityChange?(visible)
    }
}

// MARK: - 测试台

@MainActor
private struct Bench {
    let icons = FakeIcons()
    let sensor = FakeSensor()
    let director = FakeDirector()
    let renderer = FakeRenderer()
    let overlay = FakeOverlay()
    let pause = PauseSwitch()
    let pipeline: FramePipeline

    init() {
        pipeline = FramePipeline(icons: icons, sensor: sensor, director: director, renderer: renderer, overlay: overlay, pause: pause)
    }

    func frame(at seconds: TimeInterval) -> OverlayFrame {
        pipeline.overlayFrame(at: time(seconds))
    }

    func time(_ seconds: TimeInterval) -> FrameTime {
        FrameTime(monotonic: seconds, wallClock: Date(timeIntervalSince1970: 1_800_000_000 + seconds))
    }
}

private func makeIcon(_ raw: UInt64, x: CGFloat = 100) -> DesktopIcon {
    DesktopIcon(id: IconID(rawValue: raw), kind: .file, imageRect: CGRect(x: x, y: 100, width: 64, height: 64))
}

private func makeSnapshot(_ icons: [DesktopIcon], revision: UInt64) -> IconSnapshot {
    IconSnapshot(icons: icons, status: .ok, capturedAt: 0, revision: revision)
}

private func makeContext() -> CGContext {
    CGContext(
        data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
}

// MARK: - 测试

@Suite("帧流水线")
@MainActor
struct FramePipelineTests {
    @Test func 启动时接好各模块并开始工作() {
        let bench = Bench()
        bench.pipeline.start()
        bench.pipeline.start()   // 重复启动无副作用

        #expect(bench.icons.startCount == 1)
        #expect(bench.overlay.startCount == 1)
        #expect(bench.overlay.frameSource === bench.pipeline)
        #expect(bench.icons.onUpdate != nil)
        #expect(bench.icons.paces == [.active])

        bench.pipeline.stop()
        #expect(bench.icons.stopCount == 1)
        #expect(bench.overlay.stopCount == 1)
        #expect(bench.icons.onUpdate == nil)
    }

    @Test func 图标上报会唤醒叠加层并在下一帧交给交互感知和情绪引擎() {
        let bench = Bench()
        bench.pipeline.start()
        let a = makeIcon(1)

        bench.icons.report(IconUpdate(snapshot: makeSnapshot([a], revision: 1), isReset: true))
        #expect(bench.overlay.requestCount == 1)
        #expect(bench.pipeline.stats.iconUpdates == 1)

        let frame = bench.frame(at: 10)
        // 交互感知和情绪引擎拿到的是同一份图标输入、同一个时间。
        #expect(bench.sensor.received.count == 1)
        #expect(bench.sensor.received[0].isReset)
        #expect(bench.director.received[0].icons == bench.sensor.received[0])
        #expect(bench.director.received[0].time == bench.time(10))
        #expect(bench.director.received[0].facts.time == bench.time(10))
        // 情绪引擎给的脸变成了画布项。
        #expect(frame.items.map(\.iconID) == [a.id])
        #expect(frame.items[0].rect == a.imageRect)
        #expect(frame.items[0].layer == .desktop)
    }

    @Test func 两帧之间的多次上报被合并而下一帧不再重复() {
        let bench = Bench()
        bench.pipeline.start()
        let a = makeIcon(1), b = makeIcon(2, x: 300)
        bench.icons.report(IconUpdate(snapshot: makeSnapshot([a], revision: 1), changes: [.added(a)]))
        bench.icons.report(IconUpdate(snapshot: makeSnapshot([a, b], revision: 2), changes: [.added(b)]))

        _ = bench.frame(at: 1)
        #expect(bench.sensor.received[0].changes == [.added(a), .added(b)])
        #expect(bench.sensor.received[0].snapshot.revision == 2)

        // 没有新的上报：下一帧拿到的是"没变化"，变化事件不会被重复投递。
        _ = bench.frame(at: 2)
        #expect(bench.sensor.received[1].changes.isEmpty)
        #expect(bench.sensor.received[1].snapshot.revision == 2)
    }

    @Test func 交互感知要求刷新时转达给图标提供者() {
        let bench = Bench()
        bench.pipeline.start()
        _ = bench.frame(at: 1)
        #expect(bench.icons.refreshCount == 0)

        bench.sensor.next = { InteractionFacts(time: $0, wantsIconRefresh: true) }
        _ = bench.frame(at: 2)
        #expect(bench.icons.refreshCount == 1)
    }

    @Test func 省电需求取两个模块里更紧的() {
        let bench = Bench()
        bench.pipeline.start()

        bench.sensor.next = { InteractionFacts(time: $0, demand: .by($0.monotonic + 1)) }
        bench.director.demand = .idle
        #expect(bench.frame(at: 10).demand == .by(11))

        bench.director.demand = .by(10.25)
        #expect(bench.frame(at: 10).demand == .by(10.25))

        bench.director.demand = .continuous
        #expect(bench.frame(at: 10).demand == .continuous)
    }

    @Test func 表情没变就沿用版本号变了才换新的() {
        let bench = Bench()
        bench.pipeline.start()
        let a = makeIcon(1), b = makeIcon(2, x: 300)
        bench.icons.report(IconUpdate(snapshot: makeSnapshot([a, b], revision: 1), isReset: true))

        let first = bench.frame(at: 1)
        let second = bench.frame(at: 2)
        #expect(first.items.map(\.contentVersion) == second.items.map(\.contentVersion))
        #expect(Set(first.items.map(\.contentVersion)).count == 2)   // 两张脸的版本号互不相同

        // 只有 a 脸红了：a 换版本号，b 不变。
        bench.director.stateFor = { FaceState(seed: $0.id.faceSeed, blush: $0.id == a.id ? 0.5 : 0) }
        let third = bench.frame(at: 3)
        #expect(third.items[0].contentVersion != second.items[0].contentVersion)
        #expect(third.items[1].contentVersion == second.items[1].contentVersion)
    }

    @Test func 带循环动画的表情每帧换版本号并要求连续出帧() {
        let bench = Bench()
        bench.pipeline.start()
        let a = makeIcon(1)
        bench.icons.report(IconUpdate(snapshot: makeSnapshot([a], revision: 1), isReset: true))
        bench.director.stateFor = { FaceState(mood: .crying, seed: $0.id.faceSeed, tears: 1) }

        let first = bench.frame(at: 1)
        let second = bench.frame(at: 2)
        #expect(first.demand == .continuous)
        #expect(first.items[0].contentVersion != second.items[0].contentVersion)
        // 外扩取自表情绘制者：眼泪往下流，画布向下多留半个图标高。
        #expect(first.items[0].outsets == EdgeOutsets(bottom: 32))
        #expect(first.items[0].canvasRect == CGRect(x: 100, y: 100, width: 64, height: 96))
    }

    @Test func 慢动画按它声明的间隔重画而不是每帧() {
        let bench = Bench()
        bench.pipeline.start()
        let a = makeIcon(1)
        bench.icons.report(IconUpdate(snapshot: makeSnapshot([a], revision: 1), isReset: true))
        // 打瞌睡：假的表情绘制者声明每 0.125 秒刷新一次（取 1/8 秒是为了让测试里的时刻都是精确的二进制小数）。
        bench.director.stateFor = { FaceState(mood: .dozing, seed: $0.id.faceSeed, sleepiness: 1) }

        let first = bench.frame(at: 1.0)
        #expect(first.demand == .by(1.125))          // 不是连续出帧：0.125 秒后再来

        // 还没到刷新时刻：版本号不变（不重画），需求仍指向同一个时刻。
        let early = bench.frame(at: 1.0625)
        #expect(early.items[0].contentVersion == first.items[0].contentVersion)
        #expect(early.demand == .by(1.125))

        // 到了：换版本号（重画一次），并约好下一次。
        let due = bench.frame(at: 1.125)
        #expect(due.items[0].contentVersion != first.items[0].contentVersion)
        #expect(due.demand == .by(1.25))

        // 醒了（表情变了，不再有循环动画）：重画一次，之后不再有定时需求。
        bench.director.stateFor = { FaceState(seed: $0.id.faceSeed) }
        let awake = bench.frame(at: 1.1875)
        #expect(awake.items[0].contentVersion != due.items[0].contentVersion)
        #expect(awake.demand == .idle)
    }

    @Test func 绘制回调把对应的表情交给表情绘制者() {
        let bench = Bench()
        bench.pipeline.start()
        let a = makeIcon(1)
        bench.icons.report(IconUpdate(snapshot: makeSnapshot([a], revision: 1), isReset: true))
        bench.director.stateFor = { FaceState(mood: .shy, seed: $0.id.faceSeed, blush: 0.8) }

        let frame = bench.frame(at: 5)
        bench.pipeline.drawOverlayItem(frame.items[0], in: makeContext(), at: bench.time(5))

        #expect(bench.renderer.drawn.count == 1)
        #expect(bench.renderer.drawn[0].state.blush == 0.8)
        #expect(bench.renderer.drawn[0].rect == a.imageRect)
        #expect(bench.renderer.drawn[0].time == 5)
        #expect(bench.pipeline.stats.draws == 1)

        // 已经不在这一帧里的项：不画。
        let stale = OverlayItem(iconID: IconID(rawValue: 99), rect: .zero)
        bench.pipeline.drawOverlayItem(stale, in: makeContext(), at: bench.time(5))
        #expect(bench.renderer.drawn.count == 1)
    }

    @Test func 越界的表情参数会被夹回合法范围且重复的脸只认第一张() {
        let bench = Bench()
        bench.pipeline.start()
        let a = makeIcon(1)
        bench.icons.report(IconUpdate(snapshot: makeSnapshot([a], revision: 1), isReset: true))
        bench.director.stateFor = { FaceState(seed: $0.id.faceSeed, fear: 3) }
        // 情绪引擎违反约定，给同一个（图标，层）出了第二张脸。
        bench.director.extraFaces = [FacePlacement(iconID: a.id, rect: .zero, state: FaceState(seed: 0))]

        let frame = bench.frame(at: 1)
        #expect(frame.items.count == 1)
        bench.pipeline.drawOverlayItem(frame.items[0], in: makeContext(), at: bench.time(1))
        #expect(bench.renderer.drawn[0].state.fear == 1)
    }

    @Test func 拖拽层的脸与桌面层的脸是两个画布项() {
        let bench = Bench()
        bench.pipeline.start()
        let a = makeIcon(1)
        bench.icons.report(IconUpdate(snapshot: makeSnapshot([a], revision: 1), isReset: true))
        bench.director.extraFaces = [
            FacePlacement(iconID: a.id, rect: CGRect(x: 500, y: 400, width: 64, height: 64), layer: .drag, state: FaceState(mood: .scared, seed: 0, fear: 0.5)),
        ]

        let frame = bench.frame(at: 1)
        #expect(frame.items.map(\.layer) == [.desktop, .drag])
        #expect(frame.items[0].key != frame.items[1].key)
    }

    @Test func 暂停时让图标提供者停下恢复时重置判断并立即刷新() {
        let bench = Bench()
        bench.pipeline.start()

        bench.pause.setPaused(true)
        #expect(bench.icons.paces == [.active, .suspended])
        #expect(bench.sensor.resetCount == 0)

        let requestsBefore = bench.overlay.requestCount
        bench.pause.setPaused(false)
        #expect(bench.icons.paces == [.active, .suspended, .active])
        #expect(bench.sensor.resetCount == 1)
        #expect(bench.director.resetCount == 1)
        #expect(bench.icons.refreshCount == 1)
        #expect(bench.overlay.requestCount == requestsBefore + 1)
    }

    @Test func 桌面看不见时同样让图标提供者停下() {
        let bench = Bench()
        bench.pipeline.start()

        bench.overlay.setVisible(false)
        #expect(bench.icons.paces.last == .suspended)
        bench.overlay.setVisible(true)
        #expect(bench.icons.paces.last == .active)
        #expect(bench.sensor.resetCount == 1)
    }

    @Test func 桌面看不见时收到的帧回调会被单独记数() {
        let bench = Bench()
        bench.pipeline.start()
        #expect(bench.pipeline.isDesktopVisible)

        _ = bench.frame(at: 1)
        #expect(bench.pipeline.stats.frames == 1)
        #expect(bench.pipeline.stats.framesWhileDesktopHidden == 0)

        // 约定是看不见就不出帧；万一叠加层还是回调了，这里记下来，自检据此报错。
        bench.overlay.setVisible(false)
        #expect(!bench.pipeline.isDesktopVisible)
        _ = bench.frame(at: 2)
        #expect(bench.pipeline.stats.frames == 2)
        #expect(bench.pipeline.stats.framesWhileDesktopHidden == 1)
    }

    @Test func 暂停状态下启动则一开始就不读图标() {
        let bench = Bench()
        bench.pause.setPaused(true)
        bench.pipeline.start()
        #expect(bench.icons.paces == [.suspended])
    }

    @Test func 鼠标久不动就让图标提供者放慢一有动静立刻恢复() {
        let bench = Bench()
        bench.pipeline.start()

        bench.sensor.next = { InteractionFacts(time: $0, mouse: MouseState(idleDuration: 1)) }
        _ = bench.frame(at: 1)
        #expect(bench.icons.paces == [.active])

        bench.sensor.next = { InteractionFacts(time: $0, mouse: MouseState(idleDuration: 30)) }
        _ = bench.frame(at: 31)
        #expect(bench.icons.paces == [.active, .idle])

        // 鼠标没动，但有图标被悬停着（例如刚停上去）：仍算活跃。
        bench.sensor.next = {
            InteractionFacts(time: $0, mouse: MouseState(idleDuration: 30), hover: HoverState(iconID: IconID(rawValue: 1), duration: 30))
        }
        _ = bench.frame(at: 32)
        #expect(bench.icons.paces == [.active, .idle, .active])
    }

    @Test func 停止之后不再响应图标上报和暂停开关() {
        let bench = Bench()
        bench.pipeline.start()
        bench.pipeline.stop()

        let pacesAfterStop = bench.icons.paces
        bench.pause.setPaused(true)
        bench.pause.setPaused(false)
        #expect(bench.icons.paces == pacesAfterStop)
        #expect(bench.sensor.resetCount == 0)
    }
}

@Suite("命令行参数")
struct LaunchOptionsTests {
    @Test func 普通启动没有自检() {
        #expect(LaunchOptions(arguments: ["DontDeleteMe"]).smokeTestDuration == nil)
    }

    @Test func 自检的秒数可给可不给() {
        #expect(LaunchOptions(arguments: ["DontDeleteMe", "--smoke-test"]).smokeTestDuration == 3)
        #expect(LaunchOptions(arguments: ["DontDeleteMe", "--smoke-test", "1.5"]).smokeTestDuration == 1.5)
        #expect(LaunchOptions(arguments: ["DontDeleteMe", "--smoke-test", "-2"]).smokeTestDuration == 3)
        #expect(LaunchOptions(arguments: ["DontDeleteMe", "--smoke-test", "abc"]).smokeTestDuration == 3)
    }

    @Test func 强制当作桌面看得见只在自检模式下起作用() {
        #expect(!LaunchOptions(arguments: ["DontDeleteMe", "--smoke-test"]).assumesDesktopVisible)
        #expect(LaunchOptions(arguments: ["DontDeleteMe", "--smoke-test", "4", "--assume-visible"]).assumesDesktopVisible)
        #expect(LaunchOptions(arguments: ["DontDeleteMe", "--assume-visible", "--smoke-test"]).assumesDesktopVisible)
        // 没有 --smoke-test：这个参数不起作用，应用按正常方式运行。
        #expect(!LaunchOptions(arguments: ["DontDeleteMe", "--assume-visible"]).assumesDesktopVisible)
    }
}
