// 占位，由 input-sense 子对话替换。
//
// 写法示范见 Tests/DDMCoreTests/；跑法：swift test --filter InputSenseTests

import DDMCore
import Foundation
import Testing
@testable import InputSense

@MainActor
@Test func 占位的交互感知只报告一只不动的鼠标() {
    let sensor = InteractionSensor()
    let time = FrameTime(monotonic: 10, wallClock: Date(timeIntervalSince1970: 0))
    let facts = sensor.update(time: time, icons: .unchanged(.empty()))
    #expect(facts.time == time)
    #expect(facts.hover == nil)
    #expect(facts.drag == nil)
    #expect(facts.demand == .by(11))
}
