// IconBridge · 锚点校准用的像素分析（纯函数）
//
// 校准的做法（演示程序 `IconBridgeDemo --calibrate`）：在桌面空白处放一个自己的临时文件，给它设一个纯色方块图标，
// 截下访达桌面窗口里它周围的一小块，然后在这里量出：纯色方块（= 图标图像）实际画在哪、其余不透明像素（= 文字标签）在哪。
// 再和"由 desktop position 推算出来的矩形"对比，就知道锚点和推算公式对不对。
// 分析本身不碰屏幕，所以可以用合成的位图做单元测试。

import CoreGraphics
import Foundation

public enum AnchorCalibration {
    /// 一小块截图。
    public struct Bitmap: Sendable {
        /// 像素宽、高。
        public var width: Int
        public var height: Int
        /// 每像素 4 字节：红、绿、蓝、不透明度（预乘）。第 0 行是最上面一行。
        public var rgba: [UInt8]
        /// 1 点等于几个像素。
        public var scale: CGFloat
        /// 左上角像素对应的全局坐标（点）。
        public var origin: CGPoint

        public init(width: Int, height: Int, rgba: [UInt8], scale: CGFloat, origin: CGPoint) {
            precondition(rgba.count == width * height * 4, "像素数据的长度应为 宽 × 高 × 4")
            self.width = width
            self.height = height
            self.rgba = rgba
            self.scale = scale
            self.origin = origin
        }
    }

    /// 量出来的结果（全局坐标，点）。
    public struct Measurement: Equatable, Sendable {
        /// 纯色方块（图标图像）的外接矩形；没找到为 nil。
        public var imageRect: CGRect?
        /// 方块之外其余不透明像素（文字标签）的外接矩形；没找到为 nil。
        public var labelRect: CGRect?
        /// 位图里一共有多少不透明像素。为 0 说明截到的是一张空图（例如锁屏时系统不给窗口内容）。
        public var opaquePixelCount: Int
    }

    /// 在位图里找标记色的方块和其余不透明的像素。
    ///
    /// - Parameters:
    ///   - marker: 标记色（红、绿、蓝，0…255）。
    ///   - tolerance: 每个颜色分量允许的偏差。
    public static func measure(
        _ bitmap: Bitmap,
        marker: (red: UInt8, green: UInt8, blue: UInt8),
        tolerance: Int = 60
    ) -> Measurement {
        var markerBox = PixelBox()
        var opaqueCount = 0

        // 第一遍：标记色方块。
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width {
                let index = (y * bitmap.width + x) * 4
                let alpha = Int(bitmap.rgba[index + 3])
                if alpha > 24 { opaqueCount += 1 }
                guard alpha > 200 else { continue }
                let matches = abs(Int(bitmap.rgba[index]) - Int(marker.red)) <= tolerance
                    && abs(Int(bitmap.rgba[index + 1]) - Int(marker.green)) <= tolerance
                    && abs(Int(bitmap.rgba[index + 2]) - Int(marker.blue)) <= tolerance
                if matches { markerBox.include(x: x, y: y) }
            }
        }

        // 第二遍：方块外接矩形之外、足够不透明的像素（文字；阈值取一半，避开文字淡淡的投影）。
        var labelBox = PixelBox()
        if !markerBox.isEmpty {
            for y in 0..<bitmap.height {
                for x in 0..<bitmap.width where !markerBox.contains(x: x, y: y, margin: 2) {
                    if bitmap.rgba[(y * bitmap.width + x) * 4 + 3] > 128 {
                        labelBox.include(x: x, y: y)
                    }
                }
            }
        }

        return Measurement(
            imageRect: markerBox.rect(scale: bitmap.scale, origin: bitmap.origin),
            labelRect: labelBox.rect(scale: bitmap.scale, origin: bitmap.origin),
            opaquePixelCount: opaqueCount
        )
    }

    /// 像素坐标里的外接框。
    private struct PixelBox {
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min

        var isEmpty: Bool { maxX < minX }

        mutating func include(x: Int, y: Int) {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }

        func contains(x: Int, y: Int, margin: Int) -> Bool {
            !isEmpty && x >= minX - margin && x <= maxX + margin && y >= minY - margin && y <= maxY + margin
        }

        func rect(scale: CGFloat, origin: CGPoint) -> CGRect? {
            guard !isEmpty else { return nil }
            return CGRect(
                x: origin.x + CGFloat(minX) / scale,
                y: origin.y + CGFloat(minY) / scale,
                width: CGFloat(maxX - minX + 1) / scale,
                height: CGFloat(maxY - minY + 1) / scale
            )
        }
    }
}
