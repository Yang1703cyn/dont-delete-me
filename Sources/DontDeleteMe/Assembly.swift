// 装配：全应用唯一写明"每个模块具体用哪个类型"的地方。
//
// 各模块的入口类型名和构造方式是固定的（见 docs/接口约定.md「模块入口」），
// 所以各子对话把占位实现换成真的之后，这个文件不需要改。

import DDMCore
import Emotion
import Faces
import Foundation
import IconBridge
import InputSense
import Overlay

@MainActor
enum Assembly {
    /// - Parameter assumeDesktopVisible: 只给自检用（`--smoke-test … --assume-visible`）：
    ///   让叠加层不管桌面看不看得见都照常出帧。正常运行时一律为 false。
    static func makePipeline(assumeDesktopVisible: Bool = false) -> FramePipeline {
        let overlay: OverlayHost
        if assumeDesktopVisible {
            var options = OverlayOptions()
            options.assumesAlwaysVisible = true
            overlay = OverlayHost(options: options)
        } else {
            overlay = OverlayHost()
        }
        return FramePipeline(
            icons: DesktopIconProvider(),
            sensor: InteractionSensor(),
            // 情绪引擎的随机数种子由外部传入：每次启动换一个，让眨眼等随机节奏每次不同。
            director: EmotionDirector(seed: UInt64.random(in: UInt64.min...UInt64.max)),
            renderer: FaceRenderer(),
            overlay: overlay,
            pause: .shared
        )
    }
}
