// 占位，由 icon-bridge 子对话替换。
//
// 模块入口：应用以 `DesktopIconProvider()` 构造它——请保留这个类型名和无参构造方式
// （可以增加带默认值的参数），内部实现和文件组织随意。
// 要实现的协议与约定见 docs/接口约定.md 第 2 节。
//
// 占位行为：不向访达发任何请求（因此不会触发授权弹窗），永远报告"一个空桌面"。

import DDMCore
import Foundation

@MainActor
public final class DesktopIconProvider: IconProviding {
    public private(set) var snapshot: IconSnapshot = .empty()
    public var onUpdate: (@MainActor (IconUpdate) -> Void)?

    private var isRunning = false

    public init() {}

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        report(isReset: true)
    }

    public func stop() {
        isRunning = false
    }

    public func refreshNow() {
        report(isReset: false)
    }

    public func setPollingPace(_ pace: IconPollingPace) {}

    /// 模拟"后台读完一轮，回到主线程上报"：异步送出一份空快照。
    private func report(isReset: Bool) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            self.snapshot = IconSnapshot(icons: [], status: .ok, capturedAt: startedAt, revision: self.snapshot.revision)
            self.onUpdate?(IconUpdate(snapshot: self.snapshot, isReset: isReset))
        }
    }
}
