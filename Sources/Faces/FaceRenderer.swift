// Faces · 模块入口：表情绘制者
//
// 应用以 `FaceRenderer()` 构造它，通过 `FaceRendering` 协议调用（docs/接口约定.md 第 6 节）。
// 纯代码绘制（CoreGraphics），不用图片素材；无状态——同样的（表情状态、图标矩形大小、时间）
// 永远画出同样的画面，画面与图标矩形在屏幕上的位置无关。
//
// 文件分工：
//   FaceStyle.swift     风格规范：颜色、线宽、比例、各种门槛
//   FacePose.swift      姿态：把表情参数算成五官的位置和大小（只有数字）
//   FacePainter.swift   绘制：照着姿态往画布上画
//   FaceShapes.swift    形状：水滴、眼眶、星星、手
//   GhostPainter.swift  幽灵
// 风格说明、每个参数的视觉含义、已知限制见 docs/模块说明/faces.md。

import CoreGraphics
import DDMCore
import Foundation

public struct FaceRenderer: FaceRendering {
    public init() {}

    public func draw(_ state: FaceState, in iconRect: CGRect, context: CGContext, time: TimeInterval) {
        guard iconRect.width > 0, iconRect.height > 0, !iconRect.isInfinite, !iconRect.isNull else { return }
        let params = FaceParams(state)
        let time = time.isFinite ? time : 0
        // 画布是反复使用的：保存 / 恢复必须成对，画完后画布的状态和进来时一样。
        context.saveGState()
        defer { context.restoreGState() }
        if params.isGhost {
            GhostPainter.paint(params: params, rect: iconRect, time: time, context: context)
        } else {
            FacePainter(pose: FacePose(params: params, rect: iconRect, time: time), context: context).paint()
        }
    }

    /// 画到图标矩形外面多远。只有三种东西会画到外面，各占一档，和强度无关：
    ///   - 往下流的泪（`tears` 超过 0.4）：下方留 0.25 个图标高；
    ///   - Zzz（`sleepiness` 超过 0.35）：上方留约 0.22 个图标高；
    ///   - 幽灵：上方留约 0.8 个图标高（它要升一个图标高）。
    /// 其它效果（汗、星星、发抖线、手、飞溅的泪珠）都画在图标矩形以内。
    /// 结果向上取整到整点，所以同一档的画布大小始终相同。
    public func outsets(for state: FaceState, iconSize: CGSize) -> EdgeOutsets {
        guard iconSize.width > 0, iconSize.height > 0 else { return .zero }
        let u = min(iconSize.width, iconSize.height) / 64
        if state.mood == .ghost {
            return EdgeOutsets(top: (iconSize.height / 2 + FaceStyle.ghostHeadroom * u).rounded(.up))
        }
        var result = EdgeOutsets.zero
        if state.tears > Double(FaceStyle.tearStreamThreshold) {
            result.bottom = (FaceStyle.tearOutset * u).rounded(.up)
        }
        if state.sleepiness > Double(FaceStyle.zzzThreshold) {
            result.top = (FaceStyle.zzzOutset * u).rounded(.up)
        }
        return result
    }

    /// 循环小动画多久要重画一次。
    ///   - 幽灵、发抖、头晕、泪流：每个显示刷新都重画（0）；
    ///   - 只有汗：每秒 30 次；只是泪汪汪（泪还没流下来）：每秒 20 次；
    ///   - 睡着（Zzz、缓慢起伏）：每秒 4 次（`FaceStyle.sleepFrameInterval`；动作按这个帧率设计）；
    ///   - 其余（平静、害羞、不发抖的害怕、捂眼、犯困但还没睡着）：画面不随时间变化，返回 nil。
    public func animationInterval(for state: FaceState) -> TimeInterval? {
        if state.mood == .ghost { return 0 }
        if state.tremble > 0 || state.dizziness > 0 || state.tears > Double(FaceStyle.tearStreamThreshold) {
            return 0
        }
        var interval: TimeInterval?
        func atLeast(every seconds: TimeInterval) {
            interval = min(interval ?? seconds, seconds)
        }
        if state.sweat > 0 { atLeast(every: 1.0 / 30) }
        if state.tears > 0.05 { atLeast(every: 1.0 / 20) }
        if state.sleepiness > Double(FaceStyle.zzzThreshold) { atLeast(every: FaceStyle.sleepFrameInterval) }
        return interval
    }
}
