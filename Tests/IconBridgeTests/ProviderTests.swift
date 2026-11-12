// 图标提供者（主线程上的那层外壳）：线程、回调时机、立即刷新、暂停与恢复
//
// 这些测试要等后台队列把读取做完再回到主线程，所以用"等到条件成立或超时"的方式，
// 不依赖具体的耗时。桌面是假的，不碰访达。

import CoreGraphics
import DDMCore
import Foundation
import Testing
@testable import IconBridge

@MainActor
@Suite("图标提供者")
struct ProviderTests {
    /// 记下收到的上报。
    final class Collector {
        var updates: [IconUpdate] = []
        var offMainThread = 0
        var cycles: [IconBridgeCycleReport] = []
    }

    /// 不会自己轮询的节奏：间隔长到测试期间不会触发，用来单独观察 start / refreshNow 的行为。
    private var noPolling: PollingPolicy {
        var policy = PollingPolicy()
        policy.active = .init(quickInterval: 1000, fullInterval: 1000, quickDutyLimit: 1, fullDutyLimit: 1, recoveryInterval: 1000)
        policy.idle = policy.active
        policy.followUpDelays = []
        policy.minForcedSpacing = 0
        return policy
    }

    /// 很快的轮询：每 20 毫秒快速检查、每 60 毫秒完整读取。
    private var fastPolling: PollingPolicy {
        var policy = PollingPolicy()
        policy.active = .init(quickInterval: 0.02, fullInterval: 0.06, quickDutyLimit: 1, fullDutyLimit: 1, recoveryInterval: 0.03)
        policy.idle = policy.active
        policy.followUpDelays = []
        policy.minForcedSpacing = 0
        return policy
    }

    private func desktop() -> FakeDesktop {
        FakeDesktop([
            .init(name: "甲", position: CGPoint(x: 300, y: 300)),
            .init(name: "乙", position: CGPoint(x: 500, y: 300)),
        ])
    }

    private func makeProvider(_ desktop: FakeDesktop, policy: PollingPolicy, pause: PauseSwitch = PauseSwitch()) -> (DesktopIconProvider, Collector) {
        let core = BridgeCore(
            source: desktop,
            identity: IconIdentity(salt: Fixture.salt),
            layoutProvider: { Fixture.layout },
            sleep: { _ in },
            measureText: { text, _ in CGFloat(text.count) * 7 }
        )
        let provider = DesktopIconProvider(pause: pause, core: core, policy: policy)
        let collector = Collector()
        provider.onUpdate = { update in
            if !Thread.isMainThread { collector.offMainThread += 1 }
            collector.updates.append(update)
        }
        provider.onCycle = { collector.cycles.append($0) }
        return (provider, collector)
    }

    /// 等到条件成立；超时返回 false。
    private func wait(_ timeout: TimeInterval = 3, until condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            if ProcessInfo.processInfo.systemUptime > deadline { return false }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return true
    }

    /// 干等一小会儿，用来确认"没有发生"。
    private func settle(_ seconds: TimeInterval = 0.15) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    @Test func 启动前是空快照() {
        let (provider, _) = makeProvider(desktop(), policy: noPolling)
        #expect(provider.snapshot.icons.isEmpty)
        #expect(provider.status == .starting)
        #expect(provider.appearance == .finderDefault)
    }

    @Test func 默认构造方式可用_不带参数() {
        // 应用入口就是这样构造的（接口约定 §11）。只构造、不启动，所以不会向访达发请求。
        let provider = DesktopIconProvider(identityStorage: .ephemeral)
        #expect(provider.status == .starting)
        let conforming: any IconProviding = provider
        #expect(conforming.snapshot.revision == 0)
    }

    @Test func 第一次上报是整体重载_在主线程回调_读取不在主线程() async {
        let desktop = desktop()
        let (provider, collector) = makeProvider(desktop, policy: noPolling)
        provider.start()
        #expect(await wait { !collector.updates.isEmpty })
        provider.stop()

        #expect(collector.updates.count == 1)
        #expect(collector.updates[0].isReset)
        #expect(collector.updates[0].snapshot.icons.count == 2)
        #expect(collector.offMainThread == 0)
        #expect(desktop.mainThreadCalls == 0)
        #expect(desktop.log.count >= 6)
        #expect(provider.snapshot == collector.updates[0].snapshot)
        #expect(provider.status == .ok)
    }

    @Test func 各个方法立即返回_不等读取做完() async {
        let desktop = desktop()
        desktop.delay = 0.05   // 每个请求 50 毫秒：一次读取要几百毫秒
        let (provider, collector) = makeProvider(desktop, policy: noPolling)

        let before = ProcessInfo.processInfo.systemUptime
        provider.start()
        provider.refreshNow()
        provider.setPollingPace(.idle)
        let elapsed = ProcessInfo.processInfo.systemUptime - before
        #expect(elapsed < 0.04, "start / refreshNow / setPollingPace 应当立即返回，实际用了 \(elapsed) 秒")
        #expect(collector.updates.isEmpty)   // 读取还在后台进行

        #expect(await wait(5) { !collector.updates.isEmpty })
        provider.stop()
    }

    @Test func 定时轮询什么都没变时不回调() async {
        let (provider, collector) = makeProvider(desktop(), policy: fastPolling)
        provider.start()
        #expect(await wait { collector.cycles.count >= 8 })   // 已经轮询了好几轮
        provider.stop()
        #expect(collector.updates.count == 1)                  // 只有第一次的整体重载
        #expect(collector.cycles.contains { !$0.wasFullRead })
        #expect(collector.cycles.filter(\.wasFullRead).count >= 2)
    }

    @Test func 定时轮询发现新增和移动() async {
        let desktop = desktop()
        let (provider, collector) = makeProvider(desktop, policy: fastPolling)
        provider.start()
        #expect(await wait { !collector.updates.isEmpty })

        desktop.add("丙", at: CGPoint(x: 700, y: 300))
        #expect(await wait { collector.updates.count >= 2 })
        #expect(collector.updates[1].changes.count == 1)
        if case let .added(icon) = collector.updates[1].changes[0] {
            #expect(icon.id == Fixture.id("丙"))
        } else {
            Issue.record("应当是新增事件")
        }

        desktop.move("甲", to: CGPoint(x: 310, y: 420))
        #expect(await wait { collector.updates.count >= 3 })
        if case let .moved(_, to) = collector.updates[2].changes.first {
            #expect(to.imageRect.center == CGPoint(x: 310, y: 420))
        } else {
            Issue.record("应当是移动事件")
        }
        provider.stop()
        #expect(collector.offMainThread == 0)
        #expect(desktop.mainThreadCalls == 0)
    }

    @Test func 立即刷新_没有变化也回调一次_读取时刻不早于调用时刻() async {
        let (provider, collector) = makeProvider(desktop(), policy: noPolling)
        provider.start()
        #expect(await wait { collector.updates.count == 1 })

        let calledAt = ProcessInfo.processInfo.systemUptime
        provider.refreshNow()
        #expect(await wait { collector.updates.count == 2 })
        let update = collector.updates[1]
        #expect(!update.isReset)
        #expect(update.changes.isEmpty)
        #expect(update.snapshot.revision == collector.updates[0].snapshot.revision)
        #expect(update.snapshot.capturedAt >= calledAt)
        #expect(collector.cycles.last?.wasForced == true)

        await settle()
        #expect(collector.updates.count == 2)   // 只回调一次
        provider.stop()
    }

    @Test func 读取进行中多次调用立即刷新_合并成之后的一次_结果不早于最后一次调用() async {
        let desktop = desktop()
        let (provider, collector) = makeProvider(desktop, policy: noPolling)
        provider.start()
        #expect(await wait { collector.updates.count == 1 })

        let gate = desktop.hold("positions")   // 把下一次读取拦在半路
        provider.refreshNow()                  // 第一次：立刻开始读
        #expect(await wait { gate.isReached })
        var lastCall = 0.0
        for _ in 0..<5 {                       // 读取进行中又来了五次
            lastCall = ProcessInfo.processInfo.systemUptime
            provider.refreshNow()
        }
        gate.open()
        #expect(await wait(5) { collector.updates.count == 3 })
        await settle(0.2)
        provider.stop()

        #expect(collector.updates.count == 3)   // 整体重载 + 第一次刷新 + 合并后的一次
        #expect(collector.updates[2].snapshot.capturedAt >= lastCall)
        #expect(collector.cycles.filter(\.wasForced).count == 2)
    }

    @Test func 普通读取进行中调用立即刷新_之后再读一次并回调() async {
        let desktop = desktop()
        let gate = desktop.hold("positions")   // 把第一次读取拦在半路
        let (provider, collector) = makeProvider(desktop, policy: noPolling)
        provider.start()
        #expect(await wait { gate.isReached })
        let calledAt = ProcessInfo.processInfo.systemUptime
        provider.refreshNow()                  // 这时第一次读取还没完
        gate.open()
        #expect(await wait(5) { collector.updates.count == 2 })
        provider.stop()
        #expect(collector.updates[0].isReset)
        #expect(!collector.updates[1].isReset)
        #expect(collector.updates[1].snapshot.capturedAt >= calledAt)
    }

    @Test func 连续调用立即刷新时_各次读取之间保持最小间隔() async {
        var policy = noPolling
        policy.minForcedSpacing = 0.1
        let (provider, collector) = makeProvider(desktop(), policy: policy)
        provider.start()
        #expect(await wait { collector.updates.count == 1 })

        let begin = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - begin < 0.45 {   // 像应用那样每帧都调
            provider.refreshNow()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - begin
        await settle(0.25)
        provider.stop()
        // 间隔是在主线程上按"发起读取的时刻"卡的：无论机器多忙，读取次数都不会超过"时长 ÷ 间隔"再加上头尾各一次。
        let forced = collector.cycles.filter(\.wasForced)
        #expect(forced.count >= 2)
        #expect(forced.count <= Int(elapsed / 0.1) + 2, "\(elapsed) 秒里读了 \(forced.count) 次，超过了间隔允许的次数")
    }

    @Test func 停止之后不再回调_正在进行的读取作废() async {
        let desktop = desktop()
        let gate = desktop.hold("positions")   // 把第一次读取拦在半路
        let (provider, collector) = makeProvider(desktop, policy: fastPolling)
        provider.start()
        #expect(await wait { gate.isReached })
        provider.stop()                        // 读取进行到一半：停止
        gate.open()
        await settle(0.3)
        #expect(collector.updates.isEmpty)

        provider.refreshNow()                  // 停止之后调用无效
        await settle(0.2)
        #expect(collector.updates.isEmpty)
    }

    @Test func 停止后可以再次启动_重新从整体重载开始() async {
        let desktop = desktop()
        let (provider, collector) = makeProvider(desktop, policy: noPolling)
        provider.start()
        provider.start()       // 重复调用无副作用
        #expect(await wait { collector.updates.count == 1 })
        await settle()
        #expect(collector.updates.count == 1)
        provider.stop()

        desktop.add("丙", at: CGPoint(x: 700, y: 300))
        provider.start()
        #expect(await wait { collector.updates.count == 2 })
        provider.stop()
        #expect(collector.updates[1].isReset)
        #expect(collector.updates[1].changes.isEmpty)
        #expect(collector.updates[1].snapshot.icons.count == 3)
        // 版本号接着往上数：重新启动前后的两份快照不会碰巧同号。
        #expect(collector.updates[1].snapshot.revision > collector.updates[0].snapshot.revision)
    }

    @Test func 停止读取期间不向访达发请求_恢复后的第一次上报是整体重载() async {
        let desktop = desktop()
        let (provider, collector) = makeProvider(desktop, policy: fastPolling)
        provider.start()
        #expect(await wait { collector.updates.count == 1 })

        provider.setPollingPace(.suspended)
        await settle(0.1)      // 等可能还在路上的那一次读取结束
        desktop.clearLog()
        desktop.add("丙", at: CGPoint(x: 700, y: 300))
        provider.refreshNow()  // 停止读取期间的立即刷新也不读
        await settle(0.25)
        #expect(desktop.log.isEmpty)
        #expect(collector.updates.count == 1)

        provider.setPollingPace(.active)
        #expect(await wait { collector.updates.count == 2 })
        provider.stop()
        #expect(collector.updates[1].isReset)
        #expect(collector.updates[1].changes.isEmpty)
        #expect(collector.updates[1].snapshot.icons.count == 3)
    }

    @Test func 读取进行中先停止又恢复_读完后马上补一次整体重载() async {
        let desktop = desktop()
        let (provider, collector) = makeProvider(desktop, policy: noPolling)   // 不会自己轮询：补读只能来自"恢复"
        provider.start()
        #expect(await wait { collector.updates.count == 1 })

        let gate = desktop.hold("positions")
        provider.refreshNow()                  // 一次读取开始了，被拦在半路
        #expect(await wait { gate.isReached })
        provider.setPollingPace(.suspended)    // 读取进行中：停止……
        provider.setPollingPace(.active)       // ……又马上恢复
        gate.open()
        #expect(await wait(5) { collector.updates.count >= 2 && collector.updates.last?.isReset == true })
        provider.stop()
        #expect(collector.updates.last?.changes.isEmpty == true)
    }

    @Test func 恢复途中又要求立即刷新_即使状态没变也要回调() async {
        let desktop = desktop()
        desktop.authorizationState = .finderNotRunning       // 访达不在：每次读取都是同一个失败状态
        let (provider, collector) = makeProvider(desktop, policy: noPolling)
        provider.start()
        #expect(await wait { collector.updates.count == 1 })
        #expect(collector.updates[0].snapshot.status == .finderUnavailable)

        let gate = desktop.hold("authorization")
        provider.refreshNow()                  // 一次读取开始了，被拦在半路
        #expect(await wait { gate.isReached })
        provider.setPollingPace(.suspended)
        provider.setPollingPace(.active)       // 应用恢复……
        let calledAt = ProcessInfo.processInfo.systemUptime
        provider.refreshNow()                  // ……并马上要求刷新
        gate.open()
        // 被拦住的那次读完回调一次；随后补的那次读取虽然状态没变，也必须回调（兑现恢复后的那次 refreshNow）。
        #expect(await wait(5) { collector.updates.count >= 3 })
        provider.stop()
        #expect(collector.updates.last?.snapshot.status == .finderUnavailable)
        #expect((collector.updates.last?.snapshot.capturedAt ?? 0) >= calledAt)
    }

    @Test func 暂停刚解除就有人抢先调用立即刷新_恢复后的第一次上报仍是整体重载() async {
        let desktop = desktop()
        let pause = PauseSwitch()
        let (provider, collector) = makeProvider(desktop, policy: noPolling, pause: pause)
        // 这个观察者登记得比图标桥自己的早：解除暂停时它先被通知，并且立刻要求刷新。
        pause.addObserver { paused in
            if !paused { provider.refreshNow() }
        }
        provider.start()
        #expect(await wait { collector.updates.count == 1 })

        pause.setPaused(true)
        await settle(0.05)
        desktop.add("丙", at: CGPoint(x: 700, y: 300))   // 暂停期间桌面变了
        pause.setPaused(false)
        #expect(await wait { collector.updates.count >= 2 })
        provider.stop()
        #expect(collector.updates[1].isReset)            // 不是"新增了一个图标"，而是整体重载
        #expect(collector.updates[1].changes.isEmpty)
        #expect(collector.updates[1].snapshot.icons.count == 3)
    }

    @Test func 全局暂停开关暂停时不读取_继续后整体重载() async {
        let desktop = desktop()
        let pause = PauseSwitch()
        let (provider, collector) = makeProvider(desktop, policy: fastPolling, pause: pause)
        provider.start()
        #expect(await wait { collector.updates.count == 1 })

        pause.setPaused(true)
        await settle(0.1)
        desktop.clearLog()
        await settle(0.25)
        #expect(desktop.log.isEmpty)

        pause.setPaused(false)
        #expect(await wait { collector.updates.count == 2 })
        provider.stop()
        #expect(collector.updates[1].isReset)
    }

    @Test func 暂停状态下启动_不读取_继续后才开始() async {
        let desktop = desktop()
        let pause = PauseSwitch()
        pause.setPaused(true)
        let (provider, collector) = makeProvider(desktop, policy: fastPolling, pause: pause)
        provider.start()
        await settle(0.2)
        #expect(desktop.log.isEmpty)
        #expect(collector.updates.isEmpty)
        #expect(provider.status == .starting)

        pause.setPaused(false)
        #expect(await wait { collector.updates.count == 1 })
        provider.stop()
        #expect(collector.updates[0].isReset)
    }

    @Test func 被拒绝授权时报告状态_用户允许后自动恢复() async {
        let desktop = desktop()
        desktop.authorizationState = .denied
        let (provider, collector) = makeProvider(desktop, policy: fastPolling)
        provider.start()
        #expect(await wait { collector.updates.count == 1 })
        #expect(collector.updates[0].snapshot.status == .permissionDenied)
        #expect(collector.updates[0].snapshot.icons.isEmpty)
        #expect(provider.status == .permissionDenied)

        await settle(0.15)
        #expect(collector.updates.count == 1)   // 一直被拒绝：不重复上报

        desktop.authorizationState = .granted   // 用户在系统设置里允许了
        #expect(await wait { collector.updates.count == 2 })
        provider.stop()
        #expect(collector.updates[1].isReset)
        #expect(collector.updates[1].snapshot.status == .ok)
        #expect(collector.updates[1].snapshot.icons.count == 2)
    }

    @Test func 在回调里调用停止是安全的() async {
        let (provider, collector) = makeProvider(desktop(), policy: fastPolling)
        provider.onUpdate = { update in
            collector.updates.append(update)
            provider.stop()
        }
        provider.start()
        #expect(await wait { collector.updates.count == 1 })
        await settle(0.2)
        #expect(collector.updates.count == 1)
    }
}
