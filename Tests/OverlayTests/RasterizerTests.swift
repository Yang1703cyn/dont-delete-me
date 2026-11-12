// OverlayTests · 画布：交给调用方的坐标系是不是全局坐标、y 向下、单位点、已裁剪、已清空

import CoreGraphics
import DDMCore
import Foundation
import Testing
@testable import Overlay

@Suite("画布")
struct RasterizerTests {
    /// 在某块屏上给一个画布项造画布，把图标矩形涂满，返回画布供读像素。
    private func drawnCanvas(_ item: OverlayItem, on display: DisplayInfo, fill: CGRect? = nil) throws -> ItemRasterizer.Canvas {
        let placement = try #require(CanvasGeometry.placement(for: item.canvasRect, on: display))
        let canvas = try #require(ItemRasterizer.makeCanvas(placement: placement, display: display, clip: item.canvasRect))
        canvas.context.setFillColor(gray: 0, alpha: 1)
        canvas.context.fill(fill ?? item.rect)      // 调用方直接用全局坐标作画
        return canvas
    }

    @Test func 新画布是全透明的() throws {
        let item = Fixture.item(x: 100, y: 200)
        let placement = try #require(CanvasGeometry.placement(for: item.canvasRect, on: Fixture.builtIn))
        let canvas = try #require(ItemRasterizer.makeCanvas(placement: placement, display: Fixture.builtIn, clip: item.canvasRect))
        defer { ItemRasterizer.discard(canvas) }
        #expect(canvas.pixelWidth == 160 && canvas.pixelHeight == 160)
        for y in stride(from: 0, to: canvas.pixelHeight, by: 7) {
            for x in stride(from: 0, to: canvas.pixelWidth, by: 7) {
                #expect(canvas.alpha(pixelX: x, pixelY: y) == 0)
            }
        }
    }

    @Test(arguments: [Fixture.builtIn, Fixture.external])
    func 按全局坐标画的矩形落在正确的像素上(display: DisplayInfo) throws {
        // 图标矩形在这块屏内 (100, 200)，画布四周各多 8 点。
        let item = Fixture.item(x: display.frame.minX + 100, y: display.frame.minY + 200)
        let canvas = try drawnCanvas(item, on: display)
        defer { ItemRasterizer.discard(canvas) }

        let scale = Int(display.scale)
        let inset = 8 * scale                    // 图标矩形在位图里从第 8 点开始
        let size = 64 * scale
        #expect(canvas.pixelWidth == 80 * scale && canvas.pixelHeight == 80 * scale)
        // 图标矩形的四个角（内侧）是实的。
        #expect(canvas.alpha(pixelX: inset, pixelY: inset) == 255)
        #expect(canvas.alpha(pixelX: inset + size - 1, pixelY: inset) == 255)
        #expect(canvas.alpha(pixelX: inset, pixelY: inset + size - 1) == 255)
        #expect(canvas.alpha(pixelX: inset + size - 1, pixelY: inset + size - 1) == 255)
        // 紧邻的外侧像素是空的。
        #expect(canvas.alpha(pixelX: inset - 1, pixelY: inset) == 0)
        #expect(canvas.alpha(pixelX: inset, pixelY: inset - 1) == 0)
        #expect(canvas.alpha(pixelX: inset + size, pixelY: inset + size - 1) == 0)
        #expect(canvas.alpha(pixelX: inset + size - 1, pixelY: inset + size) == 0)
    }

    @Test func y轴向下_画在矩形上半部的东西出现在位图上半部() throws {
        let item = Fixture.item(x: 100, y: 200, outsets: .zero)
        let topHalf = CGRect(x: 100, y: 200, width: 64, height: 32)
        let canvas = try drawnCanvas(item, on: Fixture.builtIn, fill: topHalf)
        defer { ItemRasterizer.discard(canvas) }
        #expect(canvas.alpha(pixelX: 64, pixelY: 10) == 255)      // 上半
        #expect(canvas.alpha(pixelX: 64, pixelY: 63) == 255)
        #expect(canvas.alpha(pixelX: 64, pixelY: 64) == 0)        // 下半
        #expect(canvas.alpha(pixelX: 64, pixelY: 120) == 0)
    }

    @Test func 画出画布范围的部分被裁掉() throws {
        // 一倍屏、位置带 0.5 点：位图比画布多出半个像素的边。把一大片都涂满，
        // 画布内是实的；位图边上那一列只盖住一半；再往外没有位图。
        let display = Fixture.external
        let item = OverlayItem(
            iconID: IconID(rawValue: 1),
            rect: CGRect(x: display.frame.minX + 100.5, y: display.frame.minY + 50, width: 64, height: 64),
            outsets: .zero, contentVersion: 1
        )
        let canvas = try drawnCanvas(item, on: display, fill: item.rect.insetBy(dx: -500, dy: -500))
        defer { ItemRasterizer.discard(canvas) }
        #expect(canvas.pixelWidth == 65 && canvas.pixelHeight == 64)
        #expect(canvas.alpha(pixelX: 1, pixelY: 30) == 255)
        #expect(canvas.alpha(pixelX: 63, pixelY: 30) == 255)
        let leftEdge = Int(canvas.alpha(pixelX: 0, pixelY: 30)), rightEdge = Int(canvas.alpha(pixelX: 64, pixelY: 30))
        #expect((120...136).contains(leftEdge), "左边缘像素应当只盖住一半，读到 \(leftEdge)")
        #expect((120...136).contains(rightEdge), "右边缘像素应当只盖住一半，读到 \(rightEdge)")
    }

    @Test func 骑缝的画布在两块屏上画出的是同一个全局位置() throws {
        // 图标矩形 x: -32…32，接缝在 0。内屏的位图里矩形从位图左边缘 8 点处开始；外接屏同理。
        let item = Fixture.item(x: -32, y: 368)
        for display in [Fixture.builtIn, Fixture.external] {
            let canvas = try drawnCanvas(item, on: display)
            defer { ItemRasterizer.discard(canvas) }
            let scale = Int(display.scale)
            #expect(canvas.pixelWidth == 80 * scale)
            #expect(canvas.alpha(pixelX: 8 * scale, pixelY: 8 * scale) == 255)
            #expect(canvas.alpha(pixelX: 8 * scale - 1, pixelY: 8 * scale) == 0)
            #expect(canvas.alpha(pixelX: 72 * scale - 1, pixelY: 72 * scale - 1) == 255)
            #expect(canvas.alpha(pixelX: 72 * scale, pixelY: 72 * scale - 1) == 0)
        }
    }

    @Test func 取出的图与位图同样大小() throws {
        let item = Fixture.item(x: 100, y: 200)
        let placement = try #require(CanvasGeometry.placement(for: item.canvasRect, on: Fixture.builtIn))
        var drawCalls = 0
        let image = try #require(ItemRasterizer.render(placement: placement, display: Fixture.builtIn, clip: item.canvasRect) { context in
            drawCalls += 1
            context.fill(item.rect)
        })
        #expect(drawCalls == 1)
        #expect(image.width == 160 && image.height == 160)
        #expect(image.alphaInfo == .premultipliedFirst)
    }
}

@Suite("画布池")
struct CanvasBackingPoolTests {
    @Test func 归还的画布会被再次使用_像素和绘图状态都回到初始() throws {
        let pool = CanvasBackingPool()
        let first = try #require(pool.take(pixelWidth: 32, pixelHeight: 16))
        // 弄脏它：改坐标系、改裁剪、涂满。
        first.context.translateBy(x: 5, y: 5)
        first.context.clip(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        first.context.setFillColor(gray: 0, alpha: 1)
        first.context.fill(CGRect(x: -100, y: -100, width: 500, height: 500))
        memset(first.memory, 0xFF, first.byteCount)
        pool.give(first)
        #expect(pool.pooledBytes == 32 * 16 * 4)

        let second = try #require(pool.take(pixelWidth: 32, pixelHeight: 16))
        #expect(second === first, "同样大小的画布应当被复用")
        #expect(pool.pooledBytes == 0)
        let bytes = UnsafeRawBufferPointer(start: second.memory, count: second.byteCount)
        #expect(bytes.allSatisfy { $0 == 0 }, "复用的画布必须清零")
        #expect(second.context.ctm == .identity, "坐标系必须回到初始")
        // 裁剪也回到了初始：涂满之后最后一个像素是实的。
        second.context.setFillColor(gray: 0, alpha: 1)
        second.context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
        #expect(bytes[bytes.count - 1] == 255)
        pool.give(second)

        // 大小不同的请求不会拿到这一块。
        let other = try #require(pool.take(pixelWidth: 16, pixelHeight: 32))
        #expect(other !== second)
        #expect(pool.pooledBytes == 32 * 16 * 4)
    }

    @Test func 上一位使用者没有成对地保存恢复_坐标系和裁剪照样归位() throws {
        let pool = CanvasBackingPool()
        let first = try #require(pool.take(pixelWidth: 20, pixelHeight: 20))
        // 多恢复了一次（把出厂状态也弹掉了），之后又改了坐标系和裁剪。
        first.context.restoreGState()
        first.context.scaleBy(x: 3, y: 3)
        first.context.clip(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        pool.give(first)

        let second = try #require(pool.take(pixelWidth: 20, pixelHeight: 20))
        #expect(second.context.ctm == .identity)
        second.context.setFillColor(gray: 0, alpha: 1)
        second.context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let bytes = UnsafeRawBufferPointer(start: second.memory, count: second.byteCount)
        #expect(bytes[bytes.count - 1] == 255 && bytes[3] == 255, "裁剪应当已经放开，整块都能画到")
    }

    @Test func 图被释放时画布回到池里() throws {
        // 用一个别处不会出现的画布大小，避免和并行的其它测试互相干扰。
        let display = Fixture.builtIn
        let odd = CGRect(x: 10, y: 10, width: 123.5, height: 61.5)
        let placement = try #require(CanvasGeometry.placement(for: odd, on: display))
        let bytes = placement.pixelFrame.width * placement.pixelFrame.height * 4
        let before = CanvasBackingPool.shared.pooledBytes
        do {
            let image = try #require(ItemRasterizer.render(placement: placement, display: display, clip: odd) { _ in })
            #expect(image.width == placement.pixelFrame.width)
        }
        // 图离开作用域后被释放，它的画布回到了公用的池子里。
        #expect(CanvasBackingPool.shared.pooledBytes >= before + bytes || CanvasBackingPool.shared.pooledBytes >= bytes)
    }

    @Test func 清空之后不再留着任何画布() throws {
        let pool = CanvasBackingPool()
        for size in [8, 8, 24] { pool.give(try #require(pool.take(pixelWidth: size, pixelHeight: size))) }
        #expect(pool.pooledBytes > 0)
        pool.drain()
        #expect(pool.pooledBytes == 0)
    }

    @Test func 池子有上限_超出的直接释放() throws {
        let pool = CanvasBackingPool()
        let extra = 10
        let blocks = try (0..<(CanvasBackingPool.maxPerSize + extra)).map { _ in try #require(pool.take(pixelWidth: 4, pixelHeight: 4)) }
        for block in blocks { pool.give(block) }
        #expect(pool.pooledBytes == CanvasBackingPool.maxPerSize * 4 * 4 * 4)
    }
}
