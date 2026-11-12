// 占位，由 input-sense 子对话替换。
//
// 交互感知的独立演示程序。运行：swift run InputSenseDemo
// 只依赖 DDMCore 和 InputSense。演示程序必须能自己正常结束（限时退出）。

import CoreGraphics
import DDMCore
import Foundation
import InputSense

// 用假的图标矩形：演示不读取真实桌面。
let icon = DesktopIcon(id: IconID(rawValue: 1), kind: .file, imageRect: CGRect(x: 100, y: 100, width: 64, height: 64))
let snapshot = IconSnapshot(icons: [icon], status: .ok, capturedAt: 0, revision: 1)

let sensor = InteractionSensor()
var time = FrameTime.now()
for frame in 0..<3 {
    let facts = sensor.update(time: time, icons: .unchanged(snapshot))
    print("[InputSenseDemo] 第 \(frame) 帧：鼠标 (\(facts.mouse.position.x), \(facts.mouse.position.y))，悬停 \(facts.hover != nil)，拖拽 \(facts.drag != nil)，废纸篓已知 \(facts.trash != nil)，下次需求 \(facts.demand)")
    time = time.advanced(by: 1.0 / 60)
}
print("[InputSenseDemo] 占位演示结束（占位实现不读取任何系统状态）。")
