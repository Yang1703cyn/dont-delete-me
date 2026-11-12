// IconBridge · "向访达问桌面"的接口，以及它的真实实现
//
// `DesktopQuerying` 把图标桥需要问访达的每一个问题列成一个方法。
// 真实实现 `FinderDesktopSource` 每个方法发一个 Apple 事件；单元测试用假的实现代替它，不碰真实桌面。

import CoreGraphics
import DDMCore
import Foundation

/// 访达桌面的显示选项（"查看显示选项"里和图标矩形有关的几项）。
struct DesktopViewOptions: Equatable, Sendable {
    /// 对外公开的三项：图标大小、文字大小、标签位置。
    var appearance: DesktopAppearance
    /// 是否"显示项目简介"：打开后标签下面多一行小字，可点击区域也跟着变高。
    var showsItemInfo: Bool

    init(appearance: DesktopAppearance = .finderDefault, showsItemInfo: Bool = false) {
        self.appearance = appearance
        self.showsItemInfo = showsItemInfo
    }
}

/// 图标桥向访达提的全部问题。所有方法都是同步、会阻塞的，只在图标桥的后台队列上调用。
///
/// 以"every item of desktop"开头的四个方法各自返回一个列表，下标一一对应同一个项目；
/// 但它们是四次独立的请求，中间桌面可能变化——怎样把它们拼成一份前后一致的读数，见 `ConsistentDesktopRead`。
protocol DesktopQuerying: Sendable {
    /// 是否获准控制访达。`askUser` 为 true 时可能弹出系统授权窗口并阻塞到用户回答。
    func authorization(askUser: Bool) -> FinderAuthorization

    /// 桌面上有几个图标（最便宜的一问，用来快速发现增减）。
    func itemCount() throws(FinderError) -> Int
    /// 每个图标的 desktop position（全局坐标，点）。
    func positions() throws(FinderError) -> [CGPoint]
    /// 每个图标的名字。只在本模块内部用来区分图标，绝不外传。
    func names() throws(FinderError) -> [String]
    /// 每个图标的类（文件、文件夹、应用、磁盘……的四字符代码）。
    func classCodes() throws(FinderError) -> [FourCharCode]
    /// 每个图标的最近修改时间；个别读不到的为 nil。
    func modificationDates() throws(FinderError) -> [Date?]

    /// 桌面的显示选项。
    func viewOptions() throws(FinderError) -> DesktopViewOptions

    /// 废纸篓里有几个项目。
    func trashItemCount() throws(FinderError) -> Int
    /// 废纸篓里有没有叫这个名字的项目。
    func trashContains(name: String) throws(FinderError) -> Bool

    /// 桌面是否开启了"叠放"——由访达的一项桌面显示设置判断（不向访达发请求，很快）。
    /// nil 表示无法判断，图标桥随后会用"多个图标位置完全相同"的办法兜底。见 StacksProbe.swift。
    func stacksEnabled() -> Bool?
}

/// 真实实现：每个方法向访达发一个 Apple 事件。
struct FinderDesktopSource: DesktopQuerying {
    var connection = FinderConnection()
    var stacksProbe: any StacksProbing = FinderPreferenceStacksProbe()

    private var desktop: NSAppleEventDescriptor { FinderConnection.property(FinderCode.desktop) }
    private var trash: NSAppleEventDescriptor { FinderConnection.property(FinderCode.trash) }
    private var everyItem: NSAppleEventDescriptor { FinderConnection.every(FinderCode.item, of: desktop) }

    func authorization(askUser: Bool) -> FinderAuthorization {
        connection.authorization(askUser: askUser)
    }

    func itemCount() throws(FinderError) -> Int {
        try connection.count(FinderCode.item, in: desktop)
    }

    func positions() throws(FinderError) -> [CGPoint] {
        let reply = try connection.get(FinderConnection.property(FinderCode.desktopPosition, of: everyItem))
        // `listElements` 已经兼容"只有一个图标时回复就是一个点"的情况。
        var points: [CGPoint] = []
        for element in reply.listElements {
            guard let point = element.pointValue else { throw FinderError.malformedReply }
            points.append(point)
        }
        return points
    }

    func names() throws(FinderError) -> [String] {
        let reply = try connection.get(FinderConnection.property(FinderCode.name, of: everyItem))
        var names: [String] = []
        for element in reply.listElements {
            guard let name = element.stringValue else { throw FinderError.malformedReply }
            names.append(name)
        }
        return names
    }

    func classCodes() throws(FinderError) -> [FourCharCode] {
        let reply = try connection.get(FinderConnection.property(FinderCode.itemClass, of: everyItem))
        return reply.listElements.map(\.typeCodeValue)
    }

    func modificationDates() throws(FinderError) -> [Date?] {
        let reply = try connection.get(FinderConnection.property(FinderCode.modificationDate, of: everyItem))
        return reply.listElements.map(\.dateValue)
    }

    func viewOptions() throws(FinderError) -> DesktopViewOptions {
        // icon view options of container window of desktop —— 一次把整组选项取回来。
        let window = FinderConnection.property(FinderCode.containerWindow, of: desktop)
        let options = FinderConnection.property(FinderCode.iconViewOptions, of: window)
        let record = try connection.get(FinderConnection.property(FinderCode.allProperties, of: options))
        guard let iconSize = record.forKeyword(FinderCode.iconSize)?.int32Value, iconSize > 0,
              let textSize = record.forKeyword(FinderCode.textSize)?.int32Value, textSize > 0
        else {
            throw FinderError.malformedReply
        }
        let labelOnRight = record.forKeyword(FinderCode.labelPosition)?.enumCodeValue == FinderCode.labelOnRight
        return DesktopViewOptions(
            appearance: DesktopAppearance(
                iconSize: CGFloat(iconSize),
                textSize: CGFloat(textSize),
                labelPosition: labelOnRight ? .right : .bottom
            ),
            showsItemInfo: record.forKeyword(FinderCode.showsItemInfo)?.booleanValue ?? false
        )
    }

    func trashItemCount() throws(FinderError) -> Int {
        try connection.count(FinderCode.item, in: trash)
    }

    func trashContains(name: String) throws(FinderError) -> Bool {
        try connection.exists(FinderConnection.item(named: name, in: trash))
    }

    func stacksEnabled() -> Bool? {
        stacksProbe.stacksEnabled()
    }
}
