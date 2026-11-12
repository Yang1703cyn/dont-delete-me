// OverlayDemo · 演示用的帧回调接收方
//
// 扮演"应用入口"的角色：每帧给出画布项清单和省电信号，被要求重画时画替身脸。
// 三种模式：空闲 / 全员跟随 / 模拟拖拽。

import AppKit
import CoreGraphics
import DDMCore
import Foundation

enum DemoMode: String, CaseIterable {
    /// 空闲：平视前方，偶尔眨眼；像真实应用那样每秒醒 10 次（读鼠标）。
    case idle
    /// 全员跟随：所有的脸盯着指针。
    case follow
    /// 模拟拖拽：一张脸被"拎起来"，画在拖拽层上跟着指针走，边走边哭；其余的脸看着它。
    case drag

    var title: String {
        switch self {
        case .idle: return "空闲"
        case .follow: return "全员跟随"
        case .drag: return "模拟拖拽"
        }
    }
}

/// 指针从哪来。
enum PointerSource: String {
    /// 真实的鼠标位置。
    case mouse
    /// 自动绕圈的虚拟指针（没人动鼠标时也有东西可看；测量时保证每一帧都在动）。
    case synthetic
    /// 鼠标在动就用鼠标，停了 1.5 秒以上就换成虚拟指针。
    case auto
}

@MainActor
final class DemoSource: OverlayFrameSource {
    var mode: DemoMode = .idle
    var pointerSource: PointerSource = .auto
    /// 测量用：空闲模式下连"每秒醒 10 次"也不要，需求直接给「休息」。
    var restsCompletely = false
    /// 视线取整的细度（见 `StandInFace.gaze`）。测量时调得很细，保证指针一动每张脸都要重画。
    var gazeSteps: CGFloat = 64
    /// 测量用：只画两只眼睛，不画底色（最轻的替身）。
    var eyesOnly = false
    /// 测量用：被要求重画时什么都不画——量出来的就是叠加层自己的开销（建画布、取图、贴图层）。
    var drawsNothing = false
    /// 测量用：全员跟随时不改表情，只让每个图标的位置每帧挪一点——量"只移动不重画"的开销。
    var movesInsteadOfRedrawing = false

    private(set) var icons: [FakeIcon]
    private let layout: DisplayLayout

    /// 计数与计时，给测量用。
    private(set) var frames = 0
    private(set) var draws = 0
    private(set) var maxFrameGap: TimeInterval = 0
    /// 花在"画脸"上的时间（秒），不含叠加层自己的开销。
    private(set) var drawSeconds: TimeInterval = 0
    private(set) var timeRuleViolations = 0
    private var lastFrameAt: TimeInterval?

    private var faces: [IconID: StandInFace] = [:]
    private var versions: [IconID: UInt64] = [:]
    private var nextBlink: [IconID: TimeInterval] = [:]
    private var blinkUntil: [IconID: TimeInterval] = [:]
    private var random = SeededRandom(seed: 20261113)
    private var lastMouse = CGPoint.zero
    private var mouseMovedAt: TimeInterval = -100
    private var modeStartedAt: TimeInterval?
    private var lastMode: DemoMode?

    init(icons: [FakeIcon], layout: DisplayLayout) {
        self.icons = icons
        self.layout = layout
    }

    func resetCounters() {
        frames = 0
        draws = 0
        maxFrameGap = 0
        drawSeconds = 0
        lastFrameAt = nil
    }

    // MARK: - OverlayFrameSource

    func overlayFrame(at time: FrameTime) -> OverlayFrame {
        let now = time.monotonic
        frames += 1
        if let last = lastFrameAt { maxFrameGap = max(maxFrameGap, now - last) }
        lastFrameAt = now
        // 约定：帧时间不得超前于此刻的系统时钟。
        if now > ProcessInfo.processInfo.systemUptime + 0.0005 { timeRuleViolations += 1 }

        if mode != lastMode {
            lastMode = mode
            modeStartedAt = now
        }
        let elapsed = now - (modeStartedAt ?? now)
        let (pointer, pointerIsMoving) = currentPointer(now: now, elapsed: elapsed)

        var items: [OverlayItem] = []
        items.reserveCapacity(icons.count)
        var demand: FrameDemand

        switch mode {
        case .idle:
            // 像真实应用的"鼠标停住"状态：没有动画，每 0.1 秒醒一次读鼠标；谁该眨眼了就重画谁。
            demand = .by(now + 0.1)
            if restsCompletely {
                demand = .idle
                for icon in icons {
                    items.append(item(for: icon, face: StandInFace(hue: icon.hue), layer: .desktop, rect: icon.rect))
                }
                break
            }
            for icon in icons {
                var face = StandInFace(hue: icon.hue)
                let due = nextBlink[icon.id] ?? schedule(blinkFor: icon.id, after: now)
                if now >= due {
                    blinkUntil[icon.id] = now + 0.12
                    schedule(blinkFor: icon.id, after: now)
                }
                if let until = blinkUntil[icon.id] {
                    if now < until {
                        face.isBlinking = true
                        demand = demand.merged(with: .by(until))
                    } else {
                        blinkUntil[icon.id] = nil
                    }
                }
                items.append(item(for: icon, face: face, layer: .desktop, rect: icon.rect))
            }

        case .follow:
            demand = pointerIsMoving ? .continuous : .by(now + 0.1)
            for (index, icon) in icons.enumerated() {
                if movesInsteadOfRedrawing {
                    // 表情不变，位置每帧挪一点（整数个点，绕着原位画小圈）。
                    let angle = elapsed * 3 + Double(index)
                    let rect = icon.rect.offsetBy(dx: (cos(angle) * 12).rounded(), dy: (sin(angle) * 12).rounded())
                    items.append(item(for: icon, face: StandInFace(hue: icon.hue), layer: .desktop, rect: rect))
                    continue
                }
                let gaze = StandInFace.gaze(from: icon.rect.center, toward: pointer, steps: gazeSteps)
                let face = StandInFace(gaze: gaze, hue: icon.hue, showsBody: !eyesOnly)
                items.append(item(for: icon, face: face, layer: .desktop, rect: icon.rect))
            }

        case .drag:
            // 第一个假图标被拎起来：它的脸只画在拖拽层上，位置 = 指针 − 抓取偏移。
            demand = .continuous
            guard let victim = icons.first else { break }
            let grabOffset = CGVector(dx: victim.rect.width / 2, dy: victim.rect.height / 2)
            let dragRect = CGRect(
                x: pointer.x - grabOffset.dx, y: pointer.y - grabOffset.dy,
                width: victim.rect.width, height: victim.rect.height
            )
            for icon in icons.dropFirst() {
                let gaze = StandInFace.gaze(from: icon.rect.center, toward: dragRect.center, steps: gazeSteps)
                let face = StandInFace(gaze: gaze, hue: icon.hue)
                items.append(item(for: icon, face: face, layer: .desktop, rect: icon.rect))
            }
            var scared = StandInFace(hue: victim.hue)
            scared.isScared = true
            // 吓哭的脸带循环动画：每帧都换新的内容版本号，让叠加层每帧重画它。
            faces[victim.id] = scared
            versions[victim.id, default: 0] += 1
            items.append(OverlayItem(
                iconID: victim.id, layer: .drag, rect: dragRect,
                outsets: FakeDesktop.outsets, contentVersion: versions[victim.id] ?? 0
            ))
        }

        return OverlayFrame(items: items, demand: demand)
    }

    func drawOverlayItem(_ item: OverlayItem, in context: CGContext, at time: FrameTime) {
        draws += 1
        guard !drawsNothing else { return }
        let started = ProcessInfo.processInfo.systemUptime
        // 画布已经是全局坐标：直接画在 item.rect 上。
        faces[item.iconID]?.draw(in: item.rect, context: context, time: time.monotonic)
        drawSeconds += ProcessInfo.processInfo.systemUptime - started
    }

    // MARK: - 内部

    /// 表情变了才换新的内容版本号——这就是"没变化就不重画"里调用方该做的那一半。
    private func item(for icon: FakeIcon, face: StandInFace, layer: OverlayLayer, rect: CGRect) -> OverlayItem {
        if faces[icon.id] != face {
            faces[icon.id] = face
            versions[icon.id, default: 0] += 1
        }
        return OverlayItem(
            iconID: icon.id, layer: layer, rect: rect,
            outsets: FakeDesktop.outsets, contentVersion: versions[icon.id] ?? 0
        )
    }

    @discardableResult
    private func schedule(blinkFor id: IconID, after now: TimeInterval) -> TimeInterval {
        let due = now + Double.random(in: 2...7, using: &random)
        nextBlink[id] = due
        return due
    }

    /// 这一帧的指针位置（全局坐标），以及它是否在动。
    private func currentPointer(now: TimeInterval, elapsed: TimeInterval) -> (CGPoint, Bool) {
        let mouse = layout.globalPoint(fromAppKit: NSEvent.mouseLocation)
        if mouse.distance(to: lastMouse) > 1 {
            lastMouse = mouse
            mouseMovedAt = now
        }
        let mouseIsMoving = now - mouseMovedAt < 0.3

        let useSynthetic: Bool
        switch pointerSource {
        case .mouse: useSynthetic = false
        case .synthetic: useSynthetic = true
        case .auto: useSynthetic = now - mouseMovedAt > 1.5
        }
        guard useSynthetic else { return (mouse, mouseIsMoving) }
        return (syntheticPointer(elapsed: elapsed), true)
    }

    /// 虚拟指针：在所有屏的范围里画一条 8 字形的线，会穿过屏与屏的接缝。
    /// 拖拽模式下改成"从被拎起的图标出发，走到最远那块屏的右下角（程序坞、废纸篓通常在那一带）再回来"。
    private func syntheticPointer(elapsed: TimeInterval) -> CGPoint {
        let bounds = layout.bounds
        guard !bounds.isNull else { return .zero }
        if mode == .drag, let victim = icons.first {
            let start = victim.rect.center
            let far = layout.displays.max { $0.frame.center.distance(to: start) < $1.frame.center.distance(to: start) }
            let end = CGPoint(x: (far?.frame.maxX ?? bounds.maxX) - 60, y: (far?.frame.maxY ?? bounds.maxY) - 40)
            let progress = 0.5 - 0.5 * cos(elapsed * 2 * .pi / 6)
            return CGPoint(x: start.x + (end.x - start.x) * progress, y: start.y + (end.y - start.y) * progress)
        }
        return CGPoint(
            x: bounds.midX + bounds.width * 0.42 * CGFloat(sin(elapsed * 1.3)),
            y: bounds.midY + bounds.height * 0.38 * CGFloat(sin(elapsed * 2.1))
        )
    }
}
