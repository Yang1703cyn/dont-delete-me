// 只运行一个：已经有一个「别删我」在运行时，后启动的那个自己退出。
//
// 不这样的话，每个图标上会叠着两张脸，向访达读取的次数也翻倍。
// 只对打包后的应用生效：用 `swift run` 直接跑时没有应用标识（`Bundle.main.bundleIdentifier` 为 nil），不做这个检查。

import AppKit

enum SingleInstance {
    /// 一个正在运行的实例：进程号和启动时刻。
    struct Instance: Equatable {
        var pid: pid_t
        var launchDate: Date?
    }

    /// 自己该不该让位（退出）。规则：先启动的留下；启动时刻分不出先后（或读不到）时，进程号小的留下。
    /// 两个实例几乎同时启动时，各自按这条规则判断，结论一致，不会两个都退出。
    static func shouldYield(own: Instance, others: [Instance]) -> Bool {
        others.contains { other in
            if let theirs = other.launchDate, let ours = own.launchDate, theirs != ours {
                return theirs < ours
            }
            return other.pid < own.pid
        }
    }

    /// 此刻是否已有另一个同样标识的应用在运行、而且该由自己让位。没有应用标识时恒为 false。
    @MainActor
    static func anotherInstanceShouldStay() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let current = NSRunningApplication.current
        let own = Instance(pid: current.processIdentifier, launchDate: current.launchDate)
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != own.pid && !$0.isTerminated }
            .map { Instance(pid: $0.processIdentifier, launchDate: $0.launchDate) }
        return shouldYield(own: own, others: others)
    }
}
