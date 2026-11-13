// 核心状态机：一个读取周期里的全部行为

import CoreGraphics
import DDMCore
import Foundation
import Testing
@testable import IconBridge

@Suite("读取周期")
struct BridgeCoreTests {
    private let full = CycleRequest(kind: .full)
    private let quick = CycleRequest(kind: .quick)
    private let forced = CycleRequest(kind: .full, forced: true)

    private func twoFiles() -> FakeDesktop {
        FakeDesktop([
            .init(name: "甲", position: CGPoint(x: 300, y: 300), modified: Date(timeIntervalSince1970: 1_700_000_000)),
            .init(name: "乙", classCode: FinderCode.classFolder, position: CGPoint(x: -960, y: 400)),
        ])
    }

    // MARK: 第一次读取

    @Test func 启动前是空快照_状态为启动中() {
        let core = Fixture.core(twoFiles())
        #expect(core.snapshot.icons.isEmpty)
        #expect(core.snapshot.status == .starting)
        #expect(core.snapshot.revision == 0)
    }

    @Test func 第一次读取是整体重载_图标的各个字段都对() throws {
        let clock = Fixture.Clock(1000)
        var core = Fixture.core(twoFiles(), clock: clock)
        let outcome = core.run(full)
        let update = try #require(outcome.update)
        #expect(update.isReset)
        #expect(update.changes.isEmpty)
        #expect(update.snapshot.status == .ok)
        #expect(update.snapshot.revision == 1)
        #expect(update.snapshot.capturedAt == 1000)
        #expect(update.snapshot.icons.count == 2)

        let file = try #require(update.snapshot.icon(withID: Fixture.id("甲")))
        #expect(file.kind == .file)
        #expect(file.imageRect == CGRect(x: 268, y: 268, width: 64, height: 64))
        #expect(file.labelRect == CGRect(x: 300 - 7.5, y: 339, width: 15, height: 16))   // 1 个字 × 7 点 + 留白 8
        #expect(file.displayID == Fixture.mainDisplay.id)
        #expect(file.modifiedAt == Date(timeIntervalSince1970: 1_700_000_000))

        let folder = try #require(update.snapshot.icon(withID: Fixture.id("乙")))
        #expect(folder.kind == .folder)
        #expect(folder.imageRect.center == CGPoint(x: -960, y: 400))
        #expect(folder.displayID == Fixture.externalDisplay.id)
        #expect(folder.modifiedAt == nil)
    }

    @Test func 快照里的图标按编号排序_编号互不相同() {
        let desktop = FakeDesktop((0..<30).map { .init(name: "文件\($0)", position: CGPoint(x: 100 + $0 * 10, y: 100)) })
        var core = Fixture.core(desktop)
        let icons = core.run(full).snapshot.icons
        #expect(icons.count == 30)
        #expect(icons.map(\.id.rawValue) == icons.map(\.id.rawValue).sorted())
        #expect(Set(icons.map(\.id)).count == 30)
    }

    @Test func 磁盘和同名文件是两个不同的图标() {
        let desktop = FakeDesktop([
            .init(name: "同名", position: CGPoint(x: 100, y: 100)),
            .init(name: "同名", classCode: FinderCode.classDisk, position: CGPoint(x: 300, y: 100)),
        ])
        var core = Fixture.core(desktop)
        let icons = core.run(full).snapshot.icons
        #expect(icons.count == 2)
        #expect(Set(icons.map(\.kind)) == [.file, .volume])
    }

    // MARK: 没有变化

    @Test func 定时读取没有变化时不上报_但缓存的快照记下了新的读取时刻() {
        let clock = Fixture.Clock(1000)
        var core = Fixture.core(twoFiles(), clock: clock)
        _ = core.run(full)
        clock.advance(2)
        let outcome = core.run(full)
        #expect(outcome.update == nil)
        #expect(outcome.performedFullRead)
        #expect(outcome.wasRoutineRead)
        #expect(outcome.snapshot.revision == 1)
        #expect(outcome.snapshot.capturedAt == 1002)
    }

    @Test func 立即刷新即使没有变化也上报一次_版本号不变_读取时刻更新() throws {
        let clock = Fixture.Clock(1000)
        var core = Fixture.core(twoFiles(), clock: clock)
        _ = core.run(full)
        clock.advance(0.5)
        let update = try #require(core.run(forced).update)
        #expect(!update.isReset)
        #expect(update.changes.isEmpty)
        #expect(update.snapshot.revision == 1)
        #expect(update.snapshot.capturedAt == 1000.5)
    }

    @Test func 快速检查_个数没变就只问一个问题() {
        let desktop = twoFiles()
        var core = Fixture.core(desktop)
        _ = core.run(full)
        desktop.clearLog()
        let outcome = core.run(quick)
        #expect(desktop.log == ["count"])
        #expect(outcome.update == nil)
        #expect(!outcome.performedFullRead)
        #expect(outcome.requestCount == 1)
    }

    @Test func 快速检查不更新读取时刻_因为它没有重读位置() {
        let clock = Fixture.Clock(1000)
        var core = Fixture.core(twoFiles(), clock: clock)
        _ = core.run(full)
        clock.advance(0.5)
        #expect(core.run(quick).snapshot.capturedAt == 1000)
    }

    @Test func 快速检查_个数变了当场升级为完整读取() throws {
        let desktop = twoFiles()
        var core = Fixture.core(desktop)
        _ = core.run(full)
        desktop.add("丙", at: CGPoint(x: 500, y: 300))
        let outcome = core.run(quick)
        #expect(outcome.performedFullRead)
        #expect(try #require(outcome.update).changes.count == 1)
    }

    @Test func 第一次还没读过时_快速检查也做完整读取() {
        var core = Fixture.core(twoFiles())
        let outcome = core.run(quick)
        #expect(outcome.performedFullRead)
        #expect(outcome.update?.isReset == true)
    }

    // MARK: 变化事件

    @Test func 新建文件报新增() throws {
        let desktop = twoFiles()
        var core = Fixture.core(desktop)
        _ = core.run(full)
        desktop.add("丙", at: CGPoint(x: 500, y: 300), classCode: FinderCode.classApplicationFile)
        let outcome = core.run(full)
        let update = try #require(outcome.update)
        #expect(!update.isReset)
        #expect(outcome.foundChanges)
        #expect(update.snapshot.revision == 2)
        guard case let .added(icon) = try #require(update.changes.first), update.changes.count == 1 else {
            Issue.record("应当只有一个新增事件")
            return
        }
        #expect(icon.id == Fixture.id("丙"))
        #expect(icon.kind == .application)
        #expect(icon.imageRect.center == CGPoint(x: 500, y: 300))
    }

    @Test func 改位置报移动_带着旧样子和新样子() throws {
        let desktop = twoFiles()
        var core = Fixture.core(desktop)
        _ = core.run(full)
        desktop.move("甲", to: CGPoint(x: -500, y: 600))
        let update = try #require(core.run(full).update)
        guard case let .moved(from, to) = try #require(update.changes.first), update.changes.count == 1 else {
            Issue.record("应当只有一个移动事件")
            return
        }
        #expect(from.id == Fixture.id("甲") && to.id == Fixture.id("甲"))
        #expect(from.imageRect.center == CGPoint(x: 300, y: 300))
        #expect(to.imageRect.center == CGPoint(x: -500, y: 600))
        #expect(from.displayID == Fixture.mainDisplay.id)
        #expect(to.displayID == Fixture.externalDisplay.id)   // 从主屏挪到了外接屏
    }

    @Test func 直接删除报消失_没进废纸篓() throws {
        let desktop = twoFiles()
        var core = Fixture.core(desktop)
        _ = core.run(full)
        desktop.remove("甲")
        let update = try #require(core.run(full).update)
        guard case let .removed(icon, trashed) = try #require(update.changes.first), update.changes.count == 1 else {
            Issue.record("应当只有一个消失事件")
            return
        }
        #expect(icon.id == Fixture.id("甲"))
        #expect(icon.imageRect.center == CGPoint(x: 300, y: 300))   // 消失前最后的位置
        #expect(trashed == .no)
        #expect(update.snapshot.icons.count == 1)
    }

    @Test func 经访达移入废纸篓报消失加进了废纸篓() throws {
        let desktop = twoFiles()
        var core = Fixture.core(desktop)
        _ = core.run(full)
        desktop.moveToTrash("甲")
        let update = try #require(core.run(full).update)
        guard case let .removed(icon, trashed) = try #require(update.changes.first) else {
            Issue.record("应当是消失事件")
            return
        }
        #expect(icon.id == Fixture.id("甲"))
        #expect(trashed == .yes)
    }

    @Test func 废纸篓里早就有同名旧物_文件被挪去别处_不算进废纸篓() throws {
        let desktop = twoFiles()
        desktop.trash = ["甲"]              // 上周删过一个同名的
        var core = Fixture.core(desktop)
        _ = core.run(full)
        desktop.remove("甲")                // 这次是被挪进了某个文件夹
        let update = try #require(core.run(full).update)
        guard case let .removed(_, trashed) = try #require(update.changes.first) else {
            Issue.record("应当是消失事件")
            return
        }
        #expect(trashed == .no)
    }

    @Test func 废纸篓变多了但找不到同名项目_稍等再查一次仍没有_给不确定() throws {
        let desktop = twoFiles()
        var core = Fixture.core(desktop)
        _ = core.run(full)
        desktop.remove("甲")
        desktop.trash = ["别的东西"]          // 同一时间别处有东西进了废纸篓
        desktop.clearLog()
        let update = try #require(core.run(full).update)
        guard case let .removed(_, trashed) = try #require(update.changes.first) else {
            Issue.record("应当是消失事件")
            return
        }
        #expect(trashed == .unknown)
        #expect(desktop.log.filter { $0 == "trashContains" }.count == 2)   // 查了两次
    }

    @Test func 访达登记废纸篓慢了半拍_再查一次就查到了() throws {
        let desktop = twoFiles()
        var core = Fixture.core(desktop)
        _ = core.run(full)
        desktop.remove("甲")
        desktop.trash = ["别的东西"]
        // 第二次按名字查之前，它才出现在废纸篓里。
        desktop.before("trashContains", occurrence: 2) { $0.trash = ["别的东西", "甲"] }
        let update = try #require(core.run(full).update)
        guard case let .removed(_, trashed) = try #require(update.changes.first) else {
            Issue.record("应当是消失事件")
            return
        }
        #expect(trashed == .yes)
    }

    @Test func 桌面先少了一项_废纸篓晚一步才登记_稍等再查就查到了() throws {
        let desktop = twoFiles()
        var core = Fixture.core(desktop)
        _ = core.run(full)
        desktop.remove("甲")               // 桌面的列表里已经没有它了，废纸篓里还没出现
        // 重查时（这个周期里第二次问废纸篓计数之前）它才进了废纸篓。
        desktop.before("trashCount", occurrence: 2) { $0.trash = ["甲"] }
        let update = try #require(core.run(full).update)
        guard case let .removed(_, trashed) = try #require(update.changes.first) else {
            Issue.record("应当是消失事件")
            return
        }
        #expect(trashed == .yes)
    }

    @Test func 废纸篓先多了一项_桌面晚一步才消失_中间隔了一次读取_仍判为是() throws {
        let clock = Fixture.Clock(1000)
        let desktop = twoFiles()
        var core = Fixture.core(desktop, clock: clock)
        _ = core.run(full)                 // 废纸篓 0 项

        clock.advance(0.2)
        desktop.trash = ["甲"]             // 访达已经把它登记进废纸篓，但桌面的列表里还有它
        #expect(core.run(forced).update?.changes.isEmpty == true)   // 这次读取看到废纸篓 1 项、桌面没变

        clock.advance(0.2)
        desktop.remove("甲")               // 现在才从桌面的列表里消失
        let update = try #require(core.run(forced).update)
        guard case let .removed(_, trashed) = try #require(update.changes.first) else {
            Issue.record("应当是消失事件")
            return
        }
        #expect(trashed == .yes)           // 基准取最近几秒里最小的计数（0），所以仍然看得出"变多了"
    }

    @Test func 几秒之前就在废纸篓里的同名旧物不算刚进去的() throws {
        let clock = Fixture.Clock(1000)
        let desktop = twoFiles()
        var core = Fixture.core(desktop, clock: clock)
        _ = core.run(full)                 // 废纸篓 0 项

        clock.advance(10)
        desktop.trash = ["甲"]             // 别处的一个同名文件进了废纸篓
        _ = core.run(full)                 // 废纸篓 1 项

        clock.advance(10)                  // 过了很久
        _ = core.run(full)
        clock.advance(1)
        desktop.remove("甲")               // 桌面上的这个被挪进了文件夹
        let update = try #require(core.run(full).update)
        guard case let .removed(_, trashed) = try #require(update.changes.first) else {
            Issue.record("应当是消失事件")
            return
        }
        #expect(trashed == .no)
    }

    @Test func 多个图标同时消失_不管几个只稍等一次() throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() { lock.withLock { value += 1 } }
            var count: Int { lock.withLock { value } }
        }
        let sleeps = Counter()
        let desktop = FakeDesktop((0..<6).map { .init(name: "文件\($0)", position: CGPoint(x: 100 + $0 * 100, y: 300)) })
        var core = BridgeCore(
            source: desktop, identity: IconIdentity(salt: Fixture.salt),
            layoutProvider: { Fixture.layout }, clock: { 0 }, sleep: { _ in sleeps.increment() }, measureText: { _, _ in 10 }
        )
        _ = core.run(full)
        for index in 0..<5 { desktop.remove("文件\(index)") }   // 五个一起被挪进了某个文件夹
        let update = try #require(core.run(full).update)
        #expect(update.changes.count == 5)
        #expect(update.changes.allSatisfy { if case .removed(_, .no) = $0 { return true } else { return false } })
        #expect(sleeps.count == 1)
    }

    @Test func 确认进了废纸篓的不用再等() throws {
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            func set() { lock.withLock { value = true } }
            var isSet: Bool { lock.withLock { value } }
        }
        let slept = Flag()
        let desktop = twoFiles()
        var core = BridgeCore(
            source: desktop, identity: IconIdentity(salt: Fixture.salt),
            layoutProvider: { Fixture.layout }, clock: { 0 }, sleep: { _ in slept.set() }, measureText: { _, _ in 10 }
        )
        _ = core.run(full)
        desktop.moveToTrash("甲")
        let update = try #require(core.run(full).update)
        #expect(update.changes.count == 1)
        #expect(!slept.isSet)
    }

    @Test func 基准太老就不当基准_同名旧物加上别处的删除不会被误判成进了废纸篓() throws {
        let clock = Fixture.Clock(1000)
        let desktop = twoFiles()
        desktop.trash = ["甲"]                       // 废纸篓里早就有一个同名的旧物
        var core = Fixture.core(desktop, clock: clock)
        _ = core.run(full)                           // 废纸篓 1 项

        clock.advance(30)                            // 半分钟里没有完整读取（空闲节奏）
        desktop.trash = ["甲", "别的东西"]             // 期间别处有东西进了废纸篓
        desktop.remove("甲")                         // 桌面上的这个其实是被挪进了文件夹
        let update = try #require(core.run(full).update)
        guard case let .removed(_, trashed) = try #require(update.changes.first) else {
            Issue.record("应当是消失事件")
            return
        }
        #expect(trashed == .unknown)                 // 半分钟前的计数不可靠：不敢说"是"
    }

    @Test func 从停止读取恢复时_之前的废纸篓计数作废() throws {
        let clock = Fixture.Clock(1000)
        let desktop = twoFiles()
        var core = Fixture.core(desktop, clock: clock)
        _ = core.run(full)                           // 废纸篓 0 项

        clock.advance(1)
        desktop.trash = ["乙"]                       // 停止读取期间：别处一个同名的东西进了废纸篓
        _ = core.run(CycleRequest(kind: .full, resumed: true))   // 恢复：废纸篓 1 项

        clock.advance(1)
        desktop.remove("乙")                         // 桌面上的这个被挪进了文件夹
        let update = try #require(core.run(full).update)
        guard case let .removed(_, trashed) = try #require(update.changes.first) else {
            Issue.record("应当是消失事件")
            return
        }
        #expect(trashed == .no)                      // 不拿恢复之前的 0 项当基准
    }

    @Test func 重查时读到的废纸篓计数被记作新的基准() throws {
        let clock = Fixture.Clock(1000)
        let desktop = twoFiles()
        var core = Fixture.core(desktop, clock: clock)
        _ = core.run(full)                           // 废纸篓 0 项
        desktop.remove("甲")
        desktop.before("trashCount", occurrence: 2) { $0.trash = ["甲"] }   // 重查时才登记进去
        _ = core.run(full)                           // 这一轮最后看到的是 1 项

        clock.advance(10)
        desktop.remove("乙")                         // 另一个图标被挪进了文件夹；废纸篓没变
        let update = try #require(core.run(full).update)
        guard case let .removed(_, trashed) = try #require(update.changes.first) else {
            Issue.record("应当是消失事件")
            return
        }
        #expect(trashed == .no)                      // 基准是 1 项，没有变多
    }

    @Test func 两个同名的磁盘各有各的图标() {
        let desktop = FakeDesktop([
            .init(name: "同名盘", classCode: FinderCode.classDisk, position: CGPoint(x: 1400, y: 100)),
            .init(name: "同名盘", classCode: FinderCode.classDisk, position: CGPoint(x: 1400, y: 220)),
        ])
        var core = Fixture.core(desktop)
        let icons = core.run(full).snapshot.icons
        #expect(icons.count == 2)
        #expect(Set(icons.map(\.id)).count == 2)
        #expect(icons.allSatisfy { $0.kind == .volume })
    }

    @Test func 显示器排列变了_快速检查就能发现_不用等完整读取() throws {
        let layouts = Fixture.Layouts()
        let desktop = twoFiles()
        var core = Fixture.core(desktop, layouts: layouts)
        _ = core.run(full)
        #expect(core.run(quick).update == nil)

        layouts.current = DisplayLayout(displays: [Fixture.mainDisplay])   // 外接屏拔掉了；图标个数没变
        let outcome = core.run(quick)
        #expect(outcome.performedFullRead)
        let update = try #require(outcome.update)
        #expect(update.isReset)
        #expect(update.snapshot.icon(withID: Fixture.id("乙"))?.displayID == nil)
    }

    @Test func 磁盘被推出_报消失_不去查废纸篓() throws {
        let desktop = FakeDesktop([.init(name: "移动硬盘", classCode: FinderCode.classDisk, position: CGPoint(x: 1400, y: 100))])
        var core = Fixture.core(desktop)
        #expect(core.run(full).snapshot.icons.first?.kind == .volume)
        desktop.remove("移动硬盘")
        desktop.clearLog()
        let update = try #require(core.run(full).update)
        #expect(update.changes == [.removed(DesktopIcon(
            id: Fixture.id("移动硬盘", isVolume: true), kind: .volume,
            imageRect: CGRect(x: 1368, y: 68, width: 64, height: 64),
            labelRect: CGRect(x: 1400 - 18, y: 139, width: 36, height: 16),
            displayID: Fixture.mainDisplay.id
        ), trashed: .no)])
        #expect(!desktop.log.contains("trashContains"))
    }

    @Test func 改名是旧的消失加新的出现() throws {
        let desktop = twoFiles()
        var core = Fixture.core(desktop)
        _ = core.run(full)
        desktop.rename("甲", to: "甲改")
        let update = try #require(core.run(full).update)
        #expect(update.changes.count == 2)
        guard case let .removed(old, trashed) = update.changes[0], case let .added(new) = update.changes[1] else {
            Issue.record("应当是先消失、后新增")
            return
        }
        #expect(old.id == Fixture.id("甲") && new.id == Fixture.id("甲改"))
        #expect(trashed == .no)
        #expect(old.imageRect == new.imageRect)
    }

    @Test func 名字没变而种类变了_定期重读时跟上_不发事件() throws {
        let clock = Fixture.Clock(1000)
        let desktop = twoFiles()
        var core = Fixture.core(desktop, clock: clock)
        _ = core.run(full)
        var items = desktop.items
        items[items.firstIndex { $0.name == "甲" }!].classCode = FinderCode.classApplicationFile
        desktop.items = items

        clock.advance(61)   // 到了定期重读修改时间（顺带重读类）的时候
        let update = try #require(core.run(full).update)
        #expect(update.changes.isEmpty)
        #expect(!update.isReset)
        #expect(update.snapshot.icon(withID: Fixture.id("甲"))?.kind == .application)
    }

    @Test func 修改时间定期重读_变了就更新快照但不发事件() throws {
        let clock = Fixture.Clock(1000)
        let desktop = twoFiles()
        var core = Fixture.core(desktop, clock: clock)
        _ = core.run(full)

        var items = desktop.items
        let newDate = Date(timeIntervalSince1970: 1_800_000_000)
        items[items.firstIndex { $0.name == "甲" }!].modified = newDate
        desktop.items = items

        clock.advance(30)   // 还没到重读修改时间的时候
        #expect(core.run(full).update == nil)

        clock.advance(31)   // 超过 60 秒
        let update = try #require(core.run(full).update)
        #expect(update.changes.isEmpty)
        #expect(!update.isReset)
        #expect(update.snapshot.revision == 2)
        #expect(update.snapshot.icon(withID: Fixture.id("甲"))?.modifiedAt == newDate)
    }

    // MARK: 整体重载

    @Test func 外观设置变了是整体重载_所有矩形一起变_没有变化事件() throws {
        let desktop = twoFiles()
        var core = Fixture.core(desktop)
        _ = core.run(full)
        desktop.options = DesktopViewOptions(appearance: DesktopAppearance(iconSize: 96, textSize: 14, labelPosition: .right))
        let update = try #require(core.run(full).update)
        #expect(update.isReset)
        #expect(update.changes.isEmpty)
        #expect(update.snapshot.appearance == DesktopAppearance(iconSize: 96, textSize: 14, labelPosition: .right))
        let icon = try #require(update.snapshot.icon(withID: Fixture.id("甲")))
        #expect(icon.imageRect == CGRect(x: 252, y: 252, width: 96, height: 96))
        #expect(icon.labelRect?.minX == icon.imageRect.maxX + 6)
        #expect(update.snapshot.revision == 2)
    }

    @Test func 显示器排列变了是整体重载_所在显示器重新判断() throws {
        let layouts = Fixture.Layouts()
        var core = Fixture.core(twoFiles(), layouts: layouts)
        let first = core.run(full)
        #expect(first.snapshot.icon(withID: Fixture.id("乙"))?.displayID == Fixture.externalDisplay.id)

        layouts.current = DisplayLayout(displays: [Fixture.mainDisplay])   // 外接屏拔掉了
        let update = try #require(core.run(full).update)
        #expect(update.isReset)
        #expect(update.changes.isEmpty)
        #expect(update.snapshot.icon(withID: Fixture.id("乙"))?.displayID == nil)
    }

    @Test func 显示器全都睡了_所在显示器判断不出_图像矩形照常() throws {
        var core = Fixture.core(twoFiles(), layouts: Fixture.Layouts(DisplayLayout(displays: [])))
        let snapshot = core.run(full).snapshot
        #expect(snapshot.status == .ok)
        #expect(snapshot.icons.allSatisfy { $0.displayID == nil })
        #expect(snapshot.icon(withID: Fixture.id("甲"))?.imageRect.center == CGPoint(x: 300, y: 300))
    }

    @Test func 从停止读取恢复后的第一次读取是整体重载_哪怕期间有图标变化() throws {
        let desktop = twoFiles()
        var core = Fixture.core(desktop)
        _ = core.run(full)
        desktop.remove("甲")
        desktop.add("丙", at: CGPoint(x: 500, y: 300))
        let update = try #require(core.run(CycleRequest(kind: .full, resumed: true)).update)
        #expect(update.isReset)
        #expect(update.changes.isEmpty)        // 不把它们当成"新来的"和"不见了的"
        #expect(update.snapshot.icons.count == 2)
    }

    @Test func 恢复后的整体重载即使内容没变也上报_但版本号不变() throws {
        var core = Fixture.core(twoFiles())
        let before = core.run(full).snapshot
        let update = try #require(core.run(CycleRequest(kind: .quick, resumed: true)).update)
        #expect(update.isReset)
        #expect(update.snapshot.revision == before.revision)   // 只是重读了一遍，内容没变
        #expect(update.snapshot.icons == before.icons)
    }

    @Test func 显示器排列变了但每个图标的归属没变_整体重载_版本号不变() throws {
        let layouts = Fixture.Layouts(DisplayLayout(displays: [Fixture.mainDisplay]))
        let desktop = FakeDesktop([.init(name: "甲", position: CGPoint(x: 300, y: 300))])
        var core = Fixture.core(desktop, layouts: layouts)
        let before = core.run(full).snapshot
        layouts.current = Fixture.layout   // 接上了外接屏；主屏上的图标不受影响
        let update = try #require(core.run(full).update)
        #expect(update.isReset)
        #expect(update.snapshot.revision == before.revision)
    }

    @Test func 重新启动后回到初始状态_编号不变() throws {
        var core = Fixture.core(twoFiles())
        let before = core.run(full).snapshot
        let outcome = core.run(CycleRequest(kind: .full, restart: true))
        let update = try #require(outcome.update)
        #expect(update.isReset)
        #expect(update.snapshot.revision > before.revision)   // 版本号接着往上数，不从头再来
        #expect(update.snapshot.icons.map(\.id) == before.icons.map(\.id))
    }

    // MARK: 状态

    @Test func 用户拒绝授权_快照为空_状态明确_不去读桌面() throws {
        let desktop = twoFiles()
        desktop.authorizationState = .denied
        var core = Fixture.core(desktop)
        let outcome = core.run(full)
        let update = try #require(outcome.update)
        #expect(update.isReset)
        #expect(update.snapshot.status == .permissionDenied)
        #expect(update.snapshot.icons.isEmpty)
        #expect(!update.snapshot.status.isUsable)
        #expect(desktop.log == ["authorization"])   // 没有发任何读取请求
    }

    @Test func 读取途中被拒绝授权_错误码负1743_清空快照() throws {
        let desktop = twoFiles()
        var core = Fixture.core(desktop)
        _ = core.run(full)
        desktop.error = FinderError(code: -1743)
        let update = try #require(core.run(full).update)
        #expect(update.isReset)
        #expect(update.changes.isEmpty)   // 不给"不见了"的图标发消失事件
        #expect(update.snapshot.status == .permissionDenied)
        #expect(update.snapshot.icons.isEmpty)
        #expect(update.snapshot.revision == 2)
    }

    @Test func 被拒绝之后重复失败不再上报_用户重新允许后整体重载() throws {
        let desktop = twoFiles()
        desktop.authorizationState = .denied
        var core = Fixture.core(desktop)
        _ = core.run(full)
        #expect(core.run(full).update == nil)
        #expect(core.run(quick).update == nil)

        desktop.authorizationState = .granted   // 用户在系统设置里打开了开关
        let update = try #require(core.run(full).update)
        #expect(update.isReset)
        #expect(update.snapshot.status == .ok)
        #expect(update.snapshot.icons.count == 2)
    }

    @Test func 还没问过用户_弹窗期间保持启动中_用户允许后正常读取() throws {
        let desktop = twoFiles()
        desktop.authorizationState = .wouldPrompt
        desktop.answerWhenAsked = .granted
        var core = Fixture.core(desktop)
        #expect(core.snapshot.status == .starting)
        let update = try #require(core.run(full).update)
        #expect(desktop.log.prefix(2) == ["authorization", "authorization(ask)"])
        #expect(update.snapshot.status == .ok)
    }

    @Test func 还没问过用户_用户在弹窗里拒绝() throws {
        let desktop = twoFiles()
        desktop.authorizationState = .wouldPrompt
        desktop.answerWhenAsked = .denied
        var core = Fixture.core(desktop)
        let update = try #require(core.run(full).update)
        #expect(update.snapshot.status == .permissionDenied)
        #expect(update.snapshot.icons.isEmpty)
    }

    @Test func 访达没在运行_快照为空_恢复后整体重载() throws {
        let desktop = twoFiles()
        var core = Fixture.core(desktop)
        _ = core.run(full)

        desktop.error = .processNotFound
        let down = try #require(core.run(full).update)
        #expect(down.isReset)
        #expect(down.snapshot.status == .finderUnavailable)
        #expect(down.snapshot.icons.isEmpty)

        desktop.authorizationState = .finderNotRunning
        #expect(core.run(full).update == nil)   // 还是不可用：不重复上报

        desktop.error = nil
        desktop.authorizationState = .granted
        let up = try #require(core.run(full).update)
        #expect(up.isReset)
        #expect(up.changes.isEmpty)
        #expect(up.snapshot.status == .ok)
        #expect(up.snapshot.icons.count == 2)
        #expect(up.snapshot.revision == 3)
    }

    @Test func 快速检查时访达出错_交给完整读取定性() throws {
        let desktop = twoFiles()
        var core = Fixture.core(desktop)
        _ = core.run(full)
        desktop.error = .connectionInvalid
        let outcome = core.run(quick)
        #expect(outcome.performedFullRead)
        #expect(try #require(outcome.update).snapshot.status == .finderUnavailable)
    }

    @Test func 桌面开启了叠放_快照为空_状态明确() throws {
        let desktop = twoFiles()
        var core = Fixture.core(desktop)
        _ = core.run(full)
        desktop.stacks = true
        desktop.clearLog()
        let update = try #require(core.run(full).update)
        #expect(update.isReset)
        #expect(update.snapshot.status == .stacksEnabled)
        #expect(update.snapshot.icons.isEmpty)
        #expect(desktop.log.isEmpty)   // 位置反正不可靠，不必去读

        desktop.stacks = false
        let back = try #require(core.run(full).update)
        #expect(back.isReset)
        #expect(back.snapshot.status == .ok)
        #expect(back.snapshot.icons.count == 2)
    }

    @Test func 状态异常时立即刷新也回调一次_读取时刻更新() throws {
        let clock = Fixture.Clock(1000)
        let desktop = twoFiles()
        desktop.authorizationState = .denied
        var core = Fixture.core(desktop, clock: clock)
        _ = core.run(full)
        clock.advance(3)
        let update = try #require(core.run(forced).update)
        #expect(update.snapshot.status == .permissionDenied)
        #expect(update.snapshot.capturedAt == 1003)
        #expect(!update.isReset)
    }

    @Test func 读数拼不出一致的结果时_保留旧快照_不上报_要求尽快重读() {
        let desktop = twoFiles()
        var core = Fixture.core(desktop)
        let before = core.run(full).snapshot
        desktop.add("丙", at: CGPoint(x: 500, y: 300))
        for occurrence in 2...8 {
            desktop.before("names", occurrence: occurrence) { $0.add("新\(occurrence)", at: CGPoint(x: 600, y: 300)) }
        }
        let outcome = core.run(forced)
        #expect(outcome.wasInconsistent)
        #expect(outcome.update == nil)
        #expect(outcome.snapshot == before)
    }

    @Test func 废纸篓查不了不影响读取_只是消失的图标得到不确定() throws {
        /// 除了废纸篓的两个问题一律失败，其余照常回答。
        final class TrashBroken: DesktopQuerying, @unchecked Sendable {
            let base: FakeDesktop
            init(_ base: FakeDesktop) { self.base = base }
            func authorization(askUser: Bool) -> FinderAuthorization { base.authorization(askUser: askUser) }
            func itemCount() throws(FinderError) -> Int { try base.itemCount() }
            func positions() throws(FinderError) -> [CGPoint] { try base.positions() }
            func names() throws(FinderError) -> [String] { try base.names() }
            func classCodes() throws(FinderError) -> [FourCharCode] { try base.classCodes() }
            func modificationDates() throws(FinderError) -> [Date?] { try base.modificationDates() }
            func viewOptions() throws(FinderError) -> DesktopViewOptions { try base.viewOptions() }
            func trashItemCount() throws(FinderError) -> Int { throw .noSuchObject }
            func trashContains(name: String) throws(FinderError) -> Bool { throw .noSuchObject }
            func stacksEnabled() -> Bool? { nil }
        }
        let desktop = twoFiles()
        var core = BridgeCore(
            source: TrashBroken(desktop), identity: IconIdentity(salt: Fixture.salt),
            layoutProvider: { Fixture.layout }, clock: { 0 }, sleep: { _ in }, measureText: { _, _ in 10 }
        )
        #expect(core.run(full).snapshot.status == .ok)
        desktop.moveToTrash("甲")
        let update = try #require(core.run(full).update)
        #expect(update.snapshot.status == .ok)
        guard case let .removed(_, trashed) = try #require(update.changes.first) else {
            Issue.record("应当是消失事件")
            return
        }
        #expect(trashed == .unknown)
    }

    @Test func 版本号_只有内容变了才加一() {
        let desktop = twoFiles()
        var core = Fixture.core(desktop)
        #expect(core.run(full).snapshot.revision == 1)
        #expect(core.run(full).snapshot.revision == 1)
        #expect(core.run(forced).snapshot.revision == 1)
        desktop.move("甲", to: CGPoint(x: 310, y: 300))
        #expect(core.run(full).snapshot.revision == 2)
        #expect(core.run(quick).snapshot.revision == 2)
    }

    @Test func 周期的耗时和请求数被如实记录() {
        let clock = Fixture.Clock(1000)
        let desktop = twoFiles()
        desktop.before("names") { _ in clock.advance(0.05) }
        var core = Fixture.core(desktop, clock: clock)
        let outcome = core.run(full)
        #expect(outcome.startedAt == 1000)
        #expect(abs(outcome.duration - 0.05) < 1e-9)
        #expect(outcome.requestCount == 8)   // 位置、名字、类、修改时间、位置、名字、显示选项、废纸篓计数
    }
}
