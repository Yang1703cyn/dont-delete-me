// 快照比对：新增 / 消失 / 移动

import CoreGraphics
import DDMCore
import Foundation
import Testing
@testable import IconBridge

@Suite("快照比对")
struct SnapshotDiffTests {
    private func icon(_ raw: UInt64, x: CGFloat, y: CGFloat = 100, kind: IconKind = .file) -> DesktopIcon {
        DesktopIcon(id: IconID(rawValue: raw), kind: kind, imageRect: CGRect(x: x, y: y, width: 64, height: 64))
    }

    @Test func 没有变化时差别为空() {
        let icons = [icon(1, x: 0), icon(2, x: 100)]
        #expect(SnapshotDiff.difference(from: icons, to: icons).isEmpty)
    }

    @Test func 只在新列表里的是新增() {
        let old = [icon(1, x: 0)]
        let new = [icon(1, x: 0), icon(2, x: 100)]
        let difference = SnapshotDiff.difference(from: old, to: new)
        #expect(difference.added == [icon(2, x: 100)])
        #expect(difference.removed.isEmpty)
        #expect(difference.moved.isEmpty)
    }

    @Test func 只在旧列表里的是消失并保留最后的样子() {
        let old = [icon(1, x: 0), icon(2, x: 100, y: 300)]
        let new = [icon(1, x: 0)]
        let difference = SnapshotDiff.difference(from: old, to: new)
        #expect(difference.removed == [icon(2, x: 100, y: 300)])
        #expect(difference.added.isEmpty)
    }

    @Test func 图像矩形变了是移动() {
        let old = [icon(1, x: 0), icon(2, x: 100)]
        let new = [icon(1, x: 0), icon(2, x: 250, y: 400)]
        let difference = SnapshotDiff.difference(from: old, to: new)
        #expect(difference.moved.count == 1)
        #expect(difference.moved.first?.from == icon(2, x: 100))
        #expect(difference.moved.first?.to == icon(2, x: 250, y: 400))
        #expect(difference.added.isEmpty && difference.removed.isEmpty)
    }

    @Test func 种类标签修改时间的变化不算事件() {
        var changed = icon(1, x: 0, kind: .folder)
        changed.labelRect = CGRect(x: 0, y: 170, width: 80, height: 16)
        changed.modifiedAt = Date(timeIntervalSince1970: 1_000_000)
        changed.displayID = DisplayID(rawValue: 3)
        #expect(SnapshotDiff.difference(from: [icon(1, x: 0)], to: [changed]).isEmpty)
    }

    @Test func 同时有新增消失移动时各归各类() {
        let old = [icon(1, x: 0), icon(2, x: 100), icon(3, x: 200)]
        let new = [icon(4, x: 300), icon(1, x: 50), icon(3, x: 200)]
        let difference = SnapshotDiff.difference(from: old, to: new)
        #expect(difference.added.map(\.id.rawValue) == [4])
        #expect(difference.removed.map(\.id.rawValue) == [2])
        #expect(difference.moved.map(\.to.id.rawValue) == [1])
    }

    @Test func 事件顺序是先消失再新增最后移动() {
        let old = [icon(1, x: 0), icon(2, x: 100)]
        let new = [icon(1, x: 50), icon(3, x: 200)]
        let difference = SnapshotDiff.difference(from: old, to: new)
        let changes = SnapshotDiff.changes(for: difference) { _ in .yes }
        #expect(changes == [
            .removed(icon(2, x: 100), trashed: .yes),
            .added(icon(3, x: 200)),
            .moved(from: icon(1, x: 0), to: icon(1, x: 50)),
        ])
    }

    @Test func 废纸篓结论按图标分别给出() {
        let old = [icon(1, x: 0), icon(2, x: 100)]
        let difference = SnapshotDiff.difference(from: old, to: [])
        let changes = SnapshotDiff.changes(for: difference) { $0.id.rawValue == 1 ? .yes : .no }
        #expect(changes == [.removed(icon(1, x: 0), trashed: .yes), .removed(icon(2, x: 100), trashed: .no)])
    }

    @Test func 从空桌面到空桌面() {
        #expect(SnapshotDiff.difference(from: [], to: []).isEmpty)
    }
}

@Suite("废纸篓线索")
struct TrashVerdictTests {
    private func verdict(before: Int?, after: Int?, found: Bool?) -> TrashVerdict {
        TrashVerdictLogic.verdict(for: TrashEvidence(countBefore: before, countAfter: after, nameFound: found))
    }

    @Test func 废纸篓变多且有同名项目才是确认进了废纸篓() {
        #expect(verdict(before: 3, after: 4, found: true) == .yes)
    }

    @Test func 废纸篓没变多就是没进_哪怕里面有同名的旧物() {
        #expect(verdict(before: 3, after: 3, found: true) == .no)
        #expect(verdict(before: 3, after: 3, found: false) == .no)
        #expect(verdict(before: 3, after: 2, found: true) == .no)
    }

    @Test func 废纸篓变多但按名字对不上是不确定() {
        #expect(verdict(before: 3, after: 4, found: false) == .unknown)
    }

    @Test func 没有基准时_有同名是不确定_没有同名是否() {
        #expect(verdict(before: nil, after: 4, found: true) == .unknown)
        #expect(verdict(before: nil, after: 4, found: false) == .no)
    }

    @Test func 查询失败一律不确定() {
        #expect(verdict(before: 3, after: nil, found: true) == .unknown)
        #expect(verdict(before: 3, after: 4, found: nil) == .unknown)
        #expect(verdict(before: nil, after: nil, found: nil) == .unknown)
    }

    @Test func 证据齐全而结论不是是_才值得稍等再查一次() {
        // 结论已经是"是"：不用再查。
        #expect(!TrashVerdictLogic.shouldRecheck(TrashEvidence(countBefore: 3, countAfter: 4, nameFound: true)))
        // 结论是"否"或"不确定"，证据齐全：可能只是访达还没登记完，值得再查。
        #expect(TrashVerdictLogic.shouldRecheck(TrashEvidence(countBefore: 3, countAfter: 4, nameFound: false)))
        #expect(TrashVerdictLogic.shouldRecheck(TrashEvidence(countBefore: 3, countAfter: 3, nameFound: false)))
        #expect(TrashVerdictLogic.shouldRecheck(TrashEvidence(countBefore: 3, countAfter: 3, nameFound: true)))
        #expect(TrashVerdictLogic.shouldRecheck(TrashEvidence(countBefore: nil, countAfter: 4, nameFound: false)))
        // 查询失败：再查也没有意义。
        #expect(!TrashVerdictLogic.shouldRecheck(TrashEvidence(countBefore: 3, countAfter: nil, nameFound: false)))
        #expect(!TrashVerdictLogic.shouldRecheck(TrashEvidence(countBefore: 3, countAfter: 4, nameFound: nil)))
    }
}

@Suite("访达报错到状态的映射")
struct StatusMappingTests {
    @Test func 用户拒绝授权() {
        #expect(StatusMapping.status(for: FinderError(code: -1743)) == .permissionDenied)
        #expect(StatusMapping.status(for: .notPermitted) == .permissionDenied)
    }

    @Test func 还没问过用户算启动中() {
        #expect(StatusMapping.status(for: FinderError(code: -1744)) == .starting)
    }

    @Test(arguments: [-600, -609, -1712, -1728, -1700, -10810, -1, 12345])
    func 其余失败都算访达不可用(code: Int) {
        #expect(StatusMapping.status(for: FinderError(code: code)) == .finderUnavailable)
    }

    @Test func 授权预检的结果() {
        #expect(StatusMapping.status(for: FinderAuthorization.granted) == nil)
        #expect(StatusMapping.status(for: FinderAuthorization.undetermined(-50)) == nil)
        #expect(StatusMapping.status(for: FinderAuthorization.denied) == .permissionDenied)
        #expect(StatusMapping.status(for: FinderAuthorization.wouldPrompt) == .starting)
        #expect(StatusMapping.status(for: FinderAuthorization.finderNotRunning) == .finderUnavailable)
    }

    @Test func 系统错误码到授权状态() {
        #expect(FinderAuthorization(status: 0) == .granted)
        #expect(FinderAuthorization(status: -1743) == .denied)
        #expect(FinderAuthorization(status: -1744) == .wouldPrompt)
        #expect(FinderAuthorization(status: -600) == .finderNotRunning)
        #expect(FinderAuthorization(status: -50) == .undetermined(-50))
    }
}
