// InputSense · 判断器（纯逻辑）
//
// 输入：时间 + 鼠标 + "鼠标处最上面是什么窗口" + 图标快照与变化事件 + 废纸篓的估算。
// 输出：这一帧的全部交互事实（`InteractionFacts`），外加"该记住的废纸篓松手位置"。
//
// 它不读时钟、不读系统、不自带定时器、不依赖 AppKit：同样的输入序列永远得到同样的输出序列，
// 所以可以用编好的鼠标轨迹做单元测试（`Tests/InputSenseTests/`）。
// 唯一"向外问"的地方是 `step` 的 `surfaceAt` 参数：判断器自己决定什么时候值得问一次
// "这个点上最上面是什么窗口"（那是一次系统查询），不需要时就不问。

import CoreGraphics
import DDMCore
import Foundation

/// 判断器的可调参数。默认值的来由见 `docs/模块说明/input-sense.md`。
struct JudgeTuning: Sendable, Equatable {
    // —— 拖拽 ——
    /// 起拖阈值（点）：按下后，横向或纵向移动达到它才算开始拖。
    /// 取系统自己的"起拖距离"（本机读到 4×4，见模块说明 d）。
    var dragThreshold: CGFloat = 4
    /// 鼠标事件的时刻最多可以比上一帧早这么多（秒）还被采信；再早就说明它不是"两帧之间"发生的。
    var eventTimeSlack: TimeInterval = 0.05
    /// 两次读数相隔不超过这么久，才去折算"事件发生的那一刻鼠标在哪"。
    /// 隔得更久（鼠标静止时读得稀）说明鼠标是这一段里才动起来的：人是先挪到位、再按下，所以按下点取当前位置。
    var eventInterpolationWindow: TimeInterval = 0.05

    // —— 鼠标 ——
    /// 速度平滑的时间常数（秒）。
    var velocitySmoothing: TimeInterval = 0.05

    // —— 遮挡判断的频率 ——
    // 每问一次"鼠标处最上面是什么窗口"都要和窗口服务器往返一趟（0.02～1 毫秒，见模块说明 a），所以要省着问。
    // 按键按下或松开的那一帧不受下面这些间隔限制，总是立刻问。
    /// 鼠标进入一个图标：尽快问（悬停不能建立在旧结果上），但离上一次至少隔这么久——飞快扫过一排图标时不至于每帧都问。
    var surfaceIntervalEntering: TimeInterval = 1.0 / 30
    /// 鼠标在动：每隔这么久问一次（每秒 15 次）。
    var surfaceIntervalMoving: TimeInterval = 1.0 / 15
    /// 鼠标停在某个图标上：每隔这么久复查一次（窗口可能自己冒出来盖住它）。
    /// 不必更勤：图标被窗口盖住时脸也被盖住了，悬停晚半秒消失是看不见的。
    var surfaceIntervalStill: TimeInterval = 0.5
    /// 鼠标停着、下面没有图标：每隔这么久复查一次（这时答案几乎不影响任何判断）。
    var surfaceIntervalIdle: TimeInterval = 1
    /// 正在拖、或者有键按着：这时不可能有悬停，只是让"是否在桌面上"这个事实别太旧。
    var surfaceIntervalBusy: TimeInterval = 0.2

    // —— 省电信号 ——
    /// 鼠标最近这么久之内动过，就要连续出帧。
    var activeWindow: TimeInterval = 0.5
    /// 鼠标停在某个图标上：每隔这么久读一次（要尽快看到"按下"）。
    var hoverPollInterval: TimeInterval = 1.0 / 30
    /// 鼠标停着、不在图标上：每隔这么久读一次。
    var idlePollInterval: TimeInterval = 0.1
    /// 静止超过这么久算"长时间不动"……
    var longIdleAfter: TimeInterval = 30
    /// ……之后每隔这么久读一次。
    var longIdlePollInterval: TimeInterval = 0.2

    // —— 结局判定 ——
    /// 松手在桌面上：松手后至少过这么久再读到"图标还在原位"，才下"取消"的结论（给访达留出更新的时间）。
    /// 比两个重读间隔略短，这样第三次重读正好能用。
    var cancelSettle: TimeInterval = 0.28
    /// 松手在别处（程序坞、窗口、别的应用）：访达可能要真的去搬文件，多等一会儿再下"取消"的结论，
    /// 免得"拖进废纸篓但访达慢了半拍"被先判成取消。
    var cancelSettleOffDesktop: TimeInterval = 0.95
    /// 松手后等这么久还判断不出，结局记为"未知"。
    var outcomeTimeout: TimeInterval = 3
    /// 等结局期间请应用重读图标：刚松手时每隔这么久一次（图标桥自己保证相邻两次读取至少隔 0.15 秒）……
    var refreshInterval: TimeInterval = 0.15
    /// ……松手超过这么久之后……
    var refreshFastPeriod: TimeInterval = 0.3
    /// ……放慢到每隔这么久一次。
    var refreshSlowInterval: TimeInterval = 0.35
    /// 各种"每隔多久做一次"的判断允许提前这么多（秒）。帧的间隔本身有零点几毫秒的抖动，
    /// 不留这点余量的话，"每两帧一次"会时不时变成"每三帧一次"。
    var timingSlack: TimeInterval = 0.002
    /// 图标桥查不出"是否进了废纸篓"时，废纸篓估算的可信度至少要有这么高，才凭"松手点在废纸篓上方"认定被删。
    var trashInferenceConfidence: Double = 0.6

    var shake = ShakeMeter.Tuning()
    var approach = TrashApproach.Tuning()
}

/// 判断器一帧的输入。
struct JudgeInput: Sendable {
    var time: FrameTime
    var pointer: PointerSample
    var icons: IconUpdate
    /// 废纸篓的估算；估算不出来为 nil。
    var trash: TrashEstimate?
}

/// 判断器一帧的输出。
struct JudgeOutput: Sendable, Equatable {
    var facts: InteractionFacts
    /// 自学习：这一帧里确认"拖进了程序坞上的废纸篓"的那些拖拽的松手位置。
    var trashLessons: [CGPoint] = []
}

struct InteractionJudge: Sendable {
    var tuning: JudgeTuning

    init(tuning: JudgeTuning = JudgeTuning()) {
        self.tuning = tuning
    }

    // MARK: 状态

    private struct Frame: Sendable {
        var time: TimeInterval
        var position: CGPoint
        var buttons: MouseButtons
        /// 这一帧的位置和再上一帧相比变没变。
        var moved: Bool
    }

    /// 最近一次"鼠标处最上面是什么窗口"的查询结果。
    private struct SurfaceReading: Sendable {
        var value: PointerSurface
        var sampledAt: TimeInterval
        var position: CGPoint
        /// 查询那一刻鼠标下面的图标。
        var iconID: IconID?
    }

    /// 在某个图标上按下了左键、还没动够起拖阈值。
    private struct PressCandidate: Sendable {
        var iconID: IconID
        var point: CGPoint
        var originImageRect: CGRect
    }

    private struct ActiveDrag: Sendable {
        var state: DragState
        var meter: ShakeMeter
    }

    /// 已松手、在等结局的拖拽。
    private struct PendingRelease: Sendable {
        var drag: ReleasedDrag
        var originImageRect: CGRect
        /// 松手那一刻，松手点是否落在（足够可信的）废纸篓估算区域里。
        var releasedOverTrash: Bool
        /// 松手那一刻，鼠标处最上面是不是程序坞。
        var releasedOnDock = false
        /// 松手后至少过多久再读到"还在原位"才算取消。
        var settle: TimeInterval
        /// 下一次该请应用重读图标的时刻。
        var nextRefreshAt: TimeInterval
    }

    /// 一次已松手的拖拽此刻能下什么结论。
    private enum Resolution {
        /// 还得再等。
        case waiting
        /// 有结论了。
        case settled(DragOutcome)
        /// 图标从桌面上不见了，但没有收到它的消失事件（整体重载时会这样）。
        case vanished
    }

    private var motion = PointerMotion()
    private var previous: Frame?
    private var surface: SurfaceReading?
    private var hover: (iconID: IconID, since: TimeInterval)?
    private var press: PressCandidate?
    private var drag: ActiveDrag?
    private var released: [PendingRelease] = []
    private var approach = TrashApproach()

    /// 一共问了多少次"鼠标处最上面是什么窗口"。供演示和测试观察限频效果。
    private(set) var surfaceSampleCount = 0

    /// 此刻是否有图标正被拖着。
    var isDragging: Bool { drag != nil }

    /// 最近一次查到的"鼠标处最上面是什么窗口"；还没查过为 nil。
    var lastSurface: PointerSurface? { surface?.value }

    /// 丢弃进行到一半的判断，回到初始状态。可调参数不变。
    mutating func reset() {
        self = InteractionJudge(tuning: tuning)
    }

    // MARK: 一帧

    /// 喂一帧数据，得到这一帧的事实。
    /// - Parameter sampleSurface: "这个点上最上面是什么窗口"。只在判断器认为该查的时候才会被调用，一帧最多一次。
    mutating func step(_ input: JudgeInput, surfaceAt sampleSurface: (CGPoint) -> PointerSurface) -> JudgeOutput {
        let now = input.time.monotonic
        let pointer = input.pointer
        let snapshot = input.icons.snapshot
        let usable = snapshot.status.isUsable
        let previous = self.previous
        approach.tuning = tuning.approach

        motion.update(position: pointer.position, at: now, smoothing: tuning.velocitySmoothing)

        var outcomes: [DragOutcome] = []
        var deletions: [DeletionEvent] = []
        var lessons: [CGPoint] = []

        // —— 1. 左键的按下与松开 ——
        // 先于图标变化处理：松手和"图标消失"落在同一帧时，要按"松手之后消失"结算。
        let leftDown = pointer.buttons.contains(.left)
        // 第一帧没有"上一帧"：左键若已经按着，不知道它是在哪按下的，不当作新的按下。
        let wasLeftDown = previous?.buttons.contains(.left) ?? leftDown
        let buttonsChanged = previous.map { $0.buttons != pointer.buttons } ?? false
        var sampledThisFrame = false
        var justReleased: IconID?

        if wasLeftDown && !leftDown {
            if let active = drag {
                let (point, time) = eventMoment(
                    pointer.lastLeftUpAt, previous: previous, now: now, position: pointer.position, fromRestStaysPut: false
                )
                var state = active.state
                state.position = point
                released.append(PendingRelease(
                    drag: ReleasedDrag(
                        iconID: state.iconID, releasePoint: point,
                        imageRectAtRelease: state.currentImageRect, releasedAt: time
                    ),
                    originImageRect: state.originImageRect,
                    releasedOverTrash: isOverTrustedTrash(point, input.trash),
                    settle: tuning.cancelSettleOffDesktop,
                    nextRefreshAt: now
                ))
                justReleased = state.iconID
                drag = nil
            }
            press = nil
        }

        if !wasLeftDown && leftDown {
            press = nil
            // 只有"单按左键"才可能起拖；右键、中键同时按着的不算。
            if pointer.buttons == [.left] {
                let (point, _) = eventMoment(
                    pointer.lastLeftDownAt, previous: previous, now: now, position: pointer.position, fromRestStaysPut: true
                )
                let icon = usable ? snapshot.icon(at: point) : nil
                // 按下的那一刻必须现查：这是"点在桌面图标上"的唯一依据。
                let value = sampleSurface(point)
                surfaceSampleCount += 1
                surface = SurfaceReading(value: value, sampledAt: now, position: point, iconID: icon?.id)
                sampledThisFrame = true
                if let icon, value.isDesktop {
                    press = PressCandidate(iconID: icon.id, point: point, originImageRect: icon.imageRect)
                }
            }
        }

        // —— 2. 遮挡判断（限频）——
        let iconUnderPointer = usable ? snapshot.icon(at: pointer.position) : nil
        if !sampledThisFrame, shouldSampleSurface(
            at: now, position: pointer.position, iconID: iconUnderPointer?.id,
            buttons: pointer.buttons, buttonsChanged: buttonsChanged
        ) {
            surface = SurfaceReading(
                value: sampleSurface(pointer.position), sampledAt: now,
                position: pointer.position, iconID: iconUnderPointer?.id
            )
            surfaceSampleCount += 1
        }
        let isOverDesktop = surface?.value.isDesktop ?? false

        // 刚松手：松手处是什么（松手的那一帧一定现查过）决定了"取消"要等多久、松手点能不能拿来学废纸篓的位置。
        if let iconID = justReleased, let index = released.firstIndex(where: { $0.drag.iconID == iconID }) {
            released[index].releasedOnDock = surface?.value == .dock
            released[index].settle = isOverDesktop ? tuning.cancelSettle : tuning.cancelSettleOffDesktop
        }

        // —— 3. 图标变化 ——
        if input.icons.isReset {
            // 整体重载：按下时记的矩形可能已经不是现在的了。还没拖起来的作废；拖着的按新快照重取原位置。
            press = nil
            if var active = drag, let icon = snapshot.icon(withID: active.state.iconID) {
                active.state.originImageRect = icon.imageRect
                drag = active
            }
        }
        for change in input.icons.changes {
            guard case let .removed(icon, verdict) = change else { continue }
            // 按着还没拖起来的那个图标不见了：这次按下不可能再变成拖拽。
            if press?.iconID == icon.id { press = nil }
            if let active = drag, active.state.iconID == icon.id {
                // 左键还没松，图标就从桌面消失了（很少见，例如被别的程序删掉）：拖拽到此为止。
                // 用户并没有在废纸篓上松手，所以不凭鼠标位置认定被删，也不拿这个位置去学。
                drag = nil
                settleRemoval(
                    iconID: icon.id, releasePoint: pointer.position, originImageRect: active.state.originImageRect,
                    verdict: verdict, releasedOverTrash: false, teaches: false,
                    outcomes: &outcomes, deletions: &deletions, lessons: &lessons
                )
            } else if let index = released.firstIndex(where: { $0.drag.iconID == icon.id }) {
                let pending = released.remove(at: index)
                settleRemoval(
                    iconID: icon.id, releasePoint: pending.drag.releasePoint, originImageRect: pending.originImageRect,
                    verdict: verdict, releasedOverTrash: pending.releasedOverTrash, teaches: pending.releasedOnDock,
                    outcomes: &outcomes, deletions: &deletions, lessons: &lessons
                )
            } else if verdict == .yes {
                // 没有拖拽过程的删除（快捷键、右键菜单），或者一次已经下过结论的拖拽之后才迟到的删除——
                // 后者也标"没有经过拖拽"：接口约定里"经过拖拽"的删除一定同帧带着"进了废纸篓"的结局。
                // 查不出来（unknown）的不报：没有别的事实可以佐证，宁可少一个幽灵。
                deletions.append(DeletionEvent(iconID: icon.id, lastImageRect: icon.imageRect, wasDragged: false, trashed: verdict))
            }
        }

        // —— 4. 起拖：按住并移动超过阈值 ——
        if leftDown, drag == nil, let candidate = press {
            let moved = pointer.position.offset(from: candidate.point)
            if max(abs(moved.dx), abs(moved.dy)) >= tuning.dragThreshold {
                press = nil
                // 起拖的那一刻图标还得在（可用的）快照里。
                if usable, snapshot.icon(withID: candidate.iconID) != nil {
                    // 同一个图标上一次拖拽的结局还没等到就又被拖走了：上一次只能记为未知。
                    if let index = released.firstIndex(where: { $0.drag.iconID == candidate.iconID }) {
                        let stale = released.remove(at: index)
                        outcomes.append(DragOutcome(iconID: stale.drag.iconID, kind: .unknown, releasePoint: stale.drag.releasePoint))
                    }
                    var meter = ShakeMeter()
                    meter.tuning = tuning.shake
                    drag = ActiveDrag(
                        state: DragState(
                            iconID: candidate.iconID,
                            grabOffset: candidate.point.offset(from: candidate.originImageRect.origin),
                            originImageRect: candidate.originImageRect,
                            position: pointer.position,
                            startedAt: now
                        ),
                        meter: meter
                    )
                }
            }
        }

        // —— 5. 拖拽进行中：位置、速度、甩动强度 ——
        if var active = drag {
            active.state.position = pointer.position
            active.state.velocity = motion.velocity
            active.state.shake = active.meter.update(position: pointer.position, at: now)
            drag = active
        }

        // —— 6. 悬停 ——
        if drag == nil, pointer.buttons.isEmpty, isOverDesktop,
           let icon = iconUnderPointer, surface?.iconID == icon.id {
            if hover?.iconID != icon.id {
                hover = (icon.id, now)
            }
        } else {
            hover = nil
        }

        // —— 7. 等着结局的拖拽：看松手之后读到的快照 ——
        var stillPending: [PendingRelease] = []
        for pending in released {
            switch resolution(of: pending, snapshot: snapshot, now: now) {
            case .waiting:
                stillPending.append(pending)
            case let .settled(outcome):
                outcomes.append(outcome)
            case .vanished:
                // 图标不在了，却没有它的消失事件：和"图标桥查不出去向"同样处理。
                settleRemoval(
                    iconID: pending.drag.iconID, releasePoint: pending.drag.releasePoint, originImageRect: pending.originImageRect,
                    verdict: .unknown, releasedOverTrash: pending.releasedOverTrash, teaches: false,
                    outcomes: &outcomes, deletions: &deletions, lessons: &lessons
                )
            }
        }
        released = stillPending

        var wantsRefresh = false
        for index in released.indices where now >= released[index].nextRefreshAt - tuning.timingSlack {
            wantsRefresh = true
            let age = now - released[index].drag.releasedAt
            let isFast = age < tuning.refreshFastPeriod - tuning.timingSlack
            released[index].nextRefreshAt = now + (isFast ? tuning.refreshInterval : tuning.refreshSlowInterval)
        }

        // —— 8. 废纸篓 ——
        let trash = input.trash.map {
            approach.update(estimate: $0, position: pointer.position, velocity: motion.velocity, at: now)
        }

        // —— 9. 省电信号 ——
        let idle = motion.idleDuration(at: now)
        var demand: FrameDemand
        if !pointer.buttons.isEmpty || drag != nil || idle < tuning.activeWindow {
            demand = .continuous
        } else if hover != nil {
            demand = .by(now + tuning.hoverPollInterval)
        } else {
            demand = .by(now + (idle < tuning.longIdleAfter ? tuning.idlePollInterval : tuning.longIdlePollInterval))
        }
        for pending in released {
            demand = demand.merged(with: .by(min(pending.nextRefreshAt, pending.drag.releasedAt + tuning.outcomeTimeout)))
        }

        self.previous = Frame(
            time: now, position: pointer.position, buttons: pointer.buttons,
            moved: previous.map { $0.position != pointer.position } ?? false
        )

        let facts = InteractionFacts(
            time: input.time,
            mouse: MouseState(
                position: pointer.position, buttons: pointer.buttons,
                velocity: motion.velocity, idleDuration: idle
            ),
            isMouseOverDesktop: isOverDesktop,
            hover: hover.map { HoverState(iconID: $0.iconID, duration: now - $0.since) },
            drag: drag?.state,
            releasedDrags: released.map(\.drag),
            trash: trash,
            dragOutcomes: outcomes,
            deletions: deletions,
            wantsIconRefresh: wantsRefresh,
            demand: demand
        )
        return JudgeOutput(facts: facts, trashLessons: lessons)
    }

    // MARK: 细节

    /// 该不该现在问一次"鼠标处最上面是什么窗口"。
    private func shouldSampleSurface(
        at now: TimeInterval, position: CGPoint, iconID: IconID?, buttons: MouseButtons, buttonsChanged: Bool
    ) -> Bool {
        guard let reading = surface else { return true }
        // 按键变了（例如刚松手）：立刻查。松手处是什么、松手后能不能马上悬停，都看这一次。
        if buttonsChanged { return true }
        let age = now - reading.sampledAt + tuning.timingSlack
        // 正在拖、或者有键按着（框选、拖别的窗口）：不可能有悬停，慢慢查就行。
        if drag != nil || !buttons.isEmpty { return age >= tuning.surfaceIntervalBusy }
        // 鼠标进了一个图标：尽快查，悬停不能建立在进来之前的结果上。离开图标不用急——没有图标就没有悬停。
        if let iconID, iconID != reading.iconID { return age >= tuning.surfaceIntervalEntering }
        if position != reading.position { return age >= tuning.surfaceIntervalMoving }
        return age >= (iconID != nil ? tuning.surfaceIntervalStill : tuning.surfaceIntervalIdle)
    }

    /// 一个鼠标事件（按下或松开）发生时鼠标在哪、是什么时刻。
    ///
    /// 我们只在每帧读一次鼠标，事件发生在两帧之间；如果系统说得出事件的时刻，就在上一帧和这一帧的位置之间按比例取，
    /// 否则只能用这一帧的位置和时刻。这样抓取偏移不会因为"按下后鼠标已经走了一段"而偏掉。
    ///
    /// - Parameter fromRestStaysPut: 上一帧鼠标是静止的话，直接取上一帧的位置。用于"按下"：
    ///   人总是先停稳、按下、再开始移动，所以相邻两帧之间的那点位移发生在按下之后。
    private func eventMoment(
        _ eventTime: TimeInterval?, previous: Frame?, now: TimeInterval, position: CGPoint, fromRestStaysPut: Bool
    ) -> (point: CGPoint, time: TimeInterval) {
        guard let eventTime, let previous, now > previous.time,
              eventTime >= previous.time - tuning.eventTimeSlack, eventTime <= now + tuning.eventTimeSlack
        else { return (position, now) }
        let clamped = min(max(eventTime, previous.time), now)
        // 两次读数隔得久（鼠标静止时读得稀）：这一段里鼠标先挪到了位、然后才按下，位置只能信当前的。
        guard now - previous.time <= tuning.eventInterpolationWindow else { return (position, clamped) }
        if fromRestStaysPut, !previous.moved {
            return (previous.position, clamped)
        }
        let fraction = CGFloat((clamped - previous.time) / (now - previous.time))
        let point = CGPoint(
            x: previous.position.x + (position.x - previous.position.x) * fraction,
            y: previous.position.y + (position.y - previous.position.y) * fraction
        )
        return (point, clamped)
    }

    private func isOverTrustedTrash(_ point: CGPoint, _ trash: TrashEstimate?) -> Bool {
        guard let trash else { return false }
        return trash.confidence >= tuning.trashInferenceConfidence && trash.rect.distance(to: point) == 0
    }

    /// 被拖过的图标从桌面消失了：按图标桥给的线索下结论。
    /// - Parameter teaches: 图标桥确认进了废纸篓时，这次的松手点能不能拿去修正废纸篓的估算。
    private func settleRemoval(
        iconID: IconID, releasePoint: CGPoint, originImageRect: CGRect,
        verdict: TrashVerdict, releasedOverTrash: Bool, teaches: Bool,
        outcomes: inout [DragOutcome], deletions: inout [DeletionEvent], lessons: inout [CGPoint]
    ) {
        let trashed: Bool
        switch verdict {
        case .yes: trashed = true
        case .no: trashed = false
        // 查不出来：只有松手点确实在（足够可信的）废纸篓区域里才认定被删；拿不准就当它去了别处。
        case .unknown: trashed = releasedOverTrash
        }
        if trashed {
            outcomes.append(DragOutcome(iconID: iconID, kind: .trashed, releasePoint: releasePoint))
            // 幽灵从桌面上的原位置飘起，不是松手处（那里在程序坞上，会被挡住）。
            deletions.append(DeletionEvent(iconID: iconID, lastImageRect: originImageRect, wasDragged: true, trashed: verdict))
            // 只有图标桥确认过的才拿来学：用自己的估算去教自己没有意义。
            if teaches, verdict == .yes {
                lessons.append(releasePoint)
            }
        } else {
            outcomes.append(DragOutcome(iconID: iconID, kind: .leftDesktop, releasePoint: releasePoint))
        }
    }

    /// 一次已松手的拖拽能不能下结论了。收到消失事件的情形在别处处理，这里看松手之后读到的快照，以及超时。
    private func resolution(of pending: PendingRelease, snapshot: IconSnapshot, now: TimeInterval) -> Resolution {
        let drag = pending.drag
        // 只认松手之后才开始读的快照：更早的快照说明不了松手后的事。
        if snapshot.status.isUsable, snapshot.capturedAt >= drag.releasedAt {
            guard let icon = snapshot.icon(withID: drag.iconID) else { return .vanished }
            let origin = pending.originImageRect
            if abs(icon.imageRect.minX - origin.minX) > 0.5 || abs(icon.imageRect.minY - origin.minY) > 0.5 {
                return .settled(DragOutcome(
                    iconID: drag.iconID, kind: .moved, releasePoint: drag.releasePoint, newImageRect: icon.imageRect
                ))
            }
            // 还在原位：可能是弹回去了，也可能访达还没来得及更新。过了稳定期再读到原位才算取消。
            if snapshot.capturedAt >= drag.releasedAt + pending.settle {
                return .settled(DragOutcome(iconID: drag.iconID, kind: .cancelled, releasePoint: drag.releasePoint))
            }
        }
        if now - drag.releasedAt >= tuning.outcomeTimeout {
            return .settled(DragOutcome(iconID: drag.iconID, kind: .unknown, releasePoint: drag.releasePoint))
        }
        return .waiting
    }
}
