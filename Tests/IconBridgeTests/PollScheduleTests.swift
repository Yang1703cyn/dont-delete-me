// 轮询节奏

import CoreGraphics
import DDMCore
import Foundation
import Testing
@testable import IconBridge

@Suite("轮询节奏")
struct PollScheduleTests {
    /// 测试用一套固定的参数（不随默认值的调整而变）：活跃时每 0.5 秒快速检查、每 2 秒完整读取；空闲时 3 秒 / 15 秒。
    private let policy = PollingPolicy(
        active: .init(quickInterval: 0.5, fullInterval: 2, quickDutyLimit: 1.0 / 30, fullDutyLimit: 1.0 / 30, recoveryInterval: 1),
        idle: .init(quickInterval: 3, fullInterval: 15, quickDutyLimit: 1.0 / 200, fullDutyLimit: 1.0 / 200, recoveryInterval: 5),
        followUpDelays: [0.4, 1.0],
        inconsistentRetryDelay: 0.2,
        minForcedSpacing: 0.15
    )

    private func outcome(
        full: Bool, at start: TimeInterval, duration: TimeInterval = 0.01,
        status: IconProviderStatus = .ok, changes: Bool = false, inconsistent: Bool = false, routine: Bool = true,
        requests: Int? = nil
    ) -> CycleOutcome {
        var outcome = CycleOutcome(
            snapshot: IconSnapshot(icons: [], status: status, capturedAt: start, revision: 1),
            update: nil, performedFullRead: full, startedAt: start, duration: duration, requestCount: requests ?? (full ? 4 : 1)
        )
        outcome.foundChanges = changes
        outcome.wasInconsistent = inconsistent
        outcome.wasRoutineRead = full && routine
        return outcome
    }

    @Test func 还没读过时立刻做一次完整读取() throws {
        let next = try #require(PollSchedule(policy: policy).next(pace: .active))
        #expect(next.kind == .full)
        #expect(next.at == 0)
    }

    @Test func 停止读取时没有下一次() {
        var schedule = PollSchedule(policy: policy)
        schedule.record(outcome(full: true, at: 100))
        #expect(schedule.next(pace: .suspended) == nil)
    }

    @Test func 活跃时_半秒后快速检查_两秒后完整读取() throws {
        var schedule = PollSchedule(policy: policy)
        schedule.record(outcome(full: true, at: 100))
        var next = try #require(schedule.next(pace: .active))
        #expect(next.kind == .quick)
        #expect(abs(next.at - 100.5) < 1e-9)

        for step in 1...3 {
            schedule.record(outcome(full: false, at: 100 + Double(step) * 0.5))
        }
        next = try #require(schedule.next(pace: .active))   // 上一个周期在 101.5，下一次到 102：该完整读取了
        #expect(next.kind == .full)
        #expect(abs(next.at - 102) < 1e-9)
    }

    @Test func 空闲时读得很慢() throws {
        var schedule = PollSchedule(policy: policy)
        schedule.record(outcome(full: true, at: 100))
        let next = try #require(schedule.next(pace: .idle))
        #expect(next.kind == .quick)
        #expect(abs(next.at - 103) < 1e-9)

        schedule.record(outcome(full: false, at: 112.5))
        let later = try #require(schedule.next(pace: .idle))
        #expect(later.kind == .full)
        #expect(abs(later.at - 115) < 1e-9)
    }

    @Test func 读取很慢时间隔自动拉长_图标多的桌面读得更稀() throws {
        var schedule = PollSchedule(policy: policy)
        // 常规的完整读取要 0.2 秒（大约是上百个图标的桌面）：占比上限 1/30 → 至少隔 6 秒。
        schedule.record(outcome(full: true, at: 100, duration: 0.2))
        schedule.record(outcome(full: false, at: 100.6, duration: 0.05))   // 快速检查 50 毫秒 → 至少隔 1.5 秒
        let next = try #require(schedule.next(pace: .active))
        #expect(next.kind == .quick)
        #expect(abs(next.at - 102.1) < 1e-9)

        schedule.record(outcome(full: false, at: 105, duration: 0.05))
        let full = try #require(schedule.next(pace: .active))
        #expect(full.kind == .full)
        #expect(abs(full.at - 106) < 1e-9)
    }

    @Test func 拉长有上限_最多到下限的四倍() throws {
        var schedule = PollSchedule(policy: policy)
        // 访达忙的时候，一次快速检查等了 1 秒、一次完整读取等了 2 秒：按比例要隔 30 秒 / 60 秒，实际最多 2 秒 / 8 秒。
        schedule.record(outcome(full: true, at: 100, duration: 2))
        schedule.record(outcome(full: false, at: 103, duration: 1))
        var next = try #require(schedule.next(pace: .active))
        #expect(next.kind == .quick)
        #expect(abs(next.at - 105) < 1e-9)              // 0.5 秒 × 4

        schedule.record(outcome(full: false, at: 107.5, duration: 1))
        next = try #require(schedule.next(pace: .active))
        #expect(next.kind == .full)
        #expect(abs(next.at - 108) < 1e-9)              // 2 秒 × 4
    }

    @Test func 偶然的一次慢读取不算数_取最近几次里最快的() throws {
        var schedule = PollSchedule(policy: policy)
        schedule.record(outcome(full: true, at: 100, duration: 0.05))
        schedule.record(outcome(full: true, at: 102, duration: 2))      // 访达忙了一下
        schedule.record(outcome(full: false, at: 102.1, duration: 0.01))
        schedule.record(outcome(full: false, at: 102.6, duration: 1))   // 又忙了一下
        let next = try #require(schedule.next(pace: .active))
        #expect(next.kind == .quick)
        #expect(abs(next.at - 103.1) < 1e-9)            // 仍是平常的 0.5 秒

        schedule.record(outcome(full: false, at: 103.6, duration: 0.01))
        let full = try #require(schedule.next(pace: .active))
        #expect(full.kind == .full)
        #expect(abs(full.at - 104) < 1e-9)              // 仍是平常的 2 秒
    }

    @Test func 第一次读取和有变化的读取很慢_不拉长间隔() throws {
        var schedule = PollSchedule(policy: policy)
        schedule.record(outcome(full: true, at: 100, duration: 0.3, routine: false))
        schedule.record(outcome(full: false, at: 101.9))
        let next = try #require(schedule.next(pace: .active))
        #expect(next.kind == .full)
        #expect(abs(next.at - 102) < 1e-9)
    }

    @Test func 发现变化后追加两次完整读取() throws {
        var schedule = PollSchedule(policy: policy)
        schedule.record(outcome(full: true, at: 100, duration: 0.1, changes: true, routine: false))
        var next = try #require(schedule.next(pace: .active))
        #expect(next.kind == .full)
        #expect(abs(next.at - 100.5) < 1e-9)   // 那次读取结束于 100.1，0.4 秒后追加第一次

        schedule.record(outcome(full: true, at: 100.5))
        next = try #require(schedule.next(pace: .active))
        #expect(next.kind == .quick)           // 第二次追加在 101.1；之前先轮到一次快速检查
        #expect(abs(next.at - 101.0) < 1e-9)

        schedule.record(outcome(full: false, at: 101.0))
        next = try #require(schedule.next(pace: .active))
        #expect(next.kind == .full)
        #expect(abs(next.at - 101.1) < 1e-9)   // 第二次追加：那次读取结束后 1.0 秒

        schedule.record(outcome(full: true, at: 101.1))
        next = try #require(schedule.next(pace: .active))
        #expect(next.kind == .quick)           // 追加读取做完，回到平常的节奏
        #expect(abs(next.at - 101.6) < 1e-9)
    }

    @Test func 读数作废后很快重读() throws {
        var schedule = PollSchedule(policy: policy)
        schedule.record(outcome(full: true, at: 100, duration: 0.1, inconsistent: true, routine: false))
        let next = try #require(schedule.next(pace: .idle))
        #expect(next.kind == .full)
        #expect(abs(next.at - 100.3) < 1e-9)
    }

    @Test func 状态不正常时隔一阵完整地重试_没有快速检查() throws {
        var schedule = PollSchedule(policy: policy)
        schedule.record(outcome(full: true, at: 100, status: .permissionDenied))
        var next = try #require(schedule.next(pace: .active))
        #expect(next.kind == .full)
        #expect(abs(next.at - 101) < 1e-9)
        next = try #require(schedule.next(pace: .idle))
        #expect(abs(next.at - 105) < 1e-9)
    }

    @Test func 开了叠放_靠设置认出来的按快速检查的间隔复查_靠位置认出来的按完整读取的间隔() throws {
        var schedule = PollSchedule(policy: policy)
        // 靠那一项设置认出来：这个周期没有向访达发任何请求，复查几乎不花开销。
        schedule.record(outcome(full: true, at: 100, status: .stacksEnabled, requests: 0))
        var next = try #require(schedule.next(pace: .active))
        #expect(next.kind == .full)
        #expect(abs(next.at - 100.5) < 1e-9)
        next = try #require(schedule.next(pace: .idle))
        #expect(abs(next.at - 103) < 1e-9)

        // 靠位置认出来：每次复查都要完整读一遍，不能太勤。
        schedule.record(outcome(full: true, at: 200, status: .stacksEnabled, requests: 4))
        next = try #require(schedule.next(pace: .active))
        #expect(next.kind == .full)
        #expect(abs(next.at - 202) < 1e-9)
        next = try #require(schedule.next(pace: .idle))
        #expect(abs(next.at - 215) < 1e-9)
    }

    @Test func 默认节奏_空闲比活跃慢_完整读取比快速检查稀() {
        let policy = PollingPolicy()
        #expect(policy.active.quickInterval < policy.active.fullInterval)
        #expect(policy.idle.quickInterval < policy.idle.fullInterval)
        #expect(policy.active.quickInterval < policy.idle.quickInterval)
        #expect(policy.active.fullInterval < policy.idle.fullInterval)
        #expect(policy.pace(.suspended) == nil)
        #expect(policy.pace(.active) == policy.active)
        #expect(policy.pace(.idle) == policy.idle)
    }

    @Test func 重置后回到还没读过的状态() throws {
        var schedule = PollSchedule(policy: policy)
        schedule.record(outcome(full: true, at: 100))
        schedule.reset()
        #expect(try #require(schedule.next(pace: .active)).at == 0)
    }
}

@Suite("锚点校准的像素分析")
struct AnchorCalibrationTests {
    /// 造一小块位图：透明底，上面画若干实心矩形（像素坐标）。
    private func bitmap(width: Int, height: Int, scale: CGFloat, origin: CGPoint, rects: [(CGRect, (UInt8, UInt8, UInt8, UInt8))]) -> AnchorCalibration.Bitmap {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for (rect, color) in rects {
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    let index = (y * width + x) * 4
                    pixels[index] = color.0; pixels[index + 1] = color.1; pixels[index + 2] = color.2; pixels[index + 3] = color.3
                }
            }
        }
        return AnchorCalibration.Bitmap(width: width, height: height, rgba: pixels, scale: scale, origin: origin)
    }

    @Test func 量出纯色方块和标签的矩形_换算成全局坐标() throws {
        // 2 倍屏：这块位图的左上角在全局 (200, 220)。方块画在点坐标 (268,268)-(332,332)，标签在其下方。
        let image = CGRect(x: (268 - 200) * 2, y: (268 - 220) * 2, width: 128, height: 128)
        let label = CGRect(x: (275 - 200) * 2, y: (336 - 220) * 2, width: 100, height: 32)
        let bitmap = bitmap(width: 400, height: 360, scale: 2, origin: CGPoint(x: 200, y: 220), rects: [
            (image, (255, 0, 255, 255)),
            (label, (255, 255, 255, 255)),
        ])
        let measured = AnchorCalibration.measure(bitmap, marker: (255, 0, 255))
        #expect(measured.imageRect == CGRect(x: 268, y: 268, width: 64, height: 64))
        #expect(measured.imageRect?.center == CGPoint(x: 300, y: 300))   // 中心就是 desktop position
        #expect(measured.labelRect == CGRect(x: 275, y: 336, width: 50, height: 16))
        #expect(measured.opaquePixelCount == 128 * 128 + 100 * 32)
    }

    @Test func 文字的淡投影不算进标签() throws {
        let bitmap = bitmap(width: 200, height: 200, scale: 1, origin: .zero, rects: [
            (CGRect(x: 60, y: 20, width: 64, height: 64), (255, 0, 255, 255)),
            (CGRect(x: 40, y: 90, width: 110, height: 20), (0, 0, 0, 60)),        // 投影：很淡
            (CGRect(x: 50, y: 92, width: 90, height: 14), (255, 255, 255, 255)),  // 文字本身
        ])
        let measured = AnchorCalibration.measure(bitmap, marker: (255, 0, 255))
        #expect(measured.labelRect == CGRect(x: 50, y: 92, width: 90, height: 14))
    }

    @Test func 颜色略有偏差也认得出方块() {
        let bitmap = bitmap(width: 100, height: 100, scale: 1, origin: .zero, rects: [
            (CGRect(x: 10, y: 10, width: 64, height: 64), (236, 30, 228, 255)),
        ])
        #expect(AnchorCalibration.measure(bitmap, marker: (255, 0, 255)).imageRect == CGRect(x: 10, y: 10, width: 64, height: 64))
    }

    @Test func 空图_锁屏时系统不给窗口内容() {
        let bitmap = bitmap(width: 50, height: 50, scale: 2, origin: .zero, rects: [])
        let measured = AnchorCalibration.measure(bitmap, marker: (255, 0, 255))
        #expect(measured.imageRect == nil)
        #expect(measured.labelRect == nil)
        #expect(measured.opaquePixelCount == 0)
    }

    @Test func 没有方块时不把别的东西当成标签() {
        let bitmap = bitmap(width: 50, height: 50, scale: 1, origin: .zero, rects: [
            (CGRect(x: 5, y: 5, width: 20, height: 20), (255, 255, 255, 255)),
        ])
        let measured = AnchorCalibration.measure(bitmap, marker: (255, 0, 255))
        #expect(measured.imageRect == nil)
        #expect(measured.labelRect == nil)
        #expect(measured.opaquePixelCount == 400)
    }
}
