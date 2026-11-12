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

    init(
        source: any DesktopQuerying,
        identity: IconIdentity,
        layoutProvider: @escaping @Sendable () -> DisplayLayout = { DisplayLayout.current() },
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        measureText: @escaping @Sendable (String, CGFloat) -> CGFloat = { LabelTextMeasurer.width(of: $0, fontSize: $1) },
        tuning: Tuning = Tuning()
    ) {
        self.source = CountingSource(base: source)
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
        }
        source.resetCount()
        let startedAt = clock()

        var outcome: CycleOutcome
        if request.kind == .quick, !request.forced, quickCheckSaysUnchanged() {
            outcome = CycleOutcome(snapshot: snapshot, update: nil, performedFullRead: false, startedAt: startedAt, duration: 0, requestCount: 0)
        } else {
            outcome = fullRead(startedAt: startedAt, forced: request.forced)
        }
        outcome.duration = max(0, clock() - startedAt)
        outcome.requestCount = source.count
        return outcome
    }

    /// 快速检查：状态正常，而且图标个数和上次一样。问不出来（访达出错）也算"变了"，交给完整读取去定性。
    private func quickCheckSaysUnchanged() -> Bool {
        guard snapshot.status == .ok, !pendingReset else { return false }
        // 叠放的那一项设置读起来几乎不花时间，每次快速检查都看一眼：开了叠放要尽快停手。
        if source.stacksEnabled() == true { return false }
        // 显示器排列同理（不用问访达）：插拔显示器、改分辨率后要尽快重算每个图标在哪块屏上。
        if layoutProvider() != layout { return false }
        guard let count = try? source.itemCount() else { return false }
        return count == names.count
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
        let read: RawDesktopRead?
        let options: DesktopViewOptions
        let trashNow: Int?
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
            // 废纸篓计数读不到不算读取失败：只是消失的图标会得到"不确定"。
            trashNow = try? source.trashItemCount()
        } catch {
            return fail(StatusMapping.status(for: error), startedAt: startedAt, forced: forced)
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

        // —— 把原始读数变成图标 ——
        if let dates = read.modificationDates {
            modificationDates = [:]
            for (index, date) in dates.enumerated() {
                if let date {
                    modificationDates[Self.key(name: read.names[index], classCode: read.classCodes[index])] = date
                }
            }
            modificationDatesReadAt = startedAt
        }
        let icons = makeIcons(from: read, options: options, layout: currentLayout)

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
                let result = trashVerdicts(for: difference.removed, countBefore: trashBaseline(at: startedAt), countAfter: trashNow)
                latestTrashCount = result.latestCount
                changes = SnapshotDiff.changes(for: difference) { result.verdicts[$0.id] ?? .unknown }
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
        recordTrashCount(latestTrashCount, at: startedAt)
        pendingReset = false
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

    private func makeIcons(from read: RawDesktopRead, options: DesktopViewOptions, layout: DisplayLayout) -> [DesktopIcon] {
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
                modifiedAt: modificationDates[item.key]
            ))
        }
        // 按编号排序：顺序稳定，而且不泄露名字的字母顺序（访达给的列表是按名字排的）。
        return icons.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    // MARK: 废纸篓

    /// 某次完整读取时废纸篓里的项目数。
    private struct TrashSample: Sendable {
        var at: TimeInterval
        var count: Int
    }

    /// 判断"废纸篓有没有变多"用的基准：最近 `trashBaselineWindow` 秒内各次完整读取里最小的计数，
    /// 外加这段时间之前最近的那一次（保证至少往回看了这么久）。
    ///
    /// 不直接用"上一次读取时的计数"，是因为访达可能先把文件登记进废纸篓、稍后才从桌面的列表里去掉；
    /// 如果这中间恰好有一次读取，它看到的计数已经加过一了，拿它当基准就会误判成"没进废纸篓"。
    private func trashBaseline(at now: TimeInterval) -> Int? {
        let recent = trashSamples.filter { now - $0.at <= tuning.trashBaselineWindow }
        // 窗口之前最近的那一次也算，但不能太老。
        let lastBefore = trashSamples.last { now - $0.at > tuning.trashBaselineWindow && now - $0.at <= tuning.trashBaselineMaxAge }
        return (recent + (lastBefore.map { [$0] } ?? [])).map(\.count).min()
    }

    private mutating func recordTrashCount(_ count: Int?, at time: TimeInterval) {
        guard let count else {
            trashSamples = []
            return
        }
        // 只留基准用得到的：窗口之内的，和窗口之前最近的一个。
        let lastBefore = trashSamples.last { time - $0.at > tuning.trashBaselineWindow }
        trashSamples = (lastBefore.map { [$0] } ?? []) + trashSamples.filter { time - $0.at <= tuning.trashBaselineWindow }
        trashSamples.append(TrashSample(at: time, count: count))
    }

    /// 为每个消失的图标查清"是不是进了废纸篓"。同时返回查完之后最新的废纸篓计数。
    private func trashVerdicts(
        for removed: [DesktopIcon], countBefore: Int?, countAfter: Int?
    ) -> (verdicts: [IconID: TrashVerdict], latestCount: Int?) {
        // 消失的图标只有编号；用上一次读到的名字把编号对回名字（名字不出本模块）。
        var keyByID: [IconID: ItemKey] = [:]
        for item in identities(names: names, classCodes: classCodes) {
            keyByID[item.id] = item.key
        }

        var verdicts: [IconID: TrashVerdict] = [:]
        var undecided: [(id: IconID, name: String)] = []
        for icon in removed {
            guard let key = keyByID[icon.id] else { continue }
            if key.isVolume {
                // 磁盘从桌面消失是被推出了，进不了废纸篓。
                verdicts[icon.id] = .no
                continue
            }
            let evidence = TrashEvidence(countBefore: countBefore, countAfter: countAfter, nameFound: try? source.trashContains(name: key.name))
            verdicts[icon.id] = TrashVerdictLogic.verdict(for: evidence)
            if TrashVerdictLogic.shouldRecheck(evidence) {
                undecided.append((icon.id, key.name))
            }
        }

        // 第一次没查出"是"的：稍等片刻，一起再查一次（不管有几个，只等这一回）。
        var latestCount = countAfter
        if !undecided.isEmpty {
            sleep(tuning.trashRecheckDelay)
            latestCount = (try? source.trashItemCount()) ?? countAfter
            for (id, name) in undecided {
                let evidence = TrashEvidence(countBefore: countBefore, countAfter: latestCount, nameFound: try? source.trashContains(name: name))
                verdicts[id] = TrashVerdictLogic.verdict(for: evidence)
            }
        }
        return (verdicts, latestCount)
    }
}

// MARK: - 请求计数

/// 给 `DesktopQuerying` 套一层，数一数一个周期里向访达发了几次请求。
/// 计数只在核心所在的那一个队列上读写（核心本身就是串行使用的），用一把锁只是为了让类型满足 Sendable 的检查。
private final class CountingSource: DesktopQuerying, @unchecked Sendable {
    private let base: any DesktopQuerying
    private let lock = NSLock()
    private var requests = 0

    init(base: any DesktopQuerying) {
        self.base = base
    }

    var count: Int { lock.withLock { requests } }
    func resetCount() { lock.withLock { requests = 0 } }
    private func tick() { lock.withLock { requests += 1 } }

    func authorization(askUser: Bool) -> FinderAuthorization { base.authorization(askUser: askUser) }
    func itemCount() throws(FinderError) -> Int { tick(); return try base.itemCount() }
    func positions() throws(FinderError) -> [CGPoint] { tick(); return try base.positions() }
    func names() throws(FinderError) -> [String] { tick(); return try base.names() }
    func classCodes() throws(FinderError) -> [FourCharCode] { tick(); return try base.classCodes() }
    func modificationDates() throws(FinderError) -> [Date?] { tick(); return try base.modificationDates() }
    func viewOptions() throws(FinderError) -> DesktopViewOptions { tick(); return try base.viewOptions() }
    func trashItemCount() throws(FinderError) -> Int { tick(); return try base.trashItemCount() }
    func trashContains(name: String) throws(FinderError) -> Bool { tick(); return try base.trashContains(name: name) }
    func stacksEnabled() -> Bool? { base.stacksEnabled() }
}
