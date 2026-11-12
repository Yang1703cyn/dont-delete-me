// 应用外壳：启动时建菜单栏图标、装配并启动帧流水线；退出时停下来。

import AppKit
import DDMCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: LaunchOptions
    private var statusMenu: StatusMenuController?
    private var pipeline: FramePipeline?
    private var smokeTest: SmokeTest?

    init(options: LaunchOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusMenu = StatusMenuController(pause: .shared)
        let pipeline = Assembly.makePipeline()
        pipeline.start()
        self.statusMenu = statusMenu
        self.pipeline = pipeline

        if let duration = options.smokeTestDuration {
            let smokeTest = SmokeTest(duration: duration, statusMenu: statusMenu, pipeline: pipeline)
            smokeTest.start()
            self.smokeTest = smokeTest
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pipeline?.stop()
    }
}
