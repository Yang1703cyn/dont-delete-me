// IconBridge · 把几次独立的请求拼成一份前后一致的读数
//
// 访达不能一次把"每个图标的名字 + 位置"原子地交出来（实测：一次取多个属性的写法访达不支持；
// 取"全部属性"又慢了近十倍）。位置和名字只能分两次问，而两次之间桌面可能变化：
//   - 多了或少了图标：两个列表长度不同，能看出来；
//   - 改了名字：访达的列表是按名字排序的，改名会让项目换位——长度没变，下标却对不上了，看不出来。
//
// 办法：**先问位置、再问名字**。
//   - 名字列表和上一次一模一样、长度也对得上：名字是后问的，说明直到问完都没有增减和改名，
//     先问到的位置必然和它一一对应。两次请求就够了（平时绝大多数读取走这条路）。
//   - 名字列表变了：桌面正在变化。把需要的属性再问一轮，并且最后再问一次名字；
//     只有"这一轮前后的名字完全相同"才采用，否则再来，最多试几轮。

import CoreGraphics
import Foundation

/// 一份前后一致的原始读数：四个列表下标一一对应。
struct RawDesktopRead: Equatable, Sendable {
    var names: [String]
    var positions: [CGPoint]
    var classCodes: [FourCharCode]
    /// 这次读了修改时间才有（定期重读，或名字列表有变化时）；没读为 nil。
    var modificationDates: [Date?]?
    /// 是否走了"两次请求就够"的常规路径（名字没变、也不用补读修改时间）。
    var wasRoutine = false
}

enum ConsistentDesktopRead {
    /// 读一次桌面。
    ///
    /// - Parameters:
    ///   - previousNames / previousClassCodes: 上一次成功读到的名字和类（按访达的顺序）。第一次读传空数组。
    ///   - wantsModificationDates: 这次是否顺带读修改时间。
    ///   - maxAttempts: 桌面一直在变时最多重试几轮。
    /// - Returns: 一致的读数；试满了仍不一致返回 nil（调用方保留旧快照，稍后再读）。
    static func read(
        from source: any DesktopQuerying,
        previousNames: [String],
        previousClassCodes: [FourCharCode],
        wantsModificationDates: Bool,
        maxAttempts: Int = 3
    ) throws(FinderError) -> RawDesktopRead? {
        var positions = try source.positions()
        var names = try source.names()

        let unchanged = names == previousNames
            && positions.count == names.count
            && previousClassCodes.count == names.count
        if unchanged && !wantsModificationDates {
            return RawDesktopRead(names: names, positions: positions, classCodes: previousClassCodes, modificationDates: nil, wasRoutine: true)
        }

        // 桌面变了（或者要补读修改时间）：再问一轮，以"最后再问一次名字"收尾来确认这一轮是稳定的。
        var needsClassCodes = !unchanged
        for _ in 0..<maxAttempts {
            // 类和修改时间总是一起读：名字变了（多半有新图标）要读，定期重读修改时间时也顺带重读类——
            // 名字没变而类变了的情况很少见（例如应用正在被拷贝到桌面），靠定期重读跟上就够了。
            let wantsDetails = needsClassCodes || wantsModificationDates
            let classCodes = wantsDetails ? try source.classCodes() : previousClassCodes
            let dates = wantsDetails ? try source.modificationDates() : nil
            positions = try source.positions()
            let confirmedNames = try source.names()

            let stable = confirmedNames == names
                && positions.count == names.count
                && classCodes.count == names.count
                && (dates?.count ?? names.count) == names.count
            if stable {
                return RawDesktopRead(names: names, positions: positions, classCodes: classCodes, modificationDates: dates)
            }
            // 这一轮中间又变了：以最新的名字为准重来，这回类也必须重读。
            names = confirmedNames
            needsClassCodes = true
        }
        return nil
    }
}
