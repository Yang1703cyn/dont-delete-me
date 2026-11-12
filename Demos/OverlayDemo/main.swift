// 占位，由 overlay 子对话替换。
//
// 叠加层的独立演示程序。运行：swift run OverlayDemo
// 只依赖 DDMCore 和 Overlay。演示程序必须能自己正常结束（限时退出）。

import CoreGraphics
import DDMCore
import Foundation
import Overlay

/// 最简单的帧回调接收方：每帧给出一个假的画布项，数一数被回调了几帧、画了几次。
@MainActor
final class DemoSource: OverlayFrameSource {
    var frames = 0
    var draws = 0

    func overlayFrame(at time: FrameTime) -> OverlayFrame {
        frames += 1
        let item = OverlayItem(
            iconID: IconID(rawValue: 1),
            rect: CGRect(x: 100, y: 100, width: 64, height: 64),
            contentVersion: UInt64(frames)
        )
        // 请叠加层 0.1 秒后再来取下一帧。
        return OverlayFrame(items: [item], demand: .by(time.monotonic + 0.1))
    }

    func drawOverlayItem(_ item: OverlayItem, in context: CGContext, at time: FrameTime) {
        draws += 1
    }
}

let source = DemoSource()
let host = OverlayHost(pause: PauseSwitch())
host.frameSource = source
host.start()

RunLoop.main.run(until: Date().addingTimeInterval(0.35))
host.stop()
print("[OverlayDemo] 0.35 秒内帧回调 \(source.frames) 次，绘制回调 \(source.draws) 次（占位实现不建窗、不绘制）。")
print("[OverlayDemo] 占位演示结束。")
