// FacesDemo · 全表情样张
//
// 运行：swift run FacesDemo --sheets        （在工程根目录下）
// 产出：docs/样张/全表情.png
//   上半：8 种表情 × 4 档强度 × 3 种系统图标（64 点 @2x），外加一行几种情绪掺在一起的中间状态。
//         文件夹、应用在浅色底上，文稿在深色底上，
//         这样画到图标外面的泪、Zzz、幽灵在浅色和深色墙纸上都能看到。
//   下半：32 / 64 / 128 点三种大小的对比——先是 2x，再是 1x（1x 的每个像素放大成 2×2，看的是真实像素）。

import AppKit
import CoreGraphics
import DDMCore
import Faces
import Foundation

@MainActor
enum ExpressionSheet {
    /// 出样张时循环小动画停在哪一刻（秒）。
    static let stillTime: TimeInterval = 0.4

    /// 样张上的一行：一种表情的 4 个变化。
    struct Row {
        let title: String
        let caption: String
        let variants: [(UInt64) -> FaceState]
        /// 这一行是不是幽灵（图标已经不在了，上方要多留地方）。
        var isGhost = false
    }

    static let rows: [Row] = {
        func levels(_ preset: ExpressionPreset, gaze: CGVector = .zero) -> [(UInt64) -> FaceState] {
            [0.25, 0.5, 0.75, 1.0].map { level in { seed in preset.state(seed: seed, intensity: level, gaze: gaze) } }
        }
        let trash = CGVector(dx: 260, dy: 190)
        return [
            Row(title: "1 平静", caption: "看左上 · 看右下 · 鼠标很近（对眼）· 眨眼到一半", variants: [
                { seed in ExpressionPreset.calm.state(seed: seed, intensity: 0, gaze: CGVector(dx: -150, dy: -110)) },
                { seed in ExpressionPreset.calm.state(seed: seed, intensity: 0, gaze: CGVector(dx: 95, dy: 60)) },
                { seed in ExpressionPreset.calm.state(seed: seed, intensity: 0, gaze: CGVector(dx: 0, dy: 3)) },
                { seed in
                    var state = ExpressionPreset.calm.state(seed: seed, intensity: 0, gaze: CGVector(dx: 95, dy: 60))
                    state.blink = 0.6
                    return state
                },
            ]),
            Row(title: "2 害羞", caption: "脸红 25% · 50% · 75% · 100%，眼神躲开", variants: levels(.shy)),
            Row(title: "3 头晕", caption: "头晕 25% · 50% · 75% · 100%", variants: levels(.dizzy)),
            Row(title: "4 害怕", caption: "惊恐 = 汗 25% · 50% · 75% · 100%，发抖随之加重", variants: levels(.scared, gaze: trash)),
            Row(title: "5 哭", caption: "泪 25%（泪汪汪）· 50% · 75% · 100%（眼泪直流）", variants: levels(.crying, gaze: CGVector(dx: 40, dy: 120))),
            Row(title: "6 捂眼", caption: "手抬起 35% · 70% · 100% · 100% 且从指缝偷看", variants: [
                { seed in ExpressionPreset.coveringEyes.state(seed: seed, intensity: 0.35, gaze: trash) },
                { seed in ExpressionPreset.coveringEyes.state(seed: seed, intensity: 0.7, gaze: trash) },
                { seed in ExpressionPreset.coveringEyes.state(seed: seed, intensity: 1, gaze: trash) },
                { seed in ExpressionPreset.coveringEyes.state(seed: seed, intensity: 1, gaze: trash, peek: 1) },
            ]),
            Row(title: "7 打瞌睡", caption: "困意 25% · 50% · 75% · 100%（睡熟）", variants: levels(.dozing, gaze: CGVector(dx: 95, dy: 60))),
            Row(title: "8 幽灵", caption: "进度 10% · 35% · 60% · 85%（图标已被删，淡影只是标出原来的位置）", variants: [
                { seed in ExpressionPreset.ghost.state(seed: seed, intensity: 0.1) },
                { seed in ExpressionPreset.ghost.state(seed: seed, intensity: 0.35) },
                { seed in ExpressionPreset.ghost.state(seed: seed, intensity: 0.6) },
                { seed in ExpressionPreset.ghost.state(seed: seed, intensity: 0.85) },
            ], isGhost: true),
            // 几种情绪掺在一起的中间状态：参数是连续的，哪种组合都得是一张成立的脸。
            Row(title: "混合", caption: "害怕 30% + 困意 60% · 害羞 60% + 害怕 40% · 头晕 50% + 泪 55% · 捂眼 45% + 泪 70%", variants: [
                { seed in
                    var state = FaceState(mood: .dozing, seed: seed, gazeTarget: CGVector(dx: 95, dy: 60), gazeFollow: 0.5)
                    state.fear = 0.3
                    state.sleepiness = 0.6
                    return state
                },
                { seed in
                    var state = FaceState(mood: .shy, seed: seed, gazeTarget: CGVector(dx: -70, dy: 75), gazeFollow: 1)
                    state.blush = 0.6
                    state.fear = 0.4
                    state.sweat = 0.4
                    return state
                },
                { seed in
                    var state = FaceState(mood: .dizzy, seed: seed)
                    state.dizziness = 0.5
                    state.tears = 0.55
                    return state
                },
                { seed in
                    var state = FaceState(mood: .coveringEyes, seed: seed, gazeTarget: trash, gazeFollow: 1)
                    state.cover = 0.45
                    state.tears = 0.7
                    state.fear = 0.5
                    return state
                },
            ]),
        ]
    }()

    /// 大小对比里每种表情用的那一个状态（都取比较强的一档）。
    static let sizeSamples: [(title: String, state: (UInt64) -> FaceState)] = [
        ("平静", { seed in ExpressionPreset.calm.state(seed: seed, intensity: 0, gaze: CGVector(dx: 95, dy: 60)) }),
        ("害羞", { seed in ExpressionPreset.shy.state(seed: seed, intensity: 1) }),
        ("头晕", { seed in ExpressionPreset.dizzy.state(seed: seed, intensity: 1) }),
        ("害怕", { seed in ExpressionPreset.scared.state(seed: seed, intensity: 0.85, gaze: CGVector(dx: 260, dy: 190)) }),
        ("哭", { seed in ExpressionPreset.crying.state(seed: seed, intensity: 1, gaze: CGVector(dx: 40, dy: 120)) }),
        ("捂眼", { seed in ExpressionPreset.coveringEyes.state(seed: seed, intensity: 1, peek: 0.8) }),
        ("打瞌睡", { seed in ExpressionPreset.dozing.state(seed: seed, intensity: 1) }),
        ("幽灵", { seed in ExpressionPreset.ghost.state(seed: seed, intensity: 0.3) }),
    ]

    static func generate() throws -> [URL] {
        let directory = try SampleOutput.directory()
        let url = directory.appendingPathComponent("全表情.png")
        try draw(icons: SampleIcon.standardSet()).writePNG(to: url)
        return [url]
    }

    // 排版（点）。
    private static let iconSize: CGFloat = 64
    private static let cellWidth: CGFloat = 86
    private static let rowHeight: CGFloat = 108
    private static let ghostRowHeight: CGFloat = 152
    private static let margin: CGFloat = 24
    private static let labelColumn: CGFloat = 156
    private static let groupGap: CGFloat = 16

    private static func draw(icons: [SampleIcon]) throws -> SheetCanvas {
        let renderer = FaceRenderer()
        let groupWidth = cellWidth * 4
        let gridLeft = margin + labelColumn
        let width = gridLeft + groupWidth * CGFloat(icons.count) + groupGap * CGFloat(icons.count - 1) + margin
        let gridTop: CGFloat = 104
        let gridHeight = rows.map { $0.isGhost ? ghostRowHeight : rowHeight }.reduce(0, +) + 12

        // 大小对比：每个大小一行，行高跟着大小走（上方留给 Zzz，下方留给眼泪）。
        let sizes: [CGFloat] = [32, 64, 128]
        func sizeRowHeight(_ size: CGFloat) -> CGFloat { size * 1.55 + 16 }
        let bandHeight = sizes.map(sizeRowHeight).reduce(0, +) + 12
        let sizeTop = gridTop + gridHeight + 96
        let height = sizeTop + bandHeight * 2 + 46 + 44

        guard let canvas = SheetCanvas(size: CGSize(width: width, height: height), scale: 2) else {
            throw SampleError.cannotCreateCanvas
        }
        let ctx = canvas.context
        ctx.setFillColor(Tint.hex(0xF7F7F9))
        ctx.fill(CGRect(origin: .zero, size: canvas.size))
        let dark = NSColor(white: 0.12, alpha: 1)
        let gray = NSColor(white: 0.42, alpha: 1)

        SheetPaint.drawText(
            "「别删我」全表情样张 · 风格「大眼小嘴」", at: CGPoint(x: margin, y: 16), size: 20, weight: .bold,
            color: dark, context: ctx
        )
        SheetPaint.drawText(
            "8 种表情 × 4 档 × 3 种系统图标 · 图标 64 点、2x（本图 1 点 = 2 像素，按 100% 看就是实际大小）· 纯代码绘制",
            at: CGPoint(x: margin, y: 44), size: 12, color: gray, context: ctx
        )

        // 三组：文件夹（浅色底）、文稿（深色底）、应用（浅色底）。
        let groupIsDark = [false, true, false]
        func groupX(_ index: Int) -> CGFloat { gridLeft + (groupWidth + groupGap) * CGFloat(index) }
        for (index, icon) in icons.enumerated() {
            let isDark = groupIsDark[index % groupIsDark.count]
            SheetPaint.drawText(
                "\(icon.label) · \(isDark ? "深色墙纸" : "浅色墙纸")",
                at: CGPoint(x: groupX(index) + groupWidth / 2, y: gridTop - 24), size: 13, weight: .semibold,
                color: dark, alignment: .center, context: ctx
            )
            SheetPaint.drawWallpaper(
                in: CGRect(x: groupX(index), y: gridTop, width: groupWidth, height: gridHeight),
                dark: isDark, context: ctx
            )
        }

        var top = gridTop + 6
        for row in rows {
            let thisHeight = row.isGhost ? ghostRowHeight : rowHeight
            let iconTop = top + thisHeight - 26 - iconSize
            SheetPaint.drawText(
                row.title, at: CGPoint(x: margin, y: iconTop + 8), size: 15, weight: .bold, color: dark, context: ctx
            )
            drawWrapped(row.caption, at: CGPoint(x: margin, y: iconTop + 30), width: labelColumn - 14, color: gray, context: ctx)
            for (groupIndex, icon) in icons.enumerated() {
                let seed = IconID(rawValue: UInt64(groupIndex + 1)).faceSeed
                for (column, variant) in row.variants.enumerated() {
                    let rect = CGRect(
                        x: groupX(groupIndex) + cellWidth * CGFloat(column) + (cellWidth - iconSize) / 2,
                        y: iconTop, width: iconSize, height: iconSize
                    )
                    drawFace(
                        variant(seed), on: icon, in: rect, iconAlpha: row.isGhost ? 0.16 : 1,
                        renderer: renderer, context: ctx, pixelsPerPoint: canvas.scale
                    )
                }
            }
            top += thisHeight
        }

        // 大小对比。
        SheetPaint.drawText(
            "大小对比：32 / 64 / 128 点", at: CGPoint(x: margin, y: sizeTop - 72), size: 17, weight: .bold,
            color: dark, context: ctx
        )
        SheetPaint.drawText(
            "上：2x（内屏）。下：1x（普通外接屏）——把每个像素放大成 2×2 来看真实像素，所以显得有颗粒。中等亮度的底色是第三种墙纸。",
            at: CGPoint(x: margin, y: sizeTop - 46), size: 12, color: gray, context: ctx
        )
        let sampleLeft = margin + 62
        let sampleWidth = (width - margin - sampleLeft) / CGFloat(sizeSamples.count)
        let icon = icons[0]
        let seed = IconID(rawValue: 1).faceSeed

        for (bandIndex, pixelScale) in [CGFloat(2), 1].enumerated() {
            let bandTop = sizeTop + (bandHeight + 46) * CGFloat(bandIndex)
            let band = CGRect(x: margin, y: bandTop, width: width - margin * 2, height: bandHeight)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: band, cornerWidth: 14, cornerHeight: 14, transform: nil))
            ctx.setFillColor(Tint.hex(0x7C8FC4))
            ctx.fillPath()
            ctx.restoreGState()
            if bandIndex == 0 {
                for (column, sample) in sizeSamples.enumerated() {
                    SheetPaint.drawText(
                        sample.title, at: CGPoint(x: sampleLeft + sampleWidth * (CGFloat(column) + 0.5), y: bandTop - 20),
                        size: 12, weight: .medium, color: gray, alignment: .center, context: ctx
                    )
                }
            }

            // 这一带先画在一块同样大小、按 pixelScale 出图的画布上，再贴回来：
            // 1x 的那一带用"最近邻"放大，每个像素变成 2×2，不做平滑。
            guard let layer = SheetCanvas(size: band.size, scale: pixelScale) else { throw SampleError.cannotCreateCanvas }
            var rowTop: CGFloat = 6
            for size in sizes {
                let rowHeight = sizeRowHeight(size)
                for (column, sample) in sizeSamples.enumerated() {
                    // 对齐到整点：1x 下图标边缘才落在像素边界上，和真实桌面一样。
                    let rect = CGRect(
                        x: (sampleLeft - margin + sampleWidth * (CGFloat(column) + 0.5) - size / 2).rounded(),
                        y: (rowTop + size * 0.27).rounded(), width: size, height: size
                    )
                    let state = sample.state(seed)
                    drawFace(
                        state, on: icon, in: rect, iconAlpha: state.mood == .ghost ? 0.16 : 1,
                        renderer: renderer, context: layer.context, pixelsPerPoint: pixelScale
                    )
                }
                rowTop += rowHeight
            }
            if let image = layer.context.makeImage() {
                ctx.saveGState()
                ctx.interpolationQuality = .none
                ctx.translateBy(x: band.minX, y: band.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(image, in: CGRect(origin: .zero, size: band.size))
                ctx.restoreGState()
            }
            rowTop = 6
            for size in sizes {
                SheetPaint.drawText(
                    "\(Int(size)) 点", at: CGPoint(x: margin + 10, y: bandTop + rowTop + size * 0.27 + size / 2 - 8),
                    size: 12, weight: .semibold, color: .white, context: ctx
                )
                SheetPaint.drawText(
                    pixelScale == 2 ? "@2x" : "@1x", at: CGPoint(x: margin + 10, y: bandTop + rowTop + size * 0.27 + size / 2 + 8),
                    size: 10, color: NSColor(white: 1, alpha: 0.8), context: ctx
                )
                rowTop += sizeRowHeight(size)
            }
        }
        return canvas
    }

    /// 画一个图标和它的脸。
    /// - Parameter iconAlpha: 图标的不透明度（幽灵那一行图标已经被删了，只画一个淡影标出原位）。
    /// - Parameter time: 循环小动画停在哪一刻；默认是样张统一用的 `stillTime`。
    static func drawFace(
        _ state: FaceState, on icon: SampleIcon, in rect: CGRect, iconAlpha: CGFloat, renderer: FaceRenderer,
        context: CGContext, pixelsPerPoint: CGFloat, time: TimeInterval = stillTime
    ) {
        context.saveGState()
        context.setAlpha(iconAlpha)
        icon.draw(in: rect, context: context, pixelsPerPoint: pixelsPerPoint)
        context.restoreGState()
        // 和叠加层一样：把绘制裁在"图标矩形 + 声明的外扩"里。超出的部分在真实桌面上会被裁掉，样张上也一样。
        context.saveGState()
        context.clip(to: rect.expanded(by: renderer.outsets(for: state, iconSize: rect.size)))
        renderer.draw(state, in: rect, context: context, time: time)
        context.restoreGState()
    }

    /// 按给定宽度折行写一段小字。
    private static func drawWrapped(_ string: String, at point: CGPoint, width: CGFloat, color: NSColor, context: CGContext) {
        let text = NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: color,
        ])
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        text.draw(with: CGRect(x: point.x, y: point.y, width: width, height: 80), options: [.usesLineFragmentOrigin])
        NSGraphicsContext.current = previous
    }
}
