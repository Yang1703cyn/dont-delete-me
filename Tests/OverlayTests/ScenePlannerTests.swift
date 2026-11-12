// OverlayTests · "没变化就不重画"的判定（docs/接口约定.md §7.2）

import CoreGraphics
import DDMCore
import Foundation
import Testing
@testable import Overlay

@Suite("没变化就不重画")
struct ScenePlannerTests {
    private let display = Fixture.builtIn

    private func actions(_ slots: [ScenePlanner.Slot]) -> [ScenePlanner.Action] { slots.map(\.action) }

    @Test func 新出现的项要画_原样再来一遍不动() {
        var planner = ScenePlanner()
        let items = [Fixture.item(1, x: 100, y: 100), Fixture.item(2, x: 300, y: 100)]
        #expect(actions(planner.plan(items: items, on: display, canDraw: true)) == [.draw, .draw])
        #expect(actions(planner.plan(items: items, on: display, canDraw: true)) == [.keep, .keep])
        #expect(planner.count == 2)
    }

    @Test func 只有位置变了_只挪不画() throws {
        var planner = ScenePlanner()
        var item = Fixture.item(x: 100, y: 100)
        let drawn = try #require(planner.plan(items: [item], on: display, canDraw: true).first)
        item.rect = item.rect.offsetBy(dx: 30, dy: -10)
        let moved = try #require(planner.plan(items: [item], on: display, canDraw: true).first)
        #expect(moved.action == .move)
        #expect(moved.placement.pixelFrame.x == drawn.placement.pixelFrame.x + 60)
        #expect(moved.placement.pixelFrame.y == drawn.placement.pixelFrame.y - 20)
        #expect(moved.placement.pixelFrame.width == drawn.placement.pixelFrame.width)
        // 位置不再变：不动。
        #expect(actions(planner.plan(items: [item], on: display, canDraw: true)) == [.keep])
    }

    @Test func 内容版本号变了要重画() {
        var planner = ScenePlanner()
        var item = Fixture.item(x: 100, y: 100)
        _ = planner.plan(items: [item], on: display, canDraw: true)
        item.contentVersion += 1
        #expect(actions(planner.plan(items: [item], on: display, canDraw: true)) == [.draw])
        #expect(actions(planner.plan(items: [item], on: display, canDraw: true)) == [.keep])
    }

    @Test func 画布尺寸变了_即使版本号没变也要重画() {
        var planner = ScenePlanner()
        var item = Fixture.item(x: 100, y: 100)
        _ = planner.plan(items: [item], on: display, canDraw: true)

        item.outsets = EdgeOutsets(top: 8, left: 8, bottom: 40, right: 8)       // 外扩变了
        #expect(actions(planner.plan(items: [item], on: display, canDraw: true)) == [.draw])

        item.rect.size = CGSize(width: 96, height: 96)                          // 图标大小变了
        #expect(actions(planner.plan(items: [item], on: display, canDraw: true)) == [.draw])
    }

    @Test func 这一帧没有的项被移除_再出现时重新画() {
        var planner = ScenePlanner()
        let a = Fixture.item(1, x: 100, y: 100), b = Fixture.item(2, x: 300, y: 100)
        _ = planner.plan(items: [a, b], on: display, canDraw: true)
        let onlyB = planner.plan(items: [b], on: display, canDraw: true)
        #expect(onlyB.map(\.item.iconID) == [b.iconID])
        #expect(planner.count == 1)
        #expect(actions(planner.plan(items: [a, b], on: display, canDraw: true)) == [.draw, .keep])
    }

    @Test func 结果的顺序与清单一致_同一个key只认第一个() {
        var planner = ScenePlanner()
        let a = Fixture.item(1, x: 100, y: 100), b = Fixture.item(2, x: 300, y: 100), c = Fixture.item(3, x: 500, y: 100)
        let duplicate = Fixture.item(2, x: 700, y: 700)
        let slots = planner.plan(items: [c, b, duplicate, a], on: display, canDraw: true)
        #expect(slots.map(\.item.iconID.rawValue) == [3, 2, 1])
        #expect(slots[1].item.rect.minX == 300)
    }

    @Test func 桌面层和拖拽层是两块不同的画布() {
        var planner = ScenePlanner()
        let desktop = Fixture.item(1, x: 100, y: 100, layer: .desktop)
        let drag = Fixture.item(1, x: 100, y: 100, layer: .drag)
        #expect(actions(planner.plan(items: [desktop, drag], on: display, canDraw: true)) == [.draw, .draw])
    }

    @Test func 不在这块屏上的项不出现_挪进来时要画() {
        // 每块屏各有各的账本。
        var planner = ScenePlanner()
        var externalPlanner = ScenePlanner()
        var item = Fixture.item(x: -1000, y: 100)                // 在外接屏上
        #expect(planner.plan(items: [item], on: display, canDraw: true).isEmpty)
        #expect(actions(externalPlanner.plan(items: [item], on: Fixture.external, canDraw: true)) == [.draw])

        item.rect.origin.x = 100                                  // 挪到内屏
        #expect(actions(planner.plan(items: [item], on: display, canDraw: true)) == [.draw])
        #expect(externalPlanner.plan(items: [item], on: Fixture.external, canDraw: true).isEmpty)
        item.rect.origin.x = -1000                                // 又挪走
        #expect(planner.plan(items: [item], on: display, canDraw: true).isEmpty)
        #expect(planner.count == 0)
        #expect(actions(externalPlanner.plan(items: [item], on: Fixture.external, canDraw: true)) == [.draw])
    }

    @Test func 这块屏看不见时不画_欠着_看得见了补上() throws {
        var planner = ScenePlanner()
        var item = Fixture.item(x: 100, y: 100)

        // 新出现但屏看不见：欠着。
        #expect(actions(planner.plan(items: [item], on: display, canDraw: false)) == [.deferred])
        #expect(planner.hasDeferredDraws)
        // 看得见了：即使版本号没变也要画。
        #expect(actions(planner.plan(items: [item], on: display, canDraw: true)) == [.draw])
        #expect(!planner.hasDeferredDraws)

        // 画过之后屏又看不见，期间内容变了、位置也变了：欠着，但位置照挪（沿用旧图）。
        let drawn = try #require(planner.plan(items: [item], on: display, canDraw: true).first)
        item.contentVersion += 1
        item.rect = item.rect.offsetBy(dx: 10, dy: 0)
        let deferred = try #require(planner.plan(items: [item], on: display, canDraw: false).first)
        #expect(deferred.action == .deferred)
        #expect(deferred.placement.pixelFrame.x == drawn.placement.pixelFrame.x + 20)
        // 内容不再变也仍然欠着，直到看得见。
        #expect(actions(planner.plan(items: [item], on: display, canDraw: false)) == [.deferred])
        #expect(actions(planner.plan(items: [item], on: display, canDraw: true)) == [.draw])
        #expect(actions(planner.plan(items: [item], on: display, canDraw: true)) == [.keep])
    }

    @Test func 没画成的项下一帧再试() {
        var planner = ScenePlanner()
        let item = Fixture.item(x: 100, y: 100)
        _ = planner.plan(items: [item], on: display, canDraw: true)
        planner.markDrawFailed(item.key)
        #expect(actions(planner.plan(items: [item], on: display, canDraw: true)) == [.draw])
    }

    @Test func 一点一点地挪_误差不累积() throws {
        // 一倍屏上每帧挪 0.3 点，挪 10 次共 3 点：图层应当正好挪了 3 个像素，而不是 10 次取整的累加。
        var planner = ScenePlanner()
        var item = Fixture.item(x: Fixture.external.frame.minX + 100, y: Fixture.external.frame.minY + 100)
        let start = try #require(planner.plan(items: [item], on: Fixture.external, canDraw: true).first)
        var last = start
        for _ in 0..<10 {
            item.rect.origin.x += 0.3
            last = try #require(planner.plan(items: [item], on: Fixture.external, canDraw: true).first)
            #expect(last.action == .move || last.action == .keep)
        }
        #expect(last.placement.pixelFrame.x == start.placement.pixelFrame.x + 3)
    }

    @Test func 清空之后全部重画() {
        var planner = ScenePlanner()
        let items = [Fixture.item(1, x: 100, y: 100), Fixture.item(2, x: 300, y: 100)]
        _ = planner.plan(items: items, on: display, canDraw: true)
        planner.reset()
        #expect(actions(planner.plan(items: items, on: display, canDraw: true)) == [.draw, .draw])
    }
}
