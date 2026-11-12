// 占位，由 overlay 子对话替换。
//
// 写法示范见 Tests/DDMCoreTests/；跑法：swift test --filter OverlayTests

import DDMCore
import Foundation
import Testing
@testable import Overlay

@MainActor
@Test func 占位的叠加层在暂停时不出帧() {
    let pause = PauseSwitch()
    pause.setPaused(true)
    let host = OverlayHost(pause: pause)
    host.start()
    host.requestFrame()
    #expect(host.isDesktopVisible)
    host.stop()
}
