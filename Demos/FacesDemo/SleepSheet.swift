// FacesDemo · 睡着的脸：逐帧样张与省电前后对比
//
//   swift run -c release FacesDemo --sleep-strip 省电前 --period 3.571
//       用当前的绘制代码出一条"逐帧"样张：docs/样张/睡着-省电前-逐帧.png
//   swift run -c release FacesDemo --sleep-sheet
//       把 docs/样张/睡着-省电前-逐帧.png 和当前代码现画的逐帧拼成 docs/样张/睡着-省电前后.png
//
// "逐帧"：同一张睡着的脸（文件夹图标、困意 100%），在一个完整的起伏周期里，按这一版的刷新间隔（animationInterval）
// 连续取的每一帧——也就是应用里屏幕上实际会依次出现的那几张画面。32 / 64 / 128 点各一组（一行放不下就折行）。
// 每帧都和叠加层一样裁在"图标矩形 + 声明的外扩"里。
//
// "省电前"那一条是用提交 dafdc4e 的绘制代码出的（当时每秒重画 10 次、起伏一周 1/0.28 ≈ 3.571 秒）。
// 要重出它：把 Sources/Faces 换回那个版本，运行上面第一条命令。

import AppKit
import CoreGraphics
import DDMCore
import Faces
import Foundation

@MainActor
enum SleepSheet {
    /// 现在这一版睡着时起伏一周的时长（秒），与 Sources/Faces/FaceStyle.swift 的 breathPeriod 一致。
    static let breathPeriod: TimeInterval = 4.0
    /// 逐帧从哪一刻开始取（秒）。随便取一个固定值，保证每次出图都一样。
    static let startTime: TimeInterval = 100
    /// 一行最多放几帧。
    static let columns = 12
    static let sizes: [CGFloat] = [32, 64, 128]
    static let margin: CGFloat = 24

    /// 睡着的脸：困意 100%（应用里睡着的图标稳定在这个值）。
    static func state() -> FaceState {
        ExpressionPreset.dozing.state(seed: IconID(rawValue: 1).faceSeed, intensity: 1)
    }

    static func cellSize(_ size: CGFloat) -> CGSize {
        CGSize(width: size + 22, height: size * 1.3 + 26)
    }

    // MARK: - 一条逐帧

    /// 画一条逐帧：标题 + 32 / 64 / 128 点各一组。
    /// - Parameters:
    ///   - title: 标题，例如"省电前"。
    ///   - period: 起伏一周多少秒；取这么长时间里的每一帧。
    static func renderStrip(title: String, period: TimeInterval) throws -> SheetCanvas {
        let renderer = FaceRenderer()
        let state = state()
        let interval = renderer.animationInterval(for: state) ?? 0.1
        let step = interval > 0 ? interval : 1.0 / 60
        let frames = max(Int((period / step).rounded()), 1)

        // 每次绘制的耗时（64 点 @2x）：按刷新间隔连续画，覆盖完整的循环。
        let scenario = FaceBench.Scenario(name: title) { _ in state }
        // 先空跑一阵，让处理器升到工作频率；再量三遍，取最快的一遍（出图时别的事会干扰计时）。
        _ = FaceBench.measure(scenario, iconSize: 64, scale: 2, rounds: 3000, step: step)
        let perDraw = (0..<3).map { _ in
            FaceBench.measure(scenario, iconSize: 64, scale: 2, rounds: 3000, step: step)
        }.min() ?? .nan
        #if DEBUG
        let build = "调试版，偏慢"
        #else
        let build = "发布版"
        #endif

        let linesPerSize = (frames + columns - 1) / columns
        let width = margin * 2 + 64 + CGFloat(columns) * cellSize(128).width
        var height: CGFloat = 74 + 10
        for size in sizes {
            height += CGFloat(linesPerSize) * cellSize(size).height + 14
        }
        guard let canvas = SheetCanvas(size: CGSize(width: width, height: height), scale: 2) else {
            throw SampleError.cannotCreateCanvas
        }
        let ctx = canvas.context
        ctx.setFillColor(Tint.hex(0xF7F7F9))
        ctx.fill(CGRect(origin: .zero, size: canvas.size))
        let dark = NSColor(white: 0.12, alpha: 1)
        let gray = NSColor(white: 0.42, alpha: 1)
        SheetPaint.drawText(title, at: CGPoint(x: margin, y: 14), size: 20, weight: .bold, color: dark, context: ctx)
        SheetPaint.drawText(
            String(
                format: "每秒重画 %.0f 次（每 %.2f 秒一帧）· 起伏一周 %.1f 秒 = %d 帧 · 每帧绘制 %.3f 毫秒（64 点 @2x，%@）→ 每张脸每秒 %.2f 毫秒",
                1 / step, step, period, frames, perDraw, build, perDraw / step
            ),
            at: CGPoint(x: margin, y: 44), size: 12, color: gray, context: ctx
        )

        let icon = SampleIcon.standardSet()[0]
        var top: CGFloat = 74
        for size in sizes {
            let lineCount = linesPerSize
            let cell = cellSize(size)
            let panel = CGRect(x: margin, y: top, width: width - margin * 2, height: CGFloat(lineCount) * cell.height + 4)
            SheetPaint.drawWallpaper(in: panel, dark: false, context: ctx)
            SheetPaint.drawText(
                "\(Int(size)) 点", at: CGPoint(x: margin + 10, y: top + 10), size: 13, weight: .semibold,
                color: dark, context: ctx
            )
            for frame in 0..<frames {
                let column = frame % columns
                let line = frame / columns
                let origin = CGPoint(x: margin + 64 + CGFloat(column) * cell.width, y: top + CGFloat(line) * cell.height)
                // 图标靠下放，上方留给 Zzz。对齐到整点，和真实桌面一样。
                let rect = CGRect(
                    x: (origin.x + (cell.width - size) / 2).rounded(), y: (origin.y + size * 0.3 + 6).rounded(),
                    width: size, height: size
                )
                let time = startTime + Double(frame) * step
                ExpressionSheet.drawFace(
                    state, on: icon, in: rect, iconAlpha: 1, renderer: renderer, context: ctx,
                    pixelsPerPoint: canvas.scale, time: time
                )
                SheetPaint.drawText(
                    String(format: "%.2f", Double(frame) * step), at: CGPoint(x: rect.midX, y: rect.maxY + 3),
                    size: 9.5, color: gray, alignment: .center, context: ctx
                )
            }
            top += CGFloat(lineCount) * cell.height + 14
        }
        return canvas
    }

    /// 出一条逐帧，写到 docs/样张/睡着-<名字>-逐帧.png。
    static func writeStrip(name: String, period: TimeInterval) throws -> URL {
        let url = try SampleOutput.directory().appendingPathComponent("睡着-\(name)-逐帧.png")
        try renderStrip(title: "\(name)：睡着的脸逐帧（文件夹图标、困意 100%）", period: period).writePNG(to: url)
        return url
    }

    // MARK: - 前后对比

    /// 把"省电前"的逐帧（事先出好的图）和现在的逐帧上下拼在一起。
    static func writeComparison() throws -> URL {
        let directory = try SampleOutput.directory()
        let beforeURL = directory.appendingPathComponent("睡着-省电前-逐帧.png")
        guard let source = CGImageSourceCreateWithURL(beforeURL as CFURL, nil),
              let before = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SampleError.cannotWrite("睡着-省电前-逐帧.png（找不到，先用旧代码出一条）")
        }
        let after = try renderStrip(title: "省电后：睡着的脸逐帧（文件夹图标、困意 100%）", period: breathPeriod)
        guard let afterImage = after.context.makeImage() else { throw SampleError.cannotCreateCanvas }

        // 两张都是 2x 的图：像素 ÷ 2 = 点。
        let beforeSize = CGSize(width: CGFloat(before.width) / 2, height: CGFloat(before.height) / 2)
        let afterSize = after.size
        let header: CGFloat = 92
        let gap: CGFloat = 20
        let size = CGSize(
            width: max(beforeSize.width, afterSize.width),
            height: header + beforeSize.height + gap + afterSize.height
        )
        guard let canvas = SheetCanvas(size: size, scale: 2) else { throw SampleError.cannotCreateCanvas }
        let ctx = canvas.context
        ctx.setFillColor(Tint.hex(0xF7F7F9))
        ctx.fill(CGRect(origin: .zero, size: size))
        let dark = NSColor(white: 0.12, alpha: 1)
        let gray = NSColor(white: 0.42, alpha: 1)
        SheetPaint.drawText(
            "「别删我」睡着的脸 · 省电前后", at: CGPoint(x: margin, y: 16), size: 22, weight: .bold, color: dark, context: ctx
        )
        SheetPaint.drawText(
            "同一张睡着的脸在一个完整起伏周期里，按各自的刷新间隔取的连续每一帧——屏幕上实际依次出现的画面。每帧下面的数字是从起点算的秒数。",
            at: CGPoint(x: margin, y: 48), size: 12, color: gray, context: ctx
        )
        SheetPaint.drawText(
            "本图 1 点 = 2 像素，按 100% 看就是 2x 屏上的实际大小。",
            at: CGPoint(x: margin, y: 66), size: 12, color: gray, context: ctx
        )
        func place(_ image: CGImage, at top: CGFloat, size: CGSize) {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: top + size.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(origin: .zero, size: size))
            ctx.restoreGState()
        }
        place(before, at: header, size: beforeSize)
        place(afterImage, at: header + beforeSize.height + gap, size: afterSize)

        let url = directory.appendingPathComponent("睡着-省电前后.png")
        try canvas.writePNG(to: url)
        return url
    }
}
