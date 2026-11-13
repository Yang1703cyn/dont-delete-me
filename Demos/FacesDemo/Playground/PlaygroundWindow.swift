// FacesDemo · 试玩窗口
//
//   swift run FacesDemo --play                一直开着，关窗即退出
//   swift run FacesDemo --play --seconds 5    开 5 秒后自己退出
//
// 一个普通窗口（可以正常关闭、最小化、调整大小；不置顶、不全屏、不点击穿透）。
// 左边是舞台：几排带脸的系统图标，眼睛跟着窗口里的鼠标动。右边是控制面板。

import AppKit
import CoreGraphics
import DDMCore
import Faces
import Foundation

/// 舞台的画布。
@MainActor
final class StageView: NSView {
    let stage: Stage
    private let renderer = FaceRenderer()
    /// 画面用的时间。平时是系统的单调时钟；出窗口快照时固定成一个值。
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// 最近一帧：画了几张脸、画脸总共花了多久（秒）。
    private(set) var lastFaceCount = 0
    private(set) var lastFaceSeconds: TimeInterval = 0

    init(stage: Stage) {
        self.stage = stage
        super.init(frame: CGRect(origin: .zero, size: stage.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不支持从归档创建") }

    /// y 向下：和叠加层交给表情模块的画布一致。
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) { stage.mouse = convert(event.locationInWindow, from: nil) }
    override func mouseDragged(with event: NSEvent) { stage.mouse = convert(event.locationInWindow, from: nil) }
    override func mouseEntered(with event: NSEvent) { stage.mouse = convert(event.locationInWindow, from: nil) }
    override func mouseExited(with event: NSEvent) { stage.mouse = nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        stage.size = newSize
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let time = clock()
        let frame = stage.frame(at: time)

        context.setFillColor(stage.isDark ? Tint.hex(0x262B4A) : Tint.hex(0xDFE9F3))
        context.fill(bounds)
        drawTrash(in: frame.trash, context: context)

        let pixelsPerPoint = window?.backingScaleFactor ?? 2
        var seconds: TimeInterval = 0
        for placement in frame.placements {
            if placement.iconAlpha > 0.01 {
                context.saveGState()
                context.setAlpha(placement.iconAlpha)
                placement.icon.draw(in: placement.rect, context: context, pixelsPerPoint: pixelsPerPoint)
                context.restoreGState()
            }
            // 和叠加层一样：裁在"图标矩形 + 声明的外扩"里。
            context.saveGState()
            context.clip(to: placement.rect.expanded(by: renderer.outsets(for: placement.state, iconSize: placement.rect.size)))
            let started = ProcessInfo.processInfo.systemUptime
            renderer.draw(placement.state, in: placement.rect, context: context, time: time)
            seconds += ProcessInfo.processInfo.systemUptime - started
            context.restoreGState()
        }
        lastFaceCount = frame.placements.count
        lastFaceSeconds = seconds

        if let cursor = frame.cursor { drawCursor(at: cursor, context: context) }
    }

    /// 废纸篓：一个画出来的桶（不是系统的废纸篓，也不碰它）。
    private func drawTrash(in rect: CGRect, context: CGContext) {
        let body = CGMutablePath()
        let top = rect.minY + rect.height * 0.22
        body.move(to: CGPoint(x: rect.minX + 6, y: top))
        body.addLine(to: CGPoint(x: rect.maxX - 6, y: top))
        body.addLine(to: CGPoint(x: rect.maxX - 14, y: rect.maxY - 6))
        body.addQuadCurve(to: CGPoint(x: rect.maxX - 20, y: rect.maxY), control: CGPoint(x: rect.maxX - 15, y: rect.maxY))
        body.addLine(to: CGPoint(x: rect.minX + 20, y: rect.maxY))
        body.addQuadCurve(to: CGPoint(x: rect.minX + 14, y: rect.maxY - 6), control: CGPoint(x: rect.minX + 15, y: rect.maxY))
        body.closeSubpath()
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.addPath(body)
        context.setFillColor(Tint.hex(0xD5DAE3))
        context.setStrokeColor(Tint.hex(0x4A5163))
        context.setLineWidth(2.5)
        context.drawPath(using: .fillStroke)
        let details = CGMutablePath()
        // 桶沿和提手。
        details.move(to: CGPoint(x: rect.minX, y: top))
        details.addLine(to: CGPoint(x: rect.maxX, y: top))
        details.move(to: CGPoint(x: rect.midX - 10, y: top))
        details.addLine(to: CGPoint(x: rect.midX - 10, y: top - 9))
        details.addLine(to: CGPoint(x: rect.midX + 10, y: top - 9))
        details.addLine(to: CGPoint(x: rect.midX + 10, y: top))
        // 三道竖纹。
        for offset in [CGFloat(-14), 0, 14] {
            details.move(to: CGPoint(x: rect.midX + offset, y: top + 12))
            details.addLine(to: CGPoint(x: rect.midX + offset * 0.8, y: rect.maxY - 12))
        }
        context.addPath(details)
        context.strokePath()
    }

    /// 连续演示里的假指针。
    private func drawCursor(at point: CGPoint, context: CGContext) {
        let arrow = CGMutablePath()
        arrow.move(to: point)
        arrow.addLine(to: CGPoint(x: point.x, y: point.y + 17))
        arrow.addLine(to: CGPoint(x: point.x + 4.5, y: point.y + 13))
        arrow.addLine(to: CGPoint(x: point.x + 8, y: point.y + 20))
        arrow.addLine(to: CGPoint(x: point.x + 10.5, y: point.y + 18.8))
        arrow.addLine(to: CGPoint(x: point.x + 7.2, y: point.y + 12))
        arrow.addLine(to: CGPoint(x: point.x + 12.5, y: point.y + 12))
        arrow.closeSubpath()
        context.addPath(arrow)
        context.setFillColor(Tint.hex(0x111111))
        context.setStrokeColor(Tint.white)
        context.setLineWidth(1.5)
        context.setLineJoin(.round)
        context.drawPath(using: .fillStroke)
    }
}

/// 试玩窗口：舞台 + 控制面板。
@MainActor
final class PlaygroundController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let stage = Stage()
    let stageView: StageView
    let window: NSWindow
    private var timer: Timer?
    private var modeButtons: [NSButton] = []
    private let intensitySlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let peekSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let sizeSlider = NSSlider(value: 64, minValue: 32, maxValue: 128, target: nil, action: nil)
    private let intensityLabel = NSTextField(labelWithString: "")
    private let peekLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let playButton = NSButton(title: "▶ 播放：拖向废纸篓 → 大哭 → 幽灵", target: nil, action: nil)
    private let followBox = NSButton(checkboxWithTitle: "眼睛跟着鼠标", target: nil, action: nil)
    private let wallpaperControl = NSSegmentedControl(
        labels: ["浅色墙纸", "深色墙纸"], trackingMode: .selectOne, target: nil, action: nil
    )
    private var frameCount = 0
    private var averageFaceSeconds: TimeInterval = 0

    /// "自动" + 8 种表情，对应 9 个按钮。
    private let modes: [(title: String, mode: Stage.Mode)] =
        [("自动", .live)] + ExpressionPreset.allCases.map { ($0.title, Stage.Mode.preset($0)) }

    override init() {
        stageView = StageView(stage: stage)
        window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        super.init()
        window.title = "别删我 · 表情试玩"
        window.minSize = CGSize(width: 820, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        buildContent()
        refreshControls()
    }

    // MARK: - 界面

    private func buildContent() {
        let panel = NSStackView()
        panel.orientation = .vertical
        panel.alignment = .leading
        panel.spacing = 8
        panel.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        panel.addArrangedSubview(heading("表情"))
        // 9 个按钮排成 3 × 3。
        for row in 0..<3 {
            let line = NSStackView()
            line.orientation = .horizontal
            line.distribution = .fillEqually
            line.spacing = 6
            for column in 0..<3 {
                let index = row * 3 + column
                let button = NSButton(title: modes[index].title, target: self, action: #selector(modeChosen(_:)))
                button.setButtonType(.pushOnPushOff)
                button.bezelStyle = .rounded
                button.tag = index
                modeButtons.append(button)
                line.addArrangedSubview(button)
            }
            panel.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: panel.widthAnchor, constant: -32).isActive = true
        }

        panel.addArrangedSubview(spacer(6))
        addSlider(intensitySlider, title: "强度", valueLabel: intensityLabel, to: panel)
        addSlider(peekSlider, title: "偷看（捂眼时指缝张多大）", valueLabel: peekLabel, to: panel)
        addSlider(sizeSlider, title: "图标大小", valueLabel: sizeLabel, to: panel)

        panel.addArrangedSubview(spacer(6))
        followBox.target = self
        followBox.action = #selector(followToggled(_:))
        followBox.state = .on
        panel.addArrangedSubview(followBox)
        wallpaperControl.target = self
        wallpaperControl.action = #selector(wallpaperChosen(_:))
        wallpaperControl.selectedSegment = 0
        panel.addArrangedSubview(wallpaperControl)

        panel.addArrangedSubview(spacer(10))
        playButton.target = self
        playButton.action = #selector(playScript(_:))
        playButton.bezelStyle = .rounded
        panel.addArrangedSubview(playButton)

        panel.addArrangedSubview(spacer(10))
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.preferredMaxLayoutWidth = 250
        panel.addArrangedSubview(statusLabel)
        let hint = NSTextField(wrappingLabelWithString: "把鼠标移到左边的图标之间试试：眼睛会跟着转，停在谁身上谁就害羞。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 250
        panel.addArrangedSubview(hint)

        let content = NSView()
        stageView.translatesAutoresizingMaskIntoConstraints = false
        panel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stageView)
        content.addSubview(panel)
        NSLayoutConstraint.activate([
            stageView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stageView.topAnchor.constraint(equalTo: content.topAnchor),
            stageView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: stageView.trailingAnchor),
            panel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            panel.topAnchor.constraint(equalTo: content.topAnchor),
            panel.widthAnchor.constraint(equalToConstant: 290),
        ])
        window.contentView = content

        for slider in [intensitySlider, peekSlider, sizeSlider] {
            slider.target = self
            slider.action = #selector(sliderMoved(_:))
            slider.isContinuous = true
        }
    }

    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func spacer(_ height: CGFloat) -> NSView {
        let view = NSView()
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    private func addSlider(_ slider: NSSlider, title: String, valueLabel: NSTextField, to panel: NSStackView) {
        let line = NSStackView()
        line.orientation = .horizontal
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 12)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        line.addArrangedSubview(name)
        line.addArrangedSubview(NSView())
        line.addArrangedSubview(valueLabel)
        panel.addArrangedSubview(line)
        panel.addArrangedSubview(slider)
        line.widthAnchor.constraint(equalTo: panel.widthAnchor, constant: -32).isActive = true
        slider.widthAnchor.constraint(equalTo: panel.widthAnchor, constant: -32).isActive = true
    }

    /// 让控件的样子跟上舞台的状态。
    private func refreshControls() {
        for button in modeButtons {
            button.state = modes[button.tag].mode == stage.mode ? .on : .off
        }
        intensityLabel.stringValue = "\(Int((stage.intensity * 100).rounded()))%"
        peekLabel.stringValue = "\(Int((stage.peek * 100).rounded()))%"
        sizeLabel.stringValue = "\(Int(stage.iconSize.rounded())) 点"
        // "自动"玩法里强度滑杆不起作用；偷看只对捂眼有意义。
        intensitySlider.isEnabled = stage.mode != .live
        peekSlider.isEnabled = stage.mode == .preset(.coveringEyes)
        playButton.isEnabled = !stage.isPlayingScript
    }

    // MARK: - 操作

    @objc private func modeChosen(_ sender: NSButton) {
        select(mode: modes[sender.tag].mode)
    }

    /// 切换玩法。
    func select(mode: Stage.Mode) {
        stage.mode = mode
        refreshControls()
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        stage.intensity = intensitySlider.doubleValue
        stage.peek = peekSlider.doubleValue
        stage.iconSize = CGFloat(sizeSlider.doubleValue.rounded())
        refreshControls()
    }

    @objc private func followToggled(_ sender: NSButton) {
        stage.followsMouse = sender.state == .on
    }

    @objc private func wallpaperChosen(_ sender: NSSegmentedControl) {
        stage.isDark = sender.selectedSegment == 1
    }

    @objc private func playScript(_ sender: Any?) {
        stage.startScript(at: stageView.clock())
        refreshControls()
    }

    // MARK: - 运行

    /// 显示窗口并开始逐帧重画。
    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // .common：拖滑杆、调整窗口大小时也照常出帧。
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        stageView.needsDisplay = true
        frameCount += 1
        if stageView.lastFaceCount > 0 {
            let perFace = stageView.lastFaceSeconds / Double(stageView.lastFaceCount)
            averageFaceSeconds += (perFace - averageFaceSeconds) * 0.05
        }
        if frameCount.isMultiple(of: 20) {
            var text = String(format: "本帧画了 %d 张脸，每张约 %.3f 毫秒", stageView.lastFaceCount, averageFaceSeconds * 1000)
            #if DEBUG
            text += "\n（调试版，偏慢；真实耗时请用 swift run -c release）"
            #endif
            statusLabel.stringValue = text
            if playButton.isEnabled == stage.isPlayingScript { refreshControls() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 自检

    /// 自检的一步：等 `delay` 秒（让窗口照常出几帧），然后执行并返回是否符合预期。
    private struct CheckStep: Sendable {
        let name: String
        let delay: TimeInterval
        let run: @MainActor @Sendable () -> Bool
    }

    private var checkSteps: [CheckStep] = []
    private var checkFailures = 0
    private var checkFinished: (@MainActor (Bool) -> Void)?

    /// 窗口自检：依次触发每个按钮、每个滑杆、开关的动作，给画布喂几个鼠标位置，播放一遍连续演示，
    /// 每一步都检查舞台的状态是否跟着变。
    /// 这里只是在进程内直接调用控件的动作和画布的鼠标回调，不向系统发送任何鼠标键盘事件，也不动真实的鼠标指针。
    /// - Parameter finished: 全部做完后回调，参数是"是否全部通过"。
    func runSelfCheck(finished: @escaping @MainActor (Bool) -> Void) {
        func fire(_ control: NSControl) {
            _ = control.sendAction(control.action, to: control.target)
        }
        func mouseEvent(at stagePoint: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(
                with: .mouseMoved, location: stageView.convert(stagePoint, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 0, pressure: 0
            )
        }
        var steps: [CheckStep] = []
        for (index, entry) in modes.enumerated() {
            steps.append(CheckStep(name: "按「\(entry.title)」按钮", delay: 0.12) { [self] in
                modeButtons[index].performClick(nil)
                let onlyThisOn = modeButtons.allSatisfy { ($0.state == .on) == ($0.tag == index) }
                return stage.mode == entry.mode && onlyThisOn
            })
        }
        steps.append(CheckStep(name: "强度滑杆拨到 30%", delay: 0.12) { [self] in
            intensitySlider.doubleValue = 0.3
            fire(intensitySlider)
            return abs(stage.intensity - 0.3) < 1e-9 && intensityLabel.stringValue == "30%"
        })
        steps.append(CheckStep(name: "选「捂眼」后偷看滑杆可用，拨到 80%", delay: 0.12) { [self] in
            select(mode: .preset(.coveringEyes))
            guard peekSlider.isEnabled else { return false }
            peekSlider.doubleValue = 0.8
            fire(peekSlider)
            return abs(stage.peek - 0.8) < 1e-9
        })
        for size in [128.0, 32.0, 64.0] {
            steps.append(CheckStep(name: "图标大小拨到 \(Int(size)) 点", delay: 0.25) { [self] in
                sizeSlider.doubleValue = size
                fire(sizeSlider)
                return stage.iconSize == CGFloat(size) && stageView.lastFaceCount == stage.actors.count
            })
        }
        steps.append(CheckStep(name: "关掉、再打开「眼睛跟着鼠标」", delay: 0.12) { [self] in
            followBox.performClick(nil)
            let off = !stage.followsMouse
            followBox.performClick(nil)
            return off && stage.followsMouse
        })
        steps.append(CheckStep(name: "切到深色墙纸、再切回来", delay: 0.12) { [self] in
            wallpaperControl.selectedSegment = 1
            fire(wallpaperControl)
            let dark = stage.isDark
            wallpaperControl.selectedSegment = 0
            fire(wallpaperControl)
            return dark && !stage.isDark
        })
        steps.append(CheckStep(name: "「自动」玩法里把鼠标位置喂到第 3 个图标上", delay: 0.12) { [self] in
            select(mode: .live)
            guard let event = mouseEvent(at: stage.actors[2].home) else { return false }
            stageView.mouseMoved(with: event)
            guard let mouse = stage.mouse else { return false }
            return mouse.distance(to: stage.actors[2].home) < 0.5
        })
        steps.append(CheckStep(name: "一秒后：被悬停的图标害羞了，别的没有", delay: 1.0) { [self] in
            stage.actors[2].blush > 0.9 && stage.actors[4].blush < 0.05
        })
        steps.append(CheckStep(name: "鼠标离开舞台", delay: 0.12) { [self] in
            guard let event = mouseEvent(at: stage.actors[2].home) else { return false }
            stageView.mouseExited(with: event)
            return stage.mouse == nil
        })
        steps.append(CheckStep(name: "按「播放」：连续演示开始，按钮变灰", delay: 0.5) { [self] in
            playButton.performClick(nil)
            return stage.isPlayingScript && !playButton.isEnabled
        })
        let framesBefore = frameCount
        steps.append(CheckStep(name: "演示播完（约 9 秒）：回到平时的玩法，按钮恢复，期间一直在出帧", delay: Stage.scriptDuration + 0.8) { [self] in
            !stage.isPlayingScript && playButton.isEnabled && frameCount - framesBefore > 200
        })

        checkSteps = steps
        checkFailures = 0
        checkFinished = finished
        runNextCheckStep()
    }

    /// 执行自检的下一步：先等它要求的时间（期间窗口照常出帧），再执行、记结果。
    private func runNextCheckStep() {
        guard !checkSteps.isEmpty else {
            print("[FacesDemo] 窗口自检：\(checkFailures == 0 ? "全部通过" : "\(checkFailures) 步没通过")；共出 \(frameCount) 帧")
            checkFinished?(checkFailures == 0)
            checkFinished = nil
            return
        }
        let step = checkSteps.removeFirst()
        let timer = Timer(timeInterval: step.delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let passed = step.run()
                if !passed { self.checkFailures += 1 }
                print("[FacesDemo]   \(passed ? "✔" : "✘") \(step.name)")
                self.runNextCheckStep()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func windowWillClose(_ notification: Notification) {
        stop()
    }
}

/// 试玩窗口的启动与（可选的）限时退出。
@MainActor
enum Playground {
    /// 打开试玩窗口并进入事件循环；窗口关闭、或到了时限就返回（进程随后退出）。
    /// - Parameters:
    ///   - seconds: 限时（秒）；nil 表示一直开着直到用户关窗。
    ///   - autoplay: 一打开就播放一遍连续演示。
    static func run(seconds: TimeInterval?, autoplay: Bool) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let controller = PlaygroundController()
        app.delegate = controller
        controller.show()
        app.activate(ignoringOtherApps: true)
        if autoplay {
            controller.stage.startScript(at: controller.stageView.clock())
        }
        if let seconds {
            let quit = Timer(timeInterval: seconds, repeats: false) { _ in
                MainActor.assumeIsolated {
                    controller.stop()
                    print("[FacesDemo] 试玩窗口已运行 \(seconds) 秒，共出 \(controller.framesDrawn) 帧，自动退出。")
                    NSApp.terminate(nil)
                }
            }
            RunLoop.main.add(quit, forMode: .common)
        }
        app.run()
    }

    /// 打开试玩窗口跑一遍自检（约 15 秒），然后退出；退出码 0 表示全部通过。
    static func selfCheck() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let controller = PlaygroundController()
        app.delegate = controller
        controller.show()
        controller.runSelfCheck { passed in
            controller.stop()
            // 直接结束进程以带出退出码（NSApp.terminate 的退出码恒为 0）。
            exit(passed ? 0 : 1)
        }
        app.run()
    }

    /// 不显示窗口，把窗口内容画成一张图，写到 docs/样张/试玩窗口.png。
    /// 用来在没人看屏幕的时候检查窗口的排版和各种玩法，也作为说明文档的配图。
    /// - Parameter scriptTime: 连续演示进行到第几秒时的画面；nil 表示"自动"玩法——鼠标停在一个图标上，它正在害羞。
    static func snapshot(scriptTime: TimeInterval?) throws -> URL {
        _ = NSApplication.shared
        let controller = PlaygroundController()
        guard let content = controller.window.contentView else { throw SampleError.cannotCreateCanvas }
        content.layoutSubtreeIfNeeded()
        // 画面固定在某一刻：同样的参数永远得到同一张图。
        let base: TimeInterval = 1000
        if let scriptTime {
            controller.stageView.clock = { base + scriptTime }
            controller.stage.mouse = CGPoint(x: 300, y: 330)
            controller.stage.startScript(at: base)
        } else {
            // 鼠标停在第二排第二个图标上；先空转一秒，让害羞渐入到位。
            controller.stage.mouse = controller.stage.actors[5].home.moved(by: CGVector(dx: 6, dy: 4))
            for step in 0...60 { _ = controller.stage.frame(at: base + Double(step) / 60) }
            controller.stageView.clock = { base + 1 }
        }
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            throw SampleError.cannotCreateCanvas
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw SampleError.cannotWrite("试玩窗口.png")
        }
        let url = try SampleOutput.directory().appendingPathComponent("试玩窗口.png")
        try data.write(to: url)
        return url
    }
}

extension PlaygroundController {
    /// 已经出了多少帧。
    var framesDrawn: Int { frameCount }
}
