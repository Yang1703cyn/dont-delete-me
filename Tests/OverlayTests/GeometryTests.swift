// OverlayTests · 坐标换算：全局坐标 → 某块屏上的像素落位 → 窗口里的图层位置

import CoreGraphics
import DDMCore
import Foundation
import Testing
@testable import Overlay

@Suite("坐标换算")
struct GeometryTests {
    @Test func 整数位置的画布在两倍屏上每点两个像素() throws {
        let placement = try #require(CanvasGeometry.placement(
            for: CGRect(x: 100, y: 200, width: 80, height: 100), on: Fixture.builtIn
        ))
        #expect(placement.pixelFrame == PixelRect(x: 200, y: 400, width: 160, height: 200))
        #expect(placement.scale == 2)
        #expect(placement.localFrame == CGRect(x: 100, y: 200, width: 80, height: 100))
    }

    @Test func 外接屏原点为负_换算到屏内再取像素() throws {
        // 全局 (-1820, 142) 就是外接屏内的 (100, 200)。
        let placement = try #require(CanvasGeometry.placement(
            for: CGRect(x: -1820, y: 142, width: 80, height: 100), on: Fixture.external
        ))
        #expect(placement.pixelFrame == PixelRect(x: 100, y: 200, width: 80, height: 100))
        #expect(placement.globalFrame(on: Fixture.external) == CGRect(x: -1820, y: 142, width: 80, height: 100))
    }

    @Test func 带小数的位置向外取整到像素格() throws {
        // 一倍屏：100.25…164.25 → 像素 100…165，多出一个像素包住边缘。
        let oneX = try #require(CanvasGeometry.placement(
            for: CGRect(x: -1920 + 100.25, y: -58 + 10.75, width: 64, height: 64), on: Fixture.external
        ))
        #expect(oneX.pixelFrame == PixelRect(x: 100, y: 10, width: 65, height: 65))

        // 两倍屏：半个点正好是一个像素，不需要多出来。
        let twoX = try #require(CanvasGeometry.placement(
            for: CGRect(x: 100.5, y: 10.5, width: 64, height: 64), on: Fixture.builtIn
        ))
        #expect(twoX.pixelFrame == PixelRect(x: 201, y: 21, width: 128, height: 128))
    }

    @Test func 位图覆盖的范围总是包住画布矩形() {
        var random = SeededRandom(seed: 7)
        for display in Fixture.layout.displays {
            for _ in 0..<200 {
                let rect = CGRect(
                    x: display.frame.minX + CGFloat.random(in: 0...1000, using: &random),
                    y: display.frame.minY + CGFloat.random(in: 0...800, using: &random),
                    width: CGFloat.random(in: 1...200, using: &random),
                    height: CGFloat.random(in: 1...200, using: &random)
                )
                guard let placement = CanvasGeometry.placement(for: rect, on: display) else {
                    Issue.record("屏内的矩形应当有落位：\(rect)")
                    continue
                }
                let covered = placement.globalFrame(on: display)
                #expect(covered.contains(rect))
                // 多出来的部分不到一个像素。
                let pixel = 1 / display.scale
                #expect(rect.minX - covered.minX < pixel && covered.maxX - rect.maxX < pixel)
                #expect(rect.minY - covered.minY < pixel && covered.maxY - rect.maxY < pixel)
            }
        }
    }

    @Test func 不相交_不合法_大得离谱的矩形都不画() {
        #expect(CanvasGeometry.placement(for: CGRect(x: 5000, y: 0, width: 64, height: 64), on: Fixture.builtIn) == nil)
        #expect(CanvasGeometry.placement(for: CGRect(x: 0, y: 0, width: 0, height: 64), on: Fixture.builtIn) == nil)
        #expect(CanvasGeometry.placement(for: CGRect(x: CGFloat.nan, y: 0, width: 64, height: 64), on: Fixture.builtIn) == nil)
        #expect(CanvasGeometry.placement(for: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 64), on: Fixture.builtIn) == nil)
        #expect(CanvasGeometry.placement(for: .null, on: Fixture.builtIn) == nil)
        // 坐标或大小大得离谱（传错了）：不画，也不会在换算成整数时出错。
        #expect(CanvasGeometry.placement(for: CGRect(x: 1e300, y: 0, width: 64, height: 64), on: Fixture.builtIn) == nil)
        #expect(CanvasGeometry.placement(for: CGRect(x: 0, y: 0, width: 1e12, height: 64), on: Fixture.builtIn) == nil)
        #expect(CanvasGeometry.placement(for: CGRect(x: -1e15, y: -1e15, width: 2e15, height: 2e15), on: Fixture.builtIn) == nil)
        #expect(CanvasGeometry.placement(for: CGRect(x: -1e30, y: 0, width: 1e31, height: 64), on: Fixture.external) == nil)
        // 每边最多 4096 像素：两倍屏上 2049 点就超了。
        #expect(CanvasGeometry.placement(for: CGRect(x: 0, y: 0, width: 2049, height: 64), on: Fixture.builtIn) == nil)
        #expect(CanvasGeometry.placement(for: CGRect(x: 0, y: 0, width: 2048, height: 64), on: Fixture.builtIn) != nil)
    }

    @Test func 骑在两块屏接缝上的画布在两块屏上各有落位() throws {
        // 接缝在 x = 0：左半在外接屏，右半在内屏。
        let canvas = CGRect(x: -40, y: 360, width: 80, height: 80)
        #expect(CanvasGeometry.displays(showing: canvas, in: Fixture.layout).map(\.id) == [Fixture.builtIn.id, Fixture.external.id])

        let onBuiltIn = try #require(CanvasGeometry.placement(for: canvas, on: Fixture.builtIn))
        #expect(onBuiltIn.pixelFrame == PixelRect(x: -80, y: 720, width: 160, height: 160))   // 左半在屏外，由窗口裁掉

        let onExternal = try #require(CanvasGeometry.placement(for: canvas, on: Fixture.external))
        #expect(onExternal.pixelFrame == PixelRect(x: 1880, y: 418, width: 80, height: 80))   // 右半超出屏宽 1920

        // 两块位图描述的是同一个全局矩形。
        #expect(onBuiltIn.globalFrame(on: Fixture.builtIn) == canvas)
        #expect(onExternal.globalFrame(on: Fixture.external) == canvas)
    }

    @Test func 图层位置要用下边缘翻转成y向上() throws {
        let placement = try #require(CanvasGeometry.placement(
            for: CGRect(x: 100, y: 200, width: 80, height: 100), on: Fixture.builtIn
        ))
        // 窗口高 982：画布上沿在 200、下沿在 300，离窗口底边 682。
        #expect(placement.layerFrame(inWindowOfHeight: 982) == CGRect(x: 100, y: 682, width: 80, height: 100))
    }

    @Test func 只挪位置时按整数个像素挪() throws {
        let base = try #require(CanvasGeometry.placement(
            for: CGRect(x: 100, y: 200, width: 80, height: 100), on: Fixture.builtIn
        ))
        // 两倍屏：10.3 点 = 20.6 像素 → 21；-4.6 点 = -9.2 像素 → -9。
        let moved = base.moved(by: CGVector(dx: 10.3, dy: -4.6))
        #expect(moved.pixelFrame == PixelRect(x: 221, y: 391, width: 160, height: 200))
        #expect(moved.scale == base.scale)
        #expect(base.moved(by: .zero) == base)
    }
}
