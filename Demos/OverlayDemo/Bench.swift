// OverlayDemo · 实测
//
//   swift run -c release OverlayDemo --bench           选定方案（真实的 OverlayHost）在各块屏上的处理器占用和帧率
//   swift run -c release OverlayDemo --bench-compare   四种绘制方式的对比
//
// 都用"强制可见"运行：不管桌面此刻看不看得见都照常出帧，这样锁着屏也能测本进程的开销。
// 指针用自动绕圈的虚拟指针，保证 30 张脸每一帧都在变、都要重画（最坏情形）。
// 请用发布版（-c release）测；调试版的数字会偏高。

import AppKit
import CoreGraphics
import DDMCore
import Foundation
import Overlay
import QuartzCore

/// 测量时视线取整得极细：指针一动，每张脸的状态都变、都要重画。
private let fineGazeSteps: CGFloat = 1_048_576

private func stateLabel() -> String {
    let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    let layout = DisplayLayout.current()
    let asleep = !layout.displays.isEmpty && layout.displays.allSatisfy { CGDisplayIsAsleep($0.id.rawValue) != 0 }
    switch (asleep, locked) {
    case (true, _): return "熄屏\(locked ? "（已锁屏）" : "")"
    case (false, true): return "亮屏未解锁"
    case (false, false): return "已解锁"
    }
}

/// 让测量条件接近真实应用。
///
/// 真实应用在作画时窗口是看得见的，主线程是"交互"级别，系统不会给它降速。
/// 而从终端启动、窗口又被锁屏挡着的演示程序，会被系统当成"没人在用"而降速（放到慢的核心上、合并定时器），
/// 量出来的占用会虚高好几倍。这里向系统声明"正在做对延迟敏感的事"，并把主线程设成交互级别。
/// 只影响本进程、只在测量期间，不改任何系统设置。
@MainActor
private func prepareForMeasurement() {
    let activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .latencyCritical], reason: "OverlayDemo 实测"
    )
    Lifecycle.shared.onExit { ProcessInfo.processInfo.endActivity(activity) }
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
}

private func buildLabel() -> String {
    #if DEBUG
    return "调试版（数字偏高，请用 -c release 重测）"
    #else
    return "发布版"
    #endif
}

private func row(_ cells: [String], widths: [Int]) -> String {
    zip(cells, widths).map { cell, width in
        // 汉字占两格宽。
        let visual = cell.unicodeScalars.reduce(0) { $0 + ($1.value > 0x2E80 ? 2 : 1) }
        return cell + String(repeating: " ", count: max(1, width - visual))
    }.joined()
}

// MARK: - 选定方案

/// 测量时每个阶段给帧源的设置。
private struct Workload {
    var name: String
    var mode: DemoMode
    var seconds: TimeInterval
    /// 需求直接给「休息」。
    var rests = false
    /// 重画时什么都不画（只量叠加层自己）。
    var emptyDraw = false
    /// 只挪位置、不重画。
    var moveOnly = false
    /// 只画两只眼睛，不画底色。
    var eyesOnly = false
}

@MainActor
func runBench(_ arguments: Arguments) -> Never {
    prepareForMeasurement()
    let layout = DisplayLayout.current()
    let count = arguments.int("--count", default: 30)
    print("[实测] 选定方案（每张脸一个小图层，只重画变了的）。构建：\(buildLabel())；屏幕状态：\(stateLabel())")
    print("[实测] \(count) 张替身脸；指针为自动绕圈的虚拟指针。处理器占用 100% = 占满一个核心。")
    print("[实测] 「其中画脸」是花在替身脸绘制本身上的处理器时间；总占用减去它，就是叠加层自己的开销。")
    let widths = [18, 34, 9, 10, 9, 11, 14, 12]
    print(row(["场景", "阶段", "帧/秒", "重画/秒", "处理器", "其中画脸", "最长帧间隔", "节拍"], widths: widths))

    var options = OverlayOptions()
    options.assumesAlwaysVisible = true

    func measure(_ scene: String, only: DisplayID?, workloads: [Workload]) {
        let icons = FakeDesktop.icons(count: count, on: layout, only: only)
        let source = DemoSource(icons: icons, layout: layout)
        source.pointerSource = .synthetic
        source.gazeSteps = fineGazeSteps
        let host = OverlayHost(pause: PauseSwitch(), options: options)
        host.frameSource = source
        Lifecycle.shared.onExit { host.stop() }
        host.start()
        spin(0.4)
        for workload in workloads {
            guard !Lifecycle.shared.shouldQuit else { break }
            source.mode = workload.mode
            source.restsCompletely = workload.rests
            source.drawsNothing = workload.emptyDraw
            source.movesInsteadOfRedrawing = workload.moveOnly
            source.eyesOnly = workload.eyesOnly
            host.requestFrame()
            spin(0.3)                 // 让切换阶段引起的那一轮重画过去
            source.resetCounters()
            let meter = CPUMeter()
            let started = uptime()
            spin(workload.seconds)
            let elapsed = uptime() - started
            print(row([
                scene, workload.name,
                format(Double(source.frames) / elapsed),
                format(Double(source.draws) / elapsed, 0),
                format(meter.percent) + "%",
                format(source.drawSeconds / elapsed * 100) + "%",
                format(source.maxFrameGap * 1000) + " 毫秒",
                host.diagnostics.clockSource,
            ], widths: widths))
        }
        host.stop()
        spin(0.2)
    }

    for display in layout.displays {
        measure("屏 \(display.id.rawValue) @\(Int(display.scale))x", only: display.id, workloads: [
            Workload(name: "完全空闲（休息）", mode: .idle, seconds: 2, rests: true),
            Workload(name: "空闲（每秒醒 10 次 + 眨眼）", mode: .idle, seconds: 3),
            Workload(name: "\(count) 张全员跟随·每帧全部重画", mode: .follow, seconds: 4),
            Workload(name: "同上·只画两只眼睛（最轻的替身）", mode: .follow, seconds: 4, eyesOnly: true),
            Workload(name: "同上·但不画内容（纯叠加层开销）", mode: .follow, seconds: 3, emptyDraw: true),
            Workload(name: "\(count) 张每帧只挪位置·不重画", mode: .follow, seconds: 3, moveOnly: true),
        ])
    }
    if layout.displays.count > 1 {
        measure("两块屏各一半", only: nil, workloads: [
            Workload(name: "\(count) 张全员跟随·每帧全部重画", mode: .follow, seconds: 4),
            Workload(name: "模拟拖拽（1 张在拖拽层）", mode: .drag, seconds: 4),
        ])
    }
    print("[实测] 完成。")
    Lifecycle.shared.finish(code: 0)
}

// MARK: - 绘制方式对比

/// 对比用的窗口：与叠加层的窗口同样透明、点击穿透、不抢焦点、同样的层级。
@MainActor
private final class BenchWindow: NSWindow {
    init(display: DisplayInfo, layout: DisplayLayout) {
        super.init(
            contentRect: layout.appKitRect(fromGlobal: display.frame), styleMask: [.borderless],
            backing: .buffered, defer: true
        )
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 一张对比用的脸。
private struct BenchFace {
    var icon: FakeIcon
    var face: StandInFace
    var canvas: CGRect { icon.rect.expanded(by: FakeDesktop.outsets) }
}

/// 方式一、二：整窗一张画布。`dirtyOnly` 为 false 时每帧整窗重画；为 true 时只把变了的脸所在的矩形标脏。
private final class WholeWindowView: NSView {
    var faces: [BenchFace] = []
    var display: DisplayInfo?
    var time: TimeInterval = 0
    private(set) var faceDraws = 0

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let display else { return }
        context.saveGState()
        // 视图坐标（y 向下）→ 全局坐标。
        context.translateBy(x: -display.frame.minX, y: -display.frame.minY)
        for face in faces where needsToDraw(display.localRect(fromGlobal: face.canvas)) {
            context.saveGState()
            context.clip(to: face.canvas)
            face.face.draw(in: face.icon.rect, context: context, time: time)
            context.restoreGState()
            faceDraws += 1
        }
        context.restoreGState()
    }
}

/// 方式三：每张脸一个图层，由系统管理它的位图，在提交时回调我们画。
private final class DelegateFaceLayer: CALayer {
    var face: BenchFace?
    var time: TimeInterval = 0
    nonisolated(unsafe) static var draws = 0

    override func draw(in context: CGContext) {
        guard let face else { return }
        // 图层坐标（y 向上）→ 全局坐标（y 向下）。
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -face.canvas.minX, y: -face.canvas.minY)
        face.face.draw(in: face.icon.rect, context: context, time: time)
        Self.draws += 1
    }
}

/// 对比用的节拍：显示刷新回调（封顶每秒 60 次）；屏睡着收不到回调时改用定时器。
@MainActor
private final class BenchTicker: NSObject {
    var onTick: (() -> Void)?
    private(set) var ticks = 0
    private(set) var usesTimer = false
    private var link: CADisplayLink?
    private var timer: Timer?

    func start(on display: DisplayInfo) {
        if let screen = display.screen {
            let link = screen.displayLink(target: self, selector: #selector(fired))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 48, maximum: 72, preferred: 60)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        spin(0.3)
        if ticks == 0 {
            link?.invalidate()
            link = nil
            usesTimer = true
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.fired() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    func stop() {
        link?.invalidate()
        timer?.invalidate()
        link = nil
        timer = nil
    }

    @objc private func fired() {
        ticks += 1
        onTick?()
    }
}

@MainActor
func runBenchCompare(_ arguments: Arguments) -> Never {
    prepareForMeasurement()
    let layout = DisplayLayout.current()
    let count = arguments.int("--count", default: 30)
    let seconds = min(arguments.seconds("--seconds", default: 4), 5)
    print("[对比] 四种绘制方式，各 \(count) 张脸全员跟随 \(format(seconds, 0)) 秒。构建：\(buildLabel())；屏幕状态：\(stateLabel())")
    let widths = [16, 40, 10, 12, 16, 10]
    print(row(["屏", "绘制方式", "帧/秒", "处理器", "每帧耗处理器", "节拍"], widths: widths))

    func report(_ display: DisplayInfo, _ name: String, frames: Int, elapsed: TimeInterval, cpu: Double, ticker: String) {
        let rate = Double(frames) / elapsed
        print(row([
            "屏 \(display.id.rawValue) @\(Int(display.scale))x", name, format(rate), format(cpu) + "%",
            rate > 0 ? format(cpu * 10 / rate, 2) + " 毫秒" : "—", ticker,
        ], widths: widths))
    }

    for display in layout.displays {
        guard !Lifecycle.shared.shouldQuit else { break }
        let icons = FakeDesktop.icons(count: count, on: layout, only: display.id)
        let bounds = layout.bounds
        func pointer(_ elapsed: TimeInterval) -> CGPoint {
            CGPoint(
                x: bounds.midX + bounds.width * 0.42 * CGFloat(sin(elapsed * 1.3)),
                y: bounds.midY + bounds.height * 0.38 * CGFloat(sin(elapsed * 2.1))
            )
        }
        func faces(at elapsed: TimeInterval) -> [BenchFace] {
            let target = pointer(elapsed)
            return icons.map {
                let gaze = StandInFace.gaze(from: $0.rect.center, toward: target, steps: fineGazeSteps)
                return BenchFace(icon: $0, face: StandInFace(gaze: gaze, hue: $0.hue))
            }
        }

        // 方式一、二：整窗一张画布。
        for dirtyOnly in [false, true] {
            let window = BenchWindow(display: display, layout: layout)
            let view = WholeWindowView(frame: CGRect(origin: .zero, size: display.frame.size))
            view.wantsLayer = true
            view.layerContentsRedrawPolicy = .onSetNeedsDisplay
            view.display = display
            window.contentView = view
            window.orderFrontRegardless()
            Lifecycle.shared.onExit { window.close() }

            let ticker = BenchTicker()
            let started = uptime()
            ticker.onTick = {
                let elapsed = uptime() - started
                let next = faces(at: elapsed)
                view.time = elapsed
                if dirtyOnly {
                    for (index, face) in next.enumerated() where index >= view.faces.count || view.faces[index].face != face.face {
                        view.setNeedsDisplay(display.localRect(fromGlobal: face.canvas))
                    }
                } else {
                    view.needsDisplay = true
                }
                view.faces = next
            }
            ticker.start(on: display)
            let before = ticker.ticks
            let meter = CPUMeter()
            let measureStart = uptime()
            spin(seconds)
            report(
                display, dirtyOnly ? "二、整窗画布，只重画变了的矩形" : "一、整窗画布，每帧整窗重画",
                frames: ticker.ticks - before, elapsed: uptime() - measureStart, cpu: meter.percent,
                ticker: ticker.usesTimer ? "timer" : "displayRefresh"
            )
            ticker.stop()
            window.orderOut(nil)
            window.close()
            spin(0.2)
        }

        // 方式三：每张脸一个图层，系统管位图、回调我们画。
        do {
            let window = BenchWindow(display: display, layout: layout)
            let root = CALayer()
            let view = NSView(frame: CGRect(origin: .zero, size: display.frame.size))
            view.layer = root
            view.wantsLayer = true
            window.contentView = view
            let layers: [DelegateFaceLayer] = icons.map { icon in
                let layer = DelegateFaceLayer()
                let canvas = display.localRect(fromGlobal: icon.rect.expanded(by: FakeDesktop.outsets))
                layer.frame = CGRect(x: canvas.minX, y: display.frame.height - canvas.maxY, width: canvas.width, height: canvas.height)
                layer.contentsScale = display.scale
                layer.actions = ["contents": NSNull()]
                root.addSublayer(layer)
                return layer
            }
            window.orderFrontRegardless()
            Lifecycle.shared.onExit { window.close() }

            let ticker = BenchTicker()
            let started = uptime()
            ticker.onTick = {
                let elapsed = uptime() - started
                for (layer, face) in zip(layers, faces(at: elapsed)) where layer.face?.face != face.face {
                    layer.face = face
                    layer.time = elapsed
                    layer.setNeedsDisplay()
                }
            }
            ticker.start(on: display)
            let before = ticker.ticks
            let meter = CPUMeter()
            let measureStart = uptime()
            spin(seconds)
            report(
                display, "三、每张脸一个图层，系统管位图",
                frames: ticker.ticks - before, elapsed: uptime() - measureStart, cpu: meter.percent,
                ticker: ticker.usesTimer ? "timer" : "displayRefresh"
            )
            ticker.stop()
            window.orderOut(nil)
            window.close()
            spin(0.2)
        }

        // 方式四：选定方案——真实的 OverlayHost（每张脸一个图层，自己画位图再贴上去）。
        do {
            var options = OverlayOptions()
            options.assumesAlwaysVisible = true
            let source = DemoSource(icons: icons, layout: layout)
            source.pointerSource = .synthetic
            source.gazeSteps = fineGazeSteps
            source.mode = .follow
            let host = OverlayHost(pause: PauseSwitch(), options: options)
            host.frameSource = source
            Lifecycle.shared.onExit { host.stop() }
            host.start()
            spin(0.6)
            source.resetCounters()
            let meter = CPUMeter()
            let measureStart = uptime()
            spin(seconds)
            report(
                display, "四、每张脸一个图层，自己画位图（选定）",
                frames: source.frames, elapsed: uptime() - measureStart, cpu: meter.percent,
                ticker: host.diagnostics.clockSource
            )
            host.stop()
            spin(0.2)
        }
    }
    print("[对比] 「每帧耗处理器」= 处理器占用 ÷ 帧率，便于在帧率不同的行之间比较。")
    print("[对比] 完成。")
    Lifecycle.shared.finish(code: 0)
}
