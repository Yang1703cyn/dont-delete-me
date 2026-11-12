// IconBridgeDemo · 截图校准：desktop position 到底指图标的哪个点；推算的图像矩形、标签矩形准不准
//
// 运行：swift run IconBridgeDemo --calibrate
// 条件：屏幕亮着、已解锁，并且启动本程序的那个程序有"录屏与系统录音"权限（没有的话只说明情况，不会去申请）。
//
// 做法：在主屏空白处新建两个自己的临时文件（一个短名字、一个长名字），都设成洋红色纯色方块图标；
// 只截取访达桌面窗口里它们各自周围的一小块（不含别的图标），量出方块和文字实际画在哪，
// 再和图标桥由 desktop position 推算出来的矩形对比。截图只在内存里分析，不存盘。

import AppKit
import DDMCore
import Foundation
import IconBridge
import ScreenCaptureKit

@MainActor
final class Calibrate {
    private let shortName = "\(TestBench.namePrefix)1"
    private let longName = "\(TestBench.namePrefix)-这个名字故意起得很长很长用来看标签怎样折行和截断"

    /// 跳过"屏幕是否亮着、是否解锁"的预检，硬着头皮走完整个流程（只用来检查流程本身）。
    private let force: Bool

    init(force: Bool = false) {
        self.force = force
    }

    func run() -> Int32 {
        // —— 能不能截图 ——
        guard CGPreflightScreenCaptureAccess() else {
            say("做不了：启动本程序的那个程序没有\"录屏与系统录音\"权限。")
            printManualSteps()
            return 2
        }
        guard force || (!DisplayLayout.current().displays.isEmpty && !DemoDisplays.isScreenLocked) else {
            say("做不了：屏幕此刻\(DemoDisplays.isScreenLocked ? "锁着" : "睡着")。实测在这种状态下系统不给访达桌面窗口的画面（截出来是一张全透明的空图）。请解锁后再运行。")
            printManualSteps()
            return 2
        }

        let session = DemoSession(printsUpdates: false)
        session.start()
        defer { session.stop() }
        guard session.waitForFirstUpdate(timeout: 20), session.provider.status == .ok else {
            say("第一次读取没有成功，状态：\(statusName(session.provider.status))。中止。")
            return 1
        }
        let layout = DemoDisplays.layout()
        guard let display = layout.primary,
              case let spots = FreeSpot.find(count: 2, on: display, avoiding: session.provider.snapshot.icons), spots.count == 2
        else {
            say("主屏上找不到两个空位。中止。")
            return 1
        }
        say("桌面显示选项：\(describe(session.provider.appearance))。临时文件放在 \(format(spots[0])) 和 \(format(spots[1]))。")

        defer {
            say(TestBench.cleanUp() ? "清理：临时文件已删除。" : "清理：没能删除临时文件，请手动删除桌面上名字以「\(TestBench.namePrefix)」开头的文件。")
        }
        let magenta = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        do {
            try TestBench.createFile(named: shortName, at: spots[0])
            try TestBench.createFile(named: longName, at: spots[1])
        } catch {
            say("新建临时文件失败：\(error)")
            return 1
        }
        guard TestBench.setSolidIcon(of: shortName, color: magenta), TestBench.setSolidIcon(of: longName, color: magenta) else {
            say("给临时文件设置纯色图标失败（启动本程序的那个程序可能无权访问桌面文件夹）。中止。")
            return 1
        }
        // 等图标桥读到它们，也等访达把新图标画出来。
        let ready = pump(timeout: 8) {
            let icons = session.provider.snapshot.icons
            return spots.allSatisfy { spot in icons.contains { $0.imageRect.center == spot } }
        }
        guard ready else {
            say("图标桥没有在预定位置读到这两个临时文件。中止。")
            return 1
        }
        pump(2.0)

        // —— 截图 ——
        var captured: CGImage?
        var captureError: String?
        var finished = false
        Task {
            do {
                captured = try await Self.captureDesktopWindow(of: display)
            } catch {
                captureError = "\((error as NSError).domain) \((error as NSError).code)"
            }
            finished = true
        }
        pump(timeout: 30) { finished }
        guard let image = captured else {
            say("截图失败：\(captureError ?? "超时")。")
            printManualSteps()
            return 2
        }

        // —— 分析 ——
        var allGood = true
        for (title, spot) in [("短名字", spots[0]), ("长名字", spots[1])] {
            guard let icon = session.provider.snapshot.icons.first(where: { $0.imageRect.center == spot }) else { continue }
            // 只取这个图标周围的一小块：左右各 170 点，上 30 点，下 110 点。
            let region = icon.imageRect.insetBy(dx: -170, dy: 0).offsetBy(dx: 0, dy: 40).insetBy(dx: 0, dy: -70).intersection(display.frame)
            guard let bitmap = Self.bitmap(from: image, region: region, display: display) else {
                say("\(title)：取不出这一块像素。")
                allGood = false
                continue
            }
            let measured = AnchorCalibration.measure(bitmap, marker: (255, 0, 255))
            say("【\(title)】访达报告的 desktop position \(format(spot))")
            guard measured.opaquePixelCount > 0 else {
                say("  截到的是一张空图（没有任何不透明像素）：系统没有给出访达窗口的内容。")
                allGood = false
                continue
            }
            if let actual = measured.imageRect {
                let center = actual.center
                say(String(format: "  图标图像：推算 %@；实测 (%.1f,%.1f %.1f×%.1f)；实测中心 (%.1f,%.1f)，与 desktop position 相差 (%.1f,%.1f)", format(icon.imageRect), actual.minX, actual.minY, actual.width, actual.height, center.x, center.y, center.x - spot.x, center.y - spot.y))
                let good = abs(center.x - spot.x) <= 1 && abs(center.y - spot.y) <= 1 && abs(actual.width - icon.imageRect.width) <= 2 && abs(actual.height - icon.imageRect.height) <= 2
                say("  → \(good ? "锚点是图标图像的中心，推算的图像矩形与实测一致（误差 ≤ 1 点）" : "与推算不一致！请把以上数字交给总览")")
                if !good { allGood = false }
            } else {
                say("  没有找到洋红色方块（图标可能还没刷新出来，或被别的东西挡住）。")
                allGood = false
            }
            if let label = measured.labelRect, let predicted = icon.labelRect {
                say(String(format: "  文字标签：推算 (%.1f,%.1f %.1f×%.1f)；实测 (%.1f,%.1f %.1f×%.1f)；四边偏差 左 %.1f 上 %.1f 右 %.1f 下 %.1f", predicted.minX, predicted.minY, predicted.width, predicted.height, label.minX, label.minY, label.width, label.height, label.minX - predicted.minX, label.minY - predicted.minY, label.maxX - predicted.maxX, label.maxY - predicted.maxY))
            } else {
                say("  文字标签：没有量到。")
            }
        }
        say(allGood ? "校准结论：锚点与图像矩形的推算公式得到验证。标签矩形是估算，偏差见上（供调整 LabelMetrics 用）。" : "校准没有全部通过，见上。")
        return allGood ? 0 : 1
    }

    private func printManualSteps() {
        say("改用肉眼核对的步骤（等叠加层就绪后）：让叠加层在每个图标的 imageRect 上画一个半透明方块、在 labelRect 上画一个描边框，")
        say("看方块是否正好盖住图标图像、描边框是否大致框住名字；换一种图标大小 / 标签位置再看一遍。")
    }

    // MARK: 截图与取像素

    /// 截取访达在这块显示器上的桌面图标窗口（只这一个窗口，不含壁纸和其它窗口）。
    private static func captureDesktopWindow(of display: DisplayInfo) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let level = Int(CGWindowLevelForKey(.desktopIconWindow))
        guard let window = content.windows.first(where: {
            $0.owningApplication?.bundleIdentifier == "com.apple.finder" && $0.windowLayer == level && $0.frame == display.frame
        }) else {
            throw NSError(domain: "IconBridgeDemo.找不到访达的桌面图标窗口", code: 1)
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(display.frame.width * display.scale)
        configuration.height = Int(display.frame.height * display.scale)
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window),
            configuration: configuration
        )
    }

    /// 从整窗图像里取出 `region`（全局坐标）对应的那一块像素。
    private static func bitmap(from image: CGImage, region: CGRect, display: DisplayInfo) -> AnchorCalibration.Bitmap? {
        let scaleX = CGFloat(image.width) / display.frame.width
        let local = display.localRect(fromGlobal: region)
        let pixelRect = CGRect(x: (local.minX * scaleX).rounded(), y: (local.minY * scaleX).rounded(), width: (local.width * scaleX).rounded(), height: (local.height * scaleX).rounded())
        guard let cropped = image.cropping(to: pixelRect) else { return nil }
        let width = cropped.width, height = cropped.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let origin = display.globalPoint(fromLocal: CGPoint(x: pixelRect.minX / scaleX, y: pixelRect.minY / scaleX))
        return AnchorCalibration.Bitmap(width: width, height: height, rgba: pixels, scale: scaleX, origin: origin)
    }
}
