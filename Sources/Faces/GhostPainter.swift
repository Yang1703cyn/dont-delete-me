// Faces · 幽灵
//
// 图标被删后，原地飘起一个小幽灵：随进度匀速上升，进度为 p 时它的中心比图标矩形的中心高 p × 一个图标高
// （这是和情绪模块的约定，见 docs/接口约定.md §4.3），快到头时淡出。
// 这时图标已经不在了，所以只画幽灵，不画平常的脸；其它表情参数一律不看。

import CoreGraphics
import Foundation

enum GhostPainter {
    /// 幽灵身体的中心。
    static func center(progress: CGFloat, rect: CGRect, look: FaceLook, time: TimeInterval) -> CGPoint {
        let u = min(rect.width, rect.height) / 64
        // 左右轻轻摇摆；上升是匀速的，不加上下浮动（情绪模块要靠这个高度算"目送"的视线）。
        let sway = CGFloat(sin(time * 2 * .pi * 0.45 + look.phase * 2 * .pi)) * 2 * u
        return CGPoint(x: rect.midX + sway, y: rect.midY - progress * rect.height)
    }

    /// 幽灵的不透明度：刚冒出来时半透明，很快变实，快到头时淡出。
    static func opacity(progress: CGFloat) -> CGFloat {
        FaceMath.lerp(0.35, 1, FaceMath.smoothstep(0, 0.08, progress)) * (1 - FaceMath.smoothstep(0.6, 1, progress))
    }

    static func paint(params: FaceParams, rect: CGRect, time: TimeInterval, context: CGContext) {
        let progress = params.ghost
        let alpha = opacity(progress: progress)
        guard alpha > 0.004 else { return }
        let look = FaceLook(seed: params.seed)
        let u = min(rect.width, rect.height) / 64
        let center = center(progress: progress, rect: rect, look: look, time: time)
        // 刚冒出来时小一点，随后长到原大。
        let k = u * FaceMath.lerp(0.5, 1, FaceMath.smoothstep(0, 0.12, progress))
        let a = FaceStyle.ghostHalfWidth * k
        let b = FaceStyle.ghostHalfHeight * k

        // 身体：圆顶、直身、下摆是三道随时间荡漾的波浪。
        let hemHeight = 3.4 * k
        let ripple = time * 2 * .pi * 0.8 + look.phase * 2 * .pi
        func hem(_ x: CGFloat) -> CGFloat {
            let wave = cos(Double((x + a) / (2 * a)) * 3 * 2 * .pi + ripple)
            return center.y + b - hemHeight * 0.5 * (1 + CGFloat(wave))
        }
        let body = CGMutablePath()
        body.move(to: CGPoint(x: center.x - a, y: hem(-a)))
        body.addLine(to: CGPoint(x: center.x - a, y: center.y - b + a))
        // 画布 y 向下：角度从 π 增加到 2π，经过的是圆的上半边。
        body.addArc(
            center: CGPoint(x: center.x, y: center.y - b + a), radius: a,
            startAngle: .pi, endAngle: 2 * .pi, clockwise: false
        )
        let steps = 18
        for i in 0...steps {
            let x = a - 2 * a * CGFloat(i) / CGFloat(steps)
            body.addLine(to: CGPoint(x: center.x + x, y: hem(x)))
        }
        body.closeSubpath()

        context.setAlpha(alpha)
        context.setLineJoin(.round)
        context.addPath(body)
        context.setFillColor(FaceStyle.white)
        context.setStrokeColor(FaceStyle.ink)
        context.setLineWidth(max(FaceStyle.outline * k, 1))
        context.drawPath(using: .fillStroke)

        // 腮红。
        context.setFillColor(FaceStyle.ghostBlush)
        for side in [CGFloat(-1), 1] {
            context.fillEllipse(in: CGRect(
                x: center.x + side * 8.2 * k - 2.3 * k, y: center.y - 0.6 * k - 1.4 * k,
                width: 4.6 * k, height: 2.8 * k
            ))
        }
        // 两只墨色的椭圆眼睛、一张小圆嘴。
        for side in [CGFloat(-1), 1] {
            context.addEllipse(in: CGRect(
                x: center.x + side * 4.6 * k - 1.9 * k, y: center.y - 4.6 * k - 2.7 * k,
                width: 3.8 * k, height: 5.4 * k
            ))
        }
        context.addEllipse(in: CGRect(
            x: center.x - 1.6 * k, y: center.y + 1.6 * k - 2.0 * k, width: 3.2 * k, height: 4.0 * k
        ))
        context.setFillColor(FaceStyle.ink)
        context.fillPath()
        context.setAlpha(1)
    }
}
