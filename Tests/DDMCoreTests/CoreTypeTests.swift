// DDMCore 里带逻辑的共享类型的测试：几何、省电信号、图标、拖拽、表情状态、随机数。

import CoreGraphics
import Foundation
import Testing
@testable import DDMCore

private func makeIcon(_ raw: UInt64, x: CGFloat = 100, y: CGFloat = 100, label: Bool = true) -> DesktopIcon {
    let imageRect = CGRect(x: x, y: y, width: 64, height: 64)
    // 标签在图标下方、比图标宽：x 方向各多出 20 点。
    let labelRect = label ? CGRect(x: x - 20, y: y + 68, width: 104, height: 16) : nil
    return DesktopIcon(id: IconID(rawValue: raw), kind: .file, imageRect: imageRect, labelRect: labelRect)
}

private func makeSnapshot(_ icons: [DesktopIcon], revision: UInt64 = 1) -> IconSnapshot {
    IconSnapshot(icons: icons, status: .ok, capturedAt: 0, revision: revision)
}

@Suite("几何")
struct GeometryTests {
    @Test func 外扩按y向下的方向理解() {
        let rect = CGRect(x: 100, y: 100, width: 64, height: 64)
        let expanded = rect.expanded(by: EdgeOutsets(top: 10, left: 2, bottom: 30, right: 4))
        // top 让上边缘（minY）变小，bottom 让下边缘（maxY）变大。
        #expect(expanded == CGRect(x: 98, y: 90, width: 70, height: 104))
        #expect(rect.expanded(by: .zero) == rect)
        #expect(rect.expanded(by: EdgeOutsets(all: 8)) == rect.insetBy(dx: -8, dy: -8))
    }

    @Test func 外扩逐边取大() {
        let a = EdgeOutsets(top: 1, left: 5, bottom: 3, right: 0)
        let b = EdgeOutsets(top: 4, left: 2, bottom: 3, right: 7)
        #expect(a.union(b) == EdgeOutsets(top: 4, left: 5, bottom: 3, right: 7))
    }

    @Test func 点到矩形的距离() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        #expect(rect.distance(to: CGPoint(x: 50, y: 25)) == 0)
        #expect(rect.distance(to: CGPoint(x: 100, y: 50)) == 0)
        #expect(rect.distance(to: CGPoint(x: 130, y: 25)) == 30)
        #expect(rect.distance(to: CGPoint(x: 50, y: -20)) == 20)
        #expect(rect.distance(to: CGPoint(x: 103, y: 54)) == 5)
        #expect(rect.center == CGPoint(x: 50, y: 25))
    }

    @Test func 点与向量的小运算() {
        let a = CGPoint(x: 10, y: 20)
        let b = CGPoint(x: 13, y: 24)
        #expect(a.distance(to: b) == 5)
        #expect(b.offset(from: a) == CGVector(dx: 3, dy: 4))
        #expect(a.moved(by: CGVector(dx: 3, dy: 4)) == b)
        #expect(CGVector(dx: 3, dy: 4).length == 5)
        #expect(CGVector(dx: 3, dy: -4).negated == CGVector(dx: -3, dy: 4))
    }
}

@Suite("时间与省电信号")
struct TimeTests {
    @Test func 取最紧的需求() {
        #expect(FrameDemand.idle.merged(with: .idle) == .idle)
        #expect(FrameDemand.idle.merged(with: .by(5)) == .by(5))
        #expect(FrameDemand.by(5).merged(with: .idle) == .by(5))
        #expect(FrameDemand.by(5).merged(with: .by(3)) == .by(3))
        #expect(FrameDemand.by(5).merged(with: .continuous) == .continuous)
        #expect(FrameDemand.continuous.merged(with: .idle) == .continuous)
        #expect(FrameDemand.continuous.isContinuous)
        #expect(!FrameDemand.by(1).isContinuous)
    }

    @Test func 两个时钟一起往后推() {
        let start = FrameTime(monotonic: 100, wallClock: Date(timeIntervalSince1970: 1000))
        let later = start.advanced(by: 0.5)
        #expect(later.monotonic == 100.5)
        #expect(later.wallClock == Date(timeIntervalSince1970: 1000.5))
    }

    @Test func 当前时间的单调时钟只增不减() {
        let first = FrameTime.now()
        let second = FrameTime.now()
        #expect(second.monotonic >= first.monotonic)
        #expect(first.monotonic > 0)
    }
}

@Suite("图标")
struct IconTests {
    @Test func 编号的短形式是末八位十六进制() {
        #expect(IconID(rawValue: 0xABCD_EF01_3FA9_1C02).description == "icon#3fa91c02")
        #expect(IconID(rawValue: 1).description == "icon#00000001")
        #expect("\(IconID(rawValue: 0))" == "icon#00000000")
    }

    @Test func 长相种子稳定且相邻编号差别很大() {
        let one = IconID(rawValue: 1).faceSeed
        #expect(one == IconID(rawValue: 1).faceSeed)
        let two = IconID(rawValue: 2).faceSeed
        // 相邻编号的种子应有大量比特不同（打散得好的话约 32 个）。
        #expect((one ^ two).nonzeroBitCount > 16)
    }

    @Test func 命中测试认图像和标签但不认两者外接矩形的空角() {
        let icon = makeIcon(1)
        #expect(icon.hitTest(CGPoint(x: 132, y: 132)))   // 图像中心
        #expect(icon.hitTest(CGPoint(x: 85, y: 175)))    // 标签左端（图像之外）
        #expect(!icon.hitTest(CGPoint(x: 85, y: 110)))   // 图像左侧的空角：在外接矩形里，但点不中
        #expect(icon.hitBounds.contains(CGPoint(x: 85, y: 110)))
        #expect(icon.hitBounds == CGRect(x: 80, y: 100, width: 104, height: 84))
        // 没有标签时，可点击区域就是图像矩形。
        let bare = makeIcon(2, label: false)
        #expect(bare.hitBounds == bare.imageRect)
        #expect(!bare.hitTest(CGPoint(x: 85, y: 175)))
    }

    @Test func 快照按编号和按位置找图标() {
        let snapshot = makeSnapshot([makeIcon(1, x: 100), makeIcon(2, x: 300)])
        #expect(snapshot.icon(withID: IconID(rawValue: 2))?.imageRect.minX == 300)
        #expect(snapshot.icon(withID: IconID(rawValue: 9)) == nil)
        #expect(snapshot.icon(at: CGPoint(x: 310, y: 110))?.id == IconID(rawValue: 2))
        #expect(snapshot.icon(at: CGPoint(x: 250, y: 110)) == nil)
    }

    @Test func 变化事件说的是哪个图标() {
        let icon = makeIcon(7)
        #expect(IconChange.added(icon).iconID == icon.id)
        #expect(IconChange.removed(icon, trashed: .yes).iconID == icon.id)
        #expect(IconChange.moved(from: icon, to: makeIcon(7, x: 500)).iconID == icon.id)
    }

    @Test func 只有正常状态可以画脸() {
        #expect(IconProviderStatus.ok.isUsable)
        for status in IconProviderStatus.allCases where status != .ok {
            #expect(!status.isUsable)
        }
        #expect(IconSnapshot.empty().status == .starting)
        #expect(IconSnapshot.empty().icons.isEmpty)
    }

    @Test func 合并上报时变化事件按顺序接起来() {
        let a = makeIcon(1), b = makeIcon(2, x: 300)
        let first = IconUpdate(snapshot: makeSnapshot([a], revision: 1), changes: [.added(a)])
        let second = IconUpdate(snapshot: makeSnapshot([a, b], revision: 2), changes: [.added(b)])
        let merged = first.merging(second)
        #expect(merged.snapshot.revision == 2)
        #expect(merged.changes == [.added(a), .added(b)])
        #expect(!merged.isReset)
    }

    @Test func 合并里只要有一次整体重载结果就是整体重载且不带变化事件() {
        let a = makeIcon(1)
        let reset = IconUpdate(snapshot: makeSnapshot([a], revision: 1), isReset: true)
        let change = IconUpdate(snapshot: makeSnapshot([], revision: 2), changes: [.removed(a, trashed: .yes)])
        for merged in [reset.merging(change), change.merging(reset)] {
            #expect(merged.isReset)
            #expect(merged.changes.isEmpty)
        }
        #expect(reset.merging(change).snapshot.revision == 2)
        #expect(change.merging(reset).snapshot.revision == 1)
        // 构造时就保证：整体重载不带变化事件。
        #expect(IconUpdate(snapshot: makeSnapshot([a]), changes: [.added(a)], isReset: true).changes.isEmpty)
    }

    @Test func 没变化的更新() {
        let snapshot = makeSnapshot([makeIcon(1)])
        let update = IconUpdate.unchanged(snapshot)
        #expect(update.snapshot == snapshot)
        #expect(update.changes.isEmpty)
        #expect(!update.isReset)
    }
}

@Suite("交互事实")
struct InteractionTests {
    @Test func 拖影矩形等于鼠标位置减抓取偏移() {
        let origin = CGRect(x: 100, y: 100, width: 64, height: 64)
        // 按在图标图像的 (20, 30) 处，然后把鼠标拖到 (500, 400)。
        let drag = DragState(
            iconID: IconID(rawValue: 1),
            grabOffset: CGVector(dx: 20, dy: 30),
            originImageRect: origin,
            position: CGPoint(x: 500, y: 400),
            startedAt: 0
        )
        #expect(drag.currentImageRect == CGRect(x: 480, y: 370, width: 64, height: 64))
    }

    @Test func 鼠标速率与按键集合() {
        let mouse = MouseState(velocity: CGVector(dx: 300, dy: -400))
        #expect(mouse.speed == 500)
        let buttons: MouseButtons = [.left, .right]
        #expect(buttons.contains(.left))
        #expect(!buttons.contains(.other))
    }

    @Test func 默认的交互事实是什么都没发生() {
        let time = FrameTime(monotonic: 1, wallClock: Date(timeIntervalSince1970: 0))
        let facts = InteractionFacts(time: time)
        #expect(facts.hover == nil && facts.drag == nil && facts.trash == nil)
        #expect(facts.dragOutcomes.isEmpty && facts.deletions.isEmpty && facts.releasedDrags.isEmpty)
        #expect(!facts.wantsIconRefresh)
        #expect(facts.demand == .idle)
    }
}

@Suite("表情状态")
struct FaceStateTests {
    @Test func 默认是一张平静的脸且所有强度为零() {
        let state = FaceState(seed: 1)
        #expect(state.mood == .calm)
        #expect(state.isValid)
        for parameter in FaceState.unitParameters {
            #expect(state[keyPath: parameter.keyPath] == 0, "\(parameter.name) 默认应为 0")
        }
    }

    @Test func 参数表覆盖了全部十二个强度参数() {
        let names = FaceState.unitParameters.map(\.name)
        #expect(names.count == 12)
        #expect(Set(names).count == 12)
        // 每个键路径都指向不同的字段：逐个设成 1，其它应保持 0。
        for parameter in FaceState.unitParameters {
            var state = FaceState(seed: 1)
            state[keyPath: parameter.keyPath] = 1
            let ones = FaceState.unitParameters.filter { state[keyPath: $0.keyPath] == 1 }
            #expect(ones.map(\.name) == [parameter.name])
        }
    }

    @Test func 越界和非数字会被夹回合法范围() {
        var state = FaceState(seed: 1)
        state.fear = 1.7
        state.blush = -0.2
        state.tears = .nan
        state.sleepiness = 0.6
        state.gazeTarget = CGVector(dx: CGFloat.infinity, dy: 3)
        #expect(!state.isValid)

        let clamped = state.clamped()
        #expect(clamped.isValid)
        #expect(clamped.fear == 1)
        #expect(clamped.blush == 0)
        #expect(clamped.tears == 0)
        #expect(clamped.sleepiness == 0.6)
        #expect(clamped.gazeTarget == .zero)
        #expect(clamped.seed == 1)
    }

    @Test func 一共八种情绪() {
        #expect(FaceMood.allCases.count == 8)
    }
}

@Suite("可复现的随机数")
struct SeededRandomTests {
    @Test func 与SplitMix64的公开参考值一致() {
        // 种子 0 的前三个输出是 SplitMix64 广为引用的参考值。
        var rng = SeededRandom(seed: 0)
        #expect(rng.next() == 0xE220_A839_7B1D_CDAF)
        #expect(rng.next() == 0x6E78_9E6A_A1B9_65F4)
        #expect(rng.next() == 0x06C4_5D18_8009_454F)
    }

    @Test func 同样的种子产生同样的序列() {
        var a = SeededRandom(seed: 42)
        var b = SeededRandom(seed: 42)
        var c = SeededRandom(seed: 43)
        let fromA = (0..<50).map { _ in a.next() }
        let fromB = (0..<50).map { _ in b.next() }
        let fromC = (0..<50).map { _ in c.next() }
        #expect(fromA == fromB)
        #expect(fromA != fromC)
    }

    @Test func 小数落在零到一之间且分布大致均匀() {
        var rng = SeededRandom(seed: 7)
        let values = (0..<10_000).map { _ in rng.nextUnit() }
        #expect(values.allSatisfy { $0 >= 0 && $0 < 1 })
        let mean = values.reduce(0, +) / Double(values.count)
        #expect(abs(mean - 0.5) < 0.02)
    }

    @Test func 可用于标准库的随机接口() {
        var a = SeededRandom(seed: 9)
        var b = SeededRandom(seed: 9)
        #expect(Int.random(in: 0..<1000, using: &a) == Int.random(in: 0..<1000, using: &b))
    }

    @Test func 派生的子种子互不相同且稳定() {
        let seed: UInt64 = 123
        #expect(SeededRandom.derive(seed, stream: 0) == SeededRandom.derive(seed, stream: 0))
        #expect(SeededRandom.derive(seed, stream: 0) != SeededRandom.derive(seed, stream: 1))
        #expect(SeededRandom.derive(seed, stream: 0) != SeededRandom.derive(seed + 1, stream: 0))
    }
}
