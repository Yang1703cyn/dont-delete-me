// 自检模式（`--smoke-test [秒数] [--assume-visible]`）：给开发和验收用，普通用户用不到。
//
// 应用照常启动，然后自动：
//   1. 确认菜单栏图标和两个菜单项都在，图标被系统摆在了某块屏顶部的菜单栏区域里；
//   2. 走菜单项背后的同一个动作，把"暂停 → 继续"过一遍，确认暂停期间不出帧、继续后恢复出帧；
//   3. 到时间后把结果逐行打印到标准输出，再走「退出」菜单项背后的同一个动作正常退出。
//
// 最后一行有三种：
//   `smoke-test: PASS`          全部验证过，全部通过。退出码 0。
//   `smoke-test: PASS-LIMITED`  验证得了的都通过了，但桌面看不见（锁屏、熄屏、停在全屏空间、系统隐藏了桌面图标），
//                               应用按约定一帧不出，所以"出帧、图标上报"这半边没有验证。退出码 0。
//                               想在这种时候也跑完整条流水线，加 `--assume-visible`。
//   `smoke-test: FAIL`          有没通过的项，逐条列在前面。退出码 1。
//
// 它替代不了肉眼检查：图标是否真的出现在菜单栏、点开菜单的样子，仍需人工确认。

import AppKit
import DDMCore

@MainActor
final class SmokeTest {
    private let duration: TimeInterval
    private let statusMenu: StatusMenuController
    private let pipeline: FramePipeline
    private let assumesDesktopVisible: Bool
    private var failures: [String] = []
    /// 有没有哪一段因为桌面看不见而没能验证出帧。
    private var isLimited = false
    /// 当前这一段开始时的时刻和本进程已用的处理器时间，用来算这一段的处理器占用。
    private var phaseStartedAt: TimeInterval = 0
    private var phaseStartCPU: Double = 0

    init(duration: TimeInterval, statusMenu: StatusMenuController, pipeline: FramePipeline, assumesDesktopVisible: Bool = false) {
        self.duration = duration
        self.statusMenu = statusMenu
        self.pipeline = pipeline
        self.assumesDesktopVisible = assumesDesktopVisible
    }

    func start() {
        report("启动：菜单项 \(statusMenu.menuItemTitles)，菜单栏图标 \(statusMenu.hasIcon ? "有" : "无")")
        if assumesDesktopVisible {
            report("注意：本次强制把桌面当作看得见（--assume-visible），不代表桌面此刻真的看得见")
        }
        check(statusMenu.hasIcon, "菜单栏图标不存在")
        check(statusMenu.menuItemTitles == [L10n.pause, L10n.quit], "启动时菜单项应为 [暂停, 退出]")

        // 把总时长分成三段：运行 → 暂停 → 继续。
        beginPhase()
        after(duration / 3) { self.pauseViaMenu() }
    }

    private func pauseViaMenu() {
        // 状态项的窗口要等系统排好版才有位置，所以放到这里（启动后一段时间）再看。
        checkIconPlacement()

        let framesBeforePause = pipeline.stats.frames
        report("运行阶段：桌面\(visibilityText)，帧回调 \(framesBeforePause) 次，图标上报 \(pipeline.stats.iconUpdates) 次，\(phaseUsageText())")
        if shouldHaveFrames(inPhase: "运行阶段", frames: framesBeforePause) {
            check(framesBeforePause > 0, "运行阶段没有任何帧回调")
            check(pipeline.stats.iconUpdates > 0, "运行阶段没有收到图标上报")
        }

        statusMenu.togglePause(nil)
        check(PauseSwitch.shared.isPaused, "点「暂停」后全局开关应为暂停")
        check(statusMenu.menuItemTitles == [L10n.resume, L10n.quit], "暂停后菜单项应为 [继续, 退出]")

        let framesAtPause = pipeline.stats.frames
        beginPhase()
        after(duration / 3) { self.resumeViaMenu(framesAtPause: framesAtPause) }
    }

    private func resumeViaMenu(framesAtPause: Int) {
        let framesWhilePaused = pipeline.stats.frames - framesAtPause
        report("暂停阶段：菜单项 \(statusMenu.menuItemTitles)，帧回调 \(framesWhilePaused) 次，\(phaseUsageText())")
        check(framesWhilePaused == 0, "暂停期间不应有帧回调")

        statusMenu.togglePause(nil)
        check(!PauseSwitch.shared.isPaused, "点「继续」后全局开关应为运行")
        check(statusMenu.menuItemTitles == [L10n.pause, L10n.quit], "继续后菜单项应为 [暂停, 退出]")

        let framesAtResume = pipeline.stats.frames
        beginPhase()
        after(duration / 3) { self.finish(framesAtResume: framesAtResume) }
    }

    private func finish(framesAtResume: Int) {
        let framesAfterResume = pipeline.stats.frames - framesAtResume
        report("继续阶段：桌面\(visibilityText)，菜单项 \(statusMenu.menuItemTitles)，帧回调 \(framesAfterResume) 次，\(phaseUsageText())")
        if shouldHaveFrames(inPhase: "继续阶段", frames: framesAfterResume) {
            check(framesAfterResume > 0, "继续之后没有恢复帧回调")
        }

        let hiddenFrames = pipeline.stats.framesWhileDesktopHidden
        check(hiddenFrames == 0, "桌面看不见时不应有帧回调（出了 \(hiddenFrames) 次）")
        report("全程：帧回调 \(pipeline.stats.frames) 次，画脸 \(pipeline.stats.draws) 次，"
            + "因眼珠几乎没动而省下的重画 \(pipeline.stats.redrawsSaved) 次，图标上报 \(pipeline.stats.iconUpdates) 次")

        for failure in failures {
            report("未通过：\(failure)")
        }
        if failures.isEmpty, isLimited {
            report("受限：菜单、暂停与继续、「看不见时不出帧」已验证；出帧和图标上报没有验证。"
                + "请在桌面看得见时重跑，或加 --assume-visible 强制当作看得见")
        }
        report(failures.isEmpty ? (isLimited ? "PASS-LIMITED" : "PASS") : "FAIL")
        fflush(stdout)

        if failures.isEmpty {
            // 走「退出」菜单项背后的同一个动作。
            statusMenu.quit(nil)
        } else {
            exit(1)
        }
    }

    // MARK: 处理器占用

    private func beginPhase() {
        phaseStartedAt = ProcessInfo.processInfo.systemUptime
        phaseStartCPU = Self.processorSeconds()
    }

    /// 这一段里本进程的处理器占用（100% = 占满一个核心）。只是给开发看的参考数字，不参与通过与否的判断。
    private func phaseUsageText() -> String {
        let elapsed = ProcessInfo.processInfo.systemUptime - phaseStartedAt
        guard elapsed > 0 else { return "处理器占用 不详" }
        let used = Self.processorSeconds() - phaseStartCPU
        return String(format: "处理器占用 %.1f%%", used / elapsed * 100)
    }

    /// 本进程到现在一共用了多少秒处理器时间（用户态 + 内核态）。
    private static func processorSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private var visibilityText: String {
        pipeline.isDesktopVisible ? "看得见" : "看不见"
    }

    /// 一个"应用在干活"的阶段结束时，该不该要求它出过帧。
    ///
    /// - 桌面此刻看得见：该。
    /// - 看不见，但这一段出过帧：说明中途才变得看不见，出过的帧照常算数：该。
    /// - 看不见，而且一帧没出：这正是约定的行为（看不见就不出帧）。不算失败，但记下"这半边没验证"。
    private func shouldHaveFrames(inPhase phase: String, frames: Int) -> Bool {
        if pipeline.isDesktopVisible || frames > 0 { return true }
        isLimited = true
        report("\(phase)：桌面看不见（锁屏、熄屏、停在全屏空间，或系统隐藏了桌面图标），按约定一帧不出")
        return false
    }

    /// 菜单栏图标是否被系统摆到了某块屏顶部的菜单栏里。
    private func checkIconPlacement() {
        check(statusMenu.isIconVisible, "菜单栏图标没有被摆进菜单栏")
        guard let appKitFrame = statusMenu.iconFrameOnScreen else {
            report("菜单栏图标：没有位置")
            return
        }
        // 用 DDMCore 的坐标工具换成全局坐标（主屏左上角为原点、y 向下），再看它离所在屏的顶端多远。
        let layout = DisplayLayout.current()
        let frame = layout.globalRect(fromAppKit: appKitFrame)
        guard let display = layout.display(bestFor: frame) else {
            report("菜单栏图标：找不到它所在的显示器")
            check(false, "菜单栏图标不在任何显示器上")
            return
        }
        let offsetFromTop = frame.minY - display.frame.minY
        report("菜单栏图标：全局坐标 x=\(frame.minX) y=\(frame.minY) 宽 \(frame.width) 高 \(frame.height)；"
            + "在\(display.isPrimary ? "主屏" : "副屏")（\(Int(display.frame.width))×\(Int(display.frame.height)) @\(Int(display.scale))x），"
            + "距该屏顶端 \(offsetFromTop) 点；系统报告可见 \(statusMenu.isIconOnScreen)")
        // 菜单栏在屏幕最顶上，高度不超过几十点。实测 macOS 27 上状态项的窗口会比屏幕顶端高出 2 点，所以留几点余量。
        let isInMenuBarBand = abs(offsetFromTop) <= 8 && frame.maxY - display.frame.minY <= 60
        check(isInMenuBarBand, "菜单栏图标不在屏幕顶部的菜单栏区域里")
        check(statusMenu.isIconOnScreen, "系统报告菜单栏图标当前不可见")
    }

    private func check(_ condition: Bool, _ message: String) {
        if !condition {
            failures.append(message)
        }
    }

    private func report(_ line: String) {
        print("smoke-test: \(line)")
    }

    private func after(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}
