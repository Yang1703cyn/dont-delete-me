// OverlayDemo · 公用小工具：命令行参数、计时、处理器占用、被终止时的收尾。

import AppKit
import CoreGraphics
import DDMCore
import Foundation
import Overlay

/// 演示程序最长允许运行多久（秒）。任何模式都不会超过它。
let demoTimeLimit: TimeInterval = 60

/// 命令行参数：`--名字 值` 或 `--开关`。
struct Arguments {
    private let items: [String]

    init(_ items: [String] = Array(CommandLine.arguments.dropFirst())) {
        self.items = items
    }

    func has(_ flag: String) -> Bool { items.contains(flag) }

    func value(_ name: String) -> String? {
        guard let index = items.firstIndex(of: name), index + 1 < items.count else { return nil }
        return items[index + 1]
    }

    func seconds(_ name: String, default fallback: TimeInterval) -> TimeInterval {
        let requested = value(name).flatMap(Double.init) ?? fallback
        return min(max(requested, 1), demoTimeLimit)
    }

    func int(_ name: String, default fallback: Int) -> Int {
        value(name).flatMap(Int.init) ?? fallback
    }
}

func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

/// 让主线程"转一会儿"：定时器、显示刷新回调、图层提交、系统通知都照常进行。被要求退出时提前返回。
///
/// 这里不是简单地转 RunLoop，而是像 `NSApplication.run()` 那样取出并分发应用事件。
/// 实测（macOS 27）：只转 RunLoop 的话，"屏幕睡眠 / 唤醒"这类系统通知根本送不到——
/// 演示程序就会和真实应用表现不一样。
@MainActor
func spin(_ seconds: TimeInterval) {
    let end = Date().addingTimeInterval(seconds)
    while !Lifecycle.shared.shouldQuit, Date() < end {
        // 每 0.25 秒回来看一眼有没有被要求退出；间隔再短的话，演示程序自己的空转会混进测量结果里。
        let slice = min(end, Date().addingTimeInterval(0.25))
        if let event = NSApplication.shared.nextEvent(matching: .any, until: slice, inMode: .default, dequeue: true) {
            NSApplication.shared.sendEvent(event)
        }
    }
}

/// 本进程到目前为止用掉的处理器时间（用户态 + 内核态，秒）。
func processCPUSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

/// 一段时间内的处理器占用：100% = 占满一个核心。
struct CPUMeter {
    private let startCPU = processCPUSeconds()
    private let startWall = uptime()

    var percent: Double {
        let wall = uptime() - startWall
        return wall > 0 ? (processCPUSeconds() - startCPU) / wall * 100 : 0
    }
}

/// 运行的收尾：被 Ctrl-C 或 kill 终止时也要先关掉所有窗口再退出；另有一道保险，到时间强制结束。
@MainActor
final class Lifecycle {
    static let shared = Lifecycle()

    private(set) var shouldQuit = false
    private var sources: [any DispatchSourceSignal] = []
    private var cleanups: [@MainActor () -> Void] = []

    /// 登记一件"退出前要做的事"（例如停止叠加层）。
    func onExit(_ cleanup: @escaping @MainActor () -> Void) {
        cleanups.append(cleanup)
    }

    func install() {
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    print("[OverlayDemo] 收到终止信号，正在收尾…")
                    self?.shouldQuit = true
                }
            }
            source.resume()
            sources.append(source)
        }
        // 保险：无论哪种模式，超过上限 5 秒还没结束就强制收尾退出。
        let timer = Timer(timeInterval: demoTimeLimit + 5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                print("[OverlayDemo] 超过时间上限，强制结束。")
                self?.finish(code: 2)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 做完所有收尾，退出。
    func finish(code: Int32) -> Never {
        for cleanup in cleanups.reversed() { cleanup() }
        cleanups.removeAll()
        // 让窗口的关闭真正送达系统。
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        exit(code)
    }
}

/// 把运行状态快照打印成几行字。
func describe(_ diagnostics: OverlayDiagnostics) -> String {
    var lines: [String] = []
    lines.append(
        "  桌面可见=\(diagnostics.isDesktopVisible) 暂停=\(diagnostics.isPaused) 锁屏=\(diagnostics.isScreenLocked)"
            + " 屏幕睡眠=\(diagnostics.areDisplaysAsleep) 帧循环=\(diagnostics.frameLoop) 节拍=\(diagnostics.clockSource)"
            + " 帧=\(diagnostics.frameCount) 绘制=\(diagnostics.drawCount)"
    )
    for display in diagnostics.displays {
        lines.append(
            "  屏 \(display.id.rawValue)（\(Int(display.frame.width))×\(Int(display.frame.height)) @\(Int(display.scale))x）："
                + "图标层=\(display.iconLayer) 桌面层窗口=\(display.desktopWindowCount)（当前空间有=\(display.hasWindowOnActiveSpace)）"
                + " 被挡住=\(display.isOccluded) 看得见=\(display.isVisible)"
                + " 画布项=\(display.desktopItemCount) 拖拽项=\(display.dragItemCount) 拖拽层显示=\(display.isDragWindowShown)"
        )
    }
    return lines.joined(separator: "\n")
}

func format(_ value: Double, _ digits: Int = 1) -> String {
    String(format: "%.\(digits)f", value)
}
