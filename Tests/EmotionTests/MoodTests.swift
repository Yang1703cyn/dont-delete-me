// EmotionTests · 头晕、打瞌睡、两个彩蛋

import CoreGraphics
import DDMCore
import Foundation
import Testing
@testable import Emotion

@Suite("猛甩")
struct DizzyTests {
    @Test func 猛甩头晕_松手后再晕两三秒才恢复() {
        let icons = makeGrid(count: 4)
        let star = icons[0]
        let stage = Stage(icons: icons)
        stage.trashRect = nil
        stage.run(0.3)
        stage.startDrag(star.id)
        stage.dragTo(CGPoint(x: 500, y: 400))
        stage.run(0.5)
        #expect(stage.state(star.id).dizziness == 0)

        // 来回猛甩。
        stage.drag?.shake = 0.85
        var side: CGFloat = 1
        stage.run(1.2) { stage in
            side = -side
            stage.dragTo(CGPoint(x: 500 + 60 * side, y: 400))
        }
        let dizzy = stage.state(star.id)
        #expect(dizzy.mood == .dizzy)
        #expect(dizzy.dizziness > 0.8)

        // 松手，挪了位置。
        stage.release()
        stage.run(0.1)
        stage.settleMoved(star.id, to: stage.released[0].imageRectAtRelease)
        let releasedAt = stage.time.monotonic
        var recoveredAfter: TimeInterval?      // 眼睛不再是漩涡
        var clearAfter: TimeInterval?          // 完全恢复
        var last = 1.0
        stage.run(6) { stage in
            let value = stage.state(star.id).dizziness
            #expect(value <= last + 1e-12, "松手后头晕应当只减不增")
            last = value
            let elapsed = stage.time.monotonic - releasedAt
            if value < 0.25, recoveredAfter == nil { recoveredAfter = elapsed }
            if value == 0, clearAfter == nil { clearAfter = elapsed }
        }
        // "再晕两三秒"：1.5 秒时还晕着，两三秒之间看起来恢复，四秒之内彻底清零。
        #expect((recoveredAfter ?? 0) > 1.5 && (recoveredAfter ?? 9) < 3.0, "头晕在松手后 \(recoveredAfter ?? -1) 秒退到看不出")
        #expect((clearAfter ?? 9) < 4.0)
        #expect(isCalmAndAwake(stage.state(star.id)))
    }

    @Test func 甩得不够猛不晕_越猛越晕() {
        func dizziness(shake: Double) -> Double {
            let icon = makeIcon(1, center: CGPoint(x: 300, y: 300))
            let stage = Stage(icons: [icon])
            stage.trashRect = nil
            stage.startDrag(icon.id, shake: shake)
            stage.run(2)
            return stage.state(icon.id).dizziness
        }
        #expect(dizziness(shake: 0.3) == 0)
        #expect(dizziness(shake: 0.49) == 0)
        #expect(dizziness(shake: 0.5) >= 0.6)
        #expect(dizziness(shake: 0.75) > dizziness(shake: 0.5))
        #expect(dizziness(shake: 1) == 1)
    }

    @Test func 甩得轻一点了但还在甩_不会因此清醒一些() {
        let icon = makeIcon(1, center: CGPoint(x: 300, y: 300))
        let stage = Stage(icons: [icon])
        stage.trashRect = nil
        stage.startDrag(icon.id, shake: 0.95)
        stage.run(1.5)
        let peak = stage.state(icon.id).dizziness
        #expect(peak > 0.9)
        // 强度回落到刚过阈值：头晕保持在这一阵最猛时的程度，不往下掉。
        stage.drag?.shake = 0.55
        stage.run(3) { stage in
            #expect(stage.state(icon.id).dizziness == peak)
        }
        // 彻底不甩了：保持 1.6 秒，然后消退。
        stage.drag?.shake = 0
        stage.run(1.5)
        #expect(stage.state(icon.id).dizziness == peak)
        stage.run(3)
        #expect(stage.state(icon.id).dizziness == 0)
        // 下一次再甩，从头算起（不带着上一次的峰值）。
        stage.drag?.shake = 0.5
        stage.run(2)
        #expect(abs(stage.state(icon.id).dizziness - 0.6) < 1e-9)
    }

    @Test func 只是不甩了还拖着_也要再晕一阵() {
        let icon = makeIcon(1, center: CGPoint(x: 300, y: 300))
        let stage = Stage(icons: [icon])
        stage.trashRect = nil
        stage.startDrag(icon.id, shake: 0.9)
        stage.run(1)
        stage.drag?.shake = 0.1
        stage.run(1)
        #expect(stage.state(icon.id).dizziness > 0.8)
        stage.run(4)
        #expect(stage.state(icon.id).dizziness == 0)
    }

    @Test func 到了废纸篓上方_害怕压过头晕() {
        let icon = makeIcon(1, center: CGPoint(x: 300, y: 300))
        let stage = Stage(icons: [icon])
        stage.startDrag(icon.id, shake: 0.9)
        stage.dragTo(CGPoint(x: 400, y: 300))
        stage.run(1)
        #expect(stage.state(icon.id).dizziness > 0.8)
        stage.dragTo(stage.trashRect!.center)
        stage.run(2)
        let state = stage.state(icon.id)
        #expect(state.dizziness == 0)
        #expect(state.tears == 1)
        #expect(state.mood == .crying)
    }
}

@Suite("打瞌睡")
struct DozeTests {
    /// 9 个图标，其中若干个很久没动。鼠标停在远处。
    private func stage(ages: [Double?]) -> (Stage, [DesktopIcon]) {
        var icons = makeGrid(count: ages.count, columns: 3)
        for (index, age) in ages.enumerated() {
            icons[index].modifiedAt = age.map { Stage.daysAgo($0) }
        }
        let stage = Stage(icons: icons)
        stage.mouse = CGPoint(x: 200, y: 700)
        stage.idle = 5
        return (stage, icons)
    }

    @Test func 超过半年没改动才打瞌睡_没有修改时间的不睡() {
        // 半年 = 182.5 天。
        let (stage, icons) = stage(ages: [183, 182, nil, 10, 10, 10, 10, 10, 10])
        stage.step()
        // 一开始就是睡着的样子（不演"慢慢睡着"）。
        let asleep = stage.state(icons[0].id)
        #expect(asleep.sleepiness == 1)
        #expect(asleep.mood == .dozing)
        #expect(asleep.gazeFollow == 0)
        stage.run(8)
        #expect(stage.state(icons[0].id).sleepiness == 1)
        #expect(stage.state(icons[1].id).sleepiness == 0, "182 天还不到半年")
        #expect(stage.state(icons[2].id).sleepiness == 0, "没有修改时间的不睡")
        for icon in icons[3...] {
            #expect(stage.state(icon.id).sleepiness == 0)
        }
    }

    @Test func 最多三分之一_最久没动的优先() {
        // 9 个图标里 6 个超过半年：只有最久没动的 3 个睡。
        let (stage, icons) = stage(ages: [200, 900, 300, 700, 10, 400, 800, nil, 20])
        stage.run(3)
        let sleeping = icons.filter { stage.state($0.id).sleepiness > 0 }.map(\.id)
        #expect(Set(sleeping) == Set([icons[1].id, icons[6].id, icons[3].id]))
        // 全都很久没动，也只睡三分之一。
        let (allOld, oldIcons) = self.stage(ages: Array(repeating: 400, count: 10))
        allOld.run(3)
        #expect(oldIcons.filter { allOld.state($0.id).sleepiness > 0 }.count == 3)
        // 只有两个图标：三分之一不足一个，谁都不睡。
        let (two, twoIcons) = self.stage(ages: [400, 500])
        two.run(3)
        #expect(twoIcons.allSatisfy { two.state($0.id).sleepiness == 0 })
    }

    @Test func 鼠标靠近会惊醒_跟着看一会儿_没人理了再慢慢睡着() {
        let (stage, icons) = stage(ages: [400, 10, 10])
        let sleeper = icons[0]
        stage.run(1)
        #expect(stage.state(sleeper.id).sleepiness == 1)

        // 鼠标晃到它旁边（离图标边缘约 40 点）。
        let near = CGPoint(x: sleeper.imageRect.maxX + 40, y: sleeper.imageRect.midY)
        var wiggle: CGFloat = 0
        stage.run(0.6) { stage in
            wiggle += 1
            stage.mouse = CGPoint(x: near.x + wiggle.truncatingRemainder(dividingBy: 3), y: near.y)
        }
        // 惊醒：半秒多一点就完全清醒，并且看着鼠标。
        let awake = stage.state(sleeper.id)
        #expect(awake.sleepiness == 0)
        #expect(awake.gazeFollow == 1)
        #expect(awake.isLooking(toward: stage.mouse.offset(from: sleeper.imageRect.center), tolerance: 3))

        // 鼠标停在旁边不动了：还醒着看一会儿（约 4 秒）……
        stage.run(3.2)
        #expect(stage.state(sleeper.id).sleepiness == 0)
        // ……然后慢慢睡着：一路只增不减，中途是半睡半醒，最后睡熟。
        var last = 0.0
        var drowsyFrames = 0
        stage.run(8) { stage in
            let value = stage.state(sleeper.id).sleepiness
            #expect(value >= last)
            last = value
            if value > 0.05 && value < 0.94 { drowsyFrames += 1 }
        }
        #expect(drowsyFrames > 120, "从犯困到合眼应当超过 2 秒，实际 \(drowsyFrames) 帧")
        #expect(stage.state(sleeper.id).sleepiness == 1)
        #expect(stage.state(sleeper.id).mood == .dozing)
    }

    @Test func 鼠标只是停在旁边不动_不算有人理() {
        let (stage, icons) = stage(ages: [400, 10, 10])
        let sleeper = icons[0]
        stage.mouse = CGPoint(x: sleeper.imageRect.maxX + 30, y: sleeper.imageRect.midY)
        stage.idle = 5
        stage.run(3)
        #expect(stage.state(sleeper.id).sleepiness == 1)
    }

    @Test func 鼠标在远处动_睡着的脸一帧都不变() {
        let (stage, icons) = stage(ages: [400, 10, 10])
        let sleeper = icons[0]
        stage.run(1)
        let before = stage.state(sleeper.id)
        var x: CGFloat = 200
        stage.run(2) { stage in
            x += 7
            stage.mouse = CGPoint(x: x, y: 700)
            #expect(stage.state(sleeper.id) == before)
        }
    }

    @Test func 悬停和围观都会把它弄醒() {
        let (stage, icons) = stage(ages: [400, 10, 10])
        let sleeper = icons[0]
        stage.run(1)
        stage.hoverOn(sleeper.id)
        stage.run(1.5)
        #expect(stage.state(sleeper.id).sleepiness == 0)
        #expect(stage.state(sleeper.id).blush == 1)

        // 围观：同伴被拖到废纸篓上方，睡着的也被吵醒、有反应。
        let (crowd, crowdIcons) = self.stage(ages: [400, 10, 10])
        crowd.run(1)
        crowd.startDrag(crowdIcons[2].id)
        crowd.dragTo(crowd.trashRect!.center)
        crowd.run(3)
        let woken = crowd.state(crowdIcons[0].id)
        #expect(woken.sleepiness == 0)
        #expect(woken.fear > 0 || woken.cover > 0)
    }

    @Test func 图标数变了_名额跟着变() {
        let (stage, icons) = stage(ages: [400, 500, 600, 10, 10, 10, 10, 10, 10])
        stage.run(1)
        #expect(icons.prefix(3).allSatisfy { stage.state($0.id).sleepiness == 1 })
        // 少了一个不睡的图标：8 个图标只能睡 2 个，最"年轻"的那个瞌睡虫醒过来。
        stage.removeIcon(icons[8].id)
        stage.run(2)
        #expect(stage.state(icons[0].id).sleepiness == 0)
        #expect(stage.state(icons[1].id).sleepiness == 1)
        #expect(stage.state(icons[2].id).sleepiness == 1)
    }
}

@Suite("彩蛋")
struct EasterEggTests {
    @Test func 无聊_鼠标十来秒不动开始东张西望_一动立刻回神() {
        let icons = makeGrid(count: 9, columns: 3)
        let stage = Stage(icons: icons)
        stage.mouse = CGPoint(x: 300, y: 600)
        func wandering(_ stage: Stage) -> [IconID] {
            icons.filter { stage.state($0.id).gazeTarget != stage.mouse.offset(from: $0.imageRect.center) }.map(\.id)
        }
        // 前 11.5 秒：老老实实看着鼠标。
        stage.run(11.5) { stage in
            #expect(wandering(stage).isEmpty)
        }
        // 之后开始张望：先后有好几个图标看向别处，但同一时间只有少数几个。
        var whoLookedAway: Set<IconID> = []
        var mostAtOnce = 0
        var sawNeighborGlance = false
        var sawElsewhereGlance = false
        stage.run(40) { stage in
            let now = wandering(stage)
            whoLookedAway.formUnion(now)
            mostAtOnce = max(mostAtOnce, now.count)
            for id in now {
                guard let me = stage.icon(id) else { continue }
                let target = stage.state(id).gazeTarget
                if icons.contains(where: { $0.id != id && $0.imageRect.center.offset(from: me.imageRect.center) == target }) {
                    sawNeighborGlance = true
                } else if abs(target.length - 400) < 0.001 {
                    sawElsewhereGlance = true
                }
            }
            // 张望的图标没有别的情绪。
            #expect(icons.allSatisfy { isCalmAndAwake(stage.state($0.id)) })
        }
        #expect(whoLookedAway.count >= 4, "40 秒里只有 \(whoLookedAway.count) 个图标张望过")
        #expect(mostAtOnce >= 1 && mostAtOnce <= 5, "同时张望的最多有 \(mostAtOnce) 个")
        #expect(sawNeighborGlance, "应当有图标看过邻居")
        #expect(sawElsewhereGlance, "应当有图标看过别处")

        // 等到有人正在张望的时候动一下鼠标：立刻回神——当帧就开始往回看，不到半秒全都重新盯住鼠标。
        var guardCount = 0
        while wandering(stage).isEmpty, guardCount < 600 {
            stage.step()
            guardCount += 1
        }
        #expect(!wandering(stage).isEmpty)
        let glancer = wandering(stage)[0]
        let lookingAway = stage.state(glancer).lookVector()
        stage.mouse.x += 5
        stage.step()
        stage.step()
        let turningBack = stage.state(glancer).lookVector()
        #expect(turningBack.x != lookingAway.x || turningBack.y != lookingAway.y, "鼠标一动，下一帧视线就应当开始往回转")
        stage.run(0.45)
        #expect(wandering(stage).isEmpty)
        // 接下来的十来秒里不再张望。
        stage.run(11) { stage in
            #expect(wandering(stage).isEmpty)
        }
    }

    @Test func 身上还有汗的图标不会被挑去张望() {
        // 拖着图标在废纸篓旁边停了很久（鼠标早就"静止超过 12 秒"了），然后取消：
        // 主角的惊恐两秒就退了，汗要四秒多——汗没收干之前，它不该东张西望。
        let icons = makeGrid(count: 2)
        for seed in 1...12 as ClosedRange<UInt64> {
            let stage = Stage(icons: icons, seed: seed)
            stage.approaching = true
            stage.startDrag(icons[0].id)
            stage.dragTo(CGPoint(x: stage.trashRect!.minX - 30, y: stage.trashRect!.midY - 40))
            stage.run(13)
            stage.release()
            stage.step()
            stage.settle(icons[0].id, as: .cancelled)
            var sweatyFrames = 0
            stage.run(6) { stage in
                guard let star = stage.director.performers.first(where: { $0.id == icons[0].id }) else { return }
                if star.sweat > 0 || star.tremble > 0 || star.fear > 0 {
                    sweatyFrames += 1
                    #expect(star.glance == nil, "种子 \(seed)：汗还没收干就去张望了")
                }
            }
            #expect(sweatyFrames > 200)
        }
    }

    @Test func 有别的事的时候不无聊() {
        let icons = makeGrid(count: 6)
        let stage = Stage(icons: icons)
        stage.trashRect = nil
        stage.run(0.5)
        // 拖着一个图标停在半空 20 秒：大家一直看着它。
        stage.startDrag(icons[0].id)
        stage.dragTo(CGPoint(x: 400, y: 500))
        stage.run(20) { stage in
            let center = stage.drag!.currentImageRect.center
            for icon in icons.dropFirst() where stage.frames > 60 {
                #expect(stage.state(icon.id).gazeTarget == center.offset(from: icon.imageRect.center))
            }
        }
    }

    @Test func 新来的_其它图标转头看它一眼_新图标眨几下眼() {
        let icons = makeGrid(count: 6)
        let stage = Stage(icons: icons)
        stage.mouse = CGPoint(x: 300, y: 650)
        stage.run(1)

        let newcomer = makeIcon(500, center: CGPoint(x: 1300, y: 600))
        stage.addIcon(newcomer)
        var blinks = 0
        var previous = 0.0
        var lookedFrames = 0
        stage.run(1.5) { stage in
            stage.idle = 0
            let blink = stage.state(newcomer.id).blink
            if blink > 0, previous == 0 { blinks += 1 }
            previous = blink
            if icons.allSatisfy({ stage.state($0.id).isLooking(toward: newcomer.imageRect.center.offset(from: $0.imageRect.center), tolerance: 3) }) {
                lookedFrames += 1
            }
        }
        // 新图标连眨三下。
        #expect(blinks == 3, "新图标眨了 \(blinks) 下")
        // 其它图标都转头看了它一阵（看一眼：一秒多），新图标自己照常看鼠标。
        #expect(lookedFrames > 60 && lookedFrames < 100, "大家一起看着新图标 \(lookedFrames) 帧")
        #expect(isCalmAndAwake(stage.state(newcomer.id)))
        #expect(stage.state(newcomer.id).gazeTarget == stage.mouse.offset(from: newcomer.imageRect.center))
        // 看完回头继续看鼠标。
        stage.run(1)
        for icon in icons {
            #expect(stage.state(icon.id).gazeTarget == stage.mouse.offset(from: icon.imageRect.center))
        }
    }

    @Test func 调成不眨眼_新图标就不专门眨眼() {
        var tuning = EmotionTuning()
        tuning.newcomerBlinks = 0
        tuning.blinkIntervalMin = 500
        tuning.blinkIntervalMax = 600
        let stage = Stage(icons: makeGrid(count: 3), tuning: tuning)
        stage.run(0.5)
        let newcomer = makeIcon(500, center: CGPoint(x: 1300, y: 600))
        stage.addIcon(newcomer)
        // 第一次眨眼按平时的规矩在 600 秒之内随机——这 3 秒里只要没有被"新来的"专门安排，就多半轮不到它。
        let scheduled = stage.director.performers.first { $0.id == newcomer.id }
        stage.step()
        let planned = stage.director.performers.first { $0.id == newcomer.id }
        #expect(scheduled == nil)
        #expect(planned?.blinksQueued == 0)
        #expect((planned?.blinkAt ?? 0) != stage.time.monotonic + tuning.newcomerBlinkDelay)
    }

    @Test func 整体重载和悄悄多出来的图标不算新来的() {
        let icons = makeGrid(count: 4)
        let stage = Stage(icons: icons)
        stage.mouse = CGPoint(x: 300, y: 650)
        stage.run(1)
        // 整体重载带来 4 个新图标。
        let more = makeGrid(count: 8)
        stage.reloadAll(more)
        var blinkedTogether = false
        stage.run(1) { stage in
            stage.idle = 0
            for icon in more {
                #expect(stage.state(icon.id).gazeTarget == stage.mouse.offset(from: icon.imageRect.center))
            }
            if more[4...].allSatisfy({ stage.state($0.id).blink > 0 }) { blinkedTogether = true }
        }
        #expect(!blinkedTogether)
        // 快照里直接多出一个、没有"新增"事件。
        let silent = makeIcon(600, center: CGPoint(x: 1300, y: 600))
        stage.addIcon(silent, announce: false)
        stage.run(0.5) { stage in
            for icon in more {
                #expect(stage.state(icon.id).gazeTarget == stage.mouse.offset(from: icon.imageRect.center))
            }
        }
        #expect(stage.face(silent.id) != nil)
    }

    @Test func 很久没动的新图标_先醒着打个招呼再睡() {
        var icons = makeGrid(count: 5)
        for index in icons.indices { icons[index].modifiedAt = Stage.daysAgo(5) }
        let stage = Stage(icons: icons)
        stage.mouse = CGPoint(x: 200, y: 700)
        stage.idle = 5
        stage.run(1)
        let old = makeIcon(700, center: CGPoint(x: 1200, y: 500), modifiedAt: Stage.daysAgo(900))
        stage.addIcon(old)
        stage.run(1)
        #expect(stage.state(old.id).sleepiness == 0)
        stage.run(12)
        #expect(stage.state(old.id).sleepiness == 1)
    }
}
