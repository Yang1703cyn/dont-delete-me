// IconBridge · 把核心放到自己的后台队列上
//
// `BridgeEngine` 是一个 actor，但不用 Swift 并发的公共线程池，而是用自己的一条串行队列当执行器：
// 向访达发请求是同步阻塞的（正常十几到几十毫秒，等授权窗口时可能很久），
// 不应该占着公共线程池里的线程，更不能在主线程上做。
// 提供者在主线程 `await engine.run(…)`：主线程不会被阻塞，结果回到主线程后再上报。

import DDMCore
import Foundation

actor BridgeEngine {
    private let queue: DispatchSerialQueue
    private var core: BridgeCore

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    init(core: BridgeCore) {
        // userInitiated：松开鼠标后的那次重读需要尽快完成；这条队列绝大部分时间都在等访达回复，自身几乎不占 CPU。
        self.queue = DispatchSerialQueue(label: "IconBridge.engine", qos: .userInitiated)
        self.core = core
    }

    /// 跑一个读取周期。在后台队列上执行，期间会阻塞这条队列（不是调用者）。
    func run(_ request: CycleRequest) -> CycleOutcome {
        core.run(request)
    }
}
