// Emotion · 演员：一个图标的情绪状态
//
// 每个桌面图标对应一个演员。演员身上是一组"通道"（惊恐、汗、发抖、泪、头晕、脸红、围观反应、困意、视线），
// 每条通道各自朝自己的目标渐入渐出；这一帧的表情就是把这些通道的当前值拼起来。
// 没有"现在处于哪个状态"的开关——几种情绪可以同时存在、此消彼长，所以任何时刻的画面都是连续的。
// 谁压过谁（优先级）体现在目标值的计算里，见 docs/模块说明/emotion.md 第 3 节。

import CoreGraphics
import DDMCore
import Foundation

/// 图标的性格，决定它围观时的反应。由长相种子决定，同一个图标永远相同。
public enum EmotionPersonality: String, Sendable, CaseIterable {
    /// 胆小：捂眼，不敢看。
    case timid
    /// 好奇：捂眼，但从指缝偷看。
    case curious
    /// 胆大：瞪眼看。
    case bold

    /// 长相种子对应的性格。用的是长相种子派生出的第 1 路随机数
    /// （表情模块用第 0 路定五官），所以性格和长相互不相关。
    public init(faceSeed: UInt64, tuning: EmotionTuning = EmotionTuning()) {
        var random = SeededRandom(seed: SeededRandom.derive(faceSeed, stream: 1))
        let roll = random.nextUnit()
        if roll < tuning.timidShare {
            self = .timid
        } else if roll < tuning.timidShare + tuning.curiousShare {
            self = .curious
        } else {
            self = .bold
        }
    }
}

/// 这一帧里所有演员共用的场景信息。由导演每帧算一次。
struct FrameContext {
    var now: TimeInterval
    /// 平滑计算用的帧长（已封顶）。
    var step: TimeInterval
    var eases: Eases
    var mouse: CGPoint
    /// 鼠标是否正在动（刚动过）。
    var mouseMoving: Bool
    /// 鼠标悬停在谁身上。
    var hoverID: IconID?
    /// 废纸篓估算区域的中心。
    var trashCenter: CGPoint?
    /// 大家一起看的地方（幽灵、被拖的主角、新来的）；没有就各看各的（平时是鼠标）。
    var focus: CGPoint?
    /// 那个地方是谁——它自己不用看自己。
    var focusOwner: IconID?
    /// 正在进行的围观：从哪、什么时候开始传开。
    var alarm: Alarm?
    /// 围观者此刻该有多强的反应（由主角的威胁程度决定）。
    var scareLevel: Double
    /// 是否处于"无聊"状态（鼠标很久没动，也没有别的事）。
    var bored: Bool
    /// 刚从"安静"状态回过神：把排得太远的眨眼重新排一下。
    var rerollBlinks: Bool
    /// 安静状态下，眨眼间隔拉长的倍数（平时是 1）。
    var quietStretch: Double
}

/// 一次围观。
struct Alarm: Sendable {
    /// 被拖向废纸篓的是谁。
    var victim: IconID
    var startedAt: TimeInterval
    /// 波纹的中心：围观开始时主角所在的位置。
    var epicenter: CGPoint
}

/// 一次张望（无聊彩蛋）。
struct Glance: Sendable {
    /// 看向哪里，相对自己中心的位移。
    var vector: CGVector
    var until: TimeInterval
}

struct Performer: Sendable {
    let id: IconID
    let faceSeed: UInt64
    let personality: EmotionPersonality
    /// 这个图标在当前快照的图标数组里排第几。
    var iconIndex: Int
    /// 这个图标自己的随机数（眨眼间隔等）。每个图标一路，互不影响。
    var random: SeededRandom

    // MARK: 通道（都是 0…1）

    /// 主角的惊恐。
    var fear = 0.0
    var sweat = 0.0
    var tremble = 0.0
    var tears = 0.0
    var dizzy = 0.0
    var blush = 0.0
    /// 围观反应的强度。具体表现成什么（捂眼、偷看、瞪眼）看性格。
    var scare = 0.0
    /// 困意。
    var sleep = 0.0
    var gaze = Gaze()

    // MARK: 眨眼

    /// 下一次眨眼什么时候开始。
    var blinkAt: TimeInterval
    /// 正在眨的这一下是什么时候开始的；没在眨为 nil。
    var blinkStartedAt: TimeInterval?
    /// 眨完这一下之后还要紧接着再眨几下。
    var blinksQueued = 0

    // MARK: 打瞌睡

    /// 是否在"该打瞌睡"的名单上。由导演排定。
    var isSleeper = false
    /// 被惊醒后，醒到什么时候。
    var awakeUntil = -TimeInterval.infinity
    /// 刚刚悄悄建出来（不是"新来的"）：如果在名单上，直接从睡着的样子开始。
    var isFresh = true

    // MARK: 被拖拽

    /// 这一帧它是不是主角（正被拖着，或已松手、结局未定）。导演每帧标记，用完即清。
    var isStar = false
    /// 这一帧它的脸是不是被"拿着"（跟着拖影，或停在松手处）。导演每帧标记，用完即清。
    var isCarried = false
    /// 脸不在原位时画在哪里（拖拽层）；在原位为 nil。
    var flightRect: CGRect?
    /// 最近一次算出的威胁程度。松手后、结局出来之前保持这个值。
    var heldThreat = 0.0
    /// 头晕要晕到多重。
    var dizzyGoal = 0.0
    /// 头晕保持到什么时候才开始消退。
    var dizzyUntil = -TimeInterval.infinity

    // MARK: 无聊

    var glance: Glance?

    init(icon: DesktopIcon, iconIndex: Int, directorSeed: UInt64, now: TimeInterval, tuning: EmotionTuning) {
        id = icon.id
        faceSeed = icon.id.faceSeed
        personality = EmotionPersonality(faceSeed: faceSeed, tuning: tuning)
        self.iconIndex = iconIndex
        random = SeededRandom(seed: SeededRandom.derive(faceSeed ^ SeededRandom.mix(directorSeed), stream: 2))
        // 第一次眨眼在一个间隔之内随机，这样一桌图标一开始就不同步。
        blinkAt = now + random.nextUnit() * tuning.blinkIntervalMax
    }

    /// 作为"新来的"登场：醒着，过一小会儿连眨几下眼。
    mutating func greet(now: TimeInterval, tuning: EmotionTuning) {
        isFresh = false
        awakeUntil = now + tuning.wakeLinger
        if tuning.newcomerBlinks > 0 {
            blinkAt = now + tuning.newcomerBlinkDelay
            blinksQueued = tuning.newcomerBlinks - 1
        }
    }

    /// 现在有没有空张望一下（没睡、没被悬停、没有任何情绪在身上）。
    func isFreeToGlance(now: TimeInterval, hoverID: IconID?) -> Bool {
        glance == nil && id != hoverID && flightRect == nil && !isStar
            && sleep == 0 && !(isSleeper && now >= awakeUntil)
            && fear == 0 && sweat == 0 && tremble == 0 && tears == 0
            && scare == 0 && dizzy == 0 && blush == 0
    }

    // MARK: - 每一帧

    /// 推进一帧，给出这一帧的脸。图标矩形不合法时不画（返回 nil）。
    mutating func advance(
        icon: DesktopIcon, context: FrameContext, tuning t: EmotionTuning, pulse: inout Pulse
    ) -> FacePlacement? {
        let now = context.now
        let eases = context.eases
        let isStar = self.isStar
        let isCarried = self.isCarried
        self.isStar = false
        self.isCarried = false

        let home = icon.imageRect
        guard home.isDrawable else { return nil }

        var motion = Motion()

        // 1. 脸画在哪。被拿着的时候在拖影上；放手之后如果还没回到原位，就飘回去。
        var rect = home
        var layer = OverlayLayer.desktop
        if var flight = flightRect {
            if isCarried {
                rect = flight
                layer = .drag
            } else {
                let dx = Double(home.minX - flight.minX)
                let dy = Double(home.minY - flight.minY)
                let distance = (dx * dx + dy * dy).squareRoot()
                let stride = max(distance * eases.homing.k, t.homingMinSpeed * context.step)
                if !(distance > 0.5) || !(stride < distance) {
                    // 到家了。看着它的图标这一帧用的还是它上一步的位置，所以再要一帧。
                    flightRect = nil
                    motion.fast = true
                } else {
                    flight.origin.x += CGFloat(dx / distance * stride)
                    flight.origin.y += CGFloat(dy / distance * stride)
                    flight.size = home.size
                    flightRect = flight
                    rect = flight
                    layer = .drag
                    motion.fast = true
                }
            }
        }
        let center = rect.center
        let hovered = context.hoverID == id

        // 2. 主角的害怕：冒汗 → 发抖 → 大哭，全由威胁程度决定。
        let threat = isStar ? heldThreat : 0
        if !isStar { heldThreat = 0 }
        if threat > 0 || fear > 0 || sweat > 0 || tremble > 0 || tears > 0 {
            approach(&fear, ramp(threat, 0, t.fearFullAt), rise: eases.fearRise, fall: eases.fearFall, &motion)
            approach(&sweat, ramp(threat, t.sweatFrom, t.sweatFullAt), rise: eases.sweatRise, fall: eases.sweatFall, &motion)
            let trembleGoal = unit(t.trembleMax) * ramp(threat, t.trembleFrom, t.trembleFullAt)
            approach(&tremble, trembleGoal, rise: eases.trembleRise, fall: eases.trembleFall, &motion)
            approach(&tears, ramp(threat, t.tearsFrom, t.tearsFullAt), rise: eases.tearsRise, fall: eases.tearsFall, &motion)
        }

        // 3. 围观：波纹传到了才有反应。主角自己不围观自己。
        var scareGoal = 0.0
        if let alarm = context.alarm, !isStar {
            let delay = min(Double(center.distance(to: alarm.epicenter)) / max(t.waveSpeed, 1), t.waveMaxDelay)
            let arrival = alarm.startedAt + delay
            if now >= arrival {
                scareGoal = context.scareLevel
                // 睡着的也被吵醒。
                if isSleeper { awakeUntil = max(awakeUntil, now + t.wakeLinger) }
            } else {
                pulse.schedule(arrival)
            }
        }
        approach(&scare, scareGoal, rise: eases.scareRise, fall: eases.scareFall, &motion)

        // 4. 头晕：甩过之后保持一阵再消退；害怕上来时让位给害怕。
        if dizzyGoal > 0 || dizzy > 0 {
            var goal = 0.0
            if now < dizzyUntil {
                goal = dizzyGoal * (1 - ramp(threat, t.dizzyYieldFrom, t.dizzyYieldFullAt))
                pulse.schedule(dizzyUntil)
            } else {
                dizzyGoal = 0
            }
            approach(&dizzy, goal, rise: eases.dizzyRise, fall: eases.dizzyFall, &motion)
        }

        // 5. 打瞌睡：在名单上、又没人理，就睡；有人理（鼠标在旁边动、被悬停、被拖）就醒一阵。
        var sleepGoal = 0.0
        if isSleeper {
            let disturbed = hovered || isStar || flightRect != nil
                || (context.mouseMoving && Double(home.distance(to: context.mouse)) < t.wakeRadius)
            if disturbed { awakeUntil = now + t.wakeLinger }
            if now >= awakeUntil {
                sleepGoal = 1
            } else {
                pulse.schedule(awakeUntil)
            }
        }
        approach(&sleep, sleepGoal, rise: eases.dozeOff, fall: eases.wake, &motion)

        // 6. 害羞：被悬停就脸红。身上还有害怕、头晕的时候顾不上害羞。
        let blushGoal = hovered ? unit(1 - 2 * max(fear, dizzy, scare)) : 0
        approach(&blush, blushGoal, rise: eases.blushRise, fall: eases.blushFall, &motion)

        // 围观反应按性格变成具体的动作。还没完全醒的时候反应打折。
        let reaction = scare * (1 - sleep)
        var cover = 0.0
        var peek = 0.0
        var crowdFear = 0.0
        if reaction > 0 {
            switch personality {
            case .timid:
                cover = ramp(reaction, 0, t.timidCoverFullAt)
                crowdFear = t.timidFear * reaction
            case .curious:
                cover = ramp(reaction, t.curiousCoverFrom, t.curiousCoverFullAt)
                peek = unit(t.peekMax) * ramp(reaction, t.peekFrom, t.peekFullAt)
                crowdFear = t.curiousFear * reaction
            case .bold:
                crowdFear = t.boldFear * reaction
            }
        }
        let fearOut = unit(max(fear, crowdFear))

        // 7. 视线：这一帧想看哪里。
        var target: CGVector
        var follow = 1.0
        if isStar {
            // 主角：平时看着用户（平视前方）；越怕越盯着废纸篓。
            let stare = ramp(threat, t.stareFrom, t.stareFullAt)
            if let trash = context.trashCenter, stare > 0 {
                target = trash.offset(from: center)
                // 废纸篓就在脚下时往下看——盯着"自己所在的位置"会变成对眼。
                let height = Double(rect.height)
                let underfoot = 1 - ramp(Double(target.length), 0.5 * height, 1.5 * height)
                target.dy += CGFloat(height * t.stareDownward * underfoot)
                follow = stare
            } else {
                target = .zero
                follow = 0
            }
            glance = nil
        } else {
            let toMouse = context.mouse.offset(from: center)
            target = toMouse
            if let current = glance {
                if context.bored, !hovered, now < current.until {
                    target = current.vector
                    pulse.schedule(current.until)
                } else {
                    glance = nil
                }
            }
            if glance == nil, let focus = context.focus, context.focusOwner != id {
                target = focus.offset(from: center)
            }
            if blush > 0 {
                // 眼神躲闪：看向鼠标的反方向、偏下。脸越红躲得越彻底。
                let width = Double(rect.width)
                let side = -min(max(Double(toMouse.dx) / (0.25 * width), -1), 1)
                let awayX = side * width * t.shyLookAway
                let awayY = Double(rect.height) * t.shyLookDown
                target = CGVector(
                    dx: target.dx + (CGFloat(awayX) - target.dx) * CGFloat(blush),
                    dy: target.dy + (CGFloat(awayY) - target.dy) * CGFloat(blush)
                )
            }
        }
        if !(target.dx.isFinite && target.dy.isFinite) {
            target = .zero
            follow = 0
        }
        let softness = max(Double(rect.width) * t.gazeSoftness, 0.01)
        let look = gaze.advance(toward: target, follow: follow, softness: softness, ease: eases.gaze)
        if look.moving { motion.fast = true }
        // 睡着了、手捂严了，眼睛就不跟了——这两种时候画面不必随着目标移动而重画。
        let followOut = unit(look.follow * (1 - sleep) * (1 - cover))

        // 8. 眨眼。
        var blink = 0.0
        var needsBlinkFrame = false
        if let started = blinkStartedAt {
            let phase = t.blinkDuration > 0 ? (now - started) / t.blinkDuration : 1
            if phase >= 1 {
                blinkStartedAt = nil
                if blinksQueued > 0 {
                    blinksQueued -= 1
                    blinkAt = now + t.blinkRepeatGap
                } else {
                    blinkAt = now + nextBlinkGap(t) * context.quietStretch
                    if random.nextUnit() < t.doubleBlinkChance { blinksQueued = 1 }
                }
            } else {
                blink = unit(sin(.pi * max(phase, 0)))
                needsBlinkFrame = true
            }
        }
        if blinkStartedAt == nil {
            if context.rerollBlinks, blinkAt > now + t.blinkIntervalMax {
                blinkAt = now + random.nextUnit() * t.blinkIntervalMax
            }
            // 眼睛看不见（睡着、捂着）或者正瞪着（害怕、哭、晕）的时候不眨。
            let canBlink = sleep < 0.3 && cover < 0.3 && fearOut < 0.5 && tears < 0.2 && dizzy < 0.2
            if now >= blinkAt {
                if canBlink {
                    // 从"已经眨了一小步"开始：醒来的这一帧画面就有变化，不白醒一次。
                    let lead = t.blinkDuration > 0 ? min(context.step, 0.25 * t.blinkDuration) : 0
                    blinkStartedAt = now - lead
                    blink = lead > 0 ? unit(sin(.pi * lead / t.blinkDuration)) : 0
                    needsBlinkFrame = true
                } else {
                    // 这一下不眨了，重新排；不为它叫醒应用。
                    blinkAt = now + nextBlinkGap(t)
                }
            } else if canBlink {
                pulse.schedule(blinkAt)
            }
        }

        pulse.absorb(motion, slowInterval: t.slowFrameInterval)
        if needsBlinkFrame {
            // 眨眼不必每个显示刷新都算：没有别的动画时，按 blinkFrameInterval 出帧就够了。
            if t.blinkFrameInterval > 0 {
                pulse.schedule(now + t.blinkFrameInterval)
            } else {
                pulse.animating = true
            }
        }

        // 9. 拼成表情。
        let tearsOut = unit(tears)
        let dizzyOut = unit(dizzy)
        let blushOut = unit(blush)
        let sleepOut = unit(sleep)
        let mood: FaceMood
        if tearsOut > 0.4 {
            mood = .crying
        } else if cover > 0.5 {
            mood = .coveringEyes
        } else if fearOut > 0.2 {
            mood = .scared
        } else if dizzyOut > 0.25 {
            mood = .dizzy
        } else if blushOut > 0.3 {
            mood = .shy
        } else if sleepOut > 0.5 {
            mood = .dozing
        } else {
            mood = .calm
        }
        let state = FaceState(
            mood: mood,
            seed: faceSeed,
            gazeTarget: followOut > 0 ? look.target : .zero,
            gazeFollow: followOut,
            blink: blink,
            blush: blushOut,
            fear: fearOut,
            sweat: unit(sweat),
            tremble: unit(tremble),
            tears: tearsOut,
            dizziness: dizzyOut,
            cover: unit(cover),
            peek: unit(peek),
            sleepiness: sleepOut,
            ghost: 0
        )
        return FacePlacement(iconID: id, rect: rect, layer: layer, state: state)
    }

    /// 随机取下一次眨眼隔多久。
    private mutating func nextBlinkGap(_ t: EmotionTuning) -> TimeInterval {
        let low = max(t.blinkIntervalMin, 0.2)
        let high = max(t.blinkIntervalMax, low)
        return low + (high - low) * random.nextUnit()
    }
}
