// 测试用的假桌面：实现 `DesktopQuerying`，完全在内存里，不碰访达也不碰真实桌面。
//
// 和访达一样，列表按名字排序——所以改名会让项目换位，可以用来重现"两次请求之间桌面变了"的各种情形。
// 测试里出现的名字都是编造的。

import CoreGraphics
import DDMCore
import Foundation
@testable import IconBridge

final class FakeDesktop: DesktopQuerying, @unchecked Sendable {
    struct Item {
        var name: String
        var classCode: FourCharCode = FinderCode.classDocumentFile
        var position: CGPoint
        var modified: Date?
    }

    /// 所有可变状态都在这把锁里（提供者的测试会从后台队列访问它）。
    private let lock = NSLock()
    private var storedItems: [Item] = []
    private var storedTrash: [String] = []
    private var storedOptions = DesktopViewOptions()
    private var storedAuthorization = FinderAuthorization.granted
    private var storedAnswerWhenAsked: FinderAuthorization?
    private var storedError: FinderError?
    private var storedStacks: Bool?
    private var storedLog: [String] = []
    private var hooks: [(call: String, occurrence: Int, action: @Sendable (FakeDesktop) -> Void)] = []
    private var occurrences: [String: Int] = [:]
    private var storedDelay: TimeInterval = 0
    private var storedMainThreadCalls = 0
    private var storedEveryCall: (@Sendable (String) -> Void)?
    private var storedErrorsByCall: [String: FinderError] = [:]

    init(_ items: [Item] = []) {
        storedItems = items
    }

    // MARK: 摆布桌面

    var items: [Item] {
        get { lock.withLock { storedItems.sorted { $0.name < $1.name } } }
        set { lock.withLock { storedItems = newValue } }
    }

    func add(_ name: String, at position: CGPoint, classCode: FourCharCode = FinderCode.classDocumentFile, modified: Date? = nil) {
        lock.withLock { storedItems.append(Item(name: name, classCode: classCode, position: position, modified: modified)) }
    }

    func remove(_ name: String) {
        lock.withLock { storedItems.removeAll { $0.name == name } }
    }

    func move(_ name: String, to position: CGPoint) {
        lock.withLock {
            for index in storedItems.indices where storedItems[index].name == name {
                storedItems[index].position = position
            }
        }
    }

    func rename(_ name: String, to newName: String) {
        lock.withLock {
            for index in storedItems.indices where storedItems[index].name == name {
                storedItems[index].name = newName
            }
        }
    }

    /// 像访达那样把项目移进废纸篓。
    func moveToTrash(_ name: String) {
        lock.withLock {
            storedItems.removeAll { $0.name == name }
            storedTrash.append(name)
        }
    }

    var trash: [String] {
        get { lock.withLock { storedTrash } }
        set { lock.withLock { storedTrash = newValue } }
    }

    var options: DesktopViewOptions {
        get { lock.withLock { storedOptions } }
        set { lock.withLock { storedOptions = newValue } }
    }

    /// 不弹窗查询授权时的回答。
    var authorizationState: FinderAuthorization {
        get { lock.withLock { storedAuthorization } }
        set { lock.withLock { storedAuthorization = newValue } }
    }

    /// 弹窗询问之后用户的回答（只在 `authorizationState == .wouldPrompt` 时用到）。
    var answerWhenAsked: FinderAuthorization? {
        get { lock.withLock { storedAnswerWhenAsked } }
        set { lock.withLock { storedAnswerWhenAsked = newValue } }
    }

    /// 设了之后，所有查询都抛这个错。
    var error: FinderError? {
        get { lock.withLock { storedError } }
        set { lock.withLock { storedError = newValue } }
    }

    var stacks: Bool? {
        get { lock.withLock { storedStacks } }
        set { lock.withLock { storedStacks = newValue } }
    }

    /// 每个查询人为地慢一点（秒），用来模拟"读取正在进行"。
    var delay: TimeInterval {
        get { lock.withLock { storedDelay } }
        set { lock.withLock { storedDelay = newValue } }
    }

    /// 每个查询开始时都执行的动作（参数是查询的名字）。用来模拟"每个请求都要等很久"：在里面把假时钟往后拨。
    var everyCall: (@Sendable (String) -> Void)? {
        get { lock.withLock { storedEveryCall } }
        set { lock.withLock { storedEveryCall = newValue } }
    }

    /// 只让某一个查询出错（传 nil 恢复正常），别的查询照常回答。例如只有废纸篓问不动。
    func fail(_ call: String, with error: FinderError?) {
        lock.withLock { storedErrorsByCall[call] = error }
    }

    /// 模拟"访达没空回答"（例如用户正拖着图标）：从现在起每个请求都等满 `timeout` 秒，然后超时。
    func stopAnswering(clock: Fixture.Clock, timeout: TimeInterval = 15) {
        error = .timeout
        everyCall = { _ in clock.advance(timeout) }
    }

    /// 访达又开始回答了。
    func resumeAnswering() {
        error = nil
        everyCall = nil
    }

    /// 有多少次查询是在主线程上发生的（应当永远是 0）。
    var mainThreadCalls: Int { lock.withLock { storedMainThreadCalls } }

    /// 按顺序记下被问过的问题。
    var log: [String] { lock.withLock { storedLog } }
    func clearLog() { lock.withLock { storedLog = [] } }

    /// 在某个查询第 `occurrence` 次被问到之前先执行一个动作——模拟"两次请求之间桌面变了"。
    func before(_ call: String, occurrence: Int = 1, _ action: @escaping @Sendable (FakeDesktop) -> Void) {
        lock.withLock { hooks.append((call, (occurrences[call] ?? 0) + occurrence, action)) }
    }

    /// 一道闸门：让某个查询停在半路，直到测试放行。用来**确定地**制造"读取正在进行"，不靠掐时间。
    final class Gate: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var reached = false

        /// 查询是否已经走到闸门前（也就是读取确实正在进行）。
        var isReached: Bool { lock.withLock { reached } }

        /// 放行。
        func open() { semaphore.signal() }

        fileprivate func wait() {
            lock.withLock { reached = true }
            semaphore.wait()
        }
    }

    /// 在某个查询第 `occurrence` 次被问到时把它拦住，返回闸门。
    func hold(_ call: String, occurrence: Int = 1) -> Gate {
        let gate = Gate()
        before(call, occurrence: occurrence) { _ in gate.wait() }
        return gate
    }

    // MARK: DesktopQuerying

    /// 记下这次查询，取出到期的钩子。
    private func arrive(_ call: String) -> [@Sendable (FakeDesktop) -> Void] {
        lock.withLock {
            storedLog.append(call)
            if Thread.isMainThread { storedMainThreadCalls += 1 }
            let count = (occurrences[call] ?? 0) + 1
            occurrences[call] = count
            let due = hooks.filter { $0.call == call && $0.occurrence == count }.map(\.action)
            hooks.removeAll { $0.call == call && $0.occurrence == count }
            return due
        }
    }

    private func enter(_ call: String) throws(FinderError) {
        for action in arrive(call) { action(self) }
        everyCall?(call)
        let (error, delay) = lock.withLock { (storedErrorsByCall[call] ?? storedError, storedDelay) }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if let error { throw error }
    }

    func authorization(askUser: Bool) -> FinderAuthorization {
        for action in arrive(askUser ? "authorization(ask)" : "authorization") { action(self) }
        return lock.withLock {
            if askUser, storedAuthorization == .wouldPrompt, let answer = storedAnswerWhenAsked {
                storedAuthorization = answer
            }
            return storedAuthorization
        }
    }

    func itemCount() throws(FinderError) -> Int {
        try enter("count")
        return items.count
    }

    func positions() throws(FinderError) -> [CGPoint] {
        try enter("positions")
        return items.map(\.position)
    }

    func names() throws(FinderError) -> [String] {
        try enter("names")
        return items.map(\.name)
    }

    func classCodes() throws(FinderError) -> [FourCharCode] {
        try enter("classes")
        return items.map(\.classCode)
    }

    func modificationDates() throws(FinderError) -> [Date?] {
        try enter("dates")
        return items.map(\.modified)
    }

    func viewOptions() throws(FinderError) -> DesktopViewOptions {
        try enter("options")
        return options
    }

    func trashItemCount() throws(FinderError) -> Int {
        try enter("trashCount")
        return trash.count
    }

    func trashContains(name: String) throws(FinderError) -> Bool {
        try enter("trashContains")
        return trash.contains(name)
    }

    func stacksEnabled() -> Bool? {
        stacks
    }
}

// MARK: - 测试里常用的东西

enum Fixture {
    /// 两块屏：主屏 1512×982 @2x；左侧外接屏 1920×1080 @1x，顶端比主屏高 58 点（和开发机的实际排列一样）。
    static let mainDisplay = DisplayInfo(id: DisplayID(rawValue: 1), frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
    static let externalDisplay = DisplayInfo(id: DisplayID(rawValue: 3), frame: CGRect(x: -1920, y: -58, width: 1920, height: 1080), scale: 1)
    static let layout = DisplayLayout(displays: [mainDisplay, externalDisplay])

    static let salt = Data(repeating: 7, count: 32)

    /// 一个可以手动拨动的时钟。
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval
        init(_ start: TimeInterval = 1000) { value = start }
        var now: TimeInterval { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    }

    /// 可以随时换掉布局的"显示器布局来源"。
    final class Layouts: @unchecked Sendable {
        private let lock = NSLock()
        private var value: DisplayLayout
        init(_ layout: DisplayLayout = Fixture.layout) { value = layout }
        var current: DisplayLayout {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    /// 用假桌面造一个核心。文字宽度固定为"每个字符 7 点"，时钟由测试掌握，等待不真的等。
    static func core(_ desktop: FakeDesktop, clock: Clock = Clock(), layouts: Layouts = Layouts(), tuning: BridgeCore.Tuning = BridgeCore.Tuning()) -> BridgeCore {
        BridgeCore(
            source: desktop,
            identity: IconIdentity(salt: salt),
            layoutProvider: { layouts.current },
            clock: { clock.now },
            sleep: { _ in },
            measureText: { text, _ in CGFloat(text.count) * 7 },
            tuning: tuning
        )
    }

    static func id(_ name: String, isVolume: Bool = false) -> IconID {
        IconIdentity(salt: salt).id(for: ItemKey(name: name, isVolume: isVolume))
    }
}
