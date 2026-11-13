// InputSenseTests · 拖拽：什么算开始拖、拖的过程、松手后的结局

import CoreGraphics
import DDMCore
import Foundation
import Testing
@testable import InputSense

@Suite("什么才算开始拖")
struct DragStartTests {
    /// 图标 A 图像矩形里的一点：离左上角 (30, 40)。
    let onIconA = CGPoint(x: 130, y: 140)

    @Test func 单击不算拖() throws {
        var stage = Stage(at: onIconA)
        stage.wait(0.2)
        stage.press()
        stage.wait(0.1)
        stage.release()
        stage.wait(0.5)

        #expect(stage.facts.allSatisfy { $0.drag == nil })
        #expect(stage.facts.allSatisfy { $0.releasedDrags.isEmpty })
        #expect(stage.outcomes.isEmpty)
        #expect(stage.refreshRequests == 0)
    }

    @Test func 双击不算拖() throws {
        var stage = Stage(at: onIconA)
        stage.wait(0.2)
        for _ in 0..<2 {
            stage.press()
            stage.wait(0.06)
            stage.release()
            stage.wait(0.1)
        }
        stage.wait(0.5)

        #expect(stage.facts.allSatisfy { $0.drag == nil })
        #expect(stage.outcomes.isEmpty)
    }

    @Test func 按住不动不算拖() throws {
        var stage = Stage(at: onIconA)
        stage.wait(0.2)
        stage.press()
        stage.wait(2)
        #expect(stage.facts.allSatisfy { $0.drag == nil })

        // 手抖了一下，没到起拖阈值（4 点）：仍然不算。
        stage.move(to: CGPoint(x: 133, y: 142), in: 0.1)
        stage.wait(1)
        stage.release()
        stage.wait(0.5)
        #expect(stage.facts.allSatisfy { $0.drag == nil })
        #expect(stage.outcomes.isEmpty)
    }

    @Test func 右键按住并移动不算拖() throws {
        var stage = Stage(at: onIconA)
        stage.wait(0.2)
        stage.press(.right)
        stage.frame()
        stage.move(to: CGPoint(x: 400, y: 400), in: 0.3)
        stage.release(.right)
        stage.wait(0.5)

        #expect(stage.facts.allSatisfy { $0.drag == nil })
        #expect(stage.outcomes.isEmpty)
    }

    @Test func 左右键同时按下不算拖() throws {
        var stage = Stage(at: onIconA)
        stage.wait(0.2)
        stage.buttons = [.left, .right]
        stage.lastLeftDownAt = stage.now
        stage.frame()
        stage.move(to: CGPoint(x: 400, y: 400), in: 0.3)
        #expect(stage.facts.allSatisfy { $0.drag == nil })
    }

    @Test func 在空白处按下再拖过图标不算拖() throws {
        var stage = Stage(at: CGPoint(x: 600, y: 600))
        stage.wait(0.2)
        stage.drag(to: onIconA, in: 0.3)
        stage.wait(0.2)
        #expect(stage.facts.allSatisfy { $0.drag == nil })
    }

    @Test func 移动超过阈值才开始拖_并给出抓取偏移() throws {
        var stage = Stage(at: onIconA)
        stage.wait(0.2)
        stage.press()
        stage.frame()

        stage.position = CGPoint(x: 133, y: 140)   // 动了 3 点：还不算
        #expect(stage.frame().drag == nil)

        stage.position = CGPoint(x: 134, y: 140)   // 动了 4 点：开始
        let facts = stage.frame()
        let drag = try #require(facts.drag)
        #expect(drag.iconID == Fixture.iconA.id)
        #expect(drag.grabOffset == CGVector(dx: 30, dy: 40))
        #expect(drag.originImageRect == Fixture.iconA.imageRect)
        #expect(drag.startedAt == stage.now)
        #expect(drag.position == CGPoint(x: 134, y: 140))
        // 拖影上的图标图像 = 鼠标位置 − 抓取偏移：比原位置正好挪了 4 点。
        #expect(drag.currentImageRect == CGRect(x: 104, y: 100, width: 64, height: 64))
        // 拖拽期间没有悬停。
        #expect(facts.hover == nil)
    }

    @Test func 按在标签上也能拖_抓取偏移仍相对图像左上角() throws {
        var stage = Stage(at: CGPoint(x: 120, y: 180))   // 标签矩形 (88,168 88×30) 里
        stage.wait(0.2)
        stage.drag(to: CGPoint(x: 320, y: 380), in: 0.2)
        let drag = try #require(stage.last.drag)
        #expect(drag.grabOffset == CGVector(dx: 20, dy: 80))
        #expect(drag.currentImageRect.origin == CGPoint(x: 300, y: 300))
    }

    @Test func 拖的过程中位置和速度跟着鼠标走() throws {
        var stage = Stage(at: onIconA)
        stage.wait(0.2)
        stage.drag(to: CGPoint(x: 730, y: 140), in: 1)   // 向右 600 点/秒
        let drag = try #require(stage.last.drag)
        #expect(drag.position == CGPoint(x: 730, y: 140))
        #expect(abs(drag.velocity.dx - 600) < 15)
        #expect(abs(drag.velocity.dy) < 1)
        #expect(drag.currentImageRect.origin == CGPoint(x: 700, y: 100))
        #expect(stage.last.demand == .continuous)
    }

    @Test func 按下发生在两帧之间且鼠标在动_按下点按事件时刻折算() throws {
        var stage = Stage(at: CGPoint(x: 80, y: 140))
        // 鼠标以每帧 10 点的速度向右划过图标 A（图像从 x=100 开始）。
        stage.move(to: CGPoint(x: 100, y: 140), in: 2.0 / 60)
        let previousTime = stage.now
        // 按下发生在这一帧之后 40% 帧处，那时鼠标在 x=104。
        stage.buttons = [.left]
        stage.lastLeftDownAt = previousTime + 0.4 * stage.frameInterval
        stage.position = CGPoint(x: 110, y: 140)
        let facts = stage.frame()
        // 这一帧鼠标已经到了 110，比按下点多走了 6 点，所以立刻就开始拖；抓取偏移按 x=104 算。
        let drag = try #require(facts.drag)
        #expect(abs(drag.grabOffset.dx - 4) < 0.001)
        #expect(drag.grabOffset.dy == 40)
    }

    @Test func 按下发生在两帧之间而鼠标原本停着_按下点就是停着的位置() throws {
        var stage = Stage(at: onIconA)
        stage.wait(0.3)
        let previousTime = stage.now
        // 停着 → 按下 → 立刻甩出去：下一帧鼠标已经在 6 点之外。
        stage.buttons = [.left]
        stage.lastLeftDownAt = previousTime + 0.5 * stage.frameInterval
        stage.position = CGPoint(x: 136, y: 140)
        let drag = try #require(stage.frame().drag)
        #expect(drag.grabOffset == CGVector(dx: 30, dy: 40))
    }

    @Test func 读得稀的时候_挪到图标上再按下_按下点取当前位置() throws {
        // 鼠标停在图标 A 右边的空白处，每 0.1 秒才读一次。两次读数之间：挪进图标、按下、又动了一点。
        var stage = Stage(at: CGPoint(x: 180, y: 140))
        stage.wait(1)
        stage.frameInterval = 0.1
        stage.wait(0.5)
        let previousTime = stage.now
        stage.buttons = [.left]
        stage.lastLeftDownAt = previousTime + 0.07
        stage.position = CGPoint(x: 148, y: 140)
        stage.frame()
        // 上一次读数时鼠标还在图标外面；不能因为"上一帧是静止的"就把按下点取在那里。
        stage.frameInterval = 1.0 / 60
        stage.move(to: CGPoint(x: 300, y: 300), in: 0.2)
        let drag = try #require(stage.last.drag)
        #expect(drag.iconID == Fixture.iconA.id)
        #expect(drag.grabOffset == CGVector(dx: 48, dy: 40))
    }

    @Test func 读不到事件时刻时按下点取当前位置() throws {
        var stage = Stage(at: onIconA)
        stage.wait(0.2)
        stage.buttons = [.left]
        stage.lastLeftDownAt = nil
        stage.frame()
        stage.move(to: CGPoint(x: 200, y: 200), in: 0.1)
        #expect(stage.last.drag?.grabOffset == CGVector(dx: 30, dy: 40))
    }

    @Test func 开始观察时左键已经按着_不当作新的按下() throws {
        var stage = Stage(at: onIconA)
        stage.buttons = [.left]
        stage.frame()
        stage.move(to: CGPoint(x: 400, y: 400), in: 0.3)
        #expect(stage.facts.allSatisfy { $0.drag == nil })

        // 松开之后再按，才算数。
        stage.release()
        stage.move(to: onIconA, in: 0.2)
        stage.wait(0.1)
        stage.drag(to: CGPoint(x: 400, y: 400), in: 0.3)
        #expect(stage.last.drag != nil)
    }

    @Test func 按住还没拖起来图标就被删了_之后再移动也不算拖() throws {
        var stage = Stage(at: onIconA)
        stage.wait(0.2)
        stage.press()
        stage.wait(0.3)
        stage.reportRemoved(Fixture.iconA, trashed: .yes)   // 按着的时候用快捷键把它删了
        stage.frame()
        #expect(stage.deletions.map(\.wasDragged) == [false])

        stage.move(to: CGPoint(x: 400, y: 400), in: 0.3)
        stage.release()
        stage.wait(0.5)
        #expect(stage.facts.allSatisfy { $0.drag == nil && $0.releasedDrags.isEmpty })
        #expect(stage.outcomes.isEmpty)
    }

    @Test func 重置会丢掉进行到一半的拖拽() throws {
        var stage = Stage(at: onIconA)
        stage.wait(0.2)
        stage.drag(to: CGPoint(x: 400, y: 400), in: 0.3)
        #expect(stage.last.drag != nil)

        stage.judge.reset()
        stage.move(to: CGPoint(x: 500, y: 500), in: 0.2)
        #expect(stage.last.drag == nil)
        stage.release()
        stage.wait(0.5)
        #expect(stage.last.releasedDrags.isEmpty)
        #expect(stage.outcomes.isEmpty)
    }
}

@Suite("松手后的结局")
struct DragOutcomeTests {
    let onIconA = CGPoint(x: 130, y: 140)
    let dropPoint = CGPoint(x: 530, y: 440)

    /// 把图标 A 拖到某处并松手，停在"刚松手、结局未定"的那一帧。
    func releasedStage(at target: CGPoint) -> Stage {
        var stage = Stage(at: onIconA)
        stage.wait(0.2)
        stage.drag(to: target, in: 0.4)
        stage.release()
        stage.frame()
        return stage
    }

    @Test func 松手的那一帧_转为等待结局并请求重读图标() throws {
        let stage = releasedStage(at: dropPoint)
        let facts = stage.last
        #expect(facts.drag == nil)
        #expect(facts.dragOutcomes.isEmpty)
        #expect(facts.wantsIconRefresh)
        let released = try #require(facts.releasedDrags.first)
        #expect(released.iconID == Fixture.iconA.id)
        #expect(released.releasePoint == dropPoint)
        #expect(released.imageRectAtRelease == CGRect(x: 500, y: 400, width: 64, height: 64))
        #expect(abs(released.releasedAt - stage.now) <= stage.frameInterval + 1e-9)
    }

    @Test func 正常拖动_挪了位置() throws {
        var stage = releasedStage(at: dropPoint)
        stage.wait(0.08)
        // 访达把图标吸附到了网格上，和松手处的拖影差几个点：以访达报告的为准。
        stage.reportMoved(Fixture.iconA, to: CGPoint(x: 496, y: 404))
        let facts = stage.frame()

        #expect(facts.dragOutcomes == [DragOutcome(
            iconID: Fixture.iconA.id, kind: .moved, releasePoint: dropPoint,
            newImageRect: CGRect(x: 496, y: 404, width: 64, height: 64)
        )])
        #expect(facts.releasedDrags.isEmpty)
        #expect(facts.deletions.isEmpty)

        // 结局是一次性事件：下一帧就没有了，也不再请求重读。
        stage.wait(1)
        #expect(stage.outcomes.count == 1)
        #expect(stage.last.wantsIconRefresh == false)
        #expect(stage.lessons.isEmpty)
    }

    @Test func 拖进废纸篓_同一帧给出结局和删除事件() throws {
        var stage = releasedStage(at: Fixture.trashCenter)
        stage.wait(0.1)
        stage.reportRemoved(Fixture.iconA, trashed: .yes)
        let facts = stage.frame()

        #expect(facts.dragOutcomes == [DragOutcome(iconID: Fixture.iconA.id, kind: .trashed, releasePoint: Fixture.trashCenter)])
        // 幽灵从桌面上的原位置飘起，不是松手处。
        #expect(facts.deletions == [DeletionEvent(
            iconID: Fixture.iconA.id, lastImageRect: Fixture.iconA.imageRect, wasDragged: true, trashed: .yes
        )])
        #expect(facts.releasedDrags.isEmpty)
        // 松手点被记下来，用于修正废纸篓的估算。
        #expect(stage.lessons == [Fixture.trashCenter])

        stage.wait(1)
        #expect(stage.outcomes.count == 1)
        #expect(stage.deletions.count == 1)
    }

    @Test func 拖到别处_离开桌面但没进废纸篓() throws {
        var stage = releasedStage(at: CGPoint(x: 900, y: 300))
        stage.wait(0.35)   // 图标桥为了再查一次废纸篓，这种消失事件会晚约 0.3 秒
        stage.reportRemoved(Fixture.iconA, trashed: .no)
        let facts = stage.frame()

        #expect(facts.dragOutcomes.map(\.kind) == [.leftDesktop])
        #expect(facts.deletions.isEmpty)
        #expect(stage.lessons.isEmpty)
    }

    @Test func 拖到一半取消_弹回原位() throws {
        var stage = releasedStage(at: dropPoint)
        // 松手后马上读到的快照里图标还在原位：可能只是访达还没更新，先不下结论。
        stage.wait(0.1)
        stage.reportUnchanged()
        stage.wait(0.1)
        #expect(stage.outcomes.isEmpty)
        #expect(stage.last.releasedDrags.count == 1)

        // 过了 0.3 秒的稳定期再读，还在原位：取消。
        stage.wait(0.15)
        stage.reportUnchanged()
        let facts = stage.frame()
        #expect(facts.dragOutcomes == [DragOutcome(iconID: Fixture.iconA.id, kind: .cancelled, releasePoint: dropPoint)])
        #expect(facts.releasedDrags.isEmpty)
        #expect(facts.deletions.isEmpty)
    }

    @Test func 松手之前读的快照不能用来下结论() throws {
        var stage = releasedStage(at: dropPoint)
        // 舞台上现有的快照是松手之前读的（图标在原位）。一直没有新的读数：不能据此判"取消"。
        stage.wait(2)
        #expect(stage.outcomes.isEmpty)
        #expect(stage.last.releasedDrags.count == 1)
    }

    @Test func 一直等不到新快照_超时记为未知() throws {
        var stage = releasedStage(at: dropPoint)
        stage.wait(2.9)
        #expect(stage.outcomes.isEmpty)
        stage.wait(0.2)
        #expect(stage.outcomes == [DragOutcome(iconID: Fixture.iconA.id, kind: .unknown, releasePoint: dropPoint)])
        #expect(stage.last.releasedDrags.isEmpty)
        stage.wait(1)
        #expect(stage.outcomes.count == 1)
        #expect(stage.last.wantsIconRefresh == false)
    }

    @Test func 访达更新得慢_稍后才报告新位置_仍判为挪了位置() throws {
        var stage = releasedStage(at: dropPoint)
        stage.wait(0.1)
        stage.reportUnchanged()          // 第一次重读：还是旧位置
        stage.wait(0.1)
        #expect(stage.outcomes.isEmpty)
        stage.reportMoved(Fixture.iconA, to: CGPoint(x: 500, y: 400))
        #expect(stage.frame().dragOutcomes.map(\.kind) == [.moved])
    }

    @Test func 等结局期间按节奏请求重读_结局出来就停() throws {
        var stage = releasedStage(at: dropPoint)
        stage.wait(0.98)
        // 松手那一帧、0.15 秒、0.3 秒各一次，之后每 0.35 秒一次：第 1 秒里是 0、0.15、0.30、0.65 这 4 次。
        #expect(stage.refreshRequests == 4)
        stage.wait(1.5)
        // 再加上 1.0、1.35、1.7、2.05、2.4 这 5 次。
        #expect(stage.refreshRequests == 9)
        // 等待期间即使鼠标不动，也要按时被叫醒。
        if case let .by(deadline) = stage.last.demand {
            #expect(deadline - stage.now <= 0.35 + 1e-9)
        } else {
            Issue.record("等结局时应当给出一个定时的需求，而不是 \(stage.last.demand)")
        }
    }

    @Test func 图标桥查不出是否进了废纸篓_松手点在废纸篓上方就认定被删() throws {
        var stage = releasedStage(at: Fixture.trashCenter)
        stage.wait(0.1)
        stage.reportRemoved(Fixture.iconA, trashed: .unknown)
        let facts = stage.frame()
        #expect(facts.dragOutcomes.map(\.kind) == [.trashed])
        #expect(facts.deletions == [DeletionEvent(
            iconID: Fixture.iconA.id, lastImageRect: Fixture.iconA.imageRect, wasDragged: true, trashed: .unknown
        )])
        // 这是凭自己的估算认定的，不能再拿它去修正估算。
        #expect(stage.lessons.isEmpty)
    }

    @Test func 图标桥查不出_松手点不在废纸篓上方_宁可不报删除() throws {
        var stage = releasedStage(at: CGPoint(x: 900, y: 300))
        stage.wait(0.1)
        stage.reportRemoved(Fixture.iconA, trashed: .unknown)
        let facts = stage.frame()
        #expect(facts.dragOutcomes.map(\.kind) == [.leftDesktop])
        #expect(facts.deletions.isEmpty)
    }

    @Test func 图标桥查不出_废纸篓估算又不够可信_宁可不报删除() throws {
        var stage = Stage(at: onIconA)
        stage.trash = TrashEstimate(rect: Fixture.trash.rect, confidence: 0.45, basis: .formula)
        stage.wait(0.2)
        stage.drag(to: Fixture.trashCenter, in: 0.4)
        stage.release()
        stage.frame()
        stage.reportRemoved(Fixture.iconA, trashed: .unknown)
        let facts = stage.frame()
        #expect(facts.dragOutcomes.map(\.kind) == [.leftDesktop])
        #expect(facts.deletions.isEmpty)
    }

    @Test func 整体重载后图标不见了_松手处不是废纸篓_记为去了别处_不报删除() throws {
        var stage = releasedStage(at: dropPoint)
        stage.wait(0.1)
        stage.reportReset(icons: [Fixture.iconB])   // 快照被整个换掉，图标 A 不在里面，也没有它的消失事件
        let facts = stage.frame()
        #expect(facts.dragOutcomes.map(\.kind) == [.leftDesktop])
        #expect(facts.deletions.isEmpty)
        #expect(facts.releasedDrags.isEmpty)
    }

    @Test func 整体重载后图标不见了_松手处是可信的废纸篓_认定被删() throws {
        // 例如拖拽期间访达一时没有回应，图标桥超时之后恢复：只有一份新快照，没有消失事件。
        var stage = releasedStage(at: Fixture.trashCenter)
        stage.wait(0.1)
        stage.reportReset(icons: [Fixture.iconB])
        let facts = stage.frame()
        #expect(facts.dragOutcomes.map(\.kind) == [.trashed])
        #expect(facts.deletions == [DeletionEvent(
            iconID: Fixture.iconA.id, lastImageRect: Fixture.iconA.imageRect, wasDragged: true, trashed: .unknown
        )])
        #expect(stage.lessons.isEmpty)   // 是凭自己的估算认定的，不拿去学
    }

    @Test func 整体重载后图标还在_照常按位置下结论() throws {
        var moved = Fixture.iconA
        moved.imageRect.origin = CGPoint(x: 500, y: 400)
        var stage = releasedStage(at: dropPoint)
        stage.wait(0.1)
        stage.reportReset(icons: [moved, Fixture.iconB])
        #expect(stage.frame().dragOutcomes.map(\.kind) == [.moved])

        var cancelled = releasedStage(at: dropPoint)
        cancelled.wait(0.35)
        cancelled.reportReset(icons: [Fixture.iconA, Fixture.iconB])
        #expect(cancelled.frame().dragOutcomes.map(\.kind) == [.cancelled])
    }

    @Test func 拖着的时候整体重载_原位置按新快照重取() throws {
        // 拖到一半，用户改了桌面的图标大小：所有矩形一起变了。
        var resized = Fixture.iconA
        resized.imageRect = CGRect(x: 92, y: 92, width: 80, height: 80)
        var stage = Stage(at: onIconA)
        stage.wait(0.2)
        stage.drag(to: dropPoint, in: 0.3)
        stage.reportReset(icons: [resized, Fixture.iconB])
        #expect(stage.frame().drag?.originImageRect == resized.imageRect)

        // 松手后图标还在重载后的位置：是取消，不是"挪了位置"。
        stage.release()
        stage.wait(0.35)
        stage.reportUnchanged()
        #expect(stage.frame().dragOutcomes.map(\.kind) == [.cancelled])
    }

    @Test func 按下之后整体重载_这次按下作废() throws {
        var stage = Stage(at: onIconA)
        stage.wait(0.2)
        stage.press()
        stage.frame()
        stage.reportReset(icons: [Fixture.iconA, Fixture.iconB])
        stage.frame()
        stage.move(to: dropPoint, in: 0.3)
        #expect(stage.last.drag == nil)
    }

    @Test func 还拖着图标就从桌面消失了_拖拽到此为止() throws {
        var stage = Stage(at: onIconA)
        stage.wait(0.2)
        stage.drag(to: dropPoint, in: 0.4)
        stage.reportRemoved(Fixture.iconA, trashed: .yes)
        let facts = stage.frame()
        #expect(facts.drag == nil)
        #expect(facts.dragOutcomes.map(\.kind) == [.trashed])
        #expect(facts.deletions.map(\.wasDragged) == [true])
        // 不是在废纸篓上松的手，不能当作废纸篓的位置去学。
        #expect(stage.lessons.isEmpty)

        // 之后松手，不会再冒出第二个结局。
        stage.release()
        stage.wait(1)
        #expect(stage.outcomes.count == 1)
        #expect(stage.last.releasedDrags.isEmpty)
    }

    @Test func 还拖着图标就消失了_又查不出去向_不凭鼠标位置认定被删() throws {
        var stage = Stage(at: onIconA)
        stage.wait(0.2)
        stage.drag(to: Fixture.trashCenter, in: 0.4)   // 鼠标在废纸篓上方，但左键还没松
        stage.reportRemoved(Fixture.iconA, trashed: .unknown)
        let facts = stage.frame()
        #expect(facts.drag == nil)
        #expect(facts.dragOutcomes.map(\.kind) == [.leftDesktop])
        #expect(facts.deletions.isEmpty)
    }

    @Test func 松手和图标消失落在同一帧_按松手之后消失结算_松手点交给自学习() throws {
        var stage = Stage(at: onIconA)
        stage.wait(0.2)
        stage.drag(to: Fixture.trashCenter, in: 0.4)
        // 主线程卡了一下：这一帧既看到了松手，又收到了图标桥的消失事件。
        stage.release()
        stage.reportRemoved(Fixture.iconA, trashed: .yes)
        let facts = stage.frame()
        #expect(facts.drag == nil)
        #expect(facts.releasedDrags.isEmpty)
        #expect(facts.dragOutcomes == [DragOutcome(iconID: Fixture.iconA.id, kind: .trashed, releasePoint: Fixture.trashCenter)])
        #expect(facts.deletions.map(\.wasDragged) == [true])
        #expect(stage.lessons == [Fixture.trashCenter])
        stage.wait(1)
        #expect(stage.outcomes.count == 1)
    }

    @Test func 拖进废纸篓但访达慢了半拍_不会先判成取消() throws {
        var stage = releasedStage(at: Fixture.trashCenter)   // 松手处最上面是程序坞
        // 松手后 0.5 秒重读，图标还在原位：松在桌面上的话这时已经判取消了，松在程序坞上要多等。
        stage.wait(0.5)
        stage.reportUnchanged()
        stage.wait(0.2)
        #expect(stage.outcomes.isEmpty)
        #expect(stage.last.releasedDrags.count == 1)

        stage.reportRemoved(Fixture.iconA, trashed: .yes)   // 访达这才把它移进废纸篓
        let facts = stage.frame()
        #expect(facts.dragOutcomes.map(\.kind) == [.trashed])
        #expect(facts.deletions.map(\.wasDragged) == [true])
    }

    @Test func 松在别的窗口上_图标一直在原位_约一秒后才判取消() throws {
        var stage = Stage(at: onIconA)
        stage.surface = { $0.x > 700 ? .otherWindow : .desktopIcons }
        stage.wait(0.2)
        stage.drag(to: CGPoint(x: 900, y: 300), in: 0.4)
        stage.release()
        stage.frame()
        stage.wait(0.6)
        stage.reportUnchanged()
        stage.wait(0.2)
        #expect(stage.outcomes.isEmpty)

        stage.wait(0.2)
        stage.reportUnchanged()   // 松手 1 秒之后读的
        #expect(stage.frame().dragOutcomes.map(\.kind) == [.cancelled])
    }

    @Test func 拖进一个打开着的废纸篓窗口_结局照常_但松手点不拿去学() throws {
        var stage = Stage(at: onIconA)
        stage.surface = { $0.x > 700 ? .otherWindow : .desktopIcons }   // 右边开着一个废纸篓窗口
        stage.wait(0.2)
        stage.drag(to: CGPoint(x: 1430, y: 947), in: 0.4)   // 窗口的下沿正好盖在程序坞废纸篓的位置上
        stage.release()
        stage.frame()
        stage.reportRemoved(Fixture.iconA, trashed: .yes)
        let facts = stage.frame()
        #expect(facts.dragOutcomes.map(\.kind) == [.trashed])
        #expect(facts.deletions.count == 1)
        #expect(stage.lessons.isEmpty)
    }

    @Test func 结局还没出来又把同一个图标拖走_上一次记为未知() throws {
        var stage = releasedStage(at: CGPoint(x: 150, y: 150))   // 松手处仍在图标 A 的原位置上
        stage.wait(0.05)
        stage.drag(to: CGPoint(x: 400, y: 400), in: 0.2)
        #expect(stage.outcomes.map(\.kind) == [.unknown])
        #expect(stage.last.drag?.iconID == Fixture.iconA.id)
        #expect(stage.last.releasedDrags.isEmpty)
    }

    @Test func 拖着一个图标时别的图标被删_各算各的() throws {
        var stage = Stage(at: onIconA)
        stage.wait(0.2)
        stage.drag(to: dropPoint, in: 0.4)
        stage.reportRemoved(Fixture.iconB, trashed: .yes)
        let facts = stage.frame()
        #expect(facts.drag?.iconID == Fixture.iconA.id)
        #expect(facts.dragOutcomes.isEmpty)
        #expect(facts.deletions == [DeletionEvent(
            iconID: Fixture.iconB.id, lastImageRect: Fixture.iconB.imageRect, wasDragged: false, trashed: .yes
        )])
    }
}

@Suite("没有拖拽过程的删除")
struct DeletionTests {
    @Test func 快捷键删除_只有删除事件_位置是图标最后的位置() throws {
        var stage = Stage(at: CGPoint(x: 700, y: 500))
        stage.wait(0.3)
        stage.reportRemoved(Fixture.iconB, trashed: .yes)
        let facts = stage.frame()
        #expect(facts.deletions == [DeletionEvent(
            iconID: Fixture.iconB.id, lastImageRect: Fixture.iconB.imageRect, wasDragged: false, trashed: .yes
        )])
        #expect(facts.dragOutcomes.isEmpty)
        // 一次性事件。
        stage.wait(0.5)
        #expect(stage.deletions.count == 1)
        #expect(stage.lessons.isEmpty)
    }

    @Test func 确认没进废纸篓的消失_不报删除() throws {
        var stage = Stage(at: CGPoint(x: 700, y: 500))
        stage.wait(0.3)
        stage.reportRemoved(Fixture.iconB, trashed: .no)
        stage.wait(0.5)
        #expect(stage.deletions.isEmpty)
    }

    @Test func 查不出去向又没有拖拽佐证的消失_不报删除() throws {
        var stage = Stage(at: CGPoint(x: 700, y: 500))
        stage.wait(0.3)
        stage.reportRemoved(Fixture.iconB, trashed: .unknown)
        stage.wait(0.5)
        #expect(stage.deletions.isEmpty)
    }

    @Test func 整体重载里少了的图标_不报删除() throws {
        var stage = Stage(at: CGPoint(x: 700, y: 500))
        stage.wait(0.3)
        stage.reportReset(icons: [Fixture.iconA])
        stage.wait(0.5)
        #expect(stage.deletions.isEmpty)
        #expect(stage.outcomes.isEmpty)
    }

    @Test func 结局已判为取消之后才迟到的删除_仍然报出_但不标为经过拖拽() throws {
        // 接口约定：标"经过拖拽"的删除，同一帧一定带着"进了废纸篓"的结局。结局已经给过了，这一条就按普通删除报。
        var stage = Stage(at: CGPoint(x: 130, y: 140))
        stage.wait(0.2)
        stage.drag(to: Fixture.trashCenter, in: 0.4)
        stage.release()
        stage.wait(1.05)
        stage.reportUnchanged()
        stage.frame()
        #expect(stage.outcomes.map(\.kind) == [.cancelled])

        // 访达又过了一秒才真的把它移进废纸篓。
        stage.wait(1)
        stage.reportRemoved(Fixture.iconA, trashed: .yes)
        let facts = stage.frame()
        #expect(facts.deletions == [DeletionEvent(
            iconID: Fixture.iconA.id, lastImageRect: Fixture.iconA.imageRect, wasDragged: false, trashed: .yes
        )])
        #expect(facts.dragOutcomes.isEmpty)
    }

    @Test func 挪过位置的图标后来被快捷键删除_不标为经过拖拽() throws {
        var stage = Stage(at: CGPoint(x: 130, y: 140))
        stage.wait(0.2)
        stage.drag(to: CGPoint(x: 530, y: 440), in: 0.4)
        stage.release()
        stage.frame()
        stage.reportMoved(Fixture.iconA, to: CGPoint(x: 500, y: 400))
        stage.frame()
        #expect(stage.outcomes.map(\.kind) == [.moved])

        stage.wait(3)
        var moved = Fixture.iconA
        moved.imageRect.origin = CGPoint(x: 500, y: 400)
        stage.reportRemoved(moved, trashed: .yes)
        let facts = stage.frame()
        #expect(facts.deletions.map(\.wasDragged) == [false])
        #expect(facts.deletions.first?.lastImageRect == moved.imageRect)
        #expect(facts.dragOutcomes.isEmpty)
    }
}
