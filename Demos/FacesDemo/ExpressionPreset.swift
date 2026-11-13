// FacesDemo · 8 种表情的"标准参数"
//
// 情绪模块（Emotion）将来会按自己的规则给出这些参数；演示程序不依赖它，
// 这里给每种表情配一组有代表性的参数，供样张、试玩窗口、耗时测量共用。

import CoreGraphics
import DDMCore
import Foundation

enum ExpressionPreset: Int, CaseIterable, Sendable {
    case calm, shy, dizzy, scared, crying, coveringEyes, dozing, ghost

    /// 中文名。
    var title: String {
        switch self {
        case .calm: "平静"
        case .shy: "害羞"
        case .dizzy: "头晕"
        case .scared: "害怕"
        case .crying: "哭"
        case .coveringEyes: "捂眼"
        case .dozing: "打瞌睡"
        case .ghost: "幽灵"
        }
    }

    var mood: FaceMood {
        switch self {
        case .calm: .calm
        case .shy: .shy
        case .dizzy: .dizzy
        case .scared: .scared
        case .crying: .crying
        case .coveringEyes: .coveringEyes
        case .dozing: .dozing
        case .ghost: .ghost
        }
    }

    /// 这种表情在强度 `intensity`（0…1）时的参数。
    /// - Parameters:
    ///   - gaze: 视线目标（相对图标中心的位移）。害羞时会自动躲开它。
    ///   - peek: 捂眼时指缝张开多大；其它表情不看这个值。
    func state(seed: UInt64, intensity: Double, gaze: CGVector = .zero, peek: Double = 0) -> FaceState {
        var state = FaceState(mood: mood, seed: seed, gazeTarget: gaze, gazeFollow: 1)
        switch self {
        case .calm:
            break
        case .shy:
            // 眼神躲闪：看向鼠标的反方向、偏下。
            let away = gaze == .zero ? CGVector(dx: -70, dy: 75) : CGVector(dx: -gaze.dx, dy: abs(gaze.dy) + 60)
            state.gazeTarget = CGVector(
                dx: gaze.dx + (away.dx - gaze.dx) * intensity, dy: gaze.dy + (away.dy - gaze.dy) * intensity
            )
            state.blush = intensity
        case .dizzy:
            state.dizziness = intensity
        case .scared:
            state.fear = intensity
            state.sweat = intensity
            state.tremble = 0.8 * intensity
        case .crying:
            state.tears = intensity
            state.fear = 0.25 + 0.3 * intensity
            state.tremble = 0.5 * intensity
        case .coveringEyes:
            state.cover = intensity
            state.peek = peek
        case .dozing:
            state.sleepiness = intensity
            state.gazeFollow = 1 - intensity
        case .ghost:
            state.ghost = intensity
        }
        return state
    }
}
