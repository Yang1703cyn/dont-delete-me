// 占位，由 icon-bridge 子对话替换。
//
// 图标桥的独立演示程序。运行：swift run IconBridgeDemo
// 只依赖 DDMCore 和 IconBridge。演示程序必须能自己正常结束（限时退出）。

import DDMCore
import Foundation
import IconBridge

let provider = DesktopIconProvider()
provider.onUpdate = { update in
    let snapshot = update.snapshot
    print("[IconBridgeDemo] 收到上报：状态 \(snapshot.status.rawValue)，图标 \(snapshot.icons.count) 个，整体重载 \(update.isReset)")
}
provider.start()

// 让主线程转一小会儿，等占位实现把第一份（空的）快照送到，然后正常结束。
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
provider.stop()
print("[IconBridgeDemo] 占位演示结束。")
