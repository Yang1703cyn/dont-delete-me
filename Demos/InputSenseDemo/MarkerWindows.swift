// InputSenseDemo · 可选的标记窗口（--show）
//
// 把假图标（蓝框）、废纸篓的估算区域（红框）、量到的程序坞那一条（黄框）画在屏幕上，给真人核对用。
// 每块屏一个透明窗口：从创建起就不接收鼠标事件、不能成为焦点窗口、不激活应用。默认不开。

import AppKit
import CoreGraphics
import DDMCore
import Foundation

@MainActor
final class MarkerWindows {
    private var windows: [(display: DisplayInfo, window: NSWindow, view: MarkerView)] = []
    private var shown: MarkerView.Content?

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let layout = DisplayLayout.current()
        for display in layout.displays {
            let frame = layout.appKitRect(fromGlobal: display.frame)
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
            window.ignoresMouseEvents = true            // 第一件事：点击穿透
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)   // 比程序坞高一级
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            let view = MarkerView(frame: NSRect(origin: .zero, size: frame.size))
            view.display = display
            window.contentView = view
            window.orderFrontRegardless()               // 显示但不激活
            windows.append((display, window, view))
        }
    }

    func show(icons: [CGRect], dragged: CGRect?, trash: CGRect?, dockBar: CGRect?) {
        let content = MarkerView.Content(icons: icons, dragged: dragged, trash: trash, dockBar: dockBar)
        guard content != shown else { return }
        shown = content
        for entry in windows {
            entry.view.content = content
            entry.view.needsDisplay = true
        }
    }

    func close() {
        for entry in windows { entry.window.close() }
        windows = []
    }
}

final class MarkerView: NSView {
    struct Content: Equatable {
        var icons: [CGRect] = []
        var dragged: CGRect?
        var trash: CGRect?
        var dockBar: CGRect?
    }

    var display: DisplayInfo?
    var content = Content()

    override var isFlipped: Bool { true }   // 和全局坐标一样 y 向下

    override func draw(_ dirtyRect: NSRect) {
        guard let display else { return }
        func outline(_ rect: CGRect, _ color: NSColor, width: CGFloat, label: String? = nil) {
            let local = display.localRect(fromGlobal: rect)
            guard local.intersects(bounds) else { return }
            color.setStroke()
            let path = NSBezierPath(rect: local.insetBy(dx: width / 2, dy: width / 2))
            path.lineWidth = width
            path.stroke()
            if let label {
                label.draw(at: CGPoint(x: local.minX + 4, y: local.minY + 2), withAttributes: [
                    .font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: color,
                ])
            }
        }
        if let bar = content.dockBar { outline(bar, .systemYellow, width: 1) }
        for (index, rect) in content.icons.enumerated() { outline(rect, .systemBlue, width: 2, label: "\(index + 1)") }
        if let dragged = content.dragged { outline(dragged, .systemPurple, width: 2) }
        if let trash = content.trash { outline(trash, .systemRed, width: 3) }
    }
}
