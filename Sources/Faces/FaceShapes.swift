// Faces · 形状：往路径里添加水滴、眼眶、星星、手
//
// 都是"往一条现成的路径里加一块"，方便把同色的东西攒在一起一次画完。

import CoreGraphics
import Foundation

enum FaceShapes {
    /// 水滴（汗珠、泪珠）：圆底、尖朝上；`tilt` 是把它转过去的角度。
    /// 半径太小就不画——循环小动画里水滴是靠"缩没"来消失的。
    /// - Parameters:
    ///   - glints: 够大的水滴会在这条路径里加一道高光短线。
    ///   - center: 圆底的圆心。
    static func addDrop(
        to path: CGMutablePath, glints: CGMutablePath, center: CGPoint, radius r: CGFloat, tilt: CGFloat, u: CGFloat
    ) {
        guard r > 0.25 * u else { return }
        let tip = r * 2.0
        let transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: tilt)
        path.move(to: CGPoint(x: 0, y: -tip), transform: transform)
        path.addCurve(
            to: CGPoint(x: r, y: 0),
            control1: CGPoint(x: r * 0.2, y: -tip * 0.55), control2: CGPoint(x: r, y: -r * 0.75),
            transform: transform
        )
        // 画布 y 向下：角度从 0 增加到 π，经过的是圆的下半边。
        path.addArc(center: .zero, radius: r, startAngle: 0, endAngle: .pi, clockwise: false, transform: transform)
        path.addCurve(
            to: CGPoint(x: 0, y: -tip),
            control1: CGPoint(x: -r, y: -r * 0.75), control2: CGPoint(x: -r * 0.2, y: -tip * 0.55),
            transform: transform
        )
        path.closeSubpath()

        if r > 1.1 * u {
            glints.move(to: CGPoint(x: -r * 0.34, y: -r * 0.35), transform: transform)
            glints.addLine(to: CGPoint(x: -r * 0.34, y: r * 0.1), transform: transform)
        }
    }

    /// 眼眶里睁开的那一块：椭圆被上、下眼皮各切掉一段。
    static func addEyeOpening(to path: CGMutablePath, eye: FacePose.Eye) {
        // 在单位圆上算，再用变换拉成椭圆。
        let transform = CGAffineTransform(translationX: eye.center.x, y: eye.center.y).scaledBy(x: eye.rx, y: eye.ry)
        let top = min(max((eye.top - eye.center.y) / eye.ry, -1), 1)
        let bottom = min(max((eye.bottom - eye.center.y) / eye.ry, -1), 1)
        let topAngle = asin(top)
        let bottomAngle = asin(bottom)
        path.move(to: CGPoint(x: -cos(topAngle), y: top), transform: transform)
        path.addLine(to: CGPoint(x: cos(topAngle), y: top), transform: transform)
        // 右半边：从上眼皮沿眼眶到下眼皮。
        path.addArc(
            center: .zero, radius: 1, startAngle: topAngle, endAngle: bottomAngle, clockwise: false,
            transform: transform
        )
        path.addLine(to: CGPoint(x: -cos(bottomAngle), y: bottom), transform: transform)
        // 左半边：从下眼皮沿眼眶回到上眼皮。
        path.addArc(
            center: .zero, radius: 1, startAngle: .pi - bottomAngle, endAngle: .pi - topAngle, clockwise: false,
            transform: transform
        )
        path.closeSubpath()
    }

    /// 五角星。
    static func addStar(to path: CGMutablePath, center: CGPoint, radius: CGFloat, rotation: CGFloat) {
        guard radius > 0.2 else { return }
        for i in 0..<10 {
            let angle = rotation - .pi / 2 + CGFloat(i) * .pi / 5
            let r = i.isMultiple(of: 2) ? radius : radius * 0.48
            let point = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
    }

    /// 一只捂眼的手：一个手掌加四根朝上、略微张开的手指（都是圆角矩形）。
    /// 所有子路径的绕向相同，所以整体填充时是它们的并集。
    /// - Parameters:
    ///   - origin: 手到位时对着的眼睛中心。
    ///   - unit: 手的单位长度；整只手约 20 × 19 个单位。
    ///   - peek: 偷看程度：中间两根手指之间张开一道缝。
    static func addHand(to path: CGMutablePath, origin: CGPoint, unit k: CGFloat, peek: CGFloat) {
        guard k > 0.05 else { return }
        // 圆角半径略小于一半：正好等于一半时，浮点误差可能让系统认为"圆角比边长的一半还大"。
        let fingerWidth: CGFloat = 4.0
        let bases: [CGFloat] = [-5.4, -1.8, 1.8, 5.4]
        let lengths: [CGFloat] = [11.0, 12.6, 12.6, 11.0]
        let fans: [CGFloat] = [-14, -4.5, 4.5, 14]
        for i in 0..<4 {
            // 偷看：左边两根往左倒、右边两根往右倒，同时各自让开一点，中间露出一道宽宽的 V 形缝。
            let direction: CGFloat = i < 2 ? -1 : 1
            let transform = CGAffineTransform(
                translationX: origin.x + (bases[i] + direction * 1.4 * peek) * k, y: origin.y + 3.0 * k
            ).rotated(by: (fans[i] + direction * 19 * peek) * .pi / 180)
            path.addRoundedRect(
                in: CGRect(x: -fingerWidth / 2 * k, y: -lengths[i] * k, width: fingerWidth * k, height: (lengths[i] + 0.5) * k),
                cornerWidth: fingerWidth * 0.49 * k, cornerHeight: fingerWidth * 0.49 * k,
                transform: transform
            )
        }
        path.addRoundedRect(
            in: CGRect(x: origin.x - 7.6 * k, y: origin.y + 0.5 * k, width: 15.2 * k, height: 9.0 * k),
            cornerWidth: 4.0 * k, cornerHeight: 4.0 * k
        )
    }
}
