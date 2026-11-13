// Emotion · 调参表
//
// 情绪引擎里所有的阈值、时长、半径、概率都集中在这里，方便以后按手感调整。
// 每一项的含义和默认值在 docs/模块说明/emotion.md 第 4 节有一张对照表。
//
// 单位约定：时间是秒，距离是点（全局坐标），强度是 0…1。
// 名字以 Time 结尾的是"渐入渐出的时间常数"：大约经过这么久走完六成，约 3.5 倍这么久完全到位。

import Foundation

/// 情绪引擎的全部可调参数。`EmotionTuning()` 就是默认值。
public struct EmotionTuning: Sendable, Equatable {
    // MARK: 通用

    /// 平滑计算时，一帧最多按多长时间算。
    /// 应用休息了一阵再醒来的第一帧，如果按真实间隔算，参数会一步跳到位；封顶之后只会慢一点，不会跳。
    public var maxSmoothingStep: TimeInterval = 1.0 / 30
    /// 收尾：离目标只剩这么大比例时改成匀速走完，保证在有限时间内**正好**到达目标
    /// （到达之后表情不再变化，应用才能休息）。
    public var settleFraction: Double = 0.08
    /// 时间常数不小于这个值的渐变算"慢"的（汗慢慢收、脸红慢慢退、慢慢睡着……）。设为 0 表示没有慢的。
    public var slowChannelTime: TimeInterval = 0.5
    /// 只剩慢的渐变还没到位时，按多长的间隔出帧。默认每秒 30 次：慢的渐变每一步本来就很小，
    /// 看不出区别，而这类"余韵"往往要持续好几秒。设为 0 则每个显示刷新都算。
    public var slowFrameInterval: TimeInterval = 1.0 / 30

    // MARK: 视线

    /// 视线转向新目标的时间常数。越小越跟手，越大越"慢半拍"。
    public var gazeTime: TimeInterval = 0.08
    /// 视线的软半径，占图标宽度的比例：目标离脸这么远时，眼睛转到一半。
    /// 只影响视线过渡的匀称程度，取得和表情模块的画法接近（它是 0.12）。
    public var gazeSoftness: Double = 0.15

    // MARK: 眨眼

    /// 两次眨眼之间最短隔多久。
    public var blinkIntervalMin: TimeInterval = 2.5
    /// 两次眨眼之间最长隔多久。每个图标每次在这个范围里随机取，所以互不同步。
    public var blinkIntervalMax: TimeInterval = 7.0
    /// 一次眨眼（合上再睁开）用多久。
    public var blinkDuration: TimeInterval = 0.17
    /// 眨完一下之后，下一次连眨两下的概率。
    public var doubleBlinkChance: Double = 0.15
    /// 连眨时两下之间隔多久。
    public var blinkRepeatGap: TimeInterval = 0.1
    /// 只有眨眼、没有别的动画时，眨眼按多长的间隔出帧。默认每秒 30 次：一次眨眼算 5 帧左右，
    /// 肉眼看不出和每帧都算的区别，空闲时的出帧量却少了四成左右。设为 0 则每个显示刷新都算。
    /// 有别的动画在进行（应用本来就在连续出帧）时不受它影响，眨眼照样每帧都算。
    public var blinkFrameInterval: TimeInterval = 1.0 / 30

    // MARK: 害羞（悬停）

    /// 脸红起来的时间常数。
    public var blushRiseTime: TimeInterval = 0.15
    /// 鼠标移开后脸红退去的时间常数（"慢慢恢复"）。
    public var blushFallTime: TimeInterval = 0.7
    /// 眼神躲闪：往鼠标的反方向看多远，单位是图标宽度。
    public var shyLookAway: Double = 1.1
    /// 眼神躲闪：往下看多远，单位是图标高度。
    public var shyLookDown: Double = 1.2

    // MARK: 被拖向废纸篓（主角的害怕）

    /// 鼠标离废纸篓这么远以内才开始害怕；越近越怕。
    public var fearRadius: Double = 450
    /// 废纸篓位置不可信时放宽多少：可信度为 0 时，离估算区域这么近就算"已经到了"；可信度为 1 时不放宽。
    public var trashSlack: Double = 80
    /// 没在朝废纸篓去（停着或在远离）时，害怕打几折。离得越近这个折扣越不起作用，到了上方完全不打折。
    public var retreatRelief: Double = 0.3
    /// "正朝废纸篓去"这个判断生效的时间常数。
    public var headingRiseTime: TimeInterval = 0.2
    /// "不再朝废纸篓去"之后松一口气的时间常数。
    public var headingFallTime: TimeInterval = 0.6

    /// 威胁到这个程度时，惊恐（瞳孔缩小、眼睛瞪大）到头。威胁 = 0 时没有惊恐，中间按比例。
    public var fearFullAt: Double = 0.8
    /// 威胁超过这个值开始冒汗。
    public var sweatFrom: Double = 0.08
    /// 威胁到这个值时汗最多。
    public var sweatFullAt: Double = 0.5
    /// 威胁超过这个值开始发抖。
    public var trembleFrom: Double = 0.35
    /// 威胁到这个值时抖得最厉害。
    public var trembleFullAt: Double = 0.85
    /// 发抖幅度的上限。
    public var trembleMax: Double = 0.85
    /// 威胁超过这个值开始掉泪。
    public var tearsFrom: Double = 0.7
    /// 威胁到这个值时大哭。到了废纸篓上方威胁恒为 1。
    public var tearsFullAt: Double = 0.98
    /// 威胁超过这个值，主角的视线开始从"看着用户"转向废纸篓。
    public var stareFrom: Double = 0.04
    /// 威胁到这个值时，主角死盯废纸篓。
    public var stareFullAt: Double = 0.25
    /// 废纸篓就在主角脚下（脸几乎叠在它上面）时，视线往下偏多少，单位是图标高度。
    /// 没有这一项的话，盯着"自己所在的位置"会变成对眼。
    public var stareDownward: Double = 0.9

    /// 惊恐出现的时间常数。
    public var fearRiseTime: TimeInterval = 0.12
    /// 惊恐退去的时间常数。
    public var fearFallTime: TimeInterval = 0.6
    /// 汗冒出来的时间常数。
    public var sweatRiseTime: TimeInterval = 0.2
    /// 汗收回去的时间常数（"汗慢慢收"，最慢的一个）。
    public var sweatFallTime: TimeInterval = 1.2
    /// 开始发抖的时间常数。
    public var trembleRiseTime: TimeInterval = 0.15
    /// 不抖了的时间常数。
    public var trembleFallTime: TimeInterval = 0.4
    /// 眼泪涌出来的时间常数。
    public var tearsRiseTime: TimeInterval = 0.3
    /// 眼泪收回去的时间常数。
    public var tearsFallTime: TimeInterval = 0.6

    // MARK: 松手之后

    /// 松手后、结局出来之前，主角的脸在松手处最多停留多久；超过就飘回原位等消息。
    public var releaseHold: TimeInterval = 0.3
    /// 脸飘回原位的时间常数。
    public var homingTime: TimeInterval = 0.08
    /// 脸飘回原位的最低速度，点/秒。
    public var homingMinSpeed: Double = 500

    // MARK: 头晕（猛甩）

    /// 甩动强度达到这个值算"猛甩"，开始头晕。
    public var shakeThreshold: Double = 0.5
    /// 刚好达到阈值时的头晕程度；甩得更猛按比例升到 1。
    public var dizzyMin: Double = 0.6
    /// 不甩了（包括松手）之后，头晕原样保持多久才开始消退。连同消退大约"再晕两三秒"。
    public var dizzyLinger: TimeInterval = 1.6
    /// 晕起来的时间常数。
    public var dizzyRiseTime: TimeInterval = 0.2
    /// 头晕消退的时间常数。
    public var dizzyFallTime: TimeInterval = 0.45
    /// 威胁超过这个值，害怕开始压过头晕。
    public var dizzyYieldFrom: Double = 0.3
    /// 威胁到这个值，头晕被完全压下去（只剩害怕）。
    public var dizzyYieldFullAt: Double = 0.8

    // MARK: 全体围观

    /// 主角的威胁达到这个值，围观开始（一圈波纹从主角当时的位置传开）。
    public var alarmOn: Double = 0.4
    /// 威胁降到这个值以下，围观结束（比开始的门槛低，免得在门槛上来回跳）。
    public var alarmOff: Double = 0.2
    /// 威胁到这个值时，围观者的反应最强。
    public var alarmFullAt: Double = 0.8
    /// 波纹传开的速度，点/秒。跨屏也按全局坐标里的直线距离算。
    public var waveSpeed: Double = 900
    /// 波纹最晚多久传到（离得再远也不超过这么久）。
    public var waveMaxDelay: TimeInterval = 1.8
    /// 胆小的图标占多大比例。性格由长相种子决定，同一个图标永远相同。
    public var timidShare: Double = 0.35
    /// 好奇的图标占多大比例。剩下的是胆大的。
    public var curiousShare: Double = 0.35
    /// 围观反应出现的时间常数（抬手、瞪眼）。
    public var scareRiseTime: TimeInterval = 0.2
    /// 围观反应退去的时间常数（放下手）。
    public var scareFallTime: TimeInterval = 0.3
    /// 胆小的：反应到这个程度时手已完全捂住眼睛。
    public var timidCoverFullAt: Double = 0.6
    /// 好奇的：反应超过这个程度才开始抬手。
    public var curiousCoverFrom: Double = 0.1
    /// 好奇的：反应到这个程度时手已完全捂住眼睛。
    public var curiousCoverFullAt: Double = 0.65
    /// 好奇的：反应超过这个程度，指缝开始张开（这时手已基本捂上）。
    public var peekFrom: Double = 0.6
    /// 好奇的：反应到这个程度时，指缝张到最大。
    public var peekFullAt: Double = 0.95
    /// 好奇的：指缝最多张开多大。
    public var peekMax: Double = 0.9
    /// 胆小的：捂着眼时的惊恐程度（乘以反应强度）。
    public var timidFear: Double = 0.5
    /// 好奇的：偷看时的惊恐程度。
    public var curiousFear: Double = 0.4
    /// 胆大的：瞪眼看时的惊恐程度。
    public var boldFear: Double = 0.75

    // MARK: 幽灵

    /// 幽灵从冒出来到完全消散用多久。
    public var ghostDuration: TimeInterval = 2.6
    /// 一次删多个时，相邻两个幽灵错开多久出现。
    public var ghostStagger: TimeInterval = 0.15
    /// 一次删很多个时，从第一个到最后一个幽灵出现最多隔多久（个数多了就排得密一些）。
    public var ghostStaggerSpan: TimeInterval = 1.0

    // MARK: 打瞌睡

    /// 最近修改时间距今超过这么久的图标会打瞌睡。默认半年（182.5 天）。
    public var dozeAfter: TimeInterval = 182.5 * 86400
    /// 同时睡着的图标最多占桌面图标的多大比例（最久没动的优先）。
    public var maxSleepingFraction: Double = 1.0 / 3
    /// 鼠标离图标这么近（且正在动）会把它惊醒。
    public var wakeRadius: Double = 90
    /// 鼠标静止不超过这么久才算"正在动"。停在旁边不动的鼠标不算有人理它。
    public var wakeStillness: TimeInterval = 0.6
    /// 惊醒后没人理了，还醒着多久才重新犯困（"跟着看一会儿"）。
    public var wakeLinger: TimeInterval = 4
    /// 惊醒的时间常数。
    public var wakeTime: TimeInterval = 0.1
    /// 重新睡着的时间常数（"慢慢睡着"）。
    public var dozeOffTime: TimeInterval = 1.6
    /// 即使图标没有任何变化，也每隔这么久重新排一次"谁该打瞌睡"（有图标刚满半年）。
    public var dozeRecheckInterval: TimeInterval = 600

    // MARK: 彩蛋·无聊

    /// 鼠标静止这么久，图标们开始东张西望。
    public var boredAfter: TimeInterval = 12
    /// 整个桌面上，相邻两次"有谁张望一下"之间最短隔多久。
    public var glanceGapMin: TimeInterval = 0.7
    /// ……最长隔多久。
    public var glanceGapMax: TimeInterval = 2.2
    /// 一次张望最短看多久。
    public var glanceHoldMin: TimeInterval = 1.2
    /// 一次张望最长看多久。
    public var glanceHoldMax: TimeInterval = 3.0
    /// 张望时看邻居的概率；其余是看别处。
    public var glanceNeighborChance: Double = 0.6
    /// "看别处"看的是多远以外的一点。
    public var glanceFarDistance: Double = 400
    /// 鼠标静止超过这么久，开始进入"安静"状态：眨眼和张望逐渐放慢，省电。
    /// （鼠标在动的时候应用本来就在连续出帧，眨眼不额外费电；鼠标不动时每一次眨眼都要专门醒来。）
    public var quietAfter: TimeInterval = 20
    /// 完全安静下来之后（静止达到 quietAfter 的两倍），眨眼和张望的间隔拉长到几倍。
    public var quietStretch: Double = 3

    // MARK: 彩蛋·新来的

    /// 其它图标转头看新图标多久。
    public var newcomerLook: TimeInterval = 1.6
    /// 新图标眨几下眼。
    public var newcomerBlinks: Int = 3
    /// 新图标出现后多久开始眨眼。
    public var newcomerBlinkDelay: TimeInterval = 0.3

    public init() {}
}
