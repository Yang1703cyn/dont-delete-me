// OverlayTests · 公用的假数据
//
// 假的显示器布局照着开发机的样子造：内屏 1512×982 @2x 是主屏；外接屏 1920×1080 @1x 在它左边、略高出一截，
// 所以外接屏的坐标是负数。测试不碰真实的屏幕和桌面。

import CoreGraphics
import DDMCore
import Foundation
@testable import Overlay

enum Fixture {
    static let builtIn = DisplayInfo(id: DisplayID(rawValue: 1), frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
    static let external = DisplayInfo(id: DisplayID(rawValue: 3), frame: CGRect(x: -1920, y: -58, width: 1920, height: 1080), scale: 1)
    static let layout = DisplayLayout(displays: [builtIn, external])

    /// 一个 64×64 的画布项。
    static func item(
        _ id: UInt64 = 1,
        x: CGFloat,
        y: CGFloat,
        layer: OverlayLayer = .desktop,
        outsets: EdgeOutsets = EdgeOutsets(all: 8),
        version: UInt64 = 1
    ) -> OverlayItem {
        OverlayItem(
            iconID: IconID(rawValue: id), layer: layer,
            rect: CGRect(x: x, y: y, width: 64, height: 64), outsets: outsets, contentVersion: version
        )
    }
}
