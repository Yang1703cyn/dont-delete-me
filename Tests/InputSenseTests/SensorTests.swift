// InputSenseTests · 模块入口：薄层和判断器接在一起；以及判断器够不够快

import CoreGraphics
import DDMCore
import Foundation
import Testing
@testable import InputSense

@MainActor
@Suite("模块入口")
struct SensorTests {
    let snapshot = IconSnapshot(icons: [Fixture.iconA, Fixture.iconB], status: .ok, capturedAt: 900, revision: 1)

    func time(_ seconds: TimeInterval) -> FrameTime {
        FrameTime(monotonic: 1000 + seconds, wallClock: Date(timeIntervalSince1970: 1_700_000_000 + seconds))
    }

    @Test func 每次更新读一次鼠标_事实里带着传入的时间() throws {
        let environment = FakeEnvironment()
        environment.pointer = PointerSample(position: CGPoint(x: 130, y: 130))
        let sensor = InteractionSensor(environment: environment)

        let facts = sensor.update(time: time(0), icons: .unchanged(snapshot))
        #expect(facts.time == time(0))
        #expect(facts.mouse.position == CGPoint(x: 130, y: 130))
        #expect(facts.isMouseOverDesktop)
        #expect(facts.hover?.iconID == Fixture.iconA.id)
        #expect(facts.trash?.estimatedRect == Fixture.trash.rect)
        #expect(environment.pointerReads == 1)
        #expect(sensor.lastSurface == .desktopIcons)
        #expect(sensor.surfaceSampleCount == 1)
    }

    @Test func 没有人调用更新时什么都不读() throws {
        let environment = FakeEnvironment()
        let sensor = InteractionSensor(environment: environment)
        _ = sensor
        #expect(environment.pointerReads == 0)
        #expect(environment.surfaceQueries == 0)
        #expect(environment.draggingFlags.isEmpty)
    }

    @Test func 拖进废纸篓_松手点交给薄层去学_拖拽期间告诉薄层正在拖() throws {
        let environment = FakeEnvironment()
        environment.pointer = PointerSample(position: CGPoint(x: 130, y: 140))
        let sensor = InteractionSensor(environment: environment)
        var clock = 0.0
        func step(_ icons: IconUpdate? = nil) -> InteractionFacts {
            clock += 1.0 / 60
            return sensor.update(time: time(clock), icons: icons ?? .unchanged(snapshot))
        }

        _ = step()
        environment.pointer.buttons = [.left]
        _ = step()
        environment.pointer.position = Fixture.trashCenter
        #expect(step().drag?.iconID == Fixture.iconA.id)
        _ = step()
        #expect(environment.draggingFlags.last == true)

        environment.surfaceValue = .dock          // 松手处最上面是程序坞
        environment.pointer.buttons = []
        let released = step()
        #expect(released.releasedDrags.count == 1)
        #expect(released.wantsIconRefresh)

        let gone = IconSnapshot(icons: [Fixture.iconB], status: .ok, capturedAt: 1000 + clock, revision: 2)
        let facts = step(IconUpdate(snapshot: gone, changes: [.removed(Fixture.iconA, trashed: .yes)]))
        #expect(facts.dragOutcomes.map(\.kind) == [.trashed])
        #expect(facts.deletions.count == 1)
        #expect(environment.learned == [Fixture.trashCenter])
    }

    @Test func 重置丢掉进行到一半的判断() throws {
        let environment = FakeEnvironment()
        environment.pointer = PointerSample(position: CGPoint(x: 130, y: 140))
        let sensor = InteractionSensor(environment: environment)
        _ = sensor.update(time: time(0), icons: .unchanged(snapshot))
        environment.pointer.buttons = [.left]
        _ = sensor.update(time: time(0.02), icons: .unchanged(snapshot))
        environment.pointer.position = CGPoint(x: 300, y: 300)
        #expect(sensor.update(time: time(0.04), icons: .unchanged(snapshot)).drag != nil)

        sensor.reset()
        let facts = sensor.update(time: time(5), icons: .unchanged(snapshot))
        #expect(facts.drag == nil)
        #expect(facts.mouse.idleDuration == 0)
        #expect(sensor.surfaceSampleCount == 1)
    }

    @Test func 薄层说图标被遮住_就没有悬停() throws {
        let environment = FakeEnvironment()
        environment.pointer = PointerSample(position: CGPoint(x: 130, y: 130))
        environment.surfaceValue = .shieldedDesktop
        let sensor = InteractionSensor(environment: environment)
        let facts = sensor.update(time: time(0), icons: .unchanged(snapshot))
        #expect(facts.hover == nil)
        #expect(!facts.isMouseOverDesktop)
        #expect(sensor.lastSurface == .shieldedDesktop)
    }
}

@Suite("性能")
struct PerformanceTests {
    @Test func 一百个图标时判断器一帧远小于半毫秒() throws {
        var icons: [DesktopIcon] = []
        for index in 0..<100 {
            icons.append(Fixture.icon(UInt64(index + 1), x: 40 + CGFloat(index % 20) * 70, y: 40 + CGFloat(index / 20) * 110))
        }
        var stage = Stage(at: CGPoint(x: 60, y: 60), icons: icons)
        stage.wait(0.2)
        stage.press()
        stage.frame()

        let frames = 3000
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            // 拖着图标在一百个图标上方来回走：悬停命中测试、甩动、废纸篓、省电信号全都在算。
            stage.follow(for: Double(frames) / 60) { t in
                CGPoint(x: 700 + 600 * sin(t * 3), y: 300 + 200 * cos(t * 5))
            }
        }
        let perFrame = Double(elapsed.components.attoseconds) / 1e18 + Double(elapsed.components.seconds)
        let milliseconds = perFrame / Double(frames) * 1000
        // 目标是整个 update 不超过 0.5 毫秒；纯逻辑部分应当只占其中很小一块。
        // 这里的上限放得很宽（调试版、机器忙的时候也不该误报），实测数字见模块说明。
        #expect(milliseconds < 0.2, "每帧 \(milliseconds) 毫秒")
    }
}
