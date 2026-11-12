// 坐标换算的测试——也是全工程"测试怎么写"的示范（Swift Testing，见 docs/开发说明.md）。
//
// 要点：
//   - `import Testing`，用 `@Test` 标记测试函数、`#expect` 断言；函数名可以用中文；
//   - 逻辑测试用编造的数据（这里按开发机的真实排列造了一套两块屏的布局）；
//   - 需要主线程的测试加 `@MainActor`。

import CoreGraphics
import Foundation
import Testing
@testable import DDMCore

#if canImport(AppKit)
import AppKit
#endif

/// 仿照开发机造的布局：内屏 1512×982 @2x 是主屏；左侧外接 1920×1080 @1x。
/// 这里假设两块屏底边对齐：外接屏比主屏高 98 点，所以它的顶边在全局坐标里是 y = -98。
private let builtIn = DisplayInfo(id: DisplayID(rawValue: 1), frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
private let external = DisplayInfo(id: DisplayID(rawValue: 2), frame: CGRect(x: -1920, y: -98, width: 1920, height: 1080), scale: 1)
private let layout = DisplayLayout(displays: [external, builtIn])

@Suite("坐标换算")
struct CoordinateTests {
    @Test func 主屏排在第一个且主屏高度正确() {
        #expect(layout.displays.map(\.id) == [builtIn.id, external.id])
        #expect(layout.primary == builtIn)
        #expect(layout.primaryHeight == 982)
        #expect(builtIn.isPrimary)
        #expect(!external.isPrimary)
    }

    @Test func 全局原点对应AppKit主屏左上角() {
        // 全局 (0,0) 是主屏左上角；AppKit 里主屏左上角是 (0, 屏高)。
        #expect(layout.appKitPoint(fromGlobal: .zero) == CGPoint(x: 0, y: 982))
        // 主屏左下角：全局 (0, 982) ↔ AppKit (0, 0)。
        #expect(layout.appKitPoint(fromGlobal: CGPoint(x: 0, y: 982)) == .zero)
        #expect(layout.globalPoint(fromAppKit: .zero) == CGPoint(x: 0, y: 982))
    }

    @Test func 矩形换算用的是下边缘() {
        // 一个 64 点的图标，左上角在全局 (100, 200)。
        let global = CGRect(x: 100, y: 200, width: 64, height: 64)
        let appKit = layout.appKitRect(fromGlobal: global)
        // AppKit 矩形的原点是左下角：982 - (200 + 64) = 718。
        #expect(appKit == CGRect(x: 100, y: 718, width: 64, height: 64))
        #expect(layout.globalRect(fromAppKit: appKit) == global)
    }

    @Test func 外接屏的换算同样成立() {
        // 外接屏整块屏：全局 (-1920, -98, 1920, 1080)。
        // 底边对齐主屏，所以在 AppKit 里它的原点应是 (-1920, 0)。
        #expect(layout.appKitRect(fromGlobal: external.frame) == CGRect(x: -1920, y: 0, width: 1920, height: 1080))
        // 外接屏左上角一个点：全局 y 为负，AppKit y 超过主屏高度。
        #expect(layout.appKitPoint(fromGlobal: CGPoint(x: -1920, y: -98)) == CGPoint(x: -1920, y: 1080))
    }

    @Test func 往返换算不丢精度() {
        var rng = SeededRandom(seed: 2026)
        for _ in 0..<200 {
            let point = CGPoint(x: Double.random(in: -1920...1512, using: &rng), y: Double.random(in: -98...982, using: &rng))
            let back = layout.globalPoint(fromAppKit: layout.appKitPoint(fromGlobal: point))
            #expect(abs(back.x - point.x) < 1e-9)
            #expect(abs(back.y - point.y) < 1e-9)
        }
    }

    @Test func 找出点所在的显示器() {
        #expect(layout.display(containing: CGPoint(x: 10, y: 10)) == builtIn)
        #expect(layout.display(containing: CGPoint(x: -10, y: 10)) == external)
        // 外接屏比主屏高出的那一条（y 为负）只属于外接屏。
        #expect(layout.display(containing: CGPoint(x: -500, y: -50)) == external)
        #expect(layout.display(containing: CGPoint(x: 500, y: -50)) == nil)
        // 不在任何屏上时，取最近的。
        #expect(layout.display(nearestTo: CGPoint(x: 500, y: -50)) == builtIn)
        #expect(layout.display(nearestTo: CGPoint(x: 5000, y: 500)) == builtIn)
        #expect(layout.display(nearestTo: CGPoint(x: -5000, y: 500)) == external)
    }

    @Test func 跨屏的矩形算在面积大的那块屏上() {
        // 一个 64 点的图标横跨两块屏的接缝：40 点在外接屏，24 点在主屏。
        let mostlyExternal = CGRect(x: -40, y: 300, width: 64, height: 64)
        #expect(layout.display(bestFor: mostlyExternal) == external)
        let mostlyBuiltIn = CGRect(x: -24, y: 300, width: 64, height: 64)
        #expect(layout.display(bestFor: mostlyBuiltIn) == builtIn)
        // 完全在屏幕外：取离中心最近的屏。
        #expect(layout.display(bestFor: CGRect(x: 3000, y: 300, width: 64, height: 64)) == builtIn)
    }

    @Test func 屏内坐标以该屏左上角为原点() {
        let global = CGRect(x: -1820, y: 2, width: 64, height: 64)
        let local = external.localRect(fromGlobal: global)
        #expect(local == CGRect(x: 100, y: 100, width: 64, height: 64))
        #expect(external.globalRect(fromLocal: local) == global)
        #expect(external.localPoint(fromGlobal: CGPoint(x: -1920, y: -98)) == .zero)
        #expect(external.globalPoint(fromLocal: .zero) == CGPoint(x: -1920, y: -98))
    }

    @Test func 所有屏的外接矩形() {
        #expect(layout.bounds == CGRect(x: -1920, y: -98, width: 3432, height: 1080))
        #expect(DisplayLayout(displays: []).bounds.isNull)
        #expect(DisplayLayout(displays: []).primaryHeight == 0)
    }

    #if canImport(AppKit)
    /// 真机验证：用当前真实的显示器布局，把每块屏的全局矩形换算成 AppKit 坐标，
    /// 应当与系统自己报告的 NSScreen.frame 完全一致。这条同时验证了
    /// "DisplayLayout.current() 读得对"和"换算公式在多显示器下成立"。
    @MainActor
    @Test func 真实布局换算后与NSScreen一致() {
        let current = DisplayLayout.current()
        let screens = NSScreen.screens
        // 没有显示器的环境（无头的持续集成机器）跳过。
        guard !screens.isEmpty else { return }

        #expect(current.displays.count == screens.count)
        #expect(current.primary != nil)
        #expect(current.primaryHeight == screens[0].frame.height)

        for screen in screens {
            guard let id = screen.ddmDisplayID, let display = current.display(withID: id) else {
                Issue.record("NSScreen 在 DisplayLayout.current() 里找不到对应的显示器")
                continue
            }
            #expect(current.appKitRect(fromGlobal: display.frame) == screen.frame)
            #expect(current.globalRect(fromAppKit: screen.frame) == display.frame)
            #expect(display.scale == screen.backingScaleFactor)
            #expect(display.screen === screen)
        }

        // 鼠标位置：AppKit 报告的位置换算成全局坐标后，应与 CoreGraphics 报告的全局位置一致。
        let appKitMouse = NSEvent.mouseLocation
        if let cgMouse = CGEvent(source: nil)?.location {
            let converted = current.globalPoint(fromAppKit: appKitMouse)
            // 两次读取之间鼠标可能动了一点，留出余量。
            #expect(abs(converted.x - cgMouse.x) < 50)
            #expect(abs(converted.y - cgMouse.y) < 50)
        }
    }
    #endif
}
