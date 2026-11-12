// 占位，由 faces 子对话替换。
//
// 表情绘制的独立演示程序。运行：swift run FacesDemo
// 只依赖 DDMCore 和 Faces。演示程序必须能自己正常结束。

import CoreGraphics
import DDMCore
import Faces
import Foundation

let renderer = FaceRenderer()
let iconRect = CGRect(x: 32, y: 32, width: 64, height: 64)
let state = FaceState(mood: .scared, seed: IconID(rawValue: 1).faceSeed, gazeTarget: CGVector(dx: 100, dy: 100), gazeFollow: 1, fear: 0.6, sweat: 0.4)

// 一块 128×128 点、2x 的离屏画布；翻转成 y 向下，与叠加层交给表情模块的画布一致。
let scale: CGFloat = 2
guard let context = CGContext(
    data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("创建离屏画布失败")
}
context.translateBy(x: 0, y: 256)
context.scaleBy(x: scale, y: -scale)

renderer.draw(state, in: iconRect, context: context, time: 0)
let outsets = renderer.outsets(for: state, iconSize: iconRect.size)
print("[FacesDemo] 已在离屏画布上画了一张 \(state.mood.rawValue) 的脸；外扩 上\(outsets.top) 左\(outsets.left) 下\(outsets.bottom) 右\(outsets.right)；循环动画刷新间隔 \(renderer.animationInterval(for: state).map { "\($0) 秒" } ?? "无（静止画面）")。")
print("[FacesDemo] 占位演示结束（占位实现什么都不画）。")
