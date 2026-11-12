// docs/接口约定.md 里的用法示例，原样放在这里编译、运行——保证文档里的示例都是真的。
// 改接口或改文档示例时，请两边一起改。

import CoreGraphics
import Foundation
import Testing
@testable import DDMCore

// MARK: - 示例里用到的最小实现（文档 §5、§6、§7 的"实现方示例"）

/// §6 示例：一个最小的表情绘制者——在图标中央画两个黑点当眼睛，哭的时候画布向下多留半个图标。
private struct DotEyesRenderer: FaceRendering {
    func draw(_ state: FaceState, in iconRect: CGRect, context: CGContext, time: TimeInterval) {
        // 画布是 y 向下、单位点；iconRect 给的是哪里，就画在哪里。
        let radius = iconRect.width / 16
        context.setFillColor(gray: 0, alpha: 1)
        for side in [-1.0, 1.0] {
            let center = CGPoint(x: iconRect.midX + side * iconRect.width / 6, y: iconRect.midY)
            context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
    }

    func outsets(for state: FaceState, iconSize: CGSize) -> EdgeOutsets {
        // 成档变化：有泪就向下多留半个图标高，没有就不外扩。
        state.tears > 0 ? EdgeOutsets(bottom: iconSize.height / 2) : .zero
    }

    func animationInterval(for state: FaceState) -> TimeInterval? {
        if state.tears > 0 { return 0 }           // 泪珠下落：每帧都要重画
        if state.sleepiness > 0 { return 0.1 }    // 缓慢起伏：每秒 10 次就够
        return nil                                // 其余是静止画面：表情不变就不重画
    }
}

/// §2 示例（实现方）：图标提供者的骨架——慢的读取放后台，读完回主线程上报。
@MainActor
private final class SketchIconProvider: IconProviding {
    private(set) var snapshot: IconSnapshot = .empty()
    var onUpdate: (@MainActor (IconUpdate) -> Void)?
    private var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        read(isReset: true)
    }

    func stop() { isRunning = false }
    func refreshNow() { read(isReset: false) }
    func setPollingPace(_ pace: IconPollingPace) {}

    private func read(isReset: Bool) {
        let startedAt = ProcessInfo.processInfo.systemUptime   // capturedAt 取读取"开始"的时刻
        Task.detached(priority: .utility) { [weak self] in
            let icons = SketchIconProvider.readFromFinder()                           // 慢：在后台线程
            await self?.publish(icons, capturedAt: startedAt, isReset: isReset)       // 回主线程上报
        }
    }

    /// 必须标 nonisolated：否则它跟着类一起被隔离在主线程，"后台读取"就成了在主线程读。
    /// 真正的实现在这里向访达发请求；示例里直接返回一个假图标。
    private nonisolated static func readFromFinder() -> [DesktopIcon] {
        [DesktopIcon(id: IconID(rawValue: 1), kind: .folder, imageRect: CGRect(x: 100, y: 100, width: 64, height: 64))]
    }

    private func publish(_ icons: [DesktopIcon], capturedAt: TimeInterval, isReset: Bool) {
        guard isRunning else { return }
        let changed = icons != snapshot.icons || snapshot.status != .ok
        snapshot = IconSnapshot(
            icons: icons, status: .ok, capturedAt: capturedAt,
            revision: snapshot.revision + (changed ? 1 : 0)   // 内容变了才加一
        )
        onUpdate?(IconUpdate(snapshot: snapshot, isReset: isReset))
    }
}

/// §5 示例：一个最小的情绪引擎——鼠标悬停的图标脸红，其余平静，所有人都看着鼠标。
private struct BlushOnHoverDirector: EmotionDirecting {
    mutating func update(_ input: EmotionInput) -> EmotionOutput {
        let mouse = input.facts.mouse.position
        let faces = input.icons.snapshot.icons.map { icon -> FacePlacement in
            var state = FaceState(seed: icon.id.faceSeed)
            state.gazeTarget = mouse.offset(from: icon.imageRect.center)   // 视线目标：相对图标中心
            state.gazeFollow = 1
            if input.facts.hover?.iconID == icon.id {
                state.mood = .shy
                state.blush = 1
            }
            return FacePlacement(iconID: icon.id, rect: icon.imageRect, layer: .desktop, state: state)
        }
        return EmotionOutput(faces: faces, demand: .idle)
    }

    mutating func reset() {}
}

/// §7 示例：帧回调的接收方——每帧给出一个画布项，被要求重画时把它涂黑。
@MainActor
private final class OneBoxSource: OverlayFrameSource {
    func overlayFrame(at time: FrameTime) -> OverlayFrame {
        let item = OverlayItem(
            iconID: IconID(rawValue: 1),
            layer: .desktop,
            rect: CGRect(x: 100, y: 100, width: 64, height: 64),
            outsets: EdgeOutsets(all: 8),
            contentVersion: 1   // 内容不变就一直用同一个版本号
        )
        return OverlayFrame(items: [item], demand: .by(time.monotonic + 1))   // 一秒后再来
    }

    func drawOverlayItem(_ item: OverlayItem, in context: CGContext, at time: FrameTime) {
        // 画布已经是全局坐标，直接用 item.rect。
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(item.rect)
    }
}

/// §7 示例（实现方）：把一块位图画布调成"全局坐标、y 向下、单位点"，并裁剪到画布矩形。
/// - Parameters:
///   - canvasRect: 这块画布对应的全局矩形（即 `item.canvasRect`）。
///   - scale: 所在显示器的缩放（1 点 = 几个像素）。
private func makeCanvas(for canvasRect: CGRect, scale: CGFloat) -> CGContext {
    let context = CGContext(
        data: nil,
        width: Int((canvasRect.width * scale).rounded(.up)),
        height: Int((canvasRect.height * scale).rounded(.up)),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // 位图画布默认原点在左下角、y 向上、单位像素。三步变成全局坐标：
    context.translateBy(x: 0, y: CGFloat(context.height))             // 1. 原点挪到左上角
    context.scaleBy(x: scale, y: -scale)                              // 2. y 翻转成向下，单位变成点
    context.translateBy(x: -canvasRect.minX, y: -canvasRect.minY)     // 3. 原点挪到全局原点
    context.clip(to: canvasRect)
    return context
}

/// 读出位图里某个像素的不透明度（行 0 是最上面一行）。
private func alpha(of context: CGContext, pixelX: Int, pixelY: Int) -> UInt8 {
    let data = context.data!.assumingMemoryBound(to: UInt8.self)
    return data[pixelY * context.bytesPerRow + pixelX * 4 + 3]
}

// MARK: - 示例

@Suite("接口约定里的示例")
struct DocExampleTests {
    private let time = FrameTime(monotonic: 100, wallClock: Date(timeIntervalSince1970: 1_800_000_000))

    @Test func 第1节_坐标换算() {
        // 测试里用造出来的布局；应用里用 DisplayLayout.current()。
        let builtIn = DisplayInfo(id: DisplayID(rawValue: 1), frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
        let external = DisplayInfo(id: DisplayID(rawValue: 2), frame: CGRect(x: -1920, y: -98, width: 1920, height: 1080), scale: 1)
        let layout = DisplayLayout(displays: [builtIn, external])

        // AppKit → 全局：例如把 NSEvent.mouseLocation 换成全局坐标。
        let mouse = layout.globalPoint(fromAppKit: CGPoint(x: 200, y: 900))
        #expect(mouse == CGPoint(x: 200, y: 82))

        // 全局 → AppKit：例如给 NSWindow.setFrame 用。
        let windowFrame = layout.appKitRect(fromGlobal: external.frame)
        #expect(windowFrame == CGRect(x: -1920, y: 0, width: 1920, height: 1080))

        // 全局 → 屏内：图标在它所在那块屏的窗口里的位置。
        let iconRect = CGRect(x: -1820, y: 2, width: 64, height: 64)
        let display = layout.display(bestFor: iconRect)!
        #expect(display.id == external.id)
        #expect(display.localRect(fromGlobal: iconRect) == CGRect(x: 100, y: 100, width: 64, height: 64))
    }

    @Test func 第2节_消费图标更新() {
        let old = DesktopIcon(id: IconID(rawValue: 7), kind: .folder, imageRect: CGRect(x: 100, y: 100, width: 64, height: 64))
        var moved = old
        moved.imageRect.origin = CGPoint(x: 400, y: 300)
        let newcomer = DesktopIcon(id: IconID(rawValue: 8), kind: .file, imageRect: CGRect(x: 600, y: 100, width: 64, height: 64))
        let gone = DesktopIcon(id: IconID(rawValue: 9), kind: .file, imageRect: CGRect(x: 800, y: 100, width: 64, height: 64))
        let update = IconUpdate(
            snapshot: IconSnapshot(icons: [moved, newcomer], status: .ok, capturedAt: 99.5, revision: 4),
            changes: [.moved(from: old, to: moved), .added(newcomer), .removed(gone, trashed: .yes)]
        )

        var log: [String] = []
        if update.isReset {
            log.append("整体重载：按 update.snapshot 无动画地重建")
        }
        for change in update.changes {
            switch change {
            case let .added(icon):
                log.append("新增 \(icon.kind.rawValue)")
            case let .removed(icon, trashed):
                log.append("消失 \(icon.kind.rawValue)，进废纸篓：\(trashed.rawValue)")
            case let .moved(from, to):
                log.append("移动 \(to.imageRect.minX - from.imageRect.minX),\(to.imageRect.minY - from.imageRect.minY)")
            }
        }
        #expect(log == ["移动 300.0,200.0", "新增 file", "消失 file，进废纸篓：yes"])

        // 命中测试：鼠标点在哪个图标上。
        #expect(update.snapshot.icon(at: CGPoint(x: 410, y: 310))?.id == moved.id)
        // 状态不正常时不画脸。
        #expect(update.snapshot.status.isUsable)
    }

    @MainActor
    @Test func 第2节_图标提供者后台读取主线程上报() async {
        let provider = SketchIconProvider()

        /// 等下一次上报。
        func nextUpdate(after action: @MainActor () -> Void) async -> IconUpdate {
            await withCheckedContinuation { continuation in
                provider.onUpdate = { update in
                    provider.onUpdate = nil
                    continuation.resume(returning: update)
                }
                action()
            }
        }

        // 第一次读取完成：整体重载。
        let first = await nextUpdate { provider.start() }
        #expect(first.isReset)
        #expect(first.snapshot.status == .ok)
        #expect(first.snapshot.icons.count == 1)
        #expect(first.snapshot.revision == 1)
        #expect(provider.snapshot == first.snapshot)

        // refreshNow：即使什么都没变也要回调一次——revision 不变，capturedAt 更新。
        let second = await nextUpdate { provider.refreshNow() }
        #expect(!second.isReset)
        #expect(second.changes.isEmpty)
        #expect(second.snapshot.revision == 1)
        #expect(second.snapshot.capturedAt >= first.snapshot.capturedAt)

        provider.stop()
    }

    @Test func 第3节_读取交互事实() {
        let iconID = IconID(rawValue: 7)
        let trashRect = CGRect(x: -200, y: 900, width: 64, height: 64)
        let facts = InteractionFacts(
            time: time,
            mouse: MouseState(position: CGPoint(x: -170, y: 930), buttons: .left, velocity: CGVector(dx: -300, dy: 400)),
            isMouseOverDesktop: false,
            drag: DragState(
                iconID: iconID,
                grabOffset: CGVector(dx: 20, dy: 30),
                originImageRect: CGRect(x: 100, y: 100, width: 64, height: 64),
                position: CGPoint(x: -170, y: 930),
                velocity: CGVector(dx: -300, dy: 400),
                shake: 0.1,
                startedAt: 98
            ),
            trash: TrashInfo(estimatedRect: trashRect, confidence: 0.6, distance: 0, closingSpeed: 500, isApproaching: true, isOver: true),
            demand: .continuous
        )

        // 被拖图标的脸画在拖影上：鼠标位置 − 抓取偏移。
        if let drag = facts.drag {
            #expect(drag.currentImageRect == CGRect(x: -190, y: 900, width: 64, height: 64))
        }
        // 离废纸篓多近、是不是正朝它去、是不是已经在它上方。
        if let trash = facts.trash {
            #expect(trash.isOver && trash.isApproaching && trash.distance == 0)
        }

        // 一次性事件：松手后的某一帧里出现一次。
        let later = InteractionFacts(
            time: time.advanced(by: 0.4),
            dragOutcomes: [DragOutcome(iconID: iconID, kind: .trashed, releasePoint: CGPoint(x: -170, y: 930))],
            deletions: [DeletionEvent(iconID: iconID, lastImageRect: CGRect(x: 100, y: 100, width: 64, height: 64), wasDragged: true, trashed: .yes)]
        )
        for outcome in later.dragOutcomes {
            switch outcome.kind {
            case .trashed: break                               // 真的被删了
            case .moved, .leftDesktop, .cancelled: break       // 虚惊一场
            case .unknown: break                               // 判断不出来
            }
        }
        #expect(later.deletions.first?.lastImageRect.origin == CGPoint(x: 100, y: 100))   // 幽灵从这里飘起
    }

    @Test func 第4节_拼出一个表情() {
        let icon = DesktopIcon(id: IconID(rawValue: 7), kind: .file, imageRect: CGRect(x: 100, y: 100, width: 64, height: 64))
        let trashCenter = CGPoint(x: 900, y: 1000)

        var state = FaceState(seed: icon.id.faceSeed)   // 默认：平静、平视前方、睁着眼
        state.mood = .scared
        state.gazeTarget = trashCenter.offset(from: icon.imageRect.center)   // 死盯废纸篓
        state.gazeFollow = 1
        state.fear = 0.7
        state.sweat = 0.5
        state.tremble = 0.3

        #expect(state.gazeTarget == CGVector(dx: 768, dy: 868))
        #expect(state.isValid)
        #expect(state.blink == 0 && state.tears == 0)
    }

    @Test func 第5节_情绪引擎逐帧推进() {
        let a = DesktopIcon(id: IconID(rawValue: 1), kind: .file, imageRect: CGRect(x: 100, y: 100, width: 64, height: 64))
        let b = DesktopIcon(id: IconID(rawValue: 2), kind: .folder, imageRect: CGRect(x: 300, y: 100, width: 64, height: 64))
        let snapshot = IconSnapshot(icons: [a, b], status: .ok, capturedAt: 99, revision: 1)

        var director = BlushOnHoverDirector()
        let facts = InteractionFacts(
            time: time,
            mouse: MouseState(position: CGPoint(x: 132, y: 132)),
            isMouseOverDesktop: true,
            hover: HoverState(iconID: a.id, duration: 0.5)
        )
        let output = director.update(EmotionInput(time: time, icons: .unchanged(snapshot), facts: facts))

        #expect(output.faces.map(\.state.mood) == [.shy, .calm])
        #expect(output.faces[1].state.gazeTarget == CGVector(dx: -200, dy: 0))   // b 看向左边的鼠标
        #expect(output.faces.allSatisfy { $0.layer == .desktop && $0.state.isValid })

        // 省电信号：应用据此决定下一帧什么时候要。
        switch output.demand {
        case .continuous: break          // 有参数还在变：下一帧接着算
        case let .by(deadline): _ = deadline   // 静止，但最晚这个时刻要再算（如下一次眨眼）
        case .idle: break                // 没有新输入就不必再算
        }
    }

    @Test func 第6节_表情绘制者画在给定的矩形上() {
        let renderer = DotEyesRenderer()
        let iconRect = CGRect(x: 100, y: 100, width: 64, height: 64)
        var state = FaceState(mood: .crying, seed: 1)
        state.tears = 1

        // 应用把外扩交给叠加层，叠加层据此准备画布。
        let outsets = renderer.outsets(for: state, iconSize: iconRect.size)
        let canvasRect = iconRect.expanded(by: outsets)
        #expect(canvasRect == CGRect(x: 100, y: 100, width: 64, height: 96))
        #expect(renderer.animationInterval(for: state) == 0)
        #expect(renderer.animationInterval(for: FaceState(mood: .dozing, seed: 1, sleepiness: 1)) == 0.1)
        #expect(renderer.animationInterval(for: FaceState(seed: 1)) == nil)

        let context = makeCanvas(for: canvasRect, scale: 2)
        renderer.draw(state, in: iconRect, context: context, time: time.monotonic)

        // 左眼中心在全局 (121.33, 132) → 画布内 (21.33, 32) 点 → 2x 下像素 (42, 64)。
        #expect(alpha(of: context, pixelX: 42, pixelY: 64) == 255)
        // 图标正中（两眼之间）是透明的。
        #expect(alpha(of: context, pixelX: 64, pixelY: 64) == 0)
    }

    @MainActor
    @Test func 第7节_叠加层给的画布是全局坐标() {
        let source = OneBoxSource()
        let frame = source.overlayFrame(at: time)
        let item = frame.items[0]
        #expect(item.canvasRect == CGRect(x: 92, y: 92, width: 80, height: 80))
        #expect(frame.demand == .by(101))

        // 叠加层一侧：为这个画布项准备画布（这里是 1x），然后回调调用方作画。
        let context = makeCanvas(for: item.canvasRect, scale: 1)
        source.drawOverlayItem(item, in: context, at: time)

        // 画布 80×80 像素，四周 8 点是外扩留白：基准矩形涂黑，留白保持透明。
        #expect(alpha(of: context, pixelX: 8, pixelY: 8) == 255)     // 基准矩形左上角
        #expect(alpha(of: context, pixelX: 71, pixelY: 71) == 255)   // 基准矩形右下角
        #expect(alpha(of: context, pixelX: 4, pixelY: 40) == 0)      // 左侧留白
        #expect(alpha(of: context, pixelX: 40, pixelY: 76) == 0)     // 下方留白
    }

    @MainActor
    @Test func 第9节_读取和观察暂停开关() {
        let pause = PauseSwitch()   // 应用里各模块用 PauseSwitch.shared

        // 读：任何线程，随时。
        #expect(!pause.isPaused)

        // 观察：回调在主线程。
        var log: [String] = []
        let observation = pause.addObserver { paused in
            log.append(paused ? "停下" : "继续")
        }
        pause.setPaused(true)    // 只有应用外壳（菜单）会写
        pause.setPaused(false)
        observation.cancel()
        #expect(log == ["停下", "继续"])
    }

    @Test func 第10节_省电信号与可复现的随机数() {
        // 应用把各模块的需求合成一个，交给叠加层。
        let fromSensor = FrameDemand.by(time.monotonic + 0.1)     // 鼠标没动：0.1 秒后再读一次
        let fromDirector = FrameDemand.by(time.monotonic + 2.5)   // 2.5 秒后有人要眨眼
        #expect(fromSensor.merged(with: fromDirector) == .by(100.1))
        #expect(fromSensor.merged(with: .continuous) == .continuous)

        // 随机数：种子由外部传入，同样的种子永远得到同样的结果。
        var rng = SeededRandom(seed: 42)
        let nextBlinkIn = Double.random(in: 2...6, using: &rng)
        var again = SeededRandom(seed: 42)
        #expect(nextBlinkIn == Double.random(in: 2...6, using: &again))

        // 由长相种子派生互不相关的"子种子"：第 0 路定眼距，第 1 路定性格。
        let seed = IconID(rawValue: 7).faceSeed
        #expect(SeededRandom.derive(seed, stream: 0) != SeededRandom.derive(seed, stream: 1))
    }
}
