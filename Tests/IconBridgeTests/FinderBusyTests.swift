// 访达没空回答时（典型情形：用户正拖着图标——实测访达在拖动期间完全不回应请求，一直卡到松手）
//
// 这里用假桌面模拟：`stopAnswering` 之后每个请求都"等满 15 秒然后超时"（假时钟往后拨，不真的等）；
// 也可以让某一个请求"等了很久，在松手那一刻答回来"（用 `before` 钩子拨时钟、改桌面）。

import CoreGraphics
import DDMCore
import Foundation
import Testing
@testable import IconBridge

@Suite("访达没空回答时")
struct FinderBusyTests {
    private let full = CycleRequest(kind: .full)
    private let quick = CycleRequest(kind: .quick)
    private let forced = CycleRequest(kind: .full, forced: true)

    private func twoFiles() -> FakeDesktop {
        FakeDesktop([
            .init(name: "甲", position: CGPoint(x: 300, y: 300)),
            .init(name: "乙", position: CGPoint(x: 500, y: 300)),
        ])
    }

    // MARK: 保留快照，不上报

    @Test func 快速检查没等到回答_快照和状态原样保留_不上报() {
        let clock = Fixture.Clock(1000)
        let desktop = twoFiles()
        var core = Fixture.core(desktop, clock: clock)
        let before = core.run(full).snapshot

        desktop.stopAnswering(clock: clock)        // 用户把图标拖起来了
        desktop.clearLog()
        let outcome = core.run(quick)
        #expect(outcome.finderWasBusy)
        #expect(outcome.update == nil)             // 不上报重载
        #expect(outcome.snapshot == before)        // 状态仍是"正常"，图标一个不少
        #expect(core.snapshot.status == .ok)
        #expect(core.snapshot.icons.count == 2)
        #expect(desktop.log == ["count"])          // 只有那一个没等到回答的请求
        #expect(outcome.stalledSeconds == 15)
    }

    @Test func 完整读取没等到回答_同样保留快照() {
        let clock = Fixture.Clock(1000)
        let desktop = twoFiles()
        var core = Fixture.core(desktop, clock: clock)
        let before = core.run(full).snapshot

        desktop.stopAnswering(clock: clock)
        let outcome = core.run(full)
        #expect(outcome.finderWasBusy)
        #expect(outcome.update == nil)
        #expect(outcome.snapshot == before)
    }

    @Test func 由立即刷新引发的读取没等到回答_也不上报_留给下一次() {
        let clock = Fixture.Clock(1000)
        let desktop = twoFiles()
        var core = Fixture.core(desktop, clock: clock)
        let before = core.run(full).snapshot
        desktop.stopAnswering(clock: clock)
        let outcome = core.run(forced)
        #expect(outcome.finderWasBusy)
        #expect(outcome.update == nil)
        #expect(outcome.snapshot == before)
    }

    @Test func 读到一半访达没空了_这一轮整个作废_有空之后照常比对() throws {
        let clock = Fixture.Clock(1000)
        let desktop = twoFiles()
        var core = Fixture.core(desktop, clock: clock)
        let before = core.run(full).snapshot

        desktop.add("丙", at: CGPoint(x: 700, y: 300))
        // 位置已经问完；问名字的时候访达没空了（用户恰好在这时拖起了一个图标）。
        desktop.before("names") { $0.stopAnswering(clock: clock) }
        let busy = core.run(full)
        #expect(busy.finderWasBusy)
        #expect(busy.update == nil)
        #expect(busy.snapshot == before)

        desktop.resumeAnswering()
        let update = try #require(core.run(full).update)
        #expect(!update.isReset)
        #expect(update.changes.count == 1)         // 仍然是"新增一个"，没有因为中途作废而变成整体重载
        if case let .added(icon) = update.changes[0] {
            #expect(icon.id == Fixture.id("丙"))
        } else {
            Issue.record("应当是新增事件")
        }
    }

    // MARK: 继续等、等到了

    @Test func 没等到回答之后_只让一个最便宜的请求去排队等() {
        let clock = Fixture.Clock(1000)
        let desktop = twoFiles()
        var core = Fixture.core(desktop, clock: clock)
        _ = core.run(full)
        desktop.stopAnswering(clock: clock)
        _ = core.run(full)                         // 第一次没等到（发的是完整读取的第一个请求）

        for _ in 0..<3 {
            clock.advance(0.2)
            desktop.clearLog()
            let outcome = core.run(full)           // 提供者让我们"再读一次"
            #expect(outcome.finderWasBusy)
            #expect(outcome.update == nil)
            #expect(desktop.log == ["count"])      // 实际只发了一个数个数的请求
        }
        #expect(core.snapshot.status == .ok)
        #expect(core.snapshot.icons.count == 2)
    }

    @Test func 访达一回答_马上完整读一遍_报出拖动的结果() throws {
        let clock = Fixture.Clock(1000)
        let desktop = twoFiles()
        var core = Fixture.core(desktop, clock: clock)
        _ = core.run(full)
        desktop.stopAnswering(clock: clock)
        _ = core.run(quick)                        // 没等到

        // 用户松手：这次等的请求被卡了 7 秒，在松手那一刻答回来，图标已经在新位置。
        desktop.resumeAnswering()
        clock.advance(0.2)
        desktop.before("count") {
            $0.move("甲", to: CGPoint(x: 900, y: 600))
            clock.advance(7)
        }
        let answeredAt = clock.now + 7
        let outcome = core.run(full)
        let update = try #require(outcome.update)
        #expect(!outcome.finderWasBusy)
        #expect(!update.isReset)
        guard case let .moved(from, to) = try #require(update.changes.first), update.changes.count == 1 else {
            Issue.record("应当只有一个移动事件")
            return
        }
        #expect(from.imageRect.center == CGPoint(x: 300, y: 300))
        #expect(to.imageRect.center == CGPoint(x: 900, y: 600))
        #expect(update.snapshot.capturedAt == answeredAt)   // "读取开始的时刻"是访达回答之后，不是卡住之前
    }

    @Test func 快速检查被卡了很久才得到回答_即使个数没变也当场完整读一遍() throws {
        let clock = Fixture.Clock(1000)
        let desktop = twoFiles()
        var core = Fixture.core(desktop, clock: clock)
        _ = core.run(full)

        // 还没超时：数个数的请求发出去 7 秒后（松手那一刻）才答回来。个数没变，但图标挪了地方。
        desktop.before("count") {
            $0.move("甲", to: CGPoint(x: 900, y: 600))
            clock.advance(7)
        }
        let outcome = core.run(quick)
        #expect(outcome.performedFullRead)
        #expect(outcome.stalledSeconds == 7)
        let update = try #require(outcome.update)
        guard case .moved = try #require(update.changes.first) else {
            Issue.record("应当是移动事件")
            return
        }
        #expect(outcome.startedAt == 1000)                  // 周期是 1000 开始的
        #expect(update.snapshot.capturedAt == 1007)         // 完整读取是访达回答之后才开始的
    }

    @Test func 正常快慢的快速检查_个数没变就到此为止() {
        let clock = Fixture.Clock(1000)
        let desktop = twoFiles()
        var core = Fixture.core(desktop, clock: clock)
        _ = core.run(full)
        desktop.before("count") { _ in clock.advance(0.3) }   // 慢了一点，但没到"卡住"的程度
        let outcome = core.run(quick)
        #expect(!outcome.performedFullRead)
        #expect(outcome.stalledSeconds == 0)
        #expect(outcome.update == nil)
    }

    // MARK: 什么时候才算"不可用"

    @Test func 连续五分钟一个请求都不回答_才报访达不可用_恢复后整体重载() throws {
        let clock = Fixture.Clock(1000)
        let desktop = twoFiles()
        var core = Fixture.core(desktop, clock: clock)
        _ = core.run(full)
        desktop.stopAnswering(clock: clock)

        // 每一轮等满 15 秒，中间隔 0.2 秒。
        var updates: [(at: TimeInterval, update: IconUpdate)] = []
        while clock.now < 1000 + 400 {
            if let update = core.run(full).update {
                updates.append((clock.now, update))
            }
            clock.advance(0.2)
        }
        #expect(updates.count == 1)                              // 只上报了一次
        let reported = try #require(updates.first)
        #expect(reported.update.snapshot.status == .finderUnavailable)
        #expect(reported.update.snapshot.icons.isEmpty)
        #expect(reported.update.isReset)
        #expect(reported.at >= 1300 && reported.at < 1320)       // 第一个没等到回答的请求发出后满 5 分钟

        desktop.resumeAnswering()
        let back = try #require(core.run(full).update)
        #expect(back.isReset)
        #expect(back.snapshot.status == .ok)
        #expect(back.snapshot.icons.count == 2)
    }

    @Test func 四分多钟没回答_之后回答了_全程没有清空过快照() throws {
        let clock = Fixture.Clock(1000)
        let desktop = twoFiles()
        var core = Fixture.core(desktop, clock: clock)
        _ = core.run(full)
        desktop.stopAnswering(clock: clock)
        while clock.now < 1000 + 280 {
            let outcome = core.run(full)
            #expect(outcome.update == nil)
            #expect(outcome.snapshot.status == .ok)
            #expect(outcome.snapshot.icons.count == 2)
            clock.advance(0.2)
        }
        desktop.resumeAnswering()
        desktop.move("乙", to: CGPoint(x: 520, y: 340))
        let update = try #require(core.run(full).update)
        #expect(!update.isReset)
        #expect(update.changes.count == 1)
    }

    @Test func 等待期间访达进程没了_立刻报不可用_不用等五分钟() throws {
        let clock = Fixture.Clock(1000)
        let desktop = twoFiles()
        var core = Fixture.core(desktop, clock: clock)
        _ = core.run(full)
        desktop.stopAnswering(clock: clock)
        #expect(core.run(quick).update == nil)

        desktop.everyCall = nil
        desktop.error = .processNotFound                         // 访达退出了
        let update = try #require(core.run(full).update)
        #expect(update.snapshot.status == .finderUnavailable)
        #expect(update.snapshot.icons.isEmpty)
        #expect(clock.now < 1000 + 60)
    }

    @Test func 启动后第一次读取就没等到回答_保持启动中_不上报_回答后正常开始() throws {
        let clock = Fixture.Clock(1000)
        let desktop = twoFiles()
        desktop.stopAnswering(clock: clock)
        var core = Fixture.core(desktop, clock: clock)

        for _ in 0..<3 {
            let outcome = core.run(full)
            #expect(outcome.finderWasBusy)
            #expect(outcome.update == nil)
            #expect(outcome.snapshot.status == .starting)        // 没有上一份快照可留：就停在"启动中"，什么都不画
            #expect(outcome.snapshot.icons.isEmpty)
            clock.advance(0.2)
        }

        desktop.resumeAnswering()
        let update = try #require(core.run(full).update)
        #expect(update.isReset)
        #expect(update.snapshot.status == .ok)
        #expect(update.snapshot.icons.count == 2)
    }

    // MARK: 废纸篓：拖了很久才扔

    @Test func 拖着图标四十多秒才扔进废纸篓_仍然给出进了废纸篓() throws {
        let clock = Fixture.Clock(1000)
        let desktop = twoFiles()
        var core = Fixture.core(desktop, clock: clock)
        _ = core.run(full)                         // 废纸篓 0 项
        clock.advance(1)
        #expect(core.run(quick).update == nil)

        desktop.stopAnswering(clock: clock)        // 拖起来了
        #expect(core.run(quick).finderWasBusy)     // 等满 15 秒
        clock.advance(0.2)
        #expect(core.run(full).finderWasBusy)      // 又等满 15 秒
        clock.advance(0.2)

        // 第三次等了 12 秒，用户松手——图标进了废纸篓。此时距上一次读到废纸篓计数已经过去 43 秒多。
        desktop.resumeAnswering()
        desktop.before("count") {
            $0.moveToTrash("甲")
            clock.advance(12)
        }
        let update = try #require(core.run(full).update)
        guard case let .removed(icon, trashed) = try #require(update.changes.first) else {
            Issue.record("应当是消失事件")
            return
        }
        #expect(icon.id == Fixture.id("甲"))
        #expect(trashed == .yes)                   // 访达不回答的那四十多秒不算进基准的"年龄"
    }

    @Test func 一次很久的等待之后扔进废纸篓_同样给出进了废纸篓() throws {
        let clock = Fixture.Clock(1000)
        let desktop = twoFiles()
        var core = Fixture.core(desktop, clock: clock)
        _ = core.run(full)
        clock.advance(2)

        // 数个数的请求被卡了 25 秒，松手时答回来（个数少了一个）。
        desktop.before("count") {
            $0.moveToTrash("甲")
            clock.advance(25)
        }
        let update = try #require(core.run(quick).update)
        guard case let .removed(_, trashed) = try #require(update.changes.first) else {
            Issue.record("应当是消失事件")
            return
        }
        #expect(trashed == .yes)
    }

    @Test func 只是隔得久_访达并没有卡住_旧的计数照样过期() throws {
        let clock = Fixture.Clock(1000)
        let desktop = twoFiles()
        desktop.trash = ["甲"]                      // 废纸篓里有同名旧物
        var core = Fixture.core(desktop, clock: clock)
        _ = core.run(full)
        clock.advance(25)                          // 这 25 秒访达随时能回答，只是我们没去读
        desktop.trash = ["甲", "别的东西"]
        desktop.remove("甲")
        let update = try #require(core.run(full).update)
        guard case let .removed(_, trashed) = try #require(update.changes.first) else {
            Issue.record("应当是消失事件")
            return
        }
        #expect(trashed == .unknown)               // 扣掉的只是"访达不回答"的时间，不是所有时间
    }

    @Test func 查废纸篓时访达没空了_这一轮不算数_有空之后重新给出结论() throws {
        let clock = Fixture.Clock(1000)
        let desktop = twoFiles()
        var core = Fixture.core(desktop, clock: clock)
        let before = core.run(full).snapshot

        clock.advance(1)
        desktop.moveToTrash("甲")
        // 桌面已经读完，正要查废纸篓里有没有它——访达没空了。
        desktop.before("trashContains") { $0.stopAnswering(clock: clock) }
        let busy = core.run(full)
        #expect(busy.finderWasBusy)
        #expect(busy.update == nil)
        #expect(busy.snapshot == before)           // 没有草率地报一个"消失，不确定"

        desktop.resumeAnswering()
        clock.advance(0.2)
        let update = try #require(core.run(full).update)
        guard case let .removed(_, trashed) = try #require(update.changes.first), update.changes.count == 1 else {
            Issue.record("应当只有一个消失事件")
            return
        }
        #expect(trashed == .yes)
    }

    @Test func 查废纸篓时访达没空了_立刻停手_不再接着发别的问题去排队() {
        let clock = Fixture.Clock(1000)
        let desktop = FakeDesktop((0..<6).map { .init(name: "文件\($0)", position: CGPoint(x: 100 + $0 * 100, y: 300)) })
        var core = Fixture.core(desktop, clock: clock)
        _ = core.run(full)
        for index in 0..<4 { desktop.moveToTrash("文件\(index)") }   // 四个一起进了废纸篓
        desktop.before("trashContains") { $0.stopAnswering(clock: clock) }
        desktop.clearLog()
        let outcome = core.run(full)
        #expect(outcome.finderWasBusy)
        #expect(outcome.update == nil)
        #expect(desktop.log.filter { $0 == "trashContains" }.count == 1)   // 第一问没等到回答，后面三个就不问了
        #expect(desktop.log.suffix(2) == ["trashContains", "count"])        // 只用最便宜的问题探了一下访达
    }

    // MARK: 访达能回答，只是某些问题问不动

    @Test func 数个数能答_别的问题却一直超时_五分钟的界线照样生效() throws {
        let clock = Fixture.Clock(1000)
        let desktop = twoFiles()
        var core = Fixture.core(desktop, clock: clock)
        _ = core.run(full)

        // "每个图标的位置"这一问每次都等满 15 秒超时；数个数照常回答。
        desktop.fail("positions", with: .timeout)
        desktop.everyCall = { call in if call == "positions" { clock.advance(15) } }
        var updates: [(at: TimeInterval, update: IconUpdate)] = []
        while clock.now < 1000 + 400 {
            if let update = core.run(full).update {
                updates.append((clock.now, update))
            }
            clock.advance(0.2)
        }
        #expect(updates.count == 1)                              // 不会因为"数个数能答"就一次次重新起算、永远到不了
        let reported = try #require(updates.first)
        #expect(reported.update.snapshot.status == .finderUnavailable)
        #expect(reported.at >= 1300 && reported.at < 1320)
    }

    @Test func 只有废纸篓问不动_不拖累读取_一阵子之内不再去问() throws {
        let clock = Fixture.Clock(1000)
        let desktop = twoFiles()
        // 废纸篓的两个问题每次都等满 15 秒超时（例如废纸篓里东西极多）；别的照常回答。
        desktop.fail("trashCount", with: .timeout)
        desktop.fail("trashContains", with: .timeout)
        desktop.everyCall = { call in if call.hasPrefix("trash") { clock.advance(15) } }
        var core = Fixture.core(desktop, clock: clock)

        let first = core.run(full)
        #expect(!first.finderWasBusy)
        #expect(first.update?.snapshot.status == .ok)            // 照常读到了图标
        #expect(first.update?.snapshot.icons.count == 2)
        #expect(desktop.log.suffix(2) == ["trashCount", "count"])   // 废纸篓超时后，用数个数探了一下：访达是有空的

        clock.advance(8)
        desktop.clearLog()
        desktop.remove("甲")
        let update = try #require(core.run(full).update)
        #expect(!desktop.log.contains { $0.hasPrefix("trash") })   // 两分钟之内不再问废纸篓，不白等
        guard case let .removed(_, trashed) = try #require(update.changes.first) else {
            Issue.record("应当是消失事件")
            return
        }
        #expect(trashed == .unknown)

        clock.advance(130)                                       // 过了两分钟，再试一次
        desktop.clearLog()
        _ = core.run(full)
        #expect(desktop.log.contains("trashCount"))
        #expect(core.snapshot.status == .ok)
    }

    @Test func 查某个图标在不在废纸篓时问不动_其余的不再问_都给不确定() throws {
        let clock = Fixture.Clock(1000)
        let desktop = FakeDesktop((0..<5).map { .init(name: "文件\($0)", position: CGPoint(x: 100 + $0 * 100, y: 300)) })
        var core = Fixture.core(desktop, clock: clock)
        _ = core.run(full)
        for index in 0..<3 { desktop.remove("文件\(index)") }
        desktop.fail("trashContains", with: .timeout)
        desktop.everyCall = { call in if call == "trashContains" { clock.advance(15) } }
        desktop.clearLog()
        let outcome = core.run(full)
        let update = try #require(outcome.update)
        #expect(!outcome.finderWasBusy)
        #expect(update.snapshot.status == .ok)
        #expect(update.changes.count == 3)
        #expect(update.changes.allSatisfy { if case .removed(_, .unknown) = $0 { return true } else { return false } })
        #expect(desktop.log.filter { $0 == "trashContains" }.count == 1)
    }

    // MARK: 其它边角

    @Test func 停止读取的那段时间不算访达没回答() {
        let clock = Fixture.Clock(1000)
        let desktop = twoFiles()
        var core = Fixture.core(desktop, clock: clock)
        _ = core.run(full)
        desktop.stopAnswering(clock: clock)
        #expect(core.run(quick).finderWasBusy)     // 停止读取之前的最后一轮：访达没空

        clock.advance(600)                         // 桌面被挡住，停读了十分钟
        let outcome = core.run(CycleRequest(kind: .full, resumed: true))   // 恢复时访达碰巧又没空
        #expect(outcome.finderWasBusy)
        #expect(outcome.update == nil)             // 不会因为"算起来已经十分钟没回答"而立刻报不可用
        #expect(outcome.snapshot.status == .ok)
    }

    @Test func 完整读取读到一半被卡住_访达回答后从头重读一遍() throws {
        let clock = Fixture.Clock(1000)
        let desktop = twoFiles()
        var core = Fixture.core(desktop, clock: clock)
        _ = core.run(full)

        // 位置刚问完，用户把图标拖起来了；问名字的那一问被卡了 7 秒，松手时答回来（名字没变，但位置已经变了）。
        desktop.before("names") {
            $0.move("甲", to: CGPoint(x: 900, y: 600))
            clock.advance(7)
        }
        desktop.clearLog()
        let outcome = core.run(full)
        let update = try #require(outcome.update)
        guard case let .moved(_, to) = try #require(update.changes.first) else {
            Issue.record("应当是移动事件")
            return
        }
        #expect(to.imageRect.center == CGPoint(x: 900, y: 600))   // 没有把卡住之前读到的旧位置当成结果
        #expect(update.snapshot.capturedAt == 1007)               // 以重读开始的时刻为准
        #expect(desktop.log.filter { $0 == "positions" }.count == 2)
        #expect(outcome.stalledSeconds == 7)
    }

    @Test func 图标很多的桌面_访达回答得慢是正常的_不当成卡住() {
        let clock = Fixture.Clock(1000)
        let desktop = FakeDesktop((0..<300).map { .init(name: "文件\($0)", position: CGPoint(x: $0 * 3, y: 300)) })
        var core = Fixture.core(desktop, clock: clock)
        _ = core.run(full)

        desktop.everyCall = { call in if call == "positions" || call == "names" { clock.advance(2) } }   // 300 个图标，一问 2 秒
        desktop.clearLog()
        let outcome = core.run(full)
        #expect(outcome.stalledSeconds == 0)       // 门槛随图标数放宽到 3 秒
        #expect(outcome.wasRoutineRead)            // 仍然拿它来估计"平时要花多久"
        #expect(desktop.log.filter { $0 == "positions" }.count == 1)   // 也没有因此重读

        desktop.everyCall = { call in if call == "count" { clock.advance(5) } }   // 5 秒才是卡住
        #expect(core.run(CycleRequest(kind: .quick)).stalledSeconds == 5)
    }

    @Test func 查废纸篓时作废的那一轮_什么都没提前记下() throws {
        let clock = Fixture.Clock(1000)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let desktop = FakeDesktop([
            .init(name: "甲", position: CGPoint(x: 300, y: 300), modified: date),
            .init(name: "乙", position: CGPoint(x: 500, y: 300), modified: date),
        ])
        var core = Fixture.core(desktop, clock: clock)
        let before = core.run(full).snapshot

        clock.advance(1)
        desktop.moveToTrash("甲")
        desktop.before("trashContains") { $0.stopAnswering(clock: clock) }
        #expect(core.run(full).finderWasBusy)      // 这一轮读过修改时间（名字变了），但整轮作废

        // 访达有空之前，文件又被放回了原处：桌面和最初一模一样。
        desktop.resumeAnswering()
        desktop.trash = []
        desktop.add("甲", at: CGPoint(x: 300, y: 300), modified: date)
        clock.advance(0.2)
        let outcome = core.run(full)
        #expect(outcome.update == nil)             // 没有任何变化可报
        #expect(outcome.snapshot.icons == before.icons)
        #expect(outcome.snapshot.icon(withID: Fixture.id("甲"))?.modifiedAt == date)   // 修改时间没有被那一轮弄丢
        #expect(outcome.snapshot.revision == before.revision)
    }
}

@Suite("访达没空时的轮询节奏")
struct FinderBusyScheduleTests {
    private func outcome(
        full: Bool, at start: TimeInterval, duration: TimeInterval = 0.01,
        busy: Bool = false, stalled: TimeInterval = 0, routine: Bool = true
    ) -> CycleOutcome {
        var outcome = CycleOutcome(
            snapshot: IconSnapshot(icons: [], status: .ok, capturedAt: start, revision: 1),
            update: nil, performedFullRead: full, startedAt: start, duration: duration, requestCount: full ? 4 : 1
        )
        outcome.finderWasBusy = busy
        outcome.stalledSeconds = stalled
        outcome.wasRoutineRead = full && routine && !busy
        return outcome
    }

    @Test func 没等到回答之后很快再去等_与节奏无关() throws {
        var schedule = PollSchedule()
        schedule.record(outcome(full: true, at: 100))
        schedule.record(outcome(full: false, at: 101, duration: 15, busy: true, stalled: 15))
        var next = try #require(schedule.next(pace: .active))
        #expect(abs(next.at - 116.2) < 1e-9)
        next = try #require(schedule.next(pace: .idle))
        #expect(abs(next.at - 116.2) < 1e-9)
        #expect(schedule.next(pace: .suspended) == nil)
    }

    @Test func 访达回答之后回到平常的节奏_卡住的那段时间不算进耗时() throws {
        var schedule = PollSchedule()
        schedule.record(outcome(full: true, at: 100))
        schedule.record(outcome(full: false, at: 101, duration: 15, busy: true, stalled: 15))
        // 第二次等了 10 秒得到回答，接着完整读了 0.1 秒。
        schedule.record(outcome(full: true, at: 116.2, duration: 10.1, stalled: 10, routine: false))
        let next = try #require(schedule.next(pace: .active))
        #expect(next.kind == .quick)
        #expect(abs(next.at - 127.2) < 1e-9)        // 从访达回答的那一刻（126.2）算起 1 秒，而不是被 10 秒的等待拉长
    }

    @Test func 被卡住的快速检查不拿来估计平时的耗时() throws {
        var schedule = PollSchedule()
        schedule.record(outcome(full: true, at: 100))
        schedule.record(outcome(full: false, at: 101, duration: 7, stalled: 7))   // 卡了 7 秒才答（108 回答）
        let next = try #require(schedule.next(pace: .idle))
        #expect(next.kind == .quick)
        // 从访达回答的那一刻算起，仍是空闲档平常的 5 秒；如果把那 7 秒当成"平时的耗时"，间隔会被拉长到 20 秒。
        #expect(abs(next.at - 113) < 1e-9)
    }
}
