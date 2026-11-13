// EmotionTests · 确定性、平滑、省电信号、健壮性、耗时

import CoreGraphics
import DDMCore
import Foundation
import Testing
@testable import Emotion

/// 一段把各种情形都走一遍的固定剧本，返回每一帧的输出。
private func playMedley(seed: UInt64, record: ((Stage) -> Void)? = nil) -> [EmotionOutput] {
    var icons = makeGrid(count: 12, columns: 4)
    icons[3].modifiedAt = Stage.daysAgo(400)
    icons[7].modifiedAt = Stage.daysAgo(800)
    icons[9].modifiedAt = Stage.daysAgo(300)
    let stage = Stage(icons: icons, seed: seed)
    var outputs: [EmotionOutput] = []
    func run(_ seconds: TimeInterval, _ body: ((Stage) -> Void)? = nil) {
        stage.run(seconds) { stage in
            body?(stage)
            outputs.append(stage.output)
            record?(stage)
        }
    }
    stage.mouse = CGPoint(x: 300, y: 300)
    var x: CGFloat = 300
    run(1.5) { $0.mouse = CGPoint(x: x, y: 300 + x / 10); x += 9 }           // 鼠标划过去
    stage.hoverOn(icons[5].id); run(1.2)                                       // 悬停
    stage.moveMouse(to: CGPoint(x: 500, y: 640)); run(0.8)
    stage.startDrag(icons[1].id, shake: 0)                                     // 拖起来
    var position = icons[1].imageRect.center
    let trash = stage.trashRect!.center
    run(2.2) { stage in                                                        // 拖向废纸篓
        position.x += (trash.x - position.x) * 0.035
        position.y += (trash.y - position.y) * 0.035
        stage.dragTo(position)
    }
    stage.dragTo(trash); run(1.0)                                              // 悬在上方大哭
    stage.release(); run(0.12)
    stage.settleTrashed(icons[1].id); run(3.2)                                 // 幽灵
    stage.startDrag(icons[6].id, shake: 0.9)                                   // 再拖一个，猛甩
    var side: CGFloat = 1
    run(1.0) { stage in side = -side; stage.dragTo(CGPoint(x: 700 + 70 * side, y: 420)) }
    stage.drag?.shake = 0.2
    run(1.0) { stage in stage.dragTo(CGPoint(x: stage.mouse.x + 5, y: stage.mouse.y + 4)) }   // 朝废纸篓去一段
    stage.release(); run(0.5)
    stage.settle(icons[6].id, as: .cancelled); run(2.0)                        // 虚惊一场
    stage.addIcon(makeIcon(900, center: CGPoint(x: 600, y: 200))); run(2.0)    // 新来的
    stage.deleteWithoutDrag([icons[0].id, icons[2].id]); run(3.5)              // 快捷键删两个
    run(14)                                                                    // 鼠标不动：无聊
    stage.mouse = CGPoint(x: icons[7].imageRect.maxX + 30, y: icons[7].imageRect.midY); run(1.0)   // 惊醒瞌睡虫
    return outputs
}

@Suite("确定性")
struct DeterminismTests {
    @Test func 同种子同输入_输出逐帧相同() {
        let first = playMedley(seed: 7)
        let second = playMedley(seed: 7)
        #expect(first.count == second.count)
        #expect(first == second)
        #expect(first.count > 2000)
    }

    @Test func 换种子_眨眼时刻不同_性格不变() {
        let first = playMedley(seed: 7)
        let other = playMedley(seed: 8)
        #expect(first != other)
        // 性格只看长相种子：同一帧里捂没捂眼两次是一样的。
        for (a, b) in zip(first, other) {
            #expect(a.faces.map { $0.state.cover > 0 } == b.faces.map { $0.state.cover > 0 })
        }
    }

    @Test func 重置之后和新建的一模一样() {
        let icons = makeGrid(count: 6)
        func inputs(from start: TimeInterval) -> [EmotionInput] {
            (0..<600).map { frame in
                let time = FrameTime(monotonic: start + Double(frame) * frameInterval, wallClock: Stage.today)
                let snapshot = IconSnapshot(icons: icons, status: .ok, capturedAt: time.monotonic, revision: 1)
                let facts = InteractionFacts(
                    time: time,
                    mouse: MouseState(position: CGPoint(x: 200 + frame, y: 300)),
                    hover: frame > 300 ? HoverState(iconID: icons[2].id, duration: 1) : nil
                )
                return EmotionInput(time: time, icons: frame == 0 ? IconUpdate(snapshot: snapshot, isReset: true) : .unchanged(snapshot), facts: facts)
            }
        }
        var fresh = EmotionDirector(seed: 11)
        let expected = inputs(from: 50).map { fresh.update($0) }

        var used = EmotionDirector(seed: 11)
        for input in inputs(from: 10) { _ = used.update(input) }
        used.reset()
        let actual = inputs(from: 50).map { used.update($0) }
        #expect(actual == expected)
    }
}

@Suite("平滑")
struct SmoothnessTests {
    @Test func 所有参数连续变化_没有一帧之内的突变() {
        var previous: [IconID: FaceState] = [:]
        var worst: [String: Double] = [:]
        _ = playMedley(seed: 3) { stage in
            var current: [IconID: FaceState] = [:]
            for face in stage.output.faces where face.state.mood != .ghost {
                current[face.iconID] = face.state
                guard let before = previous[face.iconID] else { continue }
                for parameter in FaceState.unitParameters where parameter.name != "gazeFollow" && parameter.name != "ghost" {
                    let change = abs(face.state[keyPath: parameter.keyPath] - before[keyPath: parameter.keyPath])
                    worst[parameter.name] = max(worst[parameter.name] ?? 0, change)
                }
                // 视线看"画面上偏到哪里"，不看原始的目标点。
                let (a, b) = (face.state.lookVector(), before.lookVector())
                let change = ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) + (a.z - b.z) * (a.z - b.z)).squareRoot()
                worst["look"] = max(worst["look"] ?? 0, change)
            }
            previous = current
        }
        print("[平滑] 每帧（1/60 秒）最大变化：" + worst.sorted { $0.key < $1.key }.map { "\($0.key) \(String(format: "%.3f", $0.value))" }.joined(separator: "  "))
        for (name, change) in worst {
            switch name {
            case "blink": #expect(change <= 0.35, "眨眼一帧变化 \(change)")          // 0.17 秒合上再睁开，本来就快
            case "look": #expect(change <= 0.40, "视线一帧变化 \(change)")            // 满幅是 2（从一头看到另一头）
            default: #expect(change <= 0.17, "\(name) 一帧变化 \(change)")
            }
        }
        // 剧本确实把各种参数都用到了。
        for name in ["blush", "fear", "sweat", "tremble", "tears", "dizziness", "cover", "peek", "sleepiness", "blink"] {
            #expect((worst[name] ?? 0) > 0, "\(name) 在剧本里没有变化过")
        }
    }

    @Test func 隔了很久才来的一帧_也不会一步到位() {
        let icons = makeGrid(count: 3)
        let stage = Stage(icons: icons)
        stage.run(0.5)
        // 应用休息了 5 秒，醒来时鼠标已经停在图标上。
        stage.hoverOn(icons[0].id)
        stage.step(5)
        #expect(stage.state(icons[0].id).blush < 0.25)
        stage.step(2)
        #expect(stage.state(icons[0].id).blush < 0.45)
        stage.run(1)
        #expect(stage.state(icons[0].id).blush == 1)
    }

    @Test func 视线转向时经过平视前方_不经过对眼() {
        // 鼠标从图标正左方的远处瞬间跳到正右方的远处。
        let icon = makeIcon(1, center: CGPoint(x: 700, y: 400))
        let stage = Stage(icons: [icon])
        stage.mouse = CGPoint(x: 100, y: 400)
        stage.run(0.5)
        stage.mouse = CGPoint(x: 1300, y: 400)
        var minFollow = 1.0
        var frames = 0
        var sideways: [Double] = []
        stage.run(0.6) { stage in
            let state = stage.state(icon.id)
            frames += 1
            minFollow = min(minFollow, state.gazeFollow)
            // 途中每一帧：要么目标还在远处，要么跟随程度已经降下来——不会出现"盯着自己鼻尖"的对眼。
            let near = state.gazeTarget.length < 30
            #expect(!near || state.gazeFollow < 0.35, "第 \(frames) 帧：目标离脸 \(state.gazeTarget.length) 点，跟随 \(state.gazeFollow)")
            sideways.append(state.lookVector().x)
        }
        #expect(minFollow < 0.3, "转向途中应当经过接近平视前方")
        #expect(sideways == sideways.sorted(), "瞳孔应当一路从左扫到右")
        #expect(stage.state(icon.id).gazeTarget == stage.mouse.offset(from: icon.imageRect.center))
    }
}

@Suite("省电信号")
struct DemandTests {
    @Test func 鼠标不动时画面静止_只在该眨眼时醒来() {
        let icons = makeGrid(count: 9)
        let stage = Stage(icons: icons)
        stage.run(0.5)
        // 模拟应用：严格按引擎给的需求出帧——要连续就按 1/60 秒走，否则直接睡到它说的时刻。
        let start = stage.time.monotonic
        var frames = 0
        var naps = 0
        var blinkFrames = 0
        while stage.time.monotonic - start < 10 {
            let before = stage.output
            switch stage.output.demand {
            case .continuous:
                stage.step()
            case let .by(time):
                #expect(time > stage.time.monotonic)
                let wait = time - stage.time.monotonic
                stage.step(wait)
                if wait > 0.05 {
                    // 睡了一觉，醒来是因为有人要眨眼了：这一帧它的眼皮已经开始合（不白醒一次），别的脸一点没变；
                    // 接下来按每秒 30 次出帧把这一下眨完。
                    naps += 1
                    let changed = zip(stage.output.faces, before.faces).filter { $0 != $1 }
                    #expect(!changed.isEmpty, "醒来的这一帧应当有人开始眨眼")
                    for (face, old) in changed {
                        var expected = old.state
                        expected.blink = face.state.blink
                        #expect(face.state.blink > 0.3 && face.state == expected, "醒来的这一帧只应当有眨眼在变")
                    }
                    guard case let .by(next) = stage.output.demand else {
                        Issue.record("眨眼期间应当约一个很近的时刻，实际 \(stage.output.demand)")
                        continue
                    }
                    #expect(abs(next - stage.time.monotonic - 1.0 / 30) < 1e-9)
                } else {
                    blinkFrames += 1
                }
            case .idle:
                Issue.record("桌面上有图标时，总有下一次眨眼要等，不应当是 idle")
                stage.step()
            }
            frames += 1
        }
        // 10 秒里 9 个图标大约眨 20 来次眼，每次 5 帧左右；每帧都算的话是 600 帧。
        print("[省电] 10 秒、9 个图标、鼠标不动：算了 \(frames) 帧（其中眨眼途中 \(blinkFrames) 帧），中间休息 \(naps) 次")
        #expect(frames < 150)
        #expect(naps >= 5)
        #expect(blinkFrames > 20)
    }

    @Test func 有参数在变时要求连续出帧_变完就不要了() {
        let icons = makeGrid(count: 4)
        let stage = Stage(icons: icons)
        stage.run(0.5)
        stage.hoverOn(icons[0].id)
        stage.step()
        #expect(stage.output.demand == .continuous)
        // 脸红到位之后：除了眨眼的那几帧，不再要求连续出帧。
        stage.run(1.5)
        var quietFrames = 0
        stage.run(2) { stage in
            if stage.output.demand != .continuous { quietFrames += 1 }
        }
        #expect(quietFrames > 80)

        // 幽灵飘着的时候一直要求连续出帧。
        stage.deleteWithoutDrag([icons[3].id])
        stage.run(2.5) { stage in
            #expect(stage.output.demand == .continuous)
        }
    }

    /// "静止承诺"：引擎说"现在是静止的，t 时刻之前不用再算"，那么在 t 之前、输入不变的情况下再算一次，
    /// 每张脸都必须和上一帧一模一样——否则应用按它说的去休息，画面就会停在一个不该停的地方。
    @Test(arguments: [11, 12, 13, 14, 15, 16] as [UInt64])
    func 说了静止就真的静止(seed: UInt64) {
        var random = SeededRandom(seed: seed)
        func chance(_ p: Double) -> Bool { random.nextUnit() < p }
        func pick(_ range: ClosedRange<Double>) -> Double { range.lowerBound + (range.upperBound - range.lowerBound) * random.nextUnit() }
        var icons = makeGrid(count: 12, columns: 4)
        for index in icons.indices where index % 4 == 0 { icons[index].modifiedAt = Stage.daysAgo(500) }
        let stage = Stage(icons: icons, seed: seed)
        var checked = 0
        var broken = 0

        for _ in 0..<60 {
            // 先随便折腾一阵……
            for _ in 0..<Int(pick(20...140)) {
                if stage.drag != nil {
                    stage.dragTo(CGPoint(x: stage.mouse.x + pick(-30...30), y: stage.mouse.y + pick(-20...35)))
                    if chance(0.05) { stage.dragTo(stage.trashRect!.center) }
                    if chance(0.03) { stage.drag?.shake = pick(0...1) }
                    if chance(0.03) {
                        // 松手之后有一半的时候立刻定住：停留期、飘回原位、落地都发生在"定住"期间。
                        stage.release()
                        stage.step()
                        if chance(0.5) { break }
                    }
                } else {
                    stage.mouse = CGPoint(x: stage.mouse.x + pick(-25...25), y: stage.mouse.y + pick(-25...25))
                    if chance(0.03), let icon = stage.icons.randomElement(using: &random) { stage.hoverOn(icon.id) }
                    if chance(0.05) { stage.hover = nil }
                    if chance(0.03), let icon = stage.icons.randomElement(using: &random) { stage.startDrag(icon.id) }
                }
                if let pending = stage.released.first, chance(0.03) {
                    switch Int(pick(0...2.99)) {
                    case 0: stage.settleMoved(pending.iconID, to: pending.imageRectAtRelease)
                    case 1: stage.settle(pending.iconID, as: .cancelled)
                    default: stage.settle(pending.iconID, as: .unknown)
                    }
                }
                if chance(0.004), stage.icons.count > 6, let icon = stage.icons.randomElement(using: &random),
                   stage.drag?.iconID != icon.id, !stage.released.contains(where: { $0.iconID == icon.id }) {
                    if stage.hover == icon.id { stage.hover = nil }
                    stage.deleteWithoutDrag([icon.id])
                }
                stage.step()
            }
            // ……然后一切定住（鼠标不动、拖着的不动、等结局的继续等），看它安静下来的一路上有没有食言。
            for _ in 0..<Int(pick(60...420)) {
                let before = stage.output
                let now = stage.time.monotonic
                stage.step()
                let promised: Bool
                switch before.demand {
                case .continuous: promised = false
                // 约的时刻很近（一两帧之内）是"降速的动画"（眨眼、慢慢消退的参数），不是静止承诺。
                case let .by(time): promised = time - now > 0.05 && stage.time.monotonic < time
                case .idle: promised = true
                }
                guard promised else { continue }
                checked += 1
                if stage.output.faces != before.faces {
                    broken += 1
                    if broken <= 3 {
                        let changed = zip(stage.output.faces, before.faces).first { $0 != $1 }
                        Issue.record("食言：\(now) 时说静止到 \(before.demand)，下一帧却变了：\(String(describing: changed))")
                    }
                }
            }
        }
        print("[静止承诺] 种子 \(seed)：检查了 \(checked) 帧，食言 \(broken) 帧")
        #expect(checked > 3000, "只检查到 \(checked) 帧静止承诺")
        #expect(broken == 0, "\(checked) 次静止承诺里食言 \(broken) 次")
    }

    @Test func 脸飘回原位落地的那一帧_不提前说静止() {
        // 松手后结局迟迟不来：主角的脸飘回原位。围观的图标一直看着它，落地之后它们的视线还要再挪最后一步。
        var tuning = EmotionTuning()
        tuning.blinkIntervalMin = 500     // 不让眨眼掺进来
        tuning.blinkIntervalMax = 600
        let icons = makeGrid(count: 6)
        let stage = Stage(icons: icons, tuning: tuning)
        stage.trashRect = nil
        stage.run(0.3)
        stage.startDrag(icons[0].id)
        stage.dragTo(CGPoint(x: 300, y: 700))
        stage.run(0.5)
        stage.release()
        var landed = false
        var checked = 0
        for _ in 0..<240 {
            let before = stage.output
            stage.step()
            if stage.face(icons[0].id)?.layer == .desktop { landed = true }
            // 说了"t 时刻之前是静止的"，而这一帧还没到 t：画面必须一点没变。
            var promised = before.demand == .idle
            if case let .by(time) = before.demand { promised = stage.time.monotonic < time }
            if promised {
                checked += 1
                #expect(stage.output.faces == before.faces, "说了静止，下一帧却变了")
            }
        }
        #expect(landed)
        #expect(checked > 60)
        // 最后大家看着的是主角的家（它已经回去了）。
        let home = icons[0].imageRect.center
        #expect(stage.state(icons[1].id).gazeTarget == home.offset(from: icons[1].imageRect.center))
    }

    @Test func 只剩慢慢消退的参数时_按每秒三十次出帧() {
        var tuning = EmotionTuning()
        tuning.blinkIntervalMin = 500     // 不让眨眼掺进来
        tuning.blinkIntervalMax = 600
        let icons = makeGrid(count: 3)
        let stage = Stage(icons: icons, tuning: tuning)
        stage.run(0.3)
        stage.hoverOn(icons[0].id)
        // 脸红起来是快的渐变：连续出帧。
        stage.step()
        stage.step()
        #expect(stage.output.demand == .continuous)
        stage.run(1.5)
        #expect(stage.state(icons[0].id).blush == 1)
        // 鼠标移开后停住：视线先转回去（快，连续出帧）；之后只剩脸红慢慢退——约的是 1/30 秒之后。
        stage.moveMouse(to: CGPoint(x: 300, y: 600))
        stage.step()
        var slowFrames = 0
        var continuousFrames = 0
        var frames = 0
        while stage.state(icons[0].id).blush > 0, frames < 600 {
            let now = stage.time.monotonic
            switch stage.output.demand {
            case .continuous:
                continuousFrames += 1
                stage.step()
            case let .by(time):
                #expect(abs(time - now - 1.0 / 30) < 1e-9, "脸红还没退完，应当约 1/30 秒之后，实际 \(time - now)，脸红 \(stage.state(icons[0].id).blush)")
                slowFrames += 1
                stage.step(time - now)
            case .idle:
                Issue.record("脸红还没退完就说不用算了")
                stage.step()
            }
            frames += 1
        }
        #expect(stage.state(icons[0].id).blush == 0)
        #expect(isCalmAndAwake(stage.state(icons[0].id)))
        #expect(slowFrames > 40 && slowFrames < 90, "慢慢退的那一段算了 \(slowFrames) 帧")
        #expect(continuousFrames < 40, "连续出帧的只有视线转回去的那一小段，实际 \(continuousFrames) 帧")

        // 关掉这个省电措施：全程连续出帧，结果一样退到 0。
        tuning.slowFrameInterval = 0
        let eager = Stage(icons: icons, tuning: tuning)
        eager.hoverOn(icons[0].id)
        eager.run(1.5)
        eager.moveMouse(to: CGPoint(x: 300, y: 600))
        eager.run(1.0) { stage in
            #expect(stage.output.demand == .continuous)
        }
    }

    @Test func 空桌面彻底休息() {
        let stage = Stage(icons: [])
        stage.step()
        #expect(stage.output.faces.isEmpty)
        #expect(stage.output.demand == .idle)
        stage.run(1)
        #expect(stage.output.demand == .idle)
    }

    @Test func 全都睡着时不为眨眼醒来() {
        // 三个图标里只能睡一个；另外两个照常眨眼。这里只看睡着的那个不贡献唤醒。
        var icons = makeGrid(count: 3)
        icons[0].modifiedAt = Stage.daysAgo(999)
        let stage = Stage(icons: icons)
        stage.mouse = CGPoint(x: 100, y: 700)
        stage.idle = 3
        stage.run(8) { stage in stage.idle = 3 }
        // 睡着的图标 8 秒里没有眨过眼，表情始终不变。
        #expect(stage.state(icons[0].id).blink == 0)
        #expect(stage.state(icons[0].id).sleepiness == 1)
    }

    @Test func 鼠标久不动进入安静状态_眨眼和张望都放慢_一动就恢复() {
        let icons = makeGrid(count: 12)
        func blinkStarts(idleFrom: TimeInterval, seconds: TimeInterval) -> (blinks: Int, glances: Int) {
            let stage = Stage(icons: icons)
            stage.mouse = CGPoint(x: 300, y: 650)
            stage.idle = idleFrom
            var blinks = 0
            var glancing: Set<IconID> = []
            var glances = 0
            var previous: [IconID: Double] = [:]
            stage.run(seconds) { stage in
                for icon in icons {
                    let state = stage.state(icon.id)
                    if state.blink > 0, (previous[icon.id] ?? 0) == 0 { blinks += 1 }
                    previous[icon.id] = state.blink
                    let away = state.gazeTarget != stage.mouse.offset(from: icon.imageRect.center)
                    if away, glancing.insert(icon.id).inserted { glances += 1 }
                    if !away { glancing.remove(icon.id) }
                }
            }
            return (blinks, glances)
        }
        // 同样的 60 秒：鼠标刚停下不久 vs 已经静止了很久（默认 20 秒开始放慢，40 秒后间隔是平时的 3 倍）。
        let lively = blinkStarts(idleFrom: 0, seconds: 20)
        let quiet = blinkStarts(idleFrom: 200, seconds: 60)
        // 换算成每分钟：安静时眨眼大约是平时的三分之一。
        let livelyPerMinute = Double(lively.blinks) * 3
        #expect(Double(quiet.blinks) < livelyPerMinute * 0.55, "平时每分钟 \(livelyPerMinute) 次，安静时 \(quiet.blinks) 次")
        #expect(quiet.blinks >= 12, "安静不是不眨：60 秒里 12 个图标眨了 \(quiet.blinks) 次")
        #expect(quiet.glances >= 5 && quiet.glances < 30, "安静时 60 秒里张望了 \(quiet.glances) 次")

        // 鼠标一动就恢复：排到很远以后的眨眼会被重新排到 7 秒之内。
        let stage = Stage(icons: icons)
        stage.mouse = CGPoint(x: 300, y: 650)
        stage.idle = 200
        stage.run(30)
        stage.mouse.x += 3
        var blinked: Set<IconID> = []
        stage.run(7.5) { stage in
            stage.idle = 0
            for icon in icons where stage.state(icon.id).blink > 0 { blinked.insert(icon.id) }
        }
        #expect(blinked.count == icons.count, "回神后 7.5 秒里只有 \(blinked.count) 个图标眨过眼")
    }

    @Test func 无聊开始的时刻会被预约() {
        let icons = makeGrid(count: 4)
        var tuning = EmotionTuning()
        tuning.blinkIntervalMin = 500     // 把眨眼排到很久以后，只看"无聊"的预约
        tuning.blinkIntervalMax = 600
        let stage = Stage(icons: icons, tuning: tuning)
        stage.idle = 2
        stage.run(0.5) { stage in stage.idle = 2 }
        guard case let .by(time) = stage.output.demand else {
            Issue.record("应当预约一个时刻，实际 \(stage.output.demand)")
            return
        }
        // 鼠标已静止 2 秒，无聊在 12 秒开始：还有 10 秒。
        #expect(abs(time - stage.time.monotonic - 10) < 0.05)
    }
}

@Suite("健壮性")
struct RobustnessTests {
    /// 检查一帧输出是否合乎接口约定。
    private func check(_ output: EmotionOutput, stage: Stage, sourceLocation: SourceLocation = #_sourceLocation) {
        var keys: Set<String> = []
        var seenGhost = false
        let ids = Set(stage.icons.map(\.id))
        for face in output.faces {
            #expect(face.state.isValid, "表情参数越界：\(face.state)", sourceLocation: sourceLocation)
            #expect(face.rect.minX.isFinite && face.rect.minY.isFinite && face.rect.width > 0 && face.rect.height > 0, sourceLocation: sourceLocation)
            #expect(keys.insert("\(face.iconID.rawValue)-\(face.layer.rawValue)").inserted, "同一个（图标，层）出现了两次", sourceLocation: sourceLocation)
            if face.state.mood == .ghost {
                seenGhost = true
                #expect(face.layer == .desktop, sourceLocation: sourceLocation)
                #expect(!ids.contains(face.iconID), "幽灵和图标本身同时出现", sourceLocation: sourceLocation)
            } else {
                #expect(!seenGhost, "幽灵应当排在所有脸的后面", sourceLocation: sourceLocation)
                #expect(ids.contains(face.iconID), "给不存在的图标画了脸", sourceLocation: sourceLocation)
                #expect(face.state.ghost == 0, sourceLocation: sourceLocation)
            }
        }
        // 每个图标至多一张脸（不会原位置一张、拖影上又一张）。
        let nonGhosts = output.faces.filter { $0.state.mood != .ghost }
        #expect(Set(nonGhosts.map(\.iconID)).count == nonGhosts.count, sourceLocation: sourceLocation)
        if case let .by(time) = output.demand {
            #expect(time > stage.time.monotonic, sourceLocation: sourceLocation)
        }
    }

    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8] as [UInt64])
    func 随机的长输入序列_参数始终合法_最后都能恢复(seed: UInt64) {
        var random = SeededRandom(seed: seed)
        func chance(_ p: Double) -> Bool { random.nextUnit() < p }
        func pick(_ range: ClosedRange<Double>) -> Double { range.lowerBound + (range.upperBound - range.lowerBound) * random.nextUnit() }
        func point() -> CGPoint { CGPoint(x: pick(-1900...1500), y: pick(0...1000)) }

        var nextRaw: UInt64 = 1000
        var icons = makeGrid(count: 14, columns: 5)
        for index in icons.indices where index % 3 == 0 { icons[index].modifiedAt = Stage.daysAgo(pick(100...900)) }
        let stage = Stage(icons: icons, seed: seed &* 31)
        var velocity = CGVector(dx: 3, dy: 2)
        var previousStates: [IconID: FaceState] = [:]
        var largestChange: [String: Double] = [:]

        for frame in 0..<5000 {
            // 鼠标：多数时候平滑移动，偶尔停住、偶尔瞬移。
            if chance(0.01) { velocity = CGVector(dx: pick(-25...25), dy: pick(-25...25)) }
            if chance(0.004) { velocity = .zero }
            let target = chance(0.002) ? point() : CGPoint(x: stage.mouse.x + velocity.dx, y: stage.mouse.y + velocity.dy)

            if stage.drag != nil {
                stage.dragTo(target)
                if chance(0.03) { stage.drag?.shake = pick(0...1) }
                if chance(0.01) { stage.dragTo(stage.trashRect?.center ?? target) }
                if chance(0.012) { stage.release() }
            } else {
                stage.mouse = target
                if chance(0.01), let icon = stage.icons.randomElement(using: &random) {
                    stage.hoverOn(icon.id)
                } else if chance(0.02) {
                    stage.hover = nil
                }
                if chance(0.008), let icon = stage.icons.randomElement(using: &random) {
                    stage.startDrag(icon.id, shake: chance(0.3) ? pick(0...1) : 0)
                }
            }
            // 松手之后的结局：随机一种。
            if let pending = stage.released.first, chance(0.08) {
                switch Int(pick(0...4.99)) {
                case 0: stage.settleMoved(pending.iconID, to: pending.imageRectAtRelease.offsetBy(dx: pick(-4...4), dy: pick(-4...4)))
                case 1: stage.settle(pending.iconID, as: .cancelled)
                case 2: stage.settleTrashed(pending.iconID)
                case 3: stage.settleLeftDesktop(pending.iconID)
                default: stage.settle(pending.iconID, as: .unknown)
                }
            }
            // 图标随时新增、消失、挪动、整体重载。
            if chance(0.006) {
                nextRaw += 1
                stage.addIcon(makeIcon(nextRaw, center: point(), modifiedAt: chance(0.4) ? Stage.daysAgo(pick(1...900)) : nil), announce: chance(0.7))
            }
            if chance(0.004), !stage.icons.isEmpty {
                let victims = (0..<Int(pick(1...3.99))).compactMap { _ in stage.icons.randomElement(using: &random)?.id }
                stage.deleteWithoutDrag(Array(Set(victims)))
            }
            if chance(0.003), let icon = stage.icons.randomElement(using: &random) {
                // 不管它正在被悬停、被拖着还是等着结局，直接让它消失。
                stage.removeIcon(icon.id, trashed: chance(0.5) ? .unknown : .no)
                if stage.hover == icon.id { stage.hover = nil }
                if stage.drag?.iconID == icon.id { stage.drag = nil }
                stage.released.removeAll { $0.iconID == icon.id }
            }
            if chance(0.004), let icon = stage.icons.randomElement(using: &random) {
                stage.modifyIcon(icon.id) { $0.imageRect.origin = CGPoint(x: pick(-1800...1400), y: pick(0...900)) }
            }
            if chance(0.0015) { stage.reloadAll(chance(0.2) ? [] : nil) }
            if chance(0.0008) {
                // 桌面被清空，过一会儿又来了一桌新的。
                stage.reloadAll([])
            } else if stage.icons.isEmpty, chance(0.02) {
                stage.reloadAll(makeGrid(count: 10, columns: 4, firstRaw: nextRaw + 1))
                nextRaw += 10
            }
            // 废纸篓：偶尔估算不出来，可信度随便变。
            if chance(0.003) { stage.trashRect = chance(0.3) ? nil : CGRect(x: pick(-1800...1400), y: pick(800...1000), width: 60, height: 70) }
            if chance(0.005) { stage.trashConfidence = pick(-0.5...1.5) }
            if chance(0.01) { stage.approaching = [true, false, nil].randomElement(using: &random)! }

            // 时间：多数是 1/60 秒，偶尔一帧隔很久，偶尔两帧同一时刻。
            let dt: TimeInterval = chance(0.01) ? pick(0.1...3) : (chance(0.01) ? 0 : frameInterval)
            let output = stage.step(dt)
            check(output, stage: stage)
            if frame % 997 == 0 { stage.idle = 30 }   // 偶尔来一段"很久没动"

            // 平滑：正常节奏（1/60 秒）的相邻两帧之间，同一张脸的每个参数都只变一小步。
            var current: [IconID: FaceState] = [:]
            for face in output.faces where face.state.mood != .ghost {
                current[face.iconID] = face.state
                guard dt == frameInterval, let before = previousStates[face.iconID] else { continue }
                for parameter in FaceState.unitParameters where parameter.name != "gazeFollow" && parameter.name != "ghost" {
                    let change = abs(face.state[keyPath: parameter.keyPath] - before[keyPath: parameter.keyPath])
                    largestChange[parameter.name] = max(largestChange[parameter.name] ?? 0, change)
                }
                let (a, b) = (face.state.lookVector(), before.lookVector())
                let change = ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) + (a.z - b.z) * (a.z - b.z)).squareRoot()
                largestChange["look"] = max(largestChange["look"] ?? 0, change)
            }
            previousStates = current
        }
        for (name, change) in largestChange {
            switch name {
            case "blink": #expect(change <= 0.35, "眨眼一帧变化 \(change)")
            case "look": #expect(change <= 0.45, "视线一帧变化 \(change)")
            default: #expect(change <= 0.25, "\(name) 一帧变化 \(change)")
            }
        }
        if seed == 1 {
            print("[平滑·随机序列] 每帧（1/60 秒）最大变化：" + largestChange.sorted { $0.key < $1.key }.map { "\($0.key) \(String(format: "%.3f", $0.value))" }.joined(separator: "  "))
        }

        // 收场：放下手里的东西，鼠标在远处慢慢动（不让它们无聊），等 30 秒。
        if stage.drag != nil { stage.release() }
        for pending in stage.released { stage.settle(pending.iconID, as: .cancelled) }
        stage.hover = nil
        stage.trashRect = CGRect(x: 1300, y: 900, width: 60, height: 70)
        var x: CGFloat = 5000
        stage.run(30) { stage in
            x += 1
            stage.mouse = CGPoint(x: x, y: 5000)
            self.check(stage.output, stage: stage)
        }
        // 没有图标卡在某个状态回不来：全都回到原位、桌面层，要么平静清醒，要么睡熟。
        #expect(stage.ghosts.isEmpty)
        #expect(stage.output.faces.count == stage.icons.count)
        var asleep = 0
        for icon in stage.icons {
            guard let face = stage.face(icon.id) else {
                Issue.record("图标 \(icon.id) 没有脸")
                continue
            }
            #expect(face.layer == .desktop)
            #expect(face.rect == icon.imageRect)
            var state = face.state
            if state.sleepiness == 1 {
                asleep += 1
                #expect(state.mood == .dozing)
                state.sleepiness = 0
                state.mood = .calm
            }
            #expect(isCalmAndAwake(state), "图标 \(icon.id) 没有恢复：\(face.state)")
            if face.state.sleepiness == 0 {
                #expect(face.state.gazeFollow == 1)
            }
        }
        #expect(asleep <= stage.icons.count / 3)
        // 鼠标停下之后，引擎不再要求连续出帧（除了眨眼）。
        var restFrames = 0
        stage.run(3) { stage in
            if stage.output.demand != .continuous { restFrames += 1 }
        }
        #expect(stage.icons.isEmpty || restFrames > 60, "鼠标停住后 3 秒里只有 \(restFrames) 帧不要求连续出帧")
    }

    @Test func 图标在任何时刻新增或消失都不出错() {
        let icons = makeGrid(count: 8)
        let stage = Stage(icons: icons)
        stage.run(0.5)

        // 正被悬停的图标消失。
        stage.hoverOn(icons[0].id)
        stage.run(0.3)
        stage.removeIcon(icons[0].id)
        stage.run(0.2) { self.check($0.output, stage: $0) }   // 悬停还指着它：照样不出错
        stage.hover = nil

        // 正被拖着的图标消失（事实里还说在拖它）。
        stage.startDrag(icons[1].id)
        stage.dragTo(stage.trashRect!.center)
        stage.run(1)
        stage.removeIcon(icons[1].id)
        stage.run(0.5) { stage in
            self.check(stage.output, stage: stage)
            #expect(stage.output.faces.allSatisfy { $0.iconID != icons[1].id })
        }
        stage.drag = nil
        stage.run(3)
        for icon in stage.icons { #expect(isCalmAndAwake(stage.state(icon.id))) }

        // 围观正在进行时来了新图标、走了旧图标。
        stage.startDrag(icons[2].id)
        stage.dragTo(stage.trashRect!.center)
        stage.run(1)
        stage.addIcon(makeIcon(300, center: CGPoint(x: 1200, y: 800)))
        stage.removeIcon(icons[3].id)
        stage.run(1) { self.check($0.output, stage: $0) }
        #expect(stage.face(IconID(rawValue: 300)) != nil)

        // 等结局的时候图标没了（没有结局、没有删除事件）。
        stage.release()
        stage.run(0.1)
        stage.removeIcon(icons[2].id)
        stage.run(0.5) { self.check($0.output, stage: $0) }
        stage.released = []

        // 幽灵飘着的时候桌面清空，再来一桌。
        stage.deleteWithoutDrag([icons[4].id, icons[5].id])
        stage.run(0.5)
        stage.reloadAll([])
        stage.step()
        #expect(stage.output.faces.isEmpty)
        stage.reloadAll(makeGrid(count: 5, firstRaw: 50))
        stage.run(1) { self.check($0.output, stage: $0) }
        #expect(stage.output.faces.count == 5)
    }

    @Test func 离谱的输入不出事() {
        let icons = makeGrid(count: 4)
        var director = EmotionDirector(seed: 1)
        var clock = 10.0
        func run(_ mutate: (inout InteractionFacts, inout [DesktopIcon], inout FrameTime) -> Void) -> EmotionOutput {
            var output = EmotionOutput()
            for frame in 0..<120 {
                clock += frameInterval
                var time = FrameTime(monotonic: clock, wallClock: Stage.today)
                var list = icons
                var facts = InteractionFacts(time: time, mouse: MouseState(position: CGPoint(x: 100, y: 100)))
                mutate(&facts, &list, &time)
                let snapshot = IconSnapshot(icons: list, status: .ok, capturedAt: 0, revision: UInt64(frame))
                output = director.update(EmotionInput(time: time, icons: .unchanged(snapshot), facts: facts))
                #expect(output.faces.allSatisfy { $0.state.isValid })
            }
            return output
        }
        // 鼠标位置、静止时长不是数字。
        _ = run { facts, _, _ in
            facts.mouse.position = CGPoint(x: CGFloat.nan, y: .infinity)
            facts.mouse.idleDuration = .nan
        }
        // 废纸篓的距离、可信度不是数字；甩动强度越界。
        _ = run { facts, _, _ in
            facts.drag = DragState(iconID: icons[0].id, grabOffset: .zero, originImageRect: icons[0].imageRect, position: CGPoint(x: 50, y: 50), shake: .nan, startedAt: 0)
            facts.trash = TrashInfo(estimatedRect: CGRect(x: 0, y: 0, width: 10, height: 10), confidence: .nan, distance: .nan, closingSpeed: .nan, isApproaching: true)
        }
        _ = run { facts, _, _ in
            facts.drag = DragState(iconID: icons[0].id, grabOffset: CGVector(dx: CGFloat.nan, dy: 0), originImageRect: icons[0].imageRect, position: CGPoint(x: 50, y: 50), shake: 7, startedAt: 0)
            facts.trash = TrashInfo(estimatedRect: CGRect(x: CGFloat.infinity, y: 0, width: 10, height: 10), confidence: 9, distance: -40, isOver: false)
        }
        // 拖拽、悬停、结局、删除说的是不存在的图标；删除事件的矩形不合法。
        let ghostly = run { facts, _, _ in
            let stranger = IconID(rawValue: 123_456)
            facts.hover = HoverState(iconID: stranger, duration: 1)
            facts.drag = DragState(iconID: stranger, grabOffset: .zero, originImageRect: .zero, position: .zero, startedAt: 0)
            facts.releasedDrags = [ReleasedDrag(iconID: stranger, releasePoint: .zero, imageRectAtRelease: .null, releasedAt: .nan)]
            facts.dragOutcomes = [DragOutcome(iconID: stranger, kind: .moved, releasePoint: .zero)]
            facts.deletions = [DeletionEvent(iconID: stranger, lastImageRect: .null, wasDragged: true, trashed: .unknown)]
        }
        #expect(ghostly.faces.count == 4)
        // 图标矩形不合法：这个图标不画脸，别的照常。同一个编号出现两次：只画一张脸。
        let odd = run { _, list, _ in
            list[0].imageRect = CGRect(x: 0, y: 0, width: 0, height: 64)
            list[1].imageRect = CGRect(x: CGFloat.nan, y: 0, width: 64, height: 64)
            list.append(list[3])
        }
        #expect(odd.faces.map(\.iconID) == [icons[2].id, icons[3].id])
        // 重复的编号排在前面，下一帧又没了：演员表照样对得上，不越界。
        _ = run { _, list, _ in list = [icons[0], icons[0], icons[1]] }
        let deduplicated = run { _, list, _ in list = [icons[0], icons[1]] }
        #expect(deduplicated.faces.map(\.iconID) == [icons[0].id, icons[1].id])
        #expect(deduplicated.faces.map(\.rect) == [icons[0].imageRect, icons[1].imageRect])
        // 宽高是负数的矩形不画脸。
        let negative = run { _, list, _ in list[0].imageRect = CGRect(origin: CGPoint(x: 400, y: 400), size: CGSize(width: -64, height: 64)) }
        #expect(negative.faces.map(\.iconID) == icons.dropFirst().map(\.id))
        // 时间不是数字、时间倒流。
        _ = run { _, _, time in time = FrameTime(monotonic: .nan, wallClock: Stage.today) }
        _ = run { _, _, time in time = FrameTime(monotonic: 5, wallClock: Stage.today.addingTimeInterval(-9e9)) }
        let final = run { _, _, _ in }
        #expect(final.faces.count == 4)
        #expect(final.faces.allSatisfy { isCalmAndAwake($0.state) })
    }
}

@Suite("兜底")
struct FallbackTests {
    @Test func 时间倒流_当作没有流逝() {
        let icons = makeGrid(count: 4)
        let snapshot = IconSnapshot(icons: icons, status: .ok, capturedAt: 0, revision: 1)
        var director = EmotionDirector(seed: 5)
        func frame(_ monotonic: TimeInterval, deleting: Bool = false) -> EmotionOutput {
            let time = FrameTime(monotonic: monotonic, wallClock: Stage.today)
            var facts = InteractionFacts(time: time, mouse: MouseState(position: CGPoint(x: 100, y: 100)))
            if deleting {
                facts.deletions = [DeletionEvent(iconID: IconID(rawValue: 99), lastImageRect: CGRect(x: 500, y: 500, width: 64, height: 64), wasDragged: false, trashed: .yes)]
            }
            return director.update(EmotionInput(time: time, icons: .unchanged(snapshot), facts: facts))
        }
        _ = frame(100)
        _ = frame(100.5, deleting: true)
        let before = frame(101.5)   // 幽灵飘了 1 秒
        let progress = before.faces.last?.state.ghost ?? -1
        #expect(abs(progress - 1 / 2.6) < 1e-9)
        // 时钟倒退 10 秒：幽灵不消失、不重演，停在原来的进度上；别的脸也不变。
        let rewound = frame(91.5)
        #expect(rewound.faces == before.faces)
        let stillBehind = frame(95)
        #expect(stillBehind.faces.last?.state.ghost == progress)
        // 时钟追上来之后接着走。
        let resumed = frame(102)
        #expect(abs((resumed.faces.last?.state.ghost ?? -1) - 1.5 / 2.6) < 1e-9)
    }

    @Test func 离谱的坐标加上原地踏步的时间_矩形不会变成非数字() {
        let icons = makeGrid(count: 3)
        let snapshot = IconSnapshot(icons: icons, status: .ok, capturedAt: 0, revision: 1)
        var director = EmotionDirector(seed: 5)
        func frame(_ monotonic: TimeInterval, dragAt x: CGFloat?) -> EmotionOutput {
            let time = FrameTime(monotonic: monotonic, wallClock: Stage.today)
            var facts = InteractionFacts(time: time, mouse: MouseState(position: CGPoint(x: 100, y: 100)))
            if let x {
                facts.drag = DragState(iconID: icons[0].id, grabOffset: .zero, originImageRect: icons[0].imageRect, position: CGPoint(x: x, y: 300), startedAt: 0)
            }
            return director.update(EmotionInput(time: time, icons: .unchanged(snapshot), facts: facts))
        }
        _ = frame(10, dragAt: 500)
        // 拖影的坐标大得离谱（能通过"是有限数"的检查），紧接着拖拽中断、时间原地踏步。
        for x in [1e200, 1e12, -1e300] as [CGFloat] {
            _ = frame(10.1, dragAt: x)
            for _ in 0..<3 {
                let output = frame(10.1, dragAt: nil)
                #expect(output.faces.count == 3)
                #expect(output.faces.allSatisfy { $0.rect.isDrawable && $0.state.isValid })
            }
        }
        // 之后一切照常：脸回到原位、桌面层。
        var output = EmotionOutput()
        for step in 1...120 { output = frame(10.1 + Double(step) / 60, dragAt: nil) }
        #expect(output.faces.map(\.rect) == icons.map(\.imageRect))
        #expect(output.faces.allSatisfy { $0.layer == .desktop })
    }

    @Test func 调参表里填了不像样的数_不崩溃不卡死() {
        var icons = makeGrid(count: 6)
        icons[0].modifiedAt = Stage.daysAgo(900)
        var tuning = EmotionTuning()
        tuning.maxSleepingFraction = .nan
        tuning.ghostDuration = .nan
        tuning.ghostStagger = .nan
        tuning.waveSpeed = 0
        tuning.fearRadius = -5
        tuning.blinkDuration = 0
        tuning.gazeSoftness = 0
        tuning.gazeTime = .nan
        tuning.newcomerBlinks = -3
        let stage = Stage(icons: icons, tuning: tuning)
        stage.run(1)
        #expect(stage.output.faces.count == 6)
        #expect(icons.allSatisfy { stage.state($0.id).sleepiness == 0 }, "名额不是数字：谁都不睡")
        stage.deleteWithoutDrag([icons[1].id, icons[2].id])
        stage.startDrag(icons[3].id)
        stage.dragTo(stage.trashRect!.center)
        stage.run(3) { stage in
            #expect(stage.output.faces.allSatisfy { $0.state.isValid && $0.rect.isDrawable })
        }
        #expect(stage.ghosts.isEmpty, "幽灵时长不是数字：不留幽灵")
        stage.release()
        stage.settle(icons[3].id, as: .cancelled)
        stage.addIcon(makeIcon(77, center: CGPoint(x: 600, y: 600)))
        stage.run(6)
        #expect(stage.output.faces.count == 5)
        #expect(stage.icons.allSatisfy { isCalmAndAwake(stage.state($0.id)) })
    }
}

@Suite("耗时")
struct PerformanceTests {
    @Test func 一百个图标每帧一次更新() {
        var icons = makeGrid(count: 100, columns: 10, origin: CGPoint(x: 200, y: 60))
        for index in icons.indices where index % 4 == 0 { icons[index].modifiedAt = Stage.daysAgo(400) }
        let stage = Stage(icons: icons)
        stage.run(0.5)
        let clock = ContinuousClock()

        // 平时：鼠标一直在动，一百双眼睛都在跟。
        var x: CGFloat = 0
        let following = clock.measure {
            stage.run(20) { stage in
                x += 11
                stage.mouse = CGPoint(x: x.truncatingRemainder(dividingBy: 1500), y: 300 + x.truncatingRemainder(dividingBy: 400))
            }
        }
        // 最热闹的时候：一个图标被拖到废纸篓上方，其余围观。
        stage.startDrag(icons[5].id, shake: 0.8)
        let crowd = clock.measure {
            stage.run(20) { stage in
                x += 3
                stage.dragTo(CGPoint(x: 1300 + x.truncatingRemainder(dividingBy: 40), y: 920))
            }
        }
        func perFrame(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000 / 1200 + Double(duration.components.attoseconds) / 1e15 / 1200
        }
        print(String(format: "[耗时·调试版] 100 个图标：跟随 %.4f 毫秒/帧，围观 %.4f 毫秒/帧（含测试舞台自己的开销）", perFrame(following), perFrame(crowd)))
        // 调试版比发布版慢得多，这里只防数量级的退步；发布版的数字见 swift run -c release EmotionDemo --bench。
        #expect(perFrame(following) < 3)
        #expect(perFrame(crowd) < 3)
    }
}
