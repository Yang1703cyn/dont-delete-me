// OverlayTests · 帧调度：省电信号 → 帧循环该处于什么状态

import DDMCore
import Foundation
import Testing
@testable import Overlay

@Suite("帧调度")
struct FrameSchedulerTests {
    @Test func 起始状态是休息() {
        let scheduler = FrameScheduler()
        #expect(scheduler.wake == .sleep)
        #expect(!scheduler.needsRefreshTicks)
        #expect(scheduler.timerDeadline == nil)
        #expect(!scheduler.shouldRunFrame(onTickAt: 100))
    }

    @Test func 连续_每个显示刷新都出帧() {
        var scheduler = FrameScheduler()
        scheduler.frameFinished(demand: .continuous, now: 100)
        #expect(scheduler.wake == .everyRefresh)
        #expect(scheduler.needsRefreshTicks)
        #expect(scheduler.shouldRunFrame(onTickAt: 100.016))
        #expect(scheduler.shouldRunFrame(onTickAt: 100.033))
    }

    @Test func 离得远的定时需求_关掉刷新回调_交给定时器() {
        var scheduler = FrameScheduler()
        scheduler.frameFinished(demand: .by(102.5), now: 100)
        #expect(scheduler.wake == .timer(at: 102.5))
        #expect(!scheduler.needsRefreshTicks)
        #expect(scheduler.timerDeadline == 102.5)
        #expect(!scheduler.shouldRunFrame(onTickAt: 101))            // 即使有刷新回调来也不出帧
        #expect(!scheduler.shouldRunFrame(onTimerAt: 101))           // 提早响的（过期的）定时器不算
        #expect(!scheduler.shouldRunFrame(onTimerAt: 102.499))       // 差一点也不算：早到的帧调用方什么都不会做
        #expect(scheduler.shouldRunFrame(onTimerAt: 102.5))
        #expect(scheduler.shouldRunFrame(onTimerAt: 102.6))
    }

    @Test func 很近的定时需求_守着显示刷新等它() {
        var scheduler = FrameScheduler()
        scheduler.frameFinished(demand: .by(100.03), now: 100)
        #expect(scheduler.wake == .refresh(notBefore: 100.03))
        #expect(scheduler.needsRefreshTicks)
        #expect(scheduler.timerDeadline == nil)
        #expect(!scheduler.shouldRunFrame(onTickAt: 100.016))        // 还没到
        #expect(!scheduler.shouldRunFrame(onTickAt: 100.029))        // 差一毫秒也不出：白出一帧，真正的重画反而更晚
        #expect(scheduler.shouldRunFrame(onTickAt: 100.03))
        #expect(scheduler.shouldRunFrame(onTickAt: 100.033))
    }

    @Test func 已经过去的时刻视为立刻() {
        var scheduler = FrameScheduler()
        scheduler.frameFinished(demand: .by(90), now: 100)
        #expect(scheduler.wake == .refresh(notBefore: 100))
        #expect(scheduler.shouldRunFrame(onTickAt: 100.001))

        scheduler.frameFinished(demand: .by(-.infinity), now: 100)
        #expect(scheduler.wake == .refresh(notBefore: 100))
    }

    @Test func 不是一个时刻的定时需求_当作休息_不让定时器空转() {
        var scheduler = FrameScheduler()
        for bogus in [TimeInterval.nan, .infinity] {
            scheduler.frameFinished(demand: .continuous, now: 100)
            scheduler.frameFinished(demand: .by(bogus), now: 100)
            #expect(scheduler.wake == .sleep)
            #expect(scheduler.timerDeadline == nil)
            #expect(!scheduler.needsRefreshTicks)
        }
    }

    @Test func 休息_直到有人请求一帧() {
        var scheduler = FrameScheduler()
        scheduler.frameFinished(demand: .idle, now: 100)
        #expect(scheduler.wake == .sleep)
        #expect(!scheduler.shouldRunFrame(onTickAt: 105))

        scheduler.requestFrame(now: 107)
        #expect(scheduler.wake == .refresh(notBefore: 107))
        #expect(scheduler.shouldRunFrame(onTickAt: 107.01))
    }

    @Test func 请求一帧会提前远处的定时需求_但不打扰连续出帧和更早的约定() {
        var scheduler = FrameScheduler()

        scheduler.frameFinished(demand: .by(110), now: 100)
        scheduler.requestFrame(now: 101)
        #expect(scheduler.wake == .refresh(notBefore: 101))           // 定时器被换成"下一个刷新"

        scheduler.frameFinished(demand: .continuous, now: 101)
        scheduler.requestFrame(now: 101.5)
        #expect(scheduler.wake == .everyRefresh)                      // 连续出帧时无影响

        scheduler.frameFinished(demand: .by(102.04), now: 102)
        scheduler.requestFrame(now: 102.01)
        #expect(scheduler.wake == .refresh(notBefore: 102.01))        // 比原先约的更早

        scheduler.requestFrame(now: 102.02)
        #expect(scheduler.wake == .refresh(notBefore: 102.01))        // 已经约了更早的一帧：不变
    }

    @Test func 停下来之后什么都不出() {
        var scheduler = FrameScheduler()
        scheduler.frameFinished(demand: .continuous, now: 100)
        scheduler.suspend()
        #expect(scheduler.wake == .sleep)
        #expect(!scheduler.needsRefreshTicks)
        #expect(!scheduler.shouldRunFrame(onTickAt: 100.016))
        #expect(!scheduler.shouldRunFrame(onTimerAt: 100.016))
    }
}
