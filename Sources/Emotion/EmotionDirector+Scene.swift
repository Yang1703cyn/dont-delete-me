// Emotion · 场景：主角（被拖的图标）、围观、幽灵、大家看哪、两个彩蛋

import CoreGraphics
import DDMCore
import Foundation

/// 一个幽灵。
struct Ghost: Sendable {
    /// 被删图标的编号（幽灵沿用它）。
    let id: IconID
    let faceSeed: UInt64
    /// 图标被删前在桌面上的位置，幽灵从这里飘起。
    let rect: CGRect
    /// 什么时候冒出来（一次删多个时略微错开）。
    let startAt: TimeInterval
}

/// "新来的"彩蛋：大家转头看它一眼。
struct Newcomer: Sendable {
    let id: IconID
    let until: TimeInterval
}

/// 这一帧的主角：正被拖着的图标；没有的话，是已松手、结局未定的那个。
struct Star: Sendable {
    let id: IconID
    /// 它的脸此刻在哪（拖影上，或松手处）。
    let center: CGPoint
    /// 它面临的威胁程度，0…1。
    let threat: Double
}

extension EmotionDirector {
    // MARK: - 幽灵

    /// 见到删除事件就在原地放幽灵；到时间的幽灵撤掉。
    mutating func updateGhosts(deletions: [DeletionEvent], now: TimeInterval, pulse: inout Pulse) {
        if !deletions.isEmpty {
            // 一次删多个：略微错开出现。个数很多时排密一些，总跨度不超过 ghostStaggerSpan。
            let gaps = max(deletions.count - 1, 1)
            let stagger = min(max(tuning.ghostStagger, 0), max(tuning.ghostStaggerSpan, 0) / Double(gaps))
            var order = 0
            for deletion in deletions {
                guard deletion.lastImageRect.isDrawable,
                      !ghosts.contains(where: { $0.id == deletion.iconID })
                else { continue }
                ghosts.append(Ghost(
                    id: deletion.iconID,
                    faceSeed: deletion.iconID.faceSeed,
                    rect: deletion.lastImageRect,
                    startAt: now + Double(order) * stagger
                ))
                order += 1
            }
        }
        guard !ghosts.isEmpty else { return }
        // 飘完的撤掉。图标又回到了桌面上（比如撤销了删除）的也撤掉：它活过来了，脸归它自己。
        let life = ghostLife
        ghosts.removeAll { !(now < $0.startAt + life) || indexByID[$0.id] != nil }
        for ghost in ghosts {
            if now >= ghost.startAt {
                pulse.animating = true
            } else {
                pulse.schedule(ghost.startAt)
            }
        }
    }

    /// 幽灵从冒出来到消散用多久。调参表里填了不像样的数（不是正数）时按 0 算，幽灵当帧就撤。
    private var ghostLife: TimeInterval {
        tuning.ghostDuration > 0 ? tuning.ghostDuration : 0
    }

    /// 幽灵的进度：0 刚冒出来，1 完全消散。
    private func progress(of ghost: Ghost, now: TimeInterval) -> Double {
        let life = ghostLife
        return life > 0 ? unit((now - ghost.startAt) / life) : 1
    }

    /// 把已经出场的幽灵排在这一帧所有脸的最后（画在最上面）。
    func appendGhostFaces(to faces: inout [FacePlacement], now: TimeInterval) {
        for ghost in ghosts where now >= ghost.startAt {
            let state = FaceState(mood: .ghost, seed: ghost.faceSeed, ghost: progress(of: ghost, now: now))
            faces.append(FacePlacement(iconID: ghost.id, rect: ghost.rect, layer: .desktop, state: state))
        }
    }

    // MARK: - 主角

    /// 标出这一帧的主角，更新它的脸在哪、威胁多大、是否被甩晕。
    mutating func updateStars(
        facts: InteractionFacts, icons: [DesktopIcon], now: TimeInterval, eases: Eases, pulse: inout Pulse
    ) -> Star? {
        let t = tuning

        // 结局是"挪了位置"：图标已经在新位置上了，脸直接落到那里，不飘。
        for outcome in facts.dragOutcomes where outcome.kind == .moved {
            if let index = indexByID[outcome.iconID] { performers[index].flightRect = nil }
        }

        var star: Star?
        if let drag = facts.drag, let index = indexByID[drag.iconID], drag.currentImageRect.isDrawable {
            let towardsTrash = facts.trash.map { $0.isApproaching || $0.isOver } ?? false
            var motion = Motion()
            approach(&heading, towardsTrash ? 1 : 0, rise: eases.headingRise, fall: eases.headingFall, &motion)
            pulse.absorb(motion, slowInterval: t.slowFrameInterval)
            let threat = threat(from: facts.trash)
            performers[index].isStar = true
            performers[index].isCarried = true
            performers[index].flightRect = drag.currentImageRect
            performers[index].heldThreat = threat
            // 猛甩：头晕。不甩之后（包括松手之后）还要晕一阵。
            if drag.shake >= t.shakeThreshold {
                // 晕到这一阵里甩得最猛的那个程度：甩得轻一点了（但还在甩）不会因此清醒一些。
                let level = unit(t.dizzyMin + (1 - t.dizzyMin) * ramp(drag.shake, t.shakeThreshold, 1))
                performers[index].dizzyGoal = max(performers[index].dizzyGoal, level)
                performers[index].dizzyUntil = now + t.dizzyLinger
            }
            star = Star(id: drag.iconID, center: drag.currentImageRect.center, threat: threat)
        } else {
            heading = 0
        }

        // 已松手、结局未定：威胁保持松手时的样子（屏住呼吸等结果）；
        // 脸先在松手处停一小会儿，结局迟迟不来就飘回原位等。
        for released in facts.releasedDrags {
            guard let index = indexByID[released.iconID], !performers[index].isStar else { continue }
            performers[index].isStar = true
            let holdEnds = released.releasedAt + t.releaseHold
            if now < holdEnds, released.imageRectAtRelease.isDrawable {
                performers[index].isCarried = true
                performers[index].flightRect = released.imageRectAtRelease
                pulse.schedule(holdEnds)
            }
            if star == nil {
                let rect = performers[index].flightRect ?? icons[performers[index].iconIndex].imageRect
                if rect.isDrawable {
                    star = Star(id: released.iconID, center: rect.center, threat: performers[index].heldThreat)
                }
            }
        }
        return star
    }

    /// 被拖着的图标面临的威胁，0…1：离废纸篓越近越大，正朝它去更大，到了上方恒为 1。
    ///
    /// 对废纸篓位置的偏差不敏感，靠三点：起作用的范围很宽（几百点）；估算越不可信，
    /// "已经到了"的范围放得越宽；离得越近，"是否正朝它去"越不起作用。
    private func threat(from trash: TrashInfo?) -> Double {
        guard let trash else { return 0 }
        if trash.isOver { return 1 }
        let distance = Double(trash.distance)
        guard distance.isFinite, tuning.fearRadius > 0 else { return 0 }
        // （距离再大也只是"离得很远"，不需要另外把关。）
        let confidence = trash.confidence.isFinite ? unit(trash.confidence) : 0
        let slack = (1 - confidence) * max(tuning.trashSlack, 0)
        let nearness = 1 - min(max(distance - slack, 0) / tuning.fearRadius, 1)
        let relief = unit(tuning.retreatRelief)
        return nearness * (relief + (1 - relief) * max(heading, nearness))
    }

    // MARK: - 围观

    /// 围观的开始与结束。返回围观者此刻该有多强的反应。
    mutating func updateAlarm(star: Star?, now: TimeInterval) -> Double {
        guard let star else {
            // 没有主角了（被删了、结局出来了、拖拽被打断了）：围观结束。
            alarm = nil
            return 0
        }
        if let current = alarm, current.victim != star.id || star.threat < tuning.alarmOff {
            alarm = nil
        }
        if alarm == nil, star.threat >= tuning.alarmOn {
            alarm = Alarm(victim: star.id, startedAt: now, epicenter: star.center)
        }
        return alarm == nil ? 0 : ramp(star.threat, tuning.alarmOff, tuning.alarmFullAt)
    }

    // MARK: - 大家看哪

    /// 这一帧大家一起看的地方：幽灵 > 被拖的主角 > 新来的图标。都没有就各看各的。
    mutating func currentFocus(
        star: Star?, icons: [DesktopIcon], now: TimeInterval, pulse: inout Pulse
    ) -> (point: CGPoint, owner: IconID?)? {
        // 目送幽灵：看最后冒出来的那个。它随进度匀速上升一个图标高（接口约定 §4.3）。
        var leading: Ghost?
        for ghost in ghosts where now >= ghost.startAt {
            if leading.map({ ghost.startAt >= $0.startAt }) ?? true { leading = ghost }
        }
        if let ghost = leading {
            let rise = CGFloat(progress(of: ghost, now: now)) * ghost.rect.height
            return (CGPoint(x: ghost.rect.midX, y: ghost.rect.midY - rise), nil)
        }
        if let star {
            return (star.center, star.id)
        }
        if let current = newcomer {
            if now < current.until, let index = indexByID[current.id],
               icons[performers[index].iconIndex].imageRect.isDrawable {
                pulse.schedule(current.until)
                return (icons[performers[index].iconIndex].imageRect.center, current.id)
            }
            newcomer = nil
        }
        return nil
    }

    // MARK: - 彩蛋·无聊

    /// 鼠标很久没动、又没有别的事：隔一会儿挑一个闲着的图标张望一下。返回现在是否无聊。
    ///
    /// 张望由导演统一安排（而不是每个图标各自定时），所以不管桌面上有多少图标，
    /// 同一时间在张望的只有一两个——没人看的时候不至于让整个应用一直忙着。
    mutating func updateBoredom(
        nothingGoingOn: Bool, idle: TimeInterval, quietStretch: Double,
        hoverID: IconID?, icons: [DesktopIcon], now: TimeInterval, pulse: inout Pulse
    ) -> Bool {
        let t = tuning
        guard nothingGoingOn, !performers.isEmpty else {
            nextGlanceAt = nil
            return false
        }
        guard idle >= t.boredAfter else {
            nextGlanceAt = nil
            // 鼠标要是一直不动，到这个时刻就该开始无聊了。
            pulse.schedule(now + (t.boredAfter - idle))
            return false
        }
        let gapLow = max(t.glanceGapMin, 0.05)
        let gapHigh = max(t.glanceGapMax, gapLow)
        if nextGlanceAt == nil {
            nextGlanceAt = now + gapLow * random.nextUnit()
        }
        if let due = nextGlanceAt, now >= due {
            beginGlance(icons: icons, hoverID: hoverID, now: now)
            nextGlanceAt = now + (gapLow + (gapHigh - gapLow) * random.nextUnit()) * quietStretch
        }
        if let due = nextGlanceAt { pulse.schedule(due) }
        return true
    }

    /// 挑一个闲着的图标，让它看一眼邻居或者别处。
    private mutating func beginGlance(icons: [DesktopIcon], hoverID: IconID?, now: TimeInterval) {
        let t = tuning
        let count = performers.count
        guard count > 0 else { return }
        // 随机挑一个起点，往后找几个，找到闲着的为止；都没空这次就算了。
        let start = Int(random.next() % UInt64(count))
        var chosen: Int?
        for probe in 0..<min(count, 6) {
            let index = (start + probe) % count
            if performers[index].isFreeToGlance(now: now, hoverID: hoverID) {
                chosen = index
                break
            }
        }
        // 无论挑没挑到，随机数都取一样多，结果才不随"谁有空"而错位。
        let wantsNeighbor = random.nextUnit() < t.glanceNeighborChance
        let pick = random.nextUnit()
        let angle = random.nextUnit() * 2 * .pi
        let hold = t.glanceHoldMin + max(t.glanceHoldMax - t.glanceHoldMin, 0) * random.nextUnit()
        guard let index = chosen else { return }

        let center = icons[performers[index].iconIndex].imageRect.center
        var vector = CGVector(
            dx: CGFloat(cos(angle) * t.glanceFarDistance), dy: CGFloat(sin(angle) * t.glanceFarDistance)
        )
        if wantsNeighbor, count > 1 {
            // 最近的三个邻居里随机看一个。
            var nearest: [(distance: CGFloat, center: CGPoint)] = []
            for other in performers.indices where other != index {
                let otherCenter = icons[performers[other].iconIndex].imageRect.center
                let distance = center.distance(to: otherCenter)
                guard distance.isFinite else { continue }
                if nearest.count < 3 {
                    nearest.append((distance, otherCenter))
                } else if let worst = nearest.indices.max(by: { nearest[$0].distance < nearest[$1].distance }),
                          distance < nearest[worst].distance {
                    nearest[worst] = (distance, otherCenter)
                }
            }
            if !nearest.isEmpty {
                nearest.sort { $0.distance < $1.distance }
                let neighbor = nearest[min(Int(pick * Double(nearest.count)), nearest.count - 1)]
                vector = neighbor.center.offset(from: center)
            }
        }
        guard vector.dx.isFinite, vector.dy.isFinite else { return }
        performers[index].glance = Glance(vector: vector, until: now + max(hold, 0.1))
    }
}
