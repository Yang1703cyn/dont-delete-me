// IconBridge · 图标的种类与不可读的稳定编号
//
// 文件名只在本模块内部用来区分图标；对外只给一个 64 位编号。
// 编号 = HMAC-SHA256(盐, 名字) 的前 8 个字节。盐是每次安装随机生成的 32 个字节，只存在本应用自己的偏好设置里：
// 不知道盐就无法从编号反推名字，也无法验证"某个名字是不是在这台电脑的桌面上"。

import CryptoKit
import DDMCore
import Foundation

/// 由访达报告的"类"判断图标种类。
enum ItemClassification {
    static func kind(forClassCode code: FourCharCode) -> IconKind {
        switch code {
        case FinderCode.classFolder:
            return .folder
        case FinderCode.classApplicationFile:
            return .application
        case FinderCode.classDisk:
            return .volume
        case FinderCode.classDocumentFile, FinderCode.classAliasFile, FinderCode.classInternetLocation,
             FinderCode.classClipping, FinderCode.classPackage, FinderCode.classFile:
            // 文稿、替身、网址快捷方式、剪报、文稿包——都按"普通文件"算。
            return .file
        default:
            return .other
        }
    }
}

/// 模块内部用来区分桌面项目的键：名字 + 是否磁盘。
///
/// 桌面文件夹里的名字互不相同；磁盘不在那个文件夹里，可能和某个文件重名，所以把"是否磁盘"也算进键里。
struct ItemKey: Hashable, Sendable {
    var name: String
    var isVolume: Bool
}

/// 把内部的键变成对外的编号。
struct IconIdentity: Sendable {
    let salt: Data

    init(salt: Data) {
        self.salt = salt
    }

    /// 随机生成一份盐（32 字节）。
    static func randomSalt() -> Data {
        Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) })
    }

    /// - Parameter occurrence: 同一个键在一次读数里第几次出现（从 0 起）。桌面文件夹里不会有重名，
    ///   但两个磁盘可以同名；第二个起带上序号，免得它们共用一个编号。
    func id(for key: ItemKey, occurrence: Int = 0) -> IconID {
        // 名字先做 Unicode 规范化，避免同一个名字因编码形式不同而得到不同的编号。
        var message = Data((key.isVolume ? "volume\u{0}" : "item\u{0}").utf8)
        message.append(Data(key.name.precomposedStringWithCanonicalMapping.utf8))
        if occurrence > 0 {
            message.append(Data("\u{0}#\(occurrence)".utf8))
        }
        let digest = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: salt))
        let value = digest.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        return IconID(rawValue: UInt64(bigEndian: value))
    }
}

/// 盐存在哪里。
public enum IconIdentityStorage: Sendable {
    /// 存在本应用的偏好设置里：编号跨启动不变（同一个图标每次长相一样）。应用里用这个。
    case persistent
    /// 每次启动随机生成、不落盘：编号只在本次运行期间稳定。演示程序和测试用这个。
    case ephemeral

    static let defaultsKey = "IconBridge.identitySalt"

    /// 取出（或首次生成并保存）盐。在主线程调用。
    func loadSalt(defaults: UserDefaults = .standard) -> Data {
        switch self {
        case .ephemeral:
            return IconIdentity.randomSalt()
        case .persistent:
            if let existing = defaults.data(forKey: Self.defaultsKey), existing.count >= 16 {
                return existing
            }
            let salt = IconIdentity.randomSalt()
            defaults.set(salt, forKey: Self.defaultsKey)
            return salt
        }
    }
}
