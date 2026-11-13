// 省电：鼠标离得远时，眼珠其实纹丝不动——这种时候不重画。
//
// 鼠标一动，每张脸的"视线目标"都在变，按字面比较的话每张脸每一帧都算"表情变了"，都要重画。
// 但眼珠能转的范围很小（64 点的图标上整段行程约 2.7 点），目标在远处挪几十点，眼珠连十分之一点都动不了。
// 这里判断的就是这件事：两个表情除了视线目标以外完全相同，而且眼珠的落点几乎没变——那就沿用屏幕上已有的那张图。
//
// 眼珠落点的算法和表情模块一致（`Sources/Faces/FacePose.swift` 的 `gaze(from:to:reach:follow:)`）：
//   落点 = 方向 × 距离 ÷ (距离 + 图标宽 × 0.12) × 跟随程度        （单位圆内的向量，1 = 转到头）
// 表情模块是从两只眼睛各自的位置出发算的，这里拿图标中心和左右两只眼睛大致的位置各算一遍，取变化最大的那个。
// 如果表情模块以后改了这个算法，这里最坏的结果是多重画几次或眼珠晚更新不到十分之一点，不会出错。

import CoreGraphics
import DDMCore
import Foundation

enum FaceRedraw {
    /// 眼珠落点的变化小于这么多（占整段行程的比例）就不重画。
    /// 整段行程在 64 点的图标上约 2.7 点，0.02 相当于不到 0.06 点。
    static let gazeTolerance = 0.02

    /// 表情模块里视线"由近到远趋于转到头"的尺度：图标宽的这么多倍。
    private static let gazeReach: CGFloat = 0.12
    /// 两只眼睛大致在图标中心左右各这么远（图标宽的倍数）、上方这么远（图标高的倍数）。
    private static let eyeOffsetX: CGFloat = 0.17
    private static let eyeOffsetY: CGFloat = -0.08

    /// 屏幕上已有的那张脸（`shown`）和这一帧要的（`next`）画出来是否看不出差别。
    /// - Parameter iconSize: 图标矩形的大小。
    static func looksSame(_ shown: FaceState, _ next: FaceState, iconSize: CGSize) -> Bool {
        if shown == next { return true }

        // 除了视线目标和跟随程度，别的必须一模一样。
        var aligned = shown
        aligned.gazeTarget = next.gazeTarget
        aligned.gazeFollow = next.gazeFollow
        guard aligned == next else { return false }

        guard iconSize.width > 0, iconSize.height > 0,
              isFinite(shown.gazeTarget), isFinite(next.gazeTarget),
              shown.gazeFollow.isFinite, next.gazeFollow.isFinite
        else { return false }

        let reach = iconSize.width * gazeReach
        let origins = [
            CGVector(dx: 0, dy: 0),
            CGVector(dx: -iconSize.width * eyeOffsetX, dy: iconSize.height * eyeOffsetY),
            CGVector(dx: iconSize.width * eyeOffsetX, dy: iconSize.height * eyeOffsetY),
        ]
        for origin in origins {
            let before = landing(of: shown, from: origin, reach: reach)
            let after = landing(of: next, from: origin, reach: reach)
            if hypot(after.dx - before.dx, after.dy - before.dy) >= gazeTolerance {
                return false
            }
        }
        return true
    }

    /// 从 `origin`（相对图标中心）看向视线目标时，眼珠的落点：单位圆内的向量。
    private static func landing(of state: FaceState, from origin: CGVector, reach: CGFloat) -> CGVector {
        let dx = state.gazeTarget.dx - origin.dx
        let dy = state.gazeTarget.dy - origin.dy
        let distance = hypot(dx, dy)
        guard distance > 1e-6, state.gazeFollow > 0 else { return .zero }
        let strength = distance / (distance + reach) * CGFloat(state.gazeFollow)
        return CGVector(dx: dx / distance * strength, dy: dy / distance * strength)
    }

    private static func isFinite(_ vector: CGVector) -> Bool {
        vector.dx.isFinite && vector.dy.isFinite
    }
}
