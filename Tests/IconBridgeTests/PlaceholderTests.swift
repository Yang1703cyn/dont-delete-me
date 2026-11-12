// 占位，由 icon-bridge 子对话替换。
//
// 写法示范见 Tests/DDMCoreTests/；跑法：swift test --filter IconBridgeTests

import DDMCore
import Foundation
import Testing
@testable import IconBridge

@MainActor
@Test func 占位的图标提供者启动前是空快照() {
    let provider = DesktopIconProvider()
    #expect(provider.snapshot.icons.isEmpty)
    #expect(provider.status == .starting)
}
