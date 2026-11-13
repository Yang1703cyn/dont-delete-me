// 坐标换算、矩形推算、所在显示器

import CoreGraphics
import DDMCore
import Foundation
import Testing
@testable import IconBridge

@Suite("矩形推算")
struct IconGeometryTests {
    private func options(icon: CGFloat = 64, text: CGFloat = 12, label: LabelPosition = .bottom, info: Bool = false) -> DesktopViewOptions {
        DesktopViewOptions(appearance: DesktopAppearance(iconSize: icon, textSize: text, labelPosition: label), showsItemInfo: info)
    }

    @Test func 图像矩形以位置为中心_边长为图标大小() {
        let rect = IconGeometry.imageRect(position: CGPoint(x: 300, y: 300), iconSize: 64)
        #expect(rect == CGRect(x: 268, y: 268, width: 64, height: 64))
        #expect(rect.center == CGPoint(x: 300, y: 300))
    }

    @Test(arguments: [16.0, 32.0, 48.0, 64.0, 96.0, 128.0, 37.0])
    func 各种图标大小下中心都不变(size: Double) {
        let position = CGPoint(x: -960, y: 400)
        let rect = IconGeometry.imageRect(position: position, iconSize: size)
        #expect(rect.width == size && rect.height == size)
        #expect(rect.center == position)
        #expect(IconGeometry.position(ofImageRect: rect) == position)
    }

    @Test func 推算的标签矩形包住截图里量到的文字笔画() {
        // 截图校准的实测值（图标 64 点、文字 12 点、标签在下；图像矩形下沿在 y = 252）：
        //   短名字（一行，字宽 72.3 点）：笔画占 (123.0, 261.5, 71.5 × 11.0)
        //   长名字（折成两行）：        笔画占 (346.0, 261.5, 106.5 × 27.0)
        let short = IconGeometry.labelRect(textWidth: 72.3, imageRect: CGRect(x: 128, y: 188, width: 64, height: 64), options: options())
        let shortInk = CGRect(x: 123.0, y: 261.5, width: 71.5, height: 11.0)
        #expect(short.contains(shortInk))
        #expect(short.insetBy(dx: 7, dy: 3).intersection(shortInk) != shortInk)   // 没有大出去太多：每边最多多出 7 点 / 3 点

        let long = IconGeometry.labelRect(textWidth: 400, imageRect: CGRect(x: 368, y: 188, width: 64, height: 64), options: options())
        let longInk = CGRect(x: 346.0, y: 261.5, width: 106.5, height: 27.0)
        #expect(long.contains(longInk))
        #expect(long == CGRect(x: 341, y: 259, width: 118, height: 32))
    }

    @Test func 标签在下方_短名字一行_水平居中() {
        let image = CGRect(x: 268, y: 268, width: 64, height: 64)
        let label = IconGeometry.labelRect(textWidth: 50, imageRect: image, options: options())
        // 宽 = 文字 50 + 左右留白各 4；高 = 一行 16；上沿 = 图像下沿 332 + 间隙 7。
        #expect(label == CGRect(x: 300 - 29, y: 339, width: 58, height: 16))
        #expect(label.midX == image.midX)
    }

    @Test func 标签在下方_长名字折成两行_宽度封顶() {
        let image = CGRect(x: 268, y: 268, width: 64, height: 64)
        let label = IconGeometry.labelRect(textWidth: 400, imageRect: image, options: options())
        // 最宽 = 图标 64 + 46 = 110，加留白 118；最多两行。
        #expect(label.width == 118)
        #expect(label.height == 32)
        #expect(label.minY == 339)
        #expect(label.midX == image.midX)
    }

    @Test func 刚好放得下是一行_超一点就是两行() {
        let image = CGRect(x: 0, y: 0, width: 64, height: 64)
        #expect(IconGeometry.labelRect(textWidth: 110, imageRect: image, options: options()).height == 16)
        #expect(IconGeometry.labelRect(textWidth: 110.5, imageRect: image, options: options()).height == 32)
    }

    @Test func 文字越大行越高() {
        let image = CGRect(x: 0, y: 0, width: 64, height: 64)
        let small = IconGeometry.labelRect(textWidth: 30, imageRect: image, options: options(text: 10))
        let large = IconGeometry.labelRect(textWidth: 30, imageRect: image, options: options(text: 16))
        #expect(small.height == 13)
        #expect(large.height == 21)
    }

    @Test func 图标越大标签离中心越远() {
        let small = IconGeometry.imageRect(position: CGPoint(x: 500, y: 500), iconSize: 32)
        let large = IconGeometry.imageRect(position: CGPoint(x: 500, y: 500), iconSize: 128)
        let smallLabel = IconGeometry.labelRect(textWidth: 30, imageRect: small, options: options(icon: 32))
        let largeLabel = IconGeometry.labelRect(textWidth: 30, imageRect: large, options: options(icon: 128))
        // 标签上沿 = 中心 + 半个图标 + 间隙 7。
        #expect(smallLabel.minY == CGFloat(523))
        #expect(largeLabel.minY == CGFloat(571))
    }

    @Test func 标签在右侧_垂直居中_紧挨图像右沿() {
        let image = CGRect(x: 268, y: 268, width: 64, height: 64)
        let label = IconGeometry.labelRect(textWidth: 50, imageRect: image, options: options(label: .right))
        #expect(label.minX == image.maxX + 6)
        #expect(label.midY == image.midY)
        #expect(label.width == 58)
        #expect(label.height == 16)
    }

    @Test func 显示项目简介时标签多一行小字() {
        let image = CGRect(x: 0, y: 0, width: 64, height: 64)
        let plain = IconGeometry.labelRect(textWidth: 30, imageRect: image, options: options())
        let withInfo = IconGeometry.labelRect(textWidth: 30, imageRect: image, options: options(info: true))
        #expect(withInfo.height == plain.height + 15)
        #expect(withInfo.minY == plain.minY)
    }

    @Test func 空名字的标签宽度不为负() {
        let label = IconGeometry.labelRect(textWidth: 0, imageRect: CGRect(x: 0, y: 0, width: 64, height: 64), options: options())
        #expect(label.width == 8)
    }

    @Test func 系统字体能量出文字宽度_字越多越宽() {
        let short = LabelTextMeasurer.width(of: "ab", fontSize: 12)
        let long = LabelTextMeasurer.width(of: "abababab", fontSize: 12)
        #expect(short > 0)
        #expect(long > short * 3)
        #expect(LabelTextMeasurer.width(of: "ab", fontSize: 24) > short * 1.5)
    }
}

@Suite("坐标换算与所在显示器")
struct DisplayAssignmentTests {
    private let layout = Fixture.layout

    private func display(at position: CGPoint, size: CGFloat = 64) -> DisplayID? {
        IconGeometry.displayID(for: IconGeometry.imageRect(position: position, iconSize: size), in: layout)
    }

    @Test func 主屏上的图标算在主屏() {
        #expect(display(at: CGPoint(x: 300, y: 300)) == Fixture.mainDisplay.id)
        #expect(display(at: CGPoint(x: 1446, y: 746)) == Fixture.mainDisplay.id)
    }

    @Test func 左侧外接屏上的图标坐标为负_算在外接屏() {
        #expect(display(at: CGPoint(x: -960, y: 400)) == Fixture.externalDisplay.id)
        #expect(display(at: CGPoint(x: -1900, y: -40)) == Fixture.externalDisplay.id)   // 外接屏比主屏高 58 点，y 可以为负
        #expect(display(at: CGPoint(x: -30, y: 1000)) == Fixture.externalDisplay.id)    // 低于主屏底边，但仍在外接屏内
    }

    @Test func 跨在两块屏接缝上的图标按中心算() {
        #expect(display(at: CGPoint(x: 10, y: 400)) == Fixture.mainDisplay.id)
        #expect(display(at: CGPoint(x: -10, y: 400)) == Fixture.externalDisplay.id)
    }

    @Test func 中心落在屏幕之外但矩形还搭着屏幕时取相交最多的那块() {
        // 主屏下方：中心在 y = 990（主屏高 982），矩形上半截还在主屏里。
        #expect(display(at: CGPoint(x: 700, y: 990)) == Fixture.mainDisplay.id)
    }

    @Test func 和哪块屏都不相交时判断不出() {
        #expect(display(at: CGPoint(x: 5000, y: 5000)) == nil)
        #expect(display(at: CGPoint(x: 700, y: -500)) == nil)
    }

    @Test func 没有任何显示器时判断不出() {
        let rect = IconGeometry.imageRect(position: CGPoint(x: 300, y: 300), iconSize: 64)
        #expect(IconGeometry.displayID(for: rect, in: DisplayLayout(displays: [])) == nil)
    }

    @Test func 外接屏上的图标换成屏内坐标() {
        // desktop position (-960, 400) → 图像矩形 (-992, 368, 64, 64)。
        // 外接屏左上角在全局 (-1920, -58)，所以屏内坐标是 (928, 426)。
        let rect = IconGeometry.imageRect(position: CGPoint(x: -960, y: 400), iconSize: 64)
        let local = Fixture.externalDisplay.localRect(fromGlobal: rect)
        #expect(local == CGRect(x: 928, y: 426, width: 64, height: 64))
        #expect(Fixture.externalDisplay.globalRect(fromLocal: local) == rect)
        #expect(CGRect(origin: .zero, size: Fixture.externalDisplay.frame.size).contains(local))
    }

    @Test func 外接屏上的图标换成AppKit坐标后落在对应屏幕的AppKit矩形里() {
        let rect = IconGeometry.imageRect(position: CGPoint(x: -960, y: 400), iconSize: 64)
        let appKit = layout.appKitRect(fromGlobal: rect)
        // AppKit 的 y 向上、以主屏左下角为原点：下沿 = 982 − (368 + 64) = 550。
        #expect(appKit == CGRect(x: -992, y: 550, width: 64, height: 64))
        let screenInAppKit = layout.appKitRect(fromGlobal: Fixture.externalDisplay.frame)
        #expect(screenInAppKit == CGRect(x: -1920, y: -40, width: 1920, height: 1080))   // 与开发机上 NSScreen.frame 的实测值一致
        #expect(screenInAppKit.contains(appKit))
        #expect(layout.globalRect(fromAppKit: appKit) == rect)
    }
}

@Suite("访达回复的解析")
struct ReplyDecodingTests {
    @Test func 四字符代码() {
        #expect(fourCharCode("dpos") == 0x6470_6F73)
        #expect(fourCharCode("all ") == 0x616C_6C20)
        #expect(FinderCode.classDisk == fourCharCode("cdis"))
    }

    @Test func QuickDraw点是先纵后横() {
        let data = QuickDrawPoint.encode(CGPoint(x: -960, y: 400))
        #expect(data.count == 4)
        // 前两个字节是纵坐标 400，后两个字节是横坐标 -960（本机字节序）。
        #expect(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int16.self) } == 400)
        #expect(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 2, as: Int16.self) } == -960)
        #expect(QuickDrawPoint.decode(data) == CGPoint(x: -960, y: 400))
    }

    @Test func 长度不对的数据解不出点() {
        #expect(QuickDrawPoint.decode(Data([1, 2, 3])) == nil)
        #expect(QuickDrawPoint.decode(Data()) == nil)
    }

    @Test func 回复里的点列表() throws {
        let list = NSAppleEventDescriptor.list()
        for (index, point) in [CGPoint(x: 300, y: 300), CGPoint(x: -960, y: 400)].enumerated() {
            let data = QuickDrawPoint.encode(point)
            let descriptor = try #require(data.withUnsafeBytes { NSAppleEventDescriptor(descriptorType: FinderCode.quickDrawPoint, bytes: $0.baseAddress, length: $0.count) })
            list.insert(descriptor, at: index + 1)
        }
        #expect(list.listElements.compactMap(\.pointValue) == [CGPoint(x: 300, y: 300), CGPoint(x: -960, y: 400)])
    }

    @Test func 单个值也当作只有一项的列表_空列表是零项() {
        #expect(NSAppleEventDescriptor(string: "x").listElements.count == 1)
        #expect(NSAppleEventDescriptor.list().listElements.isEmpty)
    }

    @Test func 两个数的列表也能当作一个点() {
        let pair = NSAppleEventDescriptor.list()
        pair.insert(NSAppleEventDescriptor(int32: 500), at: 1)
        pair.insert(NSAppleEventDescriptor(int32: 300), at: 2)
        #expect(pair.pointValue == CGPoint(x: 500, y: 300))
    }
}

@Suite("种类与编号")
struct IdentityTests {
    @Test func 访达的类对应到图标种类() {
        #expect(ItemClassification.kind(forClassCode: FinderCode.classFolder) == .folder)
        #expect(ItemClassification.kind(forClassCode: FinderCode.classApplicationFile) == .application)
        #expect(ItemClassification.kind(forClassCode: FinderCode.classDisk) == .volume)
        #expect(ItemClassification.kind(forClassCode: FinderCode.classDocumentFile) == .file)
        #expect(ItemClassification.kind(forClassCode: FinderCode.classAliasFile) == .file)
        #expect(ItemClassification.kind(forClassCode: FinderCode.classInternetLocation) == .file)
        #expect(ItemClassification.kind(forClassCode: FinderCode.classPackage) == .file)
        #expect(ItemClassification.kind(forClassCode: fourCharCode("zzzz")) == .other)
    }

    @Test func 同样的盐和名字得到同样的编号() {
        let a = IconIdentity(salt: Fixture.salt).id(for: ItemKey(name: "示例文件.txt", isVolume: false))
        let b = IconIdentity(salt: Fixture.salt).id(for: ItemKey(name: "示例文件.txt", isVolume: false))
        #expect(a == b)
    }

    @Test func 换一份盐编号就不同() {
        let key = ItemKey(name: "示例文件.txt", isVolume: false)
        let a = IconIdentity(salt: Fixture.salt).id(for: key)
        let b = IconIdentity(salt: Data(repeating: 8, count: 32)).id(for: key)
        #expect(a != b)
    }

    @Test func 不同的名字编号不同_磁盘和同名文件编号也不同() {
        let identity = IconIdentity(salt: Fixture.salt)
        let ids = Set((0..<500).map { identity.id(for: ItemKey(name: "文件\($0)", isVolume: false)) })
        #expect(ids.count == 500)
        #expect(identity.id(for: ItemKey(name: "同名", isVolume: true)) != identity.id(for: ItemKey(name: "同名", isVolume: false)))
    }

    @Test func 同一个键重复出现时_带上序号各得一个编号() {
        let identity = IconIdentity(salt: Fixture.salt)
        let key = ItemKey(name: "同名盘", isVolume: true)
        #expect(identity.id(for: key, occurrence: 0) == identity.id(for: key))
        #expect(identity.id(for: key, occurrence: 1) != identity.id(for: key))
        #expect(identity.id(for: key, occurrence: 1) != identity.id(for: key, occurrence: 2))
        #expect(identity.id(for: key, occurrence: 1) == identity.id(for: key, occurrence: 1))
    }

    @Test func 名字的两种Unicode写法得到同一个编号() {
        let identity = IconIdentity(salt: Fixture.salt)
        let composed = "caf\u{00E9}"          // é 是一个字符
        let decomposed = "cafe\u{0301}"       // e 加组合重音符
        #expect(identity.id(for: ItemKey(name: composed, isVolume: false)) == identity.id(for: ItemKey(name: decomposed, isVolume: false)))
    }

    @Test func 编号里不含名字的字节() {
        // 名字是 8 个 ASCII 字符，正好能塞进 64 位：编号不应该就是它。
        let name = "abcdefgh"
        let id = IconIdentity(salt: Fixture.salt).id(for: ItemKey(name: name, isVolume: false))
        let nameAsNumber = name.utf8.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        #expect(id.rawValue != nameAsNumber)
        #expect(id.rawValue.byteSwapped != nameAsNumber)
        #expect(!"\(id)".contains("abcd"))
    }

    @Test func 随机盐每次不同_长度32字节() {
        let a = IconIdentity.randomSalt(), b = IconIdentity.randomSalt()
        #expect(a.count == 32 && b.count == 32)
        #expect(a != b)
    }

    /// 内存里的字典，顶替偏好设置：测试不往磁盘上写任何东西。
    private final class MemorySaltStore: SaltStore {
        var values: [String: Data] = [:]
        func data(forKey key: String) -> Data? { values[key] }
        func set(_ value: Data, forKey key: String) { values[key] = value }
    }

    @Test func 持久的盐第一次生成后存起来_以后不再变() {
        let store = MemorySaltStore()
        let first = IconIdentityStorage.persistent.loadSalt(store: store)
        let second = IconIdentityStorage.persistent.loadSalt(store: store)
        #expect(first == second)
        #expect(first.count == 32)
        #expect(store.values == [IconIdentityStorage.defaultsKey: first])   // 只存了这一项
    }

    @Test func 存着的盐太短或没有时重新生成() {
        let store = MemorySaltStore()
        store.values[IconIdentityStorage.defaultsKey] = Data([1, 2, 3])     // 坏掉的旧值
        let salt = IconIdentityStorage.persistent.loadSalt(store: store)
        #expect(salt.count == 32)
        #expect(store.values[IconIdentityStorage.defaultsKey] == salt)
    }

    @Test func 不落盘的盐每次都是新的_而且不碰存储() {
        let store = MemorySaltStore()
        let first = IconIdentityStorage.ephemeral.loadSalt(store: store)
        let second = IconIdentityStorage.ephemeral.loadSalt(store: store)
        #expect(first != second)
        #expect(store.values.isEmpty)
    }
}
