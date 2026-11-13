// IconBridge · 核心：一次"读取周期"里发生的全部事情
//
// `BridgeCore` 持有上一次的读数，每个周期向访达读一遍（或只做一次便宜的"数个数"检查），
// 比对出变化，查清消失的图标是否进了废纸篓，给出新的快照和要上报的 `IconUpdate`。
//
// 它是同步的、会阻塞的（向访达发请求），由 `BridgeEngine` 放在图标桥自己的后台队列上运行；
// 对访达的一切访问都经过 `DesktopQuerying`，所以单元测试可以用假的桌面驱动它，不碰真实桌面。

import CoreGraphics
import DDMCore
import Foundation

/// 一个读取周期的种类。
enum CycleKind: Equatable, Sendable {
    /// 快速检查：只问"桌面上有几个图标"。个数没变就到此为止；变了当场升级为完整读取。
    case quick
    /// 完整读取：位置 + 名字（必要时加上类、修改时间）+ 显示选项 + 废纸篓计数。
    case full
}

/// 交给核心的一次请求。
struct CycleRequest: Equatable, Sendable {
    var kind: CycleKind
    /// 由 `refreshNow()` 引发：必须做完整读取，而且即使没有变化也要上报一次。
    var forced = false
    /// 从"停止读取"恢复后的第一次读取：按整体重载处理。
    var resumed = false
    /// 重新 `start()`：先把核心恢复到初始状态。
    var restart = false
}

/// 一个周期的结果。
struct CycleOutcome: Equatable, Sendable {
    /// 周期结束时的快照（提供者把它存成自己的缓存）。
    var snapshot: IconSnapshot
    /// 需要上报的内容；不需要回调时为 nil。
    var update: IconUpdate?
    /// 这个周期是否做了完整读取。
    var performedFullRead: Bool
    /// 是否发现了图标的增减或移动。
    var foundChanges = false
    /// 读数前后不一致、放弃了这一轮（桌面正在连续变化）：应尽快重读。
    var wasInconsistent = false
    /// 是一次"常规"的完整读取：桌面没变，只发了最少的几个请求。节奏按它的耗时来定——
    /// 第一次读取、桌面有变化时的读取要多问好几轮，不能代表平时的开销。
    var wasRoutineRead = false
    /// 访达这一轮没空回答（等到超时也没有回复，典型情形是用户正拖着图标）：什么都没读到，
    /// 快照和状态原样保留，应尽快再等。
    var finderWasBusy = false
    /// 这个周期里，花在"等了很久才有回答、或干脆没等到回答"的请求上的时间（秒）。
    var stalledSeconds: TimeInterval = 0
    /// 周期开始的时刻与耗时（秒，单调时钟）。
    var startedAt: TimeInterval
    var duration: TimeInterval
    /// 向访达发了几次请求（诊断、基准测试用）。
    var requestCount: Int
}

struct BridgeCore: Sendable {
    /// 可调的行为参数。
    struct Tuning: Equatable, Sendable {
        /// 修改时间隔多久重读一次（秒）。
        var modificationDateInterval: TimeInterval = 60
        /// 消失的图标第一次查不出"进了废纸篓"时，等多久再查一次（秒）。
        var trashRecheckDelay: TimeInterval = 0.25
        /// 废纸篓计数的基准往回看多久（秒）：取这段时间内各次完整读取里最小的计数。
        var trashBaselineWindow: TimeInterval = 3
        /// 基准最老能有多老（秒）。更老的计数不能当基准：隔得越久，"变多了"越可能是别的东西进了废纸篓。
        var trashBaselineMaxAge: TimeInterval = 20
        /// 桌面一直在变时，一次读取最多重试几轮。
        var maxReadAttempts = 3
        /// 一个请求等了这么久（秒）才有回答，就算访达"卡过一阵"：
        /// 卡住期间桌面很可能变了（用户刚拖完图标），而且这段时间不计入废纸篓基准的"年龄"。
        var stallThreshold: TimeInterval = 1
        /// 图标很多的桌面，访达回答一次本来就慢：每多一个图标，"卡过一阵"的门槛放宽这么多秒
        /// （实测访达每个图标约花 1 毫秒，隔一阵才问时约 3 毫秒；放宽到 10 毫秒，免得把"图标多"误当成"卡住"）。
        var stallAllowancePerItem: TimeInterval = 0.01
        /// 废纸篓的问题等到超时、而访达别的问题照常回答（例如废纸篓里东西极多、或在一个连不上的卷上）之后，
        /// 这么久（秒）之内不再问废纸篓：消失的图标一律给"不确定"，免得每次读取都白等一回。
        var trashBackoff: TimeInterval = 120
        /// 访达连续这么久（秒）一个请求都不回答，才算"不可用"。
        ///
        /// 定成 5 分钟的理由：访达不回答最常见的原因是用户正拖着图标（或开着访达的菜单），这种状态持续几分钟的极少；
        /// 而访达不回答的时候它自己也动不了桌面上的图标，所以上一份快照多半仍然是对的——宁可多留一会儿，
        /// 也不要在用户拖着图标往废纸篓走的时候让所有的脸消失。真的坏了（进程没了、连接断了）会立刻得到明确的错误，不走这条路。
        var unresponsiveLimit: TimeInterval = 300
        var labelMetrics = LabelMetrics.standard
    }

    private let source: CountingSource
    private let identity: IconIdentity
    private let layoutProvider: @Sendable () -> DisplayLayout
    private let clock: @Sendable () -> TimeInterval
    private let sleep: @Sendable (TimeInterval) -> Void
    private let measureText: @Sendable (String, CGFloat) -> CGFloat
    private let tuning: Tuning

    // —— 上一次读到的东西 ——
    private(set) var snapshot: IconSnapshot = .empty()
    private var names: [String] = []
    private var classCodes: [FourCharCode] = []
    private var viewOptions = DesktopViewOptions()
    private var layout: DisplayLayout?
    private var modificationDates: [ItemKey: Date] = [:]
    private var modificationDatesReadAt: TimeInterval?
    /// 最近几次完整读取时废纸篓里的项目数（按时间先后）。
    private var trashSamples: [TrashSample] = []
    /// 下一次成功的读取要按"整体重载"上报：第一次读取、从停止读取恢复之后。
    private var pendingReset = true

    // —— 访达没空回答时 ——
    /// 访达从什么时候起一直没有回答（第一个超时的请求发出的时刻）；它回答了就清空。
    private var silentSince: TimeInterval?
    /// 累计"访达没在回答"的时间（秒）。废纸篓基准的年龄要扣掉它。
    private var silentTotal: TimeInterval = 0
    /// 上一个周期以"没等到回答"结束的时刻；到下一个周期开始之前的这段空档也算没在回答。
    private var silentGapStart: TimeInterval?
    /// 在这个时刻之前不问废纸篓（见 `Tuning.trashBackoff`）。
    private var trashUnreachableUntil: TimeInterval?

    init(
        source: any DesktopQuerying,
        identity: IconIdentity,
        layoutProvider: @escaping @Sendable () -> DisplayLayout = { DisplayLayout.current() },
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        measureText: @escaping @Sendable (String, CGFloat) -> CGFloat = { LabelTextMeasurer.width(of: $0, fontSize: $1) },
        tuning: Tuning = Tuning()
    ) {
        self.source = CountingSource(base: source, clock: clock, stallThreshold: tuning.stallThreshold)
        self.identity = identity
        self.layoutProvider = layoutProvider
        self.clock = clock
        self.sleep = sleep
        self.measureText = measureText
        self.tuning = tuning
    }

    // MARK: 一个周期

    mutating func run(_ request: CycleRequest) -> CycleOutcome {
        if request.restart {
            forgetEverything()
        }
        if request.resumed {
            pendingReset = true
            trashSamples = []   // 停止读取期间废纸篓里发生过什么不知道，之前的计数不能再当基准
            // 停止读取的那段时间不算"访达一直没回答"：重新计。
            silentSince = nil
            silentGapStart = nil
        }
        source.beginCycle(stallThreshold: max(tuning.stallThreshold, Double(names.count) * tuning.stallAllowancePerItem))
        let cycleStartedAt = clock()
        if let gapStart = silentGapStart {
            silentTotal += max(0, cycleStartedAt - gapStart)
            silentGapStart = nil
        }

        var outcome: CycleOutcome
        if silentSince != nil {
            outcome = waitForFinder(startedAt: cycleStartedAt, forced: request.forced)
        } else if request.kind == .quick, !request.forced {
            switch quickCheck() {
            case .unchanged:
                outcome = CycleOutcome(snapshot: snapshot, update: nil, performedFullRead: false, startedAt: cycleStartedAt, duration: 0, requestCount: 0)
            case .needsFullRead:
                // 完整读取从这一刻才开始：如果刚才那一问被访达卡了很久，"读取开始的时刻"不该算在卡住之前。
                outcome = fullRead(startedAt: source.stalledSeconds > 0 ? clock() : cycleStartedAt, forced: false)
            case .busy:
                outcome = busy(startedAt: cycleStartedAt, forced: false)
            }
        } else {
            outcome = fullRead(startedAt: cycleStartedAt, forced: request.forced)
        }

        silentTotal += source.stalledSeconds
        if outcome.finderWasBusy {
            silentGapStart = clock()
        }
        outcome.startedAt = cycleStartedAt
        outcome.duration = max(0, clock() - cycleStartedAt)
        outcome.requestCount = source.count
        outcome.stalledSeconds = source.stalledSeconds
        return outcome
    }

    private enum QuickCheckResult {
        case unchanged, needsFullRead, busy
    }

    /// 快速检查：只问"桌面上有几个图标"。
    private func quickCheck() -> QuickCheckResult {
        guard snapshot.status == .ok, !pendingReset else { return .needsFullRead }
        // 叠放的那一项设置读起来几乎不花时间，每次快速检查都看一眼：开了叠放要尽快停手。
        if source.stacksEnabled() == true { return .needsFullRead }
        // 显示器排列同理（不用问访达）：插拔显示器、改分辨率后要尽快重算每个图标在哪块屏上。
        if layoutProvider() != layout { return .needsFullRead }
        let count: Int
        do {
            count = try source.itemCount()
        } catch {
            // 等到超时也没有回答：访达没空。别的错误交给完整读取去定性。
            return error == .timeout ? .busy : .needsFullRead
        }
        // 这一问等了很久才有回答：访达刚才卡住了（多半是用户在拖图标，松手那一刻才回答）。
        // 这种时候桌面很可能变了——不管个数变没变，马上完整读一遍。
        if source.stalledSeconds > 0 { return .needsFullRead }
        return count == names.count ? .unchanged : .needsFullRead
    }

    // MARK: 访达没空回答

    /// 这一轮没等到访达的回答。快照和状态原样保留、不上报；连续太久都没有回答，才报"访达不可用"。
    private mutating func busy(startedAt: TimeInterval, forced: Bool) -> CycleOutcome {
        let since = silentSince ?? source.firstTimeoutSentAt ?? startedAt
        silentSince = since
        if clock() - since >= tuning.unresponsiveLimit, snapshot.status != .finderUnavailable {
            var outcome = fail(.finderUnavailable, startedAt: startedAt, forced: forced)
            outcome.finderWasBusy = true
            return outcome
        }
        var outcome = CycleOutcome(snapshot: snapshot, update: nil, performedFullRead: false, startedAt: startedAt, duration: 0, requestCount: 0)
        outcome.finderWasBusy = true
        return outcome
    }

    /// 上一轮没等到回答：这一轮先只发一个最便宜的请求（数个数）等访达。
    ///
    /// 访达忙完之后会把排着队的请求挨个处理掉，包括我们早已放弃等待的那些——所以等的时候只让最便宜的请求去排队，
    /// 免得松手之后访达先花上几百毫秒回答一堆没人要的问题。它一回答，马上完整读一遍。
    private mutating func waitForFinder(startedAt: TimeInterval, forced: Bool) -> CycleOutcome {
        do {
            _ = try source.itemCount()
        } catch {
            if error == .timeout {
                return busy(startedAt: startedAt, forced: forced)
            }
            silentSince = nil
            return fail(StatusMapping.status(for: error), startedAt: startedAt, forced: forced)
        }
        // 注意这里不清"从什么时候起没回答"：只有一次完整读取真的读完才算恢复。
        // 否则"数个数能答、别的问题一直超时"的情形下，5 分钟的界线会被一次次重新起算，永远到不了。
        return fullRead(startedAt: clock(), forced: forced)
    }

    private mutating func fullRead(startedAt: TimeInterval, forced: Bool) -> CycleOutcome {
        // 当前不是正常状态（刚启动、上次失败）时，先确认授权，免得一上来就卡在一个注定失败的请求上。
        if snapshot.status != .ok, let failure = checkAuthorization() {
            return fail(failure, startedAt: startedAt, forced: forced)
        }

        // 开了"叠放"时访达报告的位置对不上屏幕上的样子，读了也不能用——直接报告状态。
        // 先看访达的那一项桌面显示设置（办法 B）；它说"开了"就不必去读桌面了。
        let stacksBySetting = source.stacksEnabled()
        if stacksBySetting == true {
            return fail(.stacksEnabled, startedAt: startedAt, forced: forced)
        }

        let currentLayout = layoutProvider()
        var startedAt = startedAt
        var read: RawDesktopRead?
        var options = viewOptions
        var rereadAfterStall = false
        while true {
            let stalledBefore = source.stalledSeconds
            do {
                let datesAreStale = modificationDatesReadAt.map { startedAt - $0 >= tuning.modificationDateInterval } ?? true
                read = try ConsistentDesktopRead.read(
                    from: source,
                    previousNames: names,
                    previousClassCodes: classCodes,
                    wantsModificationDates: datesAreStale,
                    maxAttempts: tuning.maxReadAttempts
                )
                options = try source.viewOptions()
            } catch {
                if error == .timeout {
                    return busy(startedAt: startedAt, forced: forced)
                }
                silentSince = nil   // 访达明确地答复了一个错误：它不是"没空"
                return fail(StatusMapping.status(for: error), startedAt: startedAt, forced: forced)
            }
            // 读的过程中访达卡过一阵（多半是用户正好在这时拖了一下图标）：刚读到的东西可能一半是卡住之前的、一半是之后的。
            // 趁它现在有空，从头再读一遍；"读取开始的时刻"也从这时算起。只重读这一次。
            if source.stalledSeconds > stalledBefore, !rereadAfterStall {
                rereadAfterStall = true
                startedAt = clock()
                continue
            }
            break
        }

        guard let read else {
            // 桌面正在连续变化，这一轮拼不出一致的读数：保留旧快照、不上报，请提供者尽快重读
            // （由 refreshNow() 引发的读取，提供者会把"必须上报"带到重读的那一次）。
            var outcome = CycleOutcome(snapshot: snapshot, update: nil, performedFullRead: true, startedAt: startedAt, duration: 0, requestCount: 0)
            outcome.wasInconsistent = true
            return outcome
        }

        // 那一项设置无法判断时，用位置兜底（办法 A）：好几个图标的位置完全相同，就当作开了叠放。
        if stacksBySetting == nil, StacksHeuristic.looksStacked(positions: read.positions) {
            return fail(.stacksEnabled, startedAt: startedAt, forced: forced)
        }

        // —— 废纸篓里现在有几项（读不到不算读取失败：只是消失的图标会得到"不确定"）——
        var trashNow: Int?
        if trashIsReachable {
            do {
                trashNow = try source.trashItemCount()
            } catch {
                if error == .timeout {
                    switch probeAfterTrashTimeout() {
                    case .finderBusy:
                        return busy(startedAt: startedAt, forced: forced)
                    case let .finderFailed(failure):
                        silentSince = nil
                        return fail(StatusMapping.status(for: failure), startedAt: startedAt, forced: forced)
                    case .onlyTrashIsSlow:
                        break   // 已经记下"一阵子之内不问废纸篓"，照常往下走
                    }
                }
            }
        }

        // —— 把原始读数变成图标（这时还什么都不往自己身上记：后面查废纸篓时如果访达没空，这一轮要整个作废）——
        var dates = modificationDates
        if let fresh = read.modificationDates {
            dates = [:]
            for (index, date) in fresh.enumerated() {
                if let date {
                    dates[Self.key(name: read.names[index], classCode: read.classCodes[index])] = date
                }
            }
        }
        let icons = makeIcons(from: read, options: options, layout: currentLayout, dates: dates)

        // —— 判断是"整体重载"还是"逐个变化" ——
        let isReset = pendingReset
            || snapshot.status != .ok
            || options.appearance != snapshot.appearance
            || currentLayout != layout

        var changes: [IconChange] = []
        var foundChanges = false
        var latestTrashCount = trashNow
        if !isReset {
            let difference = SnapshotDiff.difference(from: snapshot.icons, to: icons)
            foundChanges = !difference.isEmpty
            if !difference.removed.isEmpty {
                // 消失的图标：趁旧名字还在手里，向访达查它们是不是进了废纸篓。
                switch trashVerdicts(for: difference.removed, countBefore: trashBaseline(), countAfter: trashNow) {
                case .finderBusy:
                    // 查到一半访达没空了：这一轮不算数（什么都不记），等它有空了重新比对、重新查。
                    return busy(startedAt: startedAt, forced: forced)
                case let .finderFailed(failure):
                    silentSince = nil
                    return fail(StatusMapping.status(for: failure), startedAt: startedAt, forced: forced)
                case let .decided(verdicts, latestCount):
                    latestTrashCount = latestCount
                    changes = SnapshotDiff.changes(for: difference) { verdicts[$0.id] ?? .unknown }
                }
            } else {
                changes = SnapshotDiff.changes(for: difference) { _ in .unknown }
            }
        }

        // —— 记住这一次的读数 ——
        // 版本号只在内容真的变了时加一；整体重载（例如从停止读取恢复）如果读到的和之前一模一样，版本号不变，但照样上报。
        let contentChanged = icons != snapshot.icons
            || options.appearance != snapshot.appearance
            || snapshot.status != .ok
        names = read.names
        classCodes = read.classCodes
        viewOptions = options
        layout = currentLayout
        if read.modificationDates != nil {
            modificationDates = dates
            modificationDatesReadAt = startedAt
        }
        recordTrashCount(latestTrashCount)
        pendingReset = false
        silentSince = nil
        snapshot = IconSnapshot(
            icons: icons,
            appearance: options.appearance,
            status: .ok,
            capturedAt: startedAt,
            revision: snapshot.revision + (contentChanged ? 1 : 0)
        )

        var outcome = CycleOutcome(snapshot: snapshot, update: nil, performedFullRead: true, startedAt: startedAt, duration: 0, requestCount: 0)
        outcome.foundChanges = foundChanges
        outcome.wasRoutineRead = read.wasRoutine && !isReset && !foundChanges
        if contentChanged || isReset || forced {
            outcome.update = IconUpdate(snapshot: snapshot, changes: changes, isReset: isReset)
        }
        return outcome
    }

    // MARK: 失败与状态

    /// 授权预检。返回 nil 表示可以去读；否则是应当报告的状态。
    private func checkAuthorization() -> IconProviderStatus? {
        var authorization = source.authorization(askUser: false)
        if authorization == .wouldPrompt {
            // 还没问过用户：这一问会弹出系统授权窗口，并阻塞到用户回答为止。
            // 这期间快照的状态保持"启动中"，应用什么都不画。
            authorization = source.authorization(askUser: true)
        }
        return StatusMapping.status(for: authorization)
    }

    /// 读取失败：快照清空（宁可不画，也不乱画），状态换成失败的原因。
    private mutating func fail(_ status: IconProviderStatus, startedAt: TimeInterval, forced: Bool) -> CycleOutcome {
        let statusChanged = status != snapshot.status
        let hadIcons = !snapshot.icons.isEmpty
        let contentChanged = statusChanged || hadIcons
        snapshot = IconSnapshot(
            icons: [],
            appearance: snapshot.appearance,
            status: status,
            capturedAt: startedAt,
            revision: snapshot.revision + (contentChanged ? 1 : 0)
        )
        // 之前的读数全部作废：恢复正常后的第一次读取是整体重载。
        names = []
        classCodes = []
        trashSamples = []
        pendingReset = true

        var update: IconUpdate?
        if contentChanged {
            update = IconUpdate(snapshot: snapshot, isReset: true)
        } else if forced {
            update = IconUpdate(snapshot: snapshot)
        }
        return CycleOutcome(snapshot: snapshot, update: update, performedFullRead: true, startedAt: startedAt, duration: 0, requestCount: 0)
    }

    /// 回到初始状态（重新 `start()` 时）。盐不变，所以编号不变；版本号接着往上数，
    /// 这样重新启动前后的两份快照不会碰巧带着同一个版本号。
    private mutating func forgetEverything() {
        snapshot = IconSnapshot(icons: [], status: .starting, capturedAt: 0, revision: snapshot.revision)
        names = []
        classCodes = []
        viewOptions = DesktopViewOptions()
        layout = nil
        modificationDates = [:]
        modificationDatesReadAt = nil
        trashSamples = []
        pendingReset = true
        silentSince = nil
        silentGapStart = nil
        trashUnreachableUntil = nil
    }

    // MARK: 图标

    private static func key(name: String, classCode: FourCharCode) -> ItemKey {
        ItemKey(name: name, isVolume: classCode == FinderCode.classDisk)
    }

    /// 按访达的顺序给每个项目定编号。同一个键第二次、第三次出现时（例如两个同名的磁盘）带上序号，各得一个编号。
    private func identities(names: [String], classCodes: [FourCharCode]) -> [(key: ItemKey, id: IconID)] {
        var seen: [ItemKey: Int] = [:]
        var result: [(key: ItemKey, id: IconID)] = []
        for index in names.indices where index < classCodes.count {
            let key = Self.key(name: names[index], classCode: classCodes[index])
            let occurrence = seen[key, default: 0]
            seen[key] = occurrence + 1
            result.append((key, identity.id(for: key, occurrence: occurrence)))
        }
        return result
    }

    private func makeIcons(from read: RawDesktopRead, options: DesktopViewOptions, layout: DisplayLayout, dates: [ItemKey: Date]) -> [DesktopIcon] {
        var icons: [DesktopIcon] = []
        icons.reserveCapacity(read.names.count)
        var seen = Set<IconID>()
        for (index, item) in identities(names: read.names, classCodes: read.classCodes).enumerated() {
            // 编号万一相撞（概率可以忽略），只留第一个，保证同一份快照里编号不重复。
            guard seen.insert(item.id).inserted else { continue }

            let imageRect = IconGeometry.imageRect(position: read.positions[index], iconSize: options.appearance.iconSize)
            let labelRect = IconGeometry.labelRect(
                textWidth: measureText(read.names[index], options.appearance.textSize),
                imageRect: imageRect,
                options: options,
                metrics: tuning.labelMetrics
            )
            icons.append(DesktopIcon(
                id: item.id,
                kind: ItemClassification.kind(forClassCode: read.classCodes[index]),
                imageRect: imageRect,
                labelRect: labelRect,
                displayID: IconGeometry.displayID(for: imageRect, in: layout),
                modifiedAt: dates[item.key]
            ))
        }
        // 按编号排序：顺序稳定，而且不泄露名字的字母顺序（访达给的列表是按名字排的）。
        return icons.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    // MARK: 废纸篓

    /// 某次完整读取时废纸篓里的项目数。
    private struct TrashSample: Sendable {
        /// 读到这个数的时刻——用的是"访达在回答的时间"（见 `responsiveTime`），不是墙上的时间。
        var at: TimeInterval
        var count: Int
    }

    /// "访达在回答的时间"：单调时钟扣掉访达没在回答的全部时间（包括本周期里已经卡掉的）。
    ///
    /// 废纸篓基准的年龄用它来量。用户拖着图标的那段时间访达不回答请求，我们读不了废纸篓；
    /// 但那段时间访达自己也忙着，不会有别的东西经它进废纸篓——所以拖了多久都不该让拖动之前读到的计数"过期"。
    /// 否则拖着图标犹豫二十几秒再扔进废纸篓，就给不出"进了废纸篓"了。
    private var responsiveTime: TimeInterval {
        clock() - silentTotal - source.stalledSeconds
    }

    /// 判断"废纸篓有没有变多"用的基准：最近 `trashBaselineWindow` 秒内各次完整读取里最小的计数，
    /// 外加这段时间之前最近的那一次（保证至少往回看了这么久）。
    ///
    /// 不直接用"上一次读取时的计数"，是因为访达可能先把文件登记进废纸篓、稍后才从桌面的列表里去掉；
    /// 如果这中间恰好有一次读取，它看到的计数已经加过一了，拿它当基准就会误判成"没进废纸篓"。
    private func trashBaseline() -> Int? {
        let now = responsiveTime
        let recent = trashSamples.filter { now - $0.at <= tuning.trashBaselineWindow }
        // 窗口之前最近的那一次也算，但不能太老。
        let lastBefore = trashSamples.last { now - $0.at > tuning.trashBaselineWindow && now - $0.at <= tuning.trashBaselineMaxAge }
        return (recent + (lastBefore.map { [$0] } ?? [])).map(\.count).min()
    }

    private mutating func recordTrashCount(_ count: Int?) {
        guard let count else {
            trashSamples = []
            return
        }
        let now = responsiveTime
        // 只留基准用得到的：窗口之内的，和窗口之前最近的一个。
        let lastBefore = trashSamples.last { now - $0.at > tuning.trashBaselineWindow }
        trashSamples = (lastBefore.map { [$0] } ?? []) + trashSamples.filter { now - $0.at <= tuning.trashBaselineWindow }
        trashSamples.append(TrashSample(at: now, count: count))
    }

    /// 现在能不能问废纸篓。
    private var trashIsReachable: Bool {
        trashUnreachableUntil.map { clock() >= $0 } ?? true
    }

    /// 废纸篓的一个问题等到超时之后，分清是哪种情况。
    private enum TrashTimeoutCause {
        /// 访达整个没空（用户在拖图标）：这一轮作废。
        case finderBusy
        /// 访达明确地出错了（例如进程没了）。
        case finderFailed(FinderError)
        /// 访达别的问题照常回答，只是废纸篓问不动。
        case onlyTrashIsSlow
    }

    /// 废纸篓的问题超时了：用最便宜的问题（数桌面上的个数）探一下访达。
    /// 它也不回答 → 访达整个没空；它照常回答 → 只是废纸篓问不动，记下"一阵子之内不问废纸篓"。
    private mutating func probeAfterTrashTimeout() -> TrashTimeoutCause {
        do {
            _ = try source.itemCount()
        } catch {
            return error == .timeout ? .finderBusy : .finderFailed(error)
        }
        trashUnreachableUntil = clock() + tuning.trashBackoff
        return .onlyTrashIsSlow
    }

    private enum TrashVerdictResult {
        /// 每个消失的图标的结论，以及查完之后最新的废纸篓计数。
        case decided([IconID: TrashVerdict], latestCount: Int?)
        case finderBusy
        case finderFailed(FinderError)
    }

    /// 为每个消失的图标查清"是不是进了废纸篓"。
    ///
    /// 任何一问等到超时就立刻停手（不再接着发别的问题去排队），先分清是访达整个没空还是只有废纸篓问不动。
    private mutating func trashVerdicts(for removed: [DesktopIcon], countBefore: Int?, countAfter: Int?) -> TrashVerdictResult {
        // 消失的图标只有编号；用上一次读到的名字把编号对回名字（名字不出本模块）。
        var keyByID: [IconID: ItemKey] = [:]
        for item in identities(names: names, classCodes: classCodes) {
            keyByID[item.id] = item.key
        }

        var verdicts: [IconID: TrashVerdict] = [:]
        var undecided: [(id: IconID, name: String)] = []
        var toAsk: [(id: IconID, name: String)] = []
        for icon in removed {
            guard let key = keyByID[icon.id] else { continue }
            if key.isVolume {
                verdicts[icon.id] = .no          // 磁盘从桌面消失是被推出了，进不了废纸篓
            } else {
                verdicts[icon.id] = .unknown     // 先记"不确定"，问到了再改
                toAsk.append((icon.id, key.name))
            }
        }
        guard trashIsReachable else {
            return .decided(verdicts, latestCount: countAfter)
        }

        /// 问一次"废纸篓里有没有它"。返回 nil 表示这一问失败了但可以接着往下（非超时的错误）。
        func ask(_ name: String) -> Result<Bool?, TrashAbort> {
            do {
                return .success(try source.trashContains(name: name))
            } catch {
                guard error == .timeout else { return .success(nil) }
                switch probeAfterTrashTimeout() {
                case .finderBusy: return .failure(.finderBusy)
                case let .finderFailed(failure): return .failure(.finderFailed(failure))
                case .onlyTrashIsSlow: return .failure(.trashGaveUp)
                }
            }
        }

        for (id, name) in toAsk {
            switch ask(name) {
            case let .success(found):
                let evidence = TrashEvidence(countBefore: countBefore, countAfter: countAfter, nameFound: found)
                verdicts[id] = TrashVerdictLogic.verdict(for: evidence)
                if TrashVerdictLogic.shouldRecheck(evidence) {
                    undecided.append((id, name))
                }
            case .failure(.finderBusy):
                return .finderBusy
            case let .failure(.finderFailed(failure)):
                return .finderFailed(failure)
            case .failure(.trashGaveUp):
                // 废纸篓问不动：没问到的都留着"不确定"，不再问了。
                return .decided(verdicts, latestCount: countAfter)
            }
        }

        // 第一次没查出"是"的：稍等片刻，一起再查一次（不管有几个，只等这一回）。
        var latestCount = countAfter
        if !undecided.isEmpty {
            sleep(tuning.trashRecheckDelay)
            do {
                latestCount = try source.trashItemCount()
            } catch {
                if error == .timeout {
                    switch probeAfterTrashTimeout() {
                    case .finderBusy: return .finderBusy
                    case let .finderFailed(failure): return .finderFailed(failure)
                    case .onlyTrashIsSlow: return .decided(verdicts, latestCount: countAfter)
                    }
                }
            }
            for (id, name) in undecided {
                switch ask(name) {
                case let .success(found):
                    let evidence = TrashEvidence(countBefore: countBefore, countAfter: latestCount, nameFound: found)
                    verdicts[id] = TrashVerdictLogic.verdict(for: evidence)
                case .failure(.finderBusy):
                    return .finderBusy
                case let .failure(.finderFailed(failure)):
                    return .finderFailed(failure)
                case .failure(.trashGaveUp):
                    return .decided(verdicts, latestCount: latestCount)
                }
            }
        }
        return .decided(verdicts, latestCount: latestCount)
    }

    /// 查废纸篓中途不得不停下的原因。
    private enum TrashAbort: Error {
        case finderBusy
        case finderFailed(FinderError)
        case trashGaveUp
    }
}

// MARK: - 请求的计数与计时

/// 给 `DesktopQuerying` 套一层，记下一个周期里向访达发了几次请求、有没有请求等了很久或干脆没等到回答。
/// 这些记录只在核心所在的那一个队列上读写（核心本身就是串行使用的），用一把锁只是为了让类型满足 Sendable 的检查。
private final class CountingSource: DesktopQuerying, @unchecked Sendable {
    private let base: any DesktopQuerying
    private let clock: @Sendable () -> TimeInterval
    private var stallThreshold: TimeInterval
    private let lock = NSLock()
    private var requests = 0
    private var stalled: TimeInterval = 0
    private var sawTimeout = false
    private var timeoutSentAt: TimeInterval?

    init(base: any DesktopQuerying, clock: @escaping @Sendable () -> TimeInterval, stallThreshold: TimeInterval) {
        self.base = base
        self.clock = clock
        self.stallThreshold = stallThreshold
    }

    /// 本周期发了几次请求。
    var count: Int { lock.withLock { requests } }
    /// 本周期里花在"等了很久才有回答、或没等到回答"的请求上的时间（秒）。
    var stalledSeconds: TimeInterval { lock.withLock { stalled } }
    /// 本周期里有没有请求等到超时也没有回答。
    var timedOut: Bool { lock.withLock { sawTimeout } }
    /// 本周期里第一个超时的请求是什么时候发出的。
    var firstTimeoutSentAt: TimeInterval? { lock.withLock { timeoutSentAt } }

    /// 新的一个周期开始。`stallThreshold`：这个周期里一个请求等多久算"卡过一阵"（随图标数放宽）。
    func beginCycle(stallThreshold: TimeInterval) {
        lock.withLock {
            self.stallThreshold = stallThreshold
            requests = 0
            stalled = 0
            sawTimeout = false
            timeoutSentAt = nil
        }
    }

    /// 发一个请求，并记下它等了多久。
    private func ask<Value>(_ body: () throws(FinderError) -> Value) throws(FinderError) -> Value {
        lock.withLock { requests += 1 }
        let sentAt = clock()
        do {
            let value = try body()
            note(sentAt: sentAt, timedOut: false)
            return value
        } catch {
            note(sentAt: sentAt, timedOut: error == .timeout)
            throw error
        }
    }

    private func note(sentAt: TimeInterval, timedOut: Bool) {
        let waited = max(0, clock() - sentAt)
        lock.withLock {
            if timedOut || waited >= stallThreshold {
                stalled += waited
            }
            if timedOut {
                sawTimeout = true
                if timeoutSentAt == nil { timeoutSentAt = sentAt }
            }
        }
    }

    func authorization(askUser: Bool) -> FinderAuthorization { base.authorization(askUser: askUser) }
    func itemCount() throws(FinderError) -> Int { try ask { () throws(FinderError) in try base.itemCount() } }
    func positions() throws(FinderError) -> [CGPoint] { try ask { () throws(FinderError) in try base.positions() } }
    func names() throws(FinderError) -> [String] { try ask { () throws(FinderError) in try base.names() } }
    func classCodes() throws(FinderError) -> [FourCharCode] { try ask { () throws(FinderError) in try base.classCodes() } }
    func modificationDates() throws(FinderError) -> [Date?] { try ask { () throws(FinderError) in try base.modificationDates() } }
    func viewOptions() throws(FinderError) -> DesktopViewOptions { try ask { () throws(FinderError) in try base.viewOptions() } }
    func trashItemCount() throws(FinderError) -> Int { try ask { () throws(FinderError) in try base.trashItemCount() } }
    func trashContains(name: String) throws(FinderError) -> Bool { try ask { () throws(FinderError) in try base.trashContains(name: name) } }
    func stacksEnabled() -> Bool? { base.stacksEnabled() }
}
