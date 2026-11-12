// FacesDemo · 出样张用的工具
//
// 离屏画布、写 PNG、系统自带的通用图标、仿墙纸的底、文字标注。
// 只在演示程序里用（这里可以用 AppKit：取系统图标、画文字）。
// 安全线：只取系统自带的通用图标，不读用户的任何文件；图片只写到工程的 docs/样张/ 里。

import AppKit
import CoreGraphics
import DDMCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 一块离屏画布：sRGB、y 向下、单位点——和叠加层交给表情模块的画布一致。
struct SheetCanvas {
    let context: CGContext
    /// 画布大小（点）。
    let size: CGSize
    /// 1 点等于几个像素。
    let scale: CGFloat

    init?(size: CGSize, scale: CGFloat) {
        let width = Int((size.width * scale).rounded(.up))
        let height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        // 位图画布默认原点在左下角、y 向上、单位像素；翻成 y 向下、单位点。
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        self.context = context
        self.size = size
        self.scale = scale
    }

    /// 存成 PNG。
    func writePNG(to url: URL) throws {
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL, UTType.png.identifier as CFString, 1, nil
              ) else { throw SampleError.cannotWrite(url.lastPathComponent) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw SampleError.cannotWrite(url.lastPathComponent) }
    }
}

enum SampleError: Error, CustomStringConvertible {
    case notAtProjectRoot
    case cannotCreateCanvas
    case cannotWrite(String)

    var description: String {
        switch self {
        case .notAtProjectRoot: "请在工程根目录（有 Package.swift 的那个文件夹）下运行。"
        case .cannotCreateCanvas: "创建离屏画布失败。"
        case let .cannotWrite(name): "写不了文件 \(name)。"
        }
    }
}

/// 样张的输出目录：工程根目录下的 docs/样张/。只往这里写。
enum SampleOutput {
    static func directory() throws -> URL {
        let files = FileManager.default
        let root = URL(fileURLWithPath: files.currentDirectoryPath)
        guard files.fileExists(atPath: root.appendingPathComponent("Package.swift").path),
              files.fileExists(atPath: root.appendingPathComponent("Sources/Faces").path) else {
            throw SampleError.notAtProjectRoot
        }
        let directory = root.appendingPathComponent("docs/样张", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// 一个做样张底图用的系统图标。
@MainActor
struct SampleIcon {
    /// 画在图标下面的假标签（仿访达的文件名位置），也用来标明这是哪种图标。
    let label: String
    let image: NSImage

    /// 三种系统自带的图标：文件夹（中等亮度、蓝色）、空白文稿（浅色）、终端（深色的应用图标）。
    /// 合起来覆盖"浅色、深色、有颜色"的底。
    static func standardSet() -> [SampleIcon] {
        let workspace = NSWorkspace.shared
        let terminal = "/System/Applications/Utilities/Terminal.app"
        let app = FileManager.default.fileExists(atPath: terminal)
            ? workspace.icon(forFile: terminal)
            : workspace.icon(for: .applicationBundle)
        return [
            SampleIcon(label: "文件夹", image: workspace.icon(for: .folder)),
            SampleIcon(label: "文稿", image: workspace.icon(for: .data)),
            SampleIcon(label: "应用", image: app),
        ]
    }

    /// 把图标画进 rect（y 向下的画布）。
    /// - Parameter pixelsPerPoint: 画布上 1 点对应几个像素，用来挑分辨率合适的那一版图标。
    func draw(in rect: CGRect, context: CGContext, pixelsPerPoint: CGFloat) {
        var proposed = CGRect(x: 0, y: 0, width: rect.width * pixelsPerPoint, height: rect.height * pixelsPerPoint)
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return }
        context.saveGState()
        // CGContext.draw 按"y 向上"贴图，这里局部翻回去，否则图标是倒的。
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
}

/// 样张上的底和文字。
@MainActor
enum SheetPaint {
    /// 一块代替墙纸的圆角底。浅色、深色各一种，用来检查画到图标外面的部分在两种墙纸上都看得清。
    /// 用纯色：大面积的浅渐变在 8 位色下会出现一道道色阶，反而干扰看图；纯色存成 PNG 也最小。
    static func drawWallpaper(in rect: CGRect, dark: Bool, context: CGContext) {
        context.saveGState()
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 14, cornerHeight: 14, transform: nil))
        context.setFillColor(dark ? Tint.hex(0x262B4A) : Tint.hex(0xDFE9F3))
        context.fillPath()
        context.restoreGState()
    }

    enum Alignment { case left, center }

    /// 写一行字。point 是这行字的左上角（left）或上边中点（center）。
    static func drawText(
        _ string: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular,
        color: NSColor, alignment: Alignment = .left, shadow: Bool = false, context: CGContext
    ) {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ]
        if shadow {
            // 仿访达桌面上的文件名：白字带一圈深色的影子。
            let dropShadow = NSShadow()
            dropShadow.shadowColor = NSColor(white: 0, alpha: 0.9)
            dropShadow.shadowBlurRadius = size * 0.28
            dropShadow.shadowOffset = NSSize(width: 0, height: -size * 0.08)
            attributes[.shadow] = dropShadow
        }
        let text = NSAttributedString(string: string, attributes: attributes)
        let width = text.size().width
        let origin = CGPoint(x: alignment == .center ? point.x - width / 2 : point.x, y: point.y)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        text.draw(at: origin)
        NSGraphicsContext.current = previous
    }
}
