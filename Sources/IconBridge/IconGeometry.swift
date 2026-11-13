// IconBridge · 由访达给的位置推算图标的矩形（纯函数）
//
// 【锚点】访达的 desktop position 指的是**图标图像（那个边长为"图标大小"的方块）的中心**。
// 证据与校准方法见 docs/模块说明/icon-bridge.md 的"锚点"一节。
//
// 【标签】文字标签的矩形只能估算：访达不提供标签的尺寸。估算用到的常数集中在 `LabelMetrics`，
// 校准后要调整只改这一处。

import CoreGraphics
import CoreText
import DDMCore
import Foundation

/// 估算标签矩形用的常数。单位都是点，或"文字大小的倍数"。
///
/// "标签在下方"的几项已经用截图校准过（图标 64 点、文字 12 点，见 docs/模块说明/icon-bridge.md §3.3）：
/// 文字的实际笔画落在推算的矩形之内，四边各留 2.5～6.5 点。"标签在右侧"和别的字号仍是推算，没有校准。
struct LabelMetrics: Equatable, Sendable {
    /// 标签在下方时：图标图像下沿到标签上沿的间隙。
    /// （实测第一行字的笔画从图像下沿往下 9.5 点开始、高 11 点；一行 16 点高，所以这一行的上沿在 7 点处。）
    var gapBelowImage: CGFloat = 7
    /// 标签在右侧时：图标图像右沿到标签左沿的间隙。
    var gapBesideImage: CGFloat = 6
    /// 一行文字的高度 = 文字大小 × 这个倍数（12 点的字 16 点高——实测两行字的行距正是 16 点）。
    var lineHeightFactor: CGFloat = 4.0 / 3.0
    /// 标签文字左右各多出的留白（选中时的圆角底色比文字略宽）。
    var horizontalPadding: CGFloat = 4
    /// 标签在下方时，一行文字最宽 = 图标大小 + 这个值；超过就折成两行。
    /// （访达实际按"网格间距"决定；网格间距读不到，所以按默认间距 54 估。实测默认间距下折行后的字宽 106.5 点，在 110 点之内。）
    var maxTextWidthBeyondIcon: CGFloat = 46
    /// 标签在右侧时，一行文字最宽 = 图标大小 × 这个倍数。
    var maxTextWidthFactorBeside: CGFloat = 2.5
    /// 访达的标签最多显示几行（再长就在中间用省略号截断）。
    var maxLines = 2
    /// "显示项目简介"那一行小字的高度 = 文字大小 × 这个倍数。
    var itemInfoLineFactor: CGFloat = 1.25

    static let standard = LabelMetrics()
}

/// 图标矩形的推算。全部是纯函数，可在任何线程调用。
enum IconGeometry {
    /// 图标图像的矩形：以 desktop position 为中心、边长为图标大小的方块。
    ///
    ///     imageRect = (x − size/2, y − size/2, size, size)
    static func imageRect(position: CGPoint, iconSize: CGFloat) -> CGRect {
        CGRect(x: position.x - iconSize / 2, y: position.y - iconSize / 2, width: iconSize, height: iconSize)
    }

    /// 由图像矩形反推 desktop position（校准和测试用）。
    static func position(ofImageRect rect: CGRect) -> CGPoint {
        rect.center
    }

    /// 估算文字标签的矩形。
    ///
    /// - Parameters:
    ///   - textWidth: 名字用系统字体、按桌面的文字大小排成一行的宽度（点）。
    ///   - imageRect: 图标图像矩形。
    ///   - options: 桌面显示选项。
    static func labelRect(
        textWidth: CGFloat,
        imageRect: CGRect,
        options: DesktopViewOptions,
        metrics: LabelMetrics = .standard
    ) -> CGRect {
        let appearance = options.appearance
        let lineHeight = (appearance.textSize * metrics.lineHeightFactor).rounded()
        let maxTextWidth: CGFloat
        switch appearance.labelPosition {
        case .bottom: maxTextWidth = appearance.iconSize + metrics.maxTextWidthBeyondIcon
        case .right: maxTextWidth = appearance.iconSize * metrics.maxTextWidthFactorBeside
        }

        // 一行放得下就是一行；放不下折行，宽度按最宽算，行数不超过上限。
        let lines: Int
        let width: CGFloat
        if textWidth <= maxTextWidth {
            lines = 1
            width = max(textWidth, 0)
        } else {
            lines = min(metrics.maxLines, Int((textWidth / maxTextWidth).rounded(.up)))
            width = maxTextWidth
        }
        var height = CGFloat(lines) * lineHeight
        if options.showsItemInfo {
            height += (appearance.textSize * metrics.itemInfoLineFactor).rounded()
        }
        let paddedWidth = width + metrics.horizontalPadding * 2

        switch appearance.labelPosition {
        case .bottom:
            // 标签在图标正下方，水平居中。
            return CGRect(
                x: imageRect.midX - paddedWidth / 2,
                y: imageRect.maxY + metrics.gapBelowImage,
                width: paddedWidth,
                height: height
            )
        case .right:
            // 标签在图标右侧，垂直居中。
            return CGRect(
                x: imageRect.maxX + metrics.gapBesideImage,
                y: imageRect.midY - height / 2,
                width: paddedWidth,
                height: height
            )
        }
    }

    /// 图标算在哪块显示器上：先看锚点（图像中心）落在哪块屏；落在缝隙里就取与图像矩形相交最多的那块；
    /// 和哪块屏都不相交（例如显示器都睡了、或位置在所有屏之外）就是判断不出，返回 nil。
    static func displayID(for imageRect: CGRect, in layout: DisplayLayout) -> DisplayID? {
        if let display = layout.display(containing: imageRect.center) {
            return display.id
        }
        guard let best = layout.display(bestFor: imageRect), best.frame.intersects(imageRect) else {
            return nil
        }
        return best.id
    }
}

/// 量文字宽度：系统界面字体、指定字号、排成一行。用 Core Text，可在任何线程调用。
enum LabelTextMeasurer {
    static func width(of text: String, fontSize: CGFloat) -> CGFloat {
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}
