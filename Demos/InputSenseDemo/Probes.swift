// InputSenseDemo · 几个给真人验证和取数据用的模式
//
//   --trash-check   废纸篓估算有多准：把鼠标停在废纸篓正中，读出偏差
//   --drag-probe    访达的起拖阈值、拖影是否跟着鼠标走：真人拖一个真实的桌面图标
//   --bench         各种读取要多久
// 都是只读的：不产生任何鼠标键盘事件，不需要授权，不读窗口标题。

import AppKit
import Carbon
import CoreGraphics
import DDMCore
import Foundation
import InputSense

private func summary(_ samples: [Double]) -> String {
    guard !samples.isEmpty else { return "没有数据" }
    let sorted = samples.sorted()
    let mean = samples.reduce(0, +) / Double(samples.count)
    func at(_ fraction: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))] }
    return "平均 \(text(mean * 1000, 4)) 毫秒，中位 \(text(at(0.5) * 1000, 4))，95% \(text(at(0.95) * 1000, 4))，最大 \(text(sorted[sorted.count - 1] * 1000, 4))"
}

/// 连着调用 `count` 次，量每次多久。
private func timed(_ count: Int, _ body: () -> Void) -> [Double] {
    var samples: [Double] = []
    samples.reserveCapacity(count)
    for _ in 0..<count {
        let start = ProcessInfo.processInfo.systemUptime
        body()
        samples.append(ProcessInfo.processInfo.systemUptime - start)
    }
    return samples
}

/// 每隔 `gap` 秒调用一次，量每次多久。应用里各种读取就是这样隔一会儿才来一次的，
/// 比连着调用慢（系统那边的缓存凉了），这才是实际的开销。
@MainActor
private func spaced(_ count: Int, gap: TimeInterval = 0.05, _ body: () -> Void) -> [Double] {
    var samples: [Double] = []
    for _ in 0..<count {
        spin(until: ProcessInfo.processInfo.systemUptime + gap)
        let start = ProcessInfo.processInfo.systemUptime
        body()
        samples.append(ProcessInfo.processInfo.systemUptime - start)
    }
    return samples
}

/// 系统自己的"起拖距离"参数（鼠标按下后移动多远算开始拖）。
private func systemDragThreshold() -> CGSize? {
    var time: EventTime = 0
    var distance = HISize()
    guard HIMouseTrackingGetParameters(OSType(kMouseParamsDragInitiation), &time, &distance) == noErr else { return nil }
    return CGSize(width: distance.width, height: distance.height)
}

@MainActor
private func liveEnvironment() -> LiveEnvironment {
    var options = LiveEnvironment.Options()
    options.remembersTrashLocation = false
    return LiveEnvironment(options: options)
}

// MARK: - 废纸篓估算

@MainActor
func runTrashCheck(seconds: Double, show: Bool) {
    let environment = liveEnvironment()
    let sensor = InteractionSensor(environment: environment)
    let marker = show ? MarkerWindows() : nil
    let snapshot = IconSnapshot.empty(status: .ok)

    say("废纸篓估算核对 \(text(seconds, 0)) 秒。请把鼠标停在程序坞里废纸篓图标的正中间，看\u{201C}鼠标相对估算中心\u{201D}这一项。")
    if show { say("已加 --show：红框是估算的废纸篓区域，黄框是量到的程序坞那一条。") }

    let began = ProcessInfo.processInfo.systemUptime
    var lastPrintedAt = began - 1
    var facts = InteractionFacts(time: FrameTime.now())
    while ProcessInfo.processInfo.systemUptime - began < seconds {
        let time = FrameTime.now()
        facts = sensor.update(time: time, icons: .unchanged(snapshot))
        marker?.show(icons: [], dragged: nil, trash: facts.trash?.estimatedRect, dockBar: environment.diagnostics.measuredDockBar)
        if time.monotonic - lastPrintedAt >= 1 {
            lastPrintedAt = time.monotonic
            if let trash = facts.trash {
                let offset = facts.mouse.position.offset(from: trash.estimatedRect.center)
                let basis = environment.diagnostics.measuredDockBar != nil ? "量到了程序坞" : "只靠公式"
                say(String(format: "[%5.1fs] 估算 %@ 可信度 %.2f（%@） | 鼠标 %@，相对估算中心 (%+.0f, %+.0f)，%@",
                           time.monotonic - began, text(trash.estimatedRect), trash.confidence, basis,
                           text(facts.mouse.position), offset.dx, offset.dy, trash.isOver ? "在估算区域内" : "不在估算区域内"))
            } else {
                say(String(format: "[%5.1fs] 估算不出来", time.monotonic - began))
            }
        }
        spin(until: time.monotonic + 1.0 / 30)
    }
    marker?.close()
    say("")
    describeDock(environment.diagnostics, estimate: facts.trash)
}

// MARK: - 拖拽探针

@MainActor
func runDragProbe(seconds: Double) {
    let environment = liveEnvironment()
    let draggingLevel = Int(CGWindowLevelForKey(.draggingWindow))
    let ownPID = ProcessInfo.processInfo.processIdentifier

    /// 当前在屏的系统拖影窗口（层级为"拖影"、不是本进程的）的外接矩形。
    func dragImageBounds() -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[CFString: Any]] else { return nil }
        var union: CGRect?
        for entry in list {
            guard (entry[kCGWindowLayer] as? Int) == draggingLevel,
                  (entry[kCGWindowOwnerPID] as? Int32) != ownPID,
                  let boundsInfo = entry[kCGWindowBounds] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary)
            else { continue }
            union = union?.union(bounds) ?? bounds
        }
        return union
    }

    say("拖拽探针 \(text(seconds, 0)) 秒。请用鼠标拖动一个真实的桌面图标：按住、慢慢拖出去一段、再拖回原处松手。可以多拖几次。")
    if let threshold = systemDragThreshold() {
        say("系统的起拖距离参数：\(text(Double(threshold.width), 0))×\(text(Double(threshold.height), 0)) 点（交互感知用的阈值是 4 点）。")
    }

    struct Press {
        var point: CGPoint
        var time: TimeInterval
        var lastMoveBeforeImage: CGFloat = 0
        var imageSeen = false
        var offsetMin = CGVector(dx: CGFloat.infinity, dy: CGFloat.infinity)
        var offsetMax = CGVector(dx: -CGFloat.infinity, dy: -CGFloat.infinity)
        var farthest: CGFloat = 0
    }
    var press: Press?
    var wasDown = false
    var count = 0
    let began = ProcessInfo.processInfo.systemUptime

    while ProcessInfo.processInfo.systemUptime - began < seconds {
        let sample = environment.readPointer()
        let now = ProcessInfo.processInfo.systemUptime
        let isDown = sample.buttons.contains(.left)

        if isDown, !wasDown {
            count += 1
            press = Press(point: sample.position, time: now)
            say("第 \(count) 次按下：\(text(sample.position))，最上面是：\(surfaceName(environment.rawSurface(at: sample.position)))")
        }
        if isDown, var current = press {
            let moved = sample.position.offset(from: current.point)
            let box = max(abs(moved.dx), abs(moved.dy))
            current.farthest = max(current.farthest, moved.length)
            if let image = dragImageBounds() {
                let offset = image.origin.offset(from: sample.position)
                if !current.imageSeen {
                    current.imageSeen = true
                    say("  系统拖影出现：按下后 \(text(now - current.time, 3)) 秒；这时鼠标已移动 \(text(moved))（横竖取大 \(text(Double(box), 1)) 点，直线 \(text(Double(moved.length), 1)) 点），"
                        + "上一次读数时是 \(text(Double(current.lastMoveBeforeImage), 1)) 点 → 访达的起拖阈值在这两个数之间")
                    say("  拖影窗口 \(text(image))，左上角相对鼠标 \(text(offset))，相对按下点 \(text(image.origin.offset(from: current.point)))")
                }
                current.offsetMin = CGVector(dx: min(current.offsetMin.dx, offset.dx), dy: min(current.offsetMin.dy, offset.dy))
                current.offsetMax = CGVector(dx: max(current.offsetMax.dx, offset.dx), dy: max(current.offsetMax.dy, offset.dy))
            } else if !current.imageSeen {
                current.lastMoveBeforeImage = box
            }
            press = current
        }
        if !isDown, wasDown, let finished = press {
            if finished.imageSeen {
                say("  松手：最远移动了 \(text(Double(finished.farthest), 0)) 点；整个过程中拖影左上角相对鼠标的偏移，横向在 \(text(Double(finished.offsetMin.dx), 1))…\(text(Double(finished.offsetMax.dx), 1)) 之间，"
                    + "纵向在 \(text(Double(finished.offsetMin.dy), 1))…\(text(Double(finished.offsetMax.dy), 1)) 之间（变化不到 2 点 = 拖影跟着鼠标走、偏移不变）")
            } else {
                say("  松手：最远移动了 \(text(Double(finished.farthest), 0)) 点，没有出现系统拖影（这不是一次拖放，或者按下的地方不是图标）")
            }
            press = nil
        }
        wasDown = isDown
        // 每秒约 200 次，只在这个探针里读得这么勤。用"转主循环"的方式等，后台读好的东西才回得来。
        spin(until: ProcessInfo.processInfo.systemUptime + 0.004)
    }
    say("拖拽探针结束：共 \(count) 次按下。")
}

// MARK: - 各种读取要多久

@MainActor
func runBench() {
    let environment = liveEnvironment()
    say("各种读取的耗时（本机实测）。连着 = 一口气调很多次；隔着 = 每隔 50 毫秒调一次，后者才是应用里的实际情形。")

    say("  读一次鼠标（位置、按键、最近按下/松开的时刻）")
    say("    连着：" + summary(timed(5000) { _ = environment.readPointer() }))
    say("    隔着：" + summary(spaced(40) { _ = environment.readPointer() }))

    let mouse = environment.readPointer().position
    let layout = DisplayLayout.current()
    var points: [CGPoint] = []
    for display in layout.displays {
        for column in 1..<8 {
            for row in 1..<8 {
                points.append(CGPoint(x: display.frame.minX + display.frame.width * CGFloat(column) / 8,
                                      y: display.frame.minY + display.frame.height * CGFloat(row) / 8))
            }
        }
    }
    var index = 0
    say("  鼠标处最上面是什么窗口")
    say("    连着（同一点）：" + summary(timed(2000) { _ = environment.rawSurface(at: mouse) }))
    if points.isEmpty { points = [mouse] }   // 一块显示器都没有时也别崩
    say("    连着（各块屏上 \(points.count) 个点轮流）：" + summary(timed(2000) {
        _ = environment.rawSurface(at: points[index % points.count])
        index += 1
    }))
    say("    隔着（同一点）：" + summary(spaced(40) { _ = environment.rawSurface(at: mouse) }))
    var tally: [PointerSurface: Int] = [:]
    for point in points { tally[environment.rawSurface(at: point), default: 0] += 1 }
    say("    这 \(points.count) 个点上最上面是：" + PointerSurface.allCases.compactMap { kind in
        tally[kind].map { "\(surfaceName(kind)) \($0) 个" }
    }.joined(separator: "，"))

    var windowCount = 0
    let listWindows = { windowCount = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [Any])?.count ?? 0 }
    say("  在屏窗口列表（整份）")
    say("    连着：" + summary(timed(300, listWindows)) + "；当前 \(windowCount) 个窗口")
    say("    隔着：" + summary(spaced(40, listWindows)))
    var allCount = 0
    say("  全部窗口列表（含不在屏上的；只在后台线程用）")
    say("    连着：" + summary(timed(30) {
        allCount = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [Any])?.count ?? 0
    }) + "；当前 \(allCount) 个窗口")
    say("  显示器布局")
    say("    连着：" + summary(timed(300) { _ = DisplayLayout.current() }))
    say("    隔着：" + summary(spaced(40) { _ = DisplayLayout.current() }))

    // 废纸篓估算：程序坞的设置在后台读；主线程上只有"量那一条"是当场做的。
    say("  废纸篓估算（主线程上花的时间，每秒 60 次连续问）")
    say("    平时：" + summary(spaced(120, gap: 1.0 / 60) { _ = environment.trashEstimate(at: FrameTime.now(), isDragging: false) }))
    say("    拖拽期间（每半秒量一次程序坞）：" + summary(spaced(120, gap: 1.0 / 60) { _ = environment.trashEstimate(at: FrameTime.now(), isDragging: true) }))

    // 整个 update：30 个假图标，按 60 帧/秒实时跑 3 秒。
    let sensor = InteractionSensor(environment: environment)
    var icons: [DesktopIcon] = []
    for number in 0..<30 {
        let x = 100 + CGFloat(number % 6) * 110
        let y = 100 + CGFloat(number / 6) * 120
        icons.append(DesktopIcon(
            id: IconID(rawValue: UInt64(number + 1)), kind: .file,
            imageRect: CGRect(x: x, y: y, width: 64, height: 64),
            labelRect: CGRect(x: x - 10, y: y + 68, width: 84, height: 30)
        ))
    }
    let snapshot = IconSnapshot(icons: icons, status: .ok, capturedAt: 0, revision: 1)
    var costs: [Double] = []
    let began = ProcessInfo.processInfo.systemUptime
    while ProcessInfo.processInfo.systemUptime - began < 3 {
        let time = FrameTime.now()
        let start = ProcessInfo.processInfo.systemUptime
        _ = sensor.update(time: time, icons: .unchanged(snapshot))
        costs.append(ProcessInfo.processInfo.systemUptime - start)
        spin(until: time.monotonic + 1.0 / 60)
    }
    say("  整个 update（30 个假图标，连续出帧 3 秒，共 \(costs.count) 次，其中查了 \(sensor.surfaceSampleCount) 次窗口）")
    say("    " + summary(costs))
    say("    合计占用 \(text(costs.reduce(0, +) / 3 * 100, 3))% 的一个处理器核心")
    let slow = costs.enumerated().filter { $0.element > 0.0005 }.map { "第 \($0.offset) 次 \(text($0.element * 1000, 2))" }
    say("    超过 0.5 毫秒的有 \(slow.count) 次：\(slow.prefix(12).joined(separator: "，"))")
    if let threshold = systemDragThreshold() {
        say("系统的起拖距离参数：\(text(Double(threshold.width), 0))×\(text(Double(threshold.height), 0)) 点")
    }
    describeDock(environment.diagnostics, estimate: nil)
}
