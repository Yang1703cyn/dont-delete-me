// FacesDemo · 风格提案样张
//
// 运行：swift run FacesDemo --style-proposal        （在工程根目录下）
// 产出（都在 docs/样张/ 里）：
//   风格提案.png                    三种风格 × 4 个关键表情 × 3 种图标，64 点 @2x，浅色、深色墙纸各一份
//   风格提案-细节-<风格>.png        每种风格放大 4 倍的细节图

import AppKit
import CoreGraphics
import DDMCore
import Foundation

@MainActor
enum StyleProposal {
    static let styles: [any ProposalStyle] = [GooglyStyle(), BeanStyle(), ActorStyle()]

    /// 一个关键表情：名字 + 表情参数。
    struct Expression {
        let name: String
        let state: (UInt64) -> FaceState
    }

    /// 4 个关键表情。参数就是情绪模块将来会给的那种值。
    static let expressions: [Expression] = [
        Expression(name: "平静 · 看鼠标") { seed in
            FaceState(mood: .calm, seed: seed, gazeTarget: CGVector(dx: 95, dy: 60), gazeFollow: 1)
        },
        Expression(name: "害羞") { seed in
            // 鼠标停在自己身上：脸红，眼睛躲向左下方。
            FaceState(mood: .shy, seed: seed, gazeTarget: CGVector(dx: -70, dy: 75), gazeFollow: 0.9, blush: 1)
        },
        Expression(name: "害怕 · 冒汗") { seed in
            // 正被拖向右下角的废纸篓：死盯着它，冒汗、发抖。
            FaceState(
                mood: .scared, seed: seed, gazeTarget: CGVector(dx: 260, dy: 190), gazeFollow: 1,
                fear: 0.85, sweat: 0.9, tremble: 0.7
            )
        },
        Expression(name: "大哭") { seed in
            FaceState(
                mood: .crying, seed: seed, gazeTarget: CGVector(dx: 40, dy: 120), gazeFollow: 0.5,
                fear: 0.45, tremble: 0.5, tears: 1
            )
        },
    ]

    /// 出样张时循环小动画停在哪一刻（秒）。挑了一个汗珠、泪珠都在画面里的时刻。
    static let stillTime: TimeInterval = 0.4

    // 排版（单位：点；细节图里整体放大 4 倍）。
    static let iconSize: CGFloat = 64
    static let cell = CGSize(width: 96, height: 104)
    static let iconInset = CGPoint(x: 16, y: 10)

    /// 生成全部样张，返回写出的文件。
    static func generate() throws -> [URL] {
        let directory = try SampleOutput.directory()
        let icons = SampleIcon.standardSet()
        var written: [URL] = []

        let overview = directory.appendingPathComponent("风格提案.png")
        try drawOverview(icons: icons).writePNG(to: overview)
        written.append(overview)

        for style in styles {
            let url = directory.appendingPathComponent("风格提案-细节-\(style.fileTag).png")
            try drawDetail(style: style, icons: icons).writePNG(to: url)
            written.append(url)
        }
        return written
    }

    /// 画一格：图标、脸、图标下面的假标签。
    /// - Parameter pixelsPerPoint: 画布上 1 点对应几个像素（含放大倍数），用来挑图标的分辨率。
    static func drawCell(
        at origin: CGPoint, icon: SampleIcon, iconIndex: Int, style: any ProposalStyle, expression: Expression,
        context: CGContext, pixelsPerPoint: CGFloat
    ) {
        let iconRect = CGRect(x: origin.x + iconInset.x, y: origin.y + iconInset.y, width: iconSize, height: iconSize)
        icon.draw(in: iconRect, context: context, pixelsPerPoint: pixelsPerPoint)
        SheetPaint.drawText(
            icon.label, at: CGPoint(x: iconRect.midX, y: iconRect.maxY + 3), size: 12, weight: .medium,
            color: .white, alignment: .center, shadow: true, context: context
        )
        // 每种图标一个固定的长相种子：同一种图标在三种风格里用同一个种子。
        let seed = IconID(rawValue: UInt64(iconIndex + 1)).faceSeed
        style.draw(expression.state(seed), in: iconRect, context: context, time: stillTime)
    }

    // MARK: - 总对比图

    private static func drawOverview(icons: [SampleIcon]) throws -> SheetCanvas {
        let margin: CGFloat = 24
        let blockGap: CGFloat = 20
        let blockWidth = cell.width * CGFloat(expressions.count)
        let width = margin * 2 + blockWidth * CGFloat(styles.count) + blockGap * CGFloat(styles.count - 1)
        let panelHeight = cell.height * CGFloat(icons.count) + 12
        let firstPanelTop: CGFloat = 152
        let panelGap: CGFloat = 34
        let height = firstPanelTop + panelHeight * 2 + panelGap + 40

        guard let canvas = SheetCanvas(size: CGSize(width: width, height: height), scale: 2) else {
            throw SampleError.cannotCreateCanvas
        }
        let ctx = canvas.context
        ctx.setFillColor(Tint.hex(0xF7F7F9))
        ctx.fill(CGRect(origin: .zero, size: canvas.size))

        let dark = NSColor(white: 0.12, alpha: 1)
        let gray = NSColor(white: 0.42, alpha: 1)
        SheetPaint.drawText(
            "「别删我」表情风格提案", at: CGPoint(x: margin, y: 16), size: 20, weight: .bold, color: dark, context: ctx
        )
        SheetPaint.drawText(
            "三种风格 × 4 个关键表情 × 3 种系统图标 · 图标 64 点、2x（本图 1 点 = 2 像素，按 100% 看就是实际大小）",
            at: CGPoint(x: margin, y: 44), size: 12, color: gray, context: ctx
        )

        func blockX(_ index: Int) -> CGFloat { margin + (blockWidth + blockGap) * CGFloat(index) }

        for (index, style) in styles.enumerated() {
            SheetPaint.drawText(
                style.title, at: CGPoint(x: blockX(index) + 6, y: 76), size: 17, weight: .bold, color: dark,
                context: ctx
            )
            SheetPaint.drawText(
                style.tagline, at: CGPoint(x: blockX(index) + 6, y: 100), size: 11.5, color: gray, context: ctx
            )
        }

        for (panelIndex, isDark) in [false, true].enumerated() {
            let top = firstPanelTop + (panelHeight + panelGap) * CGFloat(panelIndex)
            // 每块墙纸上方：这一列是哪个表情。
            for styleIndex in styles.indices {
                for (column, expression) in expressions.enumerated() {
                    SheetPaint.drawText(
                        expression.name,
                        at: CGPoint(x: blockX(styleIndex) + cell.width * (CGFloat(column) + 0.5), y: top - 19),
                        size: 11, weight: .medium, color: gray, alignment: .center, context: ctx
                    )
                }
            }
            for styleIndex in styles.indices {
                let panel = CGRect(x: blockX(styleIndex), y: top, width: blockWidth, height: panelHeight)
                SheetPaint.drawWallpaper(in: panel, dark: isDark, context: ctx)
                for (row, icon) in icons.enumerated() {
                    for (column, expression) in expressions.enumerated() {
                        drawCell(
                            at: CGPoint(
                                x: panel.minX + cell.width * CGFloat(column),
                                y: panel.minY + 6 + cell.height * CGFloat(row)
                            ),
                            icon: icon, iconIndex: row, style: styles[styleIndex], expression: expression,
                            context: ctx, pixelsPerPoint: canvas.scale
                        )
                    }
                }
            }
        }
        SheetPaint.drawText(
            "上：浅色墙纸　下：深色墙纸　　图标下面的白字仿的是访达的文件名位置（眼泪会流到那里）。纯代码绘制，无图片素材。",
            at: CGPoint(x: margin, y: height - 26), size: 11, color: gray, context: ctx
        )
        return canvas
    }

    // MARK: - 细节图（放大 4 倍）

    private static func drawDetail(style: any ProposalStyle, icons: [SampleIcon]) throws -> SheetCanvas {
        let zoom: CGFloat = 4
        let margin: CGFloat = 24
        let headerHeight: CGFloat = 104
        let panelGap: CGFloat = 16
        let gridWidth = cell.width * CGFloat(expressions.count) * zoom
        let lightHeight = (cell.height * CGFloat(icons.count) + 6) * zoom
        let darkHeight = (cell.height + 6) * zoom
        let size = CGSize(
            width: margin * 2 + gridWidth,
            height: headerHeight + lightHeight + panelGap + darkHeight + margin
        )
        guard let canvas = SheetCanvas(size: size, scale: 2) else { throw SampleError.cannotCreateCanvas }
        let ctx = canvas.context
        ctx.setFillColor(Tint.hex(0xF7F7F9))
        ctx.fill(CGRect(origin: .zero, size: size))

        let dark = NSColor(white: 0.12, alpha: 1)
        let gray = NSColor(white: 0.42, alpha: 1)
        SheetPaint.drawText(
            "\(style.title) · 放大 4 倍", at: CGPoint(x: margin, y: 14), size: 26, weight: .bold, color: dark,
            context: ctx
        )
        SheetPaint.drawText(
            "\(style.tagline)。与总对比图是同一套画法（64 点图标），只是整体放大 4 倍来看细节。最下面一排换成深色墙纸。",
            at: CGPoint(x: margin, y: 50), size: 14, color: gray, context: ctx
        )
        for (column, expression) in expressions.enumerated() {
            SheetPaint.drawText(
                expression.name,
                at: CGPoint(x: margin + cell.width * zoom * (CGFloat(column) + 0.5), y: headerHeight - 26),
                size: 16, weight: .semibold, color: dark, alignment: .center, context: ctx
            )
        }

        let lightPanel = CGRect(x: margin, y: headerHeight, width: gridWidth, height: lightHeight)
        let darkPanel = CGRect(x: margin, y: lightPanel.maxY + panelGap, width: gridWidth, height: darkHeight)
        SheetPaint.drawWallpaper(in: lightPanel, dark: false, context: ctx)
        SheetPaint.drawWallpaper(in: darkPanel, dark: true, context: ctx)

        // 一排的内容：在放大 4 倍的坐标系里，按和总对比图完全相同的尺寸画。
        func drawRow(top: CGFloat, icon: SampleIcon, iconIndex: Int) {
            ctx.saveGState()
            ctx.translateBy(x: margin, y: top)
            ctx.scaleBy(x: zoom, y: zoom)
            for (column, expression) in expressions.enumerated() {
                drawCell(
                    at: CGPoint(x: cell.width * CGFloat(column), y: 3),
                    icon: icon, iconIndex: iconIndex, style: style, expression: expression,
                    context: ctx, pixelsPerPoint: canvas.scale * zoom
                )
            }
            ctx.restoreGState()
        }
        for (row, icon) in icons.enumerated() {
            drawRow(top: lightPanel.minY + cell.height * zoom * CGFloat(row), icon: icon, iconIndex: row)
        }
        drawRow(top: darkPanel.minY, icon: icons[0], iconIndex: 0)
        return canvas
    }
}
