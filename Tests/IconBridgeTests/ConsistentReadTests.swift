// 把几次独立的请求拼成一份前后一致的读数

import CoreGraphics
import DDMCore
import Foundation
import Testing
@testable import IconBridge

@Suite("前后一致的读数")
struct ConsistentReadTests {
    private func desktop() -> FakeDesktop {
        FakeDesktop([
            .init(name: "乙", position: CGPoint(x: 200, y: 100)),
            .init(name: "甲", position: CGPoint(x: 100, y: 100)),
            .init(name: "丙", classCode: FinderCode.classFolder, position: CGPoint(x: 300, y: 100)),
        ])
    }

    private func read(_ desktop: FakeDesktop, previous: RawDesktopRead? = nil, dates: Bool = false) throws -> RawDesktopRead? {
        try ConsistentDesktopRead.read(
            from: desktop,
            previousNames: previous?.names ?? [],
            previousClassCodes: previous?.classCodes ?? [],
            wantsModificationDates: dates
        )
    }

    @Test func 第一次读取_四个列表下标一一对应() throws {
        let desktop = desktop()
        let result = try #require(try read(desktop))
        #expect(result.names == ["丙", "乙", "甲"])   // 假桌面和访达一样按名字排序
        #expect(result.positions == [CGPoint(x: 300, y: 100), CGPoint(x: 200, y: 100), CGPoint(x: 100, y: 100)])
        #expect(result.classCodes == [FinderCode.classFolder, FinderCode.classDocumentFile, FinderCode.classDocumentFile])
        #expect(result.wasRoutine == false)
    }

    @Test func 桌面没变时只发两个请求_先位置后名字() throws {
        let desktop = desktop()
        let first = try #require(try read(desktop))
        desktop.clearLog()
        let second = try #require(try read(desktop, previous: first))
        #expect(desktop.log == ["positions", "names"])
        #expect(second.wasRoutine)
        #expect(second.names == first.names)
        #expect(second.classCodes == first.classCodes)
        #expect(second.modificationDates == nil)
    }

    @Test func 只是移动不算名字变化_仍走常规路径并读到新位置() throws {
        let desktop = desktop()
        let first = try #require(try read(desktop))
        desktop.move("甲", to: CGPoint(x: 900, y: 500))
        desktop.clearLog()
        let second = try #require(try read(desktop, previous: first))
        #expect(desktop.log == ["positions", "names"])
        #expect(second.positions[2] == CGPoint(x: 900, y: 500))
    }

    @Test func 名字变了就再问一轮并以再问一次名字收尾() throws {
        let desktop = desktop()
        let first = try #require(try read(desktop))
        desktop.add("丁", at: CGPoint(x: 400, y: 100))
        desktop.clearLog()
        let second = try #require(try read(desktop, previous: first))
        #expect(desktop.log == ["positions", "names", "classes", "dates", "positions", "names"])
        #expect(second.names.count == 4)
        #expect(second.positions.count == 4)
        #expect(second.modificationDates?.count == 4)
        #expect(second.wasRoutine == false)
    }

    @Test func 位置和名字两次请求之间多了一个图标_长度对不上_重读后一致() throws {
        let desktop = desktop()
        let first = try #require(try read(desktop))
        // 位置已经问完（3 个），问名字之前桌面上多了一个。
        desktop.before("names") { $0.add("丁", at: CGPoint(x: 400, y: 100)) }
        let second = try #require(try read(desktop, previous: first))
        #expect(second.names.count == 4)
        #expect(second.positions.count == 4)
        for (index, name) in second.names.enumerated() {
            #expect(second.positions[index] == desktop.items.first { $0.name == name }?.position)
        }
    }

    @Test func 两次请求之间改了名_长度没变但次序变了_不会张冠李戴() throws {
        let desktop = desktop()
        let first = try #require(try read(desktop))
        // 位置按旧次序 [丙, 乙, 甲] 问完之后，"甲"被改名为"阿"——排到了最前面。
        desktop.before("names") { $0.rename("甲", to: "阿") }
        let second = try #require(try read(desktop, previous: first))
        #expect(second.names == ["丙", "乙", "阿"].sorted())
        for (index, name) in second.names.enumerated() {
            #expect(second.positions[index] == desktop.items.first { $0.name == name }?.position, "\(index) 号的位置应当属于同一个项目")
        }
    }

    @Test func 重读的那一轮中间又变了_再来一轮() throws {
        let desktop = desktop()
        let first = try #require(try read(desktop))
        desktop.add("丁", at: CGPoint(x: 400, y: 100))
        // 第二轮问位置之前又多了一个：这一轮收尾时名字对不上，要来第三轮。
        desktop.before("positions", occurrence: 2) { $0.add("戊", at: CGPoint(x: 500, y: 100)) }
        let second = try #require(try read(desktop, previous: first))
        #expect(second.names.count == 5)
        #expect(second.positions.count == 5)
        #expect(second.classCodes.count == 5)
    }

    @Test func 桌面一直在变_试满了就放弃这一轮() throws {
        let desktop = desktop()
        let first = try #require(try read(desktop))
        desktop.add("丁", at: CGPoint(x: 400, y: 100))
        // 之后每一轮问名字之前都再多一个图标。
        for occurrence in 2...6 {
            desktop.before("names", occurrence: occurrence) { $0.add("新\(occurrence)", at: CGPoint(x: 500, y: 100)) }
        }
        #expect(try read(desktop, previous: first) == nil)
    }

    @Test func 要补读修改时间时_名字没变也多问一轮并校验() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let desktop = FakeDesktop([.init(name: "甲", position: CGPoint(x: 100, y: 100), modified: date)])
        let first = try #require(try read(desktop))
        desktop.clearLog()
        let second = try #require(try read(desktop, previous: first, dates: true))
        #expect(desktop.log == ["positions", "names", "classes", "dates", "positions", "names"])
        #expect(second.modificationDates == [date])
        #expect(second.wasRoutine == false)
    }

    @Test func 空桌面() throws {
        let result = try #require(try read(FakeDesktop()))
        #expect(result.names.isEmpty && result.positions.isEmpty && result.classCodes.isEmpty)
    }

    @Test func 访达报错原样抛出() {
        let desktop = desktop()
        desktop.error = .notPermitted
        #expect(throws: FinderError.notPermitted) {
            _ = try ConsistentDesktopRead.read(from: desktop, previousNames: [], previousClassCodes: [], wantsModificationDates: false)
        }
    }
}
