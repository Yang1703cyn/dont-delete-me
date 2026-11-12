// DDMCore · 可复现的随机数
//
// 逻辑模块不得使用全局随机数（SystemRandomNumberGenerator、Double.random(in:) 的无参形式等）：
// 随机数种子由外部传入，同样的种子永远产生同样的序列，这样测试和样张才能复现。

import Foundation

/// 用种子初始化的随机数发生器（SplitMix64）。快、质量够用、跨平台结果一致。
///
/// 用法：`var rng = SeededRandom(seed: 42); let x = Double.random(in: 0..<1, using: &rng)`
public struct SeededRandom: RandomNumberGenerator, Sendable, Equatable {
    public private(set) var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        return Self.finalize(state)
    }

    /// 下一个 [0, 1) 之间的小数。
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }

    /// 把一个数打散成看起来毫不相关的另一个数（确定性的、无状态的）。
    /// 用于从编号派生种子：相邻的编号会得到差别很大的结果。
    public static func mix(_ value: UInt64) -> UInt64 {
        finalize(value &+ 0x9E37_79B9_7F4A_7C15)
    }

    /// 由一个种子派生出第 `stream` 路互不相关的子种子。
    /// 例如同一个长相种子，第 0 路决定眼距、第 1 路决定性格，互不影响。
    public static func derive(_ seed: UInt64, stream: UInt64) -> UInt64 {
        mix(seed ^ mix(stream))
    }

    private static func finalize(_ value: UInt64) -> UInt64 {
        var z = value
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
