// 表情绘制的独立演示程序。只依赖 DDMCore 和 Faces（外加系统框架）。
//
//   swift run FacesDemo                    不带参数：离屏自检，几秒内自己结束，不写任何文件
//   swift run FacesDemo --style-proposal   生成第一阶段的风格提案样张，写到 docs/样张/
//
// 现状（第一阶段）：正式的表情绘制者（Sources/Faces）还是占位实现，要等用户选定风格后再换成真的；
// 三种待选风格的画法在 Demos/FacesDemo/Proposal/ 里。

import AppKit
import CoreGraphics
import DDMCore
import Faces
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case nil:
    runOffscreenCheck()
case "--style-proposal":
    do {
        let written = try StyleProposal.generate()
        for url in written {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            print("[FacesDemo] 已写出 docs/样张/\(url.lastPathComponent)（\(bytes / 1024) KB）")
        }
    } catch {
        print("[FacesDemo] 出样张失败：\(error)")
        exit(1)
    }
default:
    print("用法：swift run FacesDemo [--style-proposal]")
    exit(2)
}

/// 不带参数时的自检：在离屏画布上把三种待选风格的 4 个关键表情各画一遍，确认画得出东西；不写文件。
@MainActor
func runOffscreenCheck() {
    let iconRect = CGRect(x: 48, y: 48, width: 64, height: 64)
    var failures = 0
    for style in StyleProposal.styles {
        for expression in StyleProposal.expressions {
            guard let canvas = SheetCanvas(size: CGSize(width: 160, height: 160), scale: 2) else {
                print("[FacesDemo] 创建离屏画布失败")
                exit(1)
            }
            style.draw(
                expression.state(IconID(rawValue: 1).faceSeed), in: iconRect, context: canvas.context,
                time: StyleProposal.stillTime
            )
            let painted = paintedPixelCount(canvas.context)
            if painted == 0 { failures += 1 }

            // 顺便量一下画一次要多久（64 点、2x），供比较三种风格的开销。
            let rounds = 300
            let state = expression.state(IconID(rawValue: 1).faceSeed)
            let started = ProcessInfo.processInfo.systemUptime
            for round in 0..<rounds {
                style.draw(state, in: iconRect, context: canvas.context, time: Double(round) / 60)
            }
            let milliseconds = (ProcessInfo.processInfo.systemUptime - started) / Double(rounds) * 1000
            print("[FacesDemo] \(style.title) · \(expression.name)：画了 \(painted) 个像素，每次约 \(String(format: "%.3f", milliseconds)) 毫秒")
        }
    }

    // 正式的表情绘制者目前还是占位（什么都不画），这里只确认接口调得通。
    let renderer = FaceRenderer()
    let state = FaceState(mood: .scared, seed: IconID(rawValue: 1).faceSeed, fear: 0.6, sweat: 0.4)
    if let canvas = SheetCanvas(size: CGSize(width: 160, height: 160), scale: 2) {
        renderer.draw(state, in: iconRect, context: canvas.context, time: 0)
        let outsets = renderer.outsets(for: state, iconSize: iconRect.size)
        print("[FacesDemo] 正式绘制者（占位）：画了 \(paintedPixelCount(canvas.context)) 个像素；外扩 上\(outsets.top) 左\(outsets.left) 下\(outsets.bottom) 右\(outsets.right)")
    }

    #if DEBUG
    print("[FacesDemo] 注意：这是调试版，耗时偏大，只能用来比较三种风格的相对开销；要看真实耗时请用 swift run -c release FacesDemo")
    #endif
    if failures > 0 {
        print("[FacesDemo] 有 \(failures) 个表情什么都没画出来")
        exit(1)
    }
    print("[FacesDemo] 离屏自检结束。出风格提案样张：swift run FacesDemo --style-proposal")
}

/// 画布上有多少个不透明度大于 0 的像素。
func paintedPixelCount(_ context: CGContext) -> Int {
    guard let data = context.data else { return 0 }
    let bytes = data.assumingMemoryBound(to: UInt8.self)
    var count = 0
    for row in 0..<context.height {
        for column in 0..<context.width where bytes[row * context.bytesPerRow + column * 4 + 3] > 0 {
            count += 1
        }
    }
    return count
}
