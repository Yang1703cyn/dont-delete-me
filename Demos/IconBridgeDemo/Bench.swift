// IconBridgeDemo · 读取开销：单次读取耗时，以及不同轮询频率下本进程和访达各占多少 CPU
//
// 运行：swift run IconBridgeDemo --bench        （只读，约 3 分钟）
//
// CPU 占用 = 这段时间里进程用掉的 CPU 时间 ÷ 这段时间的长度（100% = 占满一个核）。
// 访达的数字包含它自己的日常开销，所以先量一段"不读取"的基线作对照。

import DDMCore
import Foundation
import IconBridge

@MainActor
final class Bench {
    private let session = DemoSession(printsUpdates: false)
    private let finder = CPUMeter.finderPID
    private let myself = getpid()

    /// 一段时间内的测量结果。
    private struct Sample {
        var seconds: Double
        var ownCPU: Double
        var finderCPU: Double?
        /// 主线程两次空转之间的最长间隔（毫秒）：读取如果卡住主线程，这个数会接近读取耗时。
        var longestMainThreadGap: Double
        var cycleIndex: Int
    }

    /// 让主线程空转 `seconds` 秒并测量。`tick` 每圈调用一次（用来按固定频率触发读取）。
    private func measure(_ seconds: TimeInterval, tick: (TimeInterval) -> Void = { _ in }) -> Sample {
        let cycleIndex = session.cycles.count
        let ownBefore = CPUMeter.cpuSeconds(of: myself) ?? 0
        let finderBefore = finder.flatMap(CPUMeter.cpuSeconds(of:))
        let begin = now()
        var last = begin
        var longestGap = 0.0
        while now() - begin < seconds {
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
            let time = now()
            longestGap = max(longestGap, time - last)
            last = time
            tick(time)
        }
        let elapsed = now() - begin
        let ownAfter = CPUMeter.cpuSeconds(of: myself) ?? 0
        let finderAfter = finder.flatMap(CPUMeter.cpuSeconds(of:))
        var finderCPU: Double?
        if let finderBefore, let finderAfter {
            finderCPU = (finderAfter - finderBefore) / elapsed * 100
        }
        return Sample(seconds: elapsed, ownCPU: (ownAfter - ownBefore) / elapsed * 100, finderCPU: finderCPU, longestMainThreadGap: longestGap * 1000, cycleIndex: cycleIndex)
    }

    private func report(_ title: String, _ sample: Sample) {
        let finderText = sample.finderCPU.map { String(format: "%.2f%%", $0) } ?? "读不到"
        say(String(format: "%@：本进程 CPU %.2f%%，访达 CPU %@，主线程最长停顿 %.1f 毫秒", title, sample.ownCPU, finderText, sample.longestMainThreadGap))
        say("    \(session.cycleSummary(since: sample.cycleIndex))")
    }

    func run() -> Int32 {
        say("读取开销测量（只读）。本进程 pid \(myself)，访达 pid \(finder.map(String.init) ?? "?")。")

        // —— 基线：不读取 ——
        let baseline = measure(8)
        report("基线（图标桥没有启动，8 秒）", baseline)

        session.start()
        guard session.waitForFirstUpdate(timeout: 20), session.provider.status == .ok else {
            say("第一次读取没有成功，状态：\(statusName(session.provider.status))。中止。")
            return 1
        }
        say("桌面图标 \(session.provider.snapshot.icons.count) 个。第一次读取：\(session.cycleSummary())")

        // —— 两档节奏 ——
        session.provider.setPollingPace(.active)
        pump(0.5)
        report("活跃节奏（用户正在操作，32 秒）", measure(32))

        session.provider.setPollingPace(.idle)
        pump(0.5)
        report("空闲节奏（用户有一阵没动，65 秒）", measure(65))

        // —— 固定频率的完整读取（用 refreshNow() 触发；背景轮询保持空闲档）——
        for frequency in [1.0, 2.0, 5.0] {
            var nextFire = now()
            let sample = measure(10) { time in
                if time >= nextFire {
                    nextFire += 1 / frequency
                    self.session.provider.refreshNow()
                }
            }
            report(String(format: "每秒 %.0f 次完整读取（10 秒）", frequency), sample)
        }

        // —— 应用连续多帧调用 refreshNow()（松手后等结局时的最坏情况）——
        let burst = measure(4) { _ in self.session.provider.refreshNow() }
        report("连续不断地调用 refreshNow()（4 秒）", burst)

        // —— 停止读取 ——
        session.provider.setPollingPace(.suspended)
        pump(0.5)
        report("停止读取（suspended，6 秒）", measure(6))

        session.stop()
        say("说明：访达的数字要减去基线才是图标桥造成的部分；\"主线程最长停顿\"远小于一次完整读取的耗时，说明读取没有卡住主线程。")
        return 0
    }
}
