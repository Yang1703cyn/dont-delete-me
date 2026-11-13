// InputSense · 废纸篓定位：什么时候去打听程序坞、怎么记住学到的东西
//
// `TrashEstimator` 是纯公式；这个文件管"时机"和"记忆"：隔多久重读一次程序坞的设置、隔多久量一次那一条、
// 设置变了怎么办、学到的松手位置存在哪。对系统的访问都经过 `DockReading`，所以也能用假的程序坞做测试。

import CoreGraphics
import DDMCore
import Foundation

/// 向系统打听程序坞。真实实现是 `SystemDockReader`。全部只读、不需要授权。
///
/// 前三个属性只是取"最近一次读到的结果"，不触发读取；真正的读取比较慢，
/// 由 `requestRefresh()` 发起、在后台完成，读完后这几个属性自己更新。
@MainActor
protocol DockReading: AnyObject {
    /// 程序坞的设置和估出的项目数；还没读到为 nil。
    var settings: DockSettings? { get }
    /// 程序坞所在显示器的范围（全局坐标）；查不出来为 nil。
    var dockDisplayFrame: CGRect? { get }
    /// 主屏的范围；一块显示器都没有（或还没读到）为 nil。
    var primaryDisplayFrame: CGRect? { get }
    /// 请重读一遍上面这些。不阻塞。
    func requestRefresh()
    /// 量程序坞那一条此刻在屏上的范围；程序坞不在屏上（隐藏、在全屏空间、被挡住）为 nil。
    /// 这一个是当场量的（平时 4 次窗口查询，程序坞变了样时三十来次）。
    func measureBar(edge: DockEdge, displayFrame: CGRect) -> CGRect?
}

/// 存放学到的废纸篓位置。真实实现存在应用自己的偏好设置里。
@MainActor
protocol TrashMemoryStoring: AnyObject {
    func load() -> [TrashLesson]
    func save(_ lessons: [TrashLesson])
}

/// 只存在内存里：演示和测试用，退出就忘。
@MainActor
final class InMemoryTrashMemory: TrashMemoryStoring {
    private var lessons: [TrashLesson]

    init(_ lessons: [TrashLesson] = []) {
        self.lessons = lessons
    }

    func load() -> [TrashLesson] { lessons }
    func save(_ lessons: [TrashLesson]) { self.lessons = lessons }
}

/// 一小块"按键存取二进制数据"的存储。真实实现是偏好设置；测试用内存里的字典，不碰用户的偏好设置目录。
protocol LessonStorage: AnyObject {
    func lessonData(forKey key: String) -> Data?
    func setLessonData(_ data: Data, forKey key: String)
}

extension UserDefaults: LessonStorage {
    func lessonData(forKey key: String) -> Data? { data(forKey: key) }
    func setLessonData(_ data: Data, forKey key: String) { set(data, forKey: key) }
}

/// 把学到的废纸篓位置存进偏好设置（应用里就是应用自己的那一份）。内容只有几个数字：程序坞设置的指纹和松手点的偏差。
@MainActor
final class PersistentTrashMemory: TrashMemoryStoring {
    /// 偏好设置里的键名。
    static let key = "InputSense.trashLessons"

    private let storage: any LessonStorage

    init(storage: any LessonStorage = UserDefaults.standard) {
        self.storage = storage
    }

    func load() -> [TrashLesson] {
        guard let data = storage.lessonData(forKey: Self.key) else { return [] }
        // 读不懂（例如以后改了格式）就当没学过。
        return (try? JSONDecoder().decode([TrashLesson].self, from: data)) ?? []
    }

    func save(_ lessons: [TrashLesson]) {
        guard let data = try? JSONEncoder().encode(lessons) else { return }
        storage.setLessonData(data, forKey: Self.key)
    }
}

@MainActor
final class TrashLocator {
    struct Timing: Sendable, Equatable {
        /// 每隔这么久请求重读一次程序坞的设置（发现"设置变了""程序坞换屏了""多开了一个应用"）。
        var refreshInterval: TimeInterval = 3
        /// 鼠标有一阵没动时放慢到每隔这么久一次（重读要在后台花约 10 毫秒处理器时间）。
        var idleRefreshInterval: TimeInterval = 30
        /// 平时每隔这么久量一次程序坞那一条。
        var measureInterval: TimeInterval = 10
        /// 拖拽期间每隔这么久量一次（程序坞可能正在弹出、放大、换屏）。
        var draggingInterval: TimeInterval = 0.5
        /// 量到的范围最多沿用这么久（程序坞藏起来之后量不到新的）。
        var measurementLifetime: TimeInterval = 300
    }

    /// 一次测量在什么前提下量的。前提变了，这次测量就作废。
    private struct MeasurementKey: Equatable {
        var signature: DockSignature
        var tileCount: Double
        var displayFrame: CGRect
    }

    private let dock: any DockReading
    private let store: any TrashMemoryStoring
    private let timing: Timing

    private var lessons: [TrashLesson]
    private var refreshRequestedAt: TimeInterval?
    private var measurement: (bar: CGRect, key: MeasurementKey, at: TimeInterval)?
    private var measureTriedAt: TimeInterval?
    private var wasDragging = false
    private var cached: TrashEstimate?

    init(dock: any DockReading, store: any TrashMemoryStoring, timing: Timing = Timing()) {
        self.dock = dock
        self.store = store
        self.timing = timing
        self.lessons = store.load()
    }

    /// 这一刻对程序坞的了解；还没读过或没有显示器时为 nil。供演示和排查用。
    private(set) var observation: DockObservation?

    /// 学到了几条教训（所有设置下的总数）。
    var lessonCount: Int { lessons.count }

    /// 当前对废纸篓位置的估算。每帧都可以调：到点了才去量、去请求重读，其余时候只是比一比有没有变。
    /// - Parameter isIdle: 鼠标是否有一阵没动了（没人在操作时不必勤读程序坞的设置）。
    func estimate(at time: TimeInterval, isDragging: Bool, isIdle: Bool = false) -> TrashEstimate? {
        let startedDragging = isDragging && !wasDragging
        wasDragging = isDragging

        let refreshInterval = isIdle && !isDragging ? timing.idleRefreshInterval : timing.refreshInterval
        if refreshRequestedAt.map({ time - $0 >= refreshInterval }) ?? true {
            refreshRequestedAt = time
            dock.requestRefresh()
        }
        let knownFrame = dock.dockDisplayFrame
        guard let settings = dock.settings, let displayFrame = knownFrame ?? dock.primaryDisplayFrame else {
            observation = nil
            cached = nil
            return nil
        }
        // 不知道程序坞在哪块屏时只能假定主屏。
        var current = DockObservation(settings: settings, displayFrame: displayFrame, isDisplayKnown: knownFrame != nil)
        let key = MeasurementKey(signature: DockSignature(current), tileCount: settings.tileCount, displayFrame: displayFrame)

        // 量到的范围只在前提没变、也没过期时沿用。前提变了（设置、项目数、所在显示器）就作废，并且马上重新量，不等下一个整点。
        if let measured = measurement, measured.key != key || time - measured.at > timing.measurementLifetime {
            measurement = nil
            measureTriedAt = nil
        }
        // 刚开始拖也马上量一次：接下来这一段正是最需要准的时候。
        let measureInterval = isDragging ? timing.draggingInterval : timing.measureInterval
        if startedDragging || (measureTriedAt.map { time - $0 >= measureInterval } ?? true) {
            measureTriedAt = time
            if current.isDisplayKnown, let bar = dock.measureBar(edge: settings.edge, displayFrame: displayFrame) {
                measurement = (bar, key, time)
            }
        }
        current.measuredBar = measurement?.bar

        if current != observation || cached == nil {
            observation = current
            cached = TrashEstimator.estimate(observation: current, lessons: lessons)
        }
        return cached
    }

    /// 自学习：一次拖拽确实把图标送进了废纸篓，记下它的松手点。
    func learn(releasePoint: CGPoint) {
        guard let observation, let lesson = TrashEstimator.lesson(releasePoint: releasePoint, observation: observation) else { return }
        lessons = TrashEstimator.remember(lesson, in: lessons)
        store.save(lessons)
        cached = nil
    }
}
