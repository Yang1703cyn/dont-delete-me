// DDMCore · 从系统读取显示器布局
//
// 这是 DDMCore 里唯一接触系统显示器接口的文件。
// 上半部分只用 CoreGraphics；下半部分是给 AppKit 代码用的便利函数（有 AppKit 才编译）。

import CoreGraphics
import Foundation

extension DisplayLayout {
    /// 读取当前的显示器布局。
    ///
    /// 只用 CoreGraphics，不需要任何授权，可在任何线程调用，耗时可忽略。
    /// 显示器插拔、分辨率或排列变化后需要重新读取（叠加层会监听这类变化）。
    public static func current() -> DisplayLayout {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return DisplayLayout(displays: [])
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return DisplayLayout(displays: [])
        }
        let displays = ids.prefix(Int(count)).map { id -> DisplayInfo in
            // CGDisplayBounds 本身就是全局坐标（主屏左上角为原点、y 向下、单位点）。
            let frame = CGDisplayBounds(id)
            var scale: CGFloat = 1
            if let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 {
                scale = CGFloat(mode.pixelWidth) / CGFloat(mode.width)
            }
            return DisplayInfo(id: DisplayID(rawValue: id), frame: frame, scale: scale)
        }
        return DisplayLayout(displays: displays)
    }
}

#if canImport(AppKit)
import AppKit

extension NSScreen {
    /// 这块 NSScreen 对应的显示器编号。
    @MainActor
    public var ddmDisplayID: DisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = deviceDescription[key] as? NSNumber else { return nil }
        return DisplayID(rawValue: number.uint32Value)
    }
}

extension DisplayInfo {
    /// 这块显示器对应的 NSScreen（找不到时为 nil，例如刚被拔掉）。
    @MainActor
    public var screen: NSScreen? {
        NSScreen.screens.first { $0.ddmDisplayID == id }
    }
}
#endif
