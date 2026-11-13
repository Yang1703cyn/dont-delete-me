// IconBridge · 纯逻辑：快照比对、废纸篓线索、访达报错到状态的映射

import CoreGraphics
import DDMCore
import Foundation

// MARK: - 快照比对

/// 相邻两次读数之间的差别。
struct IconDifference: Equatable, Sendable {
    /// 新出现的图标。
    var added: [DesktopIcon] = []
    /// 不见了的图标（消失前最后的样子）。
    var removed: [DesktopIcon] = []
    /// 换了位置的图标（图像矩形变了）：旧样子 → 新样子。
    var moved: [(from: DesktopIcon, to: DesktopIcon)] = []

    var isEmpty: Bool { added.isEmpty && removed.isEmpty && moved.isEmpty }

    static func == (lhs: IconDifference, rhs: IconDifference) -> Bool {
        lhs.added == rhs.added && lhs.removed == rhs.removed
            && lhs.moved.map(\.from) == rhs.moved.map(\.from) && lhs.moved.map(\.to) == rhs.moved.map(\.to)
    }
}

enum SnapshotDiff {
    /// 比对两份图标列表（按编号对应）。
    ///
    /// - 只在新列表里有：新增；只在旧列表里有：消失；两边都有而图像矩形不同：移动。
    /// - 种类、标签矩形、所在显示器、修改时间的变化不算事件（它们直接体现在新快照里）。
    /// - 各组内部保持所在列表里的先后顺序，所以同样的输入永远得到同样的输出。
    static func difference(from old: [DesktopIcon], to new: [DesktopIcon]) -> IconDifference {
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newIDs = Set(new.map(\.id))

        var result = IconDifference()
        result.removed = old.filter { !newIDs.contains($0.id) }
        for icon in new {
            guard let previous = oldByID[icon.id] else {
                result.added.append(icon)
                continue
            }
            if previous.imageRect != icon.imageRect {
                result.moved.append((from: previous, to: icon))
            }
        }
        return result
    }

    /// 把差别排成事件序列：先消失、再新增、最后移动。
    /// （改名在访达看来是"旧名字消失 + 新名字出现"，先消失后新增读起来最自然。）
    static func changes(
        for difference: IconDifference,
        trashVerdict: (DesktopIcon) -> TrashVerdict
    ) -> [IconChange] {
        difference.removed.map { .removed($0, trashed: trashVerdict($0)) }
            + difference.added.map { .added($0) }
            + difference.moved.map { .moved(from: $0.from, to: $0.to) }
    }
}

// MARK: - 废纸篓线索

/// 一个图标从桌面消失后，向访达查到的关于废纸篓的证据。
struct TrashEvidence: Equatable, Sendable {
    /// 图标还在桌面上时废纸篓里的项目数（最近几秒内几次完整读取里最小的那个）；没有可用的基准为 nil。
    var countBefore: Int?
    /// 发现图标消失后废纸篓里的项目数；查询失败为 nil。
    var countAfter: Int?
    /// 废纸篓里现在有没有同名的项目；查询失败为 nil。
    var nameFound: Bool?
}

enum TrashVerdictLogic {
    /// 由证据得出结论。
    ///
    /// | 废纸篓变多了？ | 里面有同名项目？ | 结论 |
    /// |---|---|---|
    /// | 是 | 有 | **是**：刚进去的 |
    /// | 是 | 没有 | 不确定：有东西进了废纸篓，但按名字对不上 |
    /// | 否 | 有 | **否**：那是以前就在废纸篓里的同名旧物 |
    /// | 否 | 没有 | **否** |
    /// | 没有基准 | 有 | 不确定：分不清是刚进去的还是旧物 |
    /// | 没有基准 | 没有 | **否** |
    /// | 任何一项查询失败 | | 不确定 |
    ///
    /// 只凭"废纸篓里有同名项目"不够：用户完全可能上周删过一个同名文件。
    /// 宁可给"不确定"，也不要把没被删的文件说成进了废纸篓。
    static func verdict(for evidence: TrashEvidence) -> TrashVerdict {
        guard let nameFound = evidence.nameFound, let after = evidence.countAfter else {
            return .unknown
        }
        guard let before = evidence.countBefore else {
            return nameFound ? .unknown : .no
        }
        if after > before {
            return nameFound ? .yes : .unknown
        }
        return .no
    }

    /// 证据是否值得稍等片刻再查一次：证据齐全，结论却不是"是"。
    ///
    /// 访达把一个文件移进废纸篓，在它的两个列表里（桌面少一项、废纸篓多一项）不一定同时生效；
    /// 如果我们恰好在"桌面已经少了、废纸篓还没多"的那一瞬间问，就会得到"否"。稍等再查一次可以避开这个时间差。
    /// 证据不全（查询失败）时再查也没有意义。
    static func shouldRecheck(_ evidence: TrashEvidence) -> Bool {
        guard evidence.nameFound != nil, evidence.countAfter != nil else { return false }
        return verdict(for: evidence) != .yes
    }
}

// MARK: - 访达报错 → 状态

enum StatusMapping {
    /// 读取失败时该报告什么状态。
    ///
    /// 注意"等访达回复超时（-1712）"不走这里：超时多半只是访达一时没空（例如用户正拖着图标），
    /// `BridgeCore` 会保留快照继续等，连续很久都不回答才报"访达不可用"。
    static func status(for error: FinderError) -> IconProviderStatus {
        switch error {
        case .notPermitted:
            // 用户拒绝了"控制访达"。
            return .permissionDenied
        case .wouldRequireConsent:
            // 还没问过用户（授权窗口还没回答）：仍算"启动中"。
            return .starting
        default:
            // 访达没运行（-600）、连接断了（-609）、对象不存在（-1728，常见于访达刚重启）……
            // 以及一切归不了类的失败。（超时 -1712 落到这里时，说明已经连续很久没有回答了。）
            return .finderUnavailable
        }
    }

    /// 授权预检的结果对应什么状态；nil 表示"可以去读"。
    static func status(for authorization: FinderAuthorization) -> IconProviderStatus? {
        switch authorization {
        case .granted, .undetermined: return nil
        case .denied: return .permissionDenied
        case .wouldPrompt: return .starting
        case .finderNotRunning: return .finderUnavailable
        }
    }
}
