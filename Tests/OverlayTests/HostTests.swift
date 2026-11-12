// OverlayTests · OverlayHost 的启停（不建任何窗口）
//
// 这里给叠加层一个"没有显示器"的假布局，所以它不会创建窗口，也就不碰真实的屏幕和桌面。
// 需要真实窗口的验证在演示程序的自检里：swift run OverlayDemo --self-check。

import CoreGraphics
import DDMCore
import Foundation
import Testing
@testable import Overlay

@MainActor
private final class CountingSource: OverlayFrameSource {
    var frames = 0
    var draws = 0

    func overlayFrame(at time: FrameTime) -> OverlayFrame {
        frames += 1
        return OverlayFrame(items: [Fixture.item(x: 100, y: 100)], demand: .continuous)
    }

    func drawOverlayItem(_ item: OverlayItem, in context: CGContext, at time: FrameTime) {
        draws += 1
    }
}

@MainActor
@Suite("OverlayHost 启停")
struct HostTests {
    private func makeHost(pause: PauseSwitch = PauseSwitch()) -> OverlayHost {
        OverlayHost(pause: pause, layoutProvider: { DisplayLayout(displays: []) })
    }

    @Test func 启动之前和停止之后_桌面都算不可见() {
        let host = makeHost()
        #expect(!host.isDesktopVisible)
        host.start()
        host.stop()
        #expect(!host.isDesktopVisible)
        #expect(!host.diagnostics.isRunning)
    }

    @Test func 没有显示器_不可见_不出帧_不回调() {
        let host = makeHost()
        let source = CountingSource()
        host.frameSource = source
        var changes: [Bool] = []
        host.onDesktopVisibilityChange = { changes.append($0) }

        host.start()
        host.requestFrame()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))

        #expect(!host.isDesktopVisible)
        #expect(source.frames == 0 && source.draws == 0)
        #expect(changes.isEmpty)
        #expect(host.diagnostics.displays.isEmpty)
        #expect(host.diagnostics.frameLoop == "sleep")
        host.stop()
    }

    @Test func 重复启动和停止没有副作用_可以再次启动() {
        let host = makeHost()
        host.start()
        host.start()
        #expect(host.diagnostics.isRunning)
        host.stop()
        host.stop()
        #expect(!host.diagnostics.isRunning)
        host.start()
        #expect(host.diagnostics.isRunning)
        host.stop()
    }

    @Test func 暂停状态如实反映在快照里() {
        let pause = PauseSwitch()
        let host = makeHost(pause: pause)
        host.start()
        pause.setPaused(true)
        #expect(host.diagnostics.isPaused)
        pause.setPaused(false)
        #expect(!host.diagnostics.isPaused)
        host.stop()
    }

    @Test func 弱引用帧回调的接收方() {
        let host = makeHost()
        var source: CountingSource? = CountingSource()
        host.frameSource = source
        #expect(host.frameSource != nil)
        source = nil
        #expect(host.frameSource == nil)
    }

    @Test func 窗口层级_桌面层是图标层加一_拖拽层是拖影层加一() {
        let diagnostics = makeHost().diagnostics
        #expect(diagnostics.desktopWindowLevel == Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        #expect(diagnostics.dragWindowLevel == Int(CGWindowLevelForKey(.draggingWindow)) + 1)
        // 拖拽层要高于程序坞、菜单栏、普通窗口，低于屏保（锁屏时会被盖住）。
        #expect(diagnostics.dragWindowLevel > Int(CGWindowLevelForKey(.dockWindow)))
        #expect(diagnostics.dragWindowLevel > Int(CGWindowLevelForKey(.mainMenuWindow)))
        #expect(diagnostics.dragWindowLevel > Int(CGWindowLevelForKey(.popUpMenuWindow)))
        #expect(diagnostics.dragWindowLevel < Int(CGWindowLevelForKey(.screenSaverWindow)))
        #expect(diagnostics.desktopWindowLevel < Int(CGWindowLevelForKey(.normalWindow)))
    }
}
