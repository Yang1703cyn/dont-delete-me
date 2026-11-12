// DDMCore · 表情状态与表情绘制者协议
//
// 分工（重要）：
//   - 情绪模块（Emotion）决定：是什么情绪、多强、何时眨眼、看向哪里——全部通过 `FaceState` 的参数表达；
//   - 表情模块（Faces）决定：这些参数长什么样，以及循环小动画（泪珠下落、Zzz 飘动、发抖、星星转圈）怎么动。

import CoreGraphics
import Foundation

/// 情绪种类。一共八种，不再新增。
public enum FaceMood: String, Sendable, CaseIterable {
    /// 平静：眼睛跟着鼠标转，偶尔眨眼。
    case calm
    /// 害羞：脸红、眼神躲闪。
    case shy
    /// 头晕：眼睛转圈、冒星星。
    case dizzy
    /// 害怕：冒汗、发抖、瞳孔缩小。
    case scared
    /// 哭：眼泪直流。
    case crying
    /// 捂眼：不忍心看（可以从指缝偷看）。
    case coveringEyes
    /// 打瞌睡：眼睛半闭或闭上，冒 Zzz。
    case dozing
    /// 幽灵：图标被删后原地飘起的小幽灵。
    case ghost
}

/// 一张脸在某一帧的完整表情。值类型，同样的值永远画出同样的画面。
///
/// `mood` 是主导情绪的标签；真正的"多强"由下面的连续参数给出。
/// 表情之间靠连续参数平滑过渡（例如害怕 0.3、困意 0.6 的中间状态也要成立），
/// 所以表情模块应当主要依据连续参数作画，让 `mood` 切换的那一帧画面不跳变；
/// `mood` 只用于无法连续化的造型选择和调试输出。唯一允许突变的是幽灵的出现。
///
/// 除特别说明外，所有强度参数的范围都是 0…1，0 表示"没有"，默认全为 0——
/// 也就是说 `FaceState(seed:)` 就是一张平视前方、睁着眼的平静的脸。
public struct FaceState: Sendable, Equatable {
    /// 主导情绪。
    public var mood: FaceMood

    /// 长相种子：让每个图标的五官略有不同（眼睛大小、间距等），同一个图标永远相同。
    /// 取自 `IconID.faceSeed`。
    public var seed: UInt64

    // 视线

    /// 视线目标相对**图标图像矩形中心**的位移，单位点，y 向下。
    /// 例如鼠标在图标右下方 100 点处就是 (100, 100)。目标很近时两眼会对眼——那是表情模块的事。
    /// 用相对位移而不是全局坐标，是为了让表情状态与图标在屏幕上的位置无关。
    public var gazeTarget: CGVector

    /// 视线跟随程度：0 = 平视前方（看着屏幕外的用户），1 = 完全看向 `gazeTarget`。
    /// 中间值按比例过渡。
    public var gazeFollow: Double

    // 眼睛

    /// 闭眼程度：0 = 睁开，1 = 完全闭上。眨眼由情绪模块随时间驱动这个值。
    public var blink: Double

    // 各种情绪的强度

    /// 脸红（害羞）。
    public var blush: Double
    /// 惊恐程度：瞳孔缩小、眼睛瞪大。
    public var fear: Double
    /// 汗。
    public var sweat: Double
    /// 发抖幅度。
    public var tremble: Double
    /// 泪：小值是泪汪汪，接近 1 是眼泪直流。
    public var tears: Double
    /// 头晕：眼睛转圈、冒星星。
    public var dizziness: Double
    /// 捂眼：手抬起、遮住眼睛的程度。
    public var cover: Double
    /// 偷看程度：捂着眼时指缝张开多大。只在 `cover` 大于 0 时有意义。
    public var peek: Double
    /// 困意：0 = 清醒，1 = 睡熟。
    public var sleepiness: Double
    /// 幽灵进度：0 = 刚冒出来，1 = 完全消散。只在 `mood == .ghost` 时有意义。
    /// 约定：幽灵随进度匀速上升，进度为 p 时它的中心比图标图像矩形的中心高 p × 一个图标高度
    /// （即到消散时正好升了一个图标高）。情绪模块据此算"目送幽灵"的视线目标，表情模块据此作画。
    public var ghost: Double

    public init(
        mood: FaceMood = .calm,
        seed: UInt64,
        gazeTarget: CGVector = .zero,
        gazeFollow: Double = 0,
        blink: Double = 0,
        blush: Double = 0,
        fear: Double = 0,
        sweat: Double = 0,
        tremble: Double = 0,
        tears: Double = 0,
        dizziness: Double = 0,
        cover: Double = 0,
        peek: Double = 0,
        sleepiness: Double = 0,
        ghost: Double = 0
    ) {
        self.mood = mood
        self.seed = seed
        self.gazeTarget = gazeTarget
        self.gazeFollow = gazeFollow
        self.blink = blink
        self.blush = blush
        self.fear = fear
        self.sweat = sweat
        self.tremble = tremble
        self.tears = tears
        self.dizziness = dizziness
        self.cover = cover
        self.peek = peek
        self.sleepiness = sleepiness
        self.ghost = ghost
    }

    /// 所有取值范围为 0…1 的参数（名字 + 键路径）。写测试、打印时间线时逐个遍历用。
    public static var unitParameters: [(name: String, keyPath: WritableKeyPath<FaceState, Double>)] {
        [
            ("gazeFollow", \.gazeFollow),
            ("blink", \.blink),
            ("blush", \.blush),
            ("fear", \.fear),
            ("sweat", \.sweat),
            ("tremble", \.tremble),
            ("tears", \.tears),
            ("dizziness", \.dizziness),
            ("cover", \.cover),
            ("peek", \.peek),
            ("sleepiness", \.sleepiness),
            ("ghost", \.ghost),
        ]
    }

    /// 所有 0…1 参数是否都在合法范围内，且视线目标是有限数。
    public var isValid: Bool {
        gazeTarget.dx.isFinite && gazeTarget.dy.isFinite
            && Self.unitParameters.allSatisfy { (0...1).contains(self[keyPath: $0.keyPath]) }
    }

    /// 把所有 0…1 参数夹回合法范围（非数字按 0 处理）。
    public func clamped() -> FaceState {
        var result = self
        for parameter in Self.unitParameters {
            let value = result[keyPath: parameter.keyPath]
            result[keyPath: parameter.keyPath] = value.isNaN ? 0 : min(max(value, 0), 1)
        }
        if !result.gazeTarget.dx.isFinite || !result.gazeTarget.dy.isFinite {
            result.gazeTarget = .zero
        }
        return result
    }
}

/// 表情绘制者：把一张脸画出来。由 Faces 实现。
///
/// - **无状态**：同样的（表情状态、图标矩形大小、时间）永远画出同样的画面；
///   画面不得依赖图标矩形在屏幕上的绝对位置（叠加层可能只移动画布而不重画）。
/// - 线程：不绑定线程，可在任何线程调用；应用里实际是在主线程、叠加层的绘制回调中调用。
/// - 性能目标：64 点图标、2x 下，单张脸一次绘制平均不超过约 0.3 毫秒。
public protocol FaceRendering: Sendable {
    /// 画一张脸。
    /// - Parameters:
    ///   - state: 表情状态。
    ///   - iconRect: 图标图像矩形，位于 `context` 当前的坐标系里。
    ///   - context: 画布。坐标系：y 向下、单位点（缩放已由叠加层设好，直接按点作画即可）。
    ///     绘制范围不得超出 `iconRect.expanded(by: outsets(for:iconSize:))`。
    ///   - time: 这一帧的单调时间（`FrameTime.monotonic`），循环小动画的相位由它决定。
    func draw(_ state: FaceState, in iconRect: CGRect, context: CGContext, time: TimeInterval)

    /// 这个表情状态最多会画到图标图像矩形外面多远（点）。
    /// 应用把它交给叠加层，用来决定每张脸的画布留多大。
    /// 返回值应当"成档"稳定——只随"哪些效果出现了"变化，不要随强度连续变化，
    /// 否则叠加层每帧都得改画布大小。
    func outsets(for state: FaceState, iconSize: CGSize) -> EdgeOutsets

    /// 这个表情状态的画面多久需要重画一次（循环小动画的刷新间隔，秒）。
    /// - `nil`：画面不随 `time` 变化（没有循环小动画）。只要表情状态不变，这张脸就不会重画。
    /// - `0`：每个显示刷新都要重画（泪珠下落、发抖、星星转圈这类快动画）。
    /// - 正数：至少每隔这么久重画一次（Zzz 飘动、缓慢起伏这类慢动画，例如 0.1 即每秒 10 次）。
    /// 这是省电的关键：没有动画务必返回 nil；慢动画给一个够用的间隔，不要一律返回 0——
    /// 桌面上有图标在打瞌睡是常态，不能因此让整个应用一直满帧重画。
    func animationInterval(for state: FaceState) -> TimeInterval?
}
