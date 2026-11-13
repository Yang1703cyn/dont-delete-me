// Emotion · 视线的平滑
//
// 要解决的问题：视线目标换了（从鼠标换成幽灵、换成被拖的同伴……），眼睛要平滑地转过去。
// 不能直接对"目标点"做平滑——目标离脸很远时瞳孔早就转到头了，目标点在远处滑动几百点眼睛纹丝不动，
// 滑到脸附近的那一两帧里瞳孔却会从一头甩到另一头。
//
// 办法：把（目标点，跟随程度）换算成一个三维的量再做平滑——
//   前两维 = 跟随程度 × 目标的方向 × "偏了多少"（目标越远越接近 1），也就是瞳孔大致会偏到哪里；
//   第三维 = 跟随程度 × "离脸多近"（目标就在脸上时是 1，很远时是 0），也就是对眼的程度。
// 在这个量上走直线，画面上看到的就是瞳孔匀称地扫过去：
//   从左边的远处转到右边的远处，途中经过"平视前方"，而不是经过"对眼"；
//   "看着用户"（跟随程度 0）就是原点，转过去、转回来都是瞳孔平滑地收回正中。

import CoreGraphics
import Foundation

struct Gaze: Sendable {
    // 平滑后的量。
    private var x = 0.0
    private var y = 0.0
    private var z = 0.0
    /// 已经到位，而且目标没变：这时什么都不用算。
    private var settled = false
    private var started = false
    private var lastTarget = CGVector.zero
    private var lastFollow = 0.0
    private var lastSoftness = 0.0

    /// 朝新的视线目标走一帧。
    /// - Parameters:
    ///   - target: 想看的点，相对脸所在矩形中心的位移。
    ///   - follow: 想要的跟随程度，0 = 平视前方。
    ///   - softness: 软半径（点）：目标离脸这么远时算"偏了一半"。
    /// - Returns: 这一帧交给表情模块的视线目标和跟随程度；`moving` 表示还没转到位。
    ///   到位之后返回的就是传进来的 `target` 本身（跟随程度为 0 时统一返回零向量），一个比特都不差——
    ///   这样静止的画面每一帧的表情状态完全相同，应用才不会白白重画。
    mutating func advance(
        toward target: CGVector, follow: Double, softness: Double, ease: Ease
    ) -> (target: CGVector, follow: Double, moving: Bool) {
        if settled, target == lastTarget, follow == lastFollow, softness == lastSoftness {
            return (follow > 0 ? target : .zero, follow, false)
        }
        lastTarget = target
        lastFollow = follow
        lastSoftness = softness

        // 目标换算成三维的量。
        let tx = Double(target.dx)
        let ty = Double(target.dy)
        let reach = (tx * tx + ty * ty).squareRoot() + softness
        let goalX = reach > 0 ? tx * follow / reach : 0
        let goalY = reach > 0 ? ty * follow / reach : 0
        let goalZ = reach > 0 ? follow * softness / reach : follow

        let ex = goalX - x
        let ey = goalY - y
        let ez = goalZ - z
        let error = (ex * ex + ey * ey + ez * ez).squareRoot()
        let stride = max(error * ease.k, ease.minStep)
        if !started || stride >= error {
            // 第一次（没有"上一帧"可言），或者这一帧就能走到：直接到位。
            started = true
            x = goalX
            y = goalY
            z = goalZ
            settled = true
            return (follow > 0 ? target : .zero, follow, false)
        }
        settled = false
        let fraction = stride / error
        x += ex * fraction
        y += ey * fraction
        z += ez * fraction

        // 换算回（目标点，跟随程度）。
        let planar = (x * x + y * y).squareRoot()
        let depth = max(z, 0)
        let outFollow = min(planar + depth, 1)
        guard outFollow > 1e-6, planar > 1e-9 else {
            return (.zero, outFollow > 1e-6 ? outFollow : 0, true)
        }
        // "偏了多少"封顶在 0.999：再远画面也没有区别，免得换算出天文数字。
        let offset = min(planar / (planar + depth), 0.999)
        let distance = softness * offset / (1 - offset)
        return (
            CGVector(dx: CGFloat(x / planar * distance), dy: CGFloat(y / planar * distance)),
            outFollow,
            true
        )
    }
}
