// Overlay · 叠加窗口
//
// 一个与屏幕等大的透明窗口，里面每个画布项是一个小图层。
//
// 【安全线】这个窗口从出生起就点击穿透：先设好"不接收鼠标事件"，之后才可能被显示；
// 它不能成为键盘焦点窗口，也不能成为主窗口；显示时不激活本应用。

import AppKit
import DDMCore
import QuartzCore

/// 一个已经画好、等着贴到窗口上的画布项。
struct ItemVisual {
    var key: OverlayItem.Key
    /// 位图在这块屏上的落位。
    var placement: CanvasPlacement
    /// 画好的位图。
    var image: CGImage
}

@MainActor
final class CanvasWindow: NSWindow {
    /// 所有画布项图层的父图层。整体淡入淡出只动它的不透明度。
    private let itemsLayer = CALayer()
    private var itemLayers: [OverlayItem.Key: CALayer] = [:]

    /// 内容当前是否显示（淡出后为 false；窗口本身还在）。
    private(set) var isContentShown = true

    /// 最近一次确认"在当前空间里"的时刻。窗口太多时先关最久没用的。
    var lastActiveAt: TimeInterval = 0

    /// - Parameters:
    ///   - appKitFrame: 窗口位置，AppKit 坐标（与所在显示器等大）。
    ///   - level: 窗口层级。
    ///   - behavior: 在空间、调度中心里的表现。
    init(appKitFrame: CGRect, level: NSWindow.Level, behavior: NSWindow.CollectionBehavior) {
        // defer: true —— 在第一次显示之前，系统里还没有这个窗口。
        super.init(contentRect: appKitFrame, styleMask: [.borderless], backing: .buffered, defer: true)

        // 第一件事：点击穿透。此刻窗口还没有显示过。
        ignoresMouseEvents = true

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // 窗口的色彩空间与位图一致（sRGB）。不设的话窗口跟着屏幕走（内屏是广色域），
        // 每次换图都要在本进程里用处理器把整张位图转一遍色彩——实测占了内屏重画开销的一半。
        // 设成一致后，色彩转换由系统在合成时用显卡完成，颜色不变。
        colorSpace = .sRGB
        self.level = level
        collectionBehavior = behavior
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        canHide = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        isMovable = false
        acceptsMouseMovedEvents = false
        isRestorable = false
        // 对辅助功能来说这里没有任何可操作的东西。
        setAccessibilityElement(false)

        let root = CALayer()
        root.isOpaque = false
        root.masksToBounds = true
        itemsLayer.frame = CGRect(origin: .zero, size: appKitFrame.size)
        itemsLayer.actions = Self.noImplicitAnimations
        root.addSublayer(itemsLayer)

        let view = NSView(frame: CGRect(origin: .zero, size: appKitFrame.size))
        view.layer = root            // 先给图层再开启：视图直接用我们的图层树，不自己画任何东西
        view.wantsLayer = true
        contentView = view

        setFrame(appKitFrame, display: false)
    }

    // 绝不接收键盘焦点。
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // 系统有时会把窗口"挤回"屏幕可见范围内；叠加窗口必须和屏幕严丝合缝，不接受调整。
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// 窗口里现在有多少个画布项图层。
    var itemCount: Int { itemLayers.count }

    /// 让窗口里的图层与给定的清单一致：新增、移动、换图、调整叠放次序、移除多余的。
    /// 清单的顺序就是叠放次序，排在后面的在上面。没有变化的图层不会被触碰。
    func apply(_ visuals: [ItemVisual]) {
        let height = frame.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        var keep = Set<OverlayItem.Key>()
        keep.reserveCapacity(visuals.count)
        for visual in visuals {
            keep.insert(visual.key)
            let layer: CALayer
            if let existing = itemLayers[visual.key] {
                layer = existing
            } else {
                layer = CALayer()
                layer.actions = Self.noImplicitAnimations
                layer.anchorPoint = .zero
                layer.isOpaque = false
                itemsLayer.addSublayer(layer)
                itemLayers[visual.key] = layer
            }
            let target = visual.placement.layerFrame(inWindowOfHeight: height)
            if layer.position != target.origin { layer.position = target.origin }
            if layer.bounds.size != target.size { layer.bounds = CGRect(origin: .zero, size: target.size) }
            if layer.contentsScale != visual.placement.scale { layer.contentsScale = visual.placement.scale }
            if (layer.contents as AnyObject?) !== visual.image { layer.contents = visual.image }
        }
        for (key, layer) in itemLayers where !keep.contains(key) {
            layer.removeFromSuperlayer()
            itemLayers[key] = nil
        }
        // 叠放次序 = 清单顺序：子图层排在后面的画在上面。次序变了才重排。
        let current = itemsLayer.sublayers ?? []
        let inOrder = current.count == visuals.count
            && zip(current, visuals).allSatisfy { layer, visual in layer === itemLayers[visual.key] }
        if !inOrder {
            itemsLayer.sublayers = visuals.compactMap { itemLayers[$0.key] }
        }

        CATransaction.commit()
    }

    /// 显示 / 隐藏全部内容。窗口本身留在原处（这样它所在的空间、层级、遮挡通知都不受影响）。
    func setContentShown(_ shown: Bool, duration: TimeInterval) {
        guard shown != isContentShown else { return }
        isContentShown = shown
        CATransaction.begin()
        if duration > 0 {
            CATransaction.setAnimationDuration(duration)
            itemsLayer.actions = nil      // 这一次要动画
        } else {
            CATransaction.setDisableActions(true)
        }
        itemsLayer.opacity = shown ? 1 : 0
        CATransaction.commit()
        itemsLayer.actions = Self.noImplicitAnimations
    }

    /// 自检用：把图层树画到一个 1 像素的位图上，返回窗口里某一点渲染出来的颜色。
    /// - Parameter localPoint: 屏内坐标（点、y 向下）。
    func renderedPixel(atLocalPoint localPoint: CGPoint, scale: CGFloat) -> OverlayDebugPixel? {
        guard let root = contentView?.layer, scale > 0 else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let didRender: Bool = pixel.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: ItemRasterizer.bitmapInfo
            ) else { return false }
            // 图层坐标：原点在窗口左下角、y 向上。把要看的那个像素挪到位图唯一的那个像素上。
            let x = (localPoint.x * scale).rounded(.down) / scale
            let y = frame.height - ((localPoint.y * scale).rounded(.down) + 1) / scale
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -x, y: -y)
            root.render(in: context)
            return true
        }
        guard didRender else { return nil }
        // 位图是 BGRA、预乘透明度。
        return OverlayDebugPixel(
            red: Double(pixel[2]) / 255, green: Double(pixel[1]) / 255,
            blue: Double(pixel[0]) / 255, alpha: Double(pixel[3]) / 255
        )
    }

    /// 图层属性变化时不要系统自带的渐变动画：位置、内容都是我们逐帧给的。
    private static let noImplicitAnimations: [String: any CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "contentsScale": NSNull(),
        "opacity": NSNull(), "hidden": NSNull(), "sublayers": NSNull(),
        "onOrderIn": NSNull(), "onOrderOut": NSNull(),
    ]
}
