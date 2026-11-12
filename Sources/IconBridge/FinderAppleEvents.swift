// IconBridge · 向访达发 Apple 事件的最底层
//
// 在本进程内直接构造并发送 Apple 事件（不启动 osascript，也不编译 AppleScript）。
// 这里的一切都是同步、会阻塞的调用，只能在图标桥自己的后台队列上使用，绝不能在主线程调用。
//
// 本文件只有"读"用得到的事件：取属性（get）、数个数（count）、问存不存在（exists）。
// 图标桥不向访达发任何会改动东西的事件。

import CoreServices
import Foundation

/// 把四个字符拼成四字符代码，例如 `fourCharCode("dpos")`。
func fourCharCode(_ string: String) -> FourCharCode {
    var result: FourCharCode = 0
    for byte in string.utf8.prefix(4) {
        result = (result << 8) | FourCharCode(byte)
    }
    return result
}

/// 访达脚本字典里用到的代码（取自访达自带的字典 Finder.sdef）。
enum FinderCode {
    // 事件
    static let coreSuite = fourCharCode("core")
    static let getData = fourCharCode("getd")
    static let countElements = fourCharCode("cnte")
    static let doesExist = fourCharCode("doex")

    // 事件参数、对象说明符的字段
    static let directObject = fourCharCode("----")
    static let errorNumber = fourCharCode("errn")
    static let objectClass = fourCharCode("kocl")
    static let desiredClass = fourCharCode("want")
    static let container = fourCharCode("from")
    static let keyForm = fourCharCode("form")
    static let keyData = fourCharCode("seld")
    static let formProperty = fourCharCode("prop")
    static let formIndex = fourCharCode("indx")
    static let formName = fourCharCode("name")
    static let absoluteOrdinal = fourCharCode("abso")
    static let ordinalAll = fourCharCode("all ")

    // 对象
    static let desktop = fourCharCode("desk")
    static let trash = fourCharCode("trsh")
    static let item = fourCharCode("cobj")
    static let containerWindow = fourCharCode("cwnd")
    static let iconViewOptions = fourCharCode("icop")

    // 属性
    static let name = fourCharCode("pnam")
    static let desktopPosition = fourCharCode("dpos")
    static let itemClass = fourCharCode("pcls")
    static let modificationDate = fourCharCode("asmo")
    static let allProperties = fourCharCode("pALL")
    static let iconSize = fourCharCode("lvis")
    static let textSize = fourCharCode("fsiz")
    static let labelPosition = fourCharCode("lpos")
    static let showsItemInfo = fourCharCode("mnfo")
    static let labelOnRight = fourCharCode("lrgt")

    // 返回值的数据类型
    static let list = fourCharCode("list")
    static let quickDrawPoint = fourCharCode("QDpt")

    // 项目的类
    static let classFolder = fourCharCode("cfol")
    static let classApplicationFile = fourCharCode("appf")
    static let classDisk = fourCharCode("cdis")
    static let classDocumentFile = fourCharCode("docf")
    static let classAliasFile = fourCharCode("alia")
    static let classInternetLocation = fourCharCode("inlf")
    static let classClipping = fourCharCode("clpf")
    static let classPackage = fourCharCode("pack")
    static let classFile = fourCharCode("file")
}

/// 向访达发请求失败。`code` 是系统的错误码（OSStatus）。
struct FinderError: Error, Equatable, Sendable {
    var code: Int

    /// 用户拒绝了"控制访达"。
    static let notPermitted = FinderError(code: -1743)
    /// 还没问过用户，而这次请求不允许弹窗。
    static let wouldRequireConsent = FinderError(code: -1744)
    /// 访达没在运行。
    static let processNotFound = FinderError(code: -600)
    /// 和访达的连接断了（多半是它正在退出或重启）。
    static let connectionInvalid = FinderError(code: -609)
    /// 等访达回复超时。
    static let timeout = FinderError(code: -1712)
    /// 访达说没有这个对象。
    static let noSuchObject = FinderError(code: -1728)
    /// 访达的回复不是预期的格式。
    static let malformedReply = FinderError(code: -1700)
}

/// 本应用是否获准控制访达。
enum FinderAuthorization: Equatable, Sendable {
    /// 已获准。
    case granted
    /// 用户拒绝了。
    case denied
    /// 还没问过用户；发请求会弹出系统的授权窗口。
    case wouldPrompt
    /// 访达没在运行，问不出来。
    case finderNotRunning
    /// 系统给了别的答复（错误码）。当作"不知道"，照常去读，由读取结果说了算。
    case undetermined(Int)

    init(status: Int) {
        switch status {
        case 0: self = .granted
        case FinderError.notPermitted.code: self = .denied
        case FinderError.wouldRequireConsent.code: self = .wouldPrompt
        case FinderError.processNotFound.code: self = .finderNotRunning
        default: self = .undetermined(status)
        }
    }
}

/// 和访达的"连接"：负责构造对象说明符、发送事件、取回结果。无状态，可随意复制。
struct FinderConnection: Sendable {
    static let bundleIdentifier = "com.apple.finder"

    /// 等待访达回复的最长时间（秒）。正常一次请求只要十几毫秒；访达忙（例如正在删除、拷贝）时会排队。
    var timeout: TimeInterval = 5

    // MARK: 对象说明符

    /// 应用本身（说明符链的起点）。
    static var application: NSAppleEventDescriptor { NSAppleEventDescriptor.null() }

    /// `container` 的某个属性。
    static func property(_ code: FourCharCode, of container: NSAppleEventDescriptor = application) -> NSAppleEventDescriptor {
        specifier(
            desiredClass: FinderCode.formProperty,
            container: container,
            keyForm: FinderCode.formProperty,
            keyData: NSAppleEventDescriptor(typeCode: code)
        )
    }

    /// `container` 里某一类的全部元素（every … of …）。
    static func every(_ classCode: FourCharCode, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        var all = FinderCode.ordinalAll
        let ordinal = NSAppleEventDescriptor(descriptorType: FinderCode.absoluteOrdinal, bytes: &all, length: MemoryLayout<FourCharCode>.size)
        return specifier(
            desiredClass: classCode,
            container: container,
            keyForm: FinderCode.formIndex,
            keyData: ordinal ?? NSAppleEventDescriptor.null()
        )
    }

    /// `container` 里叫这个名字的项目。
    static func item(named name: String, in container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        specifier(
            desiredClass: FinderCode.item,
            container: container,
            keyForm: FinderCode.formName,
            keyData: NSAppleEventDescriptor(string: name)
        )
    }

    private static func specifier(
        desiredClass: FourCharCode,
        container: NSAppleEventDescriptor,
        keyForm: FourCharCode,
        keyData: NSAppleEventDescriptor
    ) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: desiredClass), forKeyword: FinderCode.desiredClass)
        record.setDescriptor(container, forKeyword: FinderCode.container)
        record.setDescriptor(NSAppleEventDescriptor(enumCode: keyForm), forKeyword: FinderCode.keyForm)
        record.setDescriptor(keyData, forKeyword: FinderCode.keyData)
        return record.coerce(toDescriptorType: typeObjectSpecifier) ?? record
    }

    // MARK: 发送

    /// 取值：`get <specifier>`。
    func get(_ specifier: NSAppleEventDescriptor) throws(FinderError) -> NSAppleEventDescriptor {
        guard let result = try send(eventID: FinderCode.getData, direct: specifier) else {
            throw FinderError.malformedReply
        }
        return result
    }

    /// 数个数：`count every <classCode> of <container>`。
    func count(_ classCode: FourCharCode, in container: NSAppleEventDescriptor) throws(FinderError) -> Int {
        let parameters = [(FinderCode.objectClass, NSAppleEventDescriptor(typeCode: classCode))]
        guard let result = try send(eventID: FinderCode.countElements, direct: container, parameters: parameters) else {
            throw FinderError.malformedReply
        }
        return Int(result.int32Value)
    }

    /// 问存不存在：`exists <specifier>`。
    func exists(_ specifier: NSAppleEventDescriptor) throws(FinderError) -> Bool {
        guard let result = try send(eventID: FinderCode.doesExist, direct: specifier) else {
            throw FinderError.malformedReply
        }
        return result.booleanValue
    }

    /// 发一个事件并等回复。返回回复里的直接对象；访达报错或发送失败时抛出 `FinderError`。
    private func send(
        eventID: FourCharCode,
        direct: NSAppleEventDescriptor,
        parameters: [(FourCharCode, NSAppleEventDescriptor)] = []
    ) throws(FinderError) -> NSAppleEventDescriptor? {
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: FinderCode.coreSuite,
            eventID: eventID,
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: Self.bundleIdentifier),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(direct, forKeyword: FinderCode.directObject)
        for (keyword, value) in parameters {
            event.setParam(value, forKeyword: keyword)
        }

        let reply: NSAppleEventDescriptor
        do {
            // neverInteract：不许访达为了回答我们而弹出任何界面。
            reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: timeout)
        } catch {
            throw FinderError(code: (error as NSError).code)
        }
        if let errorNumber = reply.paramDescriptor(forKeyword: FinderCode.errorNumber), errorNumber.int32Value != 0 {
            throw FinderError(code: Int(errorNumber.int32Value))
        }
        return reply.paramDescriptor(forKeyword: FinderCode.directObject)
    }

    // MARK: 授权

    /// 查询本应用是否获准控制访达。
    ///
    /// - Parameter askUser: 为 false 时只查不问，立即返回；为 true 时，如果还没问过用户，系统会弹出授权窗口，
    ///   并且**一直阻塞到用户回答**——所以只能在后台队列调用。
    func authorization(askUser: Bool) -> FinderAuthorization {
        let target = NSAppleEventDescriptor(bundleIdentifier: Self.bundleIdentifier)
        guard let address = target.aeDesc else { return .undetermined(0) }
        let status = AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, askUser)
        return FinderAuthorization(status: Int(status))
    }
}

// MARK: - 解析回复

extension NSAppleEventDescriptor {
    /// 把"列表或单个值"统一成数组：访达对 every … 的回答通常是列表，只有一项时个别情况下会直接给出那一项。
    var listElements: [NSAppleEventDescriptor] {
        guard descriptorType == FinderCode.list else { return [self] }
        guard numberOfItems > 0 else { return [] }
        return (1...numberOfItems).compactMap { atIndex($0) }
    }

    /// 解析一个点。访达给的是 QuickDraw 点（两个 16 位整数：先纵坐标、后横坐标）；也兼容 {x, y} 两个数的列表。
    var pointValue: CGPoint? {
        if descriptorType == FinderCode.quickDrawPoint {
            return QuickDrawPoint.decode(data)
        }
        if descriptorType == FinderCode.list, numberOfItems == 2,
           let x = atIndex(1), let y = atIndex(2),
           x.descriptorType != FinderCode.list, y.descriptorType != FinderCode.list {
            return CGPoint(x: CGFloat(x.int32Value), y: CGFloat(y.int32Value))
        }
        return nil
    }
}

/// QuickDraw 点的字节布局：4 个字节，先是纵坐标 v，再是横坐标 h，各为本机字节序的 16 位有符号整数。
enum QuickDrawPoint {
    static func decode(_ data: Data) -> CGPoint? {
        guard data.count == 4 else { return nil }
        let vertical = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int16.self) }
        let horizontal = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 2, as: Int16.self) }
        return CGPoint(x: CGFloat(horizontal), y: CGFloat(vertical))
    }

    static func encode(_ point: CGPoint) -> Data {
        var vertical = Int16(clamping: Int(point.y.rounded()))
        var horizontal = Int16(clamping: Int(point.x.rounded()))
        var data = Data()
        withUnsafeBytes(of: &vertical) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &horizontal) { data.append(contentsOf: $0) }
        return data
    }
}
