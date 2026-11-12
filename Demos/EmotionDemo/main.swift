// 占位，由 emotion 子对话替换。
//
// 情绪引擎的时间线打印程序。运行：swift run EmotionDemo
// 只依赖 DDMCore 和 Emotion。只用编造的图标数据，必须能自己正常结束。

import CoreGraphics
import DDMCore
import Emotion
import Foundation

// 三个编造的图标，排成一行。
let icons = (0..<3).map { index in
    DesktopIcon(
        id: IconID(rawValue: UInt64(index + 1)),
        kind: .file,
        imageRect: CGRect(x: 100 + 120 * CGFloat(index), y: 100, width: 64, height: 64)
    )
}
let snapshot = IconSnapshot(icons: icons, status: .ok, capturedAt: 0, revision: 1)

var director = EmotionDirector(seed: 42)
// 时间由外部传入：这里从 0 秒开始，每帧 1/60 秒。
var time = FrameTime(monotonic: 0, wallClock: Date(timeIntervalSince1970: 1_800_000_000))
for frame in 0..<3 {
    let icons: IconUpdate = frame == 0 ? IconUpdate(snapshot: snapshot, isReset: true) : .unchanged(snapshot)
    let facts = InteractionFacts(time: time, mouse: MouseState(position: CGPoint(x: 300, y: 300)))
    let output = director.update(EmotionInput(time: time, icons: icons, facts: facts))
    let summary = output.faces.map { "\($0.iconID)=\($0.state.mood.rawValue)" }.joined(separator: " ")
    print("[EmotionDemo] t=\(String(format: "%.3f", time.monotonic)) 脸 \(output.faces.count) 张：\(summary)；需求 \(output.demand)")
    time = time.advanced(by: 1.0 / 60)
}
print("[EmotionDemo] 占位演示结束（占位实现只有平静的脸）。")
