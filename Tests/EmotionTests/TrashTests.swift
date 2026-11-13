// EmotionTests · 被拖向废纸篓、全体围观、幽灵、虚惊一场

import CoreGraphics
import DDMCore
import Foundation
import Testing
@testable import Emotion

/// 把图标拖到"鼠标离废纸篓 distance 点"的地方（从废纸篓的左边靠过去），停稳后返回主角的表情。
private func settledState(distance: CGFloat, approaching: Bool = true, confidence: Double = 1) -> FaceState {
    let icon = makeIcon(1, center: CGPoint(x: 200, y: 200))
    let stage = Stage(icons: [icon])
    stage.trashConfidence = confidence
    stage.approaching = approaching
    stage.run(0.2)
    stage.startDrag(icon.id)
    let trash = stage.trashRect!
    stage.dragTo(distance > 0 ? CGPoint(x: trash.minX - distance, y: trash.midY) : trash.center)
    stage.run(4)
    return stage.state(icon.id)
}

@Suite("被拖向废纸篓")
struct TrashFearTests {
    @Test func 离废纸篓越近越怕_单调() {
        let distances: [CGFloat] = [800, 600, 450, 400, 350, 300, 250, 200, 150, 100, 60, 30, 10, 0]
        let states = distances.map { settledState(distance: $0) }
        func dread(_ state: FaceState) -> Double { state.fear + state.sweat + state.tremble + state.tears }

        // 450 点以外不害怕。
        #expect(dread(states[0]) == 0)
        #expect(dread(states[2]) == 0)
        for index in 1..<states.count {
            let (far, near) = (states[index - 1], states[index])
            // 每一项都只增不减……
            #expect(near.fear >= far.fear, "惊恐在 \(distances[index]) 点处变小了")
            #expect(near.sweat >= far.sweat)
            #expect(near.tremble >= far.tremble)
            #expect(near.tears >= far.tears)
            // ……进了起作用的范围之后，每近一步，总的害怕程度都严格增加，一直到废纸篓上方。
            if distances[index] < 450 {
                #expect(dread(near) > dread(far), "\(distances[index - 1]) → \(distances[index]) 点，害怕程度没有增加")
            }
        }
        // 冒汗 → 发抖 → 大哭：汗最先出现（离得最远），然后是发抖，最后才是泪。
        func firstIndex(_ value: (FaceState) -> Double) -> Int { states.firstIndex { value($0) > 0 } ?? .max }
        #expect(firstIndex(\.sweat) < firstIndex(\.tremble))
        #expect(firstIndex(\.tremble) < firstIndex(\.tears))
        // 中途的样子：300 点处在冒汗，还没哭。
        let middle = states[distances.firstIndex(of: 300)!]
        #expect(middle.mood == .scared)
        #expect(middle.sweat > 0.3)
        #expect(middle.tremble == 0)
        #expect(middle.tears == 0)
    }

    @Test func 进入废纸篓上方就大哭() {
        let state = settledState(distance: 0)
        #expect(state.mood == .crying)
        #expect(state.tears == 1)
        #expect(state.fear == 1)
        #expect(state.tremble > 0.8)
        // 在上方停住不动（不再"朝它去"）也一样。
        let still = settledState(distance: 0, approaching: false)
        #expect(still.tears == 1)
        #expect(still.mood == .crying)
    }

    @Test func 越怕越死盯废纸篓() {
        let icon = makeIcon(1, center: CGPoint(x: 200, y: 200))
        let stage = Stage(icons: [icon])
        stage.approaching = true
        stage.startDrag(icon.id)
        let trash = stage.trashRect!
        stage.dragTo(CGPoint(x: trash.minX - 150, y: trash.midY - 200))
        stage.run(2)
        let state = stage.state(icon.id)
        let faceCenter = stage.drag!.currentImageRect.center
        #expect(state.gazeFollow == 1)
        #expect(state.gazeTarget == trash.center.offset(from: faceCenter))
    }

    @Test func 废纸篓就在脚下时往下看_不对眼() {
        let icon = makeIcon(1, center: CGPoint(x: 200, y: 200))
        let stage = Stage(icons: [icon])
        stage.startDrag(icon.id)
        stage.dragTo(stage.trashRect!.center)   // 抓在图标正中：脸的中心正好压在废纸篓中心上
        stage.run(2)
        let state = stage.state(icon.id)
        #expect(state.gazeFollow == 1)
        #expect(state.gazeTarget.dx == 0)
        #expect(state.gazeTarget.dy > 40, "应当往下看，实际目标 \(state.gazeTarget)")
    }

    @Test func 正朝它去比离开时更怕() {
        let towards = settledState(distance: 300, approaching: true)
        let away = settledState(distance: 300, approaching: false)
        #expect(towards.fear > away.fear)
        #expect(away.fear > 0)   // 离得不远，不朝它去也还是怕的
    }

    @Test func 废纸篓位置不可信时_差一点也算到了() {
        // 鼠标停在估算区域外 50 点：估算要是偏了这么多，鼠标其实已经在废纸篓上了。
        let doubtful = settledState(distance: 50, confidence: 0.3)
        let certain = settledState(distance: 50, confidence: 1)
        #expect(doubtful.tears == 1)
        #expect(certain.tears < 1)
        #expect(certain.tears > 0.4)
        // 位置偏差不敏感：同样的可信度下，估算区域挪 30 点，害怕程度变化很小。
        let a = settledState(distance: 200, confidence: 0.75)
        let b = settledState(distance: 230, confidence: 0.75)
        #expect(abs(a.fear - b.fear) < 0.1)
    }

    @Test func 估算不出废纸篓时不害怕() {
        let icon = makeIcon(1, center: CGPoint(x: 200, y: 200))
        let stage = Stage(icons: [icon])
        stage.trashRect = nil
        stage.startDrag(icon.id)
        stage.dragTo(CGPoint(x: 1320, y: 930))
        stage.run(2)
        #expect(isCalmAndAwake(stage.state(icon.id)))
    }
}

/// 一桌图标 + 一个主角，主角被拖到废纸篓上方。
private func crowdStage(_ bystanders: [DesktopIcon], starAt: CGPoint = CGPoint(x: 700, y: 500)) -> (Stage, DesktopIcon) {
    let star = makeIcon(9000, center: starAt)
    let stage = Stage(icons: bystanders + [star])
    stage.run(0.3)
    stage.startDrag(star.id)
    return (stage, star)
}

@Suite("全体围观")
struct CrowdTests {
    @Test func 性格由长相种子决定_固定不变_三种都有() {
        var counts: [EmotionPersonality: Int] = [:]
        for raw in 1...3000 as ClosedRange<UInt64> {
            let seed = IconID(rawValue: raw).faceSeed
            let personality = EmotionPersonality(faceSeed: seed)
            #expect(personality == EmotionPersonality(faceSeed: seed))
            counts[personality, default: 0] += 1
        }
        // 默认比例 35% / 35% / 30%。
        #expect(abs(Double(counts[.timid] ?? 0) / 3000 - 0.35) < 0.04)
        #expect(abs(Double(counts[.curious] ?? 0) / 3000 - 0.35) < 0.04)
        #expect(abs(Double(counts[.bold] ?? 0) / 3000 - 0.30) < 0.04)
        // 与引擎的随机数种子无关。
        let id = IconID(rawValue: 77)
        #expect(EmotionDirector(seed: 1).personality(of: id) == EmotionDirector(seed: 999).personality(of: id))
    }

    @Test func 三种性格的表现各不相同() {
        let timid = makeIcon(rawID(of: .timid), center: CGPoint(x: 900, y: 300))
        let curious = makeIcon(rawID(of: .curious), center: CGPoint(x: 1010, y: 300))
        let bold = makeIcon(rawID(of: .bold), center: CGPoint(x: 1120, y: 300))
        let (stage, _) = crowdStage([timid, curious, bold])
        stage.dragTo(stage.trashRect!.center)
        stage.run(3)

        // 胆小的：捂眼，不偷看。
        let a = stage.state(timid.id)
        #expect(a.mood == .coveringEyes)
        #expect(a.cover == 1)
        #expect(a.peek == 0)
        // 好奇的：捂眼，从指缝偷看。
        let b = stage.state(curious.id)
        #expect(b.mood == .coveringEyes)
        #expect(b.cover == 1)
        #expect(b.peek > 0.8)
        // 胆大的：不捂，瞪眼看着主角。
        let c = stage.state(bold.id)
        #expect(c.mood == .scared)
        #expect(c.cover == 0)
        #expect(c.fear > 0.6)
        let starCenter = stage.drag!.currentImageRect.center
        #expect(c.isLooking(toward: starCenter.offset(from: bold.imageRect.center), tolerance: 3))
        // 围观者是静止画面：不发抖、不冒汗、不流泪（这些才需要每帧重画）；主角不动时表情一帧不变。
        for state in [a, b, c] {
            #expect(state.tremble == 0 && state.sweat == 0 && state.tears == 0)
        }
        let before = [timid, curious, bold].map { stage.state($0.id) }
        stage.step()
        #expect([timid, curious, bold].map { stage.state($0.id) } == before)
    }

    @Test func 捂严了的眼睛不再跟着主角转_省得重画() {
        let timid = makeIcon(rawID(of: .timid), center: CGPoint(x: 900, y: 300))
        let (stage, _) = crowdStage([timid])
        let trash = stage.trashRect!
        stage.dragTo(trash.center)
        stage.run(3)
        let before = stage.state(timid.id)
        // 主角在废纸篓上方晃：捂着眼的那张脸完全不变。
        stage.dragTo(CGPoint(x: trash.midX + 10, y: trash.midY + 5))
        stage.run(0.3)
        #expect(stage.state(timid.id) == before)
    }

    @Test func 由近到远依次反应_像波纹传开_跨屏也算() {
        // 一排胆大的图标，离主角被拖到的地方越来越远；最后一个在左侧外接屏上（x 为负）。
        var raw: UInt64 = 1
        let centers: [CGPoint] = [
            CGPoint(x: 1150, y: 760), CGPoint(x: 1000, y: 700), CGPoint(x: 800, y: 560),
            CGPoint(x: 560, y: 400), CGPoint(x: 240, y: 240), CGPoint(x: -700, y: 300),
        ]
        let bystanders = centers.map { center -> DesktopIcon in
            let id = rawID(of: .bold, from: raw)
            raw = id + 1
            return makeIcon(id, center: center)
        }
        let (stage, _) = crowdStage(bystanders, starAt: CGPoint(x: 1380, y: 300))
        stage.approaching = true
        // 匀速拖向废纸篓。
        let trash = stage.trashRect!
        var position = CGPoint(x: 1380, y: 300)
        var firstReaction: [IconID: TimeInterval] = [:]
        var alarmCenter: CGPoint?
        var alarmTime: TimeInterval = 0
        stage.run(4) { stage in
            if position.y < trash.midY {
                position.y += 6
                position.x += (trash.midX - position.x) * 0.02
                stage.dragTo(position)
            }
            for icon in bystanders where firstReaction[icon.id] == nil && stage.state(icon.id).fear > 0 {
                firstReaction[icon.id] = stage.time.monotonic
                if alarmCenter == nil {
                    alarmCenter = stage.drag!.currentImageRect.center
                    alarmTime = stage.time.monotonic
                }
            }
        }
        #expect(firstReaction.count == bystanders.count, "所有围观者都应当有反应")
        let epicenter = alarmCenter ?? .zero
        let byDistance = bystanders.sorted { $0.imageRect.center.distance(to: epicenter) < $1.imageRect.center.distance(to: epicenter) }
        let times = byDistance.map { firstReaction[$0.id] ?? .infinity }
        for index in 1..<times.count {
            #expect(times[index] > times[index - 1], "第 \(index) 近的图标应当比更近的那个晚反应")
        }
        // 最远的那个（在另一块屏上，约 2100 点开外）也在波纹的最长延迟之内。
        let delay = (times.last ?? .infinity) - alarmTime
        #expect(delay > 1.2 && delay <= 1.8 + 0.1, "最远的图标延迟 \(delay) 秒")
    }

    @Test func 没到害怕的程度时只是看着_不围观() {
        let bystanders = makeGrid(count: 6)
        let (stage, _) = crowdStage(bystanders)
        stage.approaching = true
        let trash = stage.trashRect!
        stage.dragTo(CGPoint(x: trash.minX - 480, y: trash.midY))   // 主角只是有点冒汗
        stage.run(2)
        for icon in bystanders {
            let state = stage.state(icon.id)
            #expect(state.cover == 0 && state.fear == 0)
        }
    }

    @Test func 主角被拖离废纸篓_围观者恢复() {
        let bystanders = makeGrid(count: 6)
        let (stage, _) = crowdStage(bystanders)
        stage.dragTo(stage.trashRect!.center)
        stage.run(3)
        #expect(bystanders.contains { stage.state($0.id).cover == 1 })
        stage.approaching = false
        stage.dragTo(CGPoint(x: 300, y: 200))
        stage.run(3)
        for icon in bystanders {
            #expect(isCalmAndAwake(stage.state(icon.id)))
        }
    }
}

@Suite("幽灵")
struct GhostTests {
    @Test func 拖进废纸篓_原位置出现幽灵_规定时间内消散() throws {
        let bystanders = makeGrid(count: 5)
        let (stage, star) = crowdStage(bystanders)
        stage.dragTo(stage.trashRect!.center)
        stage.run(2)
        #expect(stage.state(star.id).mood == .crying)

        stage.release()
        stage.run(0.1)
        // 结局出来之前：脸还在松手处（拖拽层），还在哭。
        #expect(stage.face(star.id)?.layer == .drag)
        #expect(stage.state(star.id).tears == 1)
        #expect(stage.ghosts.isEmpty)

        stage.settleTrashed(star.id)
        stage.step()
        let appearedAt = stage.time.monotonic
        // 主角的脸没有了；原位置（不是松手处）出现幽灵，在桌面层，排在最后（画在最上面）。
        #expect(stage.face(star.id) == nil)
        let ghost = try #require(stage.ghosts.first)
        #expect(stage.ghosts.count == 1)
        #expect(ghost.iconID == star.id)
        #expect(ghost.rect == star.imageRect)
        #expect(ghost.layer == .desktop)
        #expect(ghost.state.seed == star.id.faceSeed)
        #expect(ghost.state.ghost == 0)
        #expect(stage.output.faces.last == ghost)
        #expect(stage.output.demand == .continuous)

        // 进度匀速增加，2.6 秒后消散。
        var last = 0.0
        var lastSeenAt = appearedAt
        stage.run(3) { stage in
            guard let ghost = stage.ghosts.first else { return }
            let elapsed = stage.time.monotonic - appearedAt
            #expect(abs(ghost.state.ghost - elapsed / 2.6) < 1e-9)
            #expect(ghost.state.ghost > last)
            last = ghost.state.ghost
            lastSeenAt = stage.time.monotonic
        }
        #expect(last > 0.98)
        #expect(stage.ghosts.isEmpty)
        let lifetime = lastSeenAt - appearedAt
        #expect(lifetime > 2.0 && lifetime < 3.0, "幽灵存在了 \(lifetime) 秒")
    }

    @Test func 没有拖拽过程的删除同样出幽灵() throws {
        let icons = makeGrid(count: 6)
        let stage = Stage(icons: icons)
        stage.run(1)
        stage.deleteWithoutDrag([icons[3].id])
        stage.step()
        let ghost = try #require(stage.ghosts.first)
        #expect(ghost.iconID == icons[3].id)
        #expect(ghost.rect == icons[3].imageRect)
        #expect(stage.face(icons[3].id) == nil)
        #expect(stage.output.faces.count == 6)   // 5 张脸 + 1 个幽灵
        stage.run(3)
        #expect(stage.ghosts.isEmpty)
        #expect(stage.output.faces.count == 5)
    }

    @Test func 一次删多个_幽灵略微错开出现() {
        let icons = makeGrid(count: 8)
        let stage = Stage(icons: icons)
        stage.run(1)
        stage.deleteWithoutDrag([icons[0].id, icons[2].id, icons[5].id])
        stage.step()
        let start = stage.time.monotonic
        #expect(stage.ghosts.map(\.iconID) == [icons[0].id])
        var appeared: [IconID: TimeInterval] = [icons[0].id: 0]
        stage.run(4) { stage in
            for ghost in stage.ghosts where appeared[ghost.iconID] == nil {
                appeared[ghost.iconID] = stage.time.monotonic - start
            }
        }
        // 相邻两个错开 0.15 秒。
        #expect(abs((appeared[icons[2].id] ?? -1) - 0.15) < 0.02)
        #expect(abs((appeared[icons[5].id] ?? -1) - 0.30) < 0.02)
        #expect(stage.ghosts.isEmpty)

        // 一次删很多：从第一个到最后一个不超过 1 秒。
        let many = makeGrid(count: 30, columns: 6)
        let crowded = Stage(icons: many)
        crowded.run(0.5)
        crowded.deleteWithoutDrag(many.prefix(20).map(\.id))
        crowded.run(1.0 + 2 * frameInterval)
        #expect(crowded.ghosts.count == 20)
    }

    @Test func 围观者放下手_目送幽灵飘走_再恢复() {
        var raw: UInt64 = 1
        let centers = [CGPoint(x: 500, y: 520), CGPoint(x: 900, y: 300), CGPoint(x: 880, y: 760), CGPoint(x: 300, y: 300)]
        let kinds: [EmotionPersonality] = [.timid, .curious, .bold, .timid]
        let bystanders = zip(centers, kinds).map { center, kind -> DesktopIcon in
            let id = rawID(of: kind, from: raw)
            raw = id + 1
            return makeIcon(id, center: center)
        }
        let (stage, star) = crowdStage(bystanders)
        stage.dragTo(stage.trashRect!.center)
        stage.run(2.5)
        #expect(stage.state(bystanders[0].id).cover == 1)
        stage.release()
        stage.run(0.1)
        stage.settleTrashed(star.id)
        stage.step()
        let appearedAt = stage.time.monotonic

        // 放下手。
        stage.run(1.2)
        for icon in bystanders {
            #expect(stage.state(icon.id).cover == 0, "1.2 秒后手应当已经放下")
        }
        // 目送：盯着幽灵现在的位置（比原位置高出"进度 × 一个图标高"），而且随它往上移。
        func ghostCenter() -> CGPoint {
            let progress = (stage.time.monotonic - appearedAt) / 2.6
            return CGPoint(x: star.imageRect.midX, y: star.imageRect.midY - CGFloat(progress) * star.imageRect.height)
        }
        var targetY: [CGFloat] = []
        stage.run(1.0) { stage in
            let center = ghostCenter()
            for icon in bystanders {
                #expect(stage.state(icon.id).isLooking(toward: center.offset(from: icon.imageRect.center), tolerance: 4))
            }
            targetY.append(stage.state(bystanders[1].id).gazeTarget.dy)
        }
        #expect(targetY.last! < targetY.first! - 15, "视线目标应当随幽灵上升")

        // 幽灵散了：回过神来，看回鼠标，恢复平静。
        stage.run(2.5)
        #expect(stage.ghosts.isEmpty)
        for icon in bystanders {
            let state = stage.state(icon.id)
            #expect(isCalmAndAwake(state))
            #expect(state.gazeTarget == stage.mouse.offset(from: icon.imageRect.center))
        }
    }

    @Test func 没被删的消失_整体重载里少了的_都不放幽灵() {
        let icons = makeGrid(count: 6)
        let stage = Stage(icons: icons)
        stage.run(0.5)
        stage.removeIcon(icons[0].id, trashed: .no)
        stage.step()
        #expect(stage.ghosts.isEmpty)
        #expect(stage.output.faces.count == 5)
        stage.reloadAll(Array(icons[2...]))
        stage.step()
        #expect(stage.ghosts.isEmpty)
        #expect(stage.output.faces.count == 4)
    }

    @Test func 整体重载清掉正在飘的幽灵_同一帧新来的删除照样放() {
        let icons = makeGrid(count: 6)
        let stage = Stage(icons: icons)
        stage.run(0.5)
        stage.deleteWithoutDrag([icons[0].id])
        stage.run(0.5)
        #expect(stage.ghosts.count == 1)
        stage.reloadAll()
        stage.deletions = [DeletionEvent(iconID: IconID(rawValue: 555), lastImageRect: CGRect(x: 10, y: 10, width: 64, height: 64), wasDragged: false, trashed: .yes)]
        stage.step()
        #expect(stage.ghosts.map(\.iconID) == [IconID(rawValue: 555)])
    }

    @Test func 被删的图标又回到桌面_幽灵让位() {
        let icons = makeGrid(count: 4)
        let stage = Stage(icons: icons)
        stage.run(0.5)
        stage.deleteWithoutDrag([icons[1].id])
        stage.run(0.5)
        #expect(stage.ghosts.count == 1)
        stage.addIcon(icons[1])   // 撤销了删除
        stage.step()
        #expect(stage.ghosts.isEmpty)
        #expect(stage.output.faces.filter { $0.iconID == icons[1].id }.count == 1)
        #expect(stage.face(icons[1].id)?.rect == icons[1].imageRect)
    }
}

@Suite("虚惊一场")
struct FalseAlarmTests {
    /// 把主角拖到废纸篓旁边吓哭，然后松手。
    private func scare(_ bystanders: [DesktopIcon]) -> (Stage, DesktopIcon) {
        let (stage, star) = crowdStage(bystanders)
        let trash = stage.trashRect!
        stage.approaching = true
        stage.dragTo(CGPoint(x: trash.minX - 30, y: trash.midY - 40))
        stage.run(2.5)
        #expect(stage.state(star.id).tears > 0.4)
        #expect(stage.state(star.id).sweat == 1)
        #expect(bystanders.contains { stage.state($0.id).cover > 0.9 })
        stage.release()
        return (stage, star)
    }

    @Test func 挪了位置_主角的汗慢慢收_围观者放下手() {
        let bystanders = makeGrid(count: 6)
        let (stage, star) = scare(bystanders)
        let releaseRect = stage.released[0].imageRectAtRelease
        stage.run(0.1)
        // 结局出来之前：脸停在松手处，屏住呼吸（害怕不减）。
        #expect(stage.face(star.id)?.rect == releaseRect)
        #expect(stage.state(star.id).tears > 0.4)

        let newRect = releaseRect.offsetBy(dx: -3, dy: 2)
        stage.settleMoved(star.id, to: newRect)
        stage.step()
        // 图标已经在新位置：脸立刻落到那里，回到桌面层。
        #expect(stage.face(star.id)?.rect == newRect)
        #expect(stage.face(star.id)?.layer == .desktop)

        var goneAt: [String: TimeInterval] = [:]
        let start = stage.time.monotonic
        var last = stage.state(star.id)
        stage.run(8) { stage in
            let state = stage.state(star.id)
            #expect(state.sweat <= last.sweat && state.tears <= last.tears && state.tremble <= last.tremble && state.fear <= last.fear)
            last = state
            let elapsed = stage.time.monotonic - start
            if state.tears == 0, goneAt["tears"] == nil { goneAt["tears"] = elapsed }
            if state.tremble == 0, goneAt["tremble"] == nil { goneAt["tremble"] = elapsed }
            if state.sweat == 0, goneAt["sweat"] == nil { goneAt["sweat"] = elapsed }
        }
        // 汗是最后收干净的，而且是"慢慢"收：两秒以上。
        #expect((goneAt["sweat"] ?? 0) > (goneAt["tears"] ?? .infinity))
        #expect((goneAt["sweat"] ?? 0) > (goneAt["tremble"] ?? .infinity))
        #expect((goneAt["sweat"] ?? 0) > 2)
        #expect(isCalmAndAwake(stage.state(star.id)))
        for icon in bystanders {
            #expect(isCalmAndAwake(stage.state(icon.id)))
            #expect(stage.state(icon.id).gazeTarget == stage.mouse.offset(from: icon.imageRect.center))
        }
    }

    @Test func 围观者在结局出来后一秒左右放下手() {
        let bystanders = makeGrid(count: 6)
        let (stage, star) = scare(bystanders)
        stage.run(0.1)
        stage.settleMoved(star.id, to: stage.released[0].imageRectAtRelease)
        stage.run(1.2)
        for icon in bystanders {
            #expect(stage.state(icon.id).cover == 0)
        }
    }

    @Test func 取消_脸在松手处停一下_再飘回原位() {
        let bystanders = makeGrid(count: 4)
        let (stage, star) = scare(bystanders)
        let releaseRect = stage.released[0].imageRectAtRelease
        // 停留期（0.3 秒）之内：还在松手处。
        stage.run(0.25)
        #expect(stage.face(star.id)?.rect == releaseRect)
        #expect(stage.face(star.id)?.layer == .drag)
        // 结局迟迟不来：飘回原位等消息。途中一直只有一张脸，离家越来越近。
        var distance = releaseRect.origin.distance(to: star.imageRect.origin)
        var arrivedAfter: TimeInterval?
        let start = stage.time.monotonic
        stage.run(1.0) { stage in
            let faces = stage.output.faces.filter { $0.iconID == star.id }
            #expect(faces.count == 1)
            guard let face = faces.first else { return }
            let now = face.rect.origin.distance(to: star.imageRect.origin)
            #expect(now <= distance)
            distance = now
            if face.layer == .desktop, arrivedAfter == nil { arrivedAfter = stage.time.monotonic - start }
        }
        #expect(stage.face(star.id)?.rect == star.imageRect)
        #expect(stage.face(star.id)?.layer == .desktop)
        #expect((arrivedAfter ?? 9) < 0.8)
        // 结局还没出来：还是怕的。
        #expect(stage.state(star.id).tears > 0.4)

        stage.settle(star.id, as: .cancelled)
        stage.run(8)
        #expect(isCalmAndAwake(stage.state(star.id)))
        for icon in bystanders {
            #expect(isCalmAndAwake(stage.state(icon.id)))
        }
    }

    @Test func 去了别处_脸随图标一起消失_不放幽灵() {
        let bystanders = makeGrid(count: 4)
        let (stage, star) = scare(bystanders)
        stage.run(0.1)
        stage.settleLeftDesktop(star.id)
        stage.step()
        #expect(stage.output.faces.filter { $0.iconID == star.id }.isEmpty)
        #expect(stage.ghosts.isEmpty)
        stage.run(3)
        #expect(stage.ghosts.isEmpty)
        for icon in bystanders {
            #expect(isCalmAndAwake(stage.state(icon.id)))
        }
    }

    @Test func 判断不出结局_也恢复() {
        let bystanders = makeGrid(count: 4)
        let (stage, star) = scare(bystanders)
        stage.run(3)   // 等到超时
        stage.settle(star.id, as: .unknown)
        stage.run(8)
        #expect(isCalmAndAwake(stage.state(star.id)))
        #expect(stage.face(star.id)?.rect == star.imageRect)
    }
}
