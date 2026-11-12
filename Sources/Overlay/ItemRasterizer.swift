// Overlay · 画布（位图）
//
// 给调用方准备一块"全局坐标、y 向下、单位点、已裁剪、已清空"的画布，画完取出一张图贴到图层上。
// 只用 CoreGraphics，不碰窗口，所以可以在单元测试里逐像素检查。

import CoreGraphics
import DDMCore
import Foundation
import os

enum ItemRasterizer {
    /// 位图的像素格式：8 位、预乘透明度、BGRA（图层合成用的原生格式，贴上去不必再转换）。
    static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    /// 每个像素 4 字节，透明度在第 4 个字节。
    static let bytesPerPixel = 4
    static let alphaByteOffset = 3

    /// 位图的色彩空间。叠加窗口的色彩空间与它一致（见 CanvasWindow），贴图时不必转换。
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// 一块正在画的画布。
    struct Canvas {
        /// 坐标系是全局坐标（y 向下、单位点），已清空为全透明，已裁剪。
        var context: CGContext { backing.context }
        var pixelWidth: Int { backing.pixelWidth }
        var pixelHeight: Int { backing.pixelHeight }
        fileprivate let backing: CanvasBacking

        /// 读回一个像素的不透明度（0…255）。像素坐标以位图左上角为原点。测试用。
        func alpha(pixelX: Int, pixelY: Int) -> UInt8 {
            guard pixelX >= 0, pixelY >= 0, pixelX < pixelWidth, pixelY < pixelHeight else { return 0 }
            let offset = (pixelY * pixelWidth + pixelX) * ItemRasterizer.bytesPerPixel + ItemRasterizer.alphaByteOffset
            return backing.memory.load(fromByteOffset: offset, as: UInt8.self)
        }
    }

    /// 造一块画布。
    /// - Parameters:
    ///   - placement: 位图在这块屏上的落位（决定位图大小和坐标系的原点）。
    ///   - display: 所在的屏。
    ///   - clip: 裁剪范围，全局坐标——就是 `OverlayItem.canvasRect`。
    /// - Returns: 画完后要么交给 `finish(_:)` 取图，要么交给 `discard(_:)` 归还。
    static func makeCanvas(placement: CanvasPlacement, display: DisplayInfo, clip: CGRect) -> Canvas? {
        let width = placement.pixelFrame.width
        let height = placement.pixelFrame.height
        guard width > 0, height > 0,
              let backing = CanvasBackingPool.shared.take(pixelWidth: width, pixelHeight: height) else { return nil }
        let context = backing.context

        // 位图画布默认原点在左下角、y 向上、单位像素。三步变成全局坐标：
        let origin = placement.globalFrame(on: display).origin
        context.translateBy(x: 0, y: CGFloat(height))                    // 1. 原点挪到位图左上角
        context.scaleBy(x: placement.scale, y: -placement.scale)         // 2. y 翻转成向下，单位变成点
        context.translateBy(x: -origin.x, y: -origin.y)                  // 3. 原点挪到全局原点
        context.clip(to: clip)
        return Canvas(backing: backing)
    }

    /// 画完了：把画布变成一张图。不拷贝像素——图直接用画布的内存；图被释放时，画布自动回到池里等下次再用。
    /// 调用之后不要再往这块画布上画。
    static func finish(_ canvas: Canvas) -> CGImage? {
        let backing = canvas.backing
        // 图活着的时候要让画布也活着：把画布的一次持有交给 provider，释放回调里取回并归还池子。
        let info = Unmanaged.passRetained(backing).toOpaque()
        guard let provider = CGDataProvider(
            dataInfo: info, data: backing.memory, size: backing.byteCount,
            releaseData: { info, _, _ in
                guard let info else { return }
                CanvasBackingPool.shared.give(Unmanaged<CanvasBacking>.fromOpaque(info).takeRetainedValue())
            }
        ) else {
            CanvasBackingPool.shared.give(Unmanaged<CanvasBacking>.fromOpaque(info).takeRetainedValue())
            return nil
        }
        // 从这里起由 provider 负责归还：即使下面造图失败，provider 释放时画布也会回到池里。
        return CGImage(
            width: backing.pixelWidth, height: backing.pixelHeight,
            bitsPerComponent: 8, bitsPerPixel: bytesPerPixel * 8, bytesPerRow: backing.pixelWidth * bytesPerPixel,
            space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// 不要这块画布了：归还。
    static func discard(_ canvas: Canvas) {
        CanvasBackingPool.shared.give(canvas.backing)
    }

    /// 画一块画布并取出成图。`draw` 里按全局坐标作画即可。
    static func render(
        placement: CanvasPlacement,
        display: DisplayInfo,
        clip: CGRect,
        draw: (CGContext) -> Void
    ) -> CGImage? {
        guard let canvas = makeCanvas(placement: placement, display: display, clip: clip) else { return nil }
        draw(canvas.context)
        return finish(canvas)
    }
}

/// 一块可以反复使用的画布：位图内存 + 绑在这块内存上的绘图上下文。
///
/// 线程：同一时刻只有一方在用它——要么在池子里闲着，要么被一次绘制借走，要么被一张图拿着当像素来源
/// （这期间没有人往里画）。所以虽然它本身不是线程安全的，在各方之间交接是安全的。
final class CanvasBacking: @unchecked Sendable {
    let memory: UnsafeMutableRawPointer
    let context: CGContext
    let pixelWidth: Int
    let pixelHeight: Int
    var byteCount: Int { pixelWidth * pixelHeight * ItemRasterizer.bytesPerPixel }

    init?(pixelWidth: Int, pixelHeight: Int) {
        let byteCount = pixelWidth * pixelHeight * ItemRasterizer.bytesPerPixel
        guard byteCount > 0, let memory = calloc(1, byteCount) else { return nil }
        guard let context = CGContext(
            data: memory, width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: pixelWidth * ItemRasterizer.bytesPerPixel,
            space: ItemRasterizer.colorSpace, bitmapInfo: ItemRasterizer.bitmapInfo
        ) else {
            free(memory)
            return nil
        }
        self.memory = memory
        self.context = context
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        // 记下"刚出厂"的绘图状态，每次再用之前回到这里。
        context.saveGState()
    }

    deinit {
        free(memory)
    }

    /// 再用之前：像素清零，坐标系、裁剪、颜色、线宽等一切绘图状态回到刚出厂的样子。
    fileprivate func reset() {
        memset(memory, 0, byteCount)
        context.restoreGState()
        context.saveGState()
        // 上一位使用者的"保存 / 恢复绘图状态"如果不成对，上面那一步回不到出厂状态。
        // 最要紧的两样——坐标系和裁剪——在这里再强制归位一次，免得下一张脸画歪或被裁掉。
        if context.ctm != .identity {
            context.concatenate(context.ctm.inverted())
        }
        context.resetClip()
    }
}

/// 画布池。
///
/// 为什么需要：30 张脸每帧重画就是每秒 1800 块画布。每块都新建、用完就扔的话，
/// 内存映射、首次写入时的缺页、解除映射，再加上每个新上下文第一次作画时的内部初始化，
/// 合起来比真正画东西还贵（采样实测，见 docs/模块说明/overlay.md）。
/// 同样大小的画布反复出现（图标大小固定、外扩成档），所以把用过的留着，下次清零后直接再用。
///
/// 线程：图可能在任何线程被释放（于是画布在任何线程被归还），所以用一把锁保护。
final class CanvasBackingPool: Sendable {
    static let shared = CanvasBackingPool()

    /// 每种大小最多留这么多块、总共最多留这么多字节；超出的直接释放。
    static let maxPerSize = 96
    static let maxPooledBytes = 48 * 1024 * 1024

    private struct Size: Hashable {
        var width: Int
        var height: Int
    }

    private struct State {
        var free: [Size: [CanvasBacking]] = [:]
        var pooledBytes = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// 取一块指定大小的画布：像素全透明，绘图状态是刚出厂的样子。内存不够时为 nil。
    func take(pixelWidth: Int, pixelHeight: Int) -> CanvasBacking? {
        let size = Size(width: pixelWidth, height: pixelHeight)
        let reused: CanvasBacking? = state.withLock { state in
            guard let backing = state.free[size]?.popLast() else { return nil }
            state.pooledBytes -= backing.byteCount
            return backing
        }
        if let reused {
            reused.reset()
            return reused
        }
        return CanvasBacking(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    /// 归还一块画布。
    func give(_ backing: CanvasBacking) {
        let size = Size(width: backing.pixelWidth, height: backing.pixelHeight)
        state.withLock { state in
            guard state.pooledBytes + backing.byteCount <= Self.maxPooledBytes,
                  (state.free[size]?.count ?? 0) < Self.maxPerSize else { return }
            state.free[size, default: []].append(backing)
            state.pooledBytes += backing.byteCount
        }
        // 没被留下的，随着这次调用结束自动释放。
    }

    /// 把留着的画布全部释放（叠加层停止运行时）。
    func drain() {
        state.withLock { state in
            state.free.removeAll()
            state.pooledBytes = 0
        }
    }

    /// 池里现在留着多少字节（测试用）。
    var pooledBytes: Int { state.withLock { $0.pooledBytes } }
}
