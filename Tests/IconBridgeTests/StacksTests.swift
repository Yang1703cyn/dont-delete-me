// "叠放"的识别：办法 B（访达的一项桌面显示设置）为主，办法 A（位置完全相同）兜底

import CoreGraphics
import DDMCore
import Foundation
import Testing
@testable import IconBridge

@Suite("叠放的识别")
struct StacksTests {
    private let full = CycleRequest(kind: .full)
    private let quick = CycleRequest(kind: .quick)

    // MARK: 办法 B：那一项设置怎么解读

    @Test func 读不到那一组设置_无法判断() {
        #expect(DesktopGroupBySetting.parse(desktopViewSettings: nil) == .unreadable)
        #expect(DesktopGroupBySetting.parse(desktopViewSettings: "不是字典") == .unreadable)
        #expect(DesktopGroupBySetting.parse(desktopViewSettings: 42) == .unreadable)
        #expect(DesktopGroupBySetting.unreadable.stacksEnabled == nil)
    }

    @Test func 那一组设置里没有分组这一项_没开叠放() {
        // 开发机上没开叠放时读到的就是这个样子：只有图标显示设置，没有"分组"。
        let settings: [String: Any] = ["IconViewSettings": ["iconSize": 64, "textSize": 12]]
        #expect(DesktopGroupBySetting.parse(desktopViewSettings: settings) == .absent)
        #expect(DesktopGroupBySetting.absent.stacksEnabled == false)
    }

    @Test(arguments: ["None", "none", "NONE", " None "])
    func 分组为不分组_没开叠放(text: String) {
        let setting = DesktopGroupBySetting.parse(desktopViewSettings: ["GroupBy": text])
        #expect(setting == .value(text))
        #expect(setting.stacksEnabled == false)
    }

    @Test(arguments: ["Kind", "Date Added", "DateModified", "Tags", "Application"])
    func 分组为某种依据_开了叠放(text: String) {
        #expect(DesktopGroupBySetting.parse(desktopViewSettings: ["GroupBy": text]).stacksEnabled == true)
    }

    @Test func 分组这一项不是文字_或是空的_无法判断_不会因此判定开了叠放() {
        #expect(DesktopGroupBySetting.parse(desktopViewSettings: ["GroupBy": 3]) == .unrecognized)
        #expect(DesktopGroupBySetting.parse(desktopViewSettings: ["GroupBy": ["Kind"]]) == .unrecognized)
        #expect(DesktopGroupBySetting.unrecognized.stacksEnabled == nil)
        #expect(DesktopGroupBySetting.value("").stacksEnabled == nil)
        #expect(DesktopGroupBySetting.value("   ").stacksEnabled == nil)
    }

    @Test func 只取分组这一项_同组的其它设置不影响结果() {
        let settings: [String: Any] = ["GroupBy": "Kind", "IconViewSettings": ["arrangeBy": "none"], "别的": 1]
        #expect(DesktopGroupBySetting.parse(desktopViewSettings: settings) == .value("Kind"))
    }

    @Test func 探针按读到的设置作答() {
        #expect(FinderPreferenceStacksProbe(read: { .value("Kind") }).stacksEnabled() == true)
        #expect(FinderPreferenceStacksProbe(read: { .absent }).stacksEnabled() == false)
        #expect(FinderPreferenceStacksProbe(read: { .unreadable }).stacksEnabled() == nil)
    }

    @Test func 读的是访达的桌面显示设置里的分组一项() {
        #expect(FinderPreferenceStacksProbe.finderDomain == "com.apple.finder")
        #expect(FinderPreferenceStacksProbe.desktopViewSettingsKey == "DesktopViewSettings")
        #expect(FinderPreferenceStacksProbe.groupByKey == "GroupBy")
    }

    // MARK: 办法 A：位置完全相同

    @Test func 三个以上图标位置完全相同_像是叠放() {
        let same = CGPoint(x: 1400, y: 100)
        #expect(StacksHeuristic.looksStacked(positions: [same, same, same]))
        #expect(StacksHeuristic.looksStacked(positions: [CGPoint(x: 1, y: 1), same, CGPoint(x: 2, y: 2), same, same]))
    }

    @Test func 两个图标重合_或者只是挨得很近_不算() {
        let same = CGPoint(x: 1400, y: 100)
        #expect(!StacksHeuristic.looksStacked(positions: [same, same, CGPoint(x: 1400, y: 101)]))
        #expect(!StacksHeuristic.looksStacked(positions: [CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 1), CGPoint(x: 3, y: 1)]))
        #expect(!StacksHeuristic.looksStacked(positions: []))
    }

    // MARK: 接进读取周期

    private func piled() -> FakeDesktop {
        // 三个图标报告的位置完全相同。
        FakeDesktop((0..<3).map { .init(name: "文件\($0)", position: CGPoint(x: 1400, y: 100)) }
            + [.init(name: "别的", position: CGPoint(x: 300, y: 300))])
    }

    @Test func 设置说开了叠放_不去读桌面_直接报告状态() throws {
        let desktop = piled()
        desktop.stacks = true
        var core = Fixture.core(desktop)
        let update = try #require(core.run(full).update)
        #expect(update.snapshot.status == .stacksEnabled)
        #expect(update.snapshot.icons.isEmpty)
        #expect(update.isReset)
        #expect(!desktop.log.contains("positions"))
    }

    @Test func 设置无法判断_三个图标位置完全相同_兜底判为叠放_散开后恢复() throws {
        let desktop = piled()
        desktop.stacks = nil
        var core = Fixture.core(desktop)
        let update = try #require(core.run(full).update)
        #expect(update.snapshot.status == .stacksEnabled)
        #expect(update.snapshot.icons.isEmpty)

        #expect(core.run(full).update == nil)   // 还是叠放：不重复上报

        desktop.move("文件0", to: CGPoint(x: 1300, y: 100))
        let back = try #require(core.run(full).update)
        #expect(back.isReset)
        #expect(back.snapshot.status == .ok)
        #expect(back.snapshot.icons.count == 4)
    }

    @Test func 设置明确说没开_即使三个图标重合也照常提供图标() throws {
        let desktop = piled()
        desktop.stacks = false
        var core = Fixture.core(desktop)
        let update = try #require(core.run(full).update)
        #expect(update.snapshot.status == .ok)
        #expect(update.snapshot.icons.count == 4)
    }

    @Test func 正常使用中打开了叠放_快速检查就能发现_而且不向访达发请求() throws {
        let desktop = FakeDesktop([.init(name: "甲", position: CGPoint(x: 300, y: 300))])
        desktop.stacks = false
        var core = Fixture.core(desktop)
        #expect(core.run(full).snapshot.status == .ok)

        desktop.stacks = true
        desktop.clearLog()
        let outcome = core.run(quick)
        let update = try #require(outcome.update)
        #expect(update.snapshot.status == .stacksEnabled)
        #expect(update.isReset)
        #expect(update.changes.isEmpty)        // 不给"不见了"的图标发消失事件
        #expect(desktop.log.isEmpty)
        #expect(outcome.requestCount == 0)

        desktop.stacks = false                 // 又关掉了
        let back = try #require(core.run(full).update)
        #expect(back.isReset)
        #expect(back.snapshot.status == .ok)
        #expect(back.snapshot.icons.count == 1)
    }
}
