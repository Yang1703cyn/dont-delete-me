// InputSenseTests · 鼠标、悬停、窗口遮挡、省电信号

import CoreGraphics
import DDMCore
import Foundation
import Testing
@testable import InputSense

@Suite("鼠标")
struct MouseTests {
    @Test func 位置按键和速度() throws {
        var stage = Stage(at: CGPoint(x: 700, y: 500))
        stage.wait(0.2)
        stage.move(to: CGPoint(x: 1300, y: 500), in: 1)   // 向右 600 点/秒
        let mouse = stage.last.mouse
        #expect(mouse.position == CGPoint(x: 1300, y: 500))
        #expect(abs(mouse.velocity.dx - 600) < 15)
        #expect(abs(mouse.velocity.dy) < 1)
        #expect(abs(mouse.speed - 600) < 15)
        #expect(mouse.buttons == [])
        #expect(mouse.idleDuration == 0)

        stage.press(.right)
        #expect(stage.frame().mouse.buttons == [.right])
        stage.release(.right)
    }

    @Test func 停下后速度归零_静止时长开始累计_一动就归零() throws {
        var stage = Stage(at: CGPoint(x: 700, y: 500))
        stage.move(to: CGPoint(x: 900, y: 500), in: 0.3)
        stage.wait(0.5)
        #expect(stage.last.mouse.velocity == .zero)
        #expect(abs(stage.last.mouse.idleDuration - 0.5) < 0.02)

        stage.wait(2)
        #expect(abs(stage.last.mouse.idleDuration - 2.5) < 0.02)

        stage.position.x += 1
        #expect(stage.frame().mouse.idleDuration == 0)
    }

    @Test func 事实里的时间就是传进来的那个() throws {
        var stage = Stage(at: CGPoint(x: 700, y: 500))
        let facts = stage.frame()
        #expect(facts.time == stage.time)
    }
}

@Suite("悬停")
struct HoverTests {
    @Test func 停在图标上_给出是哪个图标和已经多久() throws {
        var stage = Stage(at: CGPoint(x: 700, y: 500))
        stage.wait(0.1)
        #expect(stage.last.hover == nil)

        stage.move(to: CGPoint(x: 130, y: 130), in: 0.3)
        let entered = try #require(stage.last.hover)
        #expect(entered.iconID == Fixture.iconA.id)
        #expect(entered.duration < 0.1)

        stage.wait(1)
        let later = try #require(stage.last.hover)
        #expect(later.iconID == Fixture.iconA.id)
        #expect(later.duration > 1 && later.duration < 1.1)
        #expect(stage.last.isMouseOverDesktop)
    }

    @Test func 标签也算可点击区域_图像和标签之间来回不重新计时() throws {
        var stage = Stage(at: CGPoint(x: 130, y: 130))
        stage.wait(0.5)
        stage.move(to: CGPoint(x: 96, y: 180), in: 0.1)   // 标签比图像宽：这一点在标签里、图像外
        stage.wait(0.5)
        let hover = try #require(stage.last.hover)
        #expect(hover.iconID == Fixture.iconA.id)
        #expect(hover.duration > 1)
    }

    @Test func 外接矩形的空角点不中图标() throws {
        // (92, 120) 在"图像 ∪ 标签"的外接矩形里，但既不在图像上也不在标签上。
        var stage = Stage(at: CGPoint(x: 92, y: 120))
        stage.wait(0.5)
        #expect(stage.last.hover == nil)
    }

    @Test func 离开再回来_重新计时_换一个图标也重新计时() throws {
        var stage = Stage(at: CGPoint(x: 130, y: 130))
        stage.wait(1)
        stage.move(to: CGPoint(x: 220, y: 130), in: 0.1)
        #expect(stage.last.hover == nil)
        stage.move(to: CGPoint(x: 130, y: 130), in: 0.1)
        #expect(try #require(stage.last.hover).duration < 0.1)

        stage.wait(1)
        stage.move(to: CGPoint(x: 330, y: 130), in: 0.2)
        let onB = try #require(stage.last.hover)
        #expect(onB.iconID == Fixture.iconB.id)
        #expect(onB.duration < 0.2)
    }

    @Test func 按着键的时候不算悬停() throws {
        var stage = Stage(at: CGPoint(x: 130, y: 130))
        stage.wait(0.5)
        #expect(stage.last.hover != nil)
        stage.press()
        #expect(stage.frame().hover == nil)
        stage.wait(0.3)
        #expect(stage.last.hover == nil)
        stage.release()
        // 松开后重新开始算。
        #expect(try #require(stage.frame().hover).duration < 0.05)
    }

    @Test func 图标桥状态不正常时_没有悬停也不会起拖() throws {
        var stage = Stage(at: CGPoint(x: 130, y: 130))
        stage.reportReset(icons: [], status: .finderUnavailable)
        stage.wait(0.5)
        #expect(stage.last.hover == nil)
        stage.drag(to: CGPoint(x: 400, y: 400), in: 0.3)
        #expect(stage.last.drag == nil)
    }
}

@Suite("被窗口挡住")
struct OcclusionTests {
    @Test func 图标被别的窗口挡住_不算悬停也不算拖() throws {
        var stage = Stage(at: CGPoint(x: 130, y: 140))
        stage.surface = { _ in .otherWindow }
        stage.wait(1)
        #expect(stage.facts.allSatisfy { $0.hover == nil })
        #expect(stage.facts.allSatisfy { !$0.isMouseOverDesktop })

        stage.drag(to: CGPoint(x: 500, y: 400), in: 0.4)
        stage.release()
        stage.wait(1)
        #expect(stage.facts.allSatisfy { $0.drag == nil })
        #expect(stage.facts.allSatisfy { $0.releasedDrags.isEmpty })
        #expect(stage.outcomes.isEmpty)
        #expect(stage.refreshRequests == 0)
    }

    @Test(arguments: [PointerSurface.shieldedDesktop, .unknown])
    func 图标被系统的遮挡窗口盖住或查不出来_同样不算(surface: PointerSurface) throws {
        var stage = Stage(at: CGPoint(x: 130, y: 140))
        stage.surface = { _ in surface }
        stage.wait(0.5)
        stage.drag(to: CGPoint(x: 500, y: 400), in: 0.4)
        #expect(stage.facts.allSatisfy { $0.hover == nil && $0.drag == nil && !$0.isMouseOverDesktop })
    }

    @Test func 窗口只挡住图标的一半_露出的那一半照常() throws {
        // 一个窗口盖住了 x ≥ 132 的部分：图标 A（x 100…164）露出左半边。
        var stage = Stage(at: CGPoint(x: 115, y: 130))
        stage.surface = { $0.x >= 132 ? .otherWindow : .desktopIcons }
        stage.wait(0.5)
        #expect(stage.last.hover?.iconID == Fixture.iconA.id)

        stage.move(to: CGPoint(x: 150, y: 130), in: 0.1)   // 挪到被挡住的那一半
        stage.wait(0.3)
        #expect(stage.last.hover == nil)
        #expect(!stage.last.isMouseOverDesktop)
        stage.drag(to: CGPoint(x: 150, y: 400), in: 0.3)
        #expect(stage.last.drag == nil)
        stage.release()

        stage.move(to: CGPoint(x: 115, y: 130), in: 0.2)   // 回到露出的那一半
        stage.wait(0.1)
        stage.drag(to: CGPoint(x: 115, y: 400), in: 0.3)
        #expect(stage.last.drag?.iconID == Fixture.iconA.id)
    }

    @Test func 悬停时窗口冒出来盖住图标_半秒内悬停消失() throws {
        var stage = Stage(at: CGPoint(x: 130, y: 130))
        stage.wait(1)
        #expect(stage.last.hover != nil)
        stage.surface = { _ in .otherWindow }   // 鼠标没动，一个窗口自己出现了
        stage.wait(0.52)
        #expect(stage.last.hover == nil)
    }

    @Test func 按下的那一刻一定现查_而且查的是按下点() throws {
        var stage = Stage(at: CGPoint(x: 130, y: 140))
        stage.wait(0.26)
        let before = stage.surfaceQueries.count
        stage.press()
        stage.frame()
        #expect(stage.surfaceQueries.count == before + 1)
        #expect(stage.surfaceQueries.last == CGPoint(x: 130, y: 140))
    }

    @Test func 开始拖之后窗口怎么变都不影响这次拖拽() throws {
        var stage = Stage(at: CGPoint(x: 130, y: 140))
        stage.wait(0.2)
        stage.drag(to: CGPoint(x: 300, y: 300), in: 0.2)
        stage.surface = { _ in .otherWindow }   // 拖到了一个窗口上方
        stage.move(to: CGPoint(x: 600, y: 300), in: 0.3)
        #expect(stage.last.drag?.iconID == Fixture.iconA.id)
        #expect(!stage.last.isMouseOverDesktop)
    }
}

@Suite("遮挡判断的频率与省电信号")
struct PacingTests {
    @Test func 鼠标在动时每秒最多查十五次() throws {
        var stage = Stage(at: CGPoint(x: 400, y: 600))
        stage.frame()
        let before = stage.surfaceQueries.count
        stage.move(to: CGPoint(x: 1400, y: 700), in: 1)   // 60 帧
        let queries = stage.surfaceQueries.count - before
        #expect((14...16).contains(queries), "一秒里查了 \(queries) 次")
    }

    @Test func 鼠标停在图标上时每秒查两次() throws {
        var stage = Stage(at: CGPoint(x: 130, y: 130))
        stage.wait(0.5)
        let before = stage.surfaceQueries.count
        stage.wait(3)
        let queries = stage.surfaceQueries.count - before
        #expect((5...7).contains(queries), "三秒里查了 \(queries) 次")
    }

    @Test func 鼠标停在空白处时每秒只查一次() throws {
        var stage = Stage(at: CGPoint(x: 400, y: 600))
        stage.wait(0.5)
        let before = stage.surfaceQueries.count
        stage.wait(4)
        let queries = stage.surfaceQueries.count - before
        #expect((3...5).contains(queries), "四秒里查了 \(queries) 次")
    }

    @Test func 鼠标进入图标的那一帧立刻查_不等限频() throws {
        var stage = Stage(at: CGPoint(x: 90, y: 130))
        stage.wait(0.5)                              // 停在空白处：上一次查询是将近半秒之前
        let before = stage.surfaceQueries.count
        stage.position = CGPoint(x: 101, y: 130)   // 上一次查询刚过去一帧，但这一帧进了图标 A
        let facts = stage.frame()
        #expect(stage.surfaceQueries.count == before + 1)
        #expect(facts.hover?.iconID == Fixture.iconA.id)
    }

    @Test func 飞快扫过一排图标_查窗口的次数有上限() throws {
        // 一排 20 个图标，间隔 70 点；鼠标以每秒 4200 点的速度横扫过去（每帧 70 点，每帧都进一个新图标）。
        var icons: [DesktopIcon] = []
        for index in 0..<20 { icons.append(Fixture.icon(UInt64(index + 1), x: 60 + CGFloat(index) * 70, y: 100)) }
        var stage = Stage(at: CGPoint(x: 40, y: 130), icons: icons)
        stage.wait(0.3)
        let before = stage.surfaceQueries.count
        stage.move(to: CGPoint(x: 1440, y: 130), in: 20.0 / 60)
        let queries = stage.surfaceQueries.count - before
        // 进入图标要尽快查，但两次之间至少隔 1/30 秒：20 帧里最多 11 次。
        #expect((8...11).contains(queries), "20 帧里查了 \(queries) 次")
    }

    @Test func 离开图标不用急着查() throws {
        var stage = Stage(at: CGPoint(x: 130, y: 130))
        stage.wait(0.52)                             // 停在图标上：刚在半秒处例行查过一次
        let before = stage.surfaceQueries.count
        stage.position = CGPoint(x: 220, y: 130)     // 一步跨出图标
        let facts = stage.frame()
        #expect(facts.hover == nil)                  // 悬停照样立刻结束（下面没有图标了）
        #expect(stage.surfaceQueries.count == before)
    }

    @Test func 按着键移动时慢慢查() throws {
        // 在空白处按下、拖出一个选框，划过图标：不可能有悬停，每秒查 5 次就够。
        var stage = Stage(at: CGPoint(x: 600, y: 600))
        stage.wait(0.3)
        stage.press()
        stage.frame()
        let before = stage.surfaceQueries.count
        stage.move(to: CGPoint(x: 100, y: 100), in: 1)
        let queries = stage.surfaceQueries.count - before
        #expect((4...6).contains(queries), "一秒里查了 \(queries) 次")
        #expect(stage.facts.allSatisfy { $0.drag == nil })
    }

    @Test func 拖拽期间每秒查五次() throws {
        var stage = Stage(at: CGPoint(x: 130, y: 140))
        stage.wait(0.2)
        stage.drag(to: CGPoint(x: 300, y: 300), in: 0.2)
        let before = stage.surfaceQueries.count
        stage.move(to: CGPoint(x: 1300, y: 600), in: 1)
        let queries = stage.surfaceQueries.count - before
        #expect((4...6).contains(queries), "一秒里查了 \(queries) 次")
    }

    @Test func 鼠标在动_连续出帧() throws {
        var stage = Stage(at: CGPoint(x: 400, y: 600))
        stage.move(to: CGPoint(x: 800, y: 600), in: 0.3)
        #expect(stage.last.demand == .continuous)
        // 刚停下的半秒内仍然连续（速度还在收尾）。
        stage.wait(0.4)
        #expect(stage.last.demand == .continuous)
    }

    @Test func 鼠标停住_每秒读十次_长时间不动降到每秒五次() throws {
        var stage = Stage(at: CGPoint(x: 400, y: 600))
        stage.move(to: CGPoint(x: 800, y: 600), in: 0.3)
        stage.wait(1)
        #expect(stage.last.demand == .by(stage.now + 0.1))
        stage.wait(30)
        #expect(stage.last.demand == .by(stage.now + 0.2))
        // 一动就恢复连续。
        stage.position.x += 5
        #expect(stage.frame().demand == .continuous)
    }

    @Test func 停在图标上_每秒读三十次_为了尽快看到按下() throws {
        var stage = Stage(at: CGPoint(x: 130, y: 130))
        stage.wait(1)
        #expect(stage.last.hover != nil)
        #expect(stage.last.demand == .by(stage.now + 1.0 / 30))
    }

    @Test func 按着键不动_连续出帧() throws {
        var stage = Stage(at: CGPoint(x: 130, y: 130))
        stage.wait(1)
        stage.press()
        stage.wait(1)
        #expect(stage.last.demand == .continuous)
    }

    @Test func 按省电信号的节奏喂数据_结论不变() throws {
        // 鼠标停在图标上很久，应用按"每秒十次 / 三十次"的节奏来喂，而不是每帧都喂。
        var stage = Stage(at: CGPoint(x: 700, y: 500))
        stage.wait(1)
        stage.frameInterval = 0.1
        stage.wait(3)
        #expect(abs(stage.last.mouse.idleDuration - 4) < 0.11)

        // 挪到图标上停住：下一次读数就看到悬停。
        stage.position = CGPoint(x: 130, y: 140)
        #expect(stage.frame().hover?.iconID == Fixture.iconA.id)
        stage.frameInterval = 1.0 / 30
        stage.wait(1)

        // 两次读数之间按下并拖走：按下点仍是停着的位置。
        let previousTime = stage.now
        stage.buttons = [.left]
        stage.lastLeftDownAt = previousTime + 0.01
        stage.position = CGPoint(x: 139, y: 143)
        let drag = try #require(stage.frame().drag)
        #expect(drag.grabOffset == CGVector(dx: 30, dy: 40))
    }
}
