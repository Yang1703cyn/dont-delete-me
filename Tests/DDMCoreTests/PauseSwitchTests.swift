// 全局暂停开关的测试。测试里自己建一个 PauseSwitch()，不碰全应用共用的 .shared。

import Foundation
import Testing
@testable import DDMCore

@Suite("暂停开关")
@MainActor
struct PauseSwitchTests {
    @Test func 默认不暂停且可以切换() {
        let pause = PauseSwitch()
        #expect(!pause.isPaused)
        #expect(pause.toggle() == true)
        #expect(pause.isPaused)
        #expect(pause.toggle() == false)
        #expect(!pause.isPaused)
    }

    @Test func 观察者只在值真的变化时被同步通知() {
        let pause = PauseSwitch()
        var received: [Bool] = []
        pause.addObserver { received.append($0) }

        pause.setPaused(false)   // 没变，不通知
        #expect(received.isEmpty)
        pause.setPaused(true)
        #expect(received == [true])   // 同步：setPaused 返回时已经通知完
        pause.setPaused(true)    // 没变，不通知
        pause.setPaused(false)
        #expect(received == [true, false])
    }

    @Test func 取消之后不再通知() {
        let pause = PauseSwitch()
        var first = 0, second = 0
        let observation = pause.addObserver { _ in first += 1 }
        pause.addObserver { _ in second += 1 }

        pause.toggle()
        observation.cancel()
        observation.cancel()   // 重复取消无副作用
        pause.toggle()

        #expect(first == 1)
        #expect(second == 2)
    }

    @Test func 观察者按登记顺序被通知() {
        let pause = PauseSwitch()
        var order: [Int] = []
        for index in 0..<5 {
            pause.addObserver { _ in order.append(index) }
        }
        pause.toggle()
        #expect(order == [0, 1, 2, 3, 4])
    }

    @Test func 后台线程可以读() async {
        let pause = PauseSwitch()
        pause.setPaused(true)
        let seenInBackground = await Task.detached { pause.isPaused }.value
        #expect(seenInBackground)
    }

    @Test func 各个开关互不影响() {
        let a = PauseSwitch()
        let b = PauseSwitch()
        a.setPaused(true)
        #expect(!b.isPaused)
        #expect(!PauseSwitch.shared.isPaused)
    }
}
