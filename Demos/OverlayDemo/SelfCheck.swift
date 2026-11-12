// OverlayDemo · 自动自检
//
// 运行：swift run OverlayDemo --self-check
//
// 不需要人操作、不需要屏幕亮着：窗口的属性从系统的窗口列表里核对，画面从窗口的图层树离屏读回。
// 不模拟任何鼠标键盘事件，不读窗口标题，不截屏。
//
// 分两部分：
//   甲、"强制可见"的叠加层——把窗口、坐标、重画规则、拖拽层、暂停、显示器变化逐项过一遍；
//   乙、默认设置的叠加层——如实报告它对当前系统状态（锁屏、全屏空间、图标被隐藏……）的判断。

import AppKit
import CoreGraphics
import DDMCore
import Foundation
import Overlay

/// 自检用的帧回调接收方：清单由外面给；画的时候先用半透明灰铺满整块画布（故意画出界，验证裁剪），
/// 再把图标矩形涂成指定的实色。
@MainActor
final class SolidSource: OverlayFrameSource {
    var items: [OverlayItem] = []
    var demand: FrameDemand = .idle
    /// 每个画布项的颜色（红、绿、蓝）。没指定的是白色。
    var colors: [OverlayItem.Key: (CGFloat, CGFloat, CGFloat)] = [:]

    /// 在帧回调里 / 绘制回调里顺手做的事（用来检查"回调里暂停或停止叠加层"）。只执行一次。
    var duringFrame: (() -> Void)?
    var duringDraw: (() -> Void)?

    private(set) var frames = 0
    private(set) var draws = 0
    private(set) var timeRuleViolations = 0

    func overlayFrame(at time: FrameTime) -> OverlayFrame {
        frames += 1
        if time.monotonic > ProcessInfo.processInfo.systemUptime + 0.0005 { timeRuleViolations += 1 }
        if let action = duringFrame {
            duringFrame = nil
            action()
        }
        return OverlayFrame(items: items, demand: demand)
    }

    func drawOverlayItem(_ item: OverlayItem, in context: CGContext, at time: FrameTime) {
        draws += 1
        if let action = duringDraw {
            duringDraw = nil
            action()
        }
        context.setFillColor(gray: 0.5, alpha: 0.5)
        context.fill(item.rect.insetBy(dx: -400, dy: -400))      // 远远超出画布：应当被裁掉
        let (r, g, b) = colors[item.key] ?? (1, 1, 1)
        context.setFillColor(red: r, green: g, blue: b, alpha: 1)
        context.fill(item.rect)
    }
}

/// 系统窗口列表里的一个窗口（不读标题）。
struct ListedWindow {
    var number: Int
    var pid: Int32
    var layer: Int
    var bounds: CGRect
    /// 在"从前到后"的在屏窗口列表里排第几。
    var order: Int
}

func onScreenWindows() -> [ListedWindow] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[CFString: Any]] ?? []
    return list.enumerated().compactMap { order, info in
        guard let number = info[kCGWindowNumber] as? Int,
              let pid = info[kCGWindowOwnerPID] as? Int32,
              let layer = info[kCGWindowLayer] as? Int,
              let boundsInfo = info[kCGWindowBounds],
              let bounds = CGRect(dictionaryRepresentation: boundsInfo as! CFDictionary)
        else { return nil }
        return ListedWindow(number: number, pid: pid, layer: layer, bounds: bounds, order: order)
    }
}

/// 可以中途替换的显示器布局。
@MainActor
final class LayoutBox {
    var layout: DisplayLayout

    init(_ layout: DisplayLayout) {
        self.layout = layout
    }
}

@MainActor
final class Checklist {
    private(set) var failures = 0
    private(set) var passes = 0

    func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        let extra = detail()
        if condition {
            passes += 1
            print("  ✔ \(name)\(extra.isEmpty ? "" : "（\(extra)）")")
        } else {
            failures += 1
            print("  ✘ \(name)\(extra.isEmpty ? "" : "（\(extra)）")")
        }
    }

    func note(_ text: String) {
        print("  · \(text)")
    }
}

@MainActor
func runSelfCheck(_ arguments: Arguments) -> Never {
    let list = Checklist()
    let realLayout = DisplayLayout.current()
    let ownPID = ProcessInfo.processInfo.processIdentifier
    let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
    let dragImageLevel = Int(CGWindowLevelForKey(.draggingWindow))
    let finderPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier

    let displayNotes: [String] = realLayout.displays.map { display in
        let size = "\(Int(display.frame.width))×\(Int(display.frame.height)) @\(Int(display.scale))x"
        let origin = "(\(Int(display.frame.minX)), \(Int(display.frame.minY)))"
        return "屏 \(display.id.rawValue) \(size) 位于 \(origin)"
    }
    print("[自检] \(realLayout.displays.count) 块屏：" + displayNotes.joined(separator: "；"))
    guard !realLayout.displays.isEmpty else {
        print("[自检] 没有显示器，无法自检。")
        Lifecycle.shared.finish(code: 1)
    }

    // "鼠标点在这里会落到哪个窗口上"——向系统询问，不产生任何事件。
    // 在每块屏上取一片网格点，叠加层出现前后各问一遍，答案必须一模一样。
    var probePoints: [CGPoint] = []
    for display in realLayout.displays {
        for row in 1...4 {
            for column in 1...5 {
                let x = display.frame.minX + display.frame.width * CGFloat(column) / 6
                let y = display.frame.minY + display.frame.height * CGFloat(row) / 5
                probePoints.append(CGPoint(x: x, y: y))
            }
        }
    }
    func hitTargets() -> [Int] {
        probePoints.map { NSWindow.windowNumber(at: realLayout.appKitPoint(fromGlobal: $0), belowWindowWithWindowNumber: 0) }
    }
    let targetsBefore = hitTargets()
    let frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier

    // ───────── 甲、强制可见的叠加层 ─────────
    print("[自检] 甲、窗口、坐标、重画规则、拖拽层、暂停、显示器变化（强制可见，不受锁屏影响）")

    // 叠加层从这里读"显示器布局"：平时给真实的，第 8 步换成假的来模拟显示器变化。
    let layoutBox = LayoutBox(realLayout)
    var options = OverlayOptions()
    options.assumesAlwaysVisible = true
    let pause = PauseSwitch()
    let host = OverlayHost(pause: pause, options: options, layoutProvider: { layoutBox.layout })
    let source = SolidSource()
    host.frameSource = source
    Lifecycle.shared.onExit { host.stop() }

    // 每块屏一个假图标；有接缝的话再加一个骑在接缝上的；再加一个位置带小数的。
    let outsets = EdgeOutsets(all: 8)
    var items: [OverlayItem] = []
    for (index, display) in realLayout.displays.enumerated() {
        items.append(OverlayItem(
            iconID: IconID(rawValue: UInt64(index + 1)),
            rect: CGRect(x: display.frame.minX + 100, y: display.frame.minY + 200, width: 64, height: 64),
            outsets: outsets, contentVersion: 1
        ))
    }
    let seam = FakeDesktop.seamPoint(in: realLayout)
    if let seam {
        items.append(OverlayItem(
            iconID: IconID(rawValue: 90), rect: CGRect(x: seam.x - 32, y: seam.y - 32, width: 64, height: 64),
            outsets: outsets, contentVersion: 1
        ))
    }
    let primary = realLayout.displays[0]
    let fractional = OverlayItem(
        iconID: IconID(rawValue: 91),
        rect: CGRect(x: primary.frame.minX + 300.5, y: primary.frame.minY + 200.5, width: 64, height: 64),
        outsets: outsets, contentVersion: 1
    )
    items.append(fractional)
    source.items = items

    func pixel(_ point: CGPoint, _ layer: OverlayLayer = .desktop) -> OverlayDebugPixel {
        host.debugRenderedPixel(at: point, layer: layer) ?? OverlayDebugPixel(red: 0, green: 0, blue: 0, alpha: -1)
    }
    func near(_ value: Double, _ target: Double) -> Bool { abs(value - target) < 0.02 }
    /// 出一帧并等它落到图层上。
    func settle(_ seconds: TimeInterval = 0.15) {
        host.requestFrame()
        spin(seconds)
    }

    host.start()
    settle(0.4)
    var diagnostics = host.diagnostics

    // 1. 窗口
    print("[自检] 1. 桌面层窗口")
    list.check("每块屏恰好一个桌面层窗口", diagnostics.displays.allSatisfy { $0.desktopWindowCount == 1 && $0.hasWindowOnActiveSpace })
    var windows = onScreenWindows()
    for display in diagnostics.displays {
        let listed = display.desktopWindowNumbers.compactMap { number in windows.first { $0.number == number } }
        let finderIconOnScreen = windows.contains { $0.pid == finderPID && $0.layer == iconLevel && $0.bounds.intersects(display.frame) }
        guard let window = listed.first else {
            if finderIconOnScreen {
                list.check("屏 \(display.id.rawValue) 的桌面层窗口在系统的在屏窗口列表里", false)
            } else {
                // 这块屏停在全屏应用的空间：系统不让桌面层窗口出现在全屏空间里，把它放到了这块屏的某个桌面空间。
                // （默认设置下叠加层根本不会在这种时候建窗；这里是"强制可见"才建的。）
                list.note("屏 \(display.id.rawValue)：这块屏此刻停在全屏应用的空间，强制建出的桌面层窗口不在屏上（符合预期：全屏空间不显示）")
            }
            continue
        }
        list.check(
            "屏 \(display.id.rawValue)：层级 = 桌面图标层 +1，大小位置与屏幕严丝合缝",
            window.layer == iconLevel + 1 && window.bounds == display.frame,
            "层级 \(window.layer)（图标层 \(iconLevel)），边界 \(Int(window.bounds.minX)),\(Int(window.bounds.minY)) \(Int(window.bounds.width))×\(Int(window.bounds.height))"
        )
        let normalBehind = windows.filter { $0.layer >= 0 && $0.order > window.order }
        list.check("屏 \(display.id.rawValue)：排在所有普通窗口（层级 ≥ 0）之后", normalBehind.isEmpty, "反例 \(normalBehind.count) 个")
        let finderIcon = windows.first { $0.pid == finderPID && $0.layer == iconLevel && $0.bounds.intersects(display.frame) }
        if let finderIcon {
            list.check("屏 \(display.id.rawValue)：排在访达图标层窗口之前（压在图标上面）", window.order < finderIcon.order)
        } else {
            list.note("屏 \(display.id.rawValue)：此刻屏上没有访达的图标层窗口（这块屏停在全屏应用的空间），无从比较前后")
        }
    }

    // 2. 点击穿透、不抢焦点
    print("[自检] 2. 点击穿透、不抢焦点")
    func ourWindowNumbers() -> Set<Int> {
        Set(host.diagnostics.displays.flatMap { $0.desktopWindowNumbers + $0.dragWindowNumbers })
    }
    list.check("所有叠加窗口都设了点击穿透", diagnostics.displays.allSatisfy(\.allWindowsIgnoreMouse))
    var targets = hitTargets()
    list.check(
        "\(probePoints.count) 个探测点上，鼠标会落到的窗口与叠加层出现前完全相同",
        targets == targetsBefore && ourWindowNumbers().isDisjoint(with: targets)
    )
    list.check("本程序没有键盘焦点窗口、没有主窗口", application.keyWindow == nil && application.mainWindow == nil)
    list.check(
        "本程序没有变成前台应用，前台应用没变",
        !application.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == frontBefore
    )

    // 3. 坐标
    print("[自检] 3. 坐标换算与清晰度（画面从图层树离屏读回）")
    for (index, display) in realLayout.displays.enumerated() {
        let rect = items[index].rect
        let px = 0.5 / display.scale     // 半个像素
        let inside = pixel(CGPoint(x: rect.minX + px, y: rect.minY + px))
        let outsideRect = pixel(CGPoint(x: rect.minX - px, y: rect.minY - px))
        let lastInside = pixel(CGPoint(x: rect.maxX - px, y: rect.maxY - px))
        let canvasEdge = pixel(CGPoint(x: rect.minX - 8 + px, y: rect.midY))
        let outsideCanvas = pixel(CGPoint(x: rect.minX - 8 - px, y: rect.midY))
        list.check(
            "屏 \(display.id.rawValue)（@\(Int(display.scale))x）：图标矩形的第一个和最后一个像素是实色，紧邻的外侧像素不是",
            near(inside.alpha, 1) && near(lastInside.alpha, 1) && near(outsideRect.alpha, 0.5),
            "内 \(format(inside.alpha, 2))/\(format(lastInside.alpha, 2))，外 \(format(outsideRect.alpha, 2))"
        )
        list.check(
            "屏 \(display.id.rawValue)：画布边缘内侧有内容（半透明底），外侧被裁掉",
            near(canvasEdge.alpha, 0.5) && near(outsideCanvas.alpha, 0),
            "内 \(format(canvasEdge.alpha, 2))，外 \(format(outsideCanvas.alpha, 2))"
        )
    }
    if let seam {
        let left = pixel(CGPoint(x: seam.x - 10, y: seam.y)), right = pixel(CGPoint(x: seam.x + 10, y: seam.y))
        let leftEdge = pixel(CGPoint(x: seam.x - 31.5, y: seam.y)), rightEdge = pixel(CGPoint(x: seam.x + 31.5, y: seam.y))
        list.check(
            "骑在两块屏接缝上的图标：两块屏上各画出自己的那一半",
            near(left.alpha, 1) && near(right.alpha, 1) && near(leftEdge.alpha, 1) && near(rightEdge.alpha, 1),
            "左 \(format(left.alpha, 2))/\(format(leftEdge.alpha, 2))，右 \(format(right.alpha, 2))/\(format(rightEdge.alpha, 2))"
        )
        let counts = host.diagnostics.displays.map(\.desktopItemCount)
        list.note("各屏的画布项数：\(counts)（骑缝的那一项在两块屏上各算一次）")
    } else {
        list.note("没有两块相邻的屏，跳过骑缝检查")
    }
    do {
        // 位置带 0.5 点的矩形：2x 屏上正好落在像素上；1x 屏上边缘那一个像素只盖住一半。
        let rect = fractional.rect
        let edge = pixel(CGPoint(x: rect.minX, y: rect.midY))
        let expected = primary.scale >= 2 ? 1.0 : 0.75
        list.check(
            "位置带 0.5 点的矩形：边缘像素的覆盖率符合这块屏的缩放",
            near(edge.alpha, expected) && near(pixel(CGPoint(x: rect.minX + 2, y: rect.midY)).alpha, 1),
            "读到 \(format(edge.alpha, 2))，应为 \(format(expected, 2))"
        )
    }

    // 4. 没变化就不重画
    print("[自检] 4. 没变化就不重画")
    var draws = source.draws
    settle()
    list.check("清单原样再给一遍：不重画", source.draws == draws, "重画 \(source.draws - draws) 次")

    let movedFrom = items[0].rect
    items[0].rect = movedFrom.offsetBy(dx: 37, dy: 21)
    source.items = items
    draws = source.draws
    settle()
    list.check(
        "只挪位置：不重画，画面跟着走",
        source.draws == draws && near(pixel(items[0].rect.center).alpha, 1)
            && near(pixel(CGPoint(x: movedFrom.minX + 2, y: movedFrom.minY + 2)).alpha, 0),
        "重画 \(source.draws - draws) 次"
    )

    items[0].contentVersion += 1
    source.items = items
    draws = source.draws
    settle()
    list.check("内容版本号变了：只重画这一项", source.draws == draws + 1, "重画 \(source.draws - draws) 次")

    items[0].outsets = EdgeOutsets(top: 8, left: 8, bottom: 30, right: 8)
    source.items = items
    draws = source.draws
    settle()
    list.check(
        "画布外扩变了（版本号没变）：重画，新多出来的一圈里有内容",
        source.draws == draws + 1 && near(pixel(CGPoint(x: items[0].rect.midX, y: items[0].rect.maxY + 20)).alpha, 0.5),
        "重画 \(source.draws - draws) 次"
    )

    // 叠放次序：两项重叠，排在后面的在上面；只调换顺序也要生效。
    let stackRect = CGRect(x: primary.frame.minX + 500, y: primary.frame.minY + 200, width: 64, height: 64)
    let red = OverlayItem(iconID: IconID(rawValue: 92), rect: stackRect, contentVersion: 1)
    let blue = OverlayItem(iconID: IconID(rawValue: 93), rect: stackRect.offsetBy(dx: 20, dy: 0), contentVersion: 1)
    source.colors[red.key] = (1, 0, 0)
    source.colors[blue.key] = (0, 0, 1)
    source.items = items + [red, blue]
    settle()
    let overlap = CGPoint(x: stackRect.minX + 40, y: stackRect.midY)
    let blueOnTop = pixel(overlap)
    source.items = items + [blue, red]
    draws = source.draws
    settle()
    let redOnTop = pixel(overlap)
    list.check(
        "叠放次序 = 清单顺序（后面的在上）；只调换顺序不重画",
        blueOnTop.blue > 0.9 && blueOnTop.red < 0.1 && redOnTop.red > 0.9 && redOnTop.blue < 0.1 && source.draws == draws,
        "蓝在后时读到 红\(format(blueOnTop.red, 2))/蓝\(format(blueOnTop.blue, 2))；红在后时读到 红\(format(redOnTop.red, 2))/蓝\(format(redOnTop.blue, 2))；重画 \(source.draws - draws) 次"
    )

    source.items = Array(items.dropFirst())
    settle()
    list.check("从清单里去掉的项：画面上消失", near(pixel(items[0].rect.center).alpha, 0))
    source.items = items
    settle()

    // 5. 拖拽层
    print("[自检] 5. 拖拽层")
    diagnostics = host.diagnostics
    list.check("没有拖拽项时，拖拽层窗口不显示", diagnostics.displays.allSatisfy { !$0.isDragWindowShown && $0.dragWindowNumbers.isEmpty })

    let dragDisplay = realLayout.displays.last ?? primary
    var dragItem = OverlayItem(
        iconID: IconID(rawValue: 1), layer: .drag,
        rect: CGRect(x: dragDisplay.frame.midX - 32, y: dragDisplay.frame.maxY - 90, width: 64, height: 64),
        outsets: outsets, contentVersion: 1
    )
    source.items = items + [dragItem]
    settle(0.3)
    diagnostics = host.diagnostics
    windows = onScreenWindows()
    let shownOn = diagnostics.displays.filter(\.isDragWindowShown).map(\.id)
    list.check("有拖拽项时，只有它所在的那块屏显示拖拽层窗口", shownOn == [dragDisplay.id], "显示在屏 \(shownOn.map(\.rawValue))")
    if let number = diagnostics.displays.first(where: { $0.id == dragDisplay.id })?.dragWindowNumbers.first,
       let window = windows.first(where: { $0.number == number }) {
        let above = windows.filter { $0.order < window.order }
        let below = windows.filter { $0.order > window.order }
        list.check(
            "拖拽层层级 = 系统拖影层 +1（\(dragImageLevel + 1)），在所有层级 ≤ \(dragImageLevel) 的窗口之前",
            window.layer == dragImageLevel + 1 && below.allSatisfy { $0.layer <= window.layer } && above.allSatisfy { $0.layer >= window.layer },
            "它前面有 \(above.count) 个窗口，层级最低的是 \(above.map(\.layer).min().map(String.init) ?? "无")；后面层级最高的是 \(below.map(\.layer).max().map(String.init) ?? "无")"
        )
        let dock = windows.filter { $0.layer == Int(CGWindowLevelForKey(.dockWindow)) }
        let menuBar = windows.filter { $0.layer == Int(CGWindowLevelForKey(.mainMenuWindow)) }
        list.note("此刻在屏的程序坞层窗口 \(dock.count) 个、菜单栏层窗口 \(menuBar.count) 个，都排在拖拽层之后：\((dock + menuBar).allSatisfy { $0.order > window.order })")
    } else {
        list.check("拖拽层窗口在系统窗口列表里", false)
    }
    list.check("拖拽项画在拖拽层上", near(pixel(dragItem.rect.center, .drag).alpha, 1))
    targets = hitTargets()
    list.check(
        "拖拽层显示期间，\(probePoints.count) 个探测点上鼠标会落到的窗口仍与最初完全相同",
        targets == targetsBefore && ourWindowNumbers().isDisjoint(with: targets)
    )
    let underDrag = NSWindow.windowNumber(at: realLayout.appKitPoint(fromGlobal: dragItem.rect.center), belowWindowWithWindowNumber: 0)
    list.check("拖拽项正下方那一点，鼠标落到的也不是叠加窗口", !ourWindowNumbers().contains(underDrag))
    list.check("拖拽层出现后仍然没有抢焦点", application.keyWindow == nil && !application.isActive
        && NSWorkspace.shared.frontmostApplication?.processIdentifier == frontBefore)

    if let seam {
        dragItem.rect = CGRect(x: seam.x - 32, y: seam.y + 80, width: 64, height: 64)
        source.items = items + [dragItem]
        draws = source.draws
        settle(0.3)
        let both = host.diagnostics.displays.filter(\.isDragWindowShown).count
        list.check(
            "拖拽项移到两块屏的接缝上：两块屏的拖拽层都显示，各画一半",
            both == 2 && near(pixel(CGPoint(x: seam.x - 10, y: seam.y + 112), .drag).alpha, 1)
                && near(pixel(CGPoint(x: seam.x + 10, y: seam.y + 112), .drag).alpha, 1),
            "显示的拖拽层窗口 \(both) 个，重画 \(source.draws - draws) 次"
        )
    }
    source.items = items
    settle(0.3)
    list.check("拖拽项消失后，拖拽层窗口全部收起", host.diagnostics.displays.allSatisfy { !$0.isDragWindowShown })

    // 6. 帧循环
    print("[自检] 6. 帧循环与省电信号")
    source.demand = .idle
    settle()
    var frames = source.frames
    spin(0.6)
    list.check("需求为「休息」：0.6 秒内一帧不出", source.frames == frames, "出了 \(source.frames - frames) 帧")

    source.demand = .continuous
    host.requestFrame()
    spin(0.2)
    frames = source.frames
    let startedAt = uptime()
    spin(1.0)
    let rate = Double(source.frames - frames) / (uptime() - startedAt)
    list.check("需求为「连续」：每秒约 60 帧（48…75 都算）", rate > 45 && rate < 78, "每秒 \(format(rate)) 帧，节拍来源 \(host.diagnostics.clockSource)")

    source.demand = .idle
    spin(0.1)
    frames = source.frames
    // 请求一帧；这一帧说"0.25 秒后再来"。
    source.demand = .by(uptime() + 0.25)
    host.requestFrame()
    spin(0.1)
    let afterRequest = source.frames
    spin(0.35)
    list.check(
        "需求为「0.25 秒后」：请求的那一帧立刻出，约定的那一帧到点才出",
        afterRequest == frames + 1 && source.frames >= afterRequest + 1,
        "请求后 \(afterRequest - frames) 帧，到点后共 \(source.frames - frames) 帧"
    )
    source.demand = .idle
    settle()
    list.check("帧时间从不超前于系统时钟", source.timeRuleViolations == 0, "超前 \(source.timeRuleViolations) 次")

    // 7. 暂停
    print("[自检] 7. 暂停与恢复")
    source.items = items + [dragItem]
    source.demand = .continuous
    settle(0.3)
    pause.setPaused(true)
    spin(0.4)
    frames = source.frames
    spin(0.5)
    diagnostics = host.diagnostics
    list.check("暂停后不再出帧", source.frames == frames, "出了 \(source.frames - frames) 帧")
    list.check(
        "暂停后画面全部隐藏、拖拽层收起",
        near(pixel(items[1 % items.count].rect.center).alpha, 0) && diagnostics.displays.allSatisfy { !$0.isDragWindowShown }
    )
    pause.setPaused(false)
    spin(0.6)
    list.check(
        "恢复后重新出帧、画面回来、拖拽层回来",
        source.frames > frames && near(pixel(items[1 % items.count].rect.center).alpha, 1)
            && host.diagnostics.displays.contains(where: \.isDragWindowShown),
        "恢复后 0.6 秒出了 \(source.frames - frames) 帧"
    )
    source.items = items
    source.demand = .idle
    settle()

    // 8. 显示器变化（模拟）
    print("[自检] 8. 显示器布局变化（用假的布局模拟：把最后一块屏缩小并挪动）")
    let changed = realLayout.displays.last ?? primary
    let fakeFrame = CGRect(
        x: changed.frame.minX + (changed.isPrimary ? 0 : 120), y: changed.frame.minY + (changed.isPrimary ? 0 : 60),
        width: changed.frame.width - 240, height: changed.frame.height - 120
    )
    layoutBox.layout = DisplayLayout(displays: realLayout.displays.map { display in
        display.id == changed.id ? DisplayInfo(id: display.id, frame: fakeFrame, scale: display.scale) : display
    })
    let insideFake = OverlayItem(
        iconID: IconID(rawValue: 94),
        rect: CGRect(x: fakeFrame.minX + 50, y: fakeFrame.minY + 50, width: 64, height: 64), contentVersion: 1
    )
    source.items = items + [insideFake]
    draws = source.draws
    // 系统在显示器变化时发的就是这条通知；这里由本程序自己发给自己。
    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: application)
    settle(0.5)
    windows = onScreenWindows()
    diagnostics = host.diagnostics
    let rebuilt = diagnostics.displays.first { $0.id == changed.id }
    let rebuiltWindow = rebuilt?.desktopWindowNumbers.first.flatMap { number in windows.first { $0.number == number } }
    list.check(
        "布局变了：窗口按新的位置和大小重建",
        rebuilt?.frame == fakeFrame && rebuiltWindow?.bounds == fakeFrame && diagnostics.displays.allSatisfy { $0.desktopWindowCount == 1 },
        "新窗口边界 \(rebuiltWindow.map { "\(Int($0.bounds.minX)),\(Int($0.bounds.minY)) \(Int($0.bounds.width))×\(Int($0.bounds.height))" } ?? "找不到")"
    )
    list.check(
        "重建后全部重画，位置按新布局换算",
        source.draws >= draws + items.count && near(pixel(insideFake.rect.center).alpha, 1),
        "重画 \(source.draws - draws) 次"
    )
    let current = Set(diagnostics.displays.flatMap { $0.desktopWindowNumbers + $0.dragWindowNumbers })
    let stray = onScreenWindows().filter { $0.pid == ownPID && !current.contains($0.number) }.count
    list.check("旧窗口没有残留", stray == 0, "本进程多余的在屏窗口 \(stray) 个")
    layoutBox.layout = realLayout
    source.items = items
    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: application)
    settle(0.5)
    list.check("布局恢复：窗口回到真实的屏幕位置", host.diagnostics.displays.map(\.frame) == realLayout.displays.map(\.frame))

    // 9. 停止
    print("[自检] 9. 停止")
    source.demand = .continuous
    settle(0.2)
    host.stop()
    spin(0.3)
    frames = source.frames
    spin(0.3)
    let leftover = onScreenWindows().filter { $0.pid == ownPID }.count
    list.check("停止后不再出帧，所有窗口都关掉了", source.frames == frames && leftover == 0, "残留窗口 \(leftover) 个")
    host.start()
    settle(0.4)
    list.check("可以再次启动", host.diagnostics.displays.allSatisfy { $0.desktopWindowCount == 1 } && source.frames > frames)
    host.stop()
    spin(0.2)

    // 10. 在回调里暂停 / 停止
    print("[自检] 10. 调用方在回调里暂停或停止叠加层")
    host.start()
    source.demand = .continuous
    source.items = items + [dragItem]
    settle(0.3)
    // 让每一项都需要重画，然后在帧回调里暂停。
    var bumped = items.map { item -> OverlayItem in
        var copy = item
        copy.contentVersion += 100
        return copy
    }
    draws = source.draws
    source.duringFrame = { pause.setPaused(true) }
    source.items = bumped + [dragItem]
    spin(0.4)
    list.check(
        "帧回调里暂停：这一帧不再作画，拖拽层不会被重新显示",
        source.draws == draws && host.diagnostics.displays.allSatisfy { !$0.isDragWindowShown },
        "作画 \(source.draws - draws) 次"
    )
    pause.setPaused(false)
    spin(0.5)
    list.check("恢复后补上欠着的重画", source.draws >= draws + bumped.count, "作画 \(source.draws - draws) 次")

    // 再让每一项都需要重画，然后在第一次绘制回调里停止。
    bumped = bumped.map { item -> OverlayItem in
        var copy = item
        copy.contentVersion += 100
        return copy
    }
    draws = source.draws
    frames = source.frames
    source.duringDraw = { host.stop() }
    source.items = bumped + [dragItem]
    spin(0.5)
    let afterStop = onScreenWindows().filter { $0.pid == ownPID }.count
    list.check(
        "绘制回调里停止：只画了正在画的那一项，之后不再有帧和绘制，窗口全部关掉",
        source.draws == draws + 1 && source.frames == frames + 1 && afterStop == 0 && !host.diagnostics.isRunning,
        "作画 \(source.draws - draws) 次，帧 \(source.frames - frames) 次，残留窗口 \(afterStop) 个"
    )
    source.items = items
    source.demand = .idle

    // ───────── 乙、默认设置的叠加层：对当前真实系统状态的判断 ─────────
    print("[自检] 乙、默认设置下对当前系统状态的判断")
    let realHost = OverlayHost(pause: PauseSwitch())
    let realSource = SolidSource()
    realSource.demand = .continuous
    realSource.items = Array(items.prefix(realLayout.displays.count))
    realHost.frameSource = realSource
    var visibilityChanges: [Bool] = []
    realHost.onDesktopVisibilityChange = { visibilityChanges.append($0) }
    Lifecycle.shared.onExit { realHost.stop() }
    realHost.start()
    spin(1.5)
    let real = realHost.diagnostics
    print(describe(real))

    if real.isScreenLocked || real.areDisplaysAsleep {
        list.check(
            "此刻\(real.isScreenLocked ? "锁屏" : "")\(real.areDisplaysAsleep ? "、屏幕睡眠" : "")：桌面不可见，1.5 秒内一帧不出、一次不画",
            !real.isDesktopVisible && realSource.frames == 0 && realSource.draws == 0,
            "帧 \(realSource.frames)，绘制 \(realSource.draws)"
        )
    }
    for display in real.displays {
        switch display.iconLayer {
        case "absent":
            list.check(
                "屏 \(display.id.rawValue)：屏上没有访达的图标层（停在全屏应用的空间）→ 不建窗、不可见",
                display.desktopWindowCount == 0 && !display.isVisible
            )
        case "shielded":
            let hidden = (realHost.debugRenderedPixel(at: realSource.items.first { display.frame.intersects($0.rect) }?.rect.center ?? .zero, layer: .desktop)?.alpha ?? 0) < 0.02
            list.check(
                "屏 \(display.id.rawValue)：图标层被系统的遮挡窗口盖住（桌面项目被隐藏）→ 窗口备着但内容隐藏、不可见",
                !display.isVisible && display.desktopWindowCount == 1 && hidden
            )
        default:
            list.note("屏 \(display.id.rawValue)：图标层看得见；这块屏\(display.isVisible ? "可见" : "不可见（被挡住或会话不在线）")")
        }
    }
    list.check(
        "可见性回调与 isDesktopVisible 一致",
        (visibilityChanges.last ?? false) == realHost.isDesktopVisible,
        "回调序列 \(visibilityChanges)"
    )
    if real.isDesktopVisible {
        list.check("桌面可见时在出帧", realSource.frames > 0, "1.5 秒 \(realSource.frames) 帧")
    }
    realHost.stop()
    spin(0.2)

    let residue = onScreenWindows().filter { $0.pid == ownPID }.count
    list.check("收尾：本进程没有残留的在屏窗口", residue == 0, "\(residue) 个")
    list.check("收尾：鼠标会落到的窗口与开始时完全相同，前台应用没变",
               hitTargets() == targetsBefore && NSWorkspace.shared.frontmostApplication?.processIdentifier == frontBefore)

    print("[自检] 结果：通过 \(list.passes) 项，未通过 \(list.failures) 项")
    print(list.failures == 0 ? "self-check: PASS" : "self-check: FAIL")
    Lifecycle.shared.finish(code: list.failures == 0 ? 0 : 1)
}
