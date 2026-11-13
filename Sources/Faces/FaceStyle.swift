// Faces · 视觉风格规范
//
// 选定的风格是「大眼小嘴」：眼睛是主角（略高的椭圆眼眶、又大又黑的瞳孔、两点高光），
// 嘴和眉毛是配角（平时只有一个很小的微笑，情绪上来才长出眉毛、嘴才变形）。
// 颜色、线宽、比例都集中在这个文件里；改风格先改这里。说明见 docs/模块说明/faces.md。
//
// 尺寸单位 u：图标短边 / 64，也就是"64 点图标上的 1 点"。下面的比例都按 u 给出。

import CoreGraphics
import Foundation

enum FaceStyle {
    // MARK: 颜色（全部是 sRGB；叠加层的画布和窗口也都是 sRGB）

    static func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// 墨线：眼眶、瞳孔、眉毛、嘴线。偏紫的近黑色，比纯黑柔和。
    static let ink = color(0x221E2B)
    /// 眼白、高光、手、幽灵，以及墨线外面那圈"贴纸边"。
    static let white = color(0xFFFFFF)
    /// 腮红。
    static let blush = color(0xFF6B8E)
    /// 腮红上的斜线。
    static let blushLine = color(0xE23A64)
    /// 泪和汗的填充：很浅的蓝，在蓝色文件夹上也比底色亮。
    static let water = color(0xC4EEFF)
    /// 泪和汗的描边：较深的蓝，在浅色墙纸和白色文稿上靠它显形。
    static let waterEdge = color(0x2B8BDA)
    /// 张开的嘴里面。
    static let mouthInside = color(0x6E1F35)
    static let tongue = color(0xFF8FA6)
    /// 头晕时转圈的星星。
    static let star = color(0xFFD64A)
    /// 捂眼的手：比眼白暖一点的米色，这样从指缝里露出来的眼白才分得清。
    static let hand = color(0xFFECD2)
    /// 眨眼、睡着时上、下眼皮各走多远（占眼睛高度的比例，合起来是 1）：眼睛闭在中线偏下的地方。
    static let lidTopShare: CGFloat = 0.7
    static let lidBottomShare: CGFloat = 0.3
    /// 幽灵的腮红。
    static let ghostBlush = color(0xFFB3C4)

    /// 腮红最浓时的不透明度。
    static let blushAlpha: CGFloat = 0.82
    /// 泪水漫过瞳孔时，盖在瞳孔上那一层的不透明度（太高瞳孔就看不见了）。
    static let tearOverPupilAlpha: CGFloat = 0.3

    // MARK: 比例（单位 u，除非注明是"占图标的比例"）

    /// 两只眼睛所在的高度：占图标高度的比例（从上往下）。
    static let eyeLine: CGFloat = 0.47
    /// 眼眶的半宽、半高。
    static let eyeRadiusX: CGFloat = 7.6
    static let eyeRadiusY: CGFloat = 8.6
    /// 两只眼眶之间留的空隙的一半。
    static let eyeHalfGap: CGFloat = 2.0
    /// 瞳孔半径：平静时、最害怕时。
    static let pupilRadius: CGFloat = 4.6
    static let pupilRadiusScared: CGFloat = 2.0
    /// 瞳孔离眼眶内缘至少这么远（比轮廓线的一半还小：看到头时瞳孔贴着眼眶）。
    static let pupilMargin: CGFloat = 0.3
    /// 害怕到头时眼睛瞪大的比例。
    static let eyeWiden: CGFloat = 0.12
    /// 视线：目标离眼睛这么远（占图标宽度的比例）时，瞳孔偏到一半。
    /// 取得小，鼠标停在图标上时两眼才对得明显。
    static let gazeReach: CGFloat = 0.12
    /// 整张脸朝视线方向"探"过去的最大距离（横、纵）。
    static let leanX: CGFloat = 1.2
    static let leanY: CGFloat = 0.9

    /// 嘴在眼眶下缘的下方多远。
    static let mouthDrop: CGFloat = 4.6
    /// 平静时微笑的宽度和弧度。
    static let smileWidth: CGFloat = 4.8
    static let smileCurve: CGFloat = 1.7

    // MARK: 线宽（单位 u；括号里是下限，单位点——保证小图标、1x 屏上线条不会细到发虚）

    /// 眼眶轮廓 1.5u（≥ 1 点）。
    static let outline: CGFloat = 1.5
    /// 上眼皮、闭眼的线 2.0u（≥ 1.25 点）。
    static let lidLine: CGFloat = 2.0
    /// 眉毛、嘴、发抖线、Zzz 1.6u（≥ 1 点）。
    static let inkLine: CGFloat = 1.6
    /// 墨线外面白边的宽度 1.0u（≥ 0.75 点）。
    static let halo: CGFloat = 1.0
    /// 泪、汗的描边 0.9u（≥ 0.75 点）。
    static let waterLine: CGFloat = 0.9

    // MARK: 大小适配

    /// 图标小于 64 点时五官相对放大：32 点时放大到 1.14 倍（再大就超出窄图标的宽度了）。
    static let smallIconBoost: CGFloat = 0.14
    /// 图标小于这个大小（点）时省掉次要细节：第二点高光、腮红斜线、发抖线、飞溅的泪珠、第三滴汗。
    static let fineDetailMinSize: CGFloat = 44

    // MARK: 效果出现的门槛（绘制和"外扩声明"共用，保证两边一致）

    /// 泪超过这个值才开始往下流（在此之前只是眼眶里泪汪汪）。流下来的泪会画到图标下方。
    static let tearStreamThreshold: CGFloat = 0.4
    /// 困意超过这个值开始缓慢起伏、画面开始定时重画，Zzz 的画布也从这里留出来（Zzz 会画到图标上方）。
    /// Zzz 本身随困意长大、淡入，约 0.5 起才看得见（见 FacePose 的 zzzAlpha）。
    static let zzzThreshold: CGFloat = 0.35

    // MARK: 睡着时的循环小动画（按每秒 4 帧设计）

    /// 睡着时（困意超过 zzzThreshold）多久重画一次：每秒 4 帧。
    /// 桌面上睡着的图标是常态，这一项决定了空闲时的耗电。起伏和 Zzz 的动作都按这个帧率设计：
    /// 64 点图标上相邻两帧之间任何东西都只移动不到半个点，Z 的出现和消失靠大小变化，低帧率下也不显得卡。
    static let sleepFrameInterval: TimeInterval = 0.25
    /// 起伏一周的时长（秒）：每秒 4 帧时正好 16 帧。Zzz 也按这个周期循环，两者同步。
    static let breathPeriod: TimeInterval = 4.0
    /// 起伏的幅度（单位 u）：整张脸上下各移动这么多。
    static let breathLift: CGFloat = 0.6
    /// 每个 Z 停留多久（秒）：每秒 4 帧时是 12 帧。比"三个 Z 冒完"的间隔长一点，
    /// 所以下一轮最下面的小 z 冒出来时，上一轮最上面的大 Z 还在——Zzz 是连成一串往上飘的，不会看上去"跳回原处"。
    static let zzzLife: TimeInterval = 3.0
    /// 三个 Z（由小到大、由下往上）：在一个起伏周期里第几秒冒出来，以及位置和大小。
    /// 位置相对图标矩形：x 从中线往右、y 从上缘往下，单位 u；大小是 Z 的半宽（单位：五官单位 s）。
    /// 每个 Z 在停留期间往右上飘 zzzDrift。数值保证加上线宽、白边之后仍在 zzzOutset 以内（测试会检查）。
    static let zzzLetters: [(spawn: TimeInterval, x: CGFloat, y: CGFloat, half: CGFloat)] = [
        (2.0, 13.0, 14.0, 2.0),
        (2.75, 18.0, 4.5, 2.7),
        (3.5, 23.0, -4.5, 3.5),
    ]
    /// 每个 Z 在停留期间飘多远（单位 u）：往右、往上。
    static let zzzDriftX: CGFloat = 1.0
    static let zzzDriftY: CGFloat = 2.4

    // MARK: 画到图标外面多远（单位 u）

    /// 泪流到图标下缘以下多远（泪带的末端）。
    static let tearReach: CGFloat = 8
    /// 有泪流时，图标下方要留的画布。
    static let tearOutset: CGFloat = 16
    /// 有 Zzz 时，图标上方要留的画布。
    static let zzzOutset: CGFloat = 14
    /// 幽灵身体的半宽、半高。
    static let ghostHalfWidth: CGFloat = 14
    static let ghostHalfHeight: CGFloat = 17
    /// 幽灵：除了"上升一个图标高"之外，上方还要多留的画布（身体的上半截 + 余量）。
    static let ghostHeadroom: CGFloat = 19
}

/// 小数学工具。
enum FaceMath {
    @inline(__always)
    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    /// 平滑台阶：x 从 e0 到 e1 时，结果从 0 平滑升到 1。
    @inline(__always)
    static func smoothstep(_ e0: CGFloat, _ e1: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// 小数部分，结果在 [0, 1)。
    @inline(__always)
    static func fract(_ x: Double) -> Double { x - floor(x) }

    /// 把一个 0…1 的参数夹回范围（非数字按 0）。
    @inline(__always)
    static func unit(_ value: Double) -> CGFloat {
        value.isNaN ? 0 : CGFloat(min(max(value, 0), 1))
    }
}
