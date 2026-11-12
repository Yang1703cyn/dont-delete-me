// IconBridgeDemo · 测试台：只操作自己新建的临时测试文件
//
// 图标桥模块本身只读不写；写入类的实测（新建、改位置、删除）需要的"写"都在这里，属于演示程序，不进应用。
//
// 安全线（由 `guardName` 强制）：
//   - 这里的每一个写操作都只接受名字以「别删我-测试」开头的项目；
//   - 新建之前先确认桌面和废纸篓里都没有同名的东西，绝不碰用户已有的文件；
//   - 进了废纸篓的临时文件，用访达移回桌面再删除；不清空废纸篓，不碰废纸篓里的其它东西。
//
// 新建、改位置、移入废纸篓、移回都经由访达完成（和应用一样只需要"控制访达"授权）；
// 只有"直接删除"和"设置纯色图标"是直接操作自己的临时文件，需要启动本程序的那个程序有权访问桌面文件夹。

import AppKit
import Foundation

@MainActor
enum TestBench {
    static let namePrefix = "别删我-测试"

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    private static func guardName(_ name: String) {
        precondition(name.hasPrefix(namePrefix), "测试台只允许操作自己的临时文件")
    }

    // MARK: 向访达发事件（最小实现）

    private static func code(_ string: String) -> FourCharCode {
        string.utf8.prefix(4).reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

    private static func specifier(want: String, from container: NSAppleEventDescriptor, form: String, data: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: code(want)), forKeyword: code("want"))
        record.setDescriptor(container, forKeyword: code("from"))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: code(form)), forKeyword: code("form"))
        record.setDescriptor(data, forKeyword: code("seld"))
        return record.coerce(toDescriptorType: typeObjectSpecifier) ?? record
    }

    private static func property(_ name: String, of container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
        specifier(want: "prop", from: container, form: "prop", data: NSAppleEventDescriptor(typeCode: code(name)))
    }

    private static var desktop: NSAppleEventDescriptor { property("desk") }
    private static var trash: NSAppleEventDescriptor { property("trsh") }

    private static func item(_ name: String, in container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        specifier(want: "cobj", from: container, form: "name", data: NSAppleEventDescriptor(string: name))
    }

    @discardableResult
    private static func send(_ eventID: String, direct: NSAppleEventDescriptor, _ parameters: [(String, NSAppleEventDescriptor)] = []) throws -> NSAppleEventDescriptor? {
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: code("core"),
            eventID: code(eventID),
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder"),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(direct, forKeyword: code("----"))
        for (keyword, value) in parameters {
            event.setParam(value, forKeyword: code(keyword))
        }
        let reply: NSAppleEventDescriptor
        do {
            reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 10)
        } catch {
            throw Failure(description: "访达没有受理请求（错误 \((error as NSError).code)）")
        }
        if let number = reply.paramDescriptor(forKeyword: code("errn")), number.int32Value != 0 {
            throw Failure(description: "访达报错 \(number.int32Value)")
        }
        return reply.paramDescriptor(forKeyword: code("----"))
    }

    // MARK: 查询

    static func existsOnDesktop(_ name: String) -> Bool {
        guardName(name)
        return (try? send("doex", direct: item(name, in: desktop)))?.booleanValue ?? false
    }

    static func existsInTrash(_ name: String) -> Bool {
        guardName(name)
        return (try? send("doex", direct: item(name, in: trash)))?.booleanValue ?? false
    }

    static func trashCount() -> Int? {
        guard let reply = try? send("cnte", direct: trash, [("kocl", NSAppleEventDescriptor(typeCode: code("cobj")))]) else { return nil }
        return Int(reply.int32Value)
    }

    /// 访达报告的 desktop position（全局坐标）。
    static func position(of name: String) -> CGPoint? {
        guardName(name)
        guard let reply = try? send("getd", direct: property("dpos", of: item(name, in: desktop))) else { return nil }
        // QuickDraw 点：先纵坐标、后横坐标，各 16 位。
        guard reply.data.count == 4 else { return nil }
        let vertical = reply.data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int16.self) }
        let horizontal = reply.data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 2, as: Int16.self) }
        return CGPoint(x: CGFloat(horizontal), y: CGFloat(vertical))
    }

    /// 访达报告的全部桌面图标的位置（只读；只有坐标，没有名字）。读不到为 nil。
    static func allDesktopPositions() -> [CGPoint]? {
        var all = code("all ")
        guard let ordinal = NSAppleEventDescriptor(descriptorType: code("abso"), bytes: &all, length: 4),
              let reply = try? send("getd", direct: property("dpos", of: specifier(want: "cobj", from: desktop, form: "indx", data: ordinal)))
        else { return nil }
        let elements: [NSAppleEventDescriptor]
        if reply.descriptorType == code("list") {
            elements = reply.numberOfItems > 0 ? (1...reply.numberOfItems).compactMap { reply.atIndex($0) } : []
        } else {
            elements = [reply]
        }
        return elements.compactMap { element in
            guard element.data.count == 4 else { return nil }
            let vertical = element.data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int16.self) }
            let horizontal = element.data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 2, as: Int16.self) }
            return CGPoint(x: CGFloat(horizontal), y: CGFloat(vertical))
        }
    }

    // MARK: 写（只对自己的临时文件）

    /// 经访达在桌面上新建一个空文件，并放到指定位置。
    static func createFile(named name: String, at position: CGPoint) throws {
        guardName(name)
        guard !existsOnDesktop(name), !existsInTrash(name) else {
            throw Failure(description: "桌面或废纸篓里已经有同名的东西，为了不碰它，放弃新建")
        }
        let properties = NSAppleEventDescriptor.record()
        properties.setDescriptor(NSAppleEventDescriptor(string: name), forKeyword: code("pnam"))
        try send("crel", direct: .null(), [
            ("kocl", NSAppleEventDescriptor(typeCode: code("file"))),
            ("insh", desktop),
            ("prdt", properties),
        ])
        created.insert(name)
        try setPosition(of: name, to: position)
    }

    /// 经访达设置图标位置。
    static func setPosition(of name: String, to position: CGPoint) throws {
        guardName(name)
        let point = NSAppleEventDescriptor.list()
        point.insert(NSAppleEventDescriptor(int32: Int32(position.x.rounded())), at: 1)
        point.insert(NSAppleEventDescriptor(int32: Int32(position.y.rounded())), at: 2)
        try send("setd", direct: property("dpos", of: item(name, in: desktop)), [("data", point)])
    }

    /// 经访达移入废纸篓（和用户把它拖进废纸篓是同一个操作）。
    static func moveToTrash(_ name: String) throws {
        guardName(name)
        try send("delo", direct: item(name, in: desktop))
    }

    /// 经访达从废纸篓移回桌面。
    static func putBack(_ name: String) throws {
        guardName(name)
        try send("move", direct: item(name, in: trash), [("insh", desktop)])
    }

    /// 直接删除（不经废纸篓）自己的临时文件。
    static func deleteDirectly(_ name: String) throws {
        guardName(name)
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").appendingPathComponent(name)
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw Failure(description: "直接删除失败（启动本程序的那个程序可能无权访问桌面文件夹）")
        }
        created.remove(name)
    }

    /// 给自己的临时文件设一个纯色方块图标（校准用：方便在截图里精确量出图标图像的矩形）。
    static func setSolidIcon(of name: String, color: NSColor) -> Bool {
        guardName(name)
        let size = NSSize(width: 512, height: 512)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").appendingPathComponent(name).path
        return NSWorkspace.shared.setIcon(image, forFile: path, options: [])
    }

    // MARK: 清理

    /// 本次运行新建过的临时文件。
    private(set) static var created = Set<String>()

    /// 清理本次运行新建的、还没删掉的临时文件：在废纸篓里的先移回桌面，再直接删除。
    /// 返回是否清理干净；临时文件既不在桌面也不在废纸篓（例如被拖进了别的文件夹）算没清理干净。
    @discardableResult
    static func cleanUp() -> Bool {
        var clean = true
        for name in created.sorted() {
            if !existsOnDesktop(name), existsInTrash(name) {
                try? putBack(name)
                waitUntil(timeout: 3) { existsOnDesktop(name) }
            }
            guard existsOnDesktop(name) else {
                clean = false
                continue
            }
            try? deleteDirectly(name)
            waitUntil(timeout: 3) { !existsOnDesktop(name) }
            if existsOnDesktop(name) {
                clean = false
            }
        }
        return clean
    }

    private static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}
