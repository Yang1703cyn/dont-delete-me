// 「别删我」图标检查脚本：看图标装进应用之后，实际会显示成什么样，存成一张图。
//
// 它看两样东西：
//   1. 应用图标——问系统"这个应用的图标长什么样"。新版 macOS 不是原样显示 .icns 里的图，而是会按系统自己的
//      规格重新处理一遍（裁成系统的圆角形状、加一圈高光，小尺寸还会缩小并加一圈边）。这里取的是处理之后、
//      访达里会看到的样子。
//   2. 菜单栏图标——按应用加载它的同样方式来取（应用包里名为 MenuBarIcon 的资源，缩到 18 点高，当作模板图），
//      再分别按浅色、深色菜单栏的颜色画出来。菜单栏本身的样子是模拟的，真实效果仍要在菜单栏上看一眼。
//
// 用法（在工程根目录下执行）：
//
//     swift Assets/check_system_icon.swift <输出.png> <应用路径> [<应用路径> …]
//
// 例如打包之后看正式应用：
//
//     swift Assets/check_system_icon.swift Assets/预览/装进应用后的样子.png build/DontDeleteMe.app
//
// 脚本只读取给定应用里的图标，只写出指定的那一张图；不开窗口，不启动应用，不联网。

import AppKit
import CoreText

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else {
    print("用法：swift Assets/check_system_icon.swift <输出.png> <应用路径> [<应用路径> …]")
    exit(arguments.isEmpty ? 0 : 2)
}
let output = URL(fileURLWithPath: arguments[0])
let apps = Array(arguments.dropFirst())
for app in apps where !FileManager.default.fileExists(atPath: app) {
    print("找不到：\(app)")
    exit(1)
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: 1
    )
}

/// 与应用里 StatusMenuController 相同的做法：取名为 MenuBarIcon 的资源，缩到 18 点高，当作模板图。
func menuBarIcon(in app: String) -> NSImage? {
    guard let image = Bundle(path: app)?.image(forResource: "MenuBarIcon") else { return nil }
    if image.size.height > 0 {
        let scale = 18 / image.size.height
        image.size = NSSize(width: image.size.width * scale, height: 18)
    }
    image.isTemplate = true
    return image
}

/// 把模板图按给定的颜色画成位图。`scale` 是每点多少像素（普通屏 1，高清屏 2）。
func tinted(_ image: NSImage, scale: CGFloat, color: CGColor) -> CGImage {
    let width = Int((image.size.width * scale).rounded(.up)), height = Int((image.size.height * scale).rounded(.up))
    let bitmap = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
    image.draw(in: CGRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    // 只保留形状，颜色换成指定的。
    bitmap.setBlendMode(.sourceIn)
    bitmap.setFillColor(color)
    bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return bitmap.makeImage()!
}

// 版面（像素；y 向上）。每个应用两段：应用图标一段，菜单栏图标一段。
let margin: CGFloat = 40, chip: CGFloat = 300, gap: CGFloat = 20, header: CGFloat = 160
let iconSection: CGFloat = 370, menuSection: CGFloat = 330
let width = Int(margin * 2 + chip * 3 + gap * 2)
let height = Int(header + (iconSection + menuSection) * CGFloat(apps.count) + 20)
let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
context.setFillColor(rgb(0xF6F6F8))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))

func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, color: CGColor, bold: Bool = false) {
    let font = CTFontCreateWithName((bold ? "PingFangSC-Semibold" : "PingFangSC-Regular") as CFString, size, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    context.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes)), context)
}

func panel(_ rect: CGRect, _ color: CGColor) {
    context.addPath(CGPath(roundedRect: rect, cornerWidth: 18, cornerHeight: 18, transform: nil))
    context.setFillColor(color)
    context.fillPath()
}

/// 让系统按目标像素大小自己挑最合适的那一份来画。
func draw(_ icon: NSImage, in rect: CGRect) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
}

let ink = rgb(0x1D1D22), subtle = rgb(0x6B6B76)
let top = CGFloat(height)
text("图标装进应用之后的样子", x: margin, y: top - 62, size: 36, color: ink, bold: true)
text("由系统给出（macOS \(ProcessInfo.processInfo.operatingSystemVersionString)）。", x: margin, y: top - 100, size: 22, color: subtle)
text("应用图标：左、中是 256 像素（浅色底、深色底），右是 128 / 64 / 32 / 16 像素，都是原大。", x: margin, y: top - 132, size: 22, color: subtle)

for (index, app) in apps.enumerated() {
    let sectionTop = top - header - CGFloat(index) * (iconSection + menuSection)
    let name = (app as NSString).lastPathComponent

    // 1. 应用图标。
    let icon = NSWorkspace.shared.icon(forFile: app)
    text("\(name) · 应用图标", x: margin, y: sectionTop - 34, size: 26, color: ink, bold: true)
    let y = sectionTop - 50 - chip
    for (column, color) in [rgb(0xE9ECF2), rgb(0x1F2026)].enumerated() {
        let rect = CGRect(x: margin + CGFloat(column) * (chip + gap), y: y, width: chip, height: chip)
        panel(rect, color)
        draw(icon, in: CGRect(x: rect.midX - 128, y: rect.midY - 128, width: 256, height: 256))
    }
    let rect = CGRect(x: margin + 2 * (chip + gap), y: y, width: chip, height: chip)
    panel(rect, rgb(0xE9ECF2))
    var x = rect.minX + 12
    for size in [128, 64, 32, 16] as [CGFloat] {
        draw(icon, in: CGRect(x: x, y: rect.midY - size / 2, width: size, height: size))
        x += size + 12
    }

    // 2. 菜单栏图标。
    let menuTop = sectionTop - iconSection
    text("\(name) · 菜单栏图标", x: margin, y: menuTop - 34, size: 26, color: ink, bold: true)
    guard let menuIcon = menuBarIcon(in: app) else {
        text("这个应用里没有名为 MenuBarIcon 的资源（应用会改用系统符号占位）。", x: margin, y: menuTop - 80, size: 22, color: subtle)
        print("\(name)：应用图标已取到；没有菜单栏图标资源")
        continue
    }
    text(
        "每条从左到右：普通屏原大、高清屏原大、普通屏放大 4 倍、高清屏放大 2 倍。上：浅色菜单栏；下：深色菜单栏。",
        x: margin, y: menuTop - 66, size: 18, color: subtle
    )
    let bars: [(bar: CGColor, glyph: CGColor)] = [(rgb(0xECECEE), rgb(0x1D1D1F)), (rgb(0x2A2A2E), rgb(0xFFFFFF))]
    for (row, colors) in bars.enumerated() {
        let bar = CGRect(x: margin, y: menuTop - 84 - CGFloat(row + 1) * 112 + 12, width: CGFloat(width) - 2 * margin, height: 100)
        panel(bar, colors.bar)
        var x = bar.minX + 40
        for (scale, zoom) in [(1, 1), (2, 1), (1, 4), (2, 2)] as [(CGFloat, CGFloat)] {
            let image = tinted(menuIcon, scale: scale, color: colors.glyph)
            let w = CGFloat(image.width) * zoom, h = CGFloat(image.height) * zoom
            context.saveGState()
            context.interpolationQuality = zoom > 1 ? .none : .high
            context.draw(image, in: CGRect(x: x, y: bar.midY - h / 2, width: w, height: h))
            context.restoreGState()
            x += w + 70
        }
    }
    print("\(name)：应用图标已取到；菜单栏图标 \(menuIcon.size.width) × \(menuIcon.size.height) 点，模板图：\(menuIcon.isTemplate)")
}

guard let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil),
      let image = context.makeImage()
else {
    print("无法创建文件：\(output.path)")
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    print("写入失败：\(output.path)")
    exit(1)
}
print("已生成 \(output.path)（\(apps.count) 个应用）")
