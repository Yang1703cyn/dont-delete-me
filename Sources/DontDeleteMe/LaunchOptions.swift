// 命令行参数。普通用户双击打开时没有任何参数；这些只给开发和自测用。

import Foundation

struct LaunchOptions: Equatable {
    /// 自检模式：`--smoke-test [秒数]`。
    /// 应用照常启动，自动把"暂停 → 继续"走一遍，到时间后打印一份报告并正常退出。
    /// 没给秒数或秒数不合法时用 3 秒。
    var smokeTestDuration: TimeInterval?

    init(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--smoke-test") else { return }
        let next = arguments.indices.contains(index + 1) ? TimeInterval(arguments[index + 1]) : nil
        smokeTestDuration = next.flatMap { $0 > 0 ? $0 : nil } ?? 3
    }
}
